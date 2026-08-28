//
//  GradientCleanroomKernels.metal
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  GPU stages for EVA's clean-room gradient-artifact corrector, ported from
//  EVA/Gradient/ per docs/provenance/fastr-gpu-port-plan.md. No
//  third-party artifact-correction source was consulted, and no part of EVA's
//  earlier ported Metal backend was read while writing this.
//
//  Three rules run through every kernel here.
//
//    - No discrete logic. Donor ranking, component counts, scale rejection and
//      the ANC go/no-go all stay on the CPU. These kernels only produce dense
//      intermediates.
//    - No atomics. The artifact estimate is gathered per output sample from a
//      precomputed coverage table, not scattered with atomic adds, so the
//      summation order is fixed and repeated runs are bit-identical.
//    - Compensated (Kahan) accumulation wherever a reduction is longer than a
//      handful of terms. Metal has no double, and the Gram matrix in particular
//      feeds eigenvalue ratios that decide a component count.
//
//  Function names carry a `gcr` prefix so they cannot collide with any other
//  Metal library linked into EVA.
//

#include <metal_stdlib>
using namespace metal;

struct GCRParams {
    uint channelCount;
    uint sampleCount;      // samples per channel before upsampling
    uint upsampleFactor;
    uint epochCount;
    uint windowLength;
    uint pairCount;
    uint maxCover;         // widest coverage of any output sample
    uint hasOBS;
    uint jobCount;
    uint maxJobSize;
};

// MARK: - Compensated accumulation

/// One Kahan step. `sum` and `compensation` are carried across the loop.
inline void gcrAccumulate(thread float &sum, thread float &compensation, float value) {
    float adjusted = value - compensation;
    float total = sum + adjusted;
    compensation = (total - sum) - adjusted;
    sum = total;
}

// MARK: - Windowed-sinc upsampling

/// One sample of the upsampled channel, evaluated straight from the recorded
/// samples rather than from a materialised upsampled buffer — at 256 channels a
/// full upsampled copy would not fit, and only epoch windows are ever read.
///
/// Phase 0 passes the recorded sample through untouched, which is what keeps an
/// upsample/decimate round trip exact.
inline float gcrUpsampledSample(
    device const float *channels,
    uint channelBase,
    int position,
    int sampleCount,
    int factor,
    device const float *taps
) {
    if (factor <= 1) {
        return channels[channelBase + uint(clamp(position, 0, sampleCount - 1))];
    }
    int base = position / factor;
    int phase = position - base * factor;
    if (phase == 0) {
        return channels[channelBase + uint(clamp(base, 0, sampleCount - 1))];
    }
    device const float *phaseTaps = taps + phase * 8;
    float sum = 0.0f;
    for (int tap = 0; tap < 8; ++tap) {
        int index = clamp(base + tap - 3, 0, sampleCount - 1);
        sum += channels[channelBase + uint(index)] * phaseTaps[tap];
    }
    return sum;
}

