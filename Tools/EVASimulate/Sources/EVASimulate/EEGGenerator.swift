//
//  EEGGenerator.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The ground-truth EEG: Grouiller et al.'s forward model, which is explicitly
//  *not* biophysical. It reproduces the first-order spatio-temporal statistics
//  of ongoing EEG — a 1/f-ish spectrum, a modulated alpha rhythm, smooth spatial
//  correlation — and claims nothing more. That is enough for its purpose, which
//  is to be a known signal that correction algorithms can be measured against.
//
//  The paper's own discussion names the model's main limitation: real neural
//  signals are strongly non-stationary and these are not, which they suspect is
//  why ICA looked far better in their simulations than on real recordings. Read
//  any ICA result out of this harness with that in mind.
//

import Foundation

nonisolated struct GeneratedEEG: Sendable {
    /// channels x samples, in µV.
    var channels: [[Double]]
    /// The eyes-open/eyes-closed alpha envelope, in µV, one value per sample.
    /// Written to the truth sidecar so an alpha-power analysis can be correlated
    /// against the block design the way the paper's Figure 6 does.
    var alphaEnvelope: [Double]
    /// Standard deviation of the generated EEG, pooled over channels. The
    /// denominator of every SNR this harness reports.
    var standardDeviation: Double
}

nonisolated enum EEGGenerator {

    static func generate(
        config: SimulationConfig,
        montage: Montage,
        source: inout GaussianSource
    ) -> GeneratedEEG {
        let sampleCount = config.sampleCount
        let alphaEnvelope = alphaEnvelope(config: config)

        // Each channel is its own mixture of the seven band-limited sources.
        // They are made spatially correlated afterwards rather than by sharing
        // sources, which is what the paper's smoothing kernel does.
        var channels = [[Double]](
            repeating: [Double](repeating: 0, count: sampleCount),
            count: config.channelCount
        )

        for channel in 0..<config.channelCount {
            var mixture = [Double](repeating: 0, count: sampleCount)
            for band in config.eegBands {
                var component = SpectralNoise.bandLimited(
                    sampleCount: sampleCount,
                    samplingRate: config.samplingRate,
                    lowHz: band.lowHz,
                    highHz: band.highHz,
                    source: &source
                )
                if band.isAlpha {
                    for i in 0..<sampleCount { component[i] *= alphaEnvelope[i] }
                } else {
                    let amplitude = band.amplitudeMicrovolts ?? 0
                    for i in 0..<sampleCount { component[i] *= amplitude }
                }
                for i in 0..<sampleCount { mixture[i] += component[i] }
            }
            channels[channel] = mixture
        }

        switch config.spatialModel {
        case .circular:
            applyCircularSpatialSmoothing(&channels, sigmaChannels: config.spatialSmoothingChannels)
        case .geometric:
            applyGeometricSpatialSmoothing(
                &channels,
                positions: montage.positions,
                sigmaChannels: config.spatialSmoothingChannels
            )
        }

        // One global scale, not one per channel: per-channel normalization would
        // flatten the spatial structure the smoothing just created.
        let std = pooledStandardDeviation(channels)
        if std > 1e-12 {
            let scale = config.eegTargetStdMicrovolts / std
            for c in channels.indices {
                for i in channels[c].indices { channels[c][i] *= scale }
            }
        }

        return GeneratedEEG(
            channels: channels,
            alphaEnvelope: alphaEnvelope,
            standardDeviation: pooledStandardDeviation(channels)
        )
    }

    /// Paper: the subject opens and closes their eyes every 20 s, modelled by
    /// sine-modulating the alpha source's amplitude between 10 µV (open) and
    /// 30 µV (closed).
    static func alphaEnvelope(config: SimulationConfig) -> [Double] {
        let mid = (config.alphaHighMicrovolts + config.alphaLowMicrovolts) / 2
        let half = (config.alphaHighMicrovolts - config.alphaLowMicrovolts) / 2
        let omega = 2 * Double.pi / max(config.alphaCycleSeconds, 1e-9)
        return (0..<config.sampleCount).map { index in
            mid + half * sin(omega * Double(index) / config.samplingRate)
        }
    }

    /// Paper: "we assumed a circular connectivity between EEG channels and
    /// applied a smoothing convolution kernel at each time bin. This kernel was
    /// a Gaussian function with a standard deviation equal to 4 channels."
    ///
    /// Circular means channel 0 neighbours channel N-1, which is not any real
    /// montage — the paper is explicit that it is deliberately not assuming a
    /// specific neuronal or electrode configuration, only *some* smooth spatial
    /// correlation. Methods that exploit topography (EVA's topography-gated OBS
    /// strategies, say) are therefore being handed an unrealistic spatial
    /// structure, and should be evaluated on real data as well.
    static func applyCircularSpatialSmoothing(_ channels: inout [[Double]], sigmaChannels: Double) {
        let count = channels.count
        guard count > 1, sigmaChannels > 0 else { return }
        let sampleCount = channels[0].count

        let radius = min(count / 2, max(1, Int((3 * sigmaChannels).rounded())))
        var kernel = [Double]()
        for d in -radius...radius {
            let x = Double(d) / sigmaChannels
            kernel.append(exp(-0.5 * x * x))
        }
        let kernelSum = kernel.reduce(0, +)
        for i in kernel.indices { kernel[i] /= kernelSum }

        var smoothed = [[Double]](
            repeating: [Double](repeating: 0, count: sampleCount),
            count: count
        )
        for c in 0..<count {
            for (offsetIndex, weight) in kernel.enumerated() {
                let d = offsetIndex - radius
                let neighbour = ((c + d) % count + count) % count
                let source = channels[neighbour]
                for i in 0..<sampleCount {
                    smoothed[c][i] += weight * source[i]
                }
            }
        }
        channels = smoothed
    }

    /// Distance-based smoothing on the actual montage.
    ///
    /// The kernel width is quoted in "channels" like the paper's, and converted
    /// to an angle by asking how far apart neighbouring electrodes actually are
    /// — so `--spatial-smoothing 4` means roughly the same amount of smoothing
    /// under either model rather than silently meaning something new.
    static func applyGeometricSpatialSmoothing(
        _ channels: inout [[Double]],
        positions: [(x: Double, y: Double, z: Double)],
        sigmaChannels: Double
    ) {
        let count = channels.count
        guard count > 1, sigmaChannels > 0, positions.count >= count else { return }
        let sampleCount = channels[0].count

        func angle(_ a: Int, _ b: Int) -> Double {
            let dot = positions[a].x * positions[b].x
                + positions[a].y * positions[b].y
                + positions[a].z * positions[b].z
            return acos(max(-1, min(1, dot)))
        }

        // Median nearest-neighbour separation, as the "one channel" unit.
        var separations: [Double] = []
        for a in 0..<count {
            var nearest = Double.greatestFiniteMagnitude
            for b in 0..<count where b != a { nearest = min(nearest, angle(a, b)) }
            if nearest.isFinite { separations.append(nearest) }
        }
        guard !separations.isEmpty else { return }
        separations.sort()
        let sigma = separations[separations.count / 2] * sigmaChannels

        var smoothed = [[Double]](
            repeating: [Double](repeating: 0, count: sampleCount),
            count: count
        )
        for a in 0..<count {
            var weights = [Double](repeating: 0, count: count)
            var total = 0.0
            for b in 0..<count {
                let z = angle(a, b) / sigma
                weights[b] = exp(-0.5 * z * z)
                total += weights[b]
            }
            guard total > 0 else { continue }
            for b in 0..<count {
                let weight = weights[b] / total
                guard weight > 1e-6 else { continue }
                let source = channels[b]
                for i in 0..<sampleCount { smoothed[a][i] += weight * source[i] }
            }
        }
        channels = smoothed
    }

    static func pooledStandardDeviation(_ channels: [[Double]]) -> Double {
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0
        for channel in channels {
            for value in channel {
                sum += value
                sumSquares += value * value
                count += 1
            }
        }
        guard count > 1 else { return 0 }
        let mean = sum / Double(count)
        let variance = max(0, sumSquares / Double(count) - mean * mean)
        return variance.squareRoot()
    }
}
