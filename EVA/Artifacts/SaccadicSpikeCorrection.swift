//
//  SaccadicSpikeCorrection.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  MAAC-1 saccadic-spike-potential detection and spatial filtering. The functional
//  specification comes from Dien (2024), section 1.8: Cz-reference, first
//  differences, a VEOG-dominant preliminary scan, biphasic confirmation at 4/8 ms,
//  a 100 ms refractory interval, and a canonical scalp-map spatial filter.
//
//  Dien, J. (2024). Multi-Algorithm Artifact Correction (MAAC) procedure part one:
//  Algorithm and example. Biological Psychology, 188, 108775.
//  https://doi.org/10.1016/j.biopsycho.2024.108775
//
//  Canonical ocular-template lineage: Semlitsch, H. V., Anderer, P., Schuster, P.,
//  & Presslich, O. (1986). Psychophysiology, 23(6), 695–703.
//  https://doi.org/10.1111/j.1469-8986.1986.tb00696.x
//

import Foundation

private final class SaccadicSpikeResourceBundleMarker: NSObject {}

nonisolated enum SaccadicSpikeTemplateSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case canonical = "Canonical (recommended)"
    case sessionAverage = "Session average"

    var id: String { rawValue }
}

nonisolated struct SaccadicSpikeConfiguration: Codable, Sendable, Equatable {
    static let defaultWindowSeconds = 0.024
    static let defaultRefractorySeconds = 0.100

    var templateSource: SaccadicSpikeTemplateSource = .canonical
    /// Robust-sigma multiplier used by both derivative-domain gates. Larger is
    /// more conservative. A data-relative threshold stays usable across sample
    /// rates and amplifier noise floors while preserving the paper's negative
    /// VEOG / critical-amplitude tests.
    var sensitivitySigma: Double = 5.0
    var maximumDerivativeMicrovolts: Float = 100
    var refractorySeconds: Double = Self.defaultRefractorySeconds
    var windowSeconds: Double = Self.defaultWindowSeconds

    static let `default` = SaccadicSpikeConfiguration()
}

nonisolated struct SaccadicSpikeChannelSelection: Sendable, Equatable {
    var czIndex: Int
    var verticalEOGIndices: [Int]
    var lowerVerticalEOGIndices: [Int]
    var horizontalEOGIndices: [Int]
    var analysisIndices: [Int]

    func validated(channelCount: Int) throws -> SaccadicSpikeChannelSelection {
        guard channelCount > 1 else { throw SaccadicSpikeError.insufficientChannels }
        guard (0..<channelCount).contains(czIndex) else { throw SaccadicSpikeError.missingCz }

        func uniqueValid(_ values: [Int]) -> [Int] {
            Array(Set(values.filter { (0..<channelCount).contains($0) })).sorted()
        }

        let vertical = uniqueValid(verticalEOGIndices)
        let lower = uniqueValid(lowerVerticalEOGIndices).filter(vertical.contains)
        let horizontal = uniqueValid(horizontalEOGIndices)
        let analysis = uniqueValid(analysisIndices).filter { !horizontal.contains($0) }
        guard vertical.count >= 2 else { throw SaccadicSpikeError.missingVerticalEOG }
        guard !lower.isEmpty else { throw SaccadicSpikeError.missingLowerVerticalEOG }
        guard analysis.count >= 2, analysis.contains(czIndex) else {
            throw SaccadicSpikeError.insufficientAnalysisChannels
        }
        return SaccadicSpikeChannelSelection(
            czIndex: czIndex,
            verticalEOGIndices: vertical,
            lowerVerticalEOGIndices: lower,
            horizontalEOGIndices: horizontal,
            analysisIndices: analysis
        )
    }
}

