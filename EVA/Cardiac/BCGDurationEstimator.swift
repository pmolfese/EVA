//
//  BCGDurationEstimator.swift
//  EVA
//
//  Estimates the temporal support of a repeating ballistocardiogram after a
//  detector has supplied candidate beat anchors. Detection answers "where are
//  the beats?"; this second stage answers "how much of each beat repeats?".
//

import Foundation

/// One recording-specific estimate of the common BCG interval, relative to the
/// detector's candidate anchors. PCA-S needs one common interval because it
/// pools every accepted beat into a single topography dictionary.
nonisolated struct BCGDurationEstimate: Sendable, Equatable {
    var startOffsetSeconds: Double
    var endOffsetSeconds: Double
    var contributingBeatCount: Int
    /// Conservative 0...1 summary of split-half repeatability, template
    /// contrast, and the number of contributing beats. This is a review aid,
    /// not a calibrated probability.
    var confidence: Double

    var durationSeconds: Double { max(endOffsetSeconds - startOffsetSeconds, 0) }
    var centerOffsetSeconds: Double { (startOffsetSeconds + endOffsetSeconds) / 2 }
}

nonisolated enum BCGDurationEstimator {
    /// A broad interval that contains the usual EEG BCG complex whether the
    /// supplied anchor is a detected BCG extremum or an imperfect QRS-locked
    /// proxy. The returned interval is normally much narrower.
    static let searchStartSeconds = -0.20
    static let searchEndSeconds = 0.80
    static let minimumBeatCount = 6

    /// Estimate the common BCG support from recurrence across detected beats.
    /// The inference low-passes the recurrence evidence but deliberately does
    /// not high-pass it. A zero-phase high-pass can create a long, perfectly
    /// repeatable pre/post ring around every sharp BCG lobe; that ring is useful
    /// for detection but would make the artifact's measured support circularly
    /// dependent on the chosen filter. PCA-S correction itself remains
    /// broadband.
    static func estimate(
        channels: [[Float]],
        samplingRate: Double,
        beatSeconds: [Double],
        lowPassHz: Double = 20
    ) async -> BCGDurationEstimate? {
        guard channels.count >= 2,
              beatSeconds.count >= minimumBeatCount,
              samplingRate > 0,
              lowPassHz > 0,
              lowPassHz < samplingRate / 2
        else { return nil }

        guard let filtered = try? await EEGSignalFilter.bandPass(
            channels: channels,
            samplingRate: samplingRate,
            lowCutoff: nil,
            highCutoff: lowPassHz,
            highPassFamily: .iir,
            lowPassFamily: .iir,
            iirDesign: .butterworth
        ) else { return nil }

        return estimateFiltered(
            channels: filtered,
            samplingRate: samplingRate,
            beatSeconds: beatSeconds
        )
    }

    /// Synchronous core kept internal so deterministic fixtures can exercise
    /// the duration inference independently of filter edge behavior.
    static func estimateFiltered(
        channels: [[Float]],
        samplingRate: Double,
        beatSeconds: [Double]
    ) -> BCGDurationEstimate? {
        guard channels.count >= 2,
              beatSeconds.count >= minimumBeatCount,
              samplingRate > 0,
              let sampleCount = channels.map(\.count).min(),
              sampleCount > 2
        else { return nil }

        let startOffset = Int((searchStartSeconds * samplingRate).rounded())
        let endOffset = Int((searchEndSeconds * samplingRate).rounded())
        let epochLength = endOffset - startOffset + 1
        guard epochLength > 4 else { return nil }

        var centers: [Int] = []
        centers.reserveCapacity(beatSeconds.count)
        for beat in beatSeconds.sorted() {
            let center = Int((beat * samplingRate).rounded())
            let start = center + startOffset
            guard start >= 0, start + epochLength <= sampleCount else { continue }
            centers.append(center)
        }
        guard centers.count >= minimumBeatCount else { return nil }

        let channelCount = channels.count
        var all = [[Double]](
            repeating: [Double](repeating: 0, count: epochLength), count: channelCount
        )
        var odd = all
        var even = all
        var oddCount = 0
        var evenCount = 0

        for (epochIndex, center) in centers.enumerated() {
            let start = center + startOffset
            let isEven = epochIndex.isMultiple(of: 2)
            if isEven { evenCount += 1 } else { oddCount += 1 }
            for channel in 0..<channelCount {
                for sample in 0..<epochLength {
                    let value = Double(channels[channel][start + sample])
                    all[channel][sample] += value
                    if isEven {
                        even[channel][sample] += value
                    } else {
                        odd[channel][sample] += value
                    }
                }
            }
        }
        guard oddCount >= 2, evenCount >= 2 else { return nil }

        scale(&all, by: 1 / Double(centers.count))
        scale(&odd, by: 1 / Double(oddCount))
        scale(&even, by: 1 / Double(evenCount))

        // Remove the instantaneous common reference before measuring spatial
        // energy or agreement. A common-mode excursion is not EEG topography.
        averageReference(&all)
        averageReference(&odd)
        averageReference(&even)

        let halfReliabilityWindow = max(1, Int((0.030 * samplingRate).rounded()))
        var energy = [Double](repeating: 0, count: epochLength)
        var reliability = [Double](repeating: 0, count: epochLength)
        for sample in 0..<epochLength {
            var sumSquares = 0.0
            for channel in 0..<channelCount {
                let value = all[channel][sample]
                sumSquares += value * value
            }
            energy[sample] = sqrt(sumSquares / Double(channelCount))

            let lower = max(0, sample - halfReliabilityWindow)
            let upper = min(epochLength, sample + halfReliabilityWindow + 1)
            var dot = 0.0, oddSquares = 0.0, evenSquares = 0.0
            for channel in 0..<channelCount {
                for local in lower..<upper {
                    let a = odd[channel][local]
                    let b = even[channel][local]
                    dot += a * b
                    oddSquares += a * a
                    evenSquares += b * b
                }
            }
            let denominator = sqrt(oddSquares * evenSquares)
            reliability[sample] = denominator > 1e-30
                ? max(min(dot / denominator, 1), -1)
                : 0
        }

        energy = smooth(energy, radius: max(1, Int((0.020 * samplingRate).rounded())))
        reliability = smooth(reliability, radius: max(1, Int((0.015 * samplingRate).rounded())))

        let sortedEnergy = energy.sorted()
        let floorIndex = min(max(Int(Double(sortedEnergy.count) * 0.20), 0), sortedEnergy.count - 1)
        let noiseFloor = sortedEnergy[floorIndex]
        guard let peakIndex = energy.indices.max(by: {
            evidence(energy: energy[$0], reliability: reliability[$0], floor: noiseFloor)
                < evidence(energy: energy[$1], reliability: reliability[$1], floor: noiseFloor)
        }) else { return nil }
        let peakEnergy = energy[peakIndex]
        let contrast = peakEnergy - noiseFloor
        guard contrast > max(peakEnergy * 0.08, 1e-9) else { return nil }

        // Eight percent of the repeatable template's peak retains the quieter
        // lobes of a multi-lobed BCG. Split-half agreement prevents unrelated
        // averaged EEG at that amplitude from extending the interval.
        let energyCutoff = noiseFloor + 0.08 * contrast
        let reliabilityCutoff = 0.25
        let active = energy.indices.map {
            energy[$0] >= energyCutoff && reliability[$0] >= reliabilityCutoff
        }
        guard active[peakIndex] else { return nil }

        // BCG crosses zero between lobes. Permit a short inactive gap while
        // walking away from the strongest evidence, but stop before the next
        // cardiac cycle or unrelated activity is absorbed into this one.
        let gapLimit = max(1, Int((0.070 * samplingRate).rounded()))
        let left = supportEdge(from: peakIndex, step: -1, active: active, gapLimit: gapLimit)
        let right = supportEdge(from: peakIndex, step: 1, active: active, gapLimit: gapLimit)
        let padding = max(1, Int((0.020 * samplingRate).rounded()))
        let paddedLeft = max(0, left - padding)
        let paddedRight = min(epochLength - 1, right + padding)
        let durationSamples = paddedRight - paddedLeft + 1
        guard durationSamples >= max(3, Int((0.080 * samplingRate).rounded())),
              durationSamples < epochLength else { return nil }

        let supportedReliability = reliability[paddedLeft...paddedRight]
            .map { max(0, $0) }
            .reduce(0, +) / Double(durationSamples)
        let beatEvidence = min(1, Double(centers.count) / 20)
        let contrastEvidence = min(1, contrast / max(peakEnergy, 1e-12))
        let confidence = max(0, min(1, supportedReliability * beatEvidence * contrastEvidence))
        guard confidence >= 0.12 else { return nil }

        return BCGDurationEstimate(
            startOffsetSeconds: searchStartSeconds + Double(paddedLeft) / samplingRate,
            endOffsetSeconds: searchStartSeconds + Double(paddedRight + 1) / samplingRate,
            contributingBeatCount: centers.count,
            confidence: confidence
        )
    }

    private static func scale(_ matrix: inout [[Double]], by factor: Double) {
        for channel in matrix.indices {
            for sample in matrix[channel].indices { matrix[channel][sample] *= factor }
        }
    }

    private static func averageReference(_ matrix: inout [[Double]]) {
        guard let sampleCount = matrix.first?.count, !matrix.isEmpty else { return }
        for sample in 0..<sampleCount {
            var mean = 0.0
            for channel in matrix.indices { mean += matrix[channel][sample] }
            mean /= Double(matrix.count)
            for channel in matrix.indices { matrix[channel][sample] -= mean }
        }
    }

    private static func smooth(_ values: [Double], radius: Int) -> [Double] {
        guard radius > 0, values.count > 2 else { return values }
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for index in values.indices { prefix[index + 1] = prefix[index] + values[index] }
        return values.indices.map { index in
            let lower = max(0, index - radius)
            let upper = min(values.count, index + radius + 1)
            return (prefix[upper] - prefix[lower]) / Double(upper - lower)
        }
    }

    private static func evidence(energy: Double, reliability: Double, floor: Double) -> Double {
        max(energy - floor, 0) * max(reliability, 0)
    }

    private static func supportEdge(
        from peak: Int,
        step: Int,
        active: [Bool],
        gapLimit: Int
    ) -> Int {
        var index = peak
        var lastActive = peak
        var gap = 0
        while true {
            index += step
            guard active.indices.contains(index) else { break }
            if active[index] {
                lastActive = index
                gap = 0
            } else {
                gap += 1
                if gap > gapLimit { break }
            }
        }
        return lastActive
    }
}
