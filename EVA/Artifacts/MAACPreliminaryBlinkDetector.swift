//
//  MAACPreliminaryBlinkDetector.swift
//  EVA
//
//  Preliminary blink masking for MAAC-2. Dien (2024) describes this pass as
//  an upper-versus-lower VEOG divergence above 150 microvolts with rapid
//  onset and offset. The events are review markers and estimation masks; they
//  are not themselves a blink correction.
//

import Foundation

nonisolated struct MAACPreliminaryBlinkConfiguration: Codable, Sendable, Equatable {
    var amplitudeThresholdMicrovolts: Double = 150
    var slopeThresholdMicrovoltsPerMillisecond: Double = 0.5
    var slopeWindowSeconds: Double = 0.100
    var upperSymmetryToleranceMicrovolts: Double = 100
    var minimumMaskDurationSeconds: Double = 0.020
    var minimumPeakSeparationSeconds: Double = 0.100
    var smoothingSeconds: Double = 0.020
    var boundaryFraction: Double = 0.15

    static let `default` = MAACPreliminaryBlinkConfiguration()
}

nonisolated struct MAACPreliminaryBlinkResult: Sendable {
    var events: [MFFEvent]
    var candidateCount: Int
    var rejectedBySlopeCount: Int
    var rejectedBySymmetryCount: Int
    var maskSampleCount: Int
}

nonisolated enum MAACPreliminaryBlinkError: LocalizedError, Equatable {
    case invalidSignal
    case missingUpperVEOG
    case missingLowerVEOG

    var errorDescription: String? {
        switch self {
        case .invalidSignal:
            return "The recording has no rectangular sample grid for the MAAC blink scan."
        case .missingUpperVEOG:
            return "Choose at least one usable upper VEOG channel for the MAAC blink scan."
        case .missingLowerVEOG:
            return "Choose at least one usable lower VEOG channel for the MAAC blink scan."
        }
    }
}

