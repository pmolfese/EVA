//
//  ChannelsWindowView.swift
//  EVA
//
//  One utility window for channel-set editing and recording diagnostics. The
//  scalp map stays in the same place while the sidebar and inspector change
//  meaning by tab. Only Channel Sets mutates set membership; every other tab
//  uses map clicks solely for inspection.
//

import SwiftUI

struct ChannelsWindowView: View {
    @Environment(\.dismiss) private var dismiss
    private var model: ChannelsWindowModel { .shared }
    @State private var automaticallyRequestedHealthRevision: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Channels View", selection: Binding(
                get: { model.selectedTab },
                set: { model.selectedTab = $0 }
            )) {
                ForEach(ChannelsWindowTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 720)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch model.selectedTab {
                case .channelSets:
                    ChannelSetEditorView(showsDismissButton: false)
                case .health, .impedance, .relationships, .reference:
                    ChannelDiagnosticsView(tab: model.selectedTab)
                }
            }
        }
        .navigationTitle("Channels")
        .frame(minWidth: 900, idealWidth: 1080, minHeight: 620, idealHeight: 720)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task(id: automaticHealthTaskID) {
            guard let revision = model.activeSignal?.dataRevision,
                  automaticallyRequestedHealthRevision != revision else { return }

            // An existing run already satisfies the automatic request. Mark
            // the revision so opening/switching tabs cannot enqueue another.
            if model.isAnalyzingHealth {
                automaticallyRequestedHealthRevision = revision
                return
            }

            // Preserve a completed result. The automatic path exists to avoid
            // presenting an empty "Run Health" state when Channels opens;
            // Refresh remains available when the user wants a forced rerun.
            guard model.healthResults.isEmpty else { return }
            automaticallyRequestedHealthRevision = revision
            model.requestHealthRefresh()
        }
    }

    private var automaticHealthTaskID: String {
        let recording = model.activeRecordingID?.uuidString ?? "none"
        let revision = model.activeSignal?.dataRevision.uuidString ?? "none"
        return "\(recording)|\(revision)|empty=\(model.healthResults.isEmpty)"
    }
}

private struct ChannelDiagnosticsView: View {
    let tab: ChannelsWindowTab
    private var model: ChannelsWindowModel { .shared }

