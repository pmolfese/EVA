//
//  HistoryRailRenderTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Renders the History rail headlessly through `ImageRenderer` and asserts the
//  result is a plausible image. Two things this buys that the derivation tests
//  do not:
//
//  1. **The view actually builds and lays out.** A row that collapses to zero
//     height fails here rather than at first sight in the app.
//  2. **A PNG to look at** without screen-recording permission, which the UI test
//     bundle and `screencapture` both need and neither reliably has on this
//     machine. The file is written to the test container and its path is
//     printed, so it can be opened after a run.
//
//  **`ImageRenderer` renders nothing inside a `ScrollView`.** A render of the
//  whole `HistoryRailView` shows its header and footer with empty space between
//  them, which looks exactly like every row having collapsed. That is why the
//  node stack is its own view (`HistoryRailNodeList`) and why the row assertions
//  target it directly — the chrome and the content are checked separately
//  because only one of them survives the renderer.
//
//  This is not a snapshot test — there is no golden image to drift against. It
//  asserts size and that the render is not blank, which catches real breakage
//  without failing on every font or accent-colour change.
//

import Testing
import Foundation
import SwiftUI
import AppKit
@testable import EVA

@MainActor
struct HistoryRailRenderTests {

    private var sampleNodes: [HistoryRailNode] {
        [
            HistoryRailNode(id: "a0", title: "raw",
                            subtitle: "128 ch · 1000 Hz · 21:04",
                            isCurrent: false, isPinned: false),
            HistoryRailNode(id: "a1", title: "gradient correction",
                            subtitle: "FASTR · 30 donors · ANC",
                            isCurrent: false, isPinned: true),
            HistoryRailNode(id: "a2", title: "ICA",
                            subtitle: "picard · 20 components · avg ref",
                            isCurrent: false, isPinned: false),
            HistoryRailNode(id: "a3", title: "filter",
                            subtitle: "0.1–40 Hz · 60 Hz notch",
                            isCurrent: false, isPinned: false),
            HistoryRailNode(id: "a4", title: "segment",
                            subtitle: "4 conditions · −100–600 ms · averaged",
                            isCurrent: true, isPinned: false)
        ]
    }

