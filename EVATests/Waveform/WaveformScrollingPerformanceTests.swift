//
//  WaveformScrollingPerformanceTests.swift
//  EVATests
//
//  Repeatable high-density scrolling benchmark plus the guard for C1's
//  horizontal LazyVStack regression. The benchmark deliberately isolates
//  stack placement from trace drawing: Instruments already showed Canvas was
//  not the bottleneck, while lazy placement consumed ~30% of wheel-scroll time.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import EVA

@Suite(.serialized)
@MainActor
struct WaveformScrollingPerformanceTests {
    // SwiftUI's AppKit-backed ScrollView is only materialized while its host is
    // attached to a window. Retain the hidden harnesses for the test process:
    // eagerly tearing down their view graphs made AppKit crash after the test.
    private static var retainedHarnesses: [ScrollHarness] = []

    private enum StackStrategy: String {
        case eagerVStack
        case lazyVStackBaseline
    }

    private struct Measurement {
        var milliseconds: Double
        var scrollUpdates: Int
    }

    @Test("64-channel horizontal scrolling benchmark compares eager and lazy placement")
    func benchmarkHighDensityScrolling() throws {
        let eager = try benchmark(strategy: .eagerVStack)
        let lazy = try benchmark(strategy: .lazyVStackBaseline)
        let ratio = lazy.milliseconds / max(eager.milliseconds, 0.001)

        print(
            String(
                format: "Waveform scrolling benchmark — 64 rows, %d offsets: "
                    + "VStack %.2f ms, LazyVStack %.2f ms, lazy/eager %.2fx",
                eager.scrollUpdates,
                eager.milliseconds,
                lazy.milliseconds,
                ratio
            )
        )

        #expect(eager.scrollUpdates == lazy.scrollUpdates)
        #expect(eager.milliseconds.isFinite && eager.milliseconds > 0)
        #expect(lazy.milliseconds.isFinite && lazy.milliseconds > 0)
        // A broad smoke ceiling catches pathological layout invalidation without
        // treating noisy wall-clock timing as the regression guard.
        #expect(eager.milliseconds < 5_000)
    }

    @Test("Horizontal waveform rows remain an eager VStack")
    func guardsHorizontalStackStrategy() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EVA/Waveform/WaveformView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let startMarker = "// PERF-GUARD: horizontal-channel-stack-begin"
        let endMarker = "// PERF-GUARD: horizontal-channel-stack-end"
        let start = try #require(source.range(of: startMarker)?.upperBound)
        let end = try #require(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound)
        let guardedStack = source[start..<end]

        #expect(guardedStack.contains("VStack(alignment:"))
        #expect(!guardedStack.contains("LazyVStack"))
    }

    private func benchmark(strategy: StackStrategy) throws -> Measurement {
        let harness = ScrollHarness(strategy: strategy)
        Self.retainedHarnesses.append(harness)

        let horizontalScrollView = try #require(harness.horizontalScrollView)
        let clipView = horizontalScrollView.contentView
        let maximumOffset = max(
            (horizontalScrollView.documentView?.bounds.width ?? 0) - clipView.bounds.width,
            1
        )
        let offsets = (0..<240).map { step in
            let phase = CGFloat(step % 60) / 59
            let movingForward = (step / 60).isMultiple(of: 2)
            return maximumOffset * (movingForward ? phase : (1 - phase))
        }

        // Warm the hosting/layout path before timing it.
        apply(offsets: Array(offsets.prefix(20)), to: horizontalScrollView, host: harness.host)

        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<5 {
            let start = clock.now
            apply(offsets: offsets, to: horizontalScrollView, host: harness.host)
            samples.append(milliseconds(clock.now - start))
        }
        samples.sort()
        return Measurement(milliseconds: samples[samples.count / 2], scrollUpdates: offsets.count)
    }

    private func apply(
        offsets: [CGFloat],
        to scrollView: NSScrollView,
        host: NSHostingView<WaveformScrollBenchmarkView>
    ) {
        for offset in offsets {
            scrollView.contentView.scroll(to: NSPoint(x: offset, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    @MainActor
    private final class ScrollHarness {
        let host: NSHostingView<WaveformScrollBenchmarkView>
        let window: NSWindow

        init(strategy: StackStrategy) {
            host = NSHostingView(rootView: WaveformScrollBenchmarkView(strategy: strategy))
            host.frame = NSRect(x: 0, y: 0, width: 1_000, height: 640)
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 1_000, height: 640),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }

        var horizontalScrollView: NSScrollView? {
            descendantScrollViews(in: host)
                .filter {
                    let documentWidth = $0.documentView?.bounds.width ?? 0
                    return documentWidth > $0.contentView.bounds.width + 1
                }
                .max {
                    ($0.documentView?.bounds.width ?? 0) < ($1.documentView?.bounds.width ?? 0)
                }
        }

        private func descendantScrollViews(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(descendantScrollViews)
        }
    }

    private struct WaveformScrollBenchmarkView: View {
        let strategy: StackStrategy

        var body: some View {
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 12) {
                    LazyVStack(spacing: 2) {
                        benchmarkRows(width: 100)
                    }
                    .frame(width: 100)

                    ScrollView(.horizontal) {
                        if strategy == .eagerVStack {
                            VStack(spacing: 2) {
                                benchmarkRows(width: 12_000)
                            }
                        } else {
                            LazyVStack(spacing: 2) {
                                benchmarkRows(width: 12_000)
                            }
                        }
                    }
                    .frame(width: 888)
                }
            }
            .frame(width: 1_000, height: 640)
        }

        @ViewBuilder
        private func benchmarkRows(width: CGFloat) -> some View {
            ForEach(0..<64, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index.isMultiple(of: 2) ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(width: width, height: 8)
            }
        }
    }
}
