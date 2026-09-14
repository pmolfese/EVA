//
//  MuscleBSSCCACorrectionTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct MuscleBSSCCACorrectionTests {
    private let samplingRate = 250.0

    @Test func continuousRangesOverlapAndCoverTheTail() throws {
        var configuration = MuscleBSSCCAConfiguration.default
        configuration.rangeMode = .continuousWindows
        let result = try MuscleBSSCCACorrector.analysisRanges(
            sampleCount: 6_500,
            samplingRate: samplingRate,
            epochSegments: [],
            configuration: configuration
        )

        #expect(result.mode == .continuousWindows)
        #expect(result.ranges == [0..<2_500, 1_250..<3_750, 2_500..<5_000, 3_750..<6_250, 4_000..<6_500])
    }

    @Test func automaticModeUsesInclusiveStoredEpochBoundaries() throws {
        let segments = [
            epoch(start: 10, end: 509, category: "A"),
            epoch(start: 700, end: 1_199, category: "B")
        ]
        let result = try MuscleBSSCCACorrector.analysisRanges(
            sampleCount: 1_500,
            samplingRate: samplingRate,
            epochSegments: segments,
            configuration: .default
        )

        #expect(result.mode == .epochSegments)
        #expect(result.ranges == [10..<510, 700..<1_200])
    }

    @Test func refusesInsufficientBandwidth() {
        #expect(throws: MuscleBSSCCAError.insufficientBandwidth(requiredHz: 30, nyquistHz: 25)) {
            try MuscleBSSCCACorrector.correct(
                data: [[Float](repeating: 0, count: 100), [Float](repeating: 0, count: 100), [Float](repeating: 0, count: 100)],
                samplingRate: 50
            )
        }
    }

    @Test func removesSeparatedHighFrequencySourceAndPreservesBrain() throws {
        let fixture = mixedFixture(sampleCount: 2_500)
        let result = try MuscleBSSCCACorrector.correct(
            data: fixture.contaminated,
            samplingRate: samplingRate
        )

        #expect(result.diagnostics.removedComponentCount >= 1)
        let beforeError = rmsDifference(fixture.contaminated[0], fixture.clean[0])
        let afterError = rmsDifference(result.correctedData[0], fixture.clean[0])
        #expect(afterError < beforeError * 0.35, "expected EMG attenuation, got error \(beforeError) -> \(afterError)")
        #expect(correlation(result.correctedData[0], fixture.clean[0]) > 0.95)
    }

    @Test func operatorEstimatedAt250HzAppliesToNativeRateSamples() throws {
        let nativeRate = 1_000.0
        let fixture = mixedFixture(sampleCount: 4_000, rate: nativeRate)
        let result = try MuscleBSSCCACorrector.correct(
            data: fixture.contaminated,
            samplingRate: nativeRate
        )

        #expect(result.diagnostics.windows.first?.analysisSamplingRate == 250)
        let beforeError = rmsDifference(fixture.contaminated[0], fixture.clean[0])
        let afterError = rmsDifference(result.correctedData[0], fixture.clean[0])
        #expect(afterError < beforeError * 0.4)
    }

    @Test func excludedChannelIsBitIdentical() throws {
        let fixture = mixedFixture(sampleCount: 2_500)
        let result = try MuscleBSSCCACorrector.correct(
            data: fixture.contaminated,
            samplingRate: samplingRate,
            excluding: [5]
        )

        #expect(result.correctedData[5] == fixture.contaminated[5])
        #expect(result.diagnostics.removedComponentCount >= 1)
    }

    @Test func lowFrequencyOnlySignalIsBitIdentical() throws {
        let data = lowFrequencyBackground(channelCount: 8, sampleCount: 2_500).map { $0.map(Float.init) }
        let result = try MuscleBSSCCACorrector.correct(data: data, samplingRate: samplingRate)

        #expect(result.diagnostics.removedComponentCount == 0)
        #expect(result.correctedData == data)
    }

    @Test func correctionIsDeterministic() throws {
        let data = mixedFixture(sampleCount: 2_500).contaminated
        let first = try MuscleBSSCCACorrector.correct(data: data, samplingRate: samplingRate)
        let second = try MuscleBSSCCACorrector.correct(data: data, samplingRate: samplingRate)

        #expect(first.correctedData == second.correctedData)
        #expect(first.diagnostics == second.diagnostics)
    }

    @Test func progressReportsEachWindowAndLiveClassificationMetrics() throws {
        let data = mixedFixture(sampleCount: 5_000).contaminated
        let recorder = ProgressRecorder()
        let diagnostics = try MuscleBSSCCACorrector.analyze(
            data: data,
            samplingRate: samplingRate
        ) { update in
            recorder.append(update)
        }
        let updates = recorder.snapshot
        let decompositionUpdates = updates.filter { $0.phase == .decomposing }
        let final = try #require(updates.last)

        #expect(updates.first?.phase == .preparing)
        #expect(decompositionUpdates.map(\.completedWindowCount) == [1, 2, 3])
        #expect(final.phase == .complete)
        #expect(final.fraction == 1)
        #expect(final.completedWindowCount == 3)
        #expect(final.completedSampleCount == 7_500)
        #expect(final.analyzedWindowCount == diagnostics.analyzedWindowCount)
        #expect(final.affectedWindowCount == diagnostics.affectedWindowCount)
        #expect(final.skippedWindowCount == diagnostics.skippedWindowCount)
        #expect(final.selectedComponentCount == diagnostics.removedComponentCount)
        #expect(final.classifiedComponentCount == diagnostics.windows.reduce(0) { $0 + $1.components.count })
    }

    @Test func selectedWindowsBecomeOnsetAnchoredDurationMarkers() {
        let diagnostics = MuscleBSSCCADiagnostics(
            requestedMode: .continuousWindows,
            resolvedMode: .continuousWindows,
            windows: [
                MuscleBSSCCAWindowDiagnostic(
                    sampleRange: 25..<75,
                    usableChannelCount: 8,
                    analysisSamplingRate: samplingRate,
                    components: [
                        MuscleBSSCCAComponentDiagnostic(
                            componentIndex: 2,
                            canonicalCorrelation: 0.2,
                            lagOneAutocorrelation: 0.18,
                            emgToEEGPowerRatio: 0.35,
                            automaticallyRemoved: true,
                            removed: true,
                            wasOverridden: false
                        )
                    ],
                    skippedReason: nil
                ),
                MuscleBSSCCAWindowDiagnostic(
                    sampleRange: 75..<125,
                    usableChannelCount: 8,
                    analysisSamplingRate: samplingRate,
                    components: [
                        MuscleBSSCCAComponentDiagnostic(
                            componentIndex: 1,
                            canonicalCorrelation: 0.9,
                            lagOneAutocorrelation: 0.88,
                            emgToEEGPowerRatio: 0.02,
                            automaticallyRemoved: false,
                            removed: false,
                            wasOverridden: false
                        )
                    ],
                    skippedReason: nil
                )
            ]
        )

        let events = MuscleBSSCCAArtifactMarkerBuilder.events(
            from: diagnostics,
            samplingRate: samplingRate
        )

        #expect(events.count == 1)
        #expect(events[0].code == "EMG")
        #expect(events[0].label == "MAAC Muscle")
        #expect(events[0].sourceFile == "MAAC-4 Muscle BSS-CCA")
        #expect(events[0].beginTimeSeconds == 0.1)
        #expect(events[0].durationSeconds == 0.2)
        #expect(events[0].timeAnchor == .onset)
        #expect(events[0].eventDescription?.contains("largest EMG/EEG ratio 0.350") == true)
    }

    @Test func markerBuilderRejectsInvalidSamplingRate() {
        let diagnostics = MuscleBSSCCADiagnostics(
            requestedMode: .continuousWindows,
            resolvedMode: .continuousWindows,
            windows: []
        )

        #expect(MuscleBSSCCAArtifactMarkerBuilder.events(from: diagnostics, samplingRate: 0).isEmpty)
    }

    @Test func manualKeepOverridesAutomaticSuggestions() throws {
        let data = mixedFixture(sampleCount: 2_500).contaminated
        let analyzed = try MuscleBSSCCACorrector.analyze(data: data, samplingRate: samplingRate)
        let suggestions = analyzed.windows.flatMap { window in
            window.components.filter(\.automaticallyRemoved).map {
                MuscleBSSCCAComponentOverride(
                    rangeStartSample: window.sampleRange.lowerBound,
                    componentIndex: $0.componentIndex,
                    removes: false
                )
            }
        }
        #expect(!suggestions.isEmpty)
        var configuration = MuscleBSSCCAConfiguration.default
        configuration.componentOverrides = suggestions
        let result = try MuscleBSSCCACorrector.correct(
            data: data,
            samplingRate: samplingRate,
            configuration: configuration
        )

        #expect(result.diagnostics.removedComponentCount == 0)
        #expect(result.correctedData == data)
    }

    @Test func artifactCleanerRunsEventlessDefinitionAndReplaysSettings() throws {
        let data = mixedFixture(sampleCount: 2_500).contaminated
        let signal = SyntheticSignal.make(data, samplingRate: samplingRate)
        var configuration = MuscleBSSCCAConfiguration.default
        configuration.rangeMode = .continuousWindows
        configuration.componentOverrides = [
            MuscleBSSCCAComponentOverride(rangeStartSample: 0, componentIndex: 2, removes: true)
        ]
        let artifact = makeArtifact(name: "Muscle", method: .bssCCA, configuration: configuration)

        let cleaned = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: [5])
        #expect(cleaned.summaries.count == 1)
        #expect(cleaned.signal.data[5] == data[5])

        let encoded = try ArtifactReplayPayload.encoder().encode(ArtifactReplayPayload(artifacts: [artifact]))
        let decoded = try ArtifactReplayPayload.decoder().decode(ArtifactReplayPayload.self, from: encoded)
        #expect(decoded.artifacts.first?.muscleBSSCCAConfiguration == configuration)
        #expect(decoded.artifacts.first?.events.isEmpty == true)

        let parameters = artifact.processingParameters(prefix: "a")
        #expect(parameters["a.muscleBSSCCA.rangeMode"] == MuscleBSSCCARangeMode.continuousWindows.rawValue)
        #expect(parameters["a.muscleBSSCCA.minimumEMGToEEGPowerRatio"] == "0.142857")
        #expect(parameters["a.muscleBSSCCA.componentOverrides"] == "0:2:1")
    }

    @Test func artifactCleanerRefusesAnAlreadyLowPassedSignal() {
        let data = mixedFixture(sampleCount: 2_500).contaminated
        let signal = SyntheticSignal.make(data, samplingRate: samplingRate)
        let artifact = makeArtifact(name: "Muscle", method: .bssCCA, configuration: .default)
        let cleaned = ArtifactCleaner.cleanedSignal(
            from: signal,
            artifacts: [artifact],
            excluding: [],
            availableBandwidthHz: 20
        )

        #expect(cleaned.summaries.isEmpty)
        #expect(cleaned.signal.data == data)
    }

    @Test func standalonePreservesOrderAndMAACOrdersMovementBeforeMuscle() {
        let muscle = makeArtifact(name: "Muscle", method: .bssCCA)
        let generic = makeArtifact(name: "Generic", method: .regression)
        let movement = makeArtifact(name: "Movement", method: .movementPCA)
        let crd = makeArtifact(name: "CRD", method: .corneoRetinalRegression)
        let spike = makeArtifact(name: "Spike", method: .spikeTemplate)
        let input = [muscle, generic, movement, crd, spike]

        #expect(ArtifactCleaner.orderedArtifacts(input, ordering: .asDefined).map(\.name) == input.map(\.name))
        #expect(ArtifactCleaner.orderedArtifacts(input, ordering: .maac).map(\.name) == ["Spike", "CRD", "Generic", "Movement", "Muscle"])
    }

    @Test func simulatorEMGTruthIsAttenuated() throws {
        let channelCount = 20
        let duration = 30.0
        let montage = Montage.standard(count: channelCount)
        var options = SourceSimulatorArtifacts.Options()
        options.emg = true
        options.emgAmplitudeMicrovolts = 70
        options.emgBurstsPerMinute = 30
        options.seed = 91
        let injection = SourceSimulatorArtifacts.inject(
            montage: montage,
            channelCount: channelCount,
            samplingRate: samplingRate,
            durationSeconds: duration,
            options: options
        )
        #expect(!injection.truth.emgBurstSeconds.isEmpty)
        let clean = lowFrequencyBackground(channelCount: channelCount, sampleCount: injection.channels[0].count)
        let contaminated = zip(clean, injection.channels).map { cleanChannel, artifactChannel in
            zip(cleanChannel, artifactChannel).map { Float($0 + $1) }
        }
        let cleanFloat = clean.map { $0.map(Float.init) }
        let result = try MuscleBSSCCACorrector.correct(data: contaminated, samplingRate: samplingRate)
        let strongest = injection.channels.indices.max {
            rms(injection.channels[$0]) < rms(injection.channels[$1])
        } ?? 0

        let before = rmsDifference(contaminated[strongest], cleanFloat[strongest])
        let after = rmsDifference(result.correctedData[strongest], cleanFloat[strongest])
        #expect(result.diagnostics.removedComponentCount >= 1)
        #expect(after < before * 0.75, "expected simulator EMG attenuation, got \(before) -> \(after)")
    }

    private func mixedFixture(
        sampleCount: Int,
        rate: Double? = nil
    ) -> (clean: [[Float]], contaminated: [[Float]]) {
        let rate = rate ?? samplingRate
        let mixing = [
            [1.0, 0.2, 0.1, 1.0],
            [0.7, -0.4, 0.3, 0.7],
            [-0.2, 0.9, 0.4, 0.25],
            [0.3, 0.1, -0.8, 0.1],
            [-0.6, 0.4, 0.5, 0.5],
            [0.2, -0.5, 0.7, 0.8]
        ]
        var clean = [[Float]](repeating: [Float](repeating: 0, count: sampleCount), count: mixing.count)
        var contaminated = clean
        for sample in 0..<sampleCount {
            let t = Double(sample) / rate
            let sources = [
                9 * sin(2 * .pi * 4.7 * t),
                6 * sin(2 * .pi * 8.3 * t + 0.4),
                4 * sin(2 * .pi * 12.1 * t + 1.1),
                24 * sin(2 * .pi * 21.7 * t + 0.2) + 15 * sin(2 * .pi * 27.1 * t + 0.9)
            ]
            for channel in mixing.indices {
                let brain = (0..<3).reduce(0.0) { $0 + mixing[channel][$1] * sources[$1] }
                clean[channel][sample] = Float(brain)
                contaminated[channel][sample] = Float(brain + mixing[channel][3] * sources[3])
            }
        }
        return (clean, contaminated)
    }

    private func lowFrequencyBackground(channelCount: Int, sampleCount: Int) -> [[Double]] {
        (0..<channelCount).map { channel in
            (0..<sampleCount).map { sample in
                let t = Double(sample) / samplingRate
                return 6 * sin(2 * .pi * (4 + Double(channel % 5)) * t + Double(channel) * 0.17)
                    + 2 * cos(2 * .pi * (9 + Double(channel % 3)) * t)
            }
        }
    }

    private func makeArtifact(
        name: String,
        method: ArtifactCleaningMethod,
        configuration: MuscleBSSCCAConfiguration? = nil
    ) -> DefinedArtifact {
        DefinedArtifact(
            type: method == .bssCCA ? .muscle : .other,
            name: name,
            eventCode: "TEST",
            events: [],
            selectedChannelIndices: [],
            windowSizeSeconds: 0,
            average: nil,
            topography: nil,
            cleaningMethod: method,
            muscleBSSCCAConfiguration: configuration
        )
    }

    private func rmsDifference(_ first: [Float], _ second: [Float]) -> Double {
        sqrt(zip(first, second).reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) } / Double(first.count))
    }

    private func rms(_ values: [Double]) -> Double {
        sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(max(values.count, 1)))
    }

    private func correlation(_ first: [Float], _ second: [Float]) -> Double {
        let x = first.map(Double.init)
        let y = second.map(Double.init)
        let mx = x.reduce(0, +) / Double(x.count)
        let my = y.reduce(0, +) / Double(y.count)
        let numerator = zip(x, y).reduce(0.0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let xx = x.reduce(0.0) { $0 + pow($1 - mx, 2) }
        let yy = y.reduce(0.0) { $0 + pow($1 - my, 2) }
        return numerator / sqrt(xx * yy)
    }

    private func epoch(start: Int, end: Int, category: String) -> EpochSegment {
        EpochSegment(
            startSample: start,
            endSample: end,
            stimulusOffsetSamples: 0,
            category: category,
            sourceCode: category,
            sourceTimeSeconds: Double(start) / samplingRate,
            colorIndex: 0,
            contributingEpochCount: 1
        )
    }

    private nonisolated final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var updates: [MuscleBSSCCAProgress] = []

        func append(_ update: MuscleBSSCCAProgress) {
            lock.lock()
            updates.append(update)
            lock.unlock()
        }

        var snapshot: [MuscleBSSCCAProgress] {
            lock.lock()
            defer { lock.unlock() }
            return updates
        }
    }
}
