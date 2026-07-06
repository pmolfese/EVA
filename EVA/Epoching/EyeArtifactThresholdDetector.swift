//
//  EyeArtifactThresholdDetector.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Threshold-based ocular (eye-blink / eye-movement) artifact detector, an L3
//  algorithm. Distinct from ECG/QRS (`RWaveDetector`): the two share no logic, so
//  they live in separate files by domain rather than behind a common supertype.
//  Configured by `EyeArtifactThresholdConfiguration`.
//

import Foundation

nonisolated enum EyeArtifactKind {
    case blink
    case movement

    var eventCode: String {
        switch self {
        case .blink: return "Eye Blink"
        case .movement: return "Eye Movement"
        }
    }

    var idComponent: String {
        switch self {
        case .blink: return "eye-blink"
        case .movement: return "eye-movement"
        }
    }
}

nonisolated enum EyeArtifactThresholdDetector {
    /// Source tag stamped on detected events; also marks them as "centered"
    /// (flag at the peak, window symmetric) for the waveform highlight.
    static let sourceFile = "Artifact Detection"

    static func detect(
        kind: EyeArtifactKind,
        channels: [[Float]],
        samplingRate: Double,
        duration: TimeInterval,
        configuration: EyeArtifactThresholdConfiguration? = nil
    ) -> [MFFEvent] {
        guard samplingRate > 0, duration > 0, let sampleCount = channels.first?.count, sampleCount > 0 else {
            return []
        }

        let config = configuration ?? .defaults(for: kind)
        let candidateChannels = resolvedChannels(kind: kind, channels: channels, configuration: config)
        guard !candidateChannels.isEmpty else { return [] }

        let amplitudeMin = max(config.amplitudeMinMicrovolts, 0)
        let amplitudeMax = config.amplitudeMaxMicrovolts   // 0 == no cap
        let minimumSamples = max(Int((config.minDurationSeconds * samplingRate).rounded()), 1)
        let maximumSamples = config.maxDurationSeconds > 0
            ? max(Int((config.maxDurationSeconds * samplingRate).rounded()), minimumSamples)
            : Int.max
        let mergeGapSamples = max(Int((config.mergeGapSeconds * samplingRate).rounded()), 1)
        let riseSamples = config.riseWindowSeconds > 0
            ? max(Int((config.riseWindowSeconds * samplingRate).rounded()), 1)
            : Int.max

        // Per-sample "driving" value = the candidate channel whose signed value
        // is largest in magnitude at that sample. Velocity/acceleration and the
        // peak all read from this single trace so the metrics stay consistent.
        var drive = [Float](repeating: 0, count: sampleCount)
        for sample in 0..<sampleCount {
            var best: Float = 0
            for channelIndex in candidateChannels {
                let value = channels[channelIndex][sample]
                if abs(value) > abs(best) { best = value }
            }
            drive[sample] = best
        }

        func crosses(_ value: Float) -> Bool {
            switch config.polarity {
            case .positive: return value >= amplitudeMin
            case .negative: return value <= -amplitudeMin
            case .bipolar:  return abs(value) >= amplitudeMin
            }
        }

        // Raw threshold-crossing runs.
        var runs: [ClosedRange<Int>] = []
        var activeStart: Int?
        var lastAbove: Int?
        for sample in 0..<sampleCount {
            if crosses(drive[sample]) {
                if activeStart == nil { activeStart = sample }
                lastAbove = sample
            } else if let start = activeStart, let end = lastAbove {
                runs.append(start...end)
                activeStart = nil
                lastAbove = nil
            }
        }
        if let start = activeStart, let end = lastAbove { runs.append(start...end) }

        let samplesPerMs = Float(samplingRate / 1000.0)

        var intervals: [ClosedRange<Int>] = []
        for run in runs {
            let length = run.upperBound - run.lowerBound + 1
            guard length >= minimumSamples, length <= maximumSamples else { continue }

            // Peak = most extreme driving sample in the run.
            var peakSample = run.lowerBound
            var peakMagnitude: Float = 0
            for sample in run where abs(drive[sample]) > peakMagnitude {
                peakMagnitude = abs(drive[sample]); peakSample = sample
            }

            if amplitudeMax > 0, peakMagnitude > amplitudeMax { continue }
            // Baseline→peak must complete within the rise window.
            if peakSample - run.lowerBound > riseSamples { continue }

            if config.velocityEnabled || config.accelerationEnabled {
                let (velocity, acceleration) = kinematics(in: run, drive: drive, samplesPerMs: samplesPerMs)
                if config.velocityEnabled,
                   velocity < config.velocityThresholdMicrovoltsPerMillisecond { continue }
                if config.accelerationEnabled,
                   acceleration < config.accelerationThresholdMicrovoltsPerMillisecondSquared { continue }
            }

            if let last = intervals.last, run.lowerBound - last.upperBound <= mergeGapSamples {
                intervals[intervals.count - 1] = last.lowerBound...run.upperBound
            } else {
                intervals.append(run)
            }
        }

        return intervals.enumerated().map { index, interval in
            let peakSample = peakSample(in: interval, drive: drive)
            let time = min(max(Double(peakSample) / samplingRate, 0), duration)
            // Flag sits at the peak (centered for OBS); the window span is carried
            // as duration so the UI can highlight the section the artifact covers.
            let windowSeconds = Double(interval.upperBound - interval.lowerBound + 1) / samplingRate
            return MFFEvent(
                id: "artifact-\(kind.idComponent)-threshold-\(index)-\(peakSample)",
                code: kind.eventCode,
                beginTimeSeconds: time,
                rawBeginTime: String(format: "%.6f", time),
                sourceFile: sourceFile,
                durationSeconds: windowSeconds
            )
        }
    }

    private static func peakSample(in interval: ClosedRange<Int>, drive: [Float]) -> Int {
        var peakSample = interval.lowerBound
        var peakMagnitude: Float = 0
        for sample in interval where drive.indices.contains(sample) {
            let magnitude = abs(drive[sample])
            if magnitude > peakMagnitude {
                peakMagnitude = magnitude
                peakSample = sample
            }
        }
        return peakSample
    }

    /// Peak absolute first / second difference over the run, expressed in
    /// µV/ms and µV/ms² respectively.
    private static func kinematics(
        in run: ClosedRange<Int>,
        drive: [Float],
        samplesPerMs: Float
    ) -> (velocity: Float, acceleration: Float) {
        var maxVelocity: Float = 0
        var maxAcceleration: Float = 0
        let lower = max(run.lowerBound, 1)
        let upper = min(run.upperBound, drive.count - 1)
        guard lower <= upper else { return (0, 0) }
        for sample in lower...upper {
            let firstDiff = abs(drive[sample] - drive[sample - 1]) * samplesPerMs
            if firstDiff > maxVelocity { maxVelocity = firstDiff }
            if sample + 1 < drive.count {
                let secondDiff = abs(drive[sample + 1] - 2 * drive[sample] + drive[sample - 1])
                    * samplesPerMs * samplesPerMs
                if secondDiff > maxAcceleration { maxAcceleration = secondDiff }
            }
        }
        return (maxVelocity, maxAcceleration)
    }

    /// Resolves the ocular channels to scan: the user override when present and
    /// valid, otherwise the net-geometry default.
    private static func resolvedChannels(
        kind: EyeArtifactKind,
        channels: [[Float]],
        configuration: EyeArtifactThresholdConfiguration
    ) -> [Int] {
        let sampleCount = channels.first?.count ?? 0
        let candidates: [Int]
        if let override = configuration.channelOverride, !override.isEmpty {
            candidates = override
        } else {
            candidates = autoOcularChannelIndices(kind: kind, channelCount: channels.count)
        }
        return candidates.filter { $0 >= 0 && $0 < channels.count && channels[$0].count == sampleCount }
    }

    /// Default ocular channels for a kind, chosen by net geometry (0-based).
    static func autoOcularChannelIndices(kind: EyeArtifactKind, channelCount: Int) -> [Int] {
        // EGI channel numbers are 1-based; signal arrays are 0-based.
        let oneBasedChannels: [Int]
        switch (kind, channelCount) {
        case (.blink, 241...):
            oneBasedChannels = [18, 37, 238, 241]
        case (.blink, 127...):
            oneBasedChannels = [8, 25, 126, 127]
        case (.movement, 252...):
            oneBasedChannels = [226, 252]
        case (.movement, 128...):
            oneBasedChannels = [1, 32, 125, 128]
        default:
            oneBasedChannels = Array(1...min(channelCount, 4))
        }

        return oneBasedChannels.map { $0 - 1 }
    }
}
