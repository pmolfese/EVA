//
//  WaveletKernels.metal
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  GPU form of the undecimated (stationary) wavelet transform's per-level step,
//  used by the Wavelet Artifact Explorer's scan. One thread produces one
//  output sample for one channel, so a whole net's worth of channels is a
//  single dispatch per level.
//
//  The convolution deliberately mirrors `WaveletTransform.swtStep` exactly —
//  same forward-only dilated taps, same circular boundary, same tap order — so
//  the two backends agree to within float-vs-double precision. Levels stay
//  sequential (each consumes the previous level's approximation), so the host
//  dispatches once per level and ping-pongs the approximation buffers.
//

#include <metal_stdlib>
using namespace metal;

struct WaveletSWTParameters {
    uint sampleCount;
    uint channelCount;
    uint lowLength;
    uint highLength;
    uint dilation;
};

/// One SWT level for a batch of channels laid out channel-major
/// (`channel * sampleCount + sample`).
kernel void waveletSWTLevel(
    device const float *input           [[buffer(0)]],
    device float *approx                [[buffer(1)]],
    device float *detail                [[buffer(2)]],
    device const float *lowPass         [[buffer(3)]],
    device const float *highPass        [[buffer(4)]],
    constant WaveletSWTParameters &p    [[buffer(5)]],
    uint2 gid                           [[thread_position_in_grid]]
) {
    const uint sample = gid.x;
    const uint channel = gid.y;
    if (sample >= p.sampleCount || channel >= p.channelCount) {
        return;
    }

    const uint base = channel * p.sampleCount;

    float sumLow = 0.0f;
    for (uint k = 0; k < p.lowLength; ++k) {
        const uint idx = (sample + k * p.dilation) % p.sampleCount;
        sumLow += lowPass[k] * input[base + idx];
    }

    float sumHigh = 0.0f;
    for (uint k = 0; k < p.highLength; ++k) {
        const uint idx = (sample + k * p.dilation) % p.sampleCount;
        sumHigh += highPass[k] * input[base + idx];
    }

    approx[base + sample] = sumLow;
    detail[base + sample] = sumHigh;
}

// MARK: - Thresholding and accumulation
//
// The transform is a small fraction of the scan's work; the per-level
// thresholding and accumulation that follows it is the bulk. Keeping the
// detail bands resident here and finishing the job on-device avoids reading
// every level of every channel back to the CPU just to walk it again.
//
// The only genuinely serial part is the robust median/MAD behind each window's
// threshold, which needs sorting. The host computes those from a strided
// subsample and uploads one value per (channel, level, window); these kernels
// interpolate between window centres exactly as `interpolatedCurve` does.

struct WaveletAccumulateParameters {
    uint sampleCount;
    uint channelCount;
    uint levelCount;
    uint windowCount;
    uint edgeMarginStart;   // first sample allowed to produce artifact energy
    uint edgeMarginEnd;     // one past the last allowed sample
    float thresholdScale;
    uint softThreshold;     // 0 = hard, 1 = soft
};

/// Threshold value for one sample, linearly interpolated between window
/// centres and clamped outside them — mirrors `interpolatedCurve`.
static inline float interpolatedThreshold(
    device const float *thresholds,   // windowCount values for this (channel, level)
    device const uint *centers,
    uint windowCount,
    uint sample
) {
    if (windowCount == 0) { return 0.0f; }
    if (windowCount == 1) { return thresholds[0]; }
    if (sample <= centers[0]) { return thresholds[0]; }
    if (sample >= centers[windowCount - 1]) { return thresholds[windowCount - 1]; }

    uint segment = 0;
    while (segment < windowCount - 2 && sample > centers[segment + 1]) {
        segment += 1;
    }
    const uint left = centers[segment];
    const uint right = centers[segment + 1];
    const float span = float(right - left);
    if (span <= 0.0f) { return thresholds[segment]; }
    const float weight = float(sample - left) / span;
    return thresholds[segment] * (1.0f - weight) + thresholds[segment + 1] * weight;
}

static inline float shrink(float value, float threshold, uint soft) {
    if (fabs(value) < threshold) { return 0.0f; }
    if (soft == 0) { return value; }
    return value < 0.0f ? value + threshold : value - threshold;
}

