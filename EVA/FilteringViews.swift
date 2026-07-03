//
//  FilteringViews.swift
//  EVA
//
//  Bandpass/notch filter popover, replay banner, and interactive-replay driver,
//  This is an extension of WaveformView (not a standalone type), following the
//  same pattern as the other L5 slices -- a file split, not a state extraction.
//

import SwiftUI

extension WaveformView {
    // MARK: - Filtering

    func filterPopover(for signal: MFFSignalData) -> some View {
        let lineNoiseMode = filter.activeLineNoiseMode
        let lineNoiseBinding = Binding<FilterLineNoiseMode> {
            filter.activeLineNoiseMode
        } set: { mode in
            filter.lineNoiseMode = mode
            filter.notch60HzEnabled = mode == .notch
            if mode != .off {
                filter.showsLineNoiseOptions = true
            }
        }

        return VStack(alignment: .leading, spacing: 14) {
            Text("Filter")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("High-Pass Cutoff (Hz)")
                    .font(.caption.weight(.semibold))
                HStack {
                    TextField("Off", text: $filter.highPassCutoffText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .help("Leave blank for no high-pass cutoff.")
                    Stepper("", value: Binding<Double>(
                        get: { filter.highPassCutoff ?? 0.1 },
                        set: { filter.lowCutoff = $0 }
                    ), in: 0.1...100, step: 0.1)
                        .labelsHidden()
                    Picker("HP Slope", selection: $filter.highPassSlope) {
                        ForEach(FilterSlope.allCases) { slope in
                            Text(slope.label).tag(slope)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .disabled(filter.highPassCutoff == nil)
                    .help("High-pass rolloff slope. 12 dB/oct (2-pole) is gentler and produces less ringing near the cutoff; 24 dB/oct (4-pole) is steeper. Both are applied zero-phase (forward+backward pass).")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Low-Pass Cutoff (Hz)")
                    .font(.caption.weight(.semibold))
                HStack {
                    TextField("Off", text: $filter.lowPassCutoffText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .help("Leave blank for no low-pass cutoff.")
                    Stepper("", value: Binding<Double>(
                        get: { filter.lowPassCutoff ?? 30 },
                        set: { filter.highCutoff = $0 }
                    ), in: 0.5...200, step: 0.5)
                        .labelsHidden()
                    Picker("LP Slope", selection: $filter.lowPassSlope) {
                        ForEach(FilterSlope.allCases) { slope in
                            Text(slope.label).tag(slope)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .disabled(filter.lowPassCutoff == nil)
                    .help("Low-pass rolloff slope. 24 dB/oct is a common choice for BCG preprocessing; 48 dB/oct gives a sharper brick-wall rolloff at the cost of more ringing. Both are zero-phase.")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Line Noise")
                    .font(.caption.weight(.semibold))
                Picker("Line Noise", selection: lineNoiseBinding) {
                    ForEach(FilterLineNoiseMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                DisclosureGroup("Line Noise Options", isExpanded: $filter.showsLineNoiseOptions) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Frequency")
                                .font(.caption)
                                .frame(width: 76, alignment: .leading)
                            TextField("Hz", value: $filter.lineNoiseFrequency, format: .number.precision(.fractionLength(1)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Stepper("", value: $filter.lineNoiseFrequency, in: 45...65, step: 0.5)
                                .labelsHidden()
                        }

                        HStack {
                            Text("Harmonics")
                                .font(.caption)
                                .frame(width: 76, alignment: .leading)
                            Stepper(value: $filter.lineNoiseHarmonics, in: 1...4) {
                                Text("\(filter.lineNoiseHarmonics)")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 32, alignment: .leading)
                            }
                        }
                        .disabled(lineNoiseMode != .adaptiveCleanLine)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("Window")
                                    .font(.caption)
                                Spacer()
                                Text(String(format: "%.1fs", filter.lineNoiseWindowSeconds))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $filter.lineNoiseWindowSeconds, in: 1...10, step: 0.5)
                        }
                        .disabled(lineNoiseMode != .adaptiveCleanLine)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("Strength")
                                    .font(.caption)
                                Spacer()
                                Text(String(format: "%.2fx", filter.lineNoiseStrength))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $filter.lineNoiseStrength, in: 0.25...1.50, step: 0.05)
                        }
                        .disabled(lineNoiseMode != .adaptiveCleanLine)
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
                .disabled(lineNoiseMode == .off)
            }

            Toggle("Average reference", isOn: $filter.averageReference)
                .help("Re-reference to the common average: subtract the mean across all channels at each time point. Removes shared reference signal.")

            HStack {
                Spacer()
                Picker("Precision", selection: $filter.precision) {
                    ForEach(FilterPrecision.allCases) { precision in
                        Text(precision.label).tag(precision)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 190)
                .help("Auto uses Float for routine filters, Double for numerically risky settings, and retries in Double if Float becomes unstable.")
            }

            if recording.pnsSignal != nil {
                Toggle("Filter PNS", isOn: $filter.filterPNS)
                    .font(.caption)
                    .help("Apply the cutoff and line-noise filter to physio/PNS channels. Average reference is EEG-only.")
            }

            HStack {
                Button("Reset 0.1–30 Hz") {
                    filter.resetToDefaults()
                }

                if filter.isActive {
                    Button("Remove Filter", role: .destructive) {
                        clearBandpassFilter()
                        filter.showsPopover = false
                    }
                }

                Spacer()

                Button("Apply Filter") {
                    applyBandpassFilter(to: signal)
                    filter.showsPopover = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    func applyBandpassFilter(to signal: MFFSignalData) {
        let pnsInput = filter.filterPNS ? pnsFilterBaseSignal() : nil
        // The interactive path fires the shared async apply without awaiting;
        // the replay coordinator awaits the same method (one code path).
        filterTask?.cancel()
        let sessionID = recordingSessionID
        filterTask = Task {
            await processingQueue.run("Filter") { [self] in
                await filter.apply(
                    to: signal,
                    pnsInput: pnsInput,
                    onApplied: { [self] in
                        guard sessionID == recordingSessionID else { return }
                        postFilterInvalidation()
                    }
                )
            }
            if !Task.isCancelled, sessionID == recordingSessionID {
                filterTask = nil
            }
        }
    }

    /// Downstream invalidation shared by interactive filtering and replay.
    func postFilterInvalidation() {
        clearAppliedArtifactCleaning()
        artifactVM.detectionRefreshToken += 1
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
    }

    /// Launches the interactive replay once the user confirms the config pane.
    func startInteractiveReplay() {
        replay.showsConfigPane = false
        replayTask?.cancel()
        let sessionID = recordingSessionID
        replayTask = Task {
            await interactiveReplay()
            guard sessionID == recordingSessionID else { return }
            replayTask = nil
        }
    }

    /// Re-applies the configured steps to the current recording, in canonical
    /// chain order, driving the SAME apply-functions the interactive UI uses.
    /// Pauses (via the controller's async gate) for review/decision steps, then
    /// resumes. Awaits each transform so downstream steps see settled output.
    @MainActor
    func interactiveReplay() async {
        guard let rawSignal = recording.signal else { replay.state = .finished; return }
        let actions = replay.plannedActions()

        loop: for action in actions {
            let params = replay.parameters(forStep: action.stepIndex)
            replay.state = .running(index: action.stepIndex)

            switch action.operation {
            case .mriGradientCorrection:
                gradient.apply(parameters: params)
                if action.gate == .review {
                    gradient.showsPopover = true
                    let decision = await replay.gate(.awaitingReview(index: action.stepIndex),
                        banner: .init(title: "Review MRI Gradient Correction",
                                      detail: "Adjust TR-skip, motion, or window in the panel, then Apply.",
                                      showsSkip: true, progress: nil))
                    gradient.showsPopover = false
                    switch decision {
                    case .cancel: break loop
                    case .skip: continue loop
                    case .proceed: break
                    }
                }
                await applyGradientCorrection(to: rawSignal)

            case .filter:
                filter.apply(parameters: params)
                // Auto step: a review gate (Review-Each mode) is banner-only — no
                // popover — so the loop remains the sole applier (no double-apply).
                if action.gate == .review {
                    switch await replay.gate(.awaitingReview(index: action.stepIndex),
                        banner: .init(title: "Apply Filter?",
                                      detail: "\(filter.activeFilterSummary). Continue to apply.",
                                      showsSkip: true, progress: nil)) {
                    case .cancel: break loop
                    case .skip: continue loop
                    case .proceed: break
                    }
                }
                let base = ica.cleanedSignal ?? gradient.correctedSignal ?? rawSignal
                let pnsInput = filter.filterPNS ? pnsFilterBaseSignal() : nil
                await filter.apply(
                    to: base,
                    pnsInput: pnsInput,
                    onApplied: { [self] in postFilterInvalidation() }
                )

            case .thresholdArtifactDetection:
                artifactVM.detectionMethod = .threshold
                detectsEyeBlinkArtifacts = params["eyeBlink"] == "true"
                detectsEyeMovementArtifacts = params["eyeMovement"] == "true"
                artifactVM.blinkThresholdConfig = .fromFlatParameters(params, prefix: "blink",
                    base: artifactVM.blinkThresholdConfig)
                artifactVM.movementThresholdConfig = .fromFlatParameters(params, prefix: "movement",
                    base: artifactVM.movementThresholdConfig)

            case .icaClean:
                // Auto-run the (portable) decomposition, then pause for the
                // subject-specific component-removal decision.
                ica.apply(parameters: params)
                replay.banner = .init(title: "Running ICA…", detail: "Decomposing components.",
                                      showsSkip: false, progress: nil)
                let base = gradient.correctedSignal ?? rawSignal
                await runICADecomposition(on: base)
                guard ica.decomposition != nil else { replay.banner = nil; continue loop }
                openICASheet(for: base)
                switch await replay.gate(.awaitingDecision(index: action.stepIndex),
                    banner: .init(title: "Select ICA Components",
                                  detail: "Choose components to remove, then Remove — or Close to skip.",
                                  showsSkip: true, progress: nil)) {
                case .cancel: ica.showsSheet = false; break loop
                case .skip, .proceed: break // .proceed = applied; .skip = closed unapplied
                }

            case .artifactClean:
                // No automated part — artifact templates are drawn per subject.
                // Pause immediately; the user defines/cleans via the normal UI
                // (Define Artifact, Clean Artifacts) and resolves the gate from
                // there (Apply → .proceed, Close-without-cleaning → .skip).
                switch await replay.gate(.awaitingDecision(index: action.stepIndex),
                    banner: .init(title: "Define & Clean Artifacts",
                                  detail: "Draw artifact templates and Apply cleaning, then Continue — or Skip to leave this file unclean.",
                                  showsSkip: true, progress: nil)) {
                case .cancel: artifactVM.showsCleaningSheet = false; break loop
                case .skip, .proceed: break
                }

            case .segment:
                // Automate PSA: segment (+ baseline / average per params), then
                // open the butterfly plot when an average was produced.
                epoching.apply(parameters: params)
                if let psaSignal = continuousProcessedSignal {
                    await applyPSA(to: psaSignal)
                    if epoching.isAveraged { epoching.showsButterflyPlot = true }
                }

            default:
                continue loop
            }
        }

        if Task.isCancelled {
            replay.banner = nil
            replay.state = .cancelled
            if batch.isActive, batch.matches(recording: recording) {
                batch.completeCurrent(.skipped) // per-file Cancel → skip + advance
            }
            return
        }

        // Finish-and-export: the seam Batch produces outputs through.
        if replay.exportWhenFinished, let folder = replay.outputFolder {
            await exportReplayResult(to: folder)
        }

        replay.banner = nil
        replay.state = .finished

        // Advance the batch only after export has fully completed above.
        if batch.isActive, batch.matches(recording: recording) {
            batch.completeCurrent(.done)
        }
    }

    /// Writes the processed recording to `<folder>/<name>-processed.mff` (with its
    /// eva.xml) after an interactive replay finishes. Panel-free so Batch can call
    /// it per file. Uses renamed PNS without the synthetic-channel prompt.
    @MainActor
    func exportReplayResult(to folder: URL) async {
        guard let snapshot = currentMFFExportSnapshot() else { return }
        let base = (recording.packageName as NSString).deletingPathExtension
        let url = folder.appendingPathComponent("\(base)-processed.mff")
        replay.banner = .init(title: "Exporting…", detail: url.lastPathComponent,
                              showsSkip: false, progress: nil)
        let result = await performMFFExport(
            snapshot: snapshot,
            pnsForExport: pnsSignalWithRenames(),
            script: currentProcessingScript(),
            to: url
        )
        switch result {
        case .success(let out):
            filter.statusMessage = "Processed + exported \(out.lastPathComponent)."
            filter.statusIsError = false
        case .failure(let error):
            filter.statusMessage = "Export failed: \(error.localizedDescription)"
            filter.statusIsError = true
        }
    }

    /// Top banner shown while an interactive replay is running or paused.
    @ViewBuilder
    func replayBanner() -> some View {
        if let info = replay.banner {
            HStack(spacing: 12) {
                if replay.state.isAwaiting {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.small)
                }

                VStack(alignment: .leading, spacing: 1) {
                    if batch.isActive, let job = batch.currentJob {
                        Text("File \(batch.currentIndex + 1) of \(batch.jobs.count) · \(job.name)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    Text(info.title).font(.callout.weight(.semibold))
                    Text(info.detail).font(.caption).foregroundStyle(.secondary)
                }

                if ica.isRunning {
                    ProgressView(value: ica.progress).frame(width: 120)
                }

                Spacer(minLength: 12)

                if replay.state.isAwaiting {
                    Button("Continue") { replay.resume(.proceed) }
                        .keyboardShortcut(.defaultAction)
                    if info.showsSkip {
                        Button("Skip") { replay.resume(.skip) }
                    }
                }
                // In batch, Cancel skips just this file; Stop Batch ends the run.
                Button(batch.isActive ? "Skip File" : "Cancel", role: .cancel) { replay.cancel() }
                if batch.isActive {
                    Button("Stop Batch") {
                        batch.stop()
                        replay.cancel()
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.35)))
            .shadow(radius: 6)
            .padding(12)
            .frame(maxWidth: 640)
        }
    }

    func clearBandpassFilter() {
        filter.clear(onCleared: { [self] in
            clearAppliedArtifactCleaning()
            artifactVM.detectionRefreshToken += 1
            invalidateEpochsForSignalChange()
            invalidateInterpolations()
        })
    }


}
