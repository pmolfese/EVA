//
//  EventAnchorPreferencesView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Preferences ▸ Events: the rules deciding which imported event codes mark the
//  middle of what they describe rather than its start. See `EventAnchorSettings`
//  for why the distinction matters and why it is applied at load.
//

import SwiftUI

struct EventAnchorPreferencesView: View {
    @Environment(EventAnchorSettings.self) private var settings

    @State private var selection: Set<EventAnchorRule.ID> = []
    @State private var reapplyMessage: String?

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 0) {
            explanation
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    builtInSection

                    Divider()
                        .padding(.vertical, 4)

                    sectionHeader("Your Rules", trailing: "for imported events")

                    if settings.rules.isEmpty {
                        emptyState
                    } else {
                        rulesList(settings: $settings)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            Divider()

            controls(settings: $settings)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    // MARK: - Explanation

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Imported event markers are read as **onsets** — the start of what they describe — because that is what every file format records. Add a rule where your markers instead sit at the middle or the peak of the event.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            EventAnchorDiagram()
                .frame(height: 58)

            Text("Rules apply when a recording is opened, and to imported events only. EVA's own detectors measure where their events sit, so their markers are already placed correctly.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Rules

    /// Deliberately does NOT say "nothing is centered" — the built-in table
    /// directly above shows that plenty is. It speaks only for imported events,
    /// which is all these rules govern.
    private var emptyState: some View {
        Text("No rules — imported events are read as onsets.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
    }

    // MARK: - Built-in anchors

    /// A readout, not a control.
    ///
    /// Without it the tab shows only the user's own rules, and an empty list
    /// reads as "nothing in EVA is centered" — untrue the moment any detector
    /// runs. These stay non-editable because detectors *measure* where their
    /// events sit; there is no guess here for a user to correct, and overriding
    /// one would move every window derived from it with no visible symptom.
    private var builtInSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Built-in", trailing: "measured by EVA")

            ForEach(EventAnchorCatalog.entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name)
                            .font(.caption)
                        Text(entry.detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    AnchorBadge(anchor: entry.anchor)
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func sectionHeader(_ title: String, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption.weight(.semibold))
            Spacer()
            Text(trailing)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 4)
    }

    private func rulesList(settings: Bindable<EventAnchorSettings>) -> some View {
        List(selection: $selection) {
            ForEach(settings.rules) { $rule in
                EventAnchorRuleRow(rule: $rule)
                    .tag(rule.id)
            }
            .onMove { offsets, destination in
                settings.wrappedValue.move(fromOffsets: offsets, toOffset: destination)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .frame(height: max(CGFloat(settings.wrappedValue.rules.count) * 28 + 12, 40))
        .scrollDisabled(true)
    }

    // MARK: - Controls

    private func controls(settings: Bindable<EventAnchorSettings>) -> some View {
        HStack(spacing: 8) {
            Button {
                settings.wrappedValue.addRule()
            } label: {
                Image(systemName: "plus")
            }
            .help("Add a rule")

            Button {
                settings.wrappedValue.removeRules(with: selection)
                selection = []
            } label: {
                Image(systemName: "minus")
            }
            .disabled(selection.isEmpty)
            .help("Remove the selected rules")

            codeMenu(settings: settings)

            Spacer()

            if let reapplyMessage {
                Text(reapplyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Button("Reapply to Open Recordings") {
                reapply()
            }
            .disabled(OpenRecordingRegistry.shared.recordings.isEmpty)
            .help("Rules are applied when a recording is opened. Use this to re-read the events of a recording that is already open under the current rules.")
        }
        .buttonStyle(.bordered)
    }

    /// Adds a rule pre-filled with a code that actually occurs in open data —
    /// the Preferences window has no recording of its own, so without this the
    /// only way to write a rule is to remember the code and type it exactly.
    private func codeMenu(settings: Bindable<EventAnchorSettings>) -> some View {
        let codes = OpenRecordingRegistry.shared.eventCodes
        return Menu {
            if codes.isEmpty {
                Text("No recordings open")
            } else {
                ForEach(codes, id: \.self) { code in
                    Button(code) {
                        settings.wrappedValue.addRule(EventAnchorRule(codePattern: code))
                    }
                }
            }
        } label: {
            Text("From Recording")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(codes.isEmpty)
        .help("Add a rule for an event code found in an open recording")
    }

    private func reapply() {
        let recordings = OpenRecordingRegistry.shared.recordings
        var changed = 0
        for recording in recordings where recording.reapplyEventAnchorRules() != nil {
            changed += 1
        }
        reapplyMessage = changed == 0
            ? "No events changed"
            : "Updated \(changed) of \(recordings.count) recording\(recordings.count == 1 ? "" : "s")"
    }
}

/// A small tinted pill naming an anchor.
///
/// Shared by the Preferences built-in table and the Events panel's rows so the
/// same anchor never reads as two different things in two places. Colour is
/// deliberately secondary to the word — the label carries the meaning, the tint
/// only makes the three kinds scannable in a list.
struct AnchorBadge: View {
    let anchor: EventTimeAnchor
    var isCompact = false

    private var tint: Color {
        switch anchor {
        case .onset: return .secondary
        case .center: return .orange
        case .peak: return .purple
        }
    }

    var body: some View {
        Text(anchor.displayName)
            .font(isCompact ? .caption2 : .caption2.weight(.medium))
            .foregroundStyle(anchor == .onset ? Color.secondary : tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(tint.opacity(anchor == .onset ? 0.10 : 0.15))
            )
            .accessibilityLabel("\(anchor.displayName) anchored")
    }
}

// MARK: - Row

private struct EventAnchorRuleRow: View {
    @Binding var rule: EventAnchorRule

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $rule.isEnabled)
                .labelsHidden()
                .help("Enable this rule")

            TextField("Code", text: $rule.codePattern)
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
                .help("Event code to match. Case-insensitive; a trailing * matches any suffix (stim* matches stim1 and stimA).")

            Picker("", selection: $rule.anchor) {
                ForEach(EventTimeAnchor.allCases, id: \.self) { anchor in
                    Text(anchor.displayName).tag(anchor)
                }
            }
            .labelsHidden()
            .frame(width: 100)

            TextField("Source", text: Binding(
                get: { rule.sourceScope ?? "" },
                set: { rule.sourceScope = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 96)
            .help("Optional. Limits the rule to events imported from one file; leave blank to apply it to every source.")

            TextField("ms", value: Binding(
                get: { rule.assumedDurationSeconds.map { $0 * 1000 } },
                set: { rule.assumedDurationSeconds = $0.map { $0 / 1000 } }
            ), format: .number.precision(.fractionLength(0)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
            .help("Optional. Width to assume for matched events that record no duration of their own — without one, a centered marker has no span to draw or clean over. Never overrides a duration the file itself recorded.")

            Text("ms")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Diagram

/// Two markers, same sample, different readings — the whole preference in one
/// picture. Worth the pixels: the distinction is genuinely hard to state in
/// prose and immediate to see.
private struct EventAnchorDiagram: View {
    var body: some View {
        Canvas { context, size in
            let laneHeight = size.height / 2
            let markerX = size.width * 0.38
            let spanWidth = min(size.width * 0.34, 150)

            draw(
                in: &context,
                lane: CGRect(x: 0, y: 0, width: size.width, height: laneHeight),
                markerX: markerX,
                spanStart: markerX,
                spanWidth: spanWidth,
                title: "Onset",
                color: .accentColor
            )
            draw(
                in: &context,
                lane: CGRect(x: 0, y: laneHeight, width: size.width, height: laneHeight),
                markerX: markerX,
                spanStart: markerX - spanWidth / 2,
                spanWidth: spanWidth,
                title: "Centered / Peak",
                color: .orange
            )
        }
        .accessibilityLabel(
            "Diagram: an onset marker begins its span, a centered marker sits in the middle of its span."
        )
    }

    private func draw(
        in context: inout GraphicsContext,
        lane: CGRect,
        markerX: CGFloat,
        spanStart: CGFloat,
        spanWidth: CGFloat,
        title: String,
        color: Color
    ) {
        let midY = lane.midY
        let barHeight: CGFloat = 13

        let span = CGRect(x: spanStart, y: midY - barHeight / 2, width: spanWidth, height: barHeight)
        context.fill(
            Path(roundedRect: span, cornerRadius: 3),
            with: .color(color.opacity(0.20))
        )

        var stem = Path()
        stem.move(to: CGPoint(x: markerX, y: midY - barHeight))
        stem.addLine(to: CGPoint(x: markerX, y: midY + barHeight))
        context.stroke(stem, with: .color(color), lineWidth: 2)

        context.draw(
            Text(title).font(.caption2).foregroundStyle(.secondary),
            at: CGPoint(x: spanStart + spanWidth + 10, y: midY),
            anchor: .leading
        )
    }
}