/// One thread per (sample, channel): walks the levels, applies each level's
/// group-delay shift and threshold, and accumulates the summed artifact
/// magnitude plus which level dominated at that sample.
kernel void waveletThresholdAccumulate(
    device const float *details              [[buffer(0)]],  // level-major: level * channelCount * sampleCount
    device const float *thresholds           [[buffer(1)]],  // (level * channelCount + channel) * windowCount
    device const uint *centers               [[buffer(2)]],
    device const uint *levelDelays           [[buffer(3)]],
    device float *energySalience             [[buffer(4)]],
    device uchar *dominantLevels             [[buffer(5)]],
    constant WaveletAccumulateParameters &p  [[buffer(6)]],
    uint2 gid                                [[thread_position_in_grid]]
) {
    const uint sample = gid.x;
    const uint channel = gid.y;
    if (sample >= p.sampleCount || channel >= p.channelCount) {
        return;
    }

    const uint outIndex = channel * p.sampleCount + sample;
    const bool inMargin = sample >= p.edgeMarginStart && sample < p.edgeMarginEnd;

    float energy = 0.0f;
    float dominantMagnitude = 0.0f;
    uchar dominantLevel = 0;

    for (uint level = 0; level < p.levelCount; ++level) {
        const uint delay = levelDelays[level];
        // Shifted forward by the level's group delay, zero-filled at the head.
        float value = 0.0f;
        if (sample >= delay) {
            const uint levelBase = (level * p.channelCount + channel) * p.sampleCount;
            value = details[levelBase + (sample - delay)];
        }

        if (!inMargin) {
            continue;   // suppressed boundary: contributes no artifact energy
        }

        const uint tableBase = (level * p.channelCount + channel) * p.windowCount;
        const float threshold = interpolatedThreshold(thresholds + tableBase, centers, p.windowCount, sample)
            * p.thresholdScale;
        const float kept = shrink(value, threshold, p.softThreshold);
        const float magnitude = fabs(kept);
        energy += magnitude;
        if (magnitude > dominantMagnitude) {
            dominantMagnitude = magnitude;
            dominantLevel = uchar(level + 1);
        }
    }

    energySalience[outIndex] = energy;
    dominantLevels[outIndex] = dominantLevel;
}

struct WaveletLevelEnergyParameters {
    uint sampleCount;
    uint channelCount;
    uint levelCount;
    uint windowCount;
    uint edgeMarginStart;
    uint edgeMarginEnd;
    float thresholdScale;
    uint softThreshold;
};

// MARK: - Reduction (decompose → threshold → reconstruct on-device)
//
// The Wavelet Artifact Reducer's whole per-channel pipeline —
// decompose, threshold the detail bands, reconstruct the artifact from the
// kept coefficients plus the approximation — runs on-device. The host only
// pads/detrends the input, computes the robust (median/MAD) thresholds from
// a strided subsample of the resident bands, and reads back the final
// artifact plane. Each kernel mirrors its CPU counterpart in
// `WaveletTransform` exactly (same taps, same circular boundary, same order)
// so the two backends agree to float-vs-double precision.

struct WaveletDWTParameters {
    uint inputLength;    // band length at this level (even)
    uint channelCount;
    uint lowLength;
    uint highLength;
};

/// One decimated analysis step (`WaveletTransform.dwtStep`): one thread per
/// (output coefficient, channel). Input is channel-major with stride
/// `inputLength`; outputs are channel-major with stride `inputLength / 2`.
kernel void waveletDWTLevel(
    device const float *input           [[buffer(0)]],
    device float *approx                [[buffer(1)]],
    device float *detail                [[buffer(2)]],
    device const float *lowPass         [[buffer(3)]],
    device const float *highPass        [[buffer(4)]],
    constant WaveletDWTParameters &p    [[buffer(5)]],
    uint2 gid                           [[thread_position_in_grid]]
) {
    const uint halfLength = p.inputLength / 2;
    const uint i = gid.x;
    const uint channel = gid.y;
    if (i >= halfLength || channel >= p.channelCount) {
        return;
    }
    const uint base = channel * p.inputLength;

    float sumLow = 0.0f;
    for (uint k = 0; k < p.lowLength; ++k) {
        sumLow += lowPass[k] * input[base + (2 * i + k) % p.inputLength];
    }
    float sumHigh = 0.0f;
    for (uint k = 0; k < p.highLength; ++k) {
        sumHigh += highPass[k] * input[base + (2 * i + k) % p.inputLength];
    }
    approx[channel * halfLength + i] = sumLow;
    detail[channel * halfLength + i] = sumHigh;
}