nonisolated enum MAACPreliminaryBlinkDetector {
    static let sourceFile = "MAAC-2 Preliminary Blink Scan"

    private struct Candidate {
        var peak: Int
        var magnitude: Double
        var risingSlope: Double
        var fallingSlope: Double
    }

    static func detect(
        channels: [[Float]],
        samplingRate: Double,
        duration: TimeInterval,
        upperVEOGIndices: [Int],
        lowerVEOGIndices: [Int],
        excluding excluded: Set<Int> = [],
        configuration: MAACPreliminaryBlinkConfiguration = .default,
        progress: (@Sendable (CorneoRetinalAnalysisProgress) -> Void)? = nil
    ) throws -> MAACPreliminaryBlinkResult {
        guard samplingRate > 0,
              duration > 0,
              let sampleCount = channels.first?.count,
              sampleCount > 2,
              channels.allSatisfy({ $0.count == sampleCount }) else {
            throw MAACPreliminaryBlinkError.invalidSignal
        }
        let upper = valid(upperVEOGIndices, channelCount: channels.count, excluding: excluded)
        let lower = valid(lowerVEOGIndices, channelCount: channels.count, excluding: excluded)
        guard !upper.isEmpty else { throw MAACPreliminaryBlinkError.missingUpperVEOG }
        guard !lower.isEmpty else { throw MAACPreliminaryBlinkError.missingLowerVEOG }

        progress?(CorneoRetinalAnalysisProgress(
            fraction: 0.04,
            stage: "Building vertical EOG trace",
            detail: "Upper-minus-lower VEOG from \(upper.count + lower.count) channels",
            totalSampleCount: sampleCount
        ))

        let centeredUpper = upper.map { medianCentered(channels[$0]) }
        let centeredLower = lower.map { medianCentered(channels[$0]) }
        var trace = [Double](repeating: 0, count: sampleCount)
        for sample in 0..<sampleCount {
            trace[sample] = mean(centeredUpper.map { $0[sample] }) - mean(centeredLower.map { $0[sample] })
        }
        let smoothingSamples = max(Int((configuration.smoothingSeconds * samplingRate).rounded()), 1)
        if smoothingSamples > 1 {
            trace = movingAverage(trace, width: smoothingSamples)
        }
        progress?(CorneoRetinalAnalysisProgress(
            fraction: 0.14,
            stage: "Finding blink candidates",
            detail: String(format: "Scanning for > %.0f µV upper/lower divergence", configuration.amplitudeThresholdMicrovolts),
            totalSampleCount: sampleCount
        ))

        let threshold = max(configuration.amplitudeThresholdMicrovolts, 0)
        let slopeWindow = max(Int((configuration.slopeWindowSeconds * samplingRate).rounded()), 2)
        let boundary = threshold * min(max(configuration.boundaryFraction, 0.01), 0.95)
        let minimumDuration = max(Int((configuration.minimumMaskDurationSeconds * samplingRate).rounded()), 1)
        let separation = max(Int((configuration.minimumPeakSeparationSeconds * samplingRate).rounded()), 1)

        var thresholdRuns: [ClosedRange<Int>] = []
        var start: Int?
        for sample in trace.indices {
            if abs(trace[sample]) >= threshold {
                start = start ?? sample
            } else if let lowerBound = start {
                thresholdRuns.append(lowerBound...max(lowerBound, sample - 1))
                start = nil
            }
        }
        if let start { thresholdRuns.append(start...(sampleCount - 1)) }

        var candidates: [Candidate] = []
        var rejectedBySlope = 0
        var rejectedBySymmetry = 0
        for run in thresholdRuns {
            let peak = run.max { abs(trace[$0]) < abs(trace[$1]) } ?? run.lowerBound
            let sign = trace[peak] >= 0 ? 1.0 : -1.0
            let riseStart = max(0, peak - slopeWindow)
            let fallEnd = min(sampleCount - 1, peak + slopeWindow)
            let rising = sign * slope(trace, range: riseStart...peak, samplingRate: samplingRate)
            let falling = sign * slope(trace, range: peak...fallEnd, samplingRate: samplingRate)
            guard rising >= configuration.slopeThresholdMicrovoltsPerMillisecond,
                  falling <= -configuration.slopeThresholdMicrovoltsPerMillisecond else {
                rejectedBySlope += 1
                continue
            }
            if centeredUpper.count > 1 {
                let values = centeredUpper.map { $0[peak] }
                if (values.max() ?? 0) - (values.min() ?? 0) > configuration.upperSymmetryToleranceMicrovolts {
                    rejectedBySymmetry += 1
                    continue
                }
            }
            candidates.append(Candidate(
                peak: peak,
                magnitude: abs(trace[peak]),
                risingSlope: rising,
                fallingSlope: falling
            ))
        }

        // Closely spaced threshold fragments represent one lid movement. Keep
        // the stronger peak, matching the EP Toolkit's 100 ms separation rule.
        var separated: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.peak < $1.peak }) {
            if let last = separated.last, candidate.peak - last.peak < separation {
                if candidate.magnitude > last.magnitude { separated[separated.count - 1] = candidate }
            } else {
                separated.append(candidate)
            }
        }

        var masks: [(candidate: Candidate, range: ClosedRange<Int>)] = []
        for candidate in separated {
            let signedBoundary = boundary
            var lowerBound = candidate.peak
            while lowerBound > 0, abs(trace[lowerBound - 1]) > signedBoundary { lowerBound -= 1 }
            var upperBound = candidate.peak
            while upperBound + 1 < sampleCount, abs(trace[upperBound + 1]) > signedBoundary { upperBound += 1 }
            if upperBound - lowerBound + 1 < minimumDuration {
                let missing = minimumDuration - (upperBound - lowerBound + 1)
                lowerBound = max(0, lowerBound - missing / 2)
                upperBound = min(sampleCount - 1, lowerBound + minimumDuration - 1)
                lowerBound = max(0, upperBound - minimumDuration + 1)
            }
            if let previous = masks.last, lowerBound <= previous.range.upperBound + 1 {
                let stronger = candidate.magnitude > previous.candidate.magnitude ? candidate : previous.candidate
                masks[masks.count - 1] = (stronger, previous.range.lowerBound...max(previous.range.upperBound, upperBound))
            } else {
                masks.append((candidate, lowerBound...upperBound))
            }
        }

        let events = masks.enumerated().map { index, item in
            let onset = Double(item.range.lowerBound) / samplingRate
            let eventDuration = Double(item.range.count) / samplingRate
            let description = String(
                format: "MAAC preliminary blink: peak %.1f µV; rise %.2f µV/ms; fall %.2f µV/ms.",
                item.candidate.magnitude, item.candidate.risingSlope, item.candidate.fallingSlope
            )
            return MFFEvent(
                id: "maac-2-blink-\(index)-\(item.range.lowerBound)-\(item.range.upperBound)",
                code: EyeArtifactKind.blink.eventCode,
                label: "MAAC preliminary blink",
                eventDescription: description,
                beginTimeSeconds: min(max(onset, 0), duration),
                rawBeginTime: String(format: "%.6f", onset),
                sourceFile: sourceFile,
                durationSeconds: eventDuration,
                timeAnchor: .onset
            )
        }
        let maskedSamples = masks.reduce(0) { $0 + $1.range.count }
        progress?(CorneoRetinalAnalysisProgress(
            fraction: 0.30,
            stage: "Preliminary blink scan complete",
            detail: "Accepted \(events.count) of \(thresholdRuns.count) threshold candidates",
            blinkCandidateCount: thresholdRuns.count,
            acceptedBlinkCount: events.count,
            blinkSampleCount: maskedSamples,
            totalSampleCount: sampleCount
        ))
        return MAACPreliminaryBlinkResult(
            events: events,
            candidateCount: thresholdRuns.count,
            rejectedBySlopeCount: rejectedBySlope,
            rejectedBySymmetryCount: rejectedBySymmetry,
            maskSampleCount: maskedSamples
        )
    }

    private static func valid(_ indices: [Int], channelCount: Int, excluding: Set<Int>) -> [Int] {
        Array(Set(indices.filter { (0..<channelCount).contains($0) && !excluding.contains($0) })).sorted()
    }

    private static func medianCentered(_ values: [Float]) -> [Double] {
        let finite = values.lazy.map(Double.init).filter(\.isFinite).sorted()
        guard !finite.isEmpty else { return values.map { _ in 0 } }
        let midpoint = finite.count / 2
        let median = finite.count.isMultiple(of: 2)
            ? (finite[midpoint - 1] + finite[midpoint]) / 2
            : finite[midpoint]
        return values.map { value in
            let value = Double(value)
            return value.isFinite ? value - median : 0
        }
    }

    private static func movingAverage(_ values: [Double], width: Int) -> [Double] {
        guard width > 1 else { return values }
        let left = (width - 1) / 2
        let right = width / 2
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for index in values.indices { prefix[index + 1] = prefix[index] + values[index] }
        return values.indices.map { index in
            let start = max(0, index - left)
            let end = min(values.count, index + right + 1)
            return (prefix[end] - prefix[start]) / Double(end - start)
        }
    }

    private static func slope(_ values: [Double], range: ClosedRange<Int>, samplingRate: Double) -> Double {
        guard range.count > 1 else { return 0 }
        let count = Double(range.count)
        let meanX = Double(range.count - 1) / 2
        let meanY = range.reduce(0.0) { $0 + values[$1] } / count
        var numerator = 0.0
        var denominator = 0.0
        for (offset, sample) in range.enumerated() {
            let x = Double(offset) - meanX
            numerator += x * (values[sample] - meanY)
            denominator += x * x
        }
        guard denominator > 0 else { return 0 }
        return (numerator / denominator) * samplingRate / 1_000
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}
