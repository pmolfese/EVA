//
//  RhythmicBurstRunner.swift
//  EVA
//
//  Bounded-memory orchestration from recording selections to burst maps.
//  Method reference: Karvat et al. (2026), Nature Communications, 17, 7024.
//  https://doi.org/10.1038/s41467-026-73553-8
//

import Foundation

nonisolated struct RhythmicBurstRunSnapshot: Sendable {
    var signal: MFFSignalData
    var rhythmicityConfiguration: RhythmicityConfiguration
    var burstConfiguration: RhythmicBurstConfiguration
    var source: RhythmicitySourceDescriptor
    var provenance: RhythmicityProcessingProvenance
    var selection: RhythmicitySelectionDescriptor
    var bandsByChannel: [Int: [RhythmicBurstBandDefinition]]
    var bandSourceDescription: String
}

nonisolated enum RhythmicBurstRunner {
    static func analyze(
        snapshot: RhythmicBurstRunSnapshot,
        cancellation: RhythmicityCancellation,
        progress: @escaping @Sendable (RhythmicityProgress) -> Void
    ) throws -> RhythmicBurstAnalysisResult {
        let frequencies = snapshot.rhythmicityConfiguration.frequenciesHz
        let totalTiles = max(
            snapshot.selection.includedChannelIndices.count
                * snapshot.selection.segments.count
                * frequencies.count,
            1
        )
        let provider = AccelerateFFTComplexCoefficientProvider(
            policy: snapshot.rhythmicityConfiguration.computePolicy
        )
        var completedTiles = 0
        var maps: [RhythmicBurstMap] = []
        var bursts: [RhythmicBurst] = []
        var warnings: [String] = []
        var analyzedDuration: [Int: Double] = [:]

        for channelIndex in snapshot.selection.includedChannelIndices {
            try cancellation.check()
            guard snapshot.signal.data.indices.contains(channelIndex) else { continue }
            let channelName = snapshot.signal.channelNames.flatMap { names in
                names.indices.contains(channelIndex) ? names[channelIndex] : nil
            } ?? "E\(channelIndex + 1)"
            let sourceSamples = snapshot.signal.data[channelIndex]
            let channelBands = snapshot.bandsByChannel[channelIndex] ?? []

            for (segmentIndex, segment) in snapshot.selection.segments.enumerated() {
                try cancellation.check()
                let lower = max(segment.startSample, 0)
                let upper = min(segment.endSample, sourceSamples.count - 1)
                guard lower <= upper else { continue }
                let samples = sourceSamples[lower...upper].map(Double.init)
                analyzedDuration[channelIndex, default: 0] += Double(samples.count) / snapshot.signal.samplingRate
                let stride = max(
                    1,
                    Int(ceil(Double(samples.count) / Double(snapshot.burstConfiguration.maximumTimePointsPerSegment)))
                )
                let reducedIndices = Array(Swift.stride(from: 0, to: samples.count, by: stride))
                let reducedRate = snapshot.signal.samplingRate / Double(stride)
                var power = [[Double]](
                    repeating: [Double](repeating: .nan, count: reducedIndices.count),
                    count: frequencies.count
                )
                var wtpl = power

                for frequencyIndex in frequencies.indices {
                    try cancellation.check()
                    let frequency = frequencies[frequencyIndex]
                    let tile = try provider.coefficients(
                        signal: samples,
                        samplingRate: snapshot.signal.samplingRate,
                        frequencyHz: frequency,
                        widthCycles: snapshot.rhythmicityConfiguration.morletWidthCycles,
                        edgePolicy: .validOnly,
                        cancellation: cancellation
                    )
                    let wtplFull = WTPLEngine.singleTrialValues(
                        tile: tile,
                        frequencyHz: frequency,
                        samplingRate: snapshot.signal.samplingRate,
                        lagCycles: snapshot.rhythmicityConfiguration.wtplLagCycles
                    )
                    for reducedTime in reducedIndices.indices {
                        let fullTime = reducedIndices[reducedTime]
                        guard tile.validSampleRange.contains(fullTime) else { continue }
                        let real = tile.real[fullTime]
                        let imaginary = tile.imaginary[fullTime]
                        let value = real * real + imaginary * imaginary
                        power[frequencyIndex][reducedTime] = value.isFinite ? value : .nan
                        wtpl[frequencyIndex][reducedTime] = wtplFull[fullTime]
                    }
                    completedTiles += 1
                    progress(RhythmicityProgress(
                        fractionComplete: Double(completedTiles) / Double(totalTiles) * 0.9,
                        phase: .transforming,
                        channelIndex: channelIndex,
                        frequencyHz: frequency,
                        completedTiles: completedTiles,
                        totalTiles: totalTiles
                    ))
                }

                let detected = try RhythmicBurstDetector.detect(
                    power: power,
                    wtpl: wtpl,
                    frequenciesHz: frequencies,
                    samplingRate: reducedRate,
                    sampleStride: stride,
                    channelIndex: channelIndex,
                    channelName: channelName,
                    segmentIndex: segmentIndex,
                    segmentID: segment.trialID,
                    segmentLabel: segment.label,
                    segmentStartSample: lower,
                    bands: channelBands,
                    configuration: snapshot.burstConfiguration,
                    cancellation: cancellation
                )
                bursts.append(contentsOf: detected.bursts)
                progress(RhythmicityProgress(
                    fractionComplete: 0.9 + 0.1 * Double(completedTiles) / Double(totalTiles),
                    phase: .detectingBursts,
                    channelIndex: channelIndex,
                    frequencyHz: nil,
                    completedTiles: completedTiles,
                    totalTiles: totalTiles
                ))

                let displayStride = max(
                    1,
                    Int(ceil(Double(reducedIndices.count) / Double(snapshot.burstConfiguration.maximumDisplayTimePoints)))
                )
                let displayIndices = Array(Swift.stride(from: 0, to: reducedIndices.count, by: displayStride))
                let normalizedPower = power.indices.map { frequency in
                    let threshold = detected.peakPowerThresholds[frequency]
                    return displayIndices.map { time in
                        let value = power[frequency][time]
                        return value.isFinite && threshold.isFinite && threshold > 0
                            ? value / threshold : .nan
                    }
                }
                let displayWTPL = wtpl.indices.map { frequency in
                    displayIndices.map { wtpl[frequency][$0] }
                }
                let fullDisplayIndices = displayIndices.map { reducedIndices[$0] }
                maps.append(RhythmicBurstMap(
                    id: "c\(channelIndex)-s\(segmentIndex)",
                    channelIndex: channelIndex,
                    channelName: channelName,
                    segmentIndex: segmentIndex,
                    segmentID: segment.trialID,
                    segmentLabel: segment.label,
                    segmentStartSample: lower,
                    segmentEndSample: upper,
                    sampleStride: stride * displayStride,
                    frequenciesHz: frequencies,
                    timesSeconds: fullDisplayIndices.map {
                        Double(lower + $0) / snapshot.signal.samplingRate
                    },
                    normalizedPower: normalizedPower,
                    wtpl: displayWTPL,
                    waveformTimesSeconds: fullDisplayIndices.map {
                        Double(lower + $0) / snapshot.signal.samplingRate
                    },
                    waveform: fullDisplayIndices.map { samples[$0] }
                ))
                if stride > 1 {
                    warnings.append(
                        "\(channelName), \(segment.label ?? "segment \(segmentIndex + 1)"): time-frequency output was sampled every \(stride) source samples for bounded-memory burst detection."
                    )
                }
            }
        }

        try cancellation.check()
        let uniqueBands = uniqueBandDefinitions(snapshot.bandsByChannel)
        let frequencyRange = (frequencies.first ?? 0)...(frequencies.last ?? 0)
        let summaries = RhythmicBurstDetector.summarize(
            bursts: bursts,
            bands: uniqueBands,
            analyzedDurationSecondsByChannel: analyzedDuration,
            samplingRateHz: snapshot.signal.samplingRate,
            fallbackFrequencyRangeHz: frequencyRange
        )
        progress(RhythmicityProgress(
            fractionComplete: 1,
            phase: .finished,
            channelIndex: nil,
            frequencyHz: nil,
            completedTiles: totalTiles,
            totalTiles: totalTiles
        ))
        return RhythmicBurstAnalysisResult(
            configuration: snapshot.burstConfiguration,
            source: snapshot.source,
            processingProvenance: snapshot.provenance,
            selection: snapshot.selection,
            samplingRateHz: snapshot.signal.samplingRate,
            frequenciesHz: frequencies,
            morletWidthCycles: snapshot.rhythmicityConfiguration.morletWidthCycles,
            wtplLagCycles: snapshot.rhythmicityConfiguration.wtplLagCycles,
            bandSourceDescription: snapshot.bandSourceDescription,
            bandDefinitions: uniqueBands,
            maps: maps,
            bursts: bursts.sorted {
                ($0.channelIndex, $0.peakGlobalSample, $0.peakFrequencyHz)
                    < ($1.channelIndex, $1.peakGlobalSample, $1.peakFrequencyHz)
            },
            summaries: summaries,
            warnings: Array(Set(warnings)).sorted()
        )
    }

    private static func uniqueBandDefinitions(
        _ values: [Int: [RhythmicBurstBandDefinition]]
    ) -> [RhythmicBurstBandDefinition] {
        var seen = Set<String>()
        return values.keys.sorted().flatMap { values[$0] ?? [] }.filter {
            seen.insert($0.id).inserted
        }
    }
}
