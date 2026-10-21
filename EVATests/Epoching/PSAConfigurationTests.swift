import AppKit
import SwiftUI
import XCTest
@testable import EVA

@MainActor
final class PSAConfigurationTests: XCTestCase {
    private static var retainedWindows: [NSWindow] = []

    private func waveform() -> WaveformView {
        WaveformView(recording: MFFRecording(packageURL: URL(fileURLWithPath: "/tmp/psa-layout.mff")),
                     userMarkers: [])
    }

    private func events() -> [MFFEvent] {
        ["standard", "deviant", "DIN1"].enumerated().map { index, code in
            MFFEvent(id: "event-\(index)", code: code, beginTimeSeconds: Double(index + 1),
                     rawBeginTime: "\(index + 1)", sourceFile: "test")
        }
    }

    func testTableRetainsGroupsAndRegexWhenEventFilterHasNoMatches() throws {
        let view = waveform()
        let events = events()
        let summaries = view.groupedPSAEventSummaries(events)
        view.epoching.categoryGroups["All tones"] = ["standard", "deviant"]
        let rule = CategoryRegexRule(sourceCode: "standard", pattern: "standard",
                                     matchField: .label, categoryName: "Matched")
        view.epoching.categoryRegexRules[rule.id.uuidString] = rule

        let rows = view.psaCategoryTableRows(events: events, allSummaries: summaries, summaries: [])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.id, "group:All tones")
        XCTAssertEqual(rows.first?.count, 2)
        XCTAssertEqual(rows.last?.id, "regex:\(rule.id.uuidString)")
        // Row IDs are namespaced, so a group with the same name as an event
        // cannot displace that event's editable category or onset controls.
        view.epoching.categoryGroups["standard"] = ["standard", "deviant"]
        let allRows = view.psaCategoryTableRows(events: events, allSummaries: summaries, summaries: summaries)
        XCTAssertEqual(Set(allRows.map(\.id)).count, allRows.count)
    }

    func testRegexOnlySourceKeepsIndependentDINBindings() throws {
        let view = waveform()
        let summaries = view.groupedPSAEventSummaries(events())
        let rule = CategoryRegexRule(sourceCode: "standard", pattern: ".*", categoryName: "Matched")
        view.epoching.categoryRegexRules[rule.id.uuidString] = rule
        XCTAssertTrue(view.epoching.selectedEventCodes.isEmpty)
        let options = view.psaTimingMarkerOptions(in: summaries, excluding: rule.sourceCode)
        view.psaTimingMarkerEnabledBinding(rule.sourceCode, options: options).wrappedValue = true
        view.psaTimingMarkerSelectionBinding(rule.sourceCode, options: options).wrappedValue = "DIN1"
        XCTAssertTrue(view.epoching.hasSegmentSelection)
        XCTAssertTrue(view.epoching.timingMarkerEnabledValues.contains("standard"))
        XCTAssertEqual(view.epoching.timingMarkerValuesBySegmentValue["standard"], "DIN1")
        XCTAssertFalse(view.epoching.selectedEventCodes.contains("standard"))
    }

    func testGroupDINKeepsEachMembersMarkerAndSelection() {
        let view = waveform()
        let summaries = view.groupedPSAEventSummaries(events())
        let members: Set<String> = ["standard", "deviant"]
        view.psaEventCodeBinding("standard").wrappedValue = true
        view.psaEventCodeBinding("deviant").wrappedValue = true
        view.epoching.timingMarkerValuesBySegmentValue = ["standard": "DIN1", "deviant": "standard"]
        let binding = view.psaCategoryGroupDINBinding(members: members, allSummaries: summaries)
        binding.wrappedValue = true
        XCTAssertTrue(binding.wrappedValue)
        XCTAssertEqual(view.epoching.timingMarkerValuesBySegmentValue["standard"], "DIN1")
        XCTAssertEqual(view.epoching.timingMarkerValuesBySegmentValue["deviant"], "standard")
        binding.wrappedValue = false
        XCTAssertTrue(view.epoching.timingMarkerEnabledValues.isEmpty)
        XCTAssertEqual(view.epoching.selectedEventCodes, members)
    }

    func testSheetFitsMinimumAndIdealSizesInBothAppearances() throws {
        for (width, height, dark) in [(1060.0, 560.0, false), (1200.0, 720.0, false), (1200.0, 720.0, true)] {
            let view = waveform()
            let source = SyntheticSignal.make([[Float](repeating: 0, count: 1000)], samplingRate: 100)
            let signal = MFFSignalData(signalURL: source.signalURL, signalType: source.signalType,
                numberOfChannels: source.numberOfChannels, samplingRate: source.samplingRate,
                duration: source.duration, recordingStartTime: nil, events: events(), data: source.data)
            view.epoching.categoryGroups["All tones"] = ["standard", "deviant"]
            view.epoching.selectedEventCodes = ["standard", "deviant"]
            let rule = CategoryRegexRule(sourceCode: "standard", pattern: "stand(.*)",
                                         categoryName: "Matched $1")
            view.epoching.categoryRegexRules[rule.id.uuidString] = rule
            let host = NSHostingView(rootView: view.psaConfigurationSheet(for: signal).frame(width: width, height: height))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            Self.retainedWindows.append(window)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
            XCTAssertLessThanOrEqual(host.fittingSize.height, height + 1)
            func tables(in parent: NSView) -> [NSTableView] {
                (parent as? NSTableView).map { [$0] } ?? parent.subviews.flatMap { tables(in: $0) }
            }
            let table = try XCTUnwrap(tables(in: host).first)
            XCTAssertEqual(table.numberOfRows, 5, "Events, pooled groups, and regex rules must all be visible")
            XCTAssertLessThanOrEqual(table.rect(ofColumn: table.numberOfColumns - 1).maxX,
                                     table.visibleRect.maxX + 2,
                                     "Every column, including group/rule removal, must fit without horizontal scrolling")
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = NSImage(size: host.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "PSA table and inspector \(Int(width))x\(Int(height)) \(dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
