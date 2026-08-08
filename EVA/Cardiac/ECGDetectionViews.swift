//
//  ECGDetectionViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ECG / QRS detection sheet and its supporting helpers, extracted from
//  WaveformView.swift during the L5 view-decomposition refactor. This is an
//  extension of WaveformView (not a standalone type) — the helpers read/write
//  WaveformView's own @State, so this is a file split, not a state extraction.
//

import SwiftUI

extension WaveformView {
    func openECGDetectionSheet(for signal: MFFSignalData) {
        prepareECGDetectionDefaults(for: signal, pns: displayedPhysioSignal())
        ecg.showsSheet = true
    }

    func prepareECGDetectionDefaults(for signal: MFFSignalData, pns: MFFSignalData?) {
        if let pns {
            ecg.selectedPNSChannels = ecg.selectedPNSChannels
                .filter { pns.data.indices.contains($0) }
            if ecg.selectedPNSChannels.isEmpty && ecg.proxyChannels.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ecg.selectedPNSChannels = Set(likelyECGPNSChannelIndices(in: pns))
            }
        } else {
            ecg.selectedPNSChannels.removeAll()
        }

        let proxyChannels = WaveformView.parseChannelList(ecg.proxyChannels, channelCount: signal.numberOfChannels)
        if proxyChannels.count != Set(proxyChannels).count {
            ecg.proxyChannels = proxyChannels.map { String($0 + 1) }.joined(separator: ", ")
        }
    }

    func ecgDetectionSheet(for signal: MFFSignalData) -> some View {
        let pns = displayedPhysioSignal()
        let sources = ecgDetectionSources(for: signal)

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ECG / QRS Detection")
                    .font(.headline)
                Text("Select PNS channels, EEG proxy channels, or both. Detected QRS complexes (or pulse-ox systolic peaks, via the Pulse-Ox method) appear as artifact events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if let pns {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("PNS Channels")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button("Likely ECG") {
                            ecg.selectedPNSChannels = Set(likelyECGPNSChannelIndices(in: pns))
                        }
                        Button("All") {
                            ecg.selectedPNSChannels = Set(pns.data.indices)
                        }
                        Button("None") {
                            ecg.selectedPNSChannels.removeAll()
                        }
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(pns.data.indices), id: \.self) { index in
                                Toggle(pnsChannelDisplayName(index: index, signal: pns), isOn: ecgPNSSelectionBinding(for: index))
                                    .font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 130)
                }
            } else {
                Text("No PNS channels are available for this recording. Use EEG proxy channels below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("EEG Proxy Channels")
                    .font(.caption.weight(.semibold))
                ChannelSetPickerView(
                    label: "Channel Set",
                    selectedSetID: $ecg.proxyChannelSetID,
                    channelCount: signal.numberOfChannels,
                    includesCustom: true
                )
                .onChange(of: ecg.proxyChannelSetID) { _, id in
                    if id == ChannelSetPickerView.customSentinel {
                        // Leave the manual field as-is for editing.
                    } else if let id, let set = ChannelSetStore.shared.allSets.first(where: { $0.id == id }) {
                        ecg.proxyChannels = set.channelIndices.map { String($0 + 1) }.joined(separator: ", ")
                    } else {
                        ecg.proxyChannels = ""
                    }
                }

                if ecg.proxyChannelSetID == ChannelSetPickerView.customSentinel {
                    TextField("1, 8, 25 or 1-4", text: $ecg.proxyChannels)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Visible Good") {
                            let indices = signal.data.indices.filter { !channels.hidden.contains($0) && !channels.bad.contains($0) }
                            ecg.proxyChannels = indices.map { String($0 + 1) }.joined(separator: ", ")
                        }
                        Button("Clear") {
                            ecg.proxyChannels = ""
                        }
                        Spacer()
                        Text(ecgProxySummary(in: signal))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if ecg.proxyChannelSetID != nil {
                    Text(ecgProxySummary(in: signal))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Detection")
                    .font(.caption.weight(.semibold))

                Picker("Polarity", selection: $ecg.polarity) {
                    ForEach(ECGDetectionPolarity.allCases) { polarity in
                        Text(polarity.rawValue).tag(polarity)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack {
                    Text("Threshold")
                        .font(.caption)
                        .frame(width: 86, alignment: .leading)
                    TextField("Threshold", value: $ecg.thresholdSD, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("robust SD")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $ecg.thresholdSD, in: 2...10, step: 0.5)
                }

                HStack {
                    Text("Min RR")
                        .font(.caption)
                        .frame(width: 86, alignment: .leading)
                    TextField("Min RR", value: $ecg.minimumRRSeconds, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $ecg.minimumRRSeconds, in: 0.20...1.20, step: 0.05)
                }
            }

            Text(ecgSourceSummary(sources))
                .font(.caption)
                .foregroundStyle(sources.isEmpty ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            ecgAlgorithmComparisonView()

            HStack {
                if ecg.isEnabled {
                    Button("Disable ECG Detection", role: .destructive) {
                        ecg.isEnabled = false
                        artifactVM.detectionRefreshToken += 1
                        ecg.showsSheet = false
                    }
                }

                Spacer()

                Button("Cancel") {
                    ecg.showsSheet = false
                }
                Button("Detect QRS") {
                    ecg.isEnabled = true
                    artifactVM.detectionMethod = .threshold
                    artifactVM.detectionRefreshToken += 1
                    ecg.showsSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sources.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620)
        .task(id: ecgDetectionPreviewRequestID(for: signal)) {
            await refreshECGDetectionEstimate(for: signal)
        }
        .onAppear {
            prepareECGDetectionDefaults(for: signal, pns: pns)
        }
    }

    func ecgPNSSelectionBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { ecg.selectedPNSChannels.contains(index) },
            set: { isSelected in
                if isSelected {
                    ecg.selectedPNSChannels.insert(index)
                } else {
                    ecg.selectedPNSChannels.remove(index)
                }
            }
        )
    }

    @ViewBuilder
    func ecgAlgorithmComparisonView() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Algorithm Comparison")
                    .font(.caption.weight(.semibold))
                Spacer()
                if ecg.isEstimating {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if ecg.algorithmResults.isEmpty && !ecg.isEstimating {
                Text("Select channels above to preview detection.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Algorithm")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("QRS")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("BPM")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("")
                    }
                    Divider()
                        .gridCellUnsizedAxes(.horizontal)
                        .gridCellColumns(4)
                    ForEach(ECGDetectionAlgorithm.allCases, id: \.self) { algo in
                        GridRow {
                            Text(algo.displayName)
                                .font(.caption2)
                            if let result = ecg.algorithmResults[algo] {
                                Text("\(result.count)")
                                    .font(.caption2.monospacedDigit())
                                if let bpm = result.bpm, bpm.isFinite {
                                    Text(String(format: "%.0f", bpm))
                                        .font(.caption2.monospacedDigit())
                                } else {
                                    Text("—")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text(ecg.isEstimating ? "…" : "—")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("")
                            }
                            Button {
                                ecg.algorithm = algo
                            } label: {
                                Image(systemName: ecg.algorithm == algo ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(ecg.algorithm == algo ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Use \(algo.displayName) for detection")
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func ecgDetectionPreviewRequestID(for signal: MFFSignalData) -> String {
        [
            signal.signalURL.path,
            "\(signal.numberOfChannels)",
            "\(signal.data.first?.count ?? 0)",
            displayedPhysioSignal().map { physioRangeTaskID(for: $0) } ?? "noPNS",
            ecg.selectedPNSChannels.sorted().map(String.init).joined(separator: ","),
            ecg.proxyChannels,
            ecg.polarity.rawValue,
            String(format: "%.3f", ecg.thresholdSD),
            String(format: "%.3f", ecg.minimumRRSeconds)
        ].joined(separator: "|")
    }

    @MainActor
    func refreshECGDetectionEstimate(for signal: MFFSignalData) async {
        let requestID = ecgDetectionPreviewRequestID(for: signal)
        let sources = ecgDetectionSources(for: signal)
        guard !sources.isEmpty else {
            ecg.isEstimating = false
            ecg.algorithmResults = [:]
            return
        }

        ecg.isEstimating = true
        ecg.algorithmResults = [:]

        let thresholdSD = ecg.thresholdSD
        let minRR = ecg.minimumRRSeconds
        let polarity = ecg.polarity
        let duration = sources.map(\.duration).max() ?? signal.duration

        let results = await withTaskGroup(
            of: (ECGDetectionAlgorithm, Int).self,
            returning: [ECGDetectionAlgorithm: ECGAlgorithmResult].self
        ) { group in
            for algorithm in ECGDetectionAlgorithm.allCases {
                let config = ECGDetectionConfiguration(
                    algorithm: algorithm,
                    thresholdSD: thresholdSD,
                    minimumRRSeconds: minRR,
                    polarity: polarity
                )
                group.addTask(priority: .utility) {
                    let count = RWaveDetector.detect(sources: sources, configuration: config).count
                    return (algorithm, count)
                }
            }
            var out: [ECGDetectionAlgorithm: ECGAlgorithmResult] = [:]
            for await (algo, count) in group {
                let bpm = duration > 0 ? Double(count) / duration * 60 : nil
                out[algo] = ECGAlgorithmResult(count: count, bpm: bpm)
            }
            return out
        }

        guard !Task.isCancelled, requestID == ecgDetectionPreviewRequestID(for: signal) else { return }
        ecg.isEstimating = false
        ecg.algorithmResults = results
    }

    func pnsChannelDisplayName(index: Int, signal: MFFSignalData) -> String {
        let name = signal.channelNames?.indices.contains(index) == true
            ? signal.channelNames?[index].nilIfEmpty ?? "PNS \(index + 1)"
            : "PNS \(index + 1)"
        return "\(index + 1): \(name)"
    }

    func eegChannelDisplayName(index: Int, signal: MFFSignalData) -> String {
        let name = signal.channelNames?.indices.contains(index) == true
            ? signal.channelNames?[index].nilIfEmpty ?? "Ch \(index + 1)"
            : "Ch \(index + 1)"
        return "\(index + 1): \(name)"
    }

    func likelyECGPNSChannelIndices(in pns: MFFSignalData) -> [Int] {
        let names = pns.channelNames ?? []
        let cardiacTokens = ["ecg", "ekg", "card", "heart"]
        let pulseTokens = ["pulse", "pleth", "ppg"]

        let cardiac = pns.data.indices.filter { index in
            guard names.indices.contains(index) else { return false }
            let lower = names[index].lowercased()
            return cardiacTokens.contains { lower.contains($0) }
        }
        if !cardiac.isEmpty { return cardiac }

        let pulse = pns.data.indices.filter { index in
            guard names.indices.contains(index) else { return false }
            let lower = names[index].lowercased()
            return pulseTokens.contains { lower.contains($0) }
        }
        if !pulse.isEmpty { return pulse }

        return pns.data.indices.first.map { [$0] } ?? []
    }

    func ecgProxySummary(in signal: MFFSignalData) -> String {
        let indices = WaveformView.parseChannelList(ecg.proxyChannels, channelCount: signal.numberOfChannels)
        guard !indices.isEmpty else { return "No EEG proxy channels selected" }
        return "\(indices.count) EEG proxy channel\(indices.count == 1 ? "" : "s")"
    }

    func ecgSourceSummary(_ sources: [ECGDetectionSource]) -> String {
        guard !sources.isEmpty else {
            return "Choose at least one PNS channel or EEG proxy channel before detecting QRS complexes."
        }
        let channelCount = sources.reduce(0) { $0 + $1.channelLabels.count }
        return "Will detect from \(channelCount) channel\(channelCount == 1 ? "" : "s") across \(sources.count) source group\(sources.count == 1 ? "" : "s")."
    }

    func ecgDetectionSources(for signal: MFFSignalData) -> [ECGDetectionSource] {
        var sources: [ECGDetectionSource] = []

        if let pns = displayedPhysioSignal() {
            let indices = ecg.selectedPNSChannels.sorted().filter { pns.data.indices.contains($0) }
            let valid = indices.filter { pns.data[$0].count == (pns.data.first?.count ?? 0) }
            if !valid.isEmpty {
                sources.append(
                    ECGDetectionSource(
                        id: "pns",
                        label: "PNS",
                        channelLabels: valid.map { pnsChannelDisplayName(index: $0, signal: pns) },
                        channels: valid.map { pns.data[$0] },
                        samplingRate: pns.samplingRate,
                        duration: min(pns.duration, signal.duration)
                    )
                )
            }
        }

        let eegIndices = WaveformView.parseChannelList(ecg.proxyChannels, channelCount: signal.numberOfChannels)
            .filter { signal.data.indices.contains($0) }
        let eegValid = eegIndices.filter { signal.data[$0].count == (signal.data.first?.count ?? 0) }
        if !eegValid.isEmpty {
            sources.append(
                ECGDetectionSource(
                    id: "eeg",
                    label: "EEG proxy",
                    channelLabels: eegValid.map { eegChannelDisplayName(index: $0, signal: signal) },
                    channels: eegValid.map { signal.data[$0] },
                    samplingRate: signal.samplingRate,
                    duration: signal.duration
                )
            )
        }

        return sources
    }
}