/// Upsamples and lifts every epoch window onto the shared aligned grid.
///
/// One thread per `(channel, epoch, sample-in-window)`. An epoch whose window
/// falls outside the recording is filled with zeros and skipped everywhere
/// downstream by its `present` flag.
kernel void gcrExtractEpochs(
    device const float *channels      [[buffer(0)]],
    device const int   *windowStarts  [[buffer(1)]],
    device const float *upsampleTaps  [[buffer(2)]],
    device const float *delayTaps     [[buffer(3)]],
    device const int   *delayBase     [[buffer(4)]],
    device const uint  *delayFlags    [[buffer(5)]],
    device float       *windows       [[buffer(6)]],
    constant GCRParams &p             [[buffer(7)]],
    uint gid [[thread_position_in_grid]]
) {
    uint length = p.windowLength;
    uint epochCount = p.epochCount;
    if (gid >= p.channelCount * epochCount * length) { return; }

    uint index = gid % length;
    uint epoch = (gid / length) % epochCount;
    uint channel = gid / (length * epochCount);

    int start = windowStarts[epoch];
    if (start < 0) {
        windows[gid] = 0.0f;
        return;
    }

    uint channelBase = channel * p.sampleCount;
    int sampleCount = int(p.sampleCount);
    int factor = int(p.upsampleFactor);

    if (delayFlags[epoch] == 0) {
        windows[gid] = gcrUpsampledSample(
            channels, channelBase, start + int(index), sampleCount, factor, upsampleTaps
        );
        return;
    }

    // A constant fractional delay: the tap set was computed once on the CPU, and
    // only the integer part of the read position varies with `index`.
    int base = int(index) + delayBase[epoch];
    device const float *taps = delayTaps + epoch * 16;
    float sum = 0.0f;
    float compensation = 0.0f;
    for (int tap = 0; tap < 16; ++tap) {
        int within = clamp(base + tap - 7, 0, int(length) - 1);
        float value = gcrUpsampledSample(
            channels, channelBase, start + within, sampleCount, factor, upsampleTaps
        );
        gcrAccumulate(sum, compensation, value * taps[tap]);
    }
    windows[gid] = sum;
}

// MARK: - Correlation donor scoring

