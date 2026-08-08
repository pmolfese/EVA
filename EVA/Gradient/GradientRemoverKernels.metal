//
//  GradientRemoverKernels.metal
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

#include <metal_stdlib>
using namespace metal;

struct GradientRemoverParameters {
    uint trCount;
    uint spacing;
    uint fitRegression;
    uint reserved;
};

kernel void gradientMedianTemplates(
    device const float *segments [[buffer(0)]],
    device const uint *donorOffsets [[buffer(1)]],
    device const uint *donorIndices [[buffer(2)]],
    device float *templates [[buffer(3)]],
    constant GradientRemoverParameters &p [[buffer(4)]],
    uint gid [[thread_position_in_grid]]) {
    uint sampleCount = p.trCount * p.spacing;
    if (gid >= sampleCount) return;
    uint tr = gid / p.spacing;
    uint column = gid % p.spacing;
    uint first = donorOffsets[tr];
    uint last = donorOffsets[tr + 1];
    uint count = last - first;
    if (count == 0) {
        templates[gid] = 0.0f;
        return;
    }

    thread float values[128];
    for (uint i = 0; i < count; ++i) {
        float value = segments[donorIndices[first + i] * p.spacing + column];
        uint insertion = i;
        while (insertion > 0 && values[insertion - 1] > value) {
            values[insertion] = values[insertion - 1];
            --insertion;
        }
        values[insertion] = value;
    }
    uint mid = count / 2;
    templates[gid] = (count & 1) != 0
        ? values[mid]
        : 0.5f * (values[mid - 1] + values[mid]);
}

kernel void gradientRegressionCoefficients(
    device const float *segments [[buffer(0)]],
    device const float *templates [[buffer(1)]],
    device float *coefficients [[buffer(2)]],
    constant GradientRemoverParameters &p [[buffer(3)]],
    uint tr [[thread_position_in_grid]]) {
    if (tr >= p.trCount) return;
    if (p.fitRegression == 0) {
        coefficients[tr] = 1.0f;
        return;
    }
    uint base = tr * p.spacing;
    float numerator = 0.0f;
    float denominator = 0.0f;
    for (uint i = 0; i < p.spacing; ++i) {
        float y = segments[base + i];
        numerator += y * templates[base + i];
        denominator += y * y;
    }
    coefficients[tr] = denominator > 1.0e-12f ? numerator / denominator : 0.0f;
}

kernel void gradientApplyTemplates(
    device const float *segments [[buffer(0)]],
    device const float *templates [[buffer(1)]],
    device const float *coefficients [[buffer(2)]],
    device float *output [[buffer(3)]],
    constant GradientRemoverParameters &p [[buffer(4)]],
    uint gid [[thread_position_in_grid]]) {
    uint sampleCount = p.trCount * p.spacing;
    if (gid >= sampleCount) return;
    uint tr = gid / p.spacing;
    output[gid] = segments[gid] - coefficients[tr] * templates[gid];
}
