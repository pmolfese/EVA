//
//  FilteringViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Bandpass/notch filter popover, replay banner, and interactive-replay driver,
//  This is an extension of WaveformView (not a standalone type), following the
//  same pattern as the other L5 slices -- a file split, not a state extraction.
//

import SwiftUI

/// What the Filter popover's Presets pop-up is currently showing.
///
/// `.custom` is a state the pop-up can *display* but that nothing applies —
/// selecting it would mean "make my settings unlike every package", which is
/// not an action. The binding below therefore ignores it.
enum FilterPresetSelection: Hashable {
    case custom
    case preset(FilterApproximationPreset)
}

extension WaveformView {
    // MARK: - Filtering

    /// Reads the preset the current mechanics correspond to, and applies one
    /// when the user picks it. Selecting the displayed "Custom" entry is a
    /// no-op — it is a description of the current state, not a destination.
    var filterPresetSelection: Binding<FilterPresetSelection> {
        Binding(
            get: { filter.activePreset.map(FilterPresetSelection.preset) ?? .custom },
            set: { selection in
                if case let .preset(preset) = selection {
                    filter.applyApproximation(preset)
                }
            }
        )
    }

/// Advanced FIR mechanics, collapsed by default.
    ///
    /// Exists mainly to make the realized filter visible *before* Apply. The
    /// kernel a request needs can exceed what a recording can carry — a narrow
    /// hand-set transition still gets there easily — and EVA used to silently
    /// shorten it, so the same settings quietly produced a different filter on a
    /// shorter file. The readout states what was asked for, what will actually
    /// be built, and how much data the full kernel would need.
    @ViewBuilder
    func firAdvancedSection(for signal: MFFSignalData) -> some View {
        if filter.filterFamily != .iir || filter.notchIsFIREffective {
            DisclosureGroup("Advanced", isExpanded: $showsFilterAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Text("Design rule")
                            .font(.caption)
                            .fixedSize()
                        InfoPopoverButton(title: "FIR Design Rule", message: """
                            How a requested cutoff becomes a filter. Packages disagree, so the same "30 Hz low-pass" can mean measurably different things.

                            EVA — the transition band is 25% of the cutoff, floored at 2 Hz and capped at the available band, and the frequency you type is the −6 dB point.

                            EEGLAB / MNE — the same transition band, but the frequency you type is the passband edge, with −6 dB falling half a transition beyond it. A band-pass uses one kernel sized by the narrower edge. MNE documents its default design as reproducing EEGLAB's, so both packages share this rule.

                            Whichever you pick is recorded in eva.xml, so a saved run states the convention that produced it rather than leaving it to be inferred.
                            """)
                        Spacer()
                        Picker("Design rule", selection: $filter.firDesignRule) {
                            ForEach(FIRDesignRule.allCases) { rule in
                                Text(rule.label).tag(rule)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }

                    ForEach(firDesignReports(for: signal), id: \.label) { report in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(report.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .leading)
                            Text(report.report.summary)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(report.report.wasCapped ? Color.orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }

                    if let capped = firDesignReports(for: signal).first(where: { $0.report.wasCapped }) {
                        Text(String(
                            format: "This recording is too short for the requested kernel. The full %d taps need %.0f s of data; widen the transition, raise the cutoff, or use a longer recording.",
                            capped.report.requestedTaps, capped.report.requiredRecordingSeconds
                        ))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
    }

    /// Per-edge design reports for whichever edges actually resolve to FIR.
    func firDesignReports(for signal: MFFSignalData) -> [(label: String, report: EEGSignalFilter.FIRDesignReport)] {
        let sampleCount = signal.data.map(\.count).min() ?? 0
        guard signal.samplingRate > 0, sampleCount > 0 else { return [] }

        var out: [(label: String, report: EEGSignalFilter.FIRDesignReport)] = []
        let edges: [(String, Double?, FilterEdge)] = [
            ("High-pass", filter.highPassCutoff, .highPass),
            ("Low-pass", filter.lowPassCutoff, .lowPass),
        ]
        for (label, cutoff, edge) in edges {
            guard let cutoff else { continue }
            let resolved = EEGSignalFilter.resolvedFamily(
                filter.filterFamily, edge: edge, cutoff: cutoff,
                crossoverHz: filter.firCrossoverHz, crossoverRule: filter.firCrossoverRule
            )
            guard resolved == .fir else { continue }
            out.append((label, EEGSignalFilter.firDesignReport(
                cutoff: cutoff, samplingRate: signal.samplingRate, edge: edge,
                transitionHz: filter.firTransitionHz, maxChannelLength: sampleCount,
                window: filter.firWindow, kaiserAttenuationDB: filter.firKaiserAttenuationDB,
                rule: filter.firDesignRule
            )))
        }
        return out
    }

    func filterPopover(for signal: MFFSignalData) -> some View {
        let lineNoiseMode = filter.activeLineNoiseMode

        // Which edges are FIR under the current family, so the IIR-only slope
        // pickers can be disabled where they don't apply.
        let highPassIsFIR = (filter.highPassCutoff.map {
            EEGSignalFilter.resolvedFamily(
                filter.filterFamily, edge: .highPass, cutoff: $0,
                crossoverHz: filter.firCrossoverHz,
                crossoverRule: filter.firCrossoverRule
            ) == .fir
        }) ?? (filter.filterFamily == .fir)
        let lowPassIsFIR = filter.filterFamily != .iir
        let hasIIREdge = filter.filterFamily != .fir
        let hasFIREdge = filter.filterFamily != .iir
            || (lineNoiseMode == .notch && filter.notchUsesFIR)

        return VStack(alignment: .leading, spacing: 14) {
            Text("Filter")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("Filter Type")
                        .font(.caption.weight(.semibold))
                    InfoPopoverButton(title: "Filter Types", message: """
                        IIR — zero-phase recursive filtering. Choose a smooth Butterworth response or a steeper elliptic response with controlled passband ripple and stopband attenuation.

                        FIR — linear-phase finite impulse response with a Hamming or Kaiser window. Apply it forward+backward, once with delay compensation, or causally forward-only.

                        Auto — Net Station-style hybrid: IIR high-pass on the selected side of the crossover (where an FIR kernel would be impractically long) and FIR everywhere else.
                        """)
                    Spacer()
                }
                Picker("Filter Type", selection: $filter.filterFamily) {
                    ForEach(FilterFamily.allCases) { family in
                        Text(family.label).tag(family)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if hasIIREdge {
                    HStack {
                        Text("IIR Design")
                            .font(.caption)
                        Spacer()
                        Picker("IIR Design", selection: $filter.iirDesign) {
                            ForEach(IIRDesign.allCases) { design in
                                Text(design.label).tag(design)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }

                    if filter.iirDesign == .elliptic {
                        HStack {
                            Text("Design ripple")
                                .font(.caption)
                            TextField("dB", value: $filter.ellipticPassbandRippleDB,
                                      format: .number.precision(.fractionLength(2)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 58)
                            Text("dB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Stopband")
                                .font(.caption)
                            TextField("dB", value: $filter.ellipticStopbandAttenuationDB,
                                      format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 58)
                            Text("dB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .help("One-pass elliptic design specifications. Forward+backward application doubles both values in dB and gives zero phase.")
                    }
                }

                if hasFIREdge {
                    HStack {
                        Text("FIR Window")
                            .font(.caption)
                        Spacer()
                        Picker("FIR Window", selection: $filter.firWindow) {
                            ForEach(FIRWindow.allCases) { window in
                                Text(window.label).tag(window)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }

                    if filter.firWindow == .kaiser {
                        HStack {
                            Text("Kaiser attenuation")
                                .font(.caption)
                            Spacer()
                            TextField("dB", value: $filter.firKaiserAttenuationDB,
                                      format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                            Text("dB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .help("Requested stopband attenuation used to derive Kaiser beta and the automatic tap count.")
                    }

                    HStack {
                        Text("FIR Application")
                            .font(.caption)
                        Spacer()
                        Picker("FIR Application", selection: $filter.firApplication) {
                            ForEach(FIRApplication.allCases) { application in
                                Text(application.label).tag(application)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 235)
                    }
                    .help("Two pass is zero-phase and squares the magnitude response. Delay-compensated is one pass with its fixed linear-phase delay removed. Forward-only is causal and retains the group delay.")
                }

                if hasFIREdge {
                    HStack {
                        if filter.filterFamily == .auto {
                            Text("IIR HP")
                                .font(.caption)
                            Picker("Crossover rule", selection: $filter.firCrossoverRule) {
                                ForEach(AutoCrossoverRule.allCases) { rule in
                                    Text(rule.label).tag(rule)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 86)
                            TextField("Hz", value: $filter.firCrossoverHz, format: .number.precision(.fractionLength(2)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("Hz")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Transition")
                            .font(.caption)
                        TextField("Auto", value: Binding(
                            get: { filter.firTransitionHz ?? 0 },
                            set: { filter.firTransitionHz = $0 > 0 ? $0 : nil }
                        ), format: .number.precision(.fractionLength(2)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            .help("FIR transition-band width in Hz. Leave 0 for automatic (25% of the cutoff). Narrower transitions need more taps.")
                        Text("Hz")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

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
                            Text(filter.iirDesign == .elliptic ? "Order \(slope.designPoles)" : slope.label).tag(slope)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .disabled(filter.highPassCutoff == nil || highPassIsFIR)
                    .help("High-pass rolloff slope (IIR only), reported as the effective slope after zero-phase (forward+backward) filtering. 24 dB/oct (2-pole design) is gentler and produces less ringing near the cutoff; 48 dB/oct (4-pole design) is steeper.")
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
                            Text(filter.iirDesign == .elliptic ? "Order \(slope.designPoles)" : slope.label).tag(slope)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .disabled(filter.lowPassCutoff == nil || lowPassIsFIR)
                    .help("Low-pass rolloff slope (IIR only), reported as the effective slope after zero-phase (forward+backward) filtering. 48 dB/oct is a common choice for BCG preprocessing; 96 dB/oct gives a sharper brick-wall rolloff at the cost of more ringing.")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Line Noise")
                    .font(.caption.weight(.semibold))
                Picker("Line Noise", selection: $filter.lineNoiseMode) {
                    ForEach(FilterLineNoiseMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: filter.lineNoiseMode) { _, mode in
                    if mode != .off, !showsFilterLineNoiseOptions {
                        showsFilterLineNoiseOptions = true
                    }
                }

                // Notch design remains independent of the passband preset. FIR
                // is off by default because it is much more expensive than the
                // single IIR biquad.
                if lineNoiseMode == .notch {
                    HStack(spacing: 4) {
                        Toggle("Apply notch as FIR", isOn: $filter.notchUsesFIR)
                            .font(.caption)
                        InfoPopoverButton(title: "FIR Notch", message: """
                            Applies the line-noise notch as a linear-phase FIR band-stop instead of the default IIR biquad.

                            This is computationally expensive: a narrow FIR notch needs hundreds to thousands of taps and uses the FIR application selected above.

                            Prefer the IIR notch unless you specifically need linear phase or an all-FIR chain.
                            """)
                    }
                }

                DisclosureGroup("Line Noise Options", isExpanded: $showsFilterLineNoiseOptions) {
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
                        // Harmonics apply to CleanLine and to the FIR notch
                        // (which nulls them in one kernel). The IIR notch is
                        // single-frequency only.
                        .disabled(lineNoiseMode != .adaptiveCleanLine && !filter.notchIsFIREffective)

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

            firAdvancedSection(for: signal)

            // Presets and Precision share a row: both name *how* filtering is
            // carried out rather than what the passband is, so they belong
            // together below the settings they summarize rather than above
            // them. Labels sit beside each control instead of over the group,
            // since neither heads a section any more.
            HStack(spacing: 6) {
                Text("Presets")
                    .font(.caption)
                    .fixedSize()
                InfoPopoverButton(title: "Filter Presets", message: """
                    Sets EVA's filter mechanics — type, design, window, application, and slopes — to match how another EEG package filters, so results are easier to compare.

                    Your passband cutoffs and your line-noise, referencing, PNS, and precision settings are left exactly as they are.

                    EEGLAB — Hamming-window FIR, one pass with its linear-phase delay removed, automatic transition width.

                    ERPLAB — Butterworth IIR at 24 dB/oct on both edges.

                    MNE-Python — Hamming-window FIR, delay-compensated, matching MNE's default design.

                    EGI Net Station — the hybrid: elliptic IIR high-pass below 1 Hz, forward-only Kaiser FIR elsewhere.

                    Reads Custom until you pick one, and returns to Custom as soon as you change any of these by hand.
                    """)
                Picker("Presets", selection: filterPresetSelection) {
                    // "Custom" is listed only while it is the current state, the
                    // way a Mac preset pop-up behaves: it describes where you
                    // are, it is not somewhere to go.
                    if filter.activePreset == nil {
                        Text("Custom").tag(FilterPresetSelection.custom)
                        Divider()
                    }
                    ForEach(FilterApproximationPreset.allCases) { preset in
                        Text(preset.label).tag(FilterPresetSelection.preset(preset))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 142)
                .help("Configure filter mechanics like another EEG package. Passband cutoffs and line-noise/notch settings are preserved.")

                Spacer(minLength: 6)

                Text("Precision")
                    .font(.caption)
                    .fixedSize()
                Picker("Precision", selection: $filter.precision) {
                    ForEach(FilterPrecision.allCases) { precision in
                        Text(precision.label).tag(precision)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 92)
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
                        showsFilterPopover = false
                    }
                }

                Spacer()

                Button("Apply Filter") {
                    applyBandpassFilter(to: signal)
                    showsFilterPopover = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 430)
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
        PipelineInvalidation.downstreamOfFilterChange(
            store: recordingStore,
            artifactVM: artifactVM,
            template: template,
            epoching: epoching,
            segHealth: segHealth
        )
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

        loop: for (actionOrdinal, action) in actions.enumerated() {
            let params = replay.parameters(forStep: action.stepIndex)
            replay.state = .running(index: action.stepIndex)
            let stepName = ReplayStepDisplay.label(for: action.operation)
            if batch.isActive, batch.matches(recording: recording) {
                let fileProgress = actions.isEmpty ? 1 : Double(actionOrdinal) / Double(actions.count)
                batch.updateProgress(stepName: stepName, stepProgress: nil, fileProgress: fileProgress)
            }
            replay.banner = .init(
                title: "Applying \(stepName)",
                detail: ReplayStepDisplay.runningDetail(for: action.operation),
                showsSkip: false,
                progress: nil
            )
            defer {
                if batch.isActive, batch.matches(recording: recording) {
                    let fileProgress = actions.isEmpty ? 1 : Double(actionOrdinal + 1) / Double(actions.count)
                    batch.updateProgress(stepName: stepName, stepProgress: 1, fileProgress: fileProgress)
                }
            }

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
                let base = ica.cleanedSignal ?? bcg.correctedSignal ?? gradient.correctedSignal ?? rawSignal
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
                let base = bcg.correctedSignal ?? gradient.correctedSignal ?? rawSignal
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

            case .waveletReduce:
                wavelet.apply(parameters: params)
                // Auto step: a review gate (Review-Each mode) is banner-only,
                // same convention as filter above.
                if action.gate == .review {
                    switch await replay.gate(.awaitingReview(index: action.stepIndex),
                        banner: .init(title: "Apply Wavelet Reduction?",
                                      detail: "\(wavelet.mode.rawValue) mode. Continue to apply.",
                                      showsSkip: true, progress: nil)) {
                    case .cancel: break loop
                    case .skip: continue loop
                    case .proceed: break
                    }
                }
                let base = ica.cleanedSignal ?? bcg.correctedSignal ?? gradient.correctedSignal ?? rawSignal
                let preArtifact = filter.output ?? base
                let processed = artifactVM.cleaningIsEnabled ? (artifactVM.cleanedSignal ?? preArtifact) : preArtifact
                await applyWaveletReduction(to: processed)

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

    /// Writes the processed recording after an interactive replay finishes (with
    /// a suffix based on the final output kind). Panel-free so Batch can call it
    /// per file. Uses renamed PNS without the synthetic-channel prompt.
    @MainActor
    func exportReplayResult(to folder: URL) async {
        guard let snapshot = currentMFFExportSnapshot() else { return }
        let base = (recording.packageName as NSString).deletingPathExtension
        let url = folder.appendingPathComponent("\(base)-\(snapshot.kind.replayOutputSuffix).mff")
        replay.banner = .init(title: "Exporting…", detail: url.lastPathComponent,
                              showsSkip: false, progress: nil)
        if batch.isActive, batch.matches(recording: recording) {
            batch.updateProgress(stepName: "Exporting", stepProgress: nil, fileProgress: 0.98)
        }
        let result = await performMFFExport(
            snapshot: snapshot,
            pnsForExport: pnsSignalWithRenames(),
            script: currentProcessingScript(),
            to: url,
            auditLogLines: currentProcessingAuditLogLines(),
            icaPayload: currentICAReplayPayload(),
            artifactPayload: currentArtifactReplayPayload()
        )
        if batch.isActive, batch.matches(recording: recording) {
            batch.updateProgress(stepName: "Exporting", stepProgress: 1, fileProgress: 1)
        }
        switch result {
        case .success(let out):
            filter.statusMessage = "Processed + exported \(out.lastPathComponent)."
            filter.statusIsError = false
            if batch.isActive, batch.matches(recording: recording) {
                batch.recordOutput(out)
            }
        case .failure(let error):
            filter.statusMessage = "Export failed: \(error.localizedDescription)"
            filter.statusIsError = true
        }
    }

    /// Top banner shown while an interactive replay is running or paused.
    @ViewBuilder
    func replayBanner() -> some View {
        if let info = replay.banner {
            let stepProgress = replayCurrentStepProgress(info: info)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    if replay.state.isAwaiting {
                        Image(systemName: "pause.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 32, height: 32)
                    } else {
                        CircularStepProgressIndicator(progress: stepProgress)
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

                if batch.isActive, let overall = replayBatchOverallProgress(stepProgress: stepProgress) {
                    VStack(alignment: .leading, spacing: 3) {
                        ProgressView(value: overall)
                            .progressViewStyle(.linear)
                        HStack {
                            Text("Overall \(Int((overall * 100).rounded()))%")
                            Spacer()
                            if let stepProgress {
                                Text("Current step \(Int((stepProgress * 100).rounded()))%")
                            }
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
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

    private func replayCurrentStepProgress(info: ReplayController.BannerInfo) -> Double? {
        if batch.isActive, batch.currentStepName == "Exporting" { return nil }
        if let progress = info.progress { return progress }
        guard let op = replayCurrentOperation() else { return nil }
        switch op {
        case .mriGradientCorrection:
            return gradient.progress
        case .filter:
            return filter.progress
        case .icaClean:
            return ica.isRunning ? ica.progress : nil
        case .waveletReduce:
            return wavelet.progress
        case .segment:
            return epoching.segmentingProgress
        case .thresholdArtifactDetection:
            return 1
        default:
            return nil
        }
    }

    private func replayCurrentOperation() -> EVAProcessingStep.Operation? {
        guard let index = replayCurrentStepIndex() else { return nil }
        return replay.steps.first { $0.id == index }?.step.operation
    }

    private func replayCurrentStepIndex() -> Int? {
        switch replay.state {
        case .running(let index), .awaitingReview(let index), .awaitingDecision(let index):
            return index
        default:
            return nil
        }
    }

    private func replayBatchOverallProgress(stepProgress: Double?) -> Double? {
        guard batch.isActive, batch.currentIndex >= 0, !batch.jobs.isEmpty else { return nil }
        let fileProgress = replayBatchCurrentFileProgress(stepProgress: stepProgress)
        return min(max((Double(batch.currentIndex) + fileProgress) / Double(batch.jobs.count), 0), 1)
    }

    private func replayBatchCurrentFileProgress(stepProgress: Double?) -> Double {
        if batch.currentStepName == "Exporting" {
            return batch.currentFileProgress
        }
        let actions = replay.plannedActions()
        guard !actions.isEmpty,
              let currentStep = replayCurrentStepIndex(),
              let position = actions.firstIndex(where: { $0.stepIndex == currentStep }) else {
            return batch.currentFileProgress
        }
        let progress = min(max(stepProgress ?? (replay.state.isAwaiting ? 1 : 0), 0), 1)
        return min(max((Double(position) + progress) / Double(actions.count), 0), 1)
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

/// A small "?" button that reveals an explanatory popover on click. Used instead
/// of `.help` tooltips, which do not reliably appear on non-control views.
struct InfoPopoverButton: View {
    let title: String
    let message: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 300)
        }
    }
}
