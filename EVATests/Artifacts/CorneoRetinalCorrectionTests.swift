//
//  CorneoRetinalCorrectionTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct CorneoRetinalCorrectionTests {
    private let samplingRate = 250.0
    private let sampleCount = 1_000

    private var selection: CorneoRetinalChannelSelection {
        CorneoRetinalChannelSelection(
            leftHEOGIndices: [0],
            rightHEOGIndices: [1],
            upperVEOGIndices: [2],
            lowerVEOGIndices: [3],
            analysisIndices: [0, 1, 2, 3, 4, 5]
        )
    }

    private func syntheticData() -> ([[Float]], [Double], [Double]) {
        let horizontalMap = [1.4, -1.2, 0.2, -0.1, 0.8, -0.5]
        let verticalMap = [0.1, -0.1, -1.1, 1.3, 0.7, 0.4]
        let horizontal = (0..<sampleCount).map { sample in
            18 * sin(2 * .pi * Double(sample) / 310)
        }
        let vertical = (0..<sampleCount).map { sample in
            11 * cos(2 * .pi * Double(sample) / 227)
        }
        var data = Array(repeating: [Float](repeating: 0, count: sampleCount), count: horizontalMap.count)
        for channel in data.indices {
            for sample in 0..<sampleCount {
                let brain = channel >= 4 ? 2 * sin(2 * .pi * Double(sample) / 37) : 0
                data[channel][sample] = Float(
                    horizontalMap[channel] * horizontal[sample]
                    + verticalMap[channel] * vertical[sample]
                    + brain
                )
            }
        }
        return (data, horizontal, vertical)
    }

    @Test func removesHorizontalThenVerticalCRDFromContinuousData() throws {
        let (data, horizontal, vertical) = syntheticData()
        let result = try CorneoRetinalCorrector.correct(
            data: data,
            samplingRate: samplingRate,
            selection: selection,
            blinkEvents: []
        )

        let beforeH = correlation(data[4].map(Double.init), horizontal)
        let afterH = correlation(result.correctedData[4].map(Double.init), horizontal)
        let beforeV = correlation(data[4].map(Double.init), vertical)
        let afterV = correlation(result.correctedData[4].map(Double.init), vertical)
        #expect(abs(beforeH) > 0.6)
        // The published horizontal-first/vertical-second sequence accepts
        // attribution when H and V are correlated; require clear reduction,
        // not an orthogonal-projection result the method does not promise.
        #expect(abs(afterH) < abs(beforeH) * 0.75)
        #expect(abs(beforeV) > 0.3)
        #expect(abs(afterV) < 0.08)
        #expect(result.diagnostics.correctedChannelCount == 6)
    }

    @Test func interpolatesPredictorsAcrossBlinkSpans() throws {
        var (data, _, _) = syntheticData()
        let blinkStart = 400
        let blinkEnd = 430
        for channel in data.indices {
            for sample in blinkStart...blinkEnd {
                data[channel][sample] += channel == 2 || channel == 3 ? 700 : 300
            }
        }
        let blink = MFFEvent(
            id: "blink", code: EyeArtifactKind.blink.eventCode,
            beginTimeSeconds: Double(blinkStart) / samplingRate,
            rawBeginTime: "", sourceFile: "test",
            durationSeconds: Double(blinkEnd - blinkStart + 1) / samplingRate,
            timeAnchor: .onset
        )
        var config = CorneoRetinalConfiguration.default
        config.blinkPaddingSeconds = 0
        let result = try CorneoRetinalCorrector.correct(
            data: data,
            samplingRate: samplingRate,
            selection: selection,
            blinkEvents: [blink],
            configuration: config
        )

        #expect(result.diagnostics.blinkSampleCount >= blinkEnd - blinkStart + 1)
        let timeCourse = result.diagnostics.horizontalTimeCourse
        let midpoint = (blinkStart + blinkEnd) / 2
        let expected = (timeCourse[blinkStart - 1] + timeCourse[blinkEnd + 1]) / 2
        #expect(abs(timeCourse[midpoint] - expected) < 1.0)
    }

    @Test func excludedChannelsRemainBitIdentical() throws {
        let (data, _, _) = syntheticData()
        var selected = selection
        selected.analysisIndices = [0, 1, 2, 3, 4, 5]
        let result = try CorneoRetinalCorrector.correct(
            data: data,
            samplingRate: samplingRate,
            selection: selected,
            blinkEvents: [],
            excluding: [5]
        )
        #expect(result.correctedData[5] == data[5])
        #expect(result.diagnostics.correctedChannelCount == 5)
    }

    @Test func artifactCleanerRunsWithoutRejectableEventsAndReplayKeepsMasks() throws {
        let (data, horizontal, _) = syntheticData()
        let signal = SyntheticSignal.make(data, samplingRate: samplingRate)
        let blink = MFFEvent(
            id: "mask", code: EyeArtifactKind.blink.eventCode,
            beginTimeSeconds: 1.0, rawBeginTime: "1.0", sourceFile: "test",
            durationSeconds: 0.12, timeAnchor: .onset
        )
        let artifact = DefinedArtifact(
            type: .corneoRetinal,
            name: "Corneo-Retinal Dipole",
            eventCode: "CRD",
            events: [],
            selectedChannelIndices: selection.analysisIndices,
            windowSizeSeconds: 0,
            average: nil,
            topography: nil,
            cleaningMethod: .corneoRetinalRegression,
            corneoRetinalConfiguration: .default,
            corneoRetinalChannelSelection: selection,
            corneoRetinalBlinkEvents: [blink]
        )

        let cleaned = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: [])
        #expect(cleaned.summaries.count == 1)
        #expect(cleaned.summaries[0].eventCount == 1)
        #expect(abs(correlation(cleaned.signal.data[4].map(Double.init), horizontal))
                < abs(correlation(data[4].map(Double.init), horizontal)))

        let encoded = try ArtifactReplayPayload.encoder().encode(
            ArtifactReplayPayload(artifacts: [artifact])
        )
        let decoded = try ArtifactReplayPayload.decoder().decode(ArtifactReplayPayload.self, from: encoded)
        let restored = try #require(decoded.artifacts.first)
        #expect(restored.events.isEmpty)
        #expect(restored.corneoRetinalBlinkEvents == [blink])
        #expect(restored.corneoRetinalChannelSelection == selection)
        #expect(restored.corneoRetinalConfiguration == .default)

        var formerlyMisclassified = artifact
        formerlyMisclassified.type = .ocular
        #expect(formerlyMisclassified.isCorneoRetinalDefinition)
        #expect(formerlyMisclassified.eventCount == 1)
    }

    @Test func cleaningPreviewUsesCRDBlinkMasksAndReportsContinuousRemoval() throws {
        let (data, _, _) = syntheticData()
        let before = SyntheticSignal.make(data, samplingRate: samplingRate)
        let blink = MFFEvent(
            id: "preview-mask", code: "Eye Blink",
            beginTimeSeconds: 1.5, rawBeginTime: "1.5",
            sourceFile: MAACPreliminaryBlinkDetector.sourceFile,
            durationSeconds: 0.12, timeAnchor: .onset
        )
        let artifact = DefinedArtifact(
            type: .corneoRetinal,
            name: "Corneo-Retinal Dipole",
            eventCode: "CRD",
            events: [],
            selectedChannelIndices: selection.analysisIndices,
            windowSizeSeconds: 0,
            average: nil,
            topography: nil,
            cleaningMethod: .corneoRetinalRegression,
            corneoRetinalConfiguration: .default,
            corneoRetinalChannelSelection: selection,
            corneoRetinalBlinkEvents: [blink]
        )
        let cleaned = ArtifactCleaner.cleanedSignal(from: before, artifacts: [artifact], excluding: []).signal
        let preview = ArtifactCleaningPreview.makePreviewData(
            artifact: artifact,
            beforeSignal: before,
            afterSignal: cleaned
        )

        #expect(preview.beforeAverage?.eventCount == 1)
        #expect(preview.afterAverage?.eventCount == 1)
        #expect((preview.continuousRemovalMetrics?.removedRMSMicrovolts ?? 0) > 0)
        #expect((preview.continuousRemovalMetrics?.removedPeakMicrovolts ?? 0) > 0)
    }

    @Test func legacyConfigurationDecodingKeepsPreliminaryBlinkDefaults() throws {
        let data = Data(#"{"verticalTemplateHorizontalFraction":0.2,"blinkPaddingSeconds":0.05}"#.utf8)
        let decoded = try JSONDecoder().decode(CorneoRetinalConfiguration.self, from: data)
        #expect(decoded.verticalTemplateHorizontalFraction == 0.2)
        #expect(decoded.blinkPaddingSeconds == 0.05)
        #expect(decoded.preliminaryBlink == .default)
    }

    @Test func blinkReviewBoundaryEditsStayOrderedAndInsideRecording() {
        let event = MFFEvent(
            id: "review", code: "Eye Blink", label: "MAAC preliminary blink",
            beginTimeSeconds: 1.0, rawBeginTime: "1.0",
            sourceFile: MAACPreliminaryBlinkDetector.sourceFile,
            durationSeconds: 0.20, timeAnchor: .onset
        )
        var item = CorneoRetinalBlinkReviewItem(event: event, isIncluded: true)

        item.setOnset(1.15, recordingDuration: 3, minimumDuration: 0.01)
        #expect(abs(item.onsetSeconds - 1.15) < 1e-9)
        #expect(abs(item.endSeconds - 1.20) < 1e-9)

        item.setEnd(1.151, recordingDuration: 3, minimumDuration: 0.01)
        #expect(abs(item.endSeconds - 1.16) < 1e-9)

        item.setOnset(-2, recordingDuration: 3, minimumDuration: 0.01)
        item.setEnd(5, recordingDuration: 3, minimumDuration: 0.01)
        #expect(item.onsetSeconds == 0)
        #expect(item.endSeconds == 3)
        #expect(item.event.id == event.id)
        #expect(item.event.timeAnchor == .onset)
    }

    private func correlation(_ x: [Double], _ y: [Double]) -> Double {
        let mx = x.reduce(0, +) / Double(x.count)
        let my = y.reduce(0, +) / Double(y.count)
        var numerator = 0.0
        var xx = 0.0
        var yy = 0.0
        for i in x.indices {
            let dx = x[i] - mx
            let dy = y[i] - my
            numerator += dx * dy
            xx += dx * dx
            yy += dy * dy
        }
        return numerator / sqrt(xx * yy)
    }
}