struct WaveletIDWTParameters {
    uint outputLength;   // band length being reconstructed (even)
    uint channelCount;
    uint lowLength;
    uint highLength;
    int shift;           // bank.reconstructionShift (0 for orthonormal banks)
};

/// One decimated synthesis step (`WaveletTransform.idwtStep`), in gather form:
/// the CPU scatters `y[(2i + k + shift) % n] += recLow[k]·a[i]`, so each
/// output sample gathers the taps whose scatter index lands on it — for tap k
/// the source index `m = (j − shift − k) mod n` must be even, and then
/// `i = m / 2`. n is even, so the mod preserves parity and the evenness test
/// is exact. The high-pass branch uses the negated shift, as on the CPU.
kernel void waveletIDWTLevel(
    device const float *approx          [[buffer(0)]],   // outputLength / 2 per channel
    device const float *detail          [[buffer(1)]],
    device float *output                [[buffer(2)]],   // outputLength per channel
    device const float *recLow          [[buffer(3)]],
    device const float *recHigh         [[buffer(4)]],
    constant WaveletIDWTParameters &p   [[buffer(5)]],
    uint2 gid                           [[thread_position_in_grid]]
) {
    const uint n = p.outputLength;
    const uint halfLength = n / 2;
    const uint j = gid.x;
    const uint channel = gid.y;
    if (j >= n || channel >= p.channelCount) {
        return;
    }
    const uint coefBase = channel * halfLength;

    float sum = 0.0f;
    for (uint k = 0; k < p.lowLength; ++k) {
        int m = (int(j) - p.shift - int(k)) % int(n);
        if (m < 0) { m += int(n); }
        if ((m & 1) == 0) {
            sum += recLow[k] * approx[coefBase + uint(m) / 2];
        }
    }
    for (uint k = 0; k < p.highLength; ++k) {
        int m = (int(j) + p.shift - int(k)) % int(n);
        if (m < 0) { m += int(n); }
        if ((m & 1) == 0) {
            sum += recHigh[k] * detail[coefBase + uint(m) / 2];
        }
    }
    output[channel * n + j] = sum;
}

struct WaveletISWTParameters {
    uint sampleCount;
    uint channelCount;
    uint lowLength;
    uint highLength;
    uint dilation;
    int shift;           // bank.reconstructionShift * dilation, as on the CPU
};

/// One undecimated synthesis step (`WaveletTransform.iswtStep`), in gather
/// form: the CPU scatters `y[(i + k·dilation ± shift) % n] += 0.5·rec[k]·c[i]`,
/// so each output gathers `c[(j − k·dilation ∓ shift) mod n]` per tap.
kernel void waveletISWTLevel(
    device const float *approx          [[buffer(0)]],
    device const float *detail          [[buffer(1)]],
    device float *output                [[buffer(2)]],
    device const float *recLow          [[buffer(3)]],
    device const float *recHigh         [[buffer(4)]],
    constant WaveletISWTParameters &p   [[buffer(5)]],
    uint2 gid                           [[thread_position_in_grid]]
) {
    const uint n = p.sampleCount;
    const uint j = gid.x;
    const uint channel = gid.y;
    if (j >= n || channel >= p.channelCount) {
        return;
    }
    const uint base = channel * n;

    float sum = 0.0f;
    for (uint k = 0; k < p.lowLength; ++k) {
        int m = (int(j) - int(k * p.dilation) - p.shift) % int(n);
        if (m < 0) { m += int(n); }
        sum += 0.5f * recLow[k] * approx[base + uint(m)];
    }
    for (uint k = 0; k < p.highLength; ++k) {
        int m = (int(j) - int(k * p.dilation) + p.shift) % int(n);
        if (m < 0) { m += int(n); }
        sum += 0.5f * recHigh[k] * detail[base + uint(m)];
    }
    output[base + j] = sum;
}

struct WaveletShrinkParameters {
    uint bandLength;
    uint channelCount;
    uint windowCount;    // 1 = one global threshold per (channel, level)
    float thresholdScale;
    uint softThreshold;
};

