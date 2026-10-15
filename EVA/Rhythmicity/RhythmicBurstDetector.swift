//
//  RhythmicBurstDetector.swift
//  EVA
//
//  Deterministic neural-rhythmicity burst detection. This analysis domain is
//  intentionally separate from EVA's artifact detection and cleaning tools.
//

import Foundation

nonisolated enum RhythmicBurstBoundarySource: String, CaseIterable, Identifiable, Sendable, Codable {
    case powerPercentile = "Power 75th percentile"
    case wtplThreshold = "WTPL threshold"

    var id: String { rawValue }
}

nonisolated struct RhythmicBurstConfiguration: Sendable, Codable, Equatable {
    var peakPercentile: Double
    var boundaryPercentile: Double
    var minimumDurationCycles: Double
    var minimumMergeGapHz: Double
    var relativeMergeGap: Double
    var wtplThreshold: Double
    var boundarySource: RhythmicBurstBoundarySource
    /// Reference `downsmpFact` analogue. Longer segments retain this many or
    /// fewer time points while the Morlet transform itself stays full-rate.
    var maximumTimePointsPerSegment: Int
    var maximumDisplayTimePoints: Int

    static let paper2026 = RhythmicBurstConfiguration(
        peakPercentile: 90,
        boundaryPercentile: 75,
        minimumDurationCycles: 1,
        minimumMergeGapHz: 4,
        relativeMergeGap: 0.25,
        wtplThreshold: 0.5,
        boundarySource: .powerPercentile,
        maximumTimePointsPerSegment: 250_000,
        maximumDisplayTimePoints: 1_200
    )
}

nonisolated struct RhythmicBurstBandDefinition: Identifiable, Sendable, Codable, Equatable {
    var id: String
    var name: String
    var lowHz: Double
    var highHz: Double
    var direction: ABBADirection?
    var source: String

    func contains(_ frequencyHz: Double) -> Bool {
        min(lowHz, highHz) <= frequencyHz && frequencyHz <= max(lowHz, highHz)
    }
}

nonisolated struct RhythmicBurst: Identifiable, Sendable, Codable, Equatable {
    var id: String
    var channelIndex: Int
    var channelName: String
    var segmentIndex: Int
    var segmentID: String?
    var segmentLabel: String?
    var peakFrequencyIndex: Int
    var peakFrequencyHz: Double
    var peakLocalSample: Int
    var peakGlobalSample: Int
    var onsetLocalSample: Int
    var offsetLocalSample: Int
    var onsetGlobalSample: Int
    var offsetGlobalSample: Int
    var initialOnsetGlobalSample: Int
    var initialOffsetGlobalSample: Int
    var peakPower: Double
    var peakThresholdPower: Double
    var relativePeakPowerDB: Double
    var durationMilliseconds: Double
    var durationCycles: Double
    var estimatedEnergy: Double
    var lowerPeakFrequencyHz: Double
    var upperPeakFrequencyHz: Double
    var peakWTPL: Double?
    var meanWTPL: Double?
    var bandID: String?
    var bandName: String?
    var bandDirection: ABBADirection?
    var bandConsistencyPercent: Double?
    var boundarySource: RhythmicBurstBoundarySource
}

nonisolated struct RhythmicBurstDetectionOutput: Sendable, Equatable {
    var bursts: [RhythmicBurst]
    var peakPowerThresholds: [Double]
    var boundaryPowerThresholds: [Double]
}

nonisolated struct RhythmicBurstMap: Identifiable, Sendable, Codable, Equatable {
    var id: String
    var channelIndex: Int
    var channelName: String
    var segmentIndex: Int
    var segmentID: String?
    var segmentLabel: String?
    var segmentStartSample: Int
    var segmentEndSample: Int
    var sampleStride: Int
    var frequenciesHz: [Double]
    var timesSeconds: [Double]
    var normalizedPower: [[Double]]
    var wtpl: [[Double]]
    var waveformTimesSeconds: [Double]
    var waveform: [Double]
}

