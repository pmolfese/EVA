#include <metal_stdlib>
using namespace metal;

struct RhythmicityMorletParameters {
    uint sampleCount;
    uint tapCount;
    uint cropOffset;
};

struct RhythmicityBatchedMorletParameters {
    uint sampleCount;
    uint tapCount;
    uint cropOffset;
    uint batchCount;
};

struct RhythmicityLAVIReductionParameters {
    uint sampleCount;
    uint validLower;
    uint validUpper;
    uint wholeLag;
    uint frequencyIndex;
    uint frequencyCount;
    float lagFraction;
};

struct RhythmicityLAVIReduction {
    float numeratorReal;
    float numeratorRealCompensation;
    float numeratorImaginary;
    float numeratorImaginaryCompensation;
    float firstEnergy;
    float firstEnergyCompensation;
    float secondEnergy;
    float secondEnergyCompensation;
    uint pairCount;
};

inline void rhythmicityCompensatedAdd(
    thread float &sum,
    thread float &compensation,
    float addition
) {
    const float corrected = addition - compensation;
    const float next = sum + corrected;
    compensation = (next - sum) - corrected;
    sum = next;
}

// One dispatch produces one bounded frequency tile. Keeping the kernel in a
// compiled .metal file makes Xcode shader diagnostics and GPU capture available,
// while the Swift side retains allocation, cancellation, and fallback policy.
kernel void rhythmicityMorletCoefficients(
    device const float *samples [[buffer(0)]],
    device const float *kernelReal [[buffer(1)]],
    device const float *kernelImaginary [[buffer(2)]],
    device float *outputReal [[buffer(3)]],
    device float *outputImaginary [[buffer(4)]],
    constant RhythmicityMorletParameters &p [[buffer(5)]],
    uint outputIndex [[thread_position_in_grid]]
) {
    if (outputIndex >= p.sampleCount) { return; }

    const uint fullIndex = outputIndex + p.cropOffset;
    const uint firstTap = fullIndex >= p.sampleCount
        ? fullIndex - (p.sampleCount - 1)
        : 0;
    const uint lastTap = min(p.tapCount - 1, fullIndex);
    float real = 0.0f;
    float imaginary = 0.0f;
    for (uint tap = firstTap; tap <= lastTap; ++tap) {
        const uint signalIndex = fullIndex - tap;
        const float sample = samples[signalIndex];
        real = fma(sample, kernelReal[tap], real);
        imaginary = fma(sample, kernelImaginary[tap], imaginary);
    }
    outputReal[outputIndex] = real;
    outputImaginary[outputIndex] = imaginary;
}

// Significance batches keep every surrogate in one input buffer. This kernel
// produces a frequency tile for the entire batch in one dispatch; the paired
// reduction kernel consumes it immediately on the GPU.
kernel void rhythmicityBatchedMorletCoefficients(
    device const float *samples [[buffer(0)]],
    device const float *kernelReal [[buffer(1)]],
    device const float *kernelImaginary [[buffer(2)]],
    device float *outputReal [[buffer(3)]],
    device float *outputImaginary [[buffer(4)]],
    constant RhythmicityBatchedMorletParameters &p [[buffer(5)]],
    uint flatIndex [[thread_position_in_grid]]
) {
    const uint valueCount = p.sampleCount * p.batchCount;
    if (flatIndex >= valueCount) { return; }

    const uint sampleIndex = flatIndex % p.sampleCount;
    const uint batchIndex = flatIndex / p.sampleCount;
    const uint fullIndex = sampleIndex + p.cropOffset;
    const uint firstTap = fullIndex >= p.sampleCount
        ? fullIndex - (p.sampleCount - 1)
        : 0;
    const uint lastTap = min(p.tapCount - 1, fullIndex);
    const uint inputBase = batchIndex * p.sampleCount;
    float real = 0.0f;
    float imaginary = 0.0f;
    for (uint tap = firstTap; tap <= lastTap; ++tap) {
        const float sample = samples[inputBase + fullIndex - tap];
        real = fma(sample, kernelReal[tap], real);
        imaginary = fma(sample, kernelImaginary[tap], imaginary);
    }
    outputReal[flatIndex] = real;
    outputImaginary[flatIndex] = imaginary;
}

// One thread reduces one surrogate/frequency tile. Multiple finite runs are
// encoded in order and accumulate into the same compact output record. Full
// coefficient tiles never cross back to the CPU.
kernel void rhythmicityAccumulateLAVI(
    device const float *coefficientReal [[buffer(0)]],
    device const float *coefficientImaginary [[buffer(1)]],
    device RhythmicityLAVIReduction *reductions [[buffer(2)]],
    constant RhythmicityLAVIReductionParameters &p [[buffer(3)]],
    uint batchIndex [[thread_position_in_grid]]
) {
    const uint upper = min(
        p.sampleCount - p.wholeLag - 1,
        p.validUpper - p.wholeLag - 1
    );
    if (p.validLower >= upper) { return; }

    const uint coefficientBase = batchIndex * p.sampleCount;
    const uint reductionIndex = batchIndex * p.frequencyCount + p.frequencyIndex;
    RhythmicityLAVIReduction reduction = reductions[reductionIndex];
    for (uint index = p.validLower; index < upper; ++index) {
        const uint firstIndex = coefficientBase + index;
        const float firstReal = coefficientReal[firstIndex];
        const float firstImaginary = coefficientImaginary[firstIndex];
        const float lowerReal = coefficientReal[firstIndex + p.wholeLag];
        const float lowerImaginary = coefficientImaginary[firstIndex + p.wholeLag];
        const float upperReal = coefficientReal[firstIndex + p.wholeLag + 1];
        const float upperImaginary = coefficientImaginary[firstIndex + p.wholeLag + 1];
        const float secondReal = mix(lowerReal, upperReal, p.lagFraction);
        const float secondImaginary = mix(lowerImaginary, upperImaginary, p.lagFraction);
        if (!isfinite(firstReal) || !isfinite(firstImaginary)
            || !isfinite(secondReal) || !isfinite(secondImaginary)) {
            continue;
        }
        rhythmicityCompensatedAdd(
            reduction.numeratorReal,
            reduction.numeratorRealCompensation,
            fma(firstReal, secondReal, firstImaginary * secondImaginary)
        );
        rhythmicityCompensatedAdd(
            reduction.numeratorImaginary,
            reduction.numeratorImaginaryCompensation,
            fma(firstImaginary, secondReal, -firstReal * secondImaginary)
        );
        rhythmicityCompensatedAdd(
            reduction.firstEnergy,
            reduction.firstEnergyCompensation,
            fma(firstReal, firstReal, firstImaginary * firstImaginary)
        );
        rhythmicityCompensatedAdd(
            reduction.secondEnergy,
            reduction.secondEnergyCompensation,
            fma(secondReal, secondReal, secondImaginary * secondImaginary)
        );
        reduction.pairCount += 1;
    }
    reductions[reductionIndex] = reduction;
}
