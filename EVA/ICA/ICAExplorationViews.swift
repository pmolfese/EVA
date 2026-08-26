//
//  ICAExplorationViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  ICA (independent component analysis) artifact exploration sheet and its
//  supporting helpers, extracted from WaveformView.swift during the L5
//  view-decomposition refactor. This is an extension of WaveformView (not a
//  standalone type), following the same pattern as the other L5 slices — the
//  cluster reads/writes WaveformView's own stores (ica, artifactVM, replay)
//  and state, so this is a file split, not a state extraction.
//

import SwiftUI
import UniformTypeIdentifiers

extension WaveformView {
    // MARK: - ICA artifact exploration

    func openICASheet(for signal: MFFSignalData) {
        ica.componentCount = min(max(ica.componentCount, 1), signal.numberOfChannels)
        ica.downsampleRate = min(ica.downsampleRate, signal.samplingRate)
        ica.statusMessage = nil
        artifactVM.detectionMethod = .ica
        ica.showsSheet = true
    }

    func icaSheet(for signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("ICA Artifact Components")
                    .font(.title3.weight(.semibold))
                Spacer()
                if let decomp = ica.decomposition {
                    Text("\(decomp.componentCount) components · \(Int(decomp.analysisSamplingRate)) Hz")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Method",
                        help: """
                        Picard (recommended) is a preconditioned ICA that optimizes the same tanh maximum-likelihood objective as Infomax, but with a quasi-Newton (L-BFGS) solver — so it reaches Infomax's solution in a few iterations instead of hundreds. Picard-O solves that same likelihood under an orthogonality constraint, i.e. the same problem FastICA solves (updates stay rotations of the whitened data), but with Picard's preconditioned solver instead of FastICA's fixed-point step — giving FastICA-equivalent results with more reliable convergence. FastICA is the classic fast symmetric fixed-point solver on whitened data. Infomax is the slower MNE/EEGLAB extended-infomax, kept for reference. In short: Picard ≈ a faster Infomax; Picard-O ≈ a more robust FastICA.

                        References

                        Infomax: Bell, A. J., & Sejnowski, T. J. (1995). An information-maximization approach to blind separation and blind deconvolution. Neural Computation, 7(6), 1129–1159. https://doi.org/10.1162/neco.1995.7.6.1129

                        Extended Infomax: Lee, T.-W., Girolami, M., & Sejnowski, T. J. (1999). Independent component analysis using an extended infomax algorithm for mixed subgaussian and supergaussian sources. Neural Computation, 11(2), 417–441. https://doi.org/10.1162/089976699300016719

                        FastICA: Hyvärinen, A., & Oja, E. (1997). A fast fixed-point algorithm for independent component analysis. Neural Computation, 9(7), 1483–1492. https://doi.org/10.1162/neco.1997.9.7.1483

                        Picard: Ablin, P., Cardoso, J.-F., & Gramfort, A. (2018). Faster independent component analysis by preconditioning with Hessian approximations. IEEE Transactions on Signal Processing, 66(15), 4040–4049. https://doi.org/10.1109/TSP.2018.2844203

                        Picard-O: Ablin, P., Cardoso, J.-F., & Gramfort, A. (2018). Faster ICA under orthogonal constraint. In 2018 IEEE International Conference on Acoustics, Speech and Signal Processing (ICASSP) (pp. 4464–4468). IEEE. https://doi.org/10.1109/ICASSP.2018.8461662
                        """
                    )
                    Picker("Method", selection: $ica.method) {
                        ForEach(ICAMethod.allCases) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .gridCellColumns(4)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Components",
                        help: "Maximum number of PCA/ICA components to estimate. The variance setting may choose fewer components to avoid whitening tiny noisy directions."
                    )
                    TextField("Components", value: $ica.componentCount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    ArtifactTemplateFieldLabel(
                        title: "Search Hz",
                        help: "Temporary downsample rate used only for fitting and previewing ICA — the selected components are still removed from the full-rate EEG afterward. This auto-scales to the fit filter: by Nyquist the rate only needs to be just above twice the highest frequency the filter keeps (≈2× the high cutoff, or 2× 60 Hz when the notch is on), so it can be far lower than the recording rate, which is what makes the fit fast. You can always set it higher."
                    )
                    TextField("Hz", value: $ica.downsampleRate, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    ArtifactTemplateFieldLabel(
                        title: "Iterations",
                        help: "Maximum solver iterations. Picard and FastICA typically converge in well under this; it acts mainly as a safety cap. Infomax may use more."
                    )
                    TextField("Iterations", value: $ica.maxIterations, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Keep Var",
                        help: "PCA variance target used to choose how many components to keep, capped by the Components field. 99.9% is a practical default for preserving blink components while still avoiding near-zero noisy directions."
                    )
                    TextField("Fraction", value: $ica.varianceThreshold, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    ArtifactTemplateFieldLabel(
                        title: "Avg Ref",
                        help: "Subtracts the instantaneous average across channels before ICA fitting. This removes common-mode reference structure that can dominate the first PCA direction."
                    )
                    Toggle("Use", isOn: $ica.usesAverageReference)
                        .toggleStyle(.checkbox)

                    Text("Components are capped after PCA screening.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Fit Filter",
                        help: "Recommended for ICA: fit components on a filtered copy of the data. A 1 Hz high-pass is commonly used so slow drift does not dominate the decomposition."
                    )
                    Toggle("Use", isOn: $ica.usesFitFilter)
                        .toggleStyle(.checkbox)

                    ArtifactTemplateFieldLabel(
                        title: "Fit Hz",
                        help: "Band-pass range used only for fitting ICA. The selected components are still removed from the full-rate EEG after review."
                    )
                    HStack(spacing: 6) {
                        TextField("Low", value: $ica.fitLowCutoff, format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 58)
                        Text("–")
                            .foregroundStyle(.secondary)
                        TextField("High", value: $ica.fitHighCutoff, format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 58)
                    }
                    .disabled(!ica.usesFitFilter)

                    Toggle("60 Hz notch", isOn: $ica.fitNotch60HzEnabled)
                        .toggleStyle(.checkbox)
                        .disabled(!ica.usesFitFilter)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Fit Type",
                        help: """
                        Filter family used for the ICA fit copy only — independent of the Filter popover's setting, because the ICA fit band (typically 1 Hz high-pass) has different tradeoffs from a display filter (typically 0.1 Hz).

                        EEGLAB's convention is FIR: `pop_eegfiltnew` designs a linear-phase FIR and the EEGLAB ICA guidance assumes it. MNE-Python likewise defaults to FIR for its `filter()` used ahead of ICA.

                        ICA fit filters use EVA's historical zero-phase application (forward + backward, `filtfilt`), so neither family shifts the ICA fit copy in time. The Filter popover separately offers one-pass and causal FIR application modes for the recording filter.

                        Practical guidance:

                        IIR (Butterworth) is cheap and well behaved at the cutoffs ICA fits at. At very low high-pass cutoffs it is the *better* choice, because an equivalent FIR kernel becomes impractically long — this is exactly why the Auto family in the Filter popover uses IIR below its crossover.

                        FIR gives a more precisely controlled transition band and matches what EEGLAB/MNE pipelines do, which matters if you are reproducing a published pipeline or comparing against results produced by those tools.

                        Either is defensible for a 1 Hz fit high-pass. The choice is recorded in eva.xml and in eva_ica.json, so whichever you pick is reproducible.

                        References

                        Widmann, A., Schröger, E., & Maess, B. (2015). Digital filter design for electrophysiological data — a practical approach. Journal of Neuroscience Methods, 250, 34–46. https://doi.org/10.1016/j.jneumeth.2014.08.002

                        Winkler, I., Debener, S., Müller, K.-R., & Tangermann, M. (2015). On the influence of high-pass filtering on ICA-based artifact reduction in EEG-ERP. In 2015 37th Annual International Conference of the IEEE EMBC (pp. 4101–4105). https://doi.org/10.1109/EMBC.2015.7319296
                        """
                    )
                    Picker("Fit Type", selection: $ica.fitFilterFamily) {
                        ForEach(FilterFamily.allCases) { family in
                            Text(family.label).tag(family)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(!ica.usesFitFilter)
                    .gridCellColumns(2)

                    Text("Zero-phase either way; see the help for the EEGLAB/MNE convention.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridCellColumns(2)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Tolerance",
                        help: "MNE-style early stopping threshold for summed squared ICA weight change between iterations. Smaller values may run longer."
                    )
                    TextField("Tolerance", value: $ica.convergenceTolerance, format: .number.notation(.scientific).precision(.significantDigits(2...4)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    ArtifactTemplateFieldLabel(
                        title: "Min Iter",
                        help: "Minimum number of infomax iterations before tolerance-based early stopping is allowed."
                    )
                    TextField("Min", value: $ica.minimumIterations, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)

                    Text("Stops when weights stabilize.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button("Run ICA") {
                    runICA(on: signal)
                }
                .disabled(ica.isRunning)

                if ica.isRunning {
                    ProgressView(value: ica.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                    Text("\(Int((ica.progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(ica.progressMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 190, alignment: .leading)
                }

                if let decomp = ica.decomposition, !decomp.excludedComponents.isEmpty {
                    Button("Remove Selected Components") {
                        removeSelectedICAComponents(from: signal)
                    }
                    .disabled(ica.isRemovingComponents)

                    Button("Save JSON…") {
                        saveICAJSON(ica.decomposition)
                    }
                }

                if let decomp = ica.decomposition, !decomp.excludedComponents.isEmpty {
                    Button("Synthesize as PNS Channel") {
                        synthesizeICAAsPNS(decomposition: ica.decomposition, signal: signal)
                    }
                    .help("Sum the checked component activations and add them as a new physio (PNS) channel.")
                }

                if ica.isRemovingComponents {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reconstructing EEG")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Close") {
                    ica.showsSheet = false
                    // Closing without removing components skips this replay step.
                    if replay.state.isAwaitingDecision { replay.resume(.skip) }
                }
            }

            if let icaStatus = ica.statusMessage {
                Text(icaStatus)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let decomp = ica.decomposition {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(0..<decomp.componentCount, id: \.self) { component in
                            icaComponentCard(component, signal: signal)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 520)
            } else {
                ContentUnavailableView(
                    "No ICA Yet",
                    systemImage: "square.grid.3x3",
                    description: Text("Run ICA to inspect component topographies and time courses.")
                )
                .frame(height: 260)
            }
        }
        .padding(20)
        .frame(width: 980, height: 760)
        .onAppear { autoScaleICAAnalysisRate(samplingRate: signal.samplingRate) }
        .onChange(of: ica.usesFitFilter) { _, _ in autoScaleICAAnalysisRate(samplingRate: signal.samplingRate) }
        .onChange(of: ica.fitNotch60HzEnabled) { _, _ in autoScaleICAAnalysisRate(samplingRate: signal.samplingRate) }
        .onChange(of: ica.fitHighCutoff) { _, _ in autoScaleICAAnalysisRate(samplingRate: signal.samplingRate) }
    }

    /// Recommended ICA fit/analysis rate. By Nyquist the rate only needs to be
    /// a little above twice the highest frequency the fit filter preserves, so
    /// it can be far below the recording rate — which is what keeps the fit fast.
    func recommendedICAAnalysisRate(samplingRate: Double) -> Double {
        let highCutoff = ica.usesFitFilter ? ica.fitHighCutoff : 40.0
        let notchFrequency = (ica.usesFitFilter && ica.fitNotch60HzEnabled) ? 60.0 : 0.0
        let maxFrequency = max(highCutoff, notchFrequency)
        // 20% headroom above the Nyquist minimum, rounded up to a tidy 10 Hz step.
        let raw = max(2.4 * maxFrequency, 100.0)
        let rounded = (raw / 10).rounded(.up) * 10
        return min(rounded, samplingRate)
    }

    func autoScaleICAAnalysisRate(samplingRate: Double) {
        guard samplingRate > 0 else { return }
        ica.downsampleRate = recommendedICAAnalysisRate(samplingRate: samplingRate)
    }

    func icaComponentCard(_ component: Int, signal: MFFSignalData) -> some View {
        let isExcluded = ica.decomposition?.excludedComponents.contains(component) == true
        let label = Binding<String>(
            get: { ica.decomposition?.labels[component] ?? "" },
            set: { newValue in ica.decomposition?.labels[component] = newValue }
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: icaComponentExcludedBinding(component)) {
                    Text("IC \(component + 1)")
                        .font(.caption.weight(.semibold))
                }
                Spacer()
                Text(icaExplainedVarianceText(component))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let layout = recording.sensorLayout,
               let values = ica.decomposition?.componentMaps[safe: component] {
                let displayValues = normalizedTopography(values)
                TopomapView(
                    layout: layout,
                    values: displayValues,
                    timeSeconds: 0,
                    fixedScale: 1,
                    unitLabel: "a.u.",
                    showsHeader: false,
                    colorBarPlacement: .trailing,
                    minimumMapHeight: 178
                )
                .frame(height: 210)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: 230)
                    .overlay {
                        Text("No layout")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }

            if let decomposition = ica.decomposition,
               let source = decomposition.componentSources[safe: component] {
                ICATimeCoursePreview(
                    samples: source,
                    visibleRange: icaVisibleSourceRange(for: decomposition, in: signal)
                )
            }

            TextField("Label", text: label)
                .textFieldStyle(.roundedBorder)
                .disabled(!isExcluded)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isExcluded
                      ? Color.red.opacity(0.10)
                      : Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isExcluded
                              ? Color.red.opacity(0.35)
                              : Color.secondary.opacity(0.15), lineWidth: 1)
        }
        .help(ica.decomposition?.labelSuggestions[component]?.reason ?? "Select components that look like eye, muscle, cardiac, or movement artifacts. Labels are saved with the JSON artifact set.")
    }

    func icaComponentExcludedBinding(_ component: Int) -> Binding<Bool> {
        Binding(
            get: { ica.decomposition?.excludedComponents.contains(component) == true },
            set: { isSelected in
                if isSelected {
                    ica.decomposition?.excludedComponents.insert(component)
                    if ica.decomposition?.labels[component]?.isEmpty != false {
                        ica.decomposition?.labels[component] = "Artifact"
                    }
                } else {
                    ica.decomposition?.excludedComponents.remove(component)
                }
            }
        )
    }

    func synthesizeICAAsPNS(decomposition: ICADecomposition?, signal: MFFSignalData) {
        guard let decomposition else { return }
        let indices = decomposition.excludedComponents.sorted()
        guard !indices.isEmpty else { return }

        // Default name: "ICA" + 1-based component numbers joined, e.g. "ICA13".
        let name = "ICA" + indices.map { "\($0 + 1)" }.joined()

        // Sum selected component activations (double precision during accumulation).
        let len = decomposition.componentSources.first?.count ?? 0
        var accum = [Double](repeating: 0, count: len)
        for idx in indices {
            if let src = decomposition.componentSources[safe: idx] {
                for i in 0..<min(accum.count, src.count) {
                    accum[i] += src[i]
                }
            }
        }
        let samples = accum.map { Float($0) }

        syntheticPNSChannels.append(SyntheticPNSChannel(
            name: name,
            samples: samples,
            samplingRate: decomposition.analysisSamplingRate,
            sourceComponents: indices
        ))
        showsPhysioChannels = true
    }

    func icaExplainedVarianceText(_ component: Int) -> String {
        guard let value = ica.decomposition?.explainedVariance[safe: component],
              let total = ica.decomposition?.explainedVariance.reduce(0, +),
              total > 0 else {
            return ""
        }
        return String(format: "%.1f%%", (value / total) * 100)
    }

    func icaVisibleSourceRange(for decomposition: ICADecomposition, in signal: MFFSignalData) -> ClosedRange<Int>? {
        guard decomposition.sampleCount > 1 else { return nil }

        let lowerSample = sampleIndex(forContentX: horizontalOffset, in: signal)
        let upperSample = sampleIndex(forContentX: horizontalOffset + horizontalViewportWidth, in: signal)
        let lowerSource = min(max(lowerSample / max(decomposition.decimation, 1), 0), decomposition.sampleCount - 1)
        let upperSource = min(max(upperSample / max(decomposition.decimation, 1), lowerSource + 1), decomposition.sampleCount - 1)
        return lowerSource...upperSource
    }

    func runICA(on signal: MFFSignalData, onComplete: (@MainActor () -> Void)? = nil) {
        ica.isRunning = true
        ica.progress = 0
        ica.progressMessage = "Preparing ICA..."
        ica.statusMessage = nil

        let fitLowCutoff = max(ica.fitLowCutoff, 0.1)
        let fitHighCutoff = min(max(ica.fitHighCutoff, 0.2), signal.samplingRate / 2 - 0.1)
        if ica.usesFitFilter, fitHighCutoff <= fitLowCutoff {
            ica.isRunning = false
            ica.statusMessage = "ICA fit filter needs a high cutoff above the low cutoff."
            onComplete?()
            return
        }

        let configuration = ICAConfiguration(
            method: ica.method,
            componentCount: min(max(ica.componentCount, 1), signal.numberOfChannels),
            varianceThreshold: min(max(ica.varianceThreshold, 0.01), 1.0),
            averageReference: ica.usesAverageReference,
            downsampleRate: min(max(ica.downsampleRate, 20), signal.samplingRate),
            maxIterations: max(ica.maxIterations, 1),
            learningRate: nil,
            fitFilter: ica.usesFitFilter ? ICAFitFilterSettings(
                lowCutoff: fitLowCutoff,
                highCutoff: fitHighCutoff,
                notch60HzEnabled: ica.fitNotch60HzEnabled,
                family: ica.fitFilterFamily
            ) : nil,
            convergenceTolerance: max(ica.convergenceTolerance, 0),
            minimumIterations: min(max(ica.minimumIterations, 0), max(ica.maxIterations, 1))
        )

        let (progressContinuation, progressTask) = ProgressBridge.make { (update: ICAProgressUpdate) in
            ica.progress = min(max(update.fraction, 0), 1)
            ica.progressMessage = update.message
        }

        icaTask?.cancel()
        let sessionID = recordingSessionID
        icaTask = Task {
          await processingQueue.run("ICA") { [self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let fitSignal: MFFSignalData
                    if let fitFilter = configuration.fitFilter {
                        let filteredData = try await EEGSignalFilter.bandPass(
                            channels: signal.data,
                            samplingRate: signal.samplingRate,
                            lowCutoff: fitFilter.lowCutoff,
                            highCutoff: fitFilter.highCutoff,
                            highPassFamily: fitFilter.family,
                            lowPassFamily: fitFilter.family,
                            notch60HzEnabled: fitFilter.notch60HzEnabled,
                            progress: { fraction in
                                progressContinuation.yield(
                                    ICAProgressUpdate(
                                        fraction: 0.25 * fraction,
                                        message: "Filtering ICA fit copy"
                                    )
                                )
                            }
                        )
                        fitSignal = MFFSignalData(
                            signalURL: signal.signalURL,
                            signalType: "\(signal.signalType) ICA Fit Filtered",
                            numberOfChannels: signal.numberOfChannels,
                            samplingRate: signal.samplingRate,
                            duration: signal.duration,
                            recordingStartTime: signal.recordingStartTime,
                            events: signal.events,
                            data: filteredData,
                            channelNames: signal.channelNames
                        )
                    } else {
                        fitSignal = signal
                    }

                    try Task.checkCancellation()
                    let decomposition = try ICAArtifactDetector.fit(
                        signal: fitSignal,
                        configuration: configuration,
                        progress: { fraction in
                            let scaled = configuration.fitFilter == nil ? fraction : 0.25 + 0.75 * fraction
                            progressContinuation.yield(
                                ICAProgressUpdate(
                                    fraction: scaled,
                                    message: icaProgressMessage(for: fraction)
                                )
                            )
                        }
                    )
                    try Task.checkCancellation()
                    return decomposition
                }
                let decomposition = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                        progressContinuation.finish()
                    }
                )
                progressContinuation.finish()
                progressTask.cancel()
                guard !Task.isCancelled, sessionID == recordingSessionID else { return }
                ica.progress = 1
                ica.progressMessage = "ICA complete"
                var labeledDecomposition = decomposition
                let baseSuggestions = ICAComponentAutoLabeler.suggestions(
                    for: decomposition,
                    layout: recording.sensorLayout
                )
                let detectedBeats = signal.events
                    .filter { $0.code == RWaveDetector.eventCode }
                    .map(\.beginTimeSeconds)
                let ecg = BCGComponentLabeller.likelyECG(in: displayedPhysioSignal())
                let suggestions = BCGComponentLabeller.augmenting(
                    baseSuggestions,
                    decomposition: decomposition,
                    detectedBeatTimes: detectedBeats,
                    ecg: ecg?.samples,
                    ecgSamplingRate: ecg?.samplingRate
                )
                labeledDecomposition.labelSuggestions = suggestions
                for (component, suggestion) in suggestions {
                    labeledDecomposition.labels[component] = suggestion.label
                }
                ica.decomposition = labeledDecomposition
                if decomposition.finalChange.isFinite,
                   decomposition.iterations >= configuration.maxIterations,
                   decomposition.finalChange > configuration.convergenceTolerance {
                    ica.statusMessage = String(
                        format: "ICA stopped at %d iterations. Auto-labeled %d components. Final change %.2g; try more iterations or fewer components.",
                        decomposition.iterations,
                        suggestions.count,
                        decomposition.finalChange
                    )
                } else if decomposition.finalChange.isFinite {
                    ica.statusMessage = String(
                        format: "ICA finished in %d iterations. Auto-labeled %d components. Final change %.2g.%@",
                        decomposition.iterations,
                        suggestions.count,
                        decomposition.finalChange,
                        detectedBeats.count >= BCGComponentLabeller.minimumBeatCount
                            ? " BCG evidence used \(detectedBeats.count) detected R waves."
                            : " Detect at least \(BCGComponentLabeller.minimumBeatCount) R waves to add BCG-specific labels."
                    )
                } else {
                    ica.statusMessage = "ICA finished in \(decomposition.iterations) iterations after learning-rate backoff."
                }
            } catch is CancellationError {
                progressContinuation.finish()
                progressTask.cancel()
            } catch {
                progressContinuation.finish()
                progressTask.cancel()
                guard sessionID == recordingSessionID else { return }
                ica.statusMessage = error.localizedDescription
                ica.progressMessage = "ICA failed"
            }
            if sessionID == recordingSessionID {
                ica.isRunning = false
                icaTask = nil
            }
            onComplete?()
          }
        }
    }

    /// Awaitable wrapper around `runICA` for the interactive replay loop.
    @MainActor
    func runICADecomposition(on signal: MFFSignalData) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            runICA(on: signal, onComplete: { cont.resume() })
        }
    }

