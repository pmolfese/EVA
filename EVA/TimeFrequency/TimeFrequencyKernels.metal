#include <metal_stdlib>
using namespace metal;

struct TFMorletParameters {
    uint channelCount;
    uint trialCount;
    uint sampleCount;
    uint frequencyCount;
    uint maximumKernelLength;
};

// One thread produces the trial-averaged power and phase coherence for one
// (channel, frequency, time) coordinate.  The index calculation is the same
// central crop as ComplexMorlet.convolveSame / numpy.convolve(..., 'same').
kernel void tfMorletBatch(
    device const float *samples [[buffer(0)]],
    device const float *kernelRe [[buffer(1)]],
    device const float *kernelIm [[buffer(2)]],
    device const uint *kernelLengths [[buffer(3)]],
    device float *meanPower [[buffer(4)]],
    device float *itpc [[buffer(5)]],
    constant TFMorletParameters &p [[buffer(6)]],
    uint3 gid [[thread_position_in_grid]]
) {
    const uint time = gid.x, frequency = gid.y, channel = gid.z;
    if (time >= p.sampleCount || frequency >= p.frequencyCount || channel >= p.channelCount) { return; }
    const uint length = kernelLengths[frequency];
    const int offset = int((length - 1) / 2);
    const uint kernelBase = frequency * p.maximumKernelLength;
    float power = 0.0f, phaseRe = 0.0f, phaseIm = 0.0f;
    for (uint trial = 0; trial < p.trialCount; ++trial) {
        float real = 0.0f, imaginary = 0.0f;
        const uint trialBase = (channel * p.trialCount + trial) * p.sampleCount;
        for (uint j = 0; j < length; ++j) {
            const int sample = int(time) + offset - int(j);
            if (sample >= 0 && sample < int(p.sampleCount)) {
                const float value = samples[trialBase + uint(sample)];
                real += value * kernelRe[kernelBase + j];
                imaginary += value * kernelIm[kernelBase + j];
            }
        }
        const float magnitudeSquared = real * real + imaginary * imaginary;
        power += magnitudeSquared;
        const float magnitude = sqrt(magnitudeSquared);
        if (magnitude > 0.0f) { phaseRe += real / magnitude; phaseIm += imaginary / magnitude; }
    }
    const uint output = (channel * p.frequencyCount + frequency) * p.sampleCount + time;
    meanPower[output] = power / float(p.trialCount);
    itpc[output] = sqrt(phaseRe * phaseRe + phaseIm * phaseIm) / float(p.trialCount);
}