nonisolated struct RhythmicBurstBandSummary: Identifiable, Sendable, Codable, Equatable {
    var id: String
    var channelIndex: Int
    var channelName: String
    var bandID: String?
    var bandName: String
    var bandDirection: ABBADirection?
    var bandWidthHz: Double
    var burstCount: Int
    var analyzedDurationSeconds: Double
    var ratePerMinutePerHz: Double
    var occupancyPercent: Double
    var meanDurationMilliseconds: Double
    var meanDurationCycles: Double
    var meanRelativePeakPowerDB: Double
    var meanWTPL: Double?
}

nonisolated struct RhythmicBurstAnalysisResult: Sendable, Equatable {
    var configuration: RhythmicBurstConfiguration
    var source: RhythmicitySourceDescriptor
    var processingProvenance: RhythmicityProcessingProvenance
    var selection: RhythmicitySelectionDescriptor
    var samplingRateHz: Double
    var frequenciesHz: [Double]
    var morletWidthCycles: Double
    var wtplLagCycles: [Double]
    var bandSourceDescription: String
    var bandDefinitions: [RhythmicBurstBandDefinition]
    var maps: [RhythmicBurstMap]
    var bursts: [RhythmicBurst]
    var summaries: [RhythmicBurstBandSummary]
    var warnings: [String]
}

nonisolated enum RhythmicBurstError: Error, Sendable, Equatable, LocalizedError {
    case emptyPowerMap
    case invalidSamplingRate(Double)
    case invalidConfiguration(String)
    case frequencyCountMismatch(expected: Int, actual: Int)
    case rowLengthMismatch(row: Int, expected: Int, actual: Int)
    case wtplShapeMismatch

    var errorDescription: String? {
        switch self {
        case .emptyPowerMap: return "Burst detection requires a nonempty power map."
        case let .invalidSamplingRate(value): return "Burst sampling rate must be finite and positive; received \(value)."
        case let .invalidConfiguration(message): return "Invalid burst configuration: \(message)"
        case let .frequencyCountMismatch(expected, actual):
            return "Burst detection received \(actual) frequency labels for \(expected) power rows."
        case let .rowLengthMismatch(row, expected, actual):
            return "Burst power row \(row) has \(actual) samples; expected \(expected)."
        case .wtplShapeMismatch: return "The WTPL and power maps must have identical shapes."
        }
    }
}

