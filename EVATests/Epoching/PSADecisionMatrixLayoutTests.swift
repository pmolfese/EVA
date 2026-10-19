import AppKit
import SwiftUI
import XCTest
@testable import EVA

@MainActor
final class PSADecisionMatrixLayoutTests: XCTestCase {
    private static var retainedWindows: [NSWindow] = []

    func testCompactCellInspectorFitsFloatingAndSheetLayouts() async throws {
        let epochCount = 24
        let channelCount = 16
        let samplesPerEpoch = 50
        let signal = SyntheticSignal.make((0..<channelCount).map { channel in
            SyntheticSignal.sine(frequency: Double(8 + channel % 4), samplingRate: 100,
                                 count: epochCount * samplesPerEpoch)
        }, samplingRate: 100)
        let segments = (0..<epochCount).map { epoch in
            EpochSegment(startSample: epoch * samplesPerEpoch,
                         endSample: (epoch + 1) * samplesPerEpoch - 1,
                         stimulusOffsetSamples: 10, category: ["LC++", "LI++", "RC++", "RI++"][epoch % 4],
                         sourceCode: "stim", sourceTimeSeconds: Double(epoch) * 0.5,
                         colorIndex: epoch % 4, contributingEpochCount: 1)
        }
        let artifacts: [PSAArtifactEventDetail] = (0..<6).map { index -> PSAArtifactEventDetail in
            let method: String? = index == 0 ? "OBS" : nil
            return PSAArtifactEventDetail(eventID: "blink-\(index)", label: "Eye Blink", code: "blink",
                                   relativeTimeSeconds: Double(index) * 0.08, hasCorrection: index == 0,
                                   isCorrected: index == 0, method: method,
                                   inputRMSMicrovolts: nil, outputRMSMicrovolts: nil, rmsChangeFraction: nil)
        }
        let preparation = PSADecisionMatrixPreparation.make(
            signal: signal, segments: segments, thresholds: EpochBadChannelThresholds(),
            detectorSegments: [:], recordingChannelGoodness: [:], electrodePositions: [:],
            globallyBadChannels: [], segmentHealthGoodnessScores: Array(repeating: 50, count: epochCount),
            suggestedRejectedEpochReasons: [0: ["Eye Blink"]], artifactEventsByEpoch: [0: artifacts]
        )

        for (width, height, floating, dark, selection) in [(760.0, 480.0, true, false, "cell"),
                                                (900.0, 560.0, true, true, "cell"),
                                                (1320.0, 820.0, false, false, "cell"),
                                                (900.0, 560.0, true, false, "epoch"),
                                                (900.0, 560.0, true, true, "channel")] {
            let model = PSADecisionMatrixModel(preparation: preparation)
            switch selection {
            case "epoch": model.selectEpochs([0])
            case "channel": model.selectChannels([5])
            default: model.selectCell(.init(channelIndex: 5, epochIndex: 0))
            }
            let view = PSADecisionMatrixView(
                model: model, isApplying: false, isRunningFullChannelHealth: false,
                allowsFullHealthUpgrade: false, fallbackMessage: "", progress: nil, progressMessage: nil,
                onBack: {}, onCancel: {}, onRunFullChannelHealth: {}, onAverage: {}, isFloating: floating
            )
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            host.sizingOptions = []
            let bounds = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
            Self.retainedWindows.append(window)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.frame = bounds
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()

            func scrolls(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls(in: $0) }
            }
            let details = try XCTUnwrap(scrolls(in: host).first { $0.frame.height > 100 })
            XCTAssertLessThanOrEqual(details.frame.width, 300, "Details must leave room for the matrix")
            XCTAssertEqual(host.frame.width, width, accuracy: 1)
            XCTAssertEqual(host.frame.height, height, accuracy: 1)
            XCTAssertTrue(window.childWindows?.isEmpty ?? true, "Cell details must not open a popover")

            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = NSImage(size: host.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Compact matrix \(Int(width))x\(Int(height)) \(dark ? "dark" : "light") \(selection)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