/// Mean and centred norm of every epoch window, so the correlation kernel below
/// runs one pass instead of three.
kernel void gcrEpochStats(
    device const float *windows [[buffer(0)]],
    device float       *means   [[buffer(1)]],
    device float       *norms   [[buffer(2)]],
    constant GCRParams &p       [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    uint length = p.windowLength;
    if (gid >= p.channelCount * p.epochCount) { return; }
    device const float *window = windows + gid * length;

    float sum = 0.0f;
    float compensation = 0.0f;
    for (uint index = 0; index < length; ++index) {
        gcrAccumulate(sum, compensation, window[index]);
    }
    float mean = sum / float(length);

    float variance = 0.0f;
    compensation = 0.0f;
    for (uint index = 0; index < length; ++index) {
        float deviation = window[index] - mean;
        gcrAccumulate(variance, compensation, deviation * deviation);
    }

    means[gid] = mean;
    norms[gid] = sqrt(variance);
}

/// Pearson correlation of every `(channel, candidate pair)` combination.
///
/// The pair list is built once on the CPU — it depends only on the epoch grid and
/// on censoring — so this is a pure batched reduction with no branching on data.
/// Ranking the results stays on the CPU.
kernel void gcrCorrelate(
    device const float *windows [[buffer(0)]],
    device const float *means   [[buffer(1)]],
    device const float *norms   [[buffer(2)]],
    device const int   *pairs   [[buffer(3)]],
    device float       *out     [[buffer(4)]],
    constant GCRParams &p       [[buffer(5)]],
    uint gid [[thread_position_in_grid]]
) {
    uint pairCount = p.pairCount;
    if (gid >= p.channelCount * pairCount) { return; }

    uint pair = gid % pairCount;
    uint channel = gid / pairCount;
    uint length = p.windowLength;

    uint targetSlot = channel * p.epochCount + uint(pairs[2 * pair]);
    uint candidateSlot = channel * p.epochCount + uint(pairs[2 * pair + 1]);

    float denominator = norms[targetSlot] * norms[candidateSlot];
    if (!(denominator > 1e-20f)) {
        out[gid] = 0.0f;
        return;
    }

    device const float *a = windows + targetSlot * length;
    device const float *b = windows + candidateSlot * length;
    float meanA = means[targetSlot];
    float meanB = means[candidateSlot];

    float covariance = 0.0f;
    float compensation = 0.0f;
    for (uint index = 0; index < length; ++index) {
        gcrAccumulate(covariance, compensation, (a[index] - meanA) * (b[index] - meanB));
    }
    out[gid] = covariance / denominator;
}

// MARK: - Template construction

/// Donor-average template for every `(channel, epoch, sample)`.
kernel void gcrBuildTemplates(
    device const float *windows      [[buffer(0)]],
    device const int   *donorOffsets [[buffer(1)]],
    device const int   *donorIndices [[buffer(2)]],
    device float       *templates    [[buffer(3)]],
    constant GCRParams &p            [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    uint length = p.windowLength;
    uint epochCount = p.epochCount;
    if (gid >= p.channelCount * epochCount * length) { return; }

    uint index = gid % length;
    uint slot = gid / length;
    uint channel = slot / epochCount;

    int first = donorOffsets[slot];
    int last = donorOffsets[slot + 1];
    if (last <= first) {
        templates[gid] = 0.0f;
        return;
    }

    float sum = 0.0f;
    float compensation = 0.0f;
    for (int cursor = first; cursor < last; ++cursor) {
        uint donor = channel * epochCount + uint(donorIndices[cursor]);
        gcrAccumulate(sum, compensation, windows[donor * length + index]);
    }
    templates[gid] = sum / float(last - first);
}

/// `dot(template, template)` and `dot(target, template)` per `(channel, epoch)`.
///
/// These two scalars are the whole reason the template exists: their ratio is the
/// fitted amplitude. They are returned to the CPU, which rounds and range-checks
/// them, because accepting or rejecting a scale is a decision.
kernel void gcrTemplateMoments(
    device const float *windows   [[buffer(0)]],
    device const float *templates [[buffer(1)]],
    device float       *energies  [[buffer(2)]],
    device float       *projections [[buffer(3)]],
    constant GCRParams &p         [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    uint length = p.windowLength;
    if (gid >= p.channelCount * p.epochCount) { return; }

    device const float *target = windows + gid * length;
    device const float *shape = templates + gid * length;

    float energy = 0.0f;
    float energyCompensation = 0.0f;
    float projection = 0.0f;
    float projectionCompensation = 0.0f;
    for (uint index = 0; index < length; ++index) {
        float value = shape[index];
        gcrAccumulate(energy, energyCompensation, value * value);
        gcrAccumulate(projection, projectionCompensation, target[index] * value);
    }
    energies[gid] = energy;
    projections[gid] = projection;
}

/// What template subtraction leaves behind, and what it takes away.
///
/// The residual stays on the shared aligned grid so OBS can compare shapes across
/// epochs; the estimate is put back on this epoch's own sub-sample phase, because
/// that is where it has to line up with the recording.
kernel void gcrResiduals(
    device const float *windows    [[buffer(0)]],
    device const float *templates  [[buffer(1)]],
    device const float *scales     [[buffer(2)]],
    device const uchar *present    [[buffer(3)]],
    device const float *delayTaps  [[buffer(4)]],
    device const int   *delayBase  [[buffer(5)]],
    device const uint  *delayFlags [[buffer(6)]],
    device float       *residuals  [[buffer(7)]],
    device float       *estimates  [[buffer(8)]],
    constant GCRParams &p          [[buffer(9)]],
    uint gid [[thread_position_in_grid]]
) {
    uint length = p.windowLength;
    uint epochCount = p.epochCount;
    if (gid >= p.channelCount * epochCount * length) { return; }

    uint index = gid % length;
    uint slot = gid / length;
    if (present[slot] == 0) {
        residuals[gid] = 0.0f;
        estimates[gid] = 0.0f;
        return;
    }

    uint epoch = slot % epochCount;
    float scale = scales[slot];
    device const float *shape = templates + slot * length;
    float scaled = shape[index] * scale;
    residuals[gid] = windows[gid] - scaled;

    if (delayFlags[epoch] == 0) {
        estimates[gid] = scaled;
        return;
    }

    int base = int(index) + delayBase[epoch];
    device const float *taps = delayTaps + epoch * 16;
    float sum = 0.0f;
    float compensation = 0.0f;
    for (int tap = 0; tap < 16; ++tap) {
        int within = clamp(base + tap - 7, 0, int(length) - 1);
        gcrAccumulate(sum, compensation, (shape[within] * scale) * taps[tap]);
    }
    estimates[gid] = sum;
}

// MARK: - OBS Gram

/// Epoch-by-epoch Gram matrix of each OBS job's detrended residuals.
///
/// One thread per `(i, j, job)` over the upper triangle. Jobs are ragged, so each
/// carries its own size and the padding threads exit immediately. The result is
/// widened to double on the CPU before the eigen-decomposition, which decides how
/// many components are removed.
kernel void gcrGram(
    device const float *detrended  [[buffer(0)]],
    device const int   *jobOffsets [[buffer(1)]],
    device const int   *jobSizes   [[buffer(2)]],
    device float       *grams      [[buffer(3)]],
    constant GCRParams &p          [[buffer(4)]],
    uint3 gid [[thread_position_in_grid]]
) {
    uint job = gid.z;
    if (job >= p.jobCount) { return; }
    uint size = uint(jobSizes[job]);
    uint row = gid.x;
    uint column = gid.y;
    if (row >= size || column >= size || column < row) { return; }

    uint length = p.windowLength;
    device const float *a = detrended + uint(jobOffsets[job]) + row * length;
    device const float *b = detrended + uint(jobOffsets[job]) + column * length;

    float sum = 0.0f;
    float compensation = 0.0f;
    for (uint index = 0; index < length; ++index) {
        gcrAccumulate(sum, compensation, a[index] * b[index]);
    }

    uint base = job * p.maxJobSize * p.maxJobSize;
    grams[base + row * p.maxJobSize + column] = sum;
    grams[base + column * p.maxJobSize + row] = sum;
}

// MARK: - Assembly

/// Gathers the per-epoch estimates into the artifact estimate, averages where
/// adjacent epochs overlap, and subtracts.
///
/// One thread per output sample, reading only the epochs a precomputed table says
/// cover it — the inverse of the CPU's scatter, and the reason no atomics are
/// needed. Decimation is free here: only every `upsampleFactor`-th position on the
/// upsampled axis is ever visited, so the full upsampled artifact is never built.
///
/// A sample no epoch covers gathers nothing, so `input - 0` comes out
/// bit-identical, which is the guarantee
/// `samplesOutsideCorrectedEpochsAreBitIdentical` asserts.
kernel void gcrAssemble(
    device const float *inputs       [[buffer(0)]],
    device const float *estimates    [[buffer(1)]],
    device const float *obs          [[buffer(2)]],
    device const uchar *present      [[buffer(3)]],
    device const int   *coverEpochs  [[buffer(4)]],
    device const int   *windowStarts [[buffer(5)]],
    device float       *cleaned      [[buffer(6)]],
    device float       *artifact     [[buffer(7)]],
    constant GCRParams &p            [[buffer(8)]],
    uint gid [[thread_position_in_grid]]
) {
    uint sampleCount = p.sampleCount;
    if (gid >= p.channelCount * sampleCount) { return; }

    uint sample = gid % sampleCount;
    uint channel = gid / sampleCount;
    int position = int(sample) * int(p.upsampleFactor);
    uint length = p.windowLength;
    uint epochCount = p.epochCount;
    uint maxCover = p.maxCover;
    device const int *cover = coverEpochs + sample * maxCover;

    float sum = 0.0f;
    uint count = 0;
    for (uint slot = 0; slot < maxCover; ++slot) {
        int epoch = cover[slot];
        if (epoch < 0) { break; }
        uint index = channel * epochCount + uint(epoch);
        if (present[index] == 0) { continue; }
        sum += estimates[index * length + uint(position - windowStarts[epoch])];
        count += 1;
    }

    // OBS is accumulated in a second pass, after every template contribution, to
    // match the summation order of the CPU backend.
    if (p.hasOBS != 0) {
        for (uint slot = 0; slot < maxCover; ++slot) {
            int epoch = cover[slot];
            if (epoch < 0) { break; }
            uint index = channel * epochCount + uint(epoch);
            if (present[index] == 0) { continue; }
            sum += obs[index * length + uint(position - windowStarts[epoch])];
        }
    }

    if (count > 1) { sum /= float(count); }
    artifact[gid] = sum;
    cleaned[gid] = inputs[gid] - sum;
}