nonisolated enum RhythmicBurstDetector {
    static let methodVersion = "rhythmic-burst-reference-2026-v1"
    static let referenceCommit = "6da57b71f1084c62cfa1a4deaebee227d38f2584"
    static let referenceFileSHA256 = "76375d0f2e972ed34654abdbed12b410754876ca5b8ea8286eca2c291c101c29"

    private struct Candidate {
        var burst: RhythmicBurst
        var involvedFrequencies: Set<Int>
    }

    static func detect(
        power: [[Double]],
        wtpl: [[Double]]? = nil,
        frequenciesHz: [Double],
        samplingRate: Double,
        sampleStride: Int = 1,
        channelIndex: Int,
        channelName: String,
        segmentIndex: Int,
        segmentID: String? = nil,
        segmentLabel: String? = nil,
        segmentStartSample: Int = 0,
        bands: [RhythmicBurstBandDefinition] = [],
        configuration: RhythmicBurstConfiguration = .paper2026,
        cancellation: RhythmicityCancellation = RhythmicityCancellation()
    ) throws -> RhythmicBurstDetectionOutput {
        let timeCount = try validate(
            power: power, wtpl: wtpl, frequenciesHz: frequenciesHz,
            samplingRate: samplingRate, sampleStride: sampleStride,
            configuration: configuration
        )
        let peakThresholds = power.map { percentile($0.filter(\.isFinite), percentile: configuration.peakPercentile) }
        let boundaryThresholds = power.map { percentile($0.filter(\.isFinite), percentile: configuration.boundaryPercentile) }
        let peaks = try regionalMaxima(
            power: power, thresholds: peakThresholds, cancellation: cancellation
        )
        var candidates: [Candidate] = []
        candidates.reserveCapacity(peaks.count)

        for (ordinal, peak) in peaks.enumerated() {
            if ordinal & 0x3f == 0 { try cancellation.check() }
            let frequencyIndex = peak.frequency
            let peakTime = peak.time
            let highRange = contiguousRange(
                around: peakTime,
                timeCount: timeCount,
                isActive: { power[frequencyIndex][$0].isFinite && power[frequencyIndex][$0] >= peakThresholds[frequencyIndex] }
            )
            let frequencySpan = contiguousFrequencySpan(
                around: frequencyIndex,
                time: peakTime,
                power: power,
                thresholds: peakThresholds
            )
            var involved = Set<Int>()
            for time in highRange {
                if let dominant = dominantFrequency(
                    at: time, frequencies: frequencySpan, power: power,
                    thresholds: peakThresholds
                ) {
                    involved.insert(dominant)
                }
            }
            if involved.isEmpty { involved.insert(frequencyIndex) }

            let finalRange: ClosedRange<Int>
            switch configuration.boundarySource {
            case .powerPercentile:
                finalRange = contiguousRange(
                    around: peakTime,
                    timeCount: timeCount,
                    isActive: { time in
                        involved.contains { frequency in
                            let value = power[frequency][time]
                            return value.isFinite && value >= boundaryThresholds[frequency]
                        }
                    }
                )
            case .wtplThreshold:
                guard let wtpl else { continue }
                finalRange = contiguousRange(
                    around: peakTime,
                    timeCount: timeCount,
                    isActive: { time in
                        involved.contains { frequency in
                            let value = wtpl[frequency][time]
                            return value.isFinite && value >= configuration.wtplThreshold
                        }
                    }
                )
            }

            let peakFrequency = frequenciesHz[frequencyIndex]
            let durationSeconds = Double(finalRange.upperBound - finalRange.lowerBound)
                / samplingRate
            let durationCycles = durationSeconds * peakFrequency
            guard durationCycles >= configuration.minimumDurationCycles else { continue }
            let peakPower = power[frequencyIndex][peakTime]
            let threshold = peakThresholds[frequencyIndex]
            let globalPeak = segmentStartSample + peakTime * sampleStride
            let globalOnset = segmentStartSample + finalRange.lowerBound * sampleStride
            let globalOffset = segmentStartSample + finalRange.upperBound * sampleStride
            let initialOnset = segmentStartSample + highRange.lowerBound * sampleStride
            let initialOffset = segmentStartSample + highRange.upperBound * sampleStride
            let band = bands.first { $0.contains(peakFrequency) }
            let wtplMetrics = wtplMetrics(
                wtpl: wtpl, involved: involved, range: finalRange,
                peakFrequency: frequencyIndex, peakTime: peakTime
            )
            let consistency = band.map {
                bandConsistency(power: power, range: finalRange, band: $0, frequenciesHz: frequenciesHz)
            }
            let lowerFrequency = involved.map { frequenciesHz[$0] }.min() ?? peakFrequency
            let upperFrequency = involved.map { frequenciesHz[$0] }.max() ?? peakFrequency
            let id = "c\(channelIndex)-s\(segmentIndex)-t\(globalPeak)-f\(frequencyIndex)"
            candidates.append(Candidate(
                burst: RhythmicBurst(
                    id: id,
                    channelIndex: channelIndex,
                    channelName: channelName,
                    segmentIndex: segmentIndex,
                    segmentID: segmentID,
                    segmentLabel: segmentLabel,
                    peakFrequencyIndex: frequencyIndex,
                    peakFrequencyHz: peakFrequency,
                    peakLocalSample: peakTime,
                    peakGlobalSample: globalPeak,
                    onsetLocalSample: finalRange.lowerBound,
                    offsetLocalSample: finalRange.upperBound,
                    onsetGlobalSample: globalOnset,
                    offsetGlobalSample: globalOffset,
                    initialOnsetGlobalSample: initialOnset,
                    initialOffsetGlobalSample: initialOffset,
                    peakPower: peakPower,
                    peakThresholdPower: threshold,
                    relativePeakPowerDB: threshold > 0 ? 10 * log10(peakPower / threshold) : .nan,
                    durationMilliseconds: durationSeconds * 1_000,
                    durationCycles: durationCycles,
                    estimatedEnergy: peakPower * max(durationSeconds, 1 / samplingRate),
                    lowerPeakFrequencyHz: lowerFrequency,
                    upperPeakFrequencyHz: upperFrequency,
                    peakWTPL: wtplMetrics.peak,
                    meanWTPL: wtplMetrics.mean,
                    bandID: band?.id,
                    bandName: band?.name,
                    bandDirection: band?.direction,
                    bandConsistencyPercent: consistency,
                    boundarySource: configuration.boundarySource
                ),
                involvedFrequencies: involved
            ))
        }

        candidates = merge(
            candidates,
            power: power,
            wtpl: wtpl,
            frequenciesHz: frequenciesHz,
            samplingRate: samplingRate,
            sampleStride: sampleStride,
            segmentStartSample: segmentStartSample,
            bands: bands,
            configuration: configuration
        )
        return RhythmicBurstDetectionOutput(
            bursts: candidates.map(\.burst).sorted(by: burstOrder),
            peakPowerThresholds: peakThresholds,
            boundaryPowerThresholds: boundaryThresholds
        )
    }

    static func summarize(
        bursts: [RhythmicBurst],
        bands: [RhythmicBurstBandDefinition],
        analyzedDurationSecondsByChannel: [Int: Double],
        samplingRateHz: Double,
        fallbackFrequencyRangeHz: ClosedRange<Double>
    ) -> [RhythmicBurstBandSummary] {
        struct Key: Hashable { var channel: Int; var band: String }
        let grouped = Dictionary(grouping: bursts) {
            Key(channel: $0.channelIndex, band: $0.bandID ?? "unassigned")
        }
        return grouped.map { key, values in
            let first = values[0]
            let band = bands.first { $0.id == first.bandID }
            let width = max((band.map { abs($0.highHz - $0.lowHz) }
                ?? (fallbackFrequencyRangeHz.upperBound - fallbackFrequencyRangeHz.lowerBound)),
                Double.leastNormalMagnitude)
            let duration = analyzedDurationSecondsByChannel[key.channel] ?? 0
            let occupiedSeconds = unionDuration(values.map {
                Double($0.onsetGlobalSample)...Double($0.offsetGlobalSample)
            }) / samplingRateHz
            let finiteWTPL = values.compactMap(\.meanWTPL).filter(\.isFinite)
            return RhythmicBurstBandSummary(
                id: "c\(key.channel)-b\(key.band)",
                channelIndex: key.channel,
                channelName: first.channelName,
                bandID: first.bandID,
                bandName: band?.name ?? "Unassigned",
                bandDirection: band?.direction,
                bandWidthHz: width,
                burstCount: values.count,
                analyzedDurationSeconds: duration,
                ratePerMinutePerHz: duration > 0 ? Double(values.count) * 60 / duration / width : .nan,
                occupancyPercent: duration > 0 ? occupiedSeconds / duration * 100 : .nan,
                meanDurationMilliseconds: finiteMean(values.map(\.durationMilliseconds)),
                meanDurationCycles: finiteMean(values.map(\.durationCycles)),
                meanRelativePeakPowerDB: finiteMean(values.map(\.relativePeakPowerDB)),
                meanWTPL: finiteWTPL.isEmpty ? nil : finiteMean(finiteWTPL)
            )
        }.sorted {
            ($0.channelIndex, $0.bandName) < ($1.channelIndex, $1.bandName)
        }
    }

    private static func validate(
        power: [[Double]],
        wtpl: [[Double]]?,
        frequenciesHz: [Double],
        samplingRate: Double,
        sampleStride: Int,
        configuration: RhythmicBurstConfiguration
    ) throws -> Int {
        guard !power.isEmpty, let timeCount = power.first?.count, timeCount > 0 else {
            throw RhythmicBurstError.emptyPowerMap
        }
        guard samplingRate.isFinite, samplingRate > 0 else {
            throw RhythmicBurstError.invalidSamplingRate(samplingRate)
        }
        guard sampleStride > 0 else { throw RhythmicBurstError.invalidConfiguration("sample stride must be positive") }
        guard frequenciesHz.count == power.count else {
            throw RhythmicBurstError.frequencyCountMismatch(expected: power.count, actual: frequenciesHz.count)
        }
        for row in power.indices where power[row].count != timeCount {
            throw RhythmicBurstError.rowLengthMismatch(row: row, expected: timeCount, actual: power[row].count)
        }
        if let wtpl {
            guard wtpl.count == power.count,
                  zip(wtpl, power).allSatisfy({ $0.count == $1.count }) else {
                throw RhythmicBurstError.wtplShapeMismatch
            }
        }
        guard (0...100).contains(configuration.peakPercentile),
              (0...100).contains(configuration.boundaryPercentile),
              configuration.boundaryPercentile <= configuration.peakPercentile,
              configuration.minimumDurationCycles >= 0,
              configuration.minimumMergeGapHz >= 0,
              configuration.relativeMergeGap >= 0,
              configuration.wtplThreshold.isFinite,
              configuration.maximumTimePointsPerSegment > 0,
              configuration.maximumDisplayTimePoints > 0 else {
            throw RhythmicBurstError.invalidConfiguration("percentiles, thresholds, duration, merge gaps, and map limits must be valid")
        }
        return timeCount
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let position = percentile / 100 * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        guard lower != upper else { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }

    private static func regionalMaxima(
        power: [[Double]],
        thresholds: [Double],
        cancellation: RhythmicityCancellation
    ) throws -> [(frequency: Int, time: Int)] {
        let frequencyCount = power.count
        let timeCount = power[0].count
        var visited = [UInt8](repeating: 0, count: frequencyCount * timeCount)
        var peaks: [(frequency: Int, time: Int)] = []
        for time in 0..<timeCount {
            if time & 0x3ff == 0 { try cancellation.check() }
            for frequency in 0..<frequencyCount {
                let flat = frequency * timeCount + time
                if visited[flat] != 0 { continue }
                let value = power[frequency][time]
                guard value.isFinite, thresholds[frequency].isFinite,
                      value >= thresholds[frequency] else {
                    visited[flat] = 1
                    continue
                }
                var component = [(frequency: frequency, time: time)]
                var head = 0
                visited[flat] = 1
                var isMaximum = true
                var hasLowerNeighbor = false
                while head < component.count {
                    let point = component[head]
                    head += 1
                    for df in -1...1 {
                        for dt in -1...1 where df != 0 || dt != 0 {
                            let neighborFrequency = point.frequency + df
                            let neighborTime = point.time + dt
                            guard power.indices.contains(neighborFrequency),
                                  power[neighborFrequency].indices.contains(neighborTime) else { continue }
                            let neighbor = power[neighborFrequency][neighborTime]
                            guard neighbor.isFinite else { continue }
                            if neighbor > value { isMaximum = false }
                            if neighbor < value { hasLowerNeighbor = true }
                            if neighbor == value {
                                let neighborFlat = neighborFrequency * timeCount + neighborTime
                                if visited[neighborFlat] == 0 {
                                    visited[neighborFlat] = 1
                                    component.append((neighborFrequency, neighborTime))
                                }
                            }
                        }
                    }
                }
                if isMaximum, hasLowerNeighbor {
                    let representative = component.min {
                        ($0.time, $0.frequency) < ($1.time, $1.frequency)
                    }!
                    peaks.append(representative)
                }
            }
        }
        return peaks.sorted { ($0.time, $0.frequency) < ($1.time, $1.frequency) }
    }

    private static func contiguousRange(
        around center: Int,
        timeCount: Int,
        isActive: (Int) -> Bool
    ) -> ClosedRange<Int> {
        guard isActive(center) else { return center...center }
        var lower = center
        var upper = center
        while lower > 0, isActive(lower - 1) { lower -= 1 }
        while upper + 1 < timeCount, isActive(upper + 1) { upper += 1 }
        return lower...upper
    }

    private static func contiguousFrequencySpan(
        around center: Int,
        time: Int,
        power: [[Double]],
        thresholds: [Double]
    ) -> ClosedRange<Int> {
        func active(_ frequency: Int) -> Bool {
            let value = power[frequency][time]
            return value.isFinite && thresholds[frequency].isFinite && value >= thresholds[frequency]
        }
        var lower = center
        var upper = center
        while lower > 0, active(lower - 1) { lower -= 1 }
        while upper + 1 < power.count, active(upper + 1) { upper += 1 }
        return lower...upper
    }

    private static func dominantFrequency(
        at time: Int,
        frequencies: ClosedRange<Int>,
        power: [[Double]],
        thresholds: [Double]
    ) -> Int? {
        frequencies.filter {
            let value = power[$0][time]
            return value.isFinite && thresholds[$0].isFinite && value >= thresholds[$0]
        }.max {
            let left = power[$0][time] / thresholds[$0]
            let right = power[$1][time] / thresholds[$1]
            return left == right ? $0 > $1 : left < right
        }
    }

    private static func wtplMetrics(
        wtpl: [[Double]]?,
        involved: Set<Int>,
        range: ClosedRange<Int>,
        peakFrequency: Int,
        peakTime: Int
    ) -> (peak: Double?, mean: Double?) {
        guard let wtpl else { return (nil, nil) }
        let peak = wtpl[peakFrequency][peakTime]
        let values = involved.flatMap { frequency in
            range.compactMap { time -> Double? in
                let value = wtpl[frequency][time]
                return value.isFinite ? value : nil
            }
        }
        return (
            peak.isFinite ? peak : nil,
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        )
    }

    private static func bandConsistency(
        power: [[Double]],
        range: ClosedRange<Int>,
        band: RhythmicBurstBandDefinition,
        frequenciesHz: [Double]
    ) -> Double {
        var valid = 0
        var inside = 0
        for time in range {
            guard let frequency = power.indices.filter({ power[$0][time].isFinite }).max(by: {
                power[$0][time] < power[$1][time]
            }) else { continue }
            valid += 1
            if band.contains(frequenciesHz[frequency]) { inside += 1 }
        }
        return valid > 0 ? Double(inside) / Double(valid) * 100 : .nan
    }

    private static func merge(
        _ source: [Candidate],
        power: [[Double]],
        wtpl: [[Double]]?,
        frequenciesHz: [Double],
        samplingRate: Double,
        sampleStride: Int,
        segmentStartSample: Int,
        bands: [RhythmicBurstBandDefinition],
        configuration: RhythmicBurstConfiguration
    ) -> [Candidate] {
        var candidates = source.sorted { burstOrder($0.burst, $1.burst) }
        var changed = true
        while changed {
            changed = false
            mergeSearch: for firstIndex in candidates.indices {
                guard firstIndex + 1 < candidates.count else { continue }
                for secondIndex in (firstIndex + 1)..<candidates.count {
                    let first = candidates[firstIndex]
                    let second = candidates[secondIndex]
                    guard first.burst.channelIndex == second.burst.channelIndex,
                          first.burst.segmentIndex == second.burst.segmentIndex else { continue }
                    let overlaps = max(first.burst.onsetLocalSample, second.burst.onsetLocalSample)
                        <= min(first.burst.offsetLocalSample, second.burst.offsetLocalSample)
                    let allowedGap = max(
                        configuration.minimumMergeGapHz,
                        min(first.burst.peakFrequencyHz, second.burst.peakFrequencyHz)
                            * configuration.relativeMergeGap
                    )
                    guard overlaps,
                          abs(first.burst.peakFrequencyHz - second.burst.peakFrequencyHz) <= allowedGap else { continue }

                    let winner: Candidate
                    if second.burst.estimatedEnergy > first.burst.estimatedEnergy {
                        winner = second
                    } else {
                        winner = first
                    }
                    var merged = winner
                    merged.involvedFrequencies.formUnion(first.involvedFrequencies)
                    merged.involvedFrequencies.formUnion(second.involvedFrequencies)
                    merged.burst.onsetLocalSample = min(first.burst.onsetLocalSample, second.burst.onsetLocalSample)
                    merged.burst.offsetLocalSample = max(first.burst.offsetLocalSample, second.burst.offsetLocalSample)
                    merged.burst.onsetGlobalSample = segmentStartSample + merged.burst.onsetLocalSample * sampleStride
                    merged.burst.offsetGlobalSample = segmentStartSample + merged.burst.offsetLocalSample * sampleStride
                    merged.burst.initialOnsetGlobalSample = min(first.burst.initialOnsetGlobalSample, second.burst.initialOnsetGlobalSample)
                    merged.burst.initialOffsetGlobalSample = max(first.burst.initialOffsetGlobalSample, second.burst.initialOffsetGlobalSample)
                    let duration = Double(merged.burst.offsetLocalSample - merged.burst.onsetLocalSample) / samplingRate
                    merged.burst.durationMilliseconds = duration * 1_000
                    merged.burst.durationCycles = duration * merged.burst.peakFrequencyHz
                    merged.burst.estimatedEnergy = merged.burst.peakPower * max(duration, 1 / samplingRate)
                    merged.burst.lowerPeakFrequencyHz = merged.involvedFrequencies.map { frequenciesHz[$0] }.min() ?? merged.burst.peakFrequencyHz
                    merged.burst.upperPeakFrequencyHz = merged.involvedFrequencies.map { frequenciesHz[$0] }.max() ?? merged.burst.peakFrequencyHz
                    let interval = merged.burst.onsetLocalSample...merged.burst.offsetLocalSample
                    let metrics = wtplMetrics(
                        wtpl: wtpl, involved: merged.involvedFrequencies, range: interval,
                        peakFrequency: merged.burst.peakFrequencyIndex,
                        peakTime: merged.burst.peakLocalSample
                    )
                    merged.burst.peakWTPL = metrics.peak
                    merged.burst.meanWTPL = metrics.mean
                    let band = bands.first { $0.contains(merged.burst.peakFrequencyHz) }
                    merged.burst.bandID = band?.id
                    merged.burst.bandName = band?.name
                    merged.burst.bandDirection = band?.direction
                    merged.burst.bandConsistencyPercent = band.map {
                        bandConsistency(power: power, range: interval, band: $0, frequenciesHz: frequenciesHz)
                    }
                    candidates[firstIndex] = merged
                    candidates.remove(at: secondIndex)
                    candidates.sort { burstOrder($0.burst, $1.burst) }
                    changed = true
                    break mergeSearch
                }
            }
        }
        return candidates
    }

    private static func burstOrder(_ lhs: RhythmicBurst, _ rhs: RhythmicBurst) -> Bool {
        (lhs.channelIndex, lhs.segmentIndex, lhs.peakGlobalSample, lhs.peakFrequencyHz, lhs.id)
            < (rhs.channelIndex, rhs.segmentIndex, rhs.peakGlobalSample, rhs.peakFrequencyHz, rhs.id)
    }

    private static func finiteMean(_ values: [Double]) -> Double {
        let finite = values.filter(\.isFinite)
        return finite.isEmpty ? .nan : finite.reduce(0, +) / Double(finite.count)
    }

    private static func unionDuration(_ intervals: [ClosedRange<Double>]) -> Double {
        guard !intervals.isEmpty else { return 0 }
        let sorted = intervals.sorted { $0.lowerBound < $1.lowerBound }
        var total = 0.0
        var current = sorted[0]
        for interval in sorted.dropFirst() {
            if interval.lowerBound <= current.upperBound {
                current = current.lowerBound...max(current.upperBound, interval.upperBound)
            } else {
                total += current.upperBound - current.lowerBound
                current = interval
            }
        }
        total += current.upperBound - current.lowerBound
        return total
    }
}