    private var channelCount: Int {
        if let signal = model.activeSignal { return signal.data.count }
        if let names = model.activeChannelNames { return names.count }
        return (model.activeLayout?.positions.map(\.channelIndex).max()).map { $0 + 1 } ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.activeSignal == nil {
                ContentUnavailableView(
                    "No Recording Selected",
                    systemImage: "waveform.slash",
                    description: Text("Focus an open recording window, then return here.")
                )
            } else {
                HSplitView {
                    sidebar
                        .frame(minWidth: 210, idealWidth: 240, maxWidth: 280)
                    mapPane
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    inspector
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380, maxHeight: .infinity)
                }
            }
        }
        .task(id: diagnosticsTaskID) {
            if tab == .relationships || tab == .reference {
                model.refreshDiagnostics()
            }
        }
    }

    private var diagnosticsTaskID: String {
        "\(tab.rawValue)|\(model.activeSignal?.dataRevision.uuidString ?? "none")|\(model.healthResults.count)"
    }

    private var title: String {
        switch tab {
        case .channelSets: return "Channel Sets"
        case .health: return "Channel Health"
        case .impedance: return "Electrode Impedance"
        case .relationships: return "Channel Relationships"
        case .reference: return "Reference & Common Mode"
        }
    }

    private var subtitle: String {
        let recording = model.activeRecordingName ?? "Focused recording"
        switch tab {
        case .channelSets: return recording
        case .health:
            if model.isAnalyzingHealth {
                return "\(recording) · analyzing channel health…"
            }
            return model.healthResults.isEmpty ? "\(recording) · health unavailable" : "\(recording) · \(model.healthResults.count) channels scored"
        case .impedance:
            let count = finiteImpedances.count
            return count == 0 ? "\(recording) · no ICAL values" : "\(recording) · \(count) measured at acquisition"
        case .relationships:
            return model.relationshipDiagnosticStatus ?? "\(recording) · review-only findings"
        case .reference:
            return model.referenceDiagnosticStatus ?? "\(recording) · recording-level assessment"
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if (tab == .health && model.isAnalyzingHealth)
                || (model.isAnalyzingDiagnostics && (tab == .relationships || tab == .reference)) {
                ProgressView()
                    .controlSize(.small)
            }
            if tab == .health {
                Button("Refresh") {
                    model.requestHealthRefresh()
                }
                .disabled(model.isAnalyzingHealth)
            } else if tab == .relationships || tab == .reference {
                Button("Refresh") { model.refreshDiagnostics(force: true) }
                    .disabled(model.isAnalyzingDiagnostics)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var sidebar: some View {
        List {
            switch tab {
            case .health:
                if model.healthResults.isEmpty {
                    if model.isAnalyzingHealth {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: model.healthProgress)
                            Text("Analyzing channel health…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        Text("Channel health could not be calculated for this signal. Use Refresh to try again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Lowest Goodness") {
                        ForEach(model.healthResults.values.sorted(by: healthSort)) { result in
                            sidebarButton(channel: result.channelIndex) {
                                HStack(spacing: 8) {
                                    Circle().fill(result.grade.channelsColor).frame(width: 9, height: 9)
                                    channelLabel(result.channelIndex)
                                    Spacer()
                                    Text("\(result.goodPercentage)%")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            case .impedance:
                if finiteImpedances.isEmpty {
                    Text("This recording has no electrode impedance calibration values.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Section("Highest Impedance") {
                        ForEach(finiteImpedances.sorted { $0.value > $1.value }, id: \.index) { item in
                            sidebarButton(channel: item.index) {
                                HStack(spacing: 8) {
                                    Circle().fill(impedanceColor(item.value)).frame(width: 9, height: 9)
                                    channelLabel(item.index)
                                    Spacer()
                                    Text(String(format: "%.0f kΩ", item.value))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            case .relationships:
                if model.isAnalyzingDiagnostics && model.relationshipFindings.isEmpty {
                    Text("Looking for persistent channel pairs…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.relationshipFindings.isEmpty {
                    Text("No persistent bridge or high-correlation findings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    relationshipSection(.likelyBridge)
                    relationshipSection(.highCorrelation)
                }
            case .reference:
                Section("Recording Context") {
                    Button {
                        model.selectedChannel = nil
                        model.selectedRelationshipID = nil
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(referenceStructureColor)
                                .frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Common-mode structure")
                                Text(model.referenceAssessment?.structureLevel ?? "Analyzing")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            case .channelSets:
                EmptyView()
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func relationshipSection(_ kind: ChannelRelationshipKind) -> some View {
        let findings = model.relationshipFindings.filter { $0.kind == kind }
        if !findings.isEmpty {
            Section(kind.displayName) {
                ForEach(findings) { finding in
                    Button {
                        model.selectedRelationshipID = finding.id
                        model.selectedChannel = finding.firstChannel
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("\(channelName(finding.firstChannel)) ↔ \(channelName(finding.secondChannel))")
                                    .font(.callout.weight(.medium))
                                Spacer()
                                Text(String(format: "r %.3f", finding.medianCorrelation))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(Int((finding.persistentWindowFraction * 100).rounded()))% of windows")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(model.selectedRelationshipID == finding.id ? Color.accentColor.opacity(0.12) : Color.clear)
                }
            }
        }
    }

    private func sidebarButton<Content: View>(channel: Int, @ViewBuilder content: () -> Content) -> some View {
        Button {
            model.selectedChannel = channel
            model.selectedRelationshipID = nil
        } label: {
            content()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(model.selectedChannel == channel ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private var mapPane: some View {
        VStack(spacing: 0) {
            if let layout = model.activeLayout {
                ChannelsScalpMapView(
                    layout: layout,
                    selectedChannels: selectedChannels,
                    findings: tab == .relationships ? model.relationshipFindings : [],
                    channelLabel: channelName,
                    channelColor: mapColor,
                    onSelect: selectChannel
                )
                .padding(18)
            } else {
                fallbackChannelGrid
                    .padding(18)
            }

            Divider()
            legend
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
    }

    private var fallbackChannelGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 8)], spacing: 8) {
                ForEach(0..<channelCount, id: \.self) { index in
                    Button { selectChannel(index) } label: {
                        Text(channelName(index))
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(mapColor(index).opacity(selectedChannels.contains(index) ? 0.28 : 0.12))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(mapColor(index), lineWidth: selectedChannels.contains(index) ? 2 : 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var legend: some View {
        HStack(spacing: 14) {
            switch tab {
            case .health:
                legendItem("Good", .green)
                legendItem("Watch", .yellow)
                legendItem("Poor", .red)
            case .impedance:
                legendItem("Great/Good", .green)
                legendItem("Fair", .yellow)
                legendItem("Poor", .red)
            case .relationships:
                legendItem("Likely bridge", .orange)
                legendItem("High correlation", .cyan)
                Text("Lines are review findings, not automatic repairs.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .reference:
                legendItem("Common-mode context", .purple)
                Text("Recording-level evidence; purple does not mark bad electrodes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .channelSets:
                EmptyView()
            }
            Spacer()
        }
    }

    private func legendItem(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2)
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch tab {
                case .health: healthInspector
                case .impedance: impedanceInspector
                case .relationships: relationshipInspector
                case .reference: referenceInspector
                case .channelSets: EmptyView()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    @ViewBuilder
    private var healthInspector: some View {
        if let channel = model.selectedChannel,
           let result = model.healthResults[channel] {
            inspectorTitle(channelName(channel), subtitle: "Channel Health · \(result.grade.displayName)")
            scoreBadge("\(result.goodPercentage)% good", color: result.grade.channelsColor)
            Text(result.summary).font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(result.metrics) { metric in
                diagnosticMetric(
                    metric.name,
                    value: "\(metric.grade.displayName) · \(Int((metric.score * 100).rounded()))%",
                    detail: metric.detail,
                    color: metric.grade.channelsColor
                )
            }
            relationshipShortcut(for: channel)
        } else {
            emptyInspector("Select a channel", detail: "Choose a channel from the list or scalp map to inspect its health metrics.")
        }
    }

    @ViewBuilder
    private var impedanceInspector: some View {
        if let channel = model.selectedChannel {
            inspectorTitle(channelName(channel), subtitle: "Electrode Impedance")
            if let impedance = impedance(at: channel) {
                scoreBadge(String(format: "%.1f kΩ", impedance), color: impedanceColor(impedance))
                diagnosticMetric(
                    "Contact-quality band",
                    value: ChannelImpedanceSettings.defaults.band(forKOhm: impedance).capitalized,
                    detail: "EVA's configurable EGI-style acquisition band.",
                    color: impedanceColor(impedance)
                )
                Text("This value was recorded at acquisition. Low impedance can support a bridge finding, but does not prove one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No impedance value was recorded for this channel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            relationshipShortcut(for: channel)
        } else {
            emptyInspector("Select a channel", detail: "Choose a measured channel to inspect its acquisition impedance.")
        }
    }

    @ViewBuilder
    private var relationshipInspector: some View {
        if let finding = selectedFinding {
            let cluster = model.cluster(containing: finding)
            inspectorTitle(
                "\(channelName(finding.firstChannel)) ↔ \(channelName(finding.secondChannel))",
                subtitle: finding.kind.displayName
            )
            scoreBadge("\(Int((finding.confidence * 100).rounded()))% confidence", color: finding.kind == .likelyBridge ? .orange : .cyan)
            diagnosticMetric("Pair correlation", value: String(format: "%.4f", finding.medianCorrelation), detail: "Robust median across distributed windows.", color: .primary)
            diagnosticMetric("Differential RMS", value: String(format: "%.3f µV", finding.medianDifferentialRMSMicrovolts), detail: "Near-zero pair difference distinguishes a likely bridge from ordinary correlation.", color: .primary)
            diagnosticMetric("Window persistence", value: "\(Int((finding.persistentWindowFraction * 100).rounded()))%", detail: "Fraction of usable windows meeting this finding's criteria.", color: .primary)
            if let distance = finding.spatialDistance {
                diagnosticMetric("Montage distance", value: String(format: "%.3f", distance), detail: "Supporting evidence only; proximity is never a hard gate.", color: .secondary)
            }
            if cluster.count > 2 {
                diagnosticMetric("Bridge cluster", value: cluster.map(channelName).joined(separator: ", "), detail: "Connected likely-bridge pairs.", color: .orange)
            }
            Divider()
            Text("RANSAC context").font(.caption.weight(.semibold))
            diagnosticMetric(channelName(finding.firstChannel), value: finding.firstNeighborPrediction ?? "Not available", detail: "Can nearby channels predict this channel?", color: .secondary)
            diagnosticMetric(channelName(finding.secondChannel), value: finding.secondNeighborPrediction ?? "Not available", detail: "RANSAC does not identify the duplicate partner.", color: .secondary)
            Divider()
            Text("Impedance context").font(.caption.weight(.semibold))
            diagnosticMetric(channelName(finding.firstChannel), value: impedanceText(finding.firstImpedanceKOhm), detail: "Acquisition value", color: .secondary)
            diagnosticMetric(channelName(finding.secondChannel), value: impedanceText(finding.secondImpedanceKOhm), detail: "Acquisition value", color: .secondary)
            reviewWarning("Common reference and volume conduction can raise correlation. EVA requires both persistent similarity and a very small pair difference before labeling a likely bridge. Review before changing channel status or reference membership.")
        } else if let channel = model.selectedChannel {
            inspectorTitle(channelName(channel), subtitle: "Channel Relationships")
            let findings = model.relationships(for: channel)
            if findings.isEmpty {
                Text("No persistent relationship finding includes this channel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(findings) { finding in
                    Button {
                        model.selectedRelationshipID = finding.id
                    } label: {
                        HStack {
                            Text(finding.kind.displayName)
                            Spacer()
                            if let partner = finding.partner(of: channel) {
                                Text(channelName(partner)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } else {
            emptyInspector("Select a finding", detail: "Choose a relationship or channel to inspect pair evidence and RANSAC context.")
        }
    }

    @ViewBuilder
    private var referenceInspector: some View {
        inspectorTitle(model.activeRecordingName ?? "Recording", subtitle: "Reference & Common Mode")
        diagnosticMetric(
            "Acquisition reference",
            value: acquisitionReferenceLabel,
            detail: acquisitionReferenceDetail,
            color: .primary
        )
        diagnosticMetric(
            "Current processing reference",
            value: processingReferenceLabel,
            detail: processingReferenceDetail,
            color: model.activeSignal?.referenceState == .average ? .green : .primary
        )
        Divider()
        if let assessment = model.referenceAssessment {
            scoreBadge("\(assessment.structureLevel) common mode", color: referenceStructureColor)
            diagnosticMetric("Common-mode RMS", value: String(format: "%.2f µV", assessment.commonModeRMSMicrovolts), detail: "Magnitude of the recording-wide channel mean.", color: referenceStructureColor)
            diagnosticMetric("Median variance fraction", value: "\(Int((assessment.medianCommonModeVarianceFraction * 100).rounded()))%", detail: "Common-mode variance relative to a typical channel.", color: .primary)
            diagnosticMetric("Same-signed loadings", value: "\(Int((assessment.positiveLoadingFraction * 100).rounded()))%", detail: "Channels carrying the shared pattern with the same polarity.", color: .primary)
            diagnosticMetric("Median correlation", value: String(format: "%.3f", assessment.medianChannelCorrelation), detail: "Typical channel correlation with the common-mode trace.", color: .primary)

            if model.activeSignal?.referenceState == .average,
               let original = model.acquisitionReferenceAssessment {
                Divider()
                diagnosticMetric(
                    "Before → after rereferencing",
                    value: String(
                        format: "%.2f → %.2f µV",
                        original.commonModeRMSMicrovolts,
                        assessment.commonModeRMSMicrovolts
                    ),
                    detail: "The acquisition-referenced signal was \(original.structureLevel.lowercased()); the current average-referenced signal is \(assessment.structureLevel.lowercased()).",
                    color: .green
                )
            } else if let check = model.averageReferenceCheck {
                Divider()
                diagnosticMetric(
                    "Average-reference check",
                    value: String(format: "%.2f µV residual", check.commonModeRMSMicrovolts),
                    detail: "A temporary average-reference calculation reduced the common-mode structure to \(check.structureLevel.lowercased()). This is an expected arithmetic consequence, not proof that the acquisition reference was faulty.",
                    color: check.grade == .good ? .green : .orange
                )
            }

            if model.activeSignal?.referenceState == .average {
                informationalNote("Low common-mode structure is expected after average referencing because the instantaneous channel mean is constrained toward zero. It should not be interpreted as an independent reference-health test.")
            } else {
                reviewWarning(referenceInterpretationWarning)
            }
        } else if model.isAnalyzingDiagnostics {
            ProgressView("Analyzing common-mode structure…")
                .controlSize(.small)
        } else {
            Text("There is not enough usable multi-channel data for a common-mode assessment.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func relationshipShortcut(for channel: Int) -> some View {
        let findings = model.relationships(for: channel)
        Divider()
        if let first = findings.first {
            Button {
                model.present(tab: .relationships, channel: channel, relationshipID: first.id)
            } label: {
                Label("\(first.kind.displayName) with \(channelName(first.partner(of: channel) ?? channel))", systemImage: "point.3.connected.trianglepath.dotted")
            }
        } else if model.relationshipAnalysisState == .analyzing {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking channel relationships…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if model.relationshipAnalysisState == .complete {
            VStack(alignment: .leading, spacing: 6) {
                Label("No persistent pair findings", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                if let summary = model.strongestRelationship(for: channel) {
                    Text("Strongest evaluated partner: \(channelName(summary.partner)), median r \(summary.medianCorrelation.formatted(.number.precision(.fractionLength(3)))).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.present(tab: .relationships, channel: channel)
                } label: {
                    Label("Open Relationships", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
        } else {
            Button {
                model.present(tab: .relationships, channel: channel)
                model.refreshDiagnostics()
            } label: {
                Label("Open Relationships", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
    }

    private func inspectorTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func scoreBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func diagnosticMetric(_ name: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.caption.weight(.semibold))
                Spacer()
                Text(value).font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(color)
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reviewWarning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }

    private func informationalNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08)))
    }

    private func emptyInspector(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectedFinding: ChannelRelationshipFinding? {
        guard let id = model.selectedRelationshipID else { return nil }
        return model.relationshipFindings.first { $0.id == id }
    }

    private var selectedChannels: Set<Int> {
        if let finding = selectedFinding { return [finding.firstChannel, finding.secondChannel] }
        return model.selectedChannel.map { [$0] } ?? []
    }

    private var finiteImpedances: [(index: Int, value: Double)] {
        guard let values = model.activeSignal?.impedancesKOhm else { return [] }
        return values.enumerated().compactMap { index, value in
            let converted = Double(value)
            return converted.isFinite ? (index, converted) : nil
        }
    }

    private func impedance(at channel: Int) -> Double? {
        guard let values = model.activeSignal?.impedancesKOhm,
              values.indices.contains(channel) else { return nil }
        let value = Double(values[channel])
        return value.isFinite ? value : nil
    }

    private func impedanceText(_ value: Double?) -> String {
        value.map { String(format: "%.1f kΩ", $0) } ?? "Not recorded"
    }

    private func impedanceColor(_ value: Double) -> Color {
        let settings = ChannelImpedanceSettings.defaults
        if value <= settings.goodMaxKOhm { return .green }
        if value <= settings.fairMaxKOhm { return .yellow }
        return .red
    }

    private func channelLabel(_ index: Int) -> some View {
        Text(channelName(index)).lineLimit(1)
    }

    private func channelName(_ index: Int) -> String {
        if let names = model.activeChannelNames, names.indices.contains(index), !names[index].isEmpty {
            return names[index]
        }
        return "Ch \(index + 1)"
    }

    private func mapColor(_ index: Int) -> Color {
        switch tab {
        case .health:
            return model.healthResults[index]?.grade.channelsColor ?? .gray
        case .impedance:
            return impedance(at: index).map(impedanceColor) ?? .gray
        case .relationships:
            let findings = model.relationships(for: index)
            if findings.contains(where: { $0.kind == .likelyBridge }) { return .orange }
            if !findings.isEmpty { return .cyan }
            return .gray
        case .reference:
            return model.referenceAssessment?.hasFinding == true ? .purple : .gray
        case .channelSets:
            return .blue
        }
    }

    private var referenceStructureColor: Color {
        guard let grade = model.referenceAssessment?.grade else { return .gray }
        switch grade {
        case .good: return .green
        case .watch: return .yellow
        case .poor: return .purple
        }
    }

    private var acquisitionReferenceLabel: String {
        guard let reference = model.activeSignal?.acquisitionReference
            ?? model.activeAcquisitionSignal?.acquisitionReference else {
            return "Not declared"
        }
        return "\(reference.name) (E\(reference.channelIndex + 1))"
    }

    private var acquisitionReferenceDetail: String {
        guard let reference = model.activeSignal?.acquisitionReference
            ?? model.activeAcquisitionSignal?.acquisitionReference else {
            return "The source metadata does not identify a physical reference electrode."
        }
        if reference.isRecorded {
            return "Declared by the source metadata and present as a recorded signal channel."
        }
        if model.activeSignal?.data.indices.contains(reference.channelIndex) == true {
            return "Declared by the source metadata; its omitted zero row was reconstructed before average referencing."
        }
        return "Declared by the source metadata but omitted from the recorded sample rows."
    }

    private var processingReferenceLabel: String {
        switch model.activeSignal?.referenceState {
        case .average: return "Average"
        case .acquisition: return acquisitionReferenceLabel
        case .unknown, nil: return "Recorded convention"
        }
    }

    private var processingReferenceDetail: String {
        switch model.activeSignal?.referenceState {
        case .average:
            return "The acquisition reference participates in the average when its metadata and position are available."
        case .acquisition:
            return "Samples remain relative to the physical acquisition reference."
        case .unknown, nil:
            return "No reliable processing-reference declaration is available."
        }
    }

    private var referenceInterpretationWarning: String {
        let namedReference = acquisitionReferenceLabel == "Not declared"
            ? "the acquisition reference"
            : acquisitionReferenceLabel
        return "High shared structure can arise from \(namedReference), common environmental noise, or neural synchrony. Treat this as reference-sensitive recording context, not a diagnosis that the physical reference is bad."
    }

    private func selectChannel(_ index: Int) {
        model.selectedChannel = index
        if tab == .relationships {
            model.selectedRelationshipID = model.relationships(for: index).first?.id
        } else {
            model.selectedRelationshipID = nil
        }
    }

    private func healthSort(_ first: ChannelHealthResult, _ second: ChannelHealthResult) -> Bool {
        first.goodPercentage == second.goodPercentage
            ? first.channelIndex < second.channelIndex
            : first.goodPercentage < second.goodPercentage
    }
}

private struct ChannelsScalpMapView: View {
    let layout: SensorLayout
    let selectedChannels: Set<Int>
    let findings: [ChannelRelationshipFinding]
    let channelLabel: (Int) -> String
    let channelColor: (Int) -> Color
    let onSelect: (Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = side / 2 * 0.82
            let positions = Dictionary(uniqueKeysWithValues: layout.positions.map { ($0.channelIndex, point($0, center: center, radius: radius)) })

            ZStack {
                Canvas { context, _ in
                    drawHead(in: &context, center: center, radius: radius)
                    for finding in findings {
                        guard let start = positions[finding.firstChannel], let end = positions[finding.secondChannel] else { continue }
                        var path = Path()
                        path.move(to: start)
                        path.addLine(to: end)
                        let color: Color = finding.kind == .likelyBridge ? .orange : .cyan
                        context.stroke(path, with: .color(color.opacity(0.82)), style: StrokeStyle(lineWidth: selectedChannels.contains(finding.firstChannel) && selectedChannels.contains(finding.secondChannel) ? 3 : 1.6, lineCap: .round))
                    }
                }

                ForEach(layout.positions) { sensor in
                    let selected = selectedChannels.contains(sensor.channelIndex)
                    let color = channelColor(sensor.channelIndex)
                    Button { onSelect(sensor.channelIndex) } label: {
                        ZStack {
                            Circle().fill(color.opacity(selected ? 0.30 : 0.15))
                            Circle().stroke(color, lineWidth: selected ? 2.5 : 1.2)
                            Text(channelLabel(sensor.channelIndex))
                                .font(.system(size: markerFontSize, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.72))
                                .minimumScaleFactor(0.45)
                                .lineLimit(1)
                                .padding(2)
                        }
                        .frame(width: markerSize, height: markerSize)
                    }
                    .buttonStyle(.plain)
                    .position(positions[sensor.channelIndex] ?? center)
                    .help(channelLabel(sensor.channelIndex))
                }
            }
        }
    }

    private var markerSize: CGFloat {
        if layout.positions.count > 128 { return 18 }
        if layout.positions.count > 64 { return 21 }
        return 27
    }

    private var markerFontSize: CGFloat {
        if layout.positions.count > 128 { return 5.5 }
        if layout.positions.count > 64 { return 6.5 }
        return 8
    }

    private func point(_ sensor: SensorPosition, center: CGPoint, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + CGFloat(sensor.x) * radius, y: center.y - CGFloat(sensor.y) * radius)
    }

    private func drawHead(in context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        let stroke = GraphicsContext.Shading.color(.primary.opacity(0.42))
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.stroke(Path(ellipseIn: rect), with: stroke, lineWidth: 1.5)

        var nose = Path()
        let width = radius * 0.10
        let height = radius * 0.10
        nose.move(to: CGPoint(x: center.x - width, y: center.y - radius + 1))
        nose.addLine(to: CGPoint(x: center.x, y: center.y - radius - height))
        nose.addLine(to: CGPoint(x: center.x + width, y: center.y - radius + 1))
        context.stroke(nose, with: stroke, lineWidth: 1.5)
    }
}

private extension ChannelHealthGrade {
    var channelsColor: Color {
        switch self {
        case .good: return .green
        case .watch: return .yellow
        case .poor: return .red
        }
    }
}
