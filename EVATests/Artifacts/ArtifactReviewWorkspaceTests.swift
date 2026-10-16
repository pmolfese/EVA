import AppKit
import Observation
import SwiftUI
import XCTest
@testable import EVA

@MainActor
final class ArtifactReviewWorkspaceTests: XCTestCase {
    @Observable @MainActor
    final class Model {
        var artifacts: [DefinedArtifact]
        var selected: UUID?
        var tab = ArtifactTemplateViewModel.WorkspaceTab.review
        init(_ artifacts: [DefinedArtifact]) { self.artifacts = artifacts }
    }
    private static var retainedWindows: [NSWindow] = []

    private struct DefinitionLayoutCase {
        var tab: ArtifactTemplateViewModel.WorkspaceTab = .define
        var panel: ArtifactDefinitionPanel = .waveforms
        var mode: ArtifactTopographyMode = .peak
        var scanStyle: ArtifactTopographyScanStyle = .windowed
        var scope: ArtifactTopographyChannelScope = .allGood
        var dark = false
    }

    func testDefineAndCleanFillWorkspace() throws {
        let planted = SyntheticSignal.plantedBumps(channelCount: 8, count: 1000,
            positions: [100, 300, 500, 700], width: 50, samplingRate: 100)
        let signal = SyntheticSignal.make(planted.data, samplingRate: 100)
        let layouts: [DefinitionLayoutCase] = [
            .init(),
            .init(panel: .topography),
            .init(panel: .topography, mode: .trajectory),
            .init(tab: .clean),
            .init(panel: .topography, scanStyle: .continuous),
            .init(panel: .topography, scope: .topN),
            .init(panel: .topography, scope: .channelSet),
            .init(dark: true)
        ]
        for layout in layouts {
            let tab = layout.tab, panel = layout.panel, mode = layout.mode
            let waveform = WaveformView(
                recording: MFFRecording(packageURL: URL(fileURLWithPath: "/tmp/layout-test.mff")),
                userMarkers: []
            )
            waveform.template.name = "Eye blinks"
            waveform.template.eventCode = "Eye Blink"
            waveform.template.definedArtifacts = [DefinedArtifact(
                type: .ocular, name: "Eye blinks", eventCode: "Eye Blink", events: [],
                selectedChannelIndices: [0], windowSizeSeconds: 0.5,
                average: nil, topography: nil, cleaningMethod: .doNothing
            )]
            waveform.template.workspaceTab = tab
            waveform.template.definitionPanel = panel
            waveform.template.topographyMode = mode
            waveform.template.topographyScanStyle = layout.scanStyle
            waveform.template.topographyChannelScope = layout.scope
            waveform.template.selectionRange = planted.exemplar
            waveform.template.channelScope = .allChannels
            waveform.template.clickedChannel = 0
            waveform.template.windowSeconds = 0.5
            let configuration = ArtifactTemplateConfiguration(
                name: "Eye blinks", eventCode: "Eye Blink", selectedChannelIndices: [0, 1, 2, 3],
                comparisonChannelIndices: Array(0..<8), exemplarRange: planted.exemplar,
                matchThreshold: 0.85, windowSizeSeconds: 0.5, downsampleRate: 100,
                mergeWindowSeconds: 0.35, polarity: .same,
                comparisonScopes: [.init(name: "Clicked Channel", channelIndices: [0]),
                                   .init(name: "Ocular Channels", channelIndices: [0, 1, 2, 3])],
                topographyMode: mode
            )
            waveform.template.result = ArtifactTemplateDetector.detect(in: signal, configuration: configuration)
            let host = NSHostingView(rootView: waveform.artifactTemplateSheet(
                for: signal, reviewSignal: signal, broadbandSignal: signal
            ).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 820),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            Self.retainedWindows.append(window)
            window.appearance = NSAppearance(named: layout.dark ? .darkAqua : .aqua)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 1060, height: 820)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, 1060, accuracy: 1)
            XCTAssertEqual(host.fittingSize.height, 820, accuracy: 1)
            if tab == .define {
                func scrolls(in view: NSView) -> [NSScrollView] {
                    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls(in: $0) }
                }
                let columns = scrolls(in: host).filter { $0.frame.height > 200 && $0.frame.width > 200 }
                XCTAssertGreaterThanOrEqual(columns.count, 2, "Settings and preview must scroll independently")
            }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = NSImage(size: host.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Artifact \(tab.rawValue) \(panel.rawValue) \(mode.rawValue) \(layout.scanStyle.rawValue) \(layout.scope.label) \(layout.dark ? "dark" : "light") layout"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testEighteenTopomapThumbnailsRender() throws {
        let rate = 100.0
        let events = (1...18).map { index in
            MFFEvent(id: "map-\(index)", code: "Eye Blink", beginTimeSeconds: Double(index),
                rawBeginTime: "\(index)", sourceFile: "test", durationSeconds: 0.2, timeAnchor: .peak)
        }
        var rows = Array(repeating: [Float](repeating: 0, count: 2000), count: 6)
        let gains: [Float] = [1, 0.8, 0.3, -0.4, -0.7, -1]
        for index in 1...18 {
            for offset in -20...20 {
                let shape = Float(200 * exp(-pow(Double(offset) / Double(5 + index % 3), 2)))
                for channel in 0..<6 { rows[channel][index * 100 + offset] = gains[channel] * shape }
            }
        }
        let signal = SyntheticSignal.make(rows, samplingRate: rate)
        let artifact = DefinedArtifact(type: .ocular, name: "Blinks", eventCode: "Eye Blink",
            events: events, selectedChannelIndices: [0, 1], windowSizeSeconds: 0.5,
            average: nil, topography: nil, cleaningMethod: .obs)
        let layout = SensorLayout(name: "Review test layout", positions: (0..<6).map { index in
            let angle = Double(index) * .pi / 3
            return SensorPosition(channelIndex: index, x: cos(angle) * 0.8, y: sin(angle) * 0.8)
        })
        let analysis = ArtifactReviewEngine.analyze(artifact: artifact, signal: signal,
            excluding: [], topographyChannelIndices: Set(0..<6))
        XCTAssertEqual(analysis.examples.compactMap(\.topography).count, 18)
        let scale = analysis.examples.compactMap { $0.topography?.maximumAbsoluteAmplitude }.max() ?? 1
        let view = VStack(alignment: .leading, spacing: 8) {
            Text("Topomaps · 18 exemplars · shared scale").font(.caption)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                ForEach(analysis.examples) { example in
                    VStack(spacing: 4) {
                        Text(example.event.centerTimeSeconds, format: .number).font(.caption2)
                        ArtifactReviewTopomapPreview(topography: example.topography, layout: layout, scale: scale)
                            .frame(height: 54)
                        Text("Wave match").font(.caption2)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(Color(nsColor: .textBackgroundColor))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        Self.retainedWindows.append(window)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 680)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Eighteen topomap exemplars"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testWaveformSubgroupPreviewsRender() async throws {
        let rate = 128.0
        var rows = Array(repeating: [Float](repeating: 0, count: 2800), count: 6)
        let gains: [Float] = [1, -0.8, 0.6, -0.4, 0.3, -0.2]
        let events = (1...18).map { index in
            let width = index <= 9 ? 3.5 : 15.0
            for offset in -31...31 {
                let shape = Float(200 * exp(-pow(Double(offset) / width, 2)))
                for channel in 0..<6 { rows[channel][index * 128 + offset] = gains[channel] * shape }
            }
            return MFFEvent(id: "shape-\(index)", code: "Eye Blink", beginTimeSeconds: Double(index),
                rawBeginTime: "\(index)", sourceFile: "test", durationSeconds: 0.2, timeAnchor: .peak)
        }
        let signal = SyntheticSignal.make(rows, samplingRate: rate)
        let artifact = DefinedArtifact(type: .ocular, name: "Blinks", eventCode: "Eye Blink",
            events: events, selectedChannelIndices: Array(0..<6), windowSizeSeconds: 0.5,
            average: nil, topography: nil, cleaningMethod: .obs)
        let result = try await Task.detached {
            let analysis = ArtifactReviewEngine.analyze(artifact: artifact, signal: signal, excluding: [])
            let family = ArtifactSpatialGroup(id: 1, eventIDs: events.map(\.id),
                representativeID: events[0].id, minimumCorrelation: 1)
            let grouped = await ArtifactWaveformGrouping.build(analysis: analysis, family: family, windowSeconds: 0.5)
            return try XCTUnwrap(grouped)
        }.value
        XCTAssertEqual(result.hierarchy.groups(minimumCorrelation: 0.95).count, 2)
        let view = VStack(alignment: .leading, spacing: 12) {
            Text("Waveform subgroups · selected spatial family").font(.headline)
            Text("Same spatial pattern · two temporal widths · preview only").font(.caption)
            ArtifactWaveformSubgroupCards(result: result, threshold: 0.95,
                preferredChannel: 0, selectedGroupID: .constant(nil), onSelect: { _ in })
        }.padding(16).frame(width: 750).background(Color(nsColor: .textBackgroundColor))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        Self.retainedWindows.append(window)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 750, height: 240)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Waveform subgroups within one spatial family"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testWorkspaceRendersRealAnalysis() throws {
        let rate = 100.0
        var row = [Float](repeating: 0, count: 2600)
        let events = (1...24).map { index -> MFFEvent in
            let center = index * 100
            let width = index % 5 == 0 ? 14.0 : 6.0
            for offset in -24...24 {
                row[center + offset] += Float((index % 3 == 0 ? -180.0 : 180.0) * exp(-pow(Double(offset) / width, 2)))
                if index % 7 == 0 { row[center + offset + 18] += Float(110 * exp(-pow(Double(offset) / 7, 2))) }
            }
            return MFFEvent(id: "blink-\(index)", code: "Eye Blink", beginTimeSeconds: Double(index),
                            rawBeginTime: "\(index)", sourceFile: "test", durationSeconds: 0.25, timeAnchor: .peak)
        }
        let signal = SyntheticSignal.make([row, row.map { -$0 }, row.map { $0 * 0.7 },
            row.map { -$0 * 0.4 }, row.map { $0 * 0.2 }, row.map { $0 * 0.15 }], samplingRate: rate)
        let artifact = DefinedArtifact(type: .ocular, name: "Eye blinks", eventCode: "Eye Blink",
            events: events, selectedChannelIndices: [0, 1], windowSizeSeconds: 0.5,
            average: nil, topography: nil, cleaningMethod: .obs)
        let model = Model([artifact])
        let layout = SensorLayout(name: "Spatial review layout", positions: (0..<6).map { index in
            let angle = Double(index) * .pi / 3
            return SensorPosition(channelIndex: index, x: cos(angle) * 0.8, y: sin(angle) * 0.8)
        })
        let review = ArtifactReviewWorkspace(
            artifacts: Binding(get: { model.artifacts }, set: { model.artifacts = $0 }),
            selectedArtifactID: Binding(get: { model.selected }, set: { model.selected = $0 }),
            signal: signal, excludedChannels: [], sensorLayoutName: layout.name, sensorLayout: layout,
            onChange: {}, onClose: {}, onClean: {})
        let view = ArtifactWorkspace(
            tab: Binding(get: { model.tab }, set: { model.tab = $0 }), isBusy: false
        ) {
            switch model.tab {
            case .define:
                ScrollView { Text("Definition options").frame(width: 760, height: 1200) }
            case .review:
                review
            case .clean:
                ScrollView { Text("Cleaning settings").frame(width: 800, height: 400) }
            }
        }
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 820),
                              styleMask: [.titled], backing: .buffered, defer: false)
        Self.retainedWindows.append(window)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1060, height: 820)
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(3)
        while model.artifacts[0].reviewState == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNotNil(model.artifacts[0].reviewState, "The native review task should prepare the candidate pool")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Artifact similarity review"
        attachment.lifetime = .keepAlways
        add(attachment)
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        if let scroll = scrollViews(in: host).max(by: {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        }) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 520))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            let detailBitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: detailBitmap)
            let detailImage = NSImage(size: host.bounds.size)
            detailImage.addRepresentation(detailBitmap)
            let detailAttachment = XCTAttachment(image: detailImage)
            detailAttachment.name = "Multi-channel contextual event"
            detailAttachment.lifetime = .keepAlways
            add(detailAttachment)
        }
        XCTAssertEqual(model.artifacts[0].reviewState?.candidates.count, 24)
        XCTAssertEqual(host.bounds.width, 1060, accuracy: 1)
        // Tall Define options and a short Clean form must not change the shell's
        // preferred size or shift its top-level navigation.
        let reviewSize = host.fittingSize
        for tab in [ArtifactTemplateViewModel.WorkspaceTab.define, .clean, .review] {
            model.tab = tab
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, reviewSize.width, accuracy: 1)
            XCTAssertEqual(host.fittingSize.height, reviewSize.height, accuracy: 1)
        }
    }
}
