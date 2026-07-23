//
//  WaveletArtifactExplorerViews.swift
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
//  Wavelet artifact explorer sheet and its supporting helpers, extracted from
//  WaveformView.swift during the L5 view-decomposition refactor. This is an
//  extension of WaveformView (not a standalone type), following the same
//  pattern as the other L5 slices -- the cluster reads/writes WaveformView's
//  own stores (wavelet, artifactVM) and state, so this is a file split, not a
//  state extraction.
//

import SwiftUI

extension WaveformView {
    // MARK: - Wavelet artifact explorer

    func openWaveletArtifactExplorer(for signal: MFFSignalData) {
        waveletExplorer.downsampleRate = min(max(waveletExplorer.downsampleRate, 20), signal.samplingRate)
        waveletExplorer.statusMessage = nil
        if waveletExplorer.statusTitle.isEmpty {
            applyWaveletExplorerPipelineDefaults(waveletExplorer.pipeline, samplingRate: signal.samplingRate, updatesStatus: false)
            waveletExplorer.statusTitle = "Wavelet artifact explorer ready"
            waveletExplorer.statusDetail = "\(waveletExplorerChannels(in: signal).count) channels selected for exploratory multiscale scanning."
        }
        waveletExplorer.showsSheet = true
    }

    @ViewBuilder
    func waveletReductionSheet(input: MFFSignalData) -> some View {
        let reduceCount = input.data.indices.filter { !channels.bad.contains($0) }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wavelet Artifact Reduction")
                        .font(.title3.weight(.semibold))
                    Text("Subtracts a wavelet reconstruction of the large coefficients (HAPPE-style), leaving the low-amplitude signal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(reduceCount) channels · \(Int(input.samplingRate.rounded())) Hz")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                waveletReductionSettingsColumn(input: input, reduceCount: reduceCount)
                    .frame(width: 320)

                Divider()

                waveletReductionInspector(input: input)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Divider()

            HStack {
                if wavelet.reducedSignal != nil {
                    Toggle("Show reduction", isOn: Binding(
                        get: { wavelet.isEnabled },
                        set: { setWaveletReductionEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    Button("Revert") { revertWaveletReduction() }
                }
                Spacer()
                Button(wavelet.reducedSignal == nil ? "Run" : "Re-run") {
                    runWaveletReduction(on: input)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(wavelet.isRunning || reduceCount == 0)
                Button("Close") { wavelet.showsSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 840, height: 640)
    }

    @ViewBuilder
    func waveletReductionSettingsColumn(input: MFFSignalData, reduceCount: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Mode", selection: $wavelet.mode) {
                    ForEach(WaveletReductionMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: wavelet.mode) { _, newMode in
                    wavelet.config = newMode.defaultConfiguration(samplingRate: input.samplingRate)
                }

                Text(wavelet.mode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Transform")
                        Picker("", selection: $wavelet.config.kind) {
                            ForEach(WaveletTransformKind.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                    GridRow {
                        Text("Wavelet")
                        Picker("", selection: $wavelet.config.family) {
                            ForEach(WaveletReductionFamily.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                    GridRow {
                        Text("Threshold rule")
                        Picker("", selection: $wavelet.config.thresholdRule) {
                            ForEach(WaveletCleaningThresholdRule.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                    GridRow {
                        Text("Threshold model")
                        Picker("", selection: $wavelet.config.thresholdModel) {
                            ForEach(WaveletCleaningThresholdModel.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                    GridRow {
                        Text("Levels")
                        Stepper("\(wavelet.config.levelCount)", value: $wavelet.config.levelCount, in: 1...WaveletReducer.maximumLevelCount)
                            .frame(width: 120)
                    }
                    GridRow {
                        Text("Strength")
                        TextField("x", value: $wavelet.config.thresholdScale, format: .number.precision(.fractionLength(2)))
                            .frame(width: 80)
                    }
                    GridRow {
                        Text("Downsample")
                        Picker("", selection: $wavelet.config.downsampleFactor) {
                            ForEach(downsampleFactorOptions(for: input.samplingRate), id: \.self) { factor in
                                Text(downsampleFactorLabel(factor: factor, rate: input.samplingRate)).tag(factor)
                            }
                        }
                        .labelsHidden().frame(width: 150)
                    }
                    GridRow {
                        Text("CPU cores")
                        Stepper("\(wavelet.coreCount) of \(WaveletReducer.maximumCoreCount)", value: $wavelet.coreCount, in: 1...WaveletReducer.maximumCoreCount)
                            .frame(width: 140)
                    }
                }
                .font(.callout)

                if wavelet.isRunning {
                    ProgressView(value: wavelet.progress)
                    Text("\(Int((wavelet.progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let result = wavelet.result {
                    Divider()
                    waveletReductionQCView(result: result)
                } else if let message = wavelet.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    func waveletReductionInspector(input: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inspect Changes")
                .font(.headline)

            if wavelet.candidates.isEmpty {
                Spacer()
                Text("Run a reduction to see the largest changes it made, channel by channel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                Spacer()
            } else {
                if let candidate = selectedWaveletCandidate {
                    waveletCandidatePlot(candidate: candidate, input: input)
                        .frame(height: 160)
                    Text("Ch \(candidate.channelIndex + 1) · peak \(String(format: "%.2f", candidate.peakTimeSeconds))s · removed \(String(format: "%.2f", candidate.peakRemovedMicrovolts)) µV")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let result = wavelet.result {
                    waveletPerLevelBars(result: result)
                }

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(wavelet.candidates) { candidate in
                            Button {
                                wavelet.selectedCandidateID = candidate.id
                            } label: {
                                HStack {
                                    Text("#\(candidate.rank)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, alignment: .leading)
                                    Text("Ch \(candidate.channelIndex + 1)")
                                        .font(.caption.weight(.medium))
                                        .frame(width: 56, alignment: .leading)
                                    Text("\(String(format: "%.1f", candidate.peakTimeSeconds))s")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(String(format: "%.1f", candidate.peakRemovedMicrovolts)) µV")
                                        .font(.caption.monospacedDigit())
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(candidate.id == wavelet.selectedCandidateID
                                            ? Color.accentColor.opacity(0.18)
                                            : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// Downsample factors that keep the decimated rate usable (≥ ~100 Hz),
    /// always including the currently-selected factor so the picker stays valid.
    func downsampleFactorOptions(for rate: Double) -> [Int] {
        var options = [1, 2, 4, 8].filter { $0 == 1 || rate / Double($0) >= 100 }
        if !options.contains(wavelet.config.downsampleFactor) {
            options.append(wavelet.config.downsampleFactor)
        }
        return options.sorted()
    }

    func downsampleFactorLabel(factor: Int, rate: Double) -> String {
        let decimatedRate = Int((rate / Double(max(factor, 1))).rounded())
        return factor == 1 ? "Full (\(decimatedRate) Hz)" : "\(decimatedRate) Hz"
    }

    var selectedWaveletCandidate: WaveletReductionCandidate? {
        wavelet.candidates.first { $0.id == wavelet.selectedCandidateID }
            ?? wavelet.candidates.first
    }

    @ViewBuilder
    func waveletCandidatePlot(candidate: WaveletReductionCandidate, input: MFFSignalData) -> some View {
        let channel = candidate.channelIndex
        let start = candidate.startSample
        let end = min(candidate.endSample, input.data[safe: channel]?.count ?? 0)
        let original = input.data[safe: channel].map { Array($0[start..<max(start, end)]) } ?? []
        let cleaned = wavelet.reducedSignal?.data[safe: channel].map { Array($0[start..<min(end, $0.count)]) } ?? []
        let removed = wavelet.artifact?.data[safe: channel].map { Array($0[start..<min(end, $0.count)]) } ?? []
        let scale = (original.map(abs).max() ?? 1)

        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
            GeometryReader { geo in
                ZStack {
                    tracePath(original, in: geo.size, scale: scale).stroke(Color.secondary, lineWidth: 1)
                    tracePath(removed, in: geo.size, scale: scale).stroke(Color.red.opacity(0.85), lineWidth: 1)
                    tracePath(cleaned, in: geo.size, scale: scale).stroke(Color.accentColor, lineWidth: 1.3)
                }
                .padding(6)
            }
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    legendDot(.secondary, "Original")
                    legendDot(.red.opacity(0.85), "Removed")
                    legendDot(.accentColor, "Cleaned")
                }
                .font(.caption2)
                .padding(.bottom, 4)
            }
        }
    }

    func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
        }
    }

    func tracePath(_ samples: [Float], in size: CGSize, scale: Float) -> Path {
        Path { path in
            guard samples.count > 1, scale > 0 else { return }
            let midY = size.height / 2
            let amp = Double(size.height) / 2 * 0.9
            for index in samples.indices {
                let x = size.width * CGFloat(index) / CGFloat(samples.count - 1)
                let y = midY - CGFloat(Double(samples[index]) / Double(scale) * amp)
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }

    @ViewBuilder
    func waveletPerLevelBars(result: WaveletReductionResult) -> some View {
        let metrics = Array(result.perChannel.values)
        let levelCount = metrics.map(\.removedEnergyByLevel.count).max() ?? 0
        if levelCount > 0 {
            let averages: [Double] = (0..<levelCount).map { level in
                let values = metrics.compactMap { $0.removedEnergyByLevel[safe: level] }
                return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Removed energy by level (fine → coarse)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(averages.indices, id: \.self) { level in
                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.red.opacity(0.7))
                                .frame(height: max(2, CGFloat(averages[level]) * 44))
                            Text("\(level + 1)")
                                .font(.system(size: 8).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 56, alignment: .bottom)
            }
        }
    }

    @ViewBuilder
    func waveletReductionQCView(result: WaveletReductionResult) -> some View {
        let metrics = Array(result.perChannel.values)
        let meanPeak = metrics.isEmpty ? 0 : metrics.map(\.peakReductionPercent).reduce(0, +) / Double(metrics.count)
        let meanRemoved = metrics.isEmpty ? 0 : metrics.map(\.removedRMSMicrovolts).reduce(0, +) / Double(metrics.count)
        VStack(alignment: .leading, spacing: 6) {
            Text("Quality").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Variance retained").foregroundStyle(.secondary)
                    Text(String(format: "%.1f%%", result.varianceRetainedPercent)).monospacedDigit()
                }
                if let band = wavelet.bandVarianceRetained {
                    GridRow {
                        Text("In-band retained").foregroundStyle(.secondary)
                        Text(String(format: "%.1f%%", band)).monospacedDigit()
                    }
                }
                GridRow {
                    Text("Mean correlation").foregroundStyle(.secondary)
                    Text(String(format: "%.3f", result.meanCorrelation)).monospacedDigit()
                }
                GridRow {
                    Text("Avg peak reduction").foregroundStyle(.secondary)
                    Text(String(format: "%.1f%%", meanPeak)).monospacedDigit()
                }
                GridRow {
                    Text("Avg removed RMS").foregroundStyle(.secondary)
                    Text(String(format: "%.2f µV", meanRemoved)).monospacedDigit()
                }
            }
            .font(.callout)
            Text("Higher variance/correlation = more of the original signal preserved; larger peak reduction/removed RMS = more artifact taken out.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func waveletArtifactExplorerSheet(for signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Wavelet Artifact Explorer")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(waveletExplorerChannels(in: signal).count) channels · \(Int(signal.samplingRate.rounded())) Hz")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    waveletExplorerConfigurationSection(signal: signal)
                    waveletExplorerProgressSection

                    if let explorerResult = waveletExplorer.result {
                        waveletExplorerResultView(explorerResult, signal: signal)
                    } else {
                        artifactDefinitionEmptyPreview(
                            title: "No wavelet explorer scan yet",
                            detail: "Run a broad multiscale scan to rank transient artifact candidates, noisy channels, and dominant wavelet levels."
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button("Clear Results") {
                    waveletExplorer.result = nil
                    waveletExplorer.log.removeAll()
                    waveletExplorer.progress = 0
                    waveletExplorer.statusTitle = "Wavelet artifact explorer ready"
                    waveletExplorer.statusDetail = "\(waveletExplorerChannels(in: signal).count) channels selected for exploratory multiscale scanning."
                    waveletExplorer.statusMessage = nil
                }
                .disabled(waveletExplorer.isRunning && waveletExplorer.result == nil && waveletExplorer.log.isEmpty)

                Spacer()

                Button("Close") {
                    waveletExplorer.showsSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button(waveletExplorer.result == nil ? "Run Wavelet Scan" : "Rescan Wavelets") {
                    runWaveletArtifactExplorer(in: signal)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(waveletExplorer.isRunning || waveletExplorerChannels(in: signal).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 860)
        .frame(minHeight: 640, idealHeight: 760, maxHeight: 820)
    }

    func waveletExplorerConfigurationSection(signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Pipeline",
                        help: "Preset defaults for HAPPE-inspired wavelet cleaning. EEG emphasizes stronger transient rejection; ERP keeps a smoother, gentler residual."
                    )
                    Picker(
                        "Pipeline",
                        selection: Binding {
                            waveletExplorer.pipeline
                        } set: { pipeline in
                            waveletExplorer.pipeline = pipeline
                            applyWaveletExplorerPipelineDefaults(pipeline, samplingRate: signal.samplingRate)
                        }
                    ) {
                        ForEach(WaveletCleaningPipeline.allCases) { pipeline in
                            Text(pipeline.rawValue).tag(pipeline)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)

                    ArtifactTemplateFieldLabel(
                        title: "Wavelet",
                        help: "bior4.4 is the non-ERP HAPPE-style choice; coif4 is the ERP-oriented choice."
                    )
                    Picker("Wavelet", selection: $waveletExplorer.waveletFamily) {
                        ForEach(WaveletCleaningFamily.allCases) { family in
                            Text(family.rawValue).tag(family)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Mode",
                        help: "Cleaning profile layered on top of the EEG/ERP pipeline."
                    )
                    Picker(
                        "Mode",
                        selection: Binding {
                            waveletExplorer.cleaningMode
                        } set: { mode in
                            waveletExplorer.cleaningMode = mode
                            applyWaveletExplorerCleaningModeDefaults(mode)
                        }
                    ) {
                        ForEach(WaveletCleaningMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 180)

                    ArtifactTemplateFieldLabel(
                        title: "Intensity",
                        help: "Higher values lower the effective coefficient gate and show stronger preview removal."
                    )
                    HStack {
                        Slider(value: $waveletExplorer.intensity, in: 0.25...2.50, step: 0.05)
                        Text(String(format: "%.2fx", waveletExplorer.intensity))
                            .font(.caption.monospacedDigit())
                            .frame(width: 46, alignment: .trailing)
                    }
                    .frame(width: 190)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Channels",
                        help: "Channels included in the broad wavelet artifact scan."
                    )
                    Picker("Channels", selection: $waveletExplorer.channelScope) {
                        ForEach(WaveletExplorerChannelScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)

                    ArtifactTemplateFieldLabel(
                        title: "Downsample Hz",
                        help: "Temporary sampling rate for exploratory scanning. Lower rates are faster and usually enough for broad artifacts."
                    )
                    TextField("Hz", value: $waveletExplorer.downsampleRate, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Levels",
                        help: "Number of undecimated wavelet detail levels to inspect."
                    )
                    Stepper(value: $waveletExplorer.levelCount, in: 1...WaveletArtifactAnalyzer.maximumLevelCount) {
                        Text("\(waveletExplorer.levelCount)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 30, alignment: .leading)
                    }
                    .frame(width: 180, alignment: .leading)

                    ArtifactTemplateFieldLabel(
                        title: "Model",
                        help: "Universal uses a robust MAD threshold per level. BayesShrink adapts each level's threshold from estimated noise and signal variance."
                    )
                    Picker("Model", selection: $waveletExplorer.thresholdModel) {
                        ForEach(WaveletCleaningThresholdModel.allCases) { model in
                            Text(model.rawValue).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Rule",
                        help: "Hard thresholding removes retained coefficients directly; soft thresholding shrinks retained coefficients for smoother ERP-style cleanup."
                    )
                    Picker("Rule", selection: $waveletExplorer.thresholdRule) {
                        ForEach(WaveletCleaningThresholdRule.allCases) { rule in
                            Text(rule.rawValue).tag(rule)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)

                    ArtifactTemplateFieldLabel(
                        title: "Coeff Gate",
                        help: "Multiplier on each channel/level's coefficient threshold after the selected model estimates it."
                    )
                    HStack {
                        Slider(value: $waveletExplorer.thresholdScale, in: 0.50...3.00, step: 0.05)
                        Text(String(format: "%.2fx", waveletExplorer.thresholdScale))
                            .font(.caption.monospacedDigit())
                            .frame(width: 46, alignment: .trailing)
                    }
                    .frame(width: 190)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Merge (s)",
                        help: "Nearby wavelet bursts closer than this interval are merged into one candidate."
                    )
                    TextField("Merge", value: $waveletExplorer.mergeWindowSeconds, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    ArtifactTemplateFieldLabel(
                        title: "Min Dur (s)",
                        help: "Shortest over-threshold wavelet burst to keep as a candidate."
                    )
                    TextField("Duration", value: $waveletExplorer.minimumDurationSeconds, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }

                GridRow {

                    ArtifactTemplateFieldLabel(
                        title: "Candidates",
                        help: "Maximum number of ranked wavelet artifact candidates retained for review."
                    )
                    Stepper(value: $waveletExplorer.maximumCandidates, in: 10...300, step: 10) {
                        Text("\(waveletExplorer.maximumCandidates)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 42, alignment: .leading)
                    }
                    .frame(width: 180, alignment: .leading)

                    Text("")
                        .gridCellColumns(2)
                }

                GridRow {
                    Text("\(waveletExplorerChannels(in: signal).count) readable channels · \(waveletExplorer.thresholdModel.rawValue) · effective gate \(String(format: "%.2fx", effectiveWaveletExplorerThresholdScale)) · bad channels excluded where applicable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridCellColumns(4)
                }
            }
        }
        .disabled(waveletExplorer.isRunning)
    }

    var waveletExplorerProgressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(waveletExplorer.statusTitle.nilIfEmpty ?? "Wavelet scan idle")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(Int((waveletExplorer.progress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: waveletExplorer.progress)
                .progressViewStyle(.linear)

            Text(waveletExplorer.statusDetail.nilIfEmpty ?? "Configure the scan and run the explorer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if waveletExplorer.isRunning && !waveletExplorer.log.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(waveletExplorer.log.suffix(80))) { line in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.title)
                                    .font(.caption2.weight(.semibold))
                                Text(line.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 118)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    func waveletExplorerResultView(_ result: WaveletArtifactExplorerResult, signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                waveletExplorerMetricChip(title: "Candidates", value: "\(result.candidates.count)")
                waveletExplorerMetricChip(title: "Artifact energy", value: waveletExplorerPercent(result.summary.artifactEnergyFraction))
                waveletExplorerMetricChip(title: "Effective Hz", value: String(format: "%.1f", result.effectiveSamplingRate))
                waveletExplorerMetricChip(title: "Threshold", value: String(format: "%.3f", result.candidateThreshold))
            }

            HStack(alignment: .top, spacing: 16) {
                waveletExplorerChannelSummary(result.summary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                waveletExplorerLevelSummary(result.summary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            waveletExplorerCandidateTable(result.candidates, signal: signal)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    func waveletExplorerMetricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    func waveletExplorerChannelSummary(_ summary: WaveletArtifactFeatureSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Strongest channels")
                .font(.caption.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Ch")
                    Text("Energy")
                    Text("Peak")
                    Text("Level")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(summary.strongestChannels.prefix(8)) { channel in
                    GridRow {
                        Text("\(channel.channelIndex + 1)")
                        Text(waveletExplorerPercent(channel.artifactEnergyFraction))
                        Text(waveletExplorerMicrovolts(channel.peakArtifactMagnitude))
                        Text("L\(channel.dominantLevel)")
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
    }

    func waveletExplorerLevelSummary(_ summary: WaveletArtifactFeatureSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dominant levels")
                .font(.caption.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Level")
                    Text("Center Hz")
                    Text("Energy")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(summary.levelSummaries) { level in
                    GridRow {
                        Text("L\(level.level)")
                        Text(String(format: "%.1f", level.centerFrequencyHz))
                        Text(waveletExplorerPercent(level.artifactEnergyFraction))
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
    }

    func waveletExplorerCandidateTable(_ candidates: [WaveletArtifactCandidate], signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ranked candidates")
                .font(.caption.weight(.semibold))

            if candidates.isEmpty {
                Text("No over-threshold wavelet bursts met the current duration and merge settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        GridRow {
                            Text("#")
                            Text("Peak")
                            Text("Duration")
                            Text("Score")
                            Text("Peak Ch")
                            Text("Level")
                            Text("Contrib")
                            Text("Preview")
                            Text("")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                        ForEach(candidates) { candidate in
                            GridRow {
                                Text("\(candidate.rank)")
                                Text(formattedEventTime(candidate.peakTimeSeconds))
                                Text(String(format: "%.3fs", candidate.durationSeconds))
                                Text(String(format: "%.3f", candidate.score))
                                Text("Ch \(candidate.channelIndex + 1)")
                                Text("L\(candidate.dominantLevel)")
                                Text("\(candidate.contributingChannelCount)")
                                WaveletCleaningPreviewButton(
                                    candidate: candidate,
                                    signal: signal,
                                    configuration: waveletCleaningConfiguration(for: signal, candidate: candidate)
                                )
                                Button("Jump") {
                                    jumpToWaveletCandidate(candidate, in: signal)
                                }
                                .font(.caption)
                            }
                            .font(.caption.monospacedDigit())
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 190)
            }
        }
    }

    func applyWaveletExplorerPipelineDefaults(
        _ pipeline: WaveletCleaningPipeline,
        samplingRate: Double,
        updatesStatus: Bool = true
    ) {
        waveletExplorer.waveletFamily = pipeline.defaultFamily
        waveletExplorer.thresholdRule = pipeline.defaultThresholdRule
        waveletExplorer.thresholdModel = pipeline.defaultThresholdModel
        waveletExplorer.thresholdScale = pipeline.defaultThresholdScale
        let defaultMode: WaveletCleaningMode = pipeline == .erp ? .erpGentle : .conservativeLocal
        waveletExplorer.cleaningMode = defaultMode
        waveletExplorer.intensity = defaultMode.defaultIntensity
        waveletExplorer.levelCount = min(
            max(pipeline.defaultLevelCount(samplingRate: samplingRate), 1),
            WaveletArtifactAnalyzer.maximumLevelCount
        )

        guard updatesStatus else { return }
        waveletExplorer.statusTitle = "\(pipeline.rawValue) wavelet defaults applied"
        waveletExplorer.statusDetail = "\(pipeline.defaultFamily.rawValue), \(pipeline.defaultThresholdModel.rawValue), \(pipeline.defaultThresholdRule.rawValue.lowercased()) threshold, \(defaultMode.rawValue), \(waveletExplorer.levelCount) levels, and a \(String(format: "%.2f", effectiveWaveletExplorerThresholdScale))x effective coefficient gate. You can still edit every value."
        waveletExplorer.statusMessage = nil
    }

    func applyWaveletExplorerCleaningModeDefaults(
        _ mode: WaveletCleaningMode,
        updatesStatus: Bool = true
    ) {
        waveletExplorer.intensity = mode.defaultIntensity
        guard updatesStatus else { return }
        waveletExplorer.statusTitle = "\(mode.rawValue) mode applied"
        waveletExplorer.statusDetail = "Intensity \(String(format: "%.2f", waveletExplorer.intensity))x gives a \(String(format: "%.2f", effectiveWaveletExplorerThresholdScale))x effective coefficient gate with the current pipeline settings."
        waveletExplorer.statusMessage = nil
    }

    var effectiveWaveletExplorerThresholdScale: Double {
        max(
            0.05,
            waveletExplorer.thresholdScale
                * waveletExplorer.cleaningMode.thresholdMultiplier
                / max(waveletExplorer.intensity, 0.10)
        )
    }

    func waveletCleaningConfiguration(
        for signal: MFFSignalData,
        candidate: WaveletArtifactCandidate
    ) -> WaveletCleaningConfiguration {
        let channels = Array(Set(waveletExplorerChannels(in: signal) + [candidate.channelIndex])).sorted()
        return WaveletCleaningConfiguration(
            pipeline: waveletExplorer.pipeline,
            mode: waveletExplorer.cleaningMode,
            channelIndices: channels,
            waveletFamily: waveletExplorer.waveletFamily,
            thresholdRule: waveletExplorer.thresholdRule,
            thresholdModel: waveletExplorer.thresholdModel,
            levelCount: waveletExplorer.levelCount,
            thresholdScale: effectiveWaveletExplorerThresholdScale,
            intensity: waveletExplorer.intensity,
            paddingSeconds: min(max(candidate.durationSeconds, 0.08), 0.30)
        )
    }

    func runWaveletArtifactExplorer(in signal: MFFSignalData) {
        guard !waveletExplorer.isRunning else { return }
        let channelIndices = waveletExplorerChannels(in: signal)
        guard !channelIndices.isEmpty else {
            waveletExplorer.statusMessage = "Wavelet explorer has no readable channels to scan."
            return
        }

        waveletExplorer.runGeneration += 1
        let generation = waveletExplorer.runGeneration
        waveletExplorer.result = nil
        waveletExplorer.log.removeAll()
        waveletExplorer.progress = 0
        waveletExplorer.statusTitle = "Starting wavelet artifact explorer"
        waveletExplorer.statusDetail = "Preparing \(channelIndices.count) channels for broad multiscale artifact discovery."
        waveletExplorer.statusMessage = nil
        waveletExplorer.isRunning = true

        let configuration = WaveletArtifactExplorerConfiguration(
            channelIndices: channelIndices,
            downsampleRate: min(max(waveletExplorer.downsampleRate, 20), signal.samplingRate),
            levelCount: waveletExplorer.levelCount,
            thresholdScale: effectiveWaveletExplorerThresholdScale,
            cleaningMode: waveletExplorer.cleaningMode,
            intensity: waveletExplorer.intensity,
            waveletFamily: waveletExplorer.waveletFamily,
            thresholdRule: waveletExplorer.thresholdRule,
            thresholdModel: waveletExplorer.thresholdModel,
            mergeWindowSeconds: max(waveletExplorer.mergeWindowSeconds, 0.001),
            minimumDurationSeconds: max(waveletExplorer.minimumDurationSeconds, 0.001),
            maximumCandidates: waveletExplorer.maximumCandidates
        )

        waveletExplorerTask?.cancel()
        let sessionID = recordingSessionID
        waveletExplorerTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                WaveletArtifactAnalyzer.explore(in: signal, configuration: configuration) { update in
                    Task { @MainActor in
                        publishWaveletExplorerProgress(update, generation: generation)
                    }
                }
            }
            let result = await withTaskCancellationHandler(
                operation: {
                    await worker.value
                },
                onCancel: {
                    worker.cancel()
                }
            )

            guard !Task.isCancelled,
                  sessionID == recordingSessionID,
                  generation == waveletExplorer.runGeneration else { return }
            waveletExplorer.result = result
            waveletExplorer.progress = 1
            waveletExplorer.statusTitle = "Wavelet artifact explorer scan complete"
            waveletExplorer.statusDetail = "\(result.candidates.count) candidates across \(result.channelCount) channels over \(String(format: "%.1f", result.analyzedDurationSeconds)) seconds."
            waveletExplorer.statusMessage = "\(result.candidates.count) wavelet candidates found"
            waveletExplorer.isRunning = false
            waveletExplorerTask = nil
        }
    }

    @MainActor
    func publishWaveletExplorerProgress(_ update: WaveletArtifactExplorerProgress, generation: Int) {
        guard generation == waveletExplorer.runGeneration else { return }
        waveletExplorer.progress = update.fraction
        waveletExplorer.statusTitle = update.title
        waveletExplorer.statusDetail = update.detail
        waveletExplorer.log.append(WaveletArtifactExplorerLogLine(
            title: "\(Int((update.fraction * 100).rounded()))% · \(update.title)",
            detail: update.detail
        ))
        if waveletExplorer.log.count > 240 {
            waveletExplorer.log.removeFirst(waveletExplorer.log.count - 240)
        }
    }

    func waveletExplorerChannels(in signal: MFFSignalData) -> [Int] {
        switch waveletExplorer.channelScope {
        case .visibleGood:
            return signal.data.indices.filter { !channels.hidden.contains($0) && !channels.bad.contains($0) }
        case .allGood:
            return signal.data.indices.filter { !channels.bad.contains($0) }
        case .all:
            return Array(signal.data.indices)
        case .ocular:
            return ocularTemplateChannels(channelCount: signal.numberOfChannels)
                .filter { signal.data.indices.contains($0) && !channels.bad.contains($0) }
        }
    }

    func jumpToWaveletCandidate(_ candidate: WaveletArtifactCandidate, in signal: MFFSignalData) {
        guard let sampleCount = signal.data.first?.count, sampleCount > 0 else { return }
        let lower = min(max(candidate.startSample, 0), sampleCount - 1)
        let upper = min(max(candidate.endSample, lower), sampleCount - 1)
        selectedSampleRange = lower...upper
        dragSelectionStartSample = nil
        dragSelectionEndSample = nil
        selectedEventID = nil

        let plotWidth = plotWidth(for: signal)
        let centerX = (contentX(forSample: lower, in: signal) + contentX(forSample: upper + 1, in: signal)) / 2
        let viewportCenter = max(horizontalViewportWidth / 2, 1)
        let maxOffset = max(plotWidth - horizontalViewportWidth, 0)
        let clampedOffset = min(max(centerX - viewportCenter, 0), maxOffset)

        isSyncingSliderFromScroll = true
        horizontalJumpValue = maxOffset > 0 ? Double(clampedOffset / maxOffset) : 0
        isSyncingSliderFromScroll = false
        horizontalScrollPosition.scrollTo(x: clampedOffset)
    }

    func waveletExplorerPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    func waveletExplorerMicrovolts(_ value: Float) -> String {
        if value >= 100 {
            return String(format: "%.0f µV", value)
        }
        if value >= 10 {
            return String(format: "%.1f µV", value)
        }
        return String(format: "%.2f µV", value)
    }

}