nonisolated enum SaccadicSpikeError: LocalizedError, Equatable {
    case invalidSignal
    case insufficientChannels
    case missingCz
    case missingVerticalEOG
    case missingLowerVerticalEOG
    case insufficientAnalysisChannels
    case missingCanonicalTemplate
    case noPreliminaryCandidates
    case invalidTemplate

    var errorDescription: String? {
        switch self {
        case .invalidSignal:
            return "The recording has no rectangular, finite EEG sample grid to scan."
        case .insufficientChannels:
            return "Saccadic-spike correction needs at least two EEG channels."
        case .missingCz:
            return "Choose the Cz channel used by the reference-independent detector."
        case .missingVerticalEOG:
            return "Choose at least two vertical periocular (VEOG) channels."
        case .missingLowerVerticalEOG:
            return "Choose at least one lower VEOG channel for template scaling."
        case .insufficientAnalysisChannels:
            return "Choose at least two non-HEOG analysis channels, including Cz."
        case .missingCanonicalTemplate:
            return "The bundled canonical saccadic-spike template could not be mapped to this montage."
        case .noPreliminaryCandidates:
            return "No VEOG-dominant derivative spikes passed the preliminary detector."
        case .invalidTemplate:
            return "The saccadic-spike scalp template is degenerate for the selected channels."
        }
    }
}

nonisolated struct SaccadicSpikeDetectionResult: Sendable {
    var events: [MFFEvent]
    var topography: ArtifactTemplateTopography
    var preliminaryCandidateCount: Int
    var criticalThresholdMicrovolts: Float
    var amplitudeAtEvents: [Float]
}

