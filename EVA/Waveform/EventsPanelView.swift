//
//  EventsPanelView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The right-hand events panel, extracted from `WaveformView.eventsPanel(for:events:)`
//  (ROADMAP Priority 1, B2 — the first panel, chosen because it was the one C1
//  called out).
//
//  This is a real `View` type taking value inputs and action closures, not a
//  function on `WaveformView`, so it is its own AttributeGraph node and does not
//  copy the whole view struct.
//
//  It also subsumes **C1**, and does so better than the caching C1 proposed.
//  C1 was "cache `groupedEventSummaries(events)` / `filteredEvents(events)`
//  because they run on every body pass". Once the panel is `Equatable` on its
//  own inputs, unrelated state changes — a drag tick, a progress tick, any of the
//  other ~60 `@State` values — don't re-run this body at all, so the derived
//  lists aren't recomputed rather than being recomputed-and-cached. They stay
//  plain `let`s in `body`, computed once when the panel genuinely changes.
//
//  Equality uses `WaveformDisplayedEventsCache.Key`, which `content(for:)`
//  already computes once per pass, instead of comparing `[MFFEvent]`
//  element-by-element — the same "compare a cheap signature, not the payload"
//  trick `WaveformChannelRow` uses for `[Float]`.
//

import SwiftUI

struct EventsPanelView: View, Equatable {
    /// The events to list. Not compared directly — see `eventsKey`.
    let events: [MFFEvent]
    /// Cheap identity for `events`, already computed by `content(for:)`.
    let eventsKey: WaveformDisplayedEventsCache.Key
    let selectedEventCodes: Set<String>
    let selectedEventID: MFFEvent.ID?
    let onSelectEvent: (MFFEvent) -> Void
    let onToggleCode: (String) -> Void
    let onClearCodes: () -> Void
    let onClose: () -> Void

    static func == (lhs: EventsPanelView, rhs: EventsPanelView) -> Bool {
        lhs.eventsKey == rhs.eventsKey
            && lhs.selectedEventCodes == rhs.selectedEventCodes
            && lhs.selectedEventID == rhs.selectedEventID
    }

    /// Event codes with counts, most frequent first, ties broken by code.
    private var summaries: [EventSummary] {
        Dictionary(grouping: events, by: \.code)
            .map { EventSummary(code: $0.key, count: $0.value.count) }
            .sorted { lhs, rhs in
                lhs.count == rhs.count
                    ? lhs.code.localizedStandardCompare(rhs.code) == .orderedAscending
                    : lhs.count > rhs.count
            }
    }

    private var visibleEvents: [MFFEvent] {
        selectedEventCodes.isEmpty ? events : events.filter { selectedEventCodes.contains($0.code) }
    }

    var body: some View {
        let summaries = summaries
        let visibleEvents = visibleEvents

        VStack(alignment: .leading, spacing: 0) {
            header(visibleCount: visibleEvents.count)

            if !summaries.isEmpty {
                codeChips(summaries)
            }

            Divider()

            if events.isEmpty {
                ContentUnavailableView(
                    "No Events",
                    systemImage: "list.bullet.rectangle",
                    description: Text("This recording has no event markers yet.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                eventList(visibleEvents)
            }
        }
    }

    private func header(visibleCount: Int) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Events")
                    .font(.headline)
                Text("\(visibleCount) of \(events.count) markers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func codeChips(_ summaries: [EventSummary]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                EventCodeChip(
                    title: "All Events",
                    count: events.count,
                    isSelected: selectedEventCodes.isEmpty,
                    action: onClearCodes
                )
                ForEach(summaries) { summary in
                    EventCodeChip(
                        title: summary.code,
                        count: summary.count,
                        isSelected: selectedEventCodes.contains(summary.code),
                        action: { onToggleCode(summary.code) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private func eventList(_ visibleEvents: [MFFEvent]) -> some View {
        let numberWidth = max(28, CGFloat(String(max(visibleEvents.count, 1)).count) * 8 + 14)
        return List(Array(visibleEvents.enumerated()), id: \.element.id) { offset, event in
            Button {
                onSelectEvent(event)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Text("\(offset + 1)")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: numberWidth, alignment: .trailing)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.code)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                        ForEach(Self.metadataRows(for: event), id: \.self) { row in
                            Text(row)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        HStack(spacing: 6) {
                            Text(Self.formattedEventTime(event.beginTimeSeconds))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            // Without this the time is ambiguous: a peak-anchored
                            // blink and an onset-anchored stimulus marker print
                            // identically, and only the flag popover said which
                            // was which. Onset is the assumed case, so it stays
                            // unmarked and only the surprising ones draw a badge.
                            if event.timeAnchor != .onset {
                                AnchorBadge(anchor: event.timeAnchor, isCompact: true)
                            }
                        }
                        Text(event.sourceFile)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "Event \(offset + 1), \(Self.accessibilitySummary(event)), "
                + "\(event.timeAnchor.timeFieldLabel) \(Self.formattedEventTime(event.beginTimeSeconds))"
            )
            .listRowBackground(
                selectedEventID == event.id ? Color.accentColor.opacity(0.14) : Color.clear
            )
        }
        .listStyle(.sidebar)
    }

    // MARK: - Formatting
    //
    // `static` because they are pure functions of the event: nothing here reads
    // the panel's state, and keeping them static makes that checkable.

    static func formattedEventTime(_ seconds: Double) -> String {
        if seconds >= 60 {
            let minutes = Int(seconds) / 60
            let remainingSeconds = seconds.truncatingRemainder(dividingBy: 60)
            return String(format: "%d:%06.3f", minutes, remainingSeconds)
        }
        return String(format: "%.3fs", seconds)
    }

    static func metadataRows(for event: MFFEvent) -> [String] {
        var rows: [String] = []
        if let label = event.label {
            rows.append("Label: \(label)")
        }
        if let description = event.eventDescription {
            rows.append("Description: \(description)")
        }
        if let cell = event.cell {
            rows.append("Cell: \(cell)")
        }
        return rows
    }

    static func accessibilitySummary(_ event: MFFEvent) -> String {
        ([event.code] + metadataRows(for: event)).joined(separator: ", ")
    }
}

/// One selectable event-code chip in the panel's filter strip.
struct EventCodeChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption2)
            }
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}
