import AppKit
import SwiftUI
import Combine
import Testing
@testable import EVA

@Suite(.serialized)
@MainActor
struct WaveformDensityScrollingTests {
    // Keep window-backed SwiftUI graphs alive through test-process teardown,
    // as in WaveformScrollingPerformanceTests.
    private static var retainedHarnesses: [Harness] = []

    @Test("Labels and traces stay aligned when density changes at the bottom")
    func densityChangesAtBottom() throws {
        for rowCount in [129, 257] {
            let harness = Harness(rowCount: rowCount)
            Self.retainedHarnesses.append(harness)
            harness.settle()
            let vertical = try #require(harness.scrollViews(in: harness.host).max {
                ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
            })
            let document = try #require(vertical.documentView)
            vertical.contentView.scroll(to: NSPoint(
                x: 0,
                y: max(0, document.frame.height - vertical.contentView.bounds.height)
            ))
            vertical.reflectScrolledClipView(vertical.contentView)
            harness.settle()

            for mode in [WaveformDensityMode.fixed(32), .fixed(64), .fixed(16), .fixed(32), .fit, .fixed(32)] {
                harness.model.mode = mode
                harness.settle()
                for index in 0..<rowCount {
                    let label = try #require(harness.model.positions["label\(index)"])
                    let trace = try #require(harness.model.positions["trace\(index)"])
                    #expect(abs(label - trace) < 0.5)
                }
                let finalRow = try #require(harness.model.positions["label\(rowCount - 1)"])
                #expect(finalRow > 0 && finalRow < harness.host.bounds.height)
            }
        }
    }

    @Test("Production label and trace columns both use eager placement")
    func productionUsesMatchingStacks() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("EVA/Waveform/WaveformView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try #require(source.range(of: "private func waveformArea(")?.lowerBound)
        let end = try #require(source.range(of: "// Pinned physio", range: start..<source.endIndex)?.lowerBound)
        let columns = source[start..<end]
        #expect(!columns.contains("LazyVStack(alignment:"))
        #expect(columns.components(separatedBy: "VStack(alignment: .leading, spacing: rowSpacing)").count == 3)
    }

    @MainActor
    private final class Model: ObservableObject {
        @Published var mode: WaveformDensityMode = .fixed(16)
        var positions: [String: CGFloat] = [:]
    }

    private struct Positions: PreferenceKey {
        static var defaultValue: [String: CGFloat] { [:] }
        static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }

    private struct Columns: View {
        @ObservedObject var model: Model
        let rowCount: Int

        var body: some View {
            let geometry = WaveformDensityLayout.geometry(mode: model.mode, viewportHeight: 720)
            let height = WaveformDensityLayout.stackHeight(rowCount: rowCount, geometry: geometry)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: geometry.rowSpacing) {
                        rows("label", width: 100, height: geometry.rowHeight)
                    }
                    .frame(width: 100, height: height, alignment: .topLeading)
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: geometry.rowSpacing) {
                            rows("trace", width: 1_200, height: geometry.rowHeight)
                        }
                        .frame(height: height, alignment: .top)
                    }
                    .frame(height: height, alignment: .top)
                    .defaultScrollAnchor(.top, for: .sizeChanges)
                }
                .padding(.bottom, model.mode == .fit ? 16 : 0)
            }
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onPreferenceChange(Positions.self) { model.positions = $0 }
        }

        private func rows(_ column: String, width: CGFloat, height: CGFloat) -> some View {
            ForEach(0..<rowCount, id: \.self) { index in
                Text("\(index)")
                    .frame(width: width, height: height)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: Positions.self,
                                value: ["\(column)\(index)": proxy.frame(in: .global).midY]
                            )
                        }
                    }
            }
        }
    }

    @MainActor
    private final class Harness {
        let model = Model()
        let host: NSHostingView<Columns>
        let window: NSWindow

        init(rowCount: Int) {
            _ = NSApplication.shared
            host = NSHostingView(rootView: Columns(model: model, rowCount: rowCount))
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 1_000, height: 720),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.contentView = host
        }

        func settle() {
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
        }

        func scrollViews(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap { scrollViews(in: $0) }
        }
    }
}
