//
//  FastrKernels.metal
//  EVA
//
//  SPDX-License-Identifier: GPL-3.0-only
//

#include <metal_stdlib>
using namespace metal;

struct FastrResampleParameters {
    uint inputCount;
    uint outputCount;
    uint factor;
    uint tapCount;
    float mean;
};

struct FastrBatchResampleParameters {
    uint inputCount;
    uint outputCount;
    uint factor;
    uint tapCount;
    uint channelCount;
};

struct FastrTemplateParameters {
    uint sampleCount;
    uint epochCount;
    uint artifactLength;
    uint fixedAlpha;
};

struct FastrBatchTemplateParameters {
    uint sampleCount;
    uint epochCount;
    uint artifactLength;
    uint prePeak;
    uint channelCount;
    uint epochOffset;
};

struct FastrOBSParameters {
    uint sampleCount;
    uint epochCount;
    uint artifactLength;
    uint basisCount;
};

kernel void fastrInterpolate(
    device const float *input [[buffer(0)]],
    device const float *taps [[buffer(1)]],
    device float *output [[buffer(2)]],
    constant FastrResampleParameters &p [[buffer(3)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= p.outputCount) return;
    int delay = int((p.tapCount - 1) / 2);
    int first = max(0, (int(gid) + delay - int(p.tapCount - 1) + int(p.factor - 1)) / int(p.factor));
    int last = min(int(p.inputCount) - 1, (int(gid) + delay) / int(p.factor));
    float value = 0.0f;
    for (int i = first; i <= last; ++i) {
        int tap = delay + int(gid) - i * int(p.factor);
        if (tap >= 0 && tap < int(p.tapCount)) value += (input[i] - p.mean) * taps[tap];
    }
    output[gid] = value;
}

kernel void fastrInterpolateChannels(
    device const float *input [[buffer(0)]],
    device const float *taps [[buffer(1)]],
    device const float *means [[buffer(2)]],
    device float *output [[buffer(3)]],
    constant FastrBatchResampleParameters &p [[buffer(4)]],
    uint gid [[thread_position_in_grid]]) {
    uint totalCount = p.channelCount * p.outputCount;
    if (gid >= totalCount) return;
    uint channel = gid / p.outputCount;
    uint localOutput = gid % p.outputCount;
    uint inputBase = channel * p.inputCount;
    int delay = int((p.tapCount - 1) / 2);
    int first = max(0, (int(localOutput) + delay - int(p.tapCount - 1) + int(p.factor - 1)) / int(p.factor));
    int last = min(int(p.inputCount) - 1, (int(localOutput) + delay) / int(p.factor));
    float value = 0.0f;
    for (int i = first; i <= last; ++i) {
        int tap = delay + int(localOutput) - i * int(p.factor);
        if (tap >= 0 && tap < int(p.tapCount)) {
            value += (input[inputBase + uint(i)] - means[channel]) * taps[tap];
        }
    }
    output[gid] = value;
}

kernel void fastrTemplateAlpha(
    device const float *data [[buffer(0)]],
    device const float *templates [[buffer(1)]],
    device const int *starts [[buffer(2)]],
    device const uint *valid [[buffer(3)]],
    device float *alpha [[buffer(4)]],
    constant FastrTemplateParameters &p [[buffer(5)]],
    uint epoch [[thread_position_in_grid]]) {
    if (epoch >= p.epochCount || valid[epoch] == 0) {
        if (epoch < p.epochCount) alpha[epoch] = 0.0f;
        return;
    }
    if (p.fixedAlpha != 0) {
        alpha[epoch] = 1.0f;
        return;
    }
    int start = starts[epoch];
    uint base = epoch * p.artifactLength;
    float numerator = 0.0f;
    float denominator = 0.0f;
    for (uint i = 0; i < p.artifactLength; ++i) {
        float t = templates[base + i];
        numerator += data[start + int(i)] * t;
        denominator += t * t;
    }
    alpha[epoch] = denominator == 0.0f ? 0.0f : numerator / denominator;
}

kernel void fastrTemplateNoise(
    device const float *templates [[buffer(0)]],
    device const int *starts [[buffer(1)]],
    device const int *owner [[buffer(2)]],
    device const float *alpha [[buffer(3)]],
    device float *noise [[buffer(4)]],
    constant FastrTemplateParameters &p [[buffer(5)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= p.sampleCount) return;
    int epoch = owner[gid];
    if (epoch < 0) {
        noise[gid] = 0.0f;
        return;
    }
    uint offset = gid - uint(starts[epoch]);
    noise[gid] = alpha[epoch] * templates[uint(epoch) * p.artifactLength + offset];
}

kernel void fastrAverageTemplateNoiseChannels(
    device const float *data [[buffer(0)]],
    device const int *markers [[buffer(1)]],
    device const int *targetStarts [[buffer(2)]],
    device const uint *donorOffsets [[buffer(3)]],
    device const uint *donorIndices [[buffer(4)]],
    device const int *owner [[buffer(5)]],
    device const uint *fixedAlpha [[buffer(6)]],
    device float *noise [[buffer(7)]],
    constant FastrBatchTemplateParameters &p [[buffer(8)]],
    threadgroup float *scratch [[threadgroup(0)]],
    uint3 group [[threadgroup_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]],
    uint3 threadsPerGroup [[threads_per_threadgroup]]) {
    uint threads = threadsPerGroup.x;
    uint epoch = group.x + p.epochOffset;
    uint channel = group.y;
    if (epoch >= p.epochCount || channel >= p.channelCount) return;

    uint donorBegin = donorOffsets[epoch];
    uint donorEnd = donorOffsets[epoch + 1];
    int targetStart = targetStarts[epoch];
    if (donorBegin >= donorEnd || targetStart < 0
        || targetStart + int(p.artifactLength) > int(p.sampleCount)) return;

    threadgroup float *templateValues = scratch;
    threadgroup float *numerators = templateValues + p.artifactLength;
    threadgroup float *denominators = numerators + threads;
    uint channelBase = channel * p.sampleCount;
    float donorScale = 1.0f / float(donorEnd - donorBegin);

    for (uint sample = tid; sample < p.artifactLength; sample += threads) {
        float sum = 0.0f;
        for (uint donor = donorBegin; donor < donorEnd; ++donor) {
            int sourceStart = markers[donorIndices[donor]] - int(p.prePeak);
            sum += data[channelBase + uint(sourceStart) + sample];
        }
        templateValues[sample] = sum * donorScale;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float numerator = 0.0f;
    float denominator = 0.0f;
    if (fixedAlpha[channel] == 0) {
        for (uint sample = tid; sample < p.artifactLength; sample += threads) {
            float value = templateValues[sample];
            numerator += data[channelBase + uint(targetStart) + sample] * value;
            denominator += value * value;
        }
    }
    numerators[tid] = numerator;
    denominators[tid] = denominator;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint width = threads / 2; width > 0; width /= 2) {
        if (tid < width) {
            numerators[tid] += numerators[tid + width];
            denominators[tid] += denominators[tid + width];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    float alpha = fixedAlpha[channel] != 0
        ? 1.0f
        : (denominators[0] == 0.0f ? 0.0f : numerators[0] / denominators[0]);
    for (uint sample = tid; sample < p.artifactLength; sample += threads) {
        uint output = uint(targetStart) + sample;
        if (owner[output] == int(epoch)) {
            noise[channelBase + output] = alpha * templateValues[sample];
        }
    }
}

kernel void fastrCorrectDecimate(
    device const float *original [[buffer(0)]],
    device const float *templateNoise [[buffer(1)]],
    device const float *residualNoise [[buffer(2)]],
    device const float *taps [[buffer(3)]],
    device float *clean [[buffer(4)]],
    device float *noiseOut [[buffer(5)]],
    constant FastrResampleParameters &p [[buffer(6)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= p.outputCount) return;
    int center = int(gid * p.factor);
    int delay = int((p.tapCount - 1) / 2);
    float cleanValue = 0.0f;
    float noiseValue = 0.0f;
    for (uint tap = 0; tap < p.tapCount; ++tap) {
        int source = center + int(tap) - delay;
        if (source < 0 || source >= int(p.inputCount)) continue;
        float totalNoise = templateNoise[source] + residualNoise[source];
        float coefficient = taps[tap];
        cleanValue += (original[source] - totalNoise) * coefficient;
        noiseValue += totalNoise * coefficient;
    }
    clean[gid] = cleanValue;
    noiseOut[gid] = noiseValue;
}

kernel void fastrCorrectDecimateChannels(
    device const float *original [[buffer(0)]],
    device const float *templateNoise [[buffer(1)]],
    device const float *residualNoise [[buffer(2)]],
    device const float *taps [[buffer(3)]],
    device float *clean [[buffer(4)]],
    device float *noiseOut [[buffer(5)]],
    constant FastrBatchResampleParameters &p [[buffer(6)]],
    uint gid [[thread_position_in_grid]]) {
    uint totalCount = p.channelCount * p.outputCount;
    if (gid >= totalCount) return;
    uint channel = gid / p.outputCount;
    uint localOutput = gid % p.outputCount;
    uint inputBase = channel * p.inputCount;
    int center = int(localOutput * p.factor);
    int delay = int((p.tapCount - 1) / 2);
    float cleanValue = 0.0f;
    float noiseValue = 0.0f;
    for (uint tap = 0; tap < p.tapCount; ++tap) {
        int source = center + int(tap) - delay;
        if (source < 0 || source >= int(p.inputCount)) continue;
        uint index = inputBase + uint(source);
        float totalNoise = templateNoise[index] + residualNoise[index];
        float coefficient = taps[tap];
        cleanValue += (original[index] - totalNoise) * coefficient;
        noiseValue += totalNoise * coefficient;
    }
    clean[gid] = cleanValue;
    noiseOut[gid] = noiseValue;
}

kernel void fastrOBSCoefficients(
    device const float *data [[buffer(0)]],
    device const int *starts [[buffer(1)]],
    device const float *dual [[buffer(2)]],
    device float *coefficients [[buffer(3)]],
    constant FastrOBSParameters &p [[buffer(4)]],
    uint gid [[thread_position_in_grid]]) {
    uint count = p.epochCount * p.basisCount;
    if (gid >= count) return;
    uint epoch = gid / p.basisCount;
    uint basis = gid % p.basisCount;
    int start = starts[epoch];
    if (start < 0) {
        coefficients[gid] = 0.0f;
        return;
    }
    float value = 0.0f;
    uint dualBase = basis * p.artifactLength;
    for (uint sample = 0; sample < p.artifactLength; ++sample) {
        value += dual[dualBase + sample] * data[start + int(sample)];
    }
    coefficients[gid] = value;
}

kernel void fastrOBSFits(
    device const int *starts [[buffer(0)]],
    device const float *columns [[buffer(1)]],
    device const float *coefficients [[buffer(2)]],
    device float *fits [[buffer(3)]],
    constant FastrOBSParameters &p [[buffer(4)]],
    uint gid [[thread_position_in_grid]]) {
    uint count = p.epochCount * p.artifactLength;
    if (gid >= count) return;
    uint epoch = gid / p.artifactLength;
    uint sample = gid % p.artifactLength;
    if (starts[epoch] < 0) {
        fits[gid] = 0.0f;
        return;
    }
    float value = 0.0f;
    uint coefficientBase = epoch * p.basisCount;
    for (uint basis = 0; basis < p.basisCount; ++basis) {
        value += columns[basis * p.artifactLength + sample]
            * coefficients[coefficientBase + basis];
    }
    fits[gid] = value;
}