nonisolated enum SaccadicSpikeChannelResolver {
    static func automatic(
        signal: MFFSignalData,
        layout: SensorLayout?,
        excluding excluded: Set<Int> = []
    ) throws -> SaccadicSpikeChannelSelection {
        let channelCount = signal.numberOfChannels
        guard channelCount > 1 else { throw SaccadicSpikeError.insufficientChannels }
        let names = signal.channelNames ?? []

        let cz = names.indices.first(where: { canonicalName(names[$0]) == "CZ" })
            ?? layout?.positions
                .filter { (0..<channelCount).contains($0.channelIndex) && !excluded.contains($0.channelIndex) }
                .min(by: { hypot($0.x, $0.y) < hypot($1.x, $1.y) })?.channelIndex
        guard let cz else { throw SaccadicSpikeError.missingCz }

        var vertical = namedIndices(
            names,
            matching: { $0.contains("VEOG") || $0.contains("VEO") || $0.contains("EOGV") }
        )
        var horizontal = namedIndices(
            names,
            matching: { $0.contains("HEOG") || $0.contains("HEO") || $0.contains("EOGH") }
        )
        if vertical.count < 2 {
            vertical = EyeArtifactThresholdDetector.autoOcularChannelIndices(
                kind: .blink,
                channelCount: channelCount,
                sensorLayoutName: layout?.name
            )
        }
        if horizontal.count < 2 {
            horizontal = EyeArtifactThresholdDetector.autoOcularChannelIndices(
                kind: .movement,
                channelCount: channelCount,
                sensorLayoutName: layout?.name
            )
        }

        vertical = Array(Set(vertical.filter { !excluded.contains($0) })).sorted()
        horizontal = Array(Set(horizontal.filter { !excluded.contains($0) })).sorted()
        let lower: [Int]
        if let layout {
            let byIndex = Dictionary(uniqueKeysWithValues: layout.positions.map { ($0.channelIndex, $0) })
            // +y is anterior in SensorLayout. The most anterior periocular
            // electrodes are the lower VEOG pair on the supported EGI nets.
            lower = vertical
                .compactMap { index in byIndex[index].map { (index, $0.y) } }
                .sorted { $0.1 > $1.1 }
                .prefix(max(1, min(2, vertical.count / 2)))
                .map(\.0)
        } else {
            lower = Array(vertical.suffix(max(1, min(2, vertical.count / 2))))
        }

        let analysis = (0..<channelCount).filter { !excluded.contains($0) && !horizontal.contains($0) }
        return try SaccadicSpikeChannelSelection(
            czIndex: cz,
            verticalEOGIndices: vertical,
            lowerVerticalEOGIndices: lower,
            horizontalEOGIndices: horizontal,
            analysisIndices: analysis
        ).validated(channelCount: channelCount)
    }

    private static func namedIndices(_ names: [String], matching predicate: (String) -> Bool) -> [Int] {
        names.indices.filter { predicate(canonicalName(names[$0])) }
    }

    private static func canonicalName(_ name: String) -> String {
        name.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}

nonisolated enum SaccadicSpikeCanonicalTemplate {
    private struct FilePayload: Decodable {
        var anchors: [Anchor]
    }

    private struct Anchor: Decodable {
        var label: String
        var thetaDegrees: Double
        var radius: Double
        var value: Float
    }

    static func mappedValues(
        signal: MFFSignalData,
        layout: SensorLayout?
    ) throws -> [Float] {
        let payload = try loadPayload()
        guard !payload.anchors.isEmpty else { throw SaccadicSpikeError.missingCanonicalTemplate }
        let names = signal.channelNames ?? []
        let exact = Dictionary(uniqueKeysWithValues: payload.anchors.map {
            (canonicalName($0.label), $0.value)
        })
        let maximumRadius = payload.anchors.map(\.radius).max() ?? 1
        let anchors = payload.anchors.map { anchor -> (x: Double, y: Double, value: Float) in
            let radians = anchor.thetaDegrees * .pi / 180
            return (
                x: sin(radians) * anchor.radius / maximumRadius,
                y: cos(radians) * anchor.radius / maximumRadius,
                value: anchor.value
            )
        }
        let positions = Dictionary(uniqueKeysWithValues: (layout?.positions ?? []).map {
            ($0.channelIndex, $0)
        })

        var mapped = [Float](repeating: .nan, count: signal.numberOfChannels)
        var resolved = 0
        for channel in mapped.indices {
            if names.indices.contains(channel), let value = exact[canonicalName(names[channel])] {
                mapped[channel] = value
                resolved += 1
                continue
            }
            guard let position = positions[channel] else { continue }
            var weighted: Double = 0
            var weightSum: Double = 0
            for anchor in anchors {
                let distance = hypot(position.x - anchor.x, position.y - anchor.y)
                if distance < 1e-5 {
                    weighted = Double(anchor.value)
                    weightSum = 1
                    break
                }
                let weight = 1 / pow(max(distance, 0.025), 3)
                weighted += Double(anchor.value) * weight
                weightSum += weight
            }
            if weightSum > 0 {
                mapped[channel] = Float(weighted / weightSum)
                resolved += 1
            }
        }
        guard resolved >= 2 else { throw SaccadicSpikeError.missingCanonicalTemplate }
        return mapped
    }

    private static func loadPayload() throws -> FilePayload {
        let bundles = [Bundle.main, Bundle(for: SaccadicSpikeResourceBundleMarker.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: "saccadic-spike-canonical", withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let payload = try? JSONDecoder().decode(FilePayload.self, from: data) {
                return payload
            }
            if let url = bundle.url(
                forResource: "saccadic-spike-canonical",
                withExtension: "json",
                subdirectory: "Artifacts/Resources"
            ), let data = try? Data(contentsOf: url),
               let payload = try? JSONDecoder().decode(FilePayload.self, from: data) {
                return payload
            }
        }
        throw SaccadicSpikeError.missingCanonicalTemplate
    }

    private static func canonicalName(_ name: String) -> String {
        name.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}

nonisolated enum SaccadicSpikeDetector {
    static let sourceFile = "MAAC Saccadic Spike Detection"
    static let eventCode = "SACC-SP"

    static func detect(
        in signal: MFFSignalData,
        selection rawSelection: SaccadicSpikeChannelSelection,
        configuration: SaccadicSpikeConfiguration = .default,
        canonicalTopography: [Float]? = nil
    ) throws -> SaccadicSpikeDetectionResult {
        guard signal.samplingRate > 0,
              signal.numberOfChannels == signal.data.count,
              let sampleCount = signal.data.first?.count,
              sampleCount > 3,
              signal.data.allSatisfy({ $0.count == sampleCount }) else {
            throw SaccadicSpikeError.invalidSignal
        }
        let selection = try rawSelection.validated(channelCount: signal.numberOfChannels)
        let cz = signal.data[selection.czIndex]
        @inline(__always) func derivativeValue(channel: Int, sample: Int) -> Float {
            let channelDelta = signal.data[channel][sample + 1] - signal.data[channel][sample]
            let czDelta = cz[sample + 1] - cz[sample]
            return channelDelta - czDelta
        }
        let sigmaMultiplier = max(configuration.sensitivitySigma, 1)
        let verticalThresholds = Dictionary(uniqueKeysWithValues: selection.verticalEOGIndices.map { index in
            var values = [Float]()
            values.reserveCapacity(sampleCount - 1)
            for sample in 0..<(sampleCount - 1) {
                values.append(derivativeValue(channel: index, sample: sample))
            }
            return (index, max(Float(sigmaMultiplier) * robustSigma(values), 1e-4))
        })
        let eightMS = max(Int((0.008 * signal.samplingRate).rounded()), 1)
        let maximum = max(configuration.maximumDerivativeMicrovolts, 1)
        var preliminary: [Int] = []
        preliminary.reserveCapacity(max(sampleCount / 2_000, 16))
        var lastPreliminary = -eightMS

        let comparison = selection.analysisIndices.filter {
            !selection.verticalEOGIndices.contains($0) && $0 != selection.czIndex
        }
        let capChannels = Array(Set(selection.analysisIndices + selection.horizontalEOGIndices)).sorted()
        for sample in 0..<(sampleCount - eightMS) {
            if Task.isCancelled { break }
            var verticalMean: Float = 0
            var passes = true
            for index in selection.verticalEOGIndices {
                let value = derivativeValue(channel: index, sample: sample)
                let threshold = verticalThresholds[index] ?? 0
                if !value.isFinite || value > -threshold || abs(value) > maximum
                    || abs(derivativeValue(channel: index, sample: sample + eightMS)) > threshold {
                    passes = false
                    break
                }
                verticalMean += value
            }
            guard passes else { continue }
            verticalMean /= Float(selection.verticalEOGIndices.count)

            // The paper's preliminary gate rejects a candidate when any
            // available channel exceeds roughly 100 µV in the derivative map.
            for index in capChannels {
                let value = derivativeValue(channel: index, sample: sample)
                guard value.isFinite, abs(value) <= maximum else {
                    passes = false
                    break
                }
            }
            guard passes else { continue }

            var restMean: Float = 0
            var restCount: Float = 0
            for index in comparison {
                let value = derivativeValue(channel: index, sample: sample)
                guard value.isFinite, abs(value) <= maximum else {
                    passes = false
                    break
                }
                restMean += value
                restCount += 1
            }
            guard passes, restCount > 0, verticalMean < restMean / restCount else { continue }

            // One derivative edge can remain below threshold for adjacent
            // samples. Keep only its first sample for the template/detector.
            if sample - lastPreliminary >= max(eightMS / 2, 1) {
                preliminary.append(sample)
                lastPreliminary = sample
            }
        }
        guard !preliminary.isEmpty else { throw SaccadicSpikeError.noPreliminaryCandidates }

        let topographyValues: [Float]
        switch configuration.templateSource {
        case .canonical:
            guard let canonicalTopography, canonicalTopography.count == signal.numberOfChannels else {
                throw SaccadicSpikeError.missingCanonicalTemplate
            }
            topographyValues = try normalizedTemplate(
                canonicalTopography,
                selection: selection
            )
        case .sessionAverage:
            var average = [Float](repeating: 0, count: signal.numberOfChannels)
            for sample in preliminary {
                for channel in average.indices {
                    average[channel] += derivativeValue(channel: channel, sample: sample)
                }
            }
            let divisor = Float(preliminary.count)
            for channel in average.indices { average[channel] /= divisor }
            topographyValues = try normalizedTemplate(average, selection: selection)
        }

        let usable = selection.analysisIndices.filter {
            topographyValues.indices.contains($0) && topographyValues[$0].isFinite
        }
        var norm: Float = 0
        for index in usable { norm += topographyValues[index] * topographyValues[index] }
        guard norm > 1e-8 else { throw SaccadicSpikeError.invalidTemplate }

        func amplitude(at sample: Int) -> Float {
            var dot: Float = 0
            for index in usable {
                let value = derivativeValue(channel: index, sample: sample)
                if value.isFinite { dot += topographyValues[index] * value }
            }
            return dot / norm
        }

        // Estimate the robust background scale from the full recording without
        // allocating a second full-length trace. A deterministic stride caps the
        // median calculation while retaining all preliminary candidates below.
        let stride = max(sampleCount / 100_000, 1)
        var amplitudeSample: [Float] = []
        amplitudeSample.reserveCapacity(min(sampleCount / stride, 100_001))
        var sample = 0
        while sample < sampleCount - 1 {
            amplitudeSample.append(amplitude(at: sample))
            sample += stride
        }
        let critical = max(Float(sigmaMultiplier) * robustSigma(amplitudeSample), 1e-4)
        let offsets = [0.004, 0.008].map { max(Int(($0 * signal.samplingRate).rounded()), 1) }
        let refractorySamples = max(Int((configuration.refractorySeconds * signal.samplingRate).rounded()), 1)
        let windowSamples = max(Int((configuration.windowSeconds * signal.samplingRate).rounded()), 3)
        var accepted: [(sample: Int, amplitude: Float)] = []
        var lastAccepted = -refractorySamples

        for candidate in preliminary where candidate - lastAccepted >= refractorySamples {
            let first = amplitude(at: candidate)
            guard first >= critical else { continue }
            let isBiphasic = offsets.contains { offset in
                candidate + offset < sampleCount && amplitude(at: candidate + offset) <= -2 * critical
            }
            guard isBiphasic else { continue }
            accepted.append((candidate, first))
            lastAccepted = candidate
        }

        let events = accepted.enumerated().map { index, item in
            let time = Double(item.sample) / signal.samplingRate
            return MFFEvent(
                id: "maac-sp-\(index)-\(item.sample)",
                code: eventCode,
                label: "Saccadic Spike Potential",
                beginTimeSeconds: time,
                rawBeginTime: String(format: "%.6f", time),
                sourceFile: sourceFile,
                durationSeconds: Double(windowSamples) / signal.samplingRate,
                timeAnchor: .peak
            )
        }
        let referenceSample = events.first.map { Int(($0.beginTimeSeconds * signal.samplingRate).rounded()) } ?? 0
        let topography = ArtifactTemplateTopography(
            mode: .peak,
            referenceSample: referenceSample,
            referenceTimeSeconds: events.first?.beginTimeSeconds ?? 0,
            channelValues: topographyValues,
            channelIndices: usable,
            matchThreshold: Double(critical),
            matchCount: events.count
        )
        return SaccadicSpikeDetectionResult(
            events: events,
            topography: topography,
            preliminaryCandidateCount: preliminary.count,
            criticalThresholdMicrovolts: critical,
            amplitudeAtEvents: accepted.map(\.amplitude)
        )
    }

    static func czReferencedDerivative(_ channels: [[Float]], czIndex: Int) -> [[Float]] {
        guard channels.indices.contains(czIndex), let sampleCount = channels.first?.count, sampleCount > 1 else {
            return []
        }
        var result = Array(repeating: [Float](repeating: 0, count: sampleCount), count: channels.count)
        let cz = channels[czIndex]
        for channel in channels.indices where channels[channel].count == sampleCount {
            for sample in 0..<(sampleCount - 1) {
                let channelDelta = channels[channel][sample + 1] - channels[channel][sample]
                let czDelta = cz[sample + 1] - cz[sample]
                result[channel][sample] = channelDelta - czDelta
            }
        }
        return result
    }

    static func normalizedTemplate(
        _ values: [Float],
        selection: SaccadicSpikeChannelSelection
    ) throws -> [Float] {
        guard values.indices.contains(selection.czIndex), !selection.lowerVerticalEOGIndices.isEmpty else {
            throw SaccadicSpikeError.invalidTemplate
        }
        var output = values
        let cz = output[selection.czIndex]
        for index in output.indices { output[index] -= cz }
        let lowerValues = selection.lowerVerticalEOGIndices.compactMap {
            output.indices.contains($0) && output[$0].isFinite ? output[$0] : nil
        }
        guard !lowerValues.isEmpty else { throw SaccadicSpikeError.invalidTemplate }
        let lowerMean = lowerValues.reduce(0, +) / Float(lowerValues.count)
        let scale = abs(lowerMean)
        guard scale.isFinite, scale > 1e-6 else { throw SaccadicSpikeError.invalidTemplate }
        // Orient the published morphology consistently: lower VEOG negative
        // relative to Cz, parietal positive.
        let orientation: Float = lowerMean > 0 ? -1 : 1
        for index in output.indices { output[index] = orientation * output[index] / scale }
        return output
    }

    static func robustSigma(_ values: [Float]) -> Float {
        var finite = values.filter(\.isFinite)
        guard !finite.isEmpty else { return 0 }
        finite.sort()
        let median = finite[finite.count / 2]
        var deviations = finite.map { abs($0 - median) }
        deviations.sort()
        return deviations[deviations.count / 2] * 1.4826
    }
}

nonisolated enum SaccadicSpikeSpatialFilter {
    /// Removes the one-dimensional canonical scalp pattern only inside the
    /// detected SP windows. For every sample, `a = dot(w, x) / dot(w, w)` is
    /// the least-squares amplitude of the saved spatial map and `w * a` is the
    /// contribution subtracted from each channel. A line through the two window
    /// edges is removed before fitting so channel baselines cannot masquerade as
    /// the short transient.
    static func apply(
        artifact: DefinedArtifact,
        data: inout [[Float]],
        samplingRate: Double,
        excluding excluded: Set<Int> = [],
        eventProgress: ((Int) -> Void)? = nil
    ) -> Int {
        guard samplingRate > 0,
              let sampleCount = data.first?.count,
              sampleCount > 2,
              data.allSatisfy({ $0.count == sampleCount }),
              let topography = artifact.topography,
              topography.channelValues.count == data.count else { return 0 }

        let channels = topography.channelIndices.filter {
            data.indices.contains($0) && !excluded.contains($0) && topography.channelValues[$0].isFinite
        }
        guard channels.count >= 2 else { return 0 }
        var norm: Float = 0
        for channel in channels {
            let weight = topography.channelValues[channel]
            norm += weight * weight
        }
        guard norm > 1e-8 else { return 0 }

        let windowSamples = max(Int((artifact.windowSizeSeconds * samplingRate).rounded()), 3)
        for (eventIndex, event) in artifact.events.enumerated() {
            let center = Int((event.centerTimeSeconds * samplingRate).rounded())
            let start = center - windowSamples / 2
            let end = start + windowSamples
            guard start >= 0, end <= sampleCount else {
                eventProgress?(eventIndex + 1)
                continue
            }

            let denominator = Float(max(windowSamples - 1, 1))
            for offset in 0..<windowSamples {
                let fraction = Float(offset) / denominator
                var amplitude: Float = 0
                for channel in channels {
                    let first = data[channel][start]
                    let last = data[channel][end - 1]
                    let baseline = first + (last - first) * fraction
                    amplitude += topography.channelValues[channel] * (data[channel][start + offset] - baseline)
                }
                amplitude /= norm
                guard amplitude.isFinite else { continue }
                for channel in channels {
                    data[channel][start + offset] -= topography.channelValues[channel] * amplitude
                }
            }
            eventProgress?(eventIndex + 1)
        }
        return channels.count
    }
}
