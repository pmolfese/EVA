//
//  EyeArtifactThresholdDetector.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
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
        sensorLayoutName: String? = nil,
        configuration: EyeArtifactThresholdConfiguration? = nil
    ) -> [MFFEvent] {
        guard samplingRate > 0, duration > 0, let sampleCount = channels.first?.count, sampleCount > 0 else {
            return []
        }

        let config = configuration ?? .defaults(for: kind)
        let candidateChannels = resolvedChannels(
            kind: kind,
            channels: channels,
            sensorLayoutName: sensorLayoutName,
            configuration: config
        )
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

        // Per-sample "driving" value. Derived mode keeps the expected ocular
        // topology: blinks are bilateral/common-mode, movements are
        // left-right/opponent-mode. Legacy mode preserves the old max-channel
        // collapse exactly.
        let drive = driveTrace(
            kind: kind,
            channels: channels,
            candidateChannels: candidateChannels,
            sensorLayoutName: sensorLayoutName,
            configuration: config
        )

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

        // Bridge raw runs within the merge gap first, so two short fragments
        // separated by a brief below-threshold dip are evaluated as one
        // combined event rather than being discarded individually by the
        // duration/peak/kinematic checks below.
        var mergedRuns: [ClosedRange<Int>] = []
        for run in runs {
            if let last = mergedRuns.last, run.lowerBound - last.upperBound <= mergeGapSamples {
                let merged = last.lowerBound...run.upperBound
                let mergedLength = merged.upperBound - merged.lowerBound + 1
                if mergedLength <= maximumSamples {
                    mergedRuns[mergedRuns.count - 1] = merged
                } else {
                    // A chain of nearby artifacts must not become one
                    // overlong run that is subsequently discarded in full.
                    mergedRuns.append(run)
                }
            } else {
                mergedRuns.append(run)
            }
        }

        var intervals: [ClosedRange<Int>] = []
        for run in mergedRuns {
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

            intervals.append(run)
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
                durationSeconds: windowSeconds,
                timeAnchor: .peak
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

    private static func driveTrace(
        kind: EyeArtifactKind,
        channels: [[Float]],
        candidateChannels: [Int],
        sensorLayoutName: String?,
        configuration: EyeArtifactThresholdConfiguration
    ) -> [Float] {
        switch configuration.topologyMode {
        case .legacyMaxChannel:
            return legacyMaxChannelDrive(channels: channels, candidateChannels: candidateChannels)
        case .derivedOcular:
            guard let groups = resolvedTopologyGroups(
                kind: kind,
                channels: channels,
                sensorLayoutName: sensorLayoutName,
                configuration: configuration
            ) else {
                return legacyMaxChannelDrive(channels: channels, candidateChannels: candidateChannels)
            }
            switch kind {
            case .blink:
                return blinkDrive(channels: channels, groups: groups)
            case .movement:
                return movementDrive(channels: channels, groups: groups)
            }
        }
    }

    private static func legacyMaxChannelDrive(channels: [[Float]], candidateChannels: [Int]) -> [Float] {
        let sampleCount = channels.first?.count ?? 0
        var drive = [Float](repeating: 0, count: sampleCount)
        for sample in 0..<sampleCount {
            var best: Float = 0
            for channelIndex in candidateChannels {
                let value = channels[channelIndex][sample]
                if abs(value) > abs(best) { best = value }
            }
            drive[sample] = best
        }
        return drive
    }

    private static func blinkDrive(channels: [[Float]], groups: OcularTopologyGroups) -> [Float] {
        let sampleCount = channels.first?.count ?? 0
        var drive = [Float](repeating: 0, count: sampleCount)
        for sample in 0..<sampleCount {
            let left = meanSample(sample, channels: channels, indices: groups.left)
            let right = meanSample(sample, channels: channels, indices: groups.right)
            guard left != 0, right != 0, (left > 0) == (right > 0) else {
                drive[sample] = 0
                continue
            }
            // Same-polarity bilateral VEOG-like activity; averaging keeps the
            // threshold in per-side µV units instead of doubling it.
            drive[sample] = (left + right) / 2
        }
        return drive
    }

    private static func movementDrive(channels: [[Float]], groups: OcularTopologyGroups) -> [Float] {
        let sampleCount = channels.first?.count ?? 0
        var drive = [Float](repeating: 0, count: sampleCount)
        for sample in 0..<sampleCount {
            let left = meanSample(sample, channels: channels, indices: groups.left)
            let right = meanSample(sample, channels: channels, indices: groups.right)
            let opponent = left - right
            let common = (left + right) / 2
            // HEOG-like activity should be dominated by left-right opposition,
            // not common-mode blink activity.
            drive[sample] = abs(opponent) > abs(common) ? opponent : 0
        }
        return drive
    }

    private static func meanSample(_ sample: Int, channels: [[Float]], indices: [Int]) -> Float {
        guard !indices.isEmpty else { return 0 }
        var sum: Float = 0
        var count: Float = 0
        for index in indices where channels.indices.contains(index) && channels[index].indices.contains(sample) {
            sum += channels[index][sample]
            count += 1
        }
        return count > 0 ? sum / count : 0
    }

    private struct OcularTopologyGroups {
        let left: [Int]
        let right: [Int]
    }

    private static func resolvedTopologyGroups(
        kind: EyeArtifactKind,
        channels: [[Float]],
        sensorLayoutName: String?,
        configuration: EyeArtifactThresholdConfiguration
    ) -> OcularTopologyGroups? {
        let sampleCount = channels.first?.count ?? 0
        let groups: OcularTopologyGroups
        if let override = configuration.channelOverride, override.count >= 2 {
            let midpoint = max(override.count / 2, 1)
            groups = OcularTopologyGroups(
                left: Array(override.prefix(midpoint)),
                right: Array(override.dropFirst(midpoint))
            )
        } else {
            groups = autoOcularTopologyGroups(
                kind: kind,
                channelCount: channels.count,
                sensorLayoutName: sensorLayoutName
            )
        }

        let left = groups.left.filter { $0 >= 0 && $0 < channels.count && channels[$0].count == sampleCount }
        let right = groups.right.filter { $0 >= 0 && $0 < channels.count && channels[$0].count == sampleCount }
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return OcularTopologyGroups(left: left, right: right)
    }

    /// Resolves the ocular channels to scan: the user override when present and
    /// valid, otherwise the net-geometry default.
    private static func resolvedChannels(
        kind: EyeArtifactKind,
        channels: [[Float]],
        sensorLayoutName: String?,
        configuration: EyeArtifactThresholdConfiguration
    ) -> [Int] {
        let sampleCount = channels.first?.count ?? 0
        let candidates: [Int]
        if let override = configuration.channelOverride, !override.isEmpty {
            candidates = override
        } else {
            candidates = autoOcularChannelIndices(
                kind: kind,
                channelCount: channels.count,
                sensorLayoutName: sensorLayoutName
            )
        }
        return candidates.filter { $0 >= 0 && $0 < channels.count && channels[$0].count == sampleCount }
    }

    /// Default ocular channels for a kind, chosen by net geometry (0-based).
    static func autoOcularChannelIndices(
        kind: EyeArtifactKind,
        channelCount: Int,
        sensorLayoutName: String? = nil
    ) -> [Int] {
        guard let entry = ocularTableEntry(sensorLayoutName: sensorLayoutName, channelCount: channelCount) else {
            return Array(1...min(channelCount, 4)).map { $0 - 1 }
        }

        switch kind {
        case .blink:
            return zeroBasedUnique(entry.blinkLeft + entry.blinkRight)
        case .movement:
            return zeroBasedUnique(entry.movement)
        }
    }

    /// Default left/right periocular groups for the derived VEOG/HEOG traces.
    /// EGI channel numbers are 1-based; returned arrays are 0-based.
    private static func autoOcularTopologyGroups(
        kind: EyeArtifactKind,
        channelCount: Int,
        sensorLayoutName: String?
    ) -> OcularTopologyGroups {
        guard let entry = ocularTableEntry(sensorLayoutName: sensorLayoutName, channelCount: channelCount) else {
            let available = Array(1...min(channelCount, 4))
            let midpoint = max(available.count / 2, 1)
            return OcularTopologyGroups(
                left: zeroBasedUnique(Array(available.prefix(midpoint))),
                right: zeroBasedUnique(Array(available.dropFirst(midpoint)))
            )
        }

        switch kind {
        case .blink:
            return OcularTopologyGroups(
                left: zeroBasedUnique(entry.blinkLeft),
                right: zeroBasedUnique(entry.blinkRight)
            )
        case .movement:
            return OcularTopologyGroups(
                left: zeroBasedUnique(Array(entry.movement.prefix(1))),
                right: zeroBasedUnique(Array(entry.movement.dropFirst(1)))
            )
        }
    }

    private struct OcularTableEntry {
        let blinkLeft: [Int]
        let blinkRight: [Int]
        let movement: [Int]
    }

    private enum OcularNetModel {
        case hcgsn32
        case hcgsn64
        case hcgsn128
        case hcgsn256
        case gsn20064v1
        case gsn20064v2
        case gsn200128
        case gsn200256
    }

    private static func ocularTableEntry(sensorLayoutName: String?, channelCount: Int) -> OcularTableEntry? {
        guard let model = ocularNetModel(sensorLayoutName: sensorLayoutName, channelCount: channelCount) else {
            return nil
        }

        // Values are EGI's 1-based channel numbers from the GSN ocular-pair table.
        switch model {
        case .hcgsn32:
            return OcularTableEntry(blinkLeft: [2, 30], blinkRight: [1, 29], movement: [31, 32])
        case .hcgsn64:
            return OcularTableEntry(blinkLeft: [10, 63], blinkRight: [5, 62], movement: [61, 64])
        case .hcgsn128:
            return OcularTableEntry(blinkLeft: [25, 127, 21], blinkRight: [8, 126, 14], movement: [125, 128])
        case .hcgsn256:
            return OcularTableEntry(blinkLeft: [37, 241, 32], blinkRight: [18, 238, 25], movement: [226, 252])
        case .gsn20064v1:
            return OcularTableEntry(blinkLeft: [14, 64, 11], blinkRight: [1, 63, 6], movement: [18, 60])
        case .gsn20064v2:
            return OcularTableEntry(blinkLeft: [14, 64, 11], blinkRight: [1, 63, 6], movement: [19, 60])
        case .gsn200128:
            return OcularTableEntry(blinkLeft: [26, 127, 33], blinkRight: [8, 126, 1], movement: [125, 128])
        case .gsn200256:
            return OcularTableEntry(blinkLeft: [36, 242, 45], blinkRight: [18, 241, 10], movement: [227, 251])
        }
    }

    private static func ocularNetModel(sensorLayoutName: String?, channelCount: Int) -> OcularNetModel? {
        let normalized = sensorLayoutName?
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ") ?? ""
        let explicitNetChannelCount = explicitNetChannelCount(in: normalized)
        let effectiveChannelCount = explicitNetChannelCount ?? nominalNetChannelCount(forLoadedChannelCount: channelCount)

        let isGSN200 = normalized.contains("gsn 200")
            || normalized.contains("gsn200")
            || normalized.contains("geodesic sensor net 200")
        if isGSN200 {
            switch effectiveChannelCount {
            case 64:
                let isVersion2 = normalized.contains("v.2")
                    || normalized.contains("v2")
                    || normalized.contains("version 2")
                    || normalized.contains("2.0")
                return isVersion2 ? .gsn20064v2 : .gsn20064v1
            case 128: return .gsn200128
            case 256...: return .gsn200256
            default: return nil
            }
        }

        switch effectiveChannelCount {
        case 32: return .hcgsn32
        case 64: return .hcgsn64
        case 128: return .hcgsn128
        case 256...: return .hcgsn256
        default: return nil
        }
    }

    private static func explicitNetChannelCount(in normalizedLayoutName: String) -> Int? {
        let numberTokens = normalizedLayoutName
            .split { !$0.isNumber }
            .compactMap { Int($0) }
        for supportedCount in [32, 64, 128, 256] where numberTokens.contains(supportedCount) {
            return supportedCount
        }
        return nil
    }

    private static func nominalNetChannelCount(forLoadedChannelCount channelCount: Int) -> Int {
        switch channelCount {
        case 32, 33:
            return 32
        case 64, 65:
            return 64
        case 128, 129:
            return 128
        case 256...:
            return 256
        default:
            return channelCount
        }
    }

    private static func zeroBasedUnique(_ oneBasedChannels: [Int]) -> [Int] {
        var seen = Set<Int>()
        return oneBasedChannels.compactMap { channel in
            guard channel > 0, seen.insert(channel).inserted else { return nil }
            return channel - 1
        }
    }
}
