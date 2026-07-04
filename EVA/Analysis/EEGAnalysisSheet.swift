//
//  EEGAnalysisSheet.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EEGAnalysisSheet: View {
    @ObservedObject var viewModel: EEGAnalysisViewModel

    let packageName: String
    let signal: MFFSignalData
    let processing: EEGAnalysisProcessingSnapshot
    let artifactSources: [EEGArtifactRejectionSource]
    let excludedChannelIndices: Set<Int>
    let channelSets: [ChannelSet]
    let sensorLayout: SensorLayout?
    let onClose: () -> Void

    @State private var selectedTab = EEGAnalysisTab.segments
    @State private var selectedTopomapBandName = "Alpha"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            TabView(selection: $selectedTab) {
                segmentsTab
                    .tabItem { Text("Segments") }
                    .tag(EEGAnalysisTab.segments)
                spectralTab
                    .tabItem { Text("Spectral Power") }
                    .tag(EEGAnalysisTab.spectral)
                connectivityTab
                    .tabItem { Text("Connectivity") }
                    .tag(EEGAnalysisTab.connectivity)
                exportTab
                    .tabItem { Text("Export") }
                    .tag(EEGAnalysisTab.export)
            }
            .padding(16)

            Divider()
            footer
        }
        .frame(minWidth: 980, idealWidth: 1120, minHeight: 720, idealHeight: 780)
        .onAppear {
            viewModel.syncArtifactSources(artifactSources)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("EEG Analysis")
                    .font(.title3.weight(.semibold))
                Text(processing.signalDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(signal.numberOfChannels) channels · \(format(signal.samplingRate)) Hz · \(format(signal.duration)) s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if viewModel.isRunning {
                ProgressView(value: viewModel.progress)
                    .frame(width: 180)
                Text("\(Int((viewModel.progress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(viewModel.statusMessage ?? "Ready")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if viewModel.isRunning {
                Button("Cancel") { viewModel.cancel() }
            }
            Button(viewModel.result == nil ? "Run Analysis" : "Re-run Analysis") {
                viewModel.run(
                    packageName: packageName,
                    signal: signal,
                    processing: processing,
                    artifactSources: artifactSources,
                    excludedChannelIndices: excludedChannelIndices,
                    channelSets: channelSets
                )
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(viewModel.isRunning)

            Button("Close") { onClose() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var segmentsTab: some View {
        HStack(alignment: .top, spacing: 18) {
            Form {
                Section("Temporary Segments") {
                    HStack {
                        Slider(value: $viewModel.segmentLengthSeconds, in: 2...10, step: 1)
                        Text("\(Int(viewModel.segmentLengthSeconds)) s")
                            .font(.body.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                    Toggle("Keep Good", isOn: $viewModel.keepsGoodSegments)
                    Toggle("Keep Watch", isOn: $viewModel.keepsWatchSegments)
                    Toggle("Keep Poor", isOn: $viewModel.keepsPoorSegments)
                }

                Section("Artifact Rejection") {
                    HStack {
                        Slider(value: $viewModel.artifactRejectionThreshold, in: 0...0.50, step: 0.01)
                        Text("\(Int((viewModel.artifactRejectionThreshold * 100).rounded()))%")
                            .font(.body.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }

                    if artifactSources.isEmpty {
                        Text("No defined artifacts")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(artifactSources) { source in
                            Toggle(isOn: artifactSourceBinding(source.id)) {
                                HStack {
                                    Text(source.name)
                                    Spacer()
                                    Text("\(source.eventCount)")
                                        .foregroundStyle(.secondary)
                                        .font(.caption.monospacedDigit())
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 340)

            VStack(alignment: .leading, spacing: 12) {
                resultSummary
                segmentDecisionList
            }
        }
    }

    private var spectralTab: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Bands")
                    .font(.headline)
                ForEach(viewModel.frequencyBands) { band in
                    HStack {
                        Text(band.name)
                        Spacer()
                        Text("\(format(band.lowHz))-\(format(band.highHz)) Hz")
                            .foregroundStyle(.secondary)
                            .font(.caption.monospacedDigit())
                    }
                }

                Divider()

                if let spectral = viewModel.result?.spectral {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
                        ForEach(spectral.bands) { band in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(band.bandName)
                                    .font(.caption.weight(.semibold))
                                Text("\(formatPercent(band.meanRelativePower))")
                                    .font(.title3.monospacedDigit())
                                Text("relative power")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                } else {
                    ContentUnavailableView("No spectral results", systemImage: "waveform.path.ecg")
                }
            }
            .frame(width: 320)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if let spectral = viewModel.result?.spectral {
                    spectralTopography(spectral)
                    spectralChannelTable(spectral)
                } else {
                    Spacer()
                }
            }
        }
    }

    private var connectivityTab: some View {
        HStack(alignment: .top, spacing: 18) {
            Form {
                Section("Band") {
                    Picker("Band", selection: $viewModel.selectedConnectivityBandName) {
                        ForEach(viewModel.frequencyBands) { band in
                            Text(band.name).tag(band.name)
                        }
                    }
                }

                Section("Metrics") {
                    ForEach(EEGConnectivityMetric.allCases) { metric in
                        Toggle(metric.displayName, isOn: connectivityMetricBinding(metric))
                    }
                }

                Section("Scope") {
                    Toggle("Channel Matrix", isOn: $viewModel.includesChannelConnectivity)
                    Toggle("Region Matrix", isOn: $viewModel.includesRegionConnectivity)
                    Text("\(channelSets.count) channel sets available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 340)

            VStack(alignment: .leading, spacing: 12) {
                if let connectivity = viewModel.result?.connectivity {
                    connectivitySummary(connectivity)
                    connectivityPairTable(title: "Region Pairs", pairs: connectivity.regionPairs)
                    connectivityPairTable(title: "Channel Pairs", pairs: Array(connectivity.channelPairs.prefix(80)))
                } else {
                    ContentUnavailableView("No connectivity results", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
        }
    }

    private var exportTab: some View {
        HStack(alignment: .top, spacing: 18) {
            Form {
                Section("JSON / CSV Contents") {
                    Toggle("Per-channel spectral details", isOn: $viewModel.exportIncludesPerChannelDetails)
                    Toggle("Per-segment decisions", isOn: $viewModel.exportIncludesSegmentDetails)
                    Toggle("Connectivity pair values", isOn: $viewModel.exportIncludesConnectivityPairs)
                }

                Section("Files") {
                    Button("Save JSON...") { saveJSON() }
                        .disabled(viewModel.result == nil)
                    Button("Save CSV...") { saveCSV() }
                        .disabled(viewModel.result == nil)
                }
            }
            .formStyle(.grouped)
            .frame(width: 340)

            VStack(alignment: .leading, spacing: 12) {
                resultSummary
                if let result = viewModel.result {
                    exportPreview(result)
                } else {
                    ContentUnavailableView("No export ready", systemImage: "square.and.arrow.down")
                }
            }
        }
    }

    private var resultSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Result")
                .font(.headline)

            if let result = viewModel.result {
                HStack(spacing: 10) {
                    summaryTile("Segments", "\(result.segments.includedSegmentCount)/\(result.segments.totalSegmentCount)")
                    summaryTile("Duration", "\(format(result.segments.includedDurationSeconds)) s")
                    summaryTile("Channels", "\(result.recording.analyzedChannelCount)")
                    summaryTile("Pairs", "\(pairCount(result))")
                }
            } else {
                Text("Run analysis to populate segment, spectral, and connectivity results.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summaryTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var segmentDecisionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Segments")
                .font(.headline)
            if let decisions = viewModel.result?.segmentDecisions, !decisions.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        segmentHeader
                        ForEach(Array(decisions.prefix(120))) { decision in
                            segmentRow(decision)
                            Divider()
                        }
                    }
                }
            } else {
                ContentUnavailableView("No segment decisions", systemImage: "rectangle.split.3x1")
            }
        }
    }

    private var segmentHeader: some View {
        HStack {
            Text("#").frame(width: 44, alignment: .leading)
            Text("Time").frame(width: 120, alignment: .leading)
            Text("Health").frame(width: 90, alignment: .leading)
            Text("Artifact").frame(width: 90, alignment: .leading)
            Text("Decision").frame(width: 90, alignment: .leading)
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }

    private func segmentRow(_ decision: EEGAnalysisSegmentDecision) -> some View {
        HStack {
            Text("\(decision.segmentIndex + 1)").frame(width: 44, alignment: .leading)
            Text("\(format(decision.startTimeSeconds))-\(format(decision.endTimeSeconds))").frame(width: 120, alignment: .leading)
            Text("\(decision.healthGrade.displayName) \(decision.healthGoodPercentage)%").frame(width: 90, alignment: .leading)
            Text(formatPercent(decision.artifactOverlapFraction)).frame(width: 90, alignment: .leading)
            Text(decision.isIncluded ? "Keep" : "Reject")
                .foregroundStyle(decision.isIncluded ? .green : .red)
                .frame(width: 90, alignment: .leading)
            Text(decision.rejectionReasons.joined(separator: ", "))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .font(.caption.monospacedDigit())
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func spectralTopography(_ spectral: EEGSpectralAnalysisResult) -> some View {
        if let sensorLayout {
            let selectedBand = spectral.bands.first { $0.bandName == selectedTopomapBandName } ?? spectral.bands.first
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Relative Power Topography")
                        .font(.headline)
                    Spacer()
                    Picker("Band", selection: $selectedTopomapBandName) {
                        ForEach(spectral.bands) { band in
                            Text(band.bandName).tag(band.bandName)
                        }
                    }
                    .frame(width: 180)
                }
                if let selectedBand {
                    TopomapView(
                        layout: sensorLayout,
                        values: selectedBand.channelRelativePowers,
                        timeSeconds: 0,
                        fixedScale: max(selectedBand.channelRelativePowers.max() ?? 0, 0.01),
                        unitLabel: "relative",
                        showsHeader: false,
                        colorBarPlacement: .bottom,
                        minimumMapHeight: 210
                    )
                    .frame(height: 280)
                }
            }
        }
    }

    private func spectralChannelTable(_ spectral: EEGSpectralAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Channel Details")
                .font(.headline)
            ScrollView {
                LazyVStack(spacing: 0) {
                    HStack {
                        Text("Channel").frame(width: 120, alignment: .leading)
                        ForEach(spectral.bands) { band in
                            Text(band.bandName).frame(width: 92, alignment: .trailing)
                        }
                        Spacer()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)

                    ForEach(Array(spectral.channels.prefix(80))) { channel in
                        HStack {
                            Text(channel.channelName).frame(width: 120, alignment: .leading)
                            ForEach(spectral.bands) { band in
                                let value = channel.bandValues.first { $0.bandName == band.bandName }?.relativePower ?? 0
                                Text(formatPercent(value)).frame(width: 92, alignment: .trailing)
                            }
                            Spacer()
                        }
                        .font(.caption.monospacedDigit())
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }
    }

    private func connectivitySummary(_ connectivity: EEGConnectivityAnalysisResult) -> some View {
        HStack(spacing: 10) {
            summaryTile("Band", connectivity.band.name)
            summaryTile("Metrics", "\(connectivity.metrics.count)")
            summaryTile("Regions", "\(connectivity.regionPairs.count)")
            summaryTile("Channels", "\(connectivity.channelPairs.count)")
        }
    }

    private func connectivityPairTable(title: String, pairs: [EEGConnectivityPairResult]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if pairs.isEmpty {
                Text("No pairs")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(pairs) { pair in
                            HStack {
                                Text(pair.nodeA.name)
                                    .frame(width: 160, alignment: .leading)
                                Text(pair.nodeB.name)
                                    .frame(width: 160, alignment: .leading)
                                Text(metricText(pair.metricValues))
                                    .font(.caption.monospacedDigit())
                                    .lineLimit(1)
                                Spacer()
                            }
                            .font(.caption)
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
    }

    private func exportPreview(_ result: EEGAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recording Summary")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Package").foregroundStyle(.secondary)
                    Text(result.recording.packageName)
                }
                GridRow {
                    Text("Signal").foregroundStyle(.secondary)
                    Text(result.processing.signalDescription)
                }
                GridRow {
                    Text("Kept Segments").foregroundStyle(.secondary)
                    Text("\(result.segments.includedSegmentCount)/\(result.segments.totalSegmentCount)")
                }
                GridRow {
                    Text("Rejected by Health").foregroundStyle(.secondary)
                    Text("\(result.segments.rejectedByHealthCount)")
                }
                GridRow {
                    Text("Rejected by Artifact").foregroundStyle(.secondary)
                    Text("\(result.segments.rejectedByArtifactCount)")
                }
            }
            .font(.caption)
        }
    }

    private func artifactSourceBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.selectedArtifactSourceIDs.contains(id) },
            set: { isOn in
                if isOn {
                    viewModel.selectedArtifactSourceIDs.insert(id)
                } else {
                    viewModel.selectedArtifactSourceIDs.remove(id)
                }
            }
        )
    }

    private func connectivityMetricBinding(_ metric: EEGConnectivityMetric) -> Binding<Bool> {
        Binding(
            get: { viewModel.selectedConnectivityMetrics.contains(metric) },
            set: { viewModel.toggleConnectivityMetric(metric, isSelected: $0) }
        )
    }

    private func saveJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultExportName(extension: "json")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try viewModel.jsonData().write(to: url, options: .atomic)
            viewModel.statusMessage = "Saved EEG analysis JSON: \(url.lastPathComponent)"
        } catch {
            viewModel.statusMessage = error.localizedDescription
        }
    }

    private func saveCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultExportName(extension: "csv")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try viewModel.csvData().write(to: url, options: .atomic)
            viewModel.statusMessage = "Saved EEG analysis CSV: \(url.lastPathComponent)"
        } catch {
            viewModel.statusMessage = error.localizedDescription
        }
    }

    private func defaultExportName(extension ext: String) -> String {
        let base = (packageName as NSString).deletingPathExtension
        return "\(base)-eeg-analysis.\(ext)"
    }

    private func metricText(_ values: [EEGConnectivityMetricValue]) -> String {
        values
            .map { "\($0.metric.shortName)=\(format($0.value))" }
            .joined(separator: "  ")
    }

    private func pairCount(_ result: EEGAnalysisResult) -> Int {
        guard let connectivity = result.connectivity else { return 0 }
        return connectivity.channelPairs.count + connectivity.regionPairs.count
    }

    private func format(_ value: Double) -> String {
        if abs(value) >= 100 {
            return String(format: "%.0f", value)
        }
        if abs(value) >= 10 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.2f", value)
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

private enum EEGAnalysisTab {
    case segments
    case spectral
    case connectivity
    case export
}

