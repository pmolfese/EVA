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
//  Wavelet artifact explorer sheet and its supporting helpers, extracted from
//  WaveformView.swift during the L5 view-decomposition refactor. This is an
//  extension of WaveformView (not a standalone type), following the same
//  pattern as the other L5 slices -- the cluster reads/writes WaveformView's
//  own stores (wavelet, artifactVM) and state, so this is a file split, not a
//  state extraction.
//

import SwiftUI

/// A metric chip that pops its `detail` content over on click instead of
/// taking up permanent vertical space — used for the Strongest Channels /
/// Dominant Levels tables so the candidate list (the thing actually worth
/// scrolling to) doesn't get pushed down by tables most sessions won't need
/// to look at every time. Self-contained `@State` (not on `WaveformView`) —
/// matches `HoverPinnedPreviewButton`'s pattern in `ArtifactPreviewViews.swift`.
struct WaveletExplorerSummaryChip<Detail: View>: View {
    let title: String
    let value: String
    @ViewBuilder var detail: () -> Detail

    @State private var showsDetail = false

    var body: some View {
        Button {
            showsDetail.toggle()
        } label: {
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
        .buttonStyle(.plain)
        .popover(isPresented: $showsDetail, arrowEdge: .bottom) {
            detail()
                .padding(12)
                .frame(minWidth: 260, alignment: .topLeading)
        }
    }
}

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
                    .frame(width: 600)

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
        .frame(width: 1140, height: 680)
    }

    @ViewBuilder
    func waveletReductionSettingsColumn(input: MFFSignalData, reduceCount: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ArtifactTemplateFieldLabel(
                    title: "Mode",
                    help: "HAPPE's two wavelet-cleaning tracks. Continuous EEG is the more aggressive, hard-thresholding pass run over the whole recording. Task / ERP is gentler (soft thresholding, one extra decomposition level, quality assessed within the ERP analysis band) so it doesn't smear stimulus-locked components. Switching modes resets the settings below to that track's defaults — pick this first, then fine-tune."
                )
                Picker("Mode", selection: $wavelet.mode) {
                    ForEach(WaveletReductionMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: wavelet.mode) { _, newMode in
                    wavelet.config = waveletDefaultConfiguration(for: newMode, input: input)
                }

                Text(wavelet.mode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Two (label, control) pairs per row. The settings list grew
                // past what a single narrow column could show without
                // scrolling; pairing related controls halves the height and
                // keeps each one beside its natural companion.
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        ArtifactTemplateFieldLabel(
                            title: "Transform",
                            help: "DWT (decimated) is what HAPPE's wdenoise uses — fast and compact, the standard choice. SWT (undecimated/stationary) is shift-invariant, so the removed-artifact estimate doesn't shift depending on where a spike falls in the decimation grid — useful for inspecting exactly what a level removed, at the cost of more compute."
                        )
                        Picker("", selection: $wavelet.config.kind) {
                            ForEach(WaveletTransformKind.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 130)

                        ArtifactTemplateFieldLabel(
                            title: "Wavelet",
                            help: "The mother wavelet. bior4.4 is HAPPE's continuous-path family and the Continuous EEG default; coif4 is HAPPE's ERP family. sym4/db4 are orthonormal and near-symmetric — solid general-purpose alternatives, but no orthogonal wavelet beyond Haar can be exactly symmetric. The biorthogonal families (bior4.4, bior6.8) are exactly linear-phase, so thresholding and subtracting the artifact estimate doesn't introduce a small time shift, which matters most right at artifact onsets and for timing-sensitive ERP work."
                        )
                        .gridColumnAlignment(.leading)
                        Picker("", selection: $wavelet.config.family) {
                            ForEach(WaveletReductionFamily.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 130)
                    }
                    GridRow {
                        ArtifactTemplateFieldLabel(
                            title: "Threshold rule",
                            help: "Hard keeps coefficients above the threshold unchanged and zeroes the rest — more aggressive, the Continuous EEG default. Soft also shrinks the surviving coefficients toward zero — gentler and less likely to leave a sharp edge in what's subtracted, the Task / ERP default."
                        )
                        Picker("", selection: $wavelet.config.thresholdRule) {
                            ForEach(WaveletCleaningThresholdRule.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 130)

                        ArtifactTemplateFieldLabel(
                            title: "Threshold model",
                            help: """
                            How each level's artifact gate is chosen.

                            Empirical Bayes — the default, and what HAPPE gets from MATLAB's wdenoise. \(WaveletCleaningThresholdModel.empiricalBayes.summary)

                            Universal — \(WaveletCleaningThresholdModel.robustUniversal.summary) It is the upper bound empirical Bayes is fitted under, and what a band of pure noise fits to, so the two agree on quiet bands and diverge where artifacts are sparse.

                            BayesShrink — \(WaveletCleaningThresholdModel.bayesShrink.summary) Avoid unless you know why you want it.
                            """
                        )
                        .gridColumnAlignment(.leading)
                        Picker("", selection: $wavelet.config.thresholdModel) {
                            ForEach(WaveletCleaningThresholdModel.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 130)
                    }
                    GridRow {
                        ArtifactTemplateFieldLabel(
                            title: "Levels",
                            help: "How many times the signal is halved in frequency. More levels reach lower frequencies (drift, slow artifacts), but each extra level has less data to estimate its threshold from, so pushing this too high risks overfitting to noise. The rate-dependent default (8–10 continuous, 9–11 ERP) mirrors HAPPE's own scheme."
                        )
                        Stepper("\(wavelet.config.levelCount)", value: $wavelet.config.levelCount, in: 1...WaveletReducer.maximumLevelCount)
                            .frame(width: 130)

                        ArtifactTemplateFieldLabel(
                            title: "Skip finest",
                            help: "Excludes this many of the finest levels from artifact removal, leaving their content in the cleaned signal. Each level covers a band roughly half the width of the one below it, so on data already low-passed well under Nyquist the finest levels sit entirely in the filter's stopband. Those bands hold only roll-off residue, which drags their noise estimate — and therefore their threshold — toward zero, so nearly all of that residue gets called artifact. This is set automatically from the filter's low-pass cutoff; raise it to protect more high-frequency signal, set it to 0 for strict HAPPE behaviour."
                        )
                        .gridColumnAlignment(.leading)
                        HStack(spacing: 6) {
                            Stepper("\(wavelet.config.skippedFineLevels)", value: $wavelet.config.skippedFineLevels, in: 0...max(wavelet.config.levelCount - 1, 0))
                                .frame(width: 74)
                            Text(waveletSkippedLevelSummary(input: input))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 130, alignment: .leading)
                    }
                    GridRow {
                        ArtifactTemplateFieldLabel(
                            title: "Strength",
                            help: "Multiplies the computed threshold — the gate a coefficient must exceed to count as artifact and be subtracted. 1.0 is the textbook rule for the chosen model. Raise it to protect more signal (fewer coefficients cleared the gate, gentler cleaning); lower it to cut more aggressively on a dataset with strong, obvious artifacts."
                        )
                        TextField("x", value: $wavelet.config.thresholdScale, format: .number.precision(.fractionLength(2)))
                            .frame(width: 80)

                        ArtifactTemplateFieldLabel(
                            title: "Threshold scope",
                            help: "Global estimates one threshold per level from the whole recording — exactly what HAPPE's wdenoise does. Local (30 s) re-estimates each level's threshold in overlapping 30-second windows, so a quiet stretch and a noisy stretch each get their own noise floor — the same scheme the Wavelet Artifact Explorer uses. Local is an EVA improvement over HAPPE, useful for recordings whose noise level changes over time; use Global for strict HAPPE parity."
                        )
                        .gridColumnAlignment(.leading)
                        Picker("", selection: $wavelet.config.thresholdWindowSeconds) {
                            Text("Global (HAPPE)").tag(0.0)
                            Text("Local (30 s)").tag(30.0)
                        }
                        .labelsHidden().frame(width: 130)
                    }
                    GridRow {
                        ArtifactTemplateFieldLabel(
                            title: "Detrend",
                            help: "Removes each channel's linear drift before the wavelet pass and folds it into the removed artifact. HAPPE's deepest approximation band swallows drift anyway, so this doesn't change what's kept — but it stops the transform's circular boundary from reading a start-to-end voltage offset as a large spurious artifact at the recording's edges. Leave on unless you're debugging."
                        )
                        Toggle("", isOn: $wavelet.config.detrend)
                            .labelsHidden()

                        ArtifactTemplateFieldLabel(
                            title: "Downsample",
                            help: "Runs the wavelet pass on a decimated copy, then upsamples the removed-artifact estimate back to full rate before subtracting. Both modes default to Full rate, matching HAPPE — decimating distorts exactly the sharp transients being removed. Opt in only if the recording is very high-rate and reduction is too slow."
                        )
                        .gridColumnAlignment(.leading)
                        Picker("", selection: $wavelet.config.downsampleFactor) {
                            ForEach(downsampleFactorOptions(for: input.samplingRate), id: \.self) { factor in
                                Text(downsampleFactorLabel(factor: factor, rate: input.samplingRate)).tag(factor)
                            }
                        }
                        .labelsHidden().frame(width: 130)
                    }
                    GridRow {
                        ArtifactTemplateFieldLabel(
                            title: "Use GPU",
                            help: "Runs the decompose–threshold–reconstruct chain on the Mac's GPU, processing whole batches of channels in shared dispatches — typically much faster than the CPU on high-density recordings. The GPU computes in 32-bit floats where the CPU uses 64-bit, so results agree closely but not to the last bit. Falls back to the CPU automatically if the GPU can't run. Unavailable when no Metal device is present."
                        )
                        Toggle("", isOn: $wavelet.config.useGPU)
                            .labelsHidden()
                            .disabled(!WaveletMetalBackend.isAvailable)

                        ArtifactTemplateFieldLabel(
                            title: "CPU cores",
                            help: "How many channels are wavelet-reduced in parallel when running on the CPU (ignored while Use GPU is on). Turn this down if the reduction is competing with other work on the Mac; raise it (up to the maximum) to finish faster on a dataset with many channels."
                        )
                        .gridColumnAlignment(.leading)
                        Stepper("\(wavelet.coreCount) of \(WaveletReducer.maximumCoreCount)", value: $wavelet.coreCount, in: 1...WaveletReducer.maximumCoreCount)
                            .frame(width: 130)
                            .disabled(wavelet.config.useGPU && WaveletMetalBackend.isAvailable)
                    }
                    GridRow {
                        ArtifactTemplateFieldLabel(
                            title: "Analysis range",
                            help: "Limits the reduction to a span of the recording. Samples outside it are passed through untouched, and the quality metrics and the found-changes list are both scoped to the span. Use it to exclude a contaminated stretch — a filter transient or amplifier step in the last few seconds, say — which would otherwise dominate the variance-retained figure and fill the changes list with one giant event."
                        )
                        HStack(spacing: 8) {
                            Text(wavelet.analysisRangeSummary(durationSeconds: waveletRecordingDuration(input)))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(wavelet.config.analysisStartSeconds == nil && wavelet.config.analysisEndSeconds == nil ? .secondary : .primary)
                            Button("Advanced…") {
                                wavelet.syncAdvancedRangeText()
                                wavelet.advancedRangeMessage = nil
                                wavelet.showsAdvancedRange = true
                            }
                            .controlSize(.small)
                            .popover(isPresented: $wavelet.showsAdvancedRange, arrowEdge: .trailing) {
                                waveletAnalysisRangePopover(input: input)
                            }
                        }
                        .gridCellColumns(3)
                    }
                }
                .font(.callout)

                Text(wavelet.config.family.explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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

    /// The frequency floor the skipped levels sit above, so the stepper reads
    /// as a band rather than as a bare count.
    func waveletSkippedLevelSummary(input: MFFSignalData) -> String {
        let skipped = wavelet.config.skippedFineLevels
        guard skipped > 0, input.samplingRate > 0 else { return "none" }
        let floorHz = input.samplingRate / Double(1 << (skipped + 1))
        return String(format: "above %.1f Hz", floorHz)
    }

    /// Start/end fields for the analysis span. Blank means "unbounded on that
    /// side", so trimming a tail is just a value in End.
    @ViewBuilder
    func waveletAnalysisRangePopover(input: MFFSignalData) -> some View {
        let duration = waveletRecordingDuration(input)
        VStack(alignment: .leading, spacing: 12) {
            Text("Analysis Range")
                .font(.headline)
            Text(String(format: "Recording is %.1f s. Leave a field blank for the recording's own start or end.", duration))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Start (s)")
                    TextField("0", text: $wavelet.advancedRangeStartText)
                        .frame(width: 100)
                }
                GridRow {
                    Text("End (s)")
                    TextField(String(format: "%.1f", duration), text: $wavelet.advancedRangeEndText)
                        .frame(width: 100)
                }
            }
            .font(.callout)

            if let message = wavelet.advancedRangeMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Trim last 5 s") {
                    wavelet.advancedRangeEndText = String(format: "%g", max(duration - 5, 0))
                    wavelet.advancedRangeMessage = nil
                }
                .controlSize(.small)
                Button("Full recording") {
                    wavelet.clearAdvancedRange()
                    wavelet.advancedRangeMessage = nil
                }
                .controlSize(.small)
                Spacer()
                Button("Apply") {
                    let message = wavelet.commitAdvancedRange(durationSeconds: duration)
                    wavelet.advancedRangeMessage = message
                    if message == nil { wavelet.showsAdvancedRange = false }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 320)
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

            if let message = waveletExplorer.applyStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Clear Results") {
                    waveletExplorer.result = nil
                    waveletExplorer.excludedCandidateIDs = []
                    waveletExplorer.log.removeAll()
                    waveletExplorer.progress = 0
                    waveletExplorer.statusTitle = "Wavelet artifact explorer ready"
                    waveletExplorer.statusDetail = "\(waveletExplorerChannels(in: signal).count) channels selected for exploratory multiscale scanning."
                    waveletExplorer.statusMessage = nil
                    waveletExplorer.applyStatusMessage = nil
                    refreshWaveletExplorerEvents()
                }
                .disabled(waveletExplorer.isRunning && waveletExplorer.result == nil && waveletExplorer.log.isEmpty)

                if let result = waveletExplorer.result, !result.candidates.isEmpty {
                    Text("\(waveletExplorerIncludedCandidateCount) of \(result.candidates.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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

                Button("Apply Selected") {
                    applyWaveletExplorerCandidates(in: signal)
                }
                .disabled(waveletExplorer.isRunning || waveletExplorer.isApplying || waveletExplorerIncludedCandidateCount == 0)
                .help("Cleans the checked candidates in place using per-event wavelet decompose-threshold-subtract, the same reversible pipeline as OBS/Regress/MAS artifact cleaning.")
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
                        ForEach(WaveletReductionFamily.allCases) { family in
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
                        help: "Temporary sampling rate for exploratory scanning. Lower rates are faster, but the scan can only see content below half this rate — muscle/EMG needs 500 Hz or more, or the fast-artifact pass below."
                    )
                    TextField("Hz", value: $waveletExplorer.downsampleRate, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Fast artifacts",
                        help: "Adds a second pass at the recording's full sampling rate over the finest levels, to catch muscle/EMG and other fast transients that sit above the downsampled pass's limit. Roughly doubles scan time."
                    )
                    Toggle(isOn: $waveletExplorer.detectsFastArtifacts) {
                        Text("Second full-rate pass")
                            .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .frame(width: 180, alignment: .leading)

                    ArtifactTemplateFieldLabel(
                        title: "Use GPU",
                        help: WaveletMetalBackend.isAvailable
                            ? "Runs the wavelet decomposition as a Metal compute kernel instead of on the CPU. Biggest win on high-density nets and long recordings. The GPU works in single precision where the CPU uses double, so candidates can differ marginally — detection is equivalent, not bit-identical. Falls back to the CPU automatically if a dispatch fails."
                            : "No Metal device is available on this machine, so the scan will run on the CPU."
                    )
                    Toggle(isOn: $waveletExplorer.usesGPU) {
                        Text(WaveletMetalBackend.isAvailable ? "Metal decomposition" : "Unavailable")
                            .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!WaveletMetalBackend.isAvailable)
                    .frame(width: 180, alignment: .leading)
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
                        help: """
                        How each level's detection gate is chosen. Universal — \(WaveletCleaningThresholdModel.robustUniversal.summary) Empirical Bayes — \(WaveletCleaningThresholdModel.empiricalBayes.summary) BayesShrink adapts each level's threshold from estimated noise and signal variance.
                        """
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
                if result.edgeMarginSeconds > 0.0005 {
                    waveletExplorerMetricChip(
                        title: "Edges skipped",
                        value: String(format: "±%.2fs", result.edgeMarginSeconds)
                    )
                    .help("The first and last \(String(format: "%.2f", result.edgeMarginSeconds))s are not scanned — the wavelet transform's boundary makes coefficients there unreliable, so candidates in that span would be spurious.")
                }
                WaveletExplorerSummaryChip(
                    title: "Strongest channels",
                    value: "\(result.summary.strongestChannels.count) ranked"
                ) {
                    waveletExplorerChannelSummary(result.summary)
                }
                WaveletExplorerSummaryChip(
                    title: "Dominant levels",
                    value: "\(result.summary.levelSummaries.count) levels"
                ) {
                    waveletExplorerLevelSummary(result.summary)
                }
            }

            if waveletExplorer.isPrecomputingPreviews {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Precomputing previews so they open instantly…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
                            Text("")
                            waveletSortHeader(.rank)
                            waveletSortHeader(.peakTime)
                            waveletSortHeader(.duration)
                            waveletSortHeader(.score)
                            waveletSortHeader(.channel)
                            waveletSortHeader(.level)
                            waveletSortHeader(.contributingChannels)
                            waveletSortHeader(.type)
                            Text("Preview")
                            Text("")
                            Text("")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                        ForEach(waveletExplorer.sortedCandidates(candidates)) { candidate in
                            GridRow {
                                Toggle("", isOn: waveletCandidateIncludedBinding(candidate))
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                    .help("Include this candidate when Apply Selected runs.")
                                Text("\(candidate.rank)")
                                Text(formattedEventTime(candidate.peakTimeSeconds))
                                Text(String(format: "%.3fs", candidate.durationSeconds))
                                Text(String(format: "%.3f", candidate.score))
                                Text("Ch \(candidate.channelIndex + 1)")
                                Text("L\(candidate.dominantLevel)")
                                Text("\(candidate.contributingChannelCount)")
                                Text(candidate.artifactType.rawValue)
                                WaveletCleaningPreviewButton(
                                    candidate: candidate,
                                    signal: signal,
                                    configuration: waveletCleaningConfiguration(for: signal, candidate: candidate),
                                    precomputed: waveletExplorer.previewCache
                                )
                                WaveletScalogramButton(candidate: candidate, signal: signal)
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

    /// A clickable column header. Clicking the active column flips direction;
    /// clicking another selects it. The active column carries a chevron.
    func waveletSortHeader(_ column: WaveletCandidateSortColumn) -> some View {
        Button {
            waveletExplorer.toggleSort(column)
        } label: {
            HStack(spacing: 2) {
                Text(column.rawValue)
                if waveletExplorer.sortColumn == column {
                    Image(systemName: waveletExplorer.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            column == .score
                ? "Anomaly strength, in sigmas above that channel's own local baseline — comparable across channels of different amplitude."
                : "Sort by \(column.rawValue)."
        )
    }

    func waveletCandidateIncludedBinding(_ candidate: WaveletArtifactCandidate) -> Binding<Bool> {
        Binding(
            get: { !waveletExplorer.excludedCandidateIDs.contains(candidate.id) },
            set: { included in
                if included {
                    waveletExplorer.excludedCandidateIDs.remove(candidate.id)
                } else {
                    waveletExplorer.excludedCandidateIDs.insert(candidate.id)
                }
            }
        )
    }

    var waveletExplorerIncludedCandidateCount: Int {
        guard let result = waveletExplorer.result else { return 0 }
        return result.candidates.filter { !waveletExplorer.excludedCandidateIDs.contains($0.id) }.count
    }

    /// Builds the waveform-display event for one candidate. `beginTimeSeconds`
    /// is the true onset (not a pre-centered peak) and `sourceFile` starts
    /// with "Continuous" so `MFFEvent.centerTimeSeconds` and the duration
    /// highlight band both read it as onset+duration, spanning the candidate's
    /// full detected window rather than a point at the peak.
    func waveletCandidateEvent(_ candidate: WaveletArtifactCandidate) -> MFFEvent {
        let duration = max(candidate.endTimeSeconds - candidate.startTimeSeconds, 0.01)
        return MFFEvent(
            id: "wavelet-explorer-\(candidate.id)",
            code: "WAVX",
            label: "Wavelet burst",
            eventDescription: String(
                format: "Wavelet Explorer candidate #%d · Ch %d · score %.2f · dominant level %d · %@",
                candidate.rank, candidate.channelIndex + 1, candidate.score, candidate.dominantLevel, candidate.artifactType.rawValue
            ),
            beginTimeSeconds: candidate.startTimeSeconds,
            rawBeginTime: String(format: "%.6f", candidate.startTimeSeconds),
            sourceFile: WaveletArtifactExplorerViewModel.candidateSourceFile,
            durationSeconds: duration
        )
    }

    /// Keeps `artifactVM.events` (the waveform's marker overlay) in sync with
    /// the current scan result — replaces any previously-shown wavelet
    /// candidates wholesale, leaving every other event source (threshold
    /// detection, defined-artifact templates) untouched.
    func refreshWaveletExplorerEvents() {
        let otherEvents = artifactVM.events.filter { $0.sourceFile != WaveletArtifactExplorerViewModel.candidateSourceFile }
        let candidateEvents = (waveletExplorer.result?.candidates ?? []).map(waveletCandidateEvent)
        artifactVM.events = (otherEvents + candidateEvents).sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
    }

    /// Cleans the checked candidates for real: stages them as a `DefinedArtifact`
    /// with `cleaningMethod = .wavelet` (creating one on first Apply, updating
    /// it in place on subsequent Applies so re-running doesn't pile up
    /// duplicates), then runs the same `applyArtifactCleaning` pipeline every
    /// other cleaning method uses — same revert/preview/provenance machinery,
    /// no bespoke apply path for wavelet candidates.
    func applyWaveletExplorerCandidates(in signal: MFFSignalData) {
        guard let result = waveletExplorer.result else { return }
        let included = result.candidates.filter { !waveletExplorer.excludedCandidateIDs.contains($0.id) }
        guard !included.isEmpty else {
            waveletExplorer.applyStatusMessage = "No candidates selected — check at least one to clean."
            return
        }

        let events = included.map(waveletCandidateEvent)
        let selectedChannels = Array(Set(included.map { $0.channelIndex })).sorted()
        let averageWindowSeconds = events.compactMap(\.durationSeconds).reduce(0, +) / Double(max(events.count, 1))

        let existingIndex = waveletExplorer.appliedArtifactID.flatMap { id in
            template.definedArtifacts.firstIndex(where: { $0.id == id })
        }

        var artifact = existingIndex.map { template.definedArtifacts[$0] } ?? DefinedArtifact(
            type: .other,
            name: "Wavelet Explorer Candidates",
            eventCode: "WAVX",
            events: [],
            selectedChannelIndices: [],
            windowSizeSeconds: 0.1,
            average: nil,
            topography: nil,
            cleaningMethod: .wavelet
        )
        artifact.cleaningMethod = .wavelet
        artifact.events = events
        artifact.selectedChannelIndices = selectedChannels
        artifact.windowSizeSeconds = max(averageWindowSeconds, 0.05)
        artifact.usesVariableEventDuration = true

        if let existingIndex {
            template.definedArtifacts[existingIndex] = artifact
        } else {
            waveletExplorer.appliedArtifactID = artifact.id
            template.definedArtifacts.append(artifact)
        }

        waveletExplorer.applyStatusMessage = "Cleaning \(events.count) candidate\(events.count == 1 ? "" : "s")…"
        applyArtifactCleaning(to: signal)
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

    /// Computes every candidate's hover preview up front (concurrently, off
    /// the main actor) right after a scan, instead of on first hover. A
    /// `TaskGroup` fans the per-candidate `cleaningPreview` calls out across
    /// cores — each one is already independent (its own padded window, no
    /// shared state) — then writes the whole batch into `previewCache` in one
    /// go so this doesn't thrash observation with dozens of tiny updates.
    /// Guarded by `runGeneration` the same way the scan itself is, so a
    /// rescan cleanly drops a still-running precompute's results.
    func precomputeWaveletExplorerPreviews(in signal: MFFSignalData) {
        guard let result = waveletExplorer.result, !result.candidates.isEmpty else { return }
        // Only the top-ranked handful. A preview costs more than its share of
        // the scan itself (each one decomposes every channel over the
        // candidate's padded window), and most candidates are never opened —
        // so precomputing all of them spends more time than the scan on work
        // that's mostly thrown away. Anything not prefetched still opens via
        // `WaveletCleaningPreview.loadPreview`'s on-demand path, with a brief
        // spinner.
        let candidates = Array(result.candidates.prefix(waveletExplorerPrefetchCount))
        let configurations = candidates.map { waveletCleaningConfiguration(for: signal, candidate: $0) }
        let signalDuration = signal.duration
        let generation = waveletExplorer.runGeneration
        let usesGPU = waveletExplorer.usesGPU

        waveletExplorer.isPrecomputingPreviews = true
        Task {
            let worker = Task.detached(priority: .utility) { () -> [(String, WaveletCleaningPreviewResult)] in
                // Batched so the GPU path can group every (candidate, channel)
                // window into a few wide dispatches; on the CPU path this is
                // equivalent to the previous per-candidate loop.
                let previews = WaveletArtifactAnalyzer.cleaningPreviews(
                    in: signal,
                    candidates: candidates,
                    configurations: configurations,
                    usesGPU: usesGPU
                )
                var collected: [(String, WaveletCleaningPreviewResult)] = []
                collected.reserveCapacity(candidates.count)
                for (offset, preview) in previews.enumerated() where preview != nil {
                    let key = WaveletCleaningPreview.cacheKey(
                        candidateID: candidates[offset].id,
                        configuration: configurations[offset],
                        signalDuration: signalDuration
                    )
                    collected.append((key, preview!))
                }
                return collected
            }
            let entries = await worker.value
            guard generation == waveletExplorer.runGeneration else { return }
            for (key, preview) in entries {
                waveletExplorer.previewCache[key] = preview
            }
            waveletExplorer.isPrecomputingPreviews = false
        }
    }

    /// How many candidates get their preview computed up front. Sized to cover
    /// what fits on screen without scrolling, since that's what a user
    /// realistically hovers first.
    var waveletExplorerPrefetchCount: Int { 12 }

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
        waveletExplorer.previewCache = [:]
        waveletExplorer.isPrecomputingPreviews = false
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
            maximumCandidates: waveletExplorer.maximumCandidates,
            detectsFastArtifacts: waveletExplorer.detectsFastArtifacts,
            usesGPU: waveletExplorer.usesGPU
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
            waveletExplorer.excludedCandidateIDs = []
            waveletExplorer.progress = 1
            waveletExplorer.statusTitle = "Wavelet artifact explorer scan complete"
            waveletExplorer.statusDetail = "\(result.candidates.count) candidates across \(result.channelCount) channels over \(String(format: "%.1f", result.analyzedDurationSeconds)) seconds."
            waveletExplorer.statusMessage = "\(result.candidates.count) wavelet candidates found"
            waveletExplorer.isRunning = false
            waveletExplorerTask = nil
            refreshWaveletExplorerEvents()
            precomputeWaveletExplorerPreviews(in: signal)
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
