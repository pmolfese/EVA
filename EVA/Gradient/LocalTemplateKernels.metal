//
//  LocalTemplateKernels.metal
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  GPU stages for EVA's clean-room local-template corrector (MAS/MAR/wAAS/wAAR),
//  ported from EVA/Gradient/LocalTemplateArtifactCorrector.swift. No third-party
//  artifact-correction source was consulted.
//
//  The shape of this port is different from the FASTR one, and deliberately so.
//  The CPU implementation materialises a template per (channel, event) and then
//  overlap-adds it. Doing that here would need either atomics — which break
//  run-to-run reproducibility — or a large intermediate buffer. Instead both
//  kernels are driven from the *output* side: one thread per (channel, sample)
//  walks the events covering that sample and recomputes their template value on
//  the spot. Coverage is one or two events in practice, the donor gather is a
//  handful of loads, and nothing is written twice. No atomics, no intermediate,
//  and the accumulation order is fixed by the cover table.
//
//  Every discrete decision — which events are corrected, which donors are
//  eligible, the correlation floor, the skip reasons — is made on the CPU and
//  arrives here as data. These kernels only reduce and accumulate.
//

#include <metal_stdlib>
using namespace metal;

/// Largest donor count a thread can reduce in registers. The CPU falls back
/// rather than dispatching past this.
constant constexpr int kLTMaxDonors = 32;

struct LTParams {
    uint channelCount;
    uint sampleCount;
    uint eventCount;
    uint reducer;           // 0 mean, 1 median, 2 exponentially weighted
    float timeConstant;     // reducer 2 only
    uint appliesScale;      // 0 when every scale is 1
};

/// Gathers this offset's donor values for one channel and reduces them.
///
/// Returns false when no donor covers the offset, which is the same condition
/// the CPU records as a nil template sample.
inline bool ltTemplateValue(
    device const float *channels,
    uint channelBase,
    int sampleCount,
    int offset,
    int targetCenter,
    device const int *eventCenters,
    device const int *eventStart,
    device const int *eventEnd,
    device const int *donorIndices,
    int donorFirst,
    int donorLast,
    uint reducer,
    float timeConstant,
    thread float &result
) {
    float values[kLTMaxDonors];
    float weights[kLTMaxDonors];
    int count = 0;

    for (int cursor = donorFirst; cursor < donorLast && count < kLTMaxDonors; ++cursor) {
        int donor = donorIndices[cursor];
        if (offset < eventStart[donor] || offset >= eventEnd[donor]) { continue; }
        int sample = eventCenters[donor] + offset;
        if (sample < 0 || sample >= sampleCount) { continue; }

        float weight = 1.0f;
        if (reducer == 2) {
            int separation = eventCenters[donor] - targetCenter;
            float distance = float(separation < 0 ? -separation : separation);
            weight = exp(-distance / timeConstant);
        }
        values[count] = channels[channelBase + uint(sample)];
        weights[count] = weight;
        count += 1;
    }
    if (count == 0) { return false; }

    if (reducer == 1) {
        // Insertion sort: `count` is the donor count, single digits in practice,
        // where this beats anything fancier and needs no scratch of its own.
        for (int i = 1; i < count; ++i) {
            float value = values[i];
            int slot = i - 1;
            while (slot >= 0 && values[slot] > value) {
                values[slot + 1] = values[slot];
                slot -= 1;
            }
            values[slot + 1] = value;
        }
        int middle = count / 2;
        result = (count % 2 == 0) ? (values[middle - 1] + values[middle]) * 0.5f
                                  : values[middle];
        return true;
    }

    if (reducer == 2) {
        float totalWeight = 0.0f;
        for (int i = 0; i < count; ++i) { totalWeight += weights[i]; }
        if (!(totalWeight > 0.0f) || !isfinite(totalWeight)) { return false; }
        float total = 0.0f;
        for (int i = 0; i < count; ++i) { total += values[i] * weights[i]; }
        result = total / totalWeight;
        return true;
    }

    float total = 0.0f;
    for (int i = 0; i < count; ++i) { total += values[i]; }
    result = total / float(count);
    return true;
}

/// Raised-cosine overlap-add weight for a position inside a window.
inline float ltTaper(int position, int length) {
    if (length <= 1) { return 1.0f; }
    float phase = float(position + 1) / float(length + 1) * M_PI_F;
    float value = sin(phase);
    return value * value;
}

