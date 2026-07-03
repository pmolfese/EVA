//
//  ICAExplorationViews.swift
//  EVA
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
                        help: "Picard (recommended) is a preconditioned ICA that converges in a few iterations. FastICA is a fast symmetric fixed-point solver. Infomax is the slower MNE/EEGLAB extended-infomax kept for reference."
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
                notch60HzEnabled: ica.fitNotch60HzEnabled
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
                let suggestions = ICAComponentAutoLabeler.suggestions(
                    for: decomposition,
                    layout: recording.sensorLayout
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
                        format: "ICA finished in %d iterations. Auto-labeled %d components. Final change %.2g.",
                        decomposition.iterations,
                        suggestions.count,
                        decomposition.finalChange
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
            var reconstructionActivationSignal: MFFSignalData?
            if let fitFilter = decomposition.fitFilter {
                do {
                    ica.statusMessage = "Filtering ICA activation copy..."
                    let activationData = try await EEGSignalFilter.bandPass(
                        channels: signal.data,
                        samplingRate: signal.samplingRate,
                        lowCutoff: fitFilter.lowCutoff,
                        highCutoff: fitFilter.highCutoff,
                        notch60HzEnabled: fitFilter.notch60HzEnabled
                    )

                    reconstructionActivationSignal = MFFSignalData(
                        signalURL: signal.signalURL,
                        signalType: "\(signal.signalType) ICA Activation Filtered",
                        numberOfChannels: signal.numberOfChannels,
                        samplingRate: signal.samplingRate,
                        duration: signal.duration,
                        recordingStartTime: signal.recordingStartTime,
                        events: signal.events,
                        data: activationData,
                        channelNames: signal.channelNames
                    )
                } catch {
                    filter.statusMessage = error.localizedDescription
                    filter.statusIsError = true
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

                    restoredFilteredSignal = MFFSignalData(
                        signalURL: cleaned.signalURL,
                        signalType: cleaned.signalType,
                        numberOfChannels: cleaned.numberOfChannels,
                        samplingRate: cleaned.samplingRate,
                        duration: cleaned.duration,
                        recordingStartTime: cleaned.recordingStartTime,
                        events: cleaned.events,
                        data: filteredData,
                        channelNames: cleaned.channelNames
                    )
                } catch {
                    filter.statusMessage = error.localizedDescription
                    filter.statusIsError = true
                }
            }

            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            ica.cleanedSignal = cleaned
            filter.output = restoredFilteredSignal
            clearAppliedArtifactCleaning()
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
            artifactVM.events = []
            artifactVM.statusMessage = "Removed \(excludedComponents.count) ICA components."
            artifactVM.detectionRefreshToken += 1
            invalidateEpochsForSignalChange()
            invalidateInterpolations()
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