/// Thresholds one detail band in place, keeping only the coefficients above
/// the (optionally windowed, linearly interpolated) gate — the kept values
/// are the artifact estimate that the inverse transform reconstructs.
kernel void waveletShrinkDetail(
    device float *detail                 [[buffer(0)]],
    device const float *thresholds       [[buffer(1)]],   // channel * windowCount + window
    device const uint *centers           [[buffer(2)]],
    constant WaveletShrinkParameters &p  [[buffer(3)]],
    uint2 gid                            [[thread_position_in_grid]]
) {
    const uint sample = gid.x;
    const uint channel = gid.y;
    if (sample >= p.bandLength || channel >= p.channelCount) {
        return;
    }
    const float threshold = interpolatedThreshold(
        thresholds + channel * p.windowCount, centers, p.windowCount, sample) * p.thresholdScale;
    const uint index = channel * p.bandLength + sample;
    detail[index] = shrink(detail[index], threshold, p.softThreshold);
}

/// Per-channel total and kept (artifact) energy for one band, computed
/// BEFORE `waveletShrinkDetail` mutates it — one thread per channel doing a
/// plain linear sweep, same pattern as `waveletLevelEnergy`. Feeds the
/// reducer's per-level removed-energy metric without reading the band back.
kernel void waveletReduceBandEnergy(
    device const float *detail            [[buffer(0)]],
    device const float *thresholds        [[buffer(1)]],
    device const uint *centers            [[buffer(2)]],
    device float *totalEnergy             [[buffer(3)]],   // one per channel
    device float *keptEnergy              [[buffer(4)]],
    constant WaveletShrinkParameters &p   [[buffer(5)]],
    uint gid                              [[thread_position_in_grid]]
) {
    const uint channel = gid;
    if (channel >= p.channelCount) {
        return;
    }
    const uint base = channel * p.bandLength;
    const uint tableBase = channel * p.windowCount;

    float total = 0.0f;
    float kept = 0.0f;
    for (uint sample = 0; sample < p.bandLength; ++sample) {
        const float value = detail[base + sample];
        total += value * value;
        const float threshold = interpolatedThreshold(
            thresholds + tableBase, centers, p.windowCount, sample) * p.thresholdScale;
        const float keptValue = shrink(value, threshold, p.softThreshold);
        kept += keptValue * keptValue;
    }
    totalEnergy[channel] = total;
    keptEnergy[channel] = kept;
}

/// One thread per (level, channel), summing that band's total and retained
/// energy. Only `levelCount * channelCount` threads, but each is a plain
/// linear sweep — cheap enough on-device to be worth not reading the bands
/// back for. Feeds the scan's summary percentages.
kernel void waveletLevelEnergy(
    device const float *details                [[buffer(0)]],
    device const float *thresholds             [[buffer(1)]],
    device const uint *centers                 [[buffer(2)]],
    device const uint *levelDelays             [[buffer(3)]],
    device float *totalEnergy                  [[buffer(4)]],   // level * channelCount + channel
    device float *artifactEnergy               [[buffer(5)]],
    constant WaveletLevelEnergyParameters &p   [[buffer(6)]],
    uint2 gid                                  [[thread_position_in_grid]]
) {
    const uint level = gid.x;
    const uint channel = gid.y;
    if (level >= p.levelCount || channel >= p.channelCount) {
        return;
    }

    const uint slot = level * p.channelCount + channel;
    const uint levelBase = slot * p.sampleCount;
    const uint tableBase = slot * p.windowCount;
    const uint delay = levelDelays[level];

    float total = 0.0f;
    float artifact = 0.0f;
    for (uint sample = 0; sample < p.sampleCount; ++sample) {
        float value = 0.0f;
        if (sample >= delay) {
            value = details[levelBase + (sample - delay)];
        }
        total += value * value;

        if (sample < p.edgeMarginStart || sample >= p.edgeMarginEnd) {
            continue;
        }
        const float threshold = interpolatedThreshold(thresholds + tableBase, centers, p.windowCount, sample)
            * p.thresholdScale;
        const float kept = shrink(value, threshold, p.softThreshold);
        artifact += kept * kept;
    }

    totalEnergy[slot] = total;
    artifactEnergy[slot] = artifact;
}