/// Least-squares template scale per `(channel, event)`.
///
/// Only dispatched for the regression fits (MAR/wAAR). The template values are
/// recomputed here rather than cached from a previous pass: the gather is cheap,
/// and a cached `channel x event x sample` buffer is not.
kernel void ltLeastSquaresScales(
    device const float *channels      [[buffer(0)]],
    device const int   *eventCenters  [[buffer(1)]],
    device const int   *eventStart    [[buffer(2)]],
    device const int   *eventEnd      [[buffer(3)]],
    device const int   *donorOffsets  [[buffer(4)]],
    device const int   *donorIndices  [[buffer(5)]],
    device float       *scales        [[buffer(6)]],
    constant LTParams  &p             [[buffer(7)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= p.channelCount * p.eventCount) { return; }
    uint channel = gid / p.eventCount;
    uint event = gid % p.eventCount;

    int donorFirst = donorOffsets[event];
    int donorLast = donorOffsets[event + 1];
    if (donorLast <= donorFirst) { scales[gid] = 1.0f; return; }

    uint channelBase = channel * p.sampleCount;
    int sampleCount = int(p.sampleCount);
    int center = eventCenters[event];

    float numerator = 0.0f;
    float denominator = 0.0f;
    for (int offset = eventStart[event]; offset < eventEnd[event]; ++offset) {
        int sample = center + offset;
        if (sample < 0 || sample >= sampleCount) { continue; }
        float templateValue;
        if (!ltTemplateValue(channels, channelBase, sampleCount, offset, center,
                             eventCenters, eventStart, eventEnd, donorIndices,
                             donorFirst, donorLast, p.reducer, p.timeConstant,
                             templateValue)) {
            continue;
        }
        numerator += channels[channelBase + uint(sample)] * templateValue;
        denominator += templateValue * templateValue;
    }

    float scale = (isfinite(denominator) && denominator > 1e-12f) ? numerator / denominator : 0.0f;
    scales[gid] = isfinite(scale) ? scale : 0.0f;
}

/// Builds the artifact estimate and subtracts it, one thread per output sample.
///
/// Driven from the output side so overlapping events combine without atomics:
/// each thread owns one sample and walks the events covering it in the fixed
/// order the cover table gives, so repeated runs are bit-identical.
kernel void ltAccumulateAndSubtract(
    device const float *channels      [[buffer(0)]],
    device const int   *eventCenters  [[buffer(1)]],
    device const int   *eventStart    [[buffer(2)]],
    device const int   *eventEnd      [[buffer(3)]],
    device const int   *donorOffsets  [[buffer(4)]],
    device const int   *donorIndices  [[buffer(5)]],
    device const float *scales        [[buffer(6)]],
    device const int   *coverOffsets  [[buffer(7)]],
    device const int   *coverEvents   [[buffer(8)]],
    device float       *artifact      [[buffer(9)]],
    device float       *cleaned       [[buffer(10)]],
    constant LTParams  &p             [[buffer(11)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= p.channelCount * p.sampleCount) { return; }
    uint sample = gid % p.sampleCount;
    uint channel = gid / p.sampleCount;

    float input = channels[gid];
    int first = coverOffsets[sample];
    int last = coverOffsets[sample + 1];
    if (last <= first) {
        artifact[gid] = 0.0f;
        cleaned[gid] = input;
        return;
    }

    uint channelBase = channel * p.sampleCount;
    int sampleCount = int(p.sampleCount);
    float total = 0.0f;
    float totalWeight = 0.0f;

    for (int cursor = first; cursor < last; ++cursor) {
        int event = coverEvents[cursor];
        int center = eventCenters[event];
        int offset = int(sample) - center;
        int donorFirst = donorOffsets[event];
        int donorLast = donorOffsets[event + 1];
        if (donorLast <= donorFirst) { continue; }

        float templateValue;
        if (!ltTemplateValue(channels, channelBase, sampleCount, offset, center,
                             eventCenters, eventStart, eventEnd, donorIndices,
                             donorFirst, donorLast, p.reducer, p.timeConstant,
                             templateValue)) {
            continue;
        }

        int length = eventEnd[event] - eventStart[event];
        float weight = ltTaper(offset - eventStart[event], length);
        float scale = (p.appliesScale != 0) ? scales[channel * p.eventCount + uint(event)] : 1.0f;
        total += scale * templateValue * weight;
        totalWeight += weight;
    }

    if (totalWeight > 0.0f) {
        float value = total / totalWeight;
        artifact[gid] = value;
        cleaned[gid] = input - value;
    } else {
        artifact[gid] = 0.0f;
        cleaned[gid] = input;
    }
}