    private func render(_ view: some View, width: CGFloat, height: CGFloat) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content:
            view.frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "ImageRenderer produced no image")
        let data = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: data))
    }

    /// The load-bearing one: every node draws something. A row that collapsed to
    /// zero height would leave a clean, empty column that looks intentional.
    @Test func everyNodeRowDrawsSomething() throws {
        let bitmap = try render(
            HistoryRailNodeList(nodes: sampleNodes),
            width: 260, height: 220
        )
        #expect(bitmap.pixelsWide == 520)   // 260 pt at 2×

        let inked = inkedRowCount(in: bitmap, topFraction: 0, bottomFraction: 1)
        #expect(inked > 150, "the node stack looks blank — only \(inked) inked scanlines")

        // Ink spread across the whole stack, not bunched at the top: five rows
        // that all collapsed onto one would still ink plenty of scanlines.
        let topHalf = inkedRowCount(in: bitmap, topFraction: 0.05, bottomFraction: 0.5)
        let bottomHalf = inkedRowCount(in: bitmap, topFraction: 0.5, bottomFraction: 0.95)
        #expect(topHalf > 40, "nothing in the top half")
        #expect(bottomHalf > 40, "nothing in the bottom half — rows are not distributing")

        try write(bitmap, named: "history-rail-nodes")
    }

    /// An unprocessed recording shows the root alone, where the connector has
    /// neither a segment above nor below.
    @Test func rootOnlyStackRenders() throws {
        let root = [HistoryRailNode(id: "a0", title: "raw",
                                    subtitle: "128 ch · 1000 Hz · 21:04",
                                    isCurrent: true, isPinned: false)]
        let bitmap = try render(HistoryRailNodeList(nodes: root), width: 260, height: 60)
        #expect(inkedRowCount(in: bitmap, topFraction: 0, bottomFraction: 1) > 20)
        try write(bitmap, named: "history-rail-root-only")
    }

    /// Long subtitles must wrap inside the rail rather than forcing it wider.
    @Test func longSubtitlesStayInsideTheRail() throws {
        let wordy = [
            HistoryRailNode(id: "a0", title: "raw", subtitle: "256 ch · 1000 Hz · 1:04:22",
                            isCurrent: false, isPinned: false),
            HistoryRailNode(id: "a1", title: "segment",
                            subtitle: "12 conditions · −200–1200 ms · on artifacts · averaged",
                            isCurrent: true, isPinned: false)
        ]
        let bitmap = try render(HistoryRailNodeList(nodes: wordy), width: 260, height: 120)
        #expect(bitmap.pixelsWide == 520, "the rail must not be widened by its content")
        #expect(inkedRowCount(in: bitmap, topFraction: 0.5, bottomFraction: 1) > 20,
                "the wrapped subtitle should occupy the lower half")
        try write(bitmap, named: "history-rail-wrapping")
    }

    // MARK: - The popover the rail lives in

    /// Tab bar and footer, rendered as part of the whole popover. The node stack
    /// between them is empty here for the reason in the file header — the
    /// renderer drops `ScrollView` content — so this checks the chrome only.
    @Test func popoverChromeRendersOnTheHistoryTab() throws {
        let bitmap = try render(popover(tab: .history), width: 460, height: 420)
        #expect(bitmap.pixelsWide == 920)
        #expect(bitmap.pixelsHigh == 840)
        #expect(inkedRowCount(in: bitmap, topFraction: 0, bottomFraction: 0.10) > 15,
                "tab bar did not render")
        #expect(inkedRowCount(in: bitmap, topFraction: 0.93, bottomFraction: 1) > 8,
                "history footer did not render")
        try write(bitmap, named: "status-popover-history")
    }

    @Test func popoverRendersTheQueueTab() throws {
        let bitmap = try render(popover(tab: .queue), width: 460, height: 420)
        #expect(bitmap.pixelsWide == 920)
        #expect(inkedRowCount(in: bitmap, topFraction: 0, bottomFraction: 0.10) > 15,
                "tab bar did not render")
        try write(bitmap, named: "status-popover-queue")
    }

    /// The queue's contents, outside its scroll container. Same seam and same
    /// reason as the node stack.
    @Test func queueContentRendersARunningOperationAndTheLog() throws {
        let bitmap = try render(
            QueueTabContent(
                operations: [sampleOperation],
                statusHistory: sampleStatusHistory,
                onClearStatusHistory: {}
            ),
            width: 460, height: 340
        )
        #expect(inkedRowCount(in: bitmap, topFraction: 0, bottomFraction: 1) > 200,
                "the queue content looks blank")
        #expect(inkedRowCount(in: bitmap, topFraction: 0.6, bottomFraction: 1) > 40,
                "the status log did not render below the operation")
        try write(bitmap, named: "status-popover-queue-content")
    }

    /// An idle session must say so rather than showing an empty panel.
    @Test func queueContentSaysWhenNothingIsRunning() throws {
        let bitmap = try render(
            QueueTabContent(operations: [], statusHistory: [], onClearStatusHistory: {}),
            width: 460, height: 140
        )
        #expect(inkedRowCount(in: bitmap, topFraction: 0, bottomFraction: 1) > 20)
        try write(bitmap, named: "status-popover-queue-idle")
    }

    /// Both tabs are the same fixed size, so switching does not resize the
    /// popover under the pointer.
    @Test func bothTabsAreTheSameSize() throws {
        let queue = try render(popover(tab: .queue), width: 460, height: 420)
        let history = try render(popover(tab: .history), width: 460, height: 420)
        #expect(queue.pixelsWide == history.pixelsWide)
        #expect(queue.pixelsHigh == history.pixelsHigh)
    }

    private func popover(tab: ProcessingStatusTab) -> some View {
        ProcessingStatusPopoverView(
            operations: [sampleOperation],
            statusHistory: sampleStatusHistory,
            historyNodes: sampleNodes,
            historyShortID: "a4f1c9",
            canStepBack: true,
            canStepForward: false,
            tab: .constant(tab),
            onClearStatusHistory: {},
            onSelectNode: { _ in },
            onStepBack: {},
            onStepForward: {},
            onFork: {}
        )
    }

    private var sampleOperation: OperationProgress {
        OperationProgress(
            source: "Filter",
            title: "Signal Filtering",
            subtitle: "Butterworth 0.1–30 Hz + IIR 60.0 Hz notch + average reference",
            phase: "Filtering EEG channels",
            detail: "EEG channels 14 of 129",
            fraction: 0.16,
            stages: [
                .init(name: "Preparing", state: .complete),
                .init(name: "EEG filtering", state: .active),
                .init(name: "Finalizing", state: .pending)
            ],
            startedAt: Date(timeIntervalSinceNow: -5)
        )
    }

    private var sampleStatusHistory: [StatusHistoryEntry] {
        [
            StatusHistoryEntry(source: "PSA", text: "4 categories, 59 epochs averaged.",
                               isError: false, date: Date(timeIntervalSinceNow: -90)),
            StatusHistoryEntry(source: "Channels", text: "Interpolated Ch 8 from 125 neighbors.",
                               isError: false, date: Date(timeIntervalSinceNow: -40))
        ]
    }

    // MARK: - Helpers

    /// Scanlines between `topFraction` and `bottomFraction` of the image that
    /// contain any pixel differing from that row's leftmost pixel — i.e. rows
    /// with something drawn on them. Comparing within a scanline rather than
    /// against a fixed colour keeps this working in both light and dark
    /// appearance and under any accent colour.
    private func inkedRowCount(
        in bitmap: NSBitmapImageRep,
        topFraction: Double,
        bottomFraction: Double
    ) -> Int {
        let first = Int(Double(bitmap.pixelsHigh) * topFraction)
        let last = Int(Double(bitmap.pixelsHigh) * bottomFraction)
        var count = 0
        for y in first..<max(first, last) {
            guard let background = bitmap.colorAt(x: 2, y: y) else { continue }
            for x in stride(from: 4, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                if abs(color.redComponent - background.redComponent) > 0.04
                    || abs(color.greenComponent - background.greenComponent) > 0.04
                    || abs(color.blueComponent - background.blueComponent) > 0.04 {
                    count += 1
                    break
                }
            }
        }
        return count
    }

    /// Writes into the test container's temporary directory — tests cannot write
    /// into the repo under the sandbox — and prints the path so the PNG can be
    /// opened after a run.
    private func write(_ bitmap: NSBitmapImageRep, named name: String) throws {
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("[HistoryRailRenderTests] wrote \(url.path)")
    }
}
