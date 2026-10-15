//
//  MovementPCACorrectionTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct MovementPCACorrectionTests {
    private let samplingRate = 250.0

    @Test func continuousRangesIncludeShortTrailingWindow() throws {
        var configuration = MovementPCAConfiguration.default
        configuration.rangeMode = .continuousWindows
        let result = try MovementPCACorrector.analysisRanges(
            sampleCount: 620,
            samplingRate: samplingRate,
            epochSegments: [],
            configuration: configuration
        )

        #expect(result.mode == .continuousWindows)
        #expect(result.ranges == [0..<250, 250..<500, 500..<620])
    }

    @Test func automaticModeUsesInclusiveStoredEpochBoundaries() throws {
        let segments = [
            epoch(start: 10, end: 29, category: "A"),
            epoch(start: 50, end: 74, category: "B")
        ]
        let result = try MovementPCACorrector.analysisRanges(
            sampleCount: 100,
            samplingRate: samplingRate,
            epochSegments: segments,
            configuration: .default
        )

        #expect(result.mode == .epochSegments)
        #expect(result.ranges == [10..<30, 50..<75])
    }

    @Test func storedEpochCorrectionLeavesSamplesOutsideEpochUntouched() throws {
        let data = movementData(sampleCount: 250, movementScale: 180)
        let segment = epoch(start: 50, end: 199, category: "A")
        var configuration = MovementPCAConfiguration.default
        configuration.amplitudeThresholdMicrovolts = 150
        configuration.maximumFactorCount = 4
        let result = try MovementPCACorrector.correct(
            data: data,
            samplingRate: samplingRate,
            epochSegments: [segment],
            configuration: configuration
        )

        #expect(result.diagnostics.resolvedMode == .epochSegments)
        #expect(result.diagnostics.removedFactorCount >= 1)
        for channel in data.indices {
            #expect(Array(result.correctedData[channel][0..<50]) == Array(data[channel][0..<50]))
            #expect(Array(result.correctedData[channel][200..<250]) == Array(data[channel][200..<250]))
        }
    }

    @Test func forcedEpochModeRefusesContinuousInput() {
        var configuration = MovementPCAConfiguration.default
        configuration.rangeMode = .epochSegments
        #expect(throws: MovementPCACorrectionError.noEpochSegments) {
            try MovementPCACorrector.analysisRanges(
                sampleCount: 100,
                samplingRate: samplingRate,
                epochSegments: [],
                configuration: configuration
            )
        }
    }

    @Test func removesLargeSharedMovementFactor() throws {
        let data = movementData(sampleCount: 250, movementScale: 180)
        var configuration = MovementPCAConfiguration.default
        configuration.maximumFactorCount = 4
        configuration.amplitudeThresholdMicrovolts = 150
        let result = try MovementPCACorrector.correct(
            data: data,
            samplingRate: samplingRate,
            configuration: configuration
        )

        #expect(result.diagnostics.analyzedEpochCount == 1)
        #expect(result.diagnostics.affectedEpochCount == 1)
        #expect(result.diagnostics.removedFactorCount >= 1)
        let before = peakToPeak(data[7])
        let after = peakToPeak(result.correctedData[7])
        #expect(after < before * 0.55, "expected movement attenuation, got \(before) -> \(after)")
    }

    @Test func belowThresholdSignalIsBitIdentical() throws {
        let data = movementData(sampleCount: 250, movementScale: 8)
        var configuration = MovementPCAConfiguration.default
        configuration.amplitudeThresholdMicrovolts = 200
        let result = try MovementPCACorrector.correct(
            data: data,
            samplingRate: samplingRate,
            configuration: configuration
        )

        #expect(result.diagnostics.removedFactorCount == 0)
        #expect(result.correctedData == data)
    }

    @Test func excludedChannelRemainsBitIdentical() throws {
        let data = movementData(sampleCount: 250, movementScale: 180)
        var configuration = MovementPCAConfiguration.default
        configuration.amplitudeThresholdMicrovolts = 150
        let result = try MovementPCACorrector.correct(
            data: data,
            samplingRate: samplingRate,
            configuration: configuration,
            excluding: [7]
        )

        #expect(result.correctedData[7] == data[7])
        #expect(result.diagnostics.removedFactorCount >= 1)
    }

    @Test func correctionIsDeterministic() throws {
        let data = movementData(sampleCount: 500, movementScale: 180)
        let first = try MovementPCACorrector.correct(data: data, samplingRate: samplingRate)
        let second = try MovementPCACorrector.correct(data: data, samplingRate: samplingRate)

        #expect(first.correctedData == second.correctedData)
        #expect(first.diagnostics == second.diagnostics)
    }

    @Test func progressReportsBoundedWorkersAndLiveDiagnostics() throws {
        let data = movementData(sampleCount: 750, movementScale: 180)
        let recorder = ProgressRecorder()
        let result = try MovementPCACorrector.correct(
            data: data,
            samplingRate: samplingRate
        ) { update in
            recorder.append(update)
        }
        let updates = recorder.snapshot
        let decompositionUpdates = updates.filter { $0.phase == .decomposing }
        let final = try #require(updates.last)

        #expect(updates.first?.phase == .preparing)
        #expect(decompositionUpdates.map(\.completedRangeCount) == [1, 2, 3])
        #expect(final.phase == .complete)
        #expect(final.fraction == 1)
        #expect(final.completedRangeCount == 3)
        #expect(final.completedSampleCount == 750)
        #expect(final.workerCount == min(3, evaMaxWorkers))
        #expect(final.affectedRangeCount == result.diagnostics.affectedEpochCount)
        #expect(final.skippedRangeCount == result.diagnostics.skippedEpochCount)
        #expect(final.removedFactorCount == result.diagnostics.removedFactorCount)
    }

    @Test func affectedRangesBecomeOnsetAnchoredDurationMarkers() {
        let diagnostics = MovementPCADiagnostics(
            requestedMode: .continuousWindows,
            resolvedMode: .continuousWindows,
            epochs: [
                MovementPCAEpochDiagnostic(
                    sampleRange: 25..<75,
                    usableChannelCount: 8,
                    retainedFactorCount: 2,
                    factors: [
                        MovementPCAFactorDiagnostic(
                            factorIndex: 0,
                            peakToPeakMicrovolts: 247.5,
                            removed: true
                        )
                    ],
                    skippedReason: nil
                ),
                MovementPCAEpochDiagnostic(
                    sampleRange: 75..<125,
                    usableChannelCount: 8,
                    retainedFactorCount: 2,
                    factors: [
                        MovementPCAFactorDiagnostic(
                            factorIndex: 0,
                            peakToPeakMicrovolts: 42,
                            removed: false
                        )
                    ],
                    skippedReason: nil
                )
            ]
        )

        let events = MovementPCAArtifactMarkerBuilder.events(
            from: diagnostics,
            samplingRate: samplingRate
        )

        #expect(events.count == 1)
        #expect(events[0].code == "MOV")
        #expect(events[0].label == "MAAC Movement")
        #expect(events[0].sourceFile == "MAAC-3 Movement PCA")
        #expect(events[0].beginTimeSeconds == 0.1)
        #expect(events[0].durationSeconds == 0.2)
        #expect(events[0].timeAnchor == .onset)
        #expect(events[0].eventDescription?.contains("247.5 µV") == true)
    }

    @Test func markerBuilderRejectsInvalidSamplingRate() {
        let diagnostics = MovementPCADiagnostics(
            requestedMode: .continuousWindows,
            resolvedMode: .continuousWindows,
            epochs: []
        )

        #expect(MovementPCAArtifactMarkerBuilder.events(from: diagnostics, samplingRate: 0).isEmpty)
    }

    @Test func artifactCleanerPreservesUnselectedChannels() {
        let data = movementData(sampleCount: 250, movementScale: 180)
        let signal = SyntheticSignal.make(data, samplingRate: samplingRate)
        var configuration = MovementPCAConfiguration.default
        configuration.amplitudeThresholdMicrovolts = 150
        let artifact = DefinedArtifact(
            type: .movement,
            name: "Movement Artifact",
            eventCode: "MOV",
            events: [],
            selectedChannelIndices: Array(data.indices.dropLast()),
            windowSizeSeconds: 0,
            average: nil,
            topography: nil,
            cleaningMethod: .movementPCA,
            movementPCAConfiguration: configuration
        )

        let cleaned = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: [])
        #expect(cleaned.signal.data[7] == data[7])
        #expect(cleaned.summaries.first?.channelCount == 7)
    }

    @Test func artifactCleanerRunsEventlessMovementDefinitionAndReplaysSettings() throws {
        let data = movementData(sampleCount: 250, movementScale: 180)
        let signal = SyntheticSignal.make(data, samplingRate: samplingRate)
        var configuration = MovementPCAConfiguration.default
        configuration.rangeMode = .continuousWindows
        configuration.amplitudeThresholdMicrovolts = 150
        configuration.maximumFactorCount = 4
        let artifact = DefinedArtifact(
            type: .movement,
            name: "Movement Artifact",
            eventCode: "MOV",
            events: [],
            selectedChannelIndices: Array(data.indices),
            windowSizeSeconds: 0,
            average: nil,
            topography: nil,
            cleaningMethod: .movementPCA,
            movementPCAConfiguration: configuration
        )

        let cleaned = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: [])
        #expect(cleaned.summaries.count == 1)
        #expect(peakToPeak(cleaned.signal.data[7]) < peakToPeak(data[7]) * 0.55)

        let encoded = try ArtifactReplayPayload.encoder().encode(
            ArtifactReplayPayload(artifacts: [artifact])
        )
        let decoded = try ArtifactReplayPayload.decoder().decode(ArtifactReplayPayload.self, from: encoded)
        #expect(decoded.artifacts.first?.movementPCAConfiguration == configuration)
        #expect(decoded.artifacts.first?.events.isEmpty == true)

        let parameters = artifact.processingParameters(prefix: "a")
        #expect(parameters["a.movementPCA.rangeMode"] == MovementPCARangeMode.continuousWindows.rawValue)
        #expect(parameters["a.movementPCA.amplitudeThresholdMicrovolts"] == "150.000000")
        #expect(parameters["a.movementPCA.maximumFactorCount"] == "4")
    }

    private func movementData(sampleCount: Int, movementScale: Double) -> [[Float]] {
        let channelScores = [-1.5, -1.0, -0.55, -0.15, 0.35, 0.8, 1.25, 1.8]
        return channelScores.enumerated().map { channel, score in
            (0..<sampleCount).map { sample in
                let phase = Double(sample % 250)
                let brain = 4 * sin(2 * .pi * phase / Double(31 + channel))
                    + 1.5 * cos(2 * .pi * phase / Double(17 + channel))
                let movement: Double
                switch phase {
                case 70..<90:
                    movement = (phase - 70) / 20
                case 90..<125:
                    movement = 1
                case 125..<150:
                    movement = (150 - phase) / 25
                default:
                    movement = 0
                }
                return Float(brain + score * movementScale * movement)
            }
        }
    }

    private func peakToPeak(_ values: [Float]) -> Float {
        (values.max() ?? 0) - (values.min() ?? 0)
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
        private var updates: [MovementPCAProgress] = []

        func append(_ update: MovementPCAProgress) {
            lock.lock()
            updates.append(update)
            lock.unlock()
        }

        var snapshot: [MovementPCAProgress] {
            lock.lock()
            defer { lock.unlock() }
            return updates
        }
    }
}