    private nonisolated func icaProgressMessage(for detectorFraction: Double) -> String {
        switch detectorFraction {
        case ..<0.08:
            return "Downsampling ICA data"
        case ..<0.16:
            return "Centering channels"
        case ..<0.30:
            return "Building covariance"
        case ..<0.40:
            return "Solving PCA whitening"
        case ..<0.48:
            return "Whitening data"
        case ..<0.88:
            return "Rotating ICA weights"
        default:
            return "Preparing component maps"
        }
    }

    func removeSelectedICAComponents(from signal: MFFSignalData) {
        guard let decomposition = ica.decomposition,
              !decomposition.excludedComponents.isEmpty else {
            ica.statusMessage = "Select at least one component to remove."
            return
        }

        let excludedComponents = decomposition.excludedComponents
        let shouldRestoreFilter = filter.output != nil
        let beforeDisplaySignal = filter.output ?? signal
        let restoredFilterHighPassCutoff = filter.highPassCutoff
        let restoredFilterLowPassCutoff = filter.lowPassCutoff
        let restoredFilterHighPassCutoffText = filter.highPassCutoffText
        let restoredFilterLowPassCutoffText = filter.lowPassCutoffText
        let restoredNotch60HzEnabled = filter.notch60HzEnabled
        let restoredAverageReference = filter.averageReference
        let restoredReferenceExclusions = channels.bad
        let restoredAmplitudeScale = amplitudeScale
        let restoredTimeScale = timeScale
        let restoredScrollPosition = horizontalScrollPosition
        ica.isRemovingComponents = true
        ica.lastReconstructionDebugReport = """
        ## Last ICA Removal
        Status: reconstruction in progress
        Excluded components: \(excludedComponents.sorted().map { "IC \($0 + 1) \(decomposition.labels[$0] ?? "")" }.joined(separator: ", ").nilIfEmpty ?? "none")
        Before display signal type: \(beforeDisplaySignal.signalType)
        \(debugStatsLine("Before display full", signal: beforeDisplaySignal))
        """
        ica.statusMessage = "Reconstructing EEG..."

        icaRemovalTask?.cancel()
        let sessionID = recordingSessionID
        icaRemovalTask = Task {
          await processingQueue.run("ICA Component Removal") { [self] in
            // Shared with headless replay (`ICAReplay.activationSignal`) so the
            // interactive and re-applied reconstructions cannot drift.
            //
            // This used to swallow a filter failure and carry on with a `nil`
            // activation — which does not fail, it reconstructs the sources from
            // the *unfiltered* base signal and returns different samples than the
            // fit implies. Silently different data is worse than no removal, so
            // the removal now aborts and says why.
            var reconstructionActivationSignal: MFFSignalData?
            if decomposition.fitFilter != nil {
                ica.statusMessage = "Filtering ICA activation copy..."
                do {
                    reconstructionActivationSignal = try await ICAReplay.activationSignal(
                        for: signal,
                        fitFilter: decomposition.fitFilter
                    )
                } catch {
                    ica.statusMessage = error.localizedDescription
                    ica.isRemovingComponents = false
                    filter.statusMessage = error.localizedDescription
                    filter.statusIsError = true
                    icaRemovalTask = nil
                    // Sheet stays open: nothing was applied, so the components
                    // are still selected and the user can retry.
                    return
                }
            }

            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            ica.statusMessage = "Reconstructing EEG..."
            let cleaningWorker = Task.detached(priority: .userInitiated) {
                ICAArtifactDetector.cleanedSignal(
                    from: signal,
                    activationSignal: reconstructionActivationSignal,
                    decomposition: decomposition,
                    excluding: excludedComponents
                )
            }
            let cleaned = await withTaskCancellationHandler(
                operation: {
                    await cleaningWorker.value
                },
                onCancel: {
                    cleaningWorker.cancel()
                }
            )

            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            var restoredFilteredSignal: MFFSignalData?
            if shouldRestoreFilter {
                do {
                    let filterWorker = Task.detached(priority: .userInitiated) {
                        try await EEGSignalFilter.bandPass(
                            channels: cleaned.data,
                            samplingRate: cleaned.samplingRate,
                            lowCutoff: restoredFilterHighPassCutoff,
                            highCutoff: restoredFilterLowPassCutoff,
                            notch60HzEnabled: restoredNotch60HzEnabled
                        )
                    }
                    let filteredData = try await withTaskCancellationHandler(
                        operation: {
                            try await filterWorker.value
                        },
                        onCancel: {
                            filterWorker.cancel()
                        }
                    )

                    let filtered = cleaned.replacingSamples(filteredData)
                    restoredFilteredSignal = restoredAverageReference
                        ? Rereferencing.applied(filtered, excluding: restoredReferenceExclusions)
                        : filtered
                } catch {
                    filter.statusMessage = error.localizedDescription
                    filter.statusIsError = true
                }
            }

            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            // The pipeline half of the commit is shared with the headless path
            // (`ProcessingCore`'s `.icaClean` case) so the two cannot drift.
            // Everything below it — filter restoration, the debug report, the
            // viewport, the sheet, the replay gate — is view and session state
            // that only this caller has.
            ICAComponentRemoval.commit(
                cleaned: cleaned,
                ica: ica,
                artifactVM: artifactVM,
                template: template,
                epoching: epoching,
                segHealth: segHealth,
                store: recordingStore
            )
            filter.output = restoredFilteredSignal
            ica.lastReconstructionDebugReport = icaReconstructionDebugReport(
                beforeBase: signal,
                beforeDisplay: beforeDisplaySignal,
                activationSignal: reconstructionActivationSignal,
                afterBase: cleaned,
                afterDisplay: restoredFilteredSignal ?? cleaned,
                decomposition: decomposition,
                excludedComponents: excludedComponents
            )
            filter.highPassCutoffText = restoredFilterHighPassCutoffText
            filter.lowPassCutoffText = restoredFilterLowPassCutoffText
            filter.notch60HzEnabled = restoredNotch60HzEnabled
            amplitudeScale = restoredAmplitudeScale
            timeScale = restoredTimeScale
            horizontalScrollPosition = restoredScrollPosition
            artifactVM.statusMessage = "Removed \(excludedComponents.count) ICA components."
            ica.isRemovingComponents = false
            ica.showsSheet = false
            icaRemovalTask = nil
            // Applying components resolves an interactive-replay decision pause.
            if replay.state.isAwaitingDecision { replay.resume(.proceed) }
          }
        }
    }

    func saveICAJSON(_ decomposition: ICADecomposition?) {
        guard let decomposition else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ica-artifacts.json"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(ICAArtifactDetector.savedArtifactSet(from: decomposition))
            try data.write(to: url, options: .atomic)
            ica.statusMessage = "Saved \(url.lastPathComponent)."
        } catch {
            ica.statusMessage = error.localizedDescription
        }
    }
}
