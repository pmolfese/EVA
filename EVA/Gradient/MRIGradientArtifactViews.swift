//
//  MRIGradientArtifactViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  MRI gradient artifact removal popover (AAS/FASTR/FARM/Moosmann) and its
//  supporting helpers, extracted from WaveformView.swift during the L5
//  view-decomposition refactor. This is an extension of WaveformView (not a
//  standalone type), following the same pattern as the other L5 slices — the
//  cluster reads/writes WaveformView's own stores (gradient, artifactVM,
//  filter, ica) and state, so this is a file split, not a state extraction.
//

import SwiftUI

extension WaveformView {
    // MARK: - MRI gradient artifact removal

    /// Volume-trigger sample indices from the raw recording (events whose code
    /// matches `code`), used as the TR grid for gradient correction.
    func trMarkerSamples(in signal: MFFSignalData, code: String, samplingRate: Double? = nil) -> [Int] {
        let rate = samplingRate ?? signal.samplingRate
        return signal.events
            .filter { $0.code == code }
            .map { Int(($0.beginTimeSeconds * rate).rounded()) }
            .sorted()
    }

    /// Distinct event codes in the recording with their occurrence counts,
    /// sorted by descending count then code.
    func eventCodeCounts(in signal: MFFSignalData) -> [(code: String, count: Int)] {
        var counts: [String: Int] = [:]
        for event in signal.events {
            counts[event.code, default: 0] += 1
        }
        return counts
            .map { (code: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.code < $1.code }
    }

    @ViewBuilder
    func mriPopover(for signal: MFFSignalData?) -> some View {
        let codeCounts = signal.map(eventCodeCounts) ?? []
        let selectedCount = codeCounts.first { $0.code == gradient.trMarkerCode }?.count
        let motionUsable = (gradient.motionParameters?.count ?? 0) >= 2
        let motionAlignmentOK = mriMotionAlignmentOK(selectedCount: selectedCount)
        let spacing = trSpacingInfo(for: signal)
        let canApply = signal != nil && !gradient.isProcessing && (selectedCount ?? 0) >= 2
            && (gradient.method != .moosmann || motionUsable)
            && motionAlignmentOK
            && spacing.hasEnoughTriggers && spacing.isEvenlySpaced

        VStack(alignment: .leading, spacing: 14) {
            Text("MR Gradient Removal")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Method")
                        .font(.caption.weight(.semibold))
                    Button {
                        gradient.showsMethodHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("About AAS vs FASTR and references")
                    .popover(isPresented: $gradient.showsMethodHelp, arrowEdge: .trailing) {
                        mriMethodHelp()
                    }
                }
                Picker("Method", selection: $gradient.method) {
                    ForEach(MRIGradientMethod.allCases) { method in
                        Text(method.label).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("TR Marker Event")
                    .font(.caption.weight(.semibold))
                if codeCounts.isEmpty {
                    Text("No events found in this recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("TR Marker Event", selection: $gradient.trMarkerCode) {
                                ForEach(codeCounts, id: \.code) { entry in
                                    Text("\(entry.code)  (\(entry.count))").tag(entry.code)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 150, alignment: .leading)
                            if let selectedCount {
                                Text("\(trimmedMarkerCount(total: selectedCount)) of \(selectedCount) \(gradient.trMarkerCode) markers used.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("No \(gradient.trMarkerCode) markers in this recording.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }

                        Spacer(minLength: 0)

                        VStack(alignment: .leading, spacing: 6) {
                            mriSkipControl(
                                title: "Skip First",
                                value: $gradient.skipStart,
                                totalMarkers: selectedCount,
                                otherSkip: gradient.skipEnd
                            )
                            mriSkipControl(
                                title: "Skip Last",
                                value: $gradient.skipEnd,
                                totalMarkers: selectedCount,
                                otherSkip: gradient.skipStart
                            )
                        }
                    }

                    if let selectedCount, selectedCount > 0 {
                        mriTRSpacingStatus(spacing: spacing, totalMarkers: selectedCount)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Template Window (neighboring TRs)")
                    .font(.caption.weight(.semibold))
                HStack {
                    Text("Pre")
                        .font(.caption)
                        .frame(width: 36, alignment: .leading)
                    TextField("Pre", value: $gradient.windowBefore, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Stepper("", value: $gradient.windowBefore, in: 1...64)
                        .labelsHidden()
                }
                HStack {
                    Text("Post")
                        .font(.caption)
                        .frame(width: 36, alignment: .leading)
                    TextField("Post", value: $gradient.windowAfter, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Stepper("", value: $gradient.windowAfter, in: 1...64)
                        .labelsHidden()
                }
            }

            let motionLoaded = (gradient.motionParameters?.count ?? 0) >= 2

            if gradient.method == .moosmann, motionLoaded {
                Text("Using motion: \(gradient.motionParameters?.sourceName ?? "") (\(gradient.motionParameters?.count ?? 0) vols), \(gradient.moosmannMotionMetric.label.lowercased()) metric, threshold \(String(format: "%.2f", gradient.motionFDThreshold)) mm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Optional motion-censoring for AAS/FASTR/FARM (Moosmann censors
            // intrinsically, so the toggle is hidden there).
            if motionLoaded, gradient.method != .moosmann {
                Toggle(isOn: $gradient.excludeHighMotion) {
                    Text("Exclude high-motion TRs")
                        .font(.caption)
                }
                .help("High-motion volumes (FD over the threshold set in Configure Motion…) are still corrected, but are not used as donors when building artifact templates.")
            }

            if recording.pnsSignal != nil {
                Toggle("Apply to PNS channels", isOn: $gradient.appliesToPNS)
                    .font(.caption)
                    .help("Apply the selected MRI gradient artifact correction to physio/PNS channels using the same TR markers.")
            }

            if gradient.method == .mas || gradient.method == .mar {
                Toggle("Use Metal GPU", isOn: $gradient.fastrUseMetal)
                    .font(.caption)
                    .disabled(!GradientRemoverMetalBackend.isAvailable)
                    .help(GradientRemoverMetalBackend.isAvailable
                          ? "Build median artifact templates and perform subtraction or regression on the GPU. Donor and outlier selection remain on the CPU."
                          : "No compatible Metal GPU is available; correction will use the CPU.")
            }

            if gradient.method.isFASTR {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("FASTR Options")
                            .font(.caption.weight(.semibold))
                        Button {
                            gradient.showsFastrOptionsHelp = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .buttonStyle(.plain)
                        .help("About FASTR options")
                        .popover(isPresented: $gradient.showsFastrOptionsHelp, arrowEdge: .trailing) {
                            mriFastrOptionsHelp()
                        }
                    }
                    HStack {
                        Text("Slices / volume")
                            .font(.caption)
                            .frame(width: 96, alignment: .leading)
                        TextField("Slices", value: $gradient.fastrSlices, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Stepper("", value: $gradient.fastrSlices, in: 1...128)
                            .labelsHidden()
                    }
                    .help("Number of fMRI slices per volume. Each TR interval is split into this many slice epochs.")
                    Toggle("Use Metal GPU", isOn: $gradient.fastrUseMetal)
                        .font(.caption)
                        .disabled(!FastrCorrector.isMetalAvailable)
                        .help(FastrCorrector.isMetalAvailable
                              ? "Run interpolation, template scaling and subtraction, OBS fitting, and decimation on the GPU. Alignment, OBS PCA, donor selection, and ANC remain on the CPU."
                              : "No compatible Metal GPU is available; FASTR will use the CPU.")
                    Toggle("Sub-sample alignment", isOn: $gradient.fastrSubSample)
                        .font(.caption)
                        .help("FACET-style fractional-sample epoch alignment.")
                    Toggle("FACET 30-artifact window", isOn: $gradient.fastrUseFacetWindow)
                        .font(.caption)
                        .help("Use FACET's AvgWindow=30 donor rows with border saturation instead of EVA's Pre/Post template window.")
                    Toggle("OBS residual removal (auto PCs)", isOn: $gradient.fastrOBSAuto)
                        .font(.caption)
                        .help("Remove residual artifact via an optimal basis set of residual PCs.")
                    if gradient.fastrOBSAuto {
                        HStack(spacing: 6) {
                            Toggle("Random OBS epoch sampling", isOn: $gradient.fastrOBSRandomSampling)
                                .font(.caption)
                                .help("Use FACET's random 2/3 epoch subset when building the OBS PCA matrix. Leave off for reproducible EVA runs.")
                            Button {
                                gradient.showsOBSRandomHelp = true
                            } label: {
                                Image(systemName: "questionmark.circle")
                            }
                            .buttonStyle(.plain)
                            .help("About random OBS epoch sampling")
                            .popover(isPresented: $gradient.showsOBSRandomHelp, arrowEdge: .trailing) {
                                mriOBSRandomHelp()
                            }
                        }
                        HStack(spacing: 6) {
                            Text("OBS chunk")
                                .font(.caption)
                                .frame(width: 96, alignment: .leading)
                            TextField("Seconds", value: $gradient.fastrOBSChunkSeconds, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Text("s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .help("PCA for the optimal basis set is recomputed independently every this many seconds of the recording, matching FASTR's reference implementation (Niazy et al., 2005). Shorter chunks adapt faster to changing artifact shape but use fewer epochs per PCA fit; longer chunks average over more data but assume the artifact stays stable throughout. Default: 60s.")
                    }
                    Toggle("Adaptive noise cancellation (ANC)", isOn: $gradient.fastrANC)
                        .font(.caption)
                        .help("Apply LMS adaptive noise cancellation after template subtraction.")
                    if gradient.fastrANC {
                        HStack(spacing: 6) {
                            Toggle("Slice-rate ANC high-pass", isOn: $gradient.fastrANCSliceHighPass)
                                .font(.caption)
                                .help("Use FACET's 0.75×slice-trigger-rate high-pass for slice-triggered FASTR. Off keeps EVA/FMRIB's fixed 2 Hz cutoff.")
                            Button {
                                gradient.showsANCHighPassHelp = true
                            } label: {
                                Image(systemName: "questionmark.circle")
                            }
                            .buttonStyle(.plain)
                            .help("About ANC high-pass mode")
                            .popover(isPresented: $gradient.showsANCHighPassHelp, arrowEdge: .trailing) {
                                mriANCHighPassHelp()
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("Donor selection")
                                .font(.caption.weight(.semibold))
                            Button {
                                gradient.showsFastrDonorHelp = true
                            } label: {
                                Image(systemName: "questionmark.circle")
                            }
                            .buttonStyle(.plain)
                            .help("About FASTR-family donor selection")
                            .popover(isPresented: $gradient.showsFastrDonorHelp, arrowEdge: .trailing) {
                                mriFastrDonorHelp()
                            }
                        }
                        Picker("Donor selection", selection: $gradient.fastrDonorSelection) {
                            ForEach(FastrDonorSelection.allCases) { selection in
                                Text(selection.label).tag(selection)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .help(gradient.fastrDonorSelection.help)
                    }
                }
            }

            Divider()

            Button {
                gradient.showsPopover = false
                gradient.showsMotionConfig = true
            } label: {
                Label(gradient.motionParameters == nil
                      ? "Configure Motion…"
                      : "Motion: \(gradient.motionParameters?.sourceName ?? "") (\(gradient.motionParameters?.count ?? 0) TRs)…",
                      systemImage: "slider.horizontal.3")
            }
            .help("Load AFNI or BERGEN/SPM motion parameters, plot head motion, and set a motion threshold.")

            if let motion = gradient.motionParameters {
                mriMotionAlignmentStatus(motion: motion, selectedCount: selectedCount)
            }

            HStack {
                Button("Reset 4 / 4") {
                    gradient.windowBefore = GradientRemover.Window.default.before
                    gradient.windowAfter = GradientRemover.Window.default.after
                }

                if gradient.correctedSignal != nil {
                    Button("Restore Original", role: .destructive) {
                        clearGradientCorrection()
                        gradient.showsPopover = false
                    }
                }

                Spacer()

                Button("Apply") {
                    gradient.showsPopover = false
                    if replay.state.isAwaitingReview {
                        // During replay the loop applies after the gate resolves.
                        replay.resume(.proceed)
                    } else {
                        gradientTask?.cancel()
                        let sessionID = recordingSessionID
                        gradientTask = Task {
                            await applyGradientCorrection(to: signal)
                            if !Task.isCancelled, sessionID == recordingSessionID {
                                gradientTask = nil
                            }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
                .help(applyButtonHelp(motionUsable: motionUsable, selectedCount: selectedCount, spacing: spacing, motionAlignmentOK: motionAlignmentOK))
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            // Default to TREV when present; otherwise fall back to the most
            // common event code so the picker always shows a valid selection.
            if !codeCounts.contains(where: { $0.code == gradient.trMarkerCode }) {
                if codeCounts.contains(where: { $0.code == "TREV" }) {
                    gradient.trMarkerCode = "TREV"
                } else if let first = codeCounts.first {
                    gradient.trMarkerCode = first.code
                }
            }
            clampMRITrims(totalMarkers: codeCounts.first { $0.code == gradient.trMarkerCode }?.count)
        }
        .onChange(of: gradient.trMarkerCode) { _, newCode in
            clampMRITrims(totalMarkers: codeCounts.first { $0.code == newCode }?.count)
        }
    }

    func clampMRITrims(totalMarkers: Int?) {
        let maximumCombinedSkip = max(0, (totalMarkers ?? 0) - 2)
        let clampedStart = min(max(gradient.skipStart, 0), maximumCombinedSkip)
        let clampedEnd = min(max(gradient.skipEnd, 0), maximumCombinedSkip - clampedStart)
        if gradient.skipStart != clampedStart {
            gradient.skipStart = clampedStart
        }
        if gradient.skipEnd != clampedEnd {
            gradient.skipEnd = clampedEnd
        }
    }

    func mriSkipControl(
        title: String,
        value: Binding<Int>,
        totalMarkers: Int?,
        otherSkip: Int
    ) -> some View {
        let maximum = max(0, (totalMarkers ?? 0) - otherSkip - 2)
        let clampedValue = Binding<Int>(
            get: { min(max(value.wrappedValue, 0), maximum) },
            set: { newValue in
                let clamped = min(max(newValue, 0), maximum)
                guard value.wrappedValue != clamped else { return }
                value.wrappedValue = clamped
            }
        )

        return HStack(spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)
            TextField("", value: clampedValue, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
            Stepper("", value: clampedValue, in: 0...maximum)
                .labelsHidden()
        }
        .help("Trim \(title.lowercased()) \(gradient.trMarkerCode) markers before running AAS/FASTR correction.")
    }

    func trimmedMarkerCount(total: Int) -> Int {
        max(total - gradient.skipStart - gradient.skipEnd, 0)
    }

    func mriMotionAlignmentOK(selectedCount: Int?) -> Bool {
        guard let motion = gradient.motionParameters else { return true }
        guard let selectedCount else { return false }
        return trimmedMarkerCount(total: selectedCount) == motion.count
    }

    @ViewBuilder
    func mriMotionAlignmentStatus(motion: MotionParameters, selectedCount: Int?) -> some View {
        let usedCount = selectedCount.map(trimmedMarkerCount(total:)) ?? 0
        let matches = selectedCount != nil && usedCount == motion.count
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: matches ? "checkmark.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(matches ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(matches
                     ? "Motion file matches \(usedCount) \(gradient.trMarkerCode) TRs."
                     : "Motion file has \(motion.count) TRs; current \(gradient.trMarkerCode) selection uses \(usedCount).")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(matches ? Color.secondary : Color.orange)

                Text(matches
                     ? "\(motion.sourceName), \(motion.format.label), FD threshold \(String(format: "%.2f", gradient.motionFDThreshold)) mm."
                     : "Adjust Skip First/Last, choose the matching TR marker event, or clear the motion file before applying.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    func mriTRSpacingStatus(spacing: TRSpacingInfo, totalMarkers: Int) -> some View {
        let usedCount = trimmedMarkerCount(total: totalMarkers)
        HStack(spacing: 6) {
            Image(systemName: spacing.isEvenlySpaced ? "checkmark.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(spacing.isEvenlySpaced ? Color.secondary : Color.orange)
            if spacing.hasEnoughTriggers {
                Text(spacing.isEvenlySpaced
                     ? "Fixed TR \(String(format: "%.3f", spacing.modeSeconds)) s after trim."
                     : "TRs uneven after trim; correction is disabled.")
            } else {
                Text("Need at least 2 markers after trim; currently using \(usedCount).")
            }
        }
        .font(.caption2)
        .foregroundStyle(spacing.isEvenlySpaced ? Color.secondary : Color.orange)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// TR markers after trimming `gradient.skipStart` events from the start and
    /// `gradient.skipEnd` from the end (to align the EEG's TREV events to the motion
    /// file). Returns [] if the skips would leave nothing.
    func trimmedTRMarkers(in signal: MFFSignalData, code: String, samplingRate: Double? = nil) -> [Int] {
        let all = trMarkerSamples(in: signal, code: code, samplingRate: samplingRate)
        guard all.count > gradient.skipStart + gradient.skipEnd else { return [] }
        return Array(all[gradient.skipStart..<(all.count - gradient.skipEnd)])
    }

    func trSpacingInfo(for signal: MFFSignalData?) -> TRSpacingInfo {
        guard let signal else {
            return TRSpacingInfo.from(triggerSamples: [], samplingRate: 0)
        }
        return TRSpacingInfo.from(
            triggerSamples: trimmedTRMarkers(in: signal, code: gradient.trMarkerCode),
            samplingRate: signal.samplingRate
        )
    }

    /// Awaitable dispatcher shared by the interactive Apply button (wrapped in
    /// a Task) and the replay coordinator (awaited) — one code path, via
    /// `GradientViewModel.apply(to:pnsSignal:onApplied:)`. This wrapper's job
    /// is just the interactive-only session guard: `gradient` (and `filter`/
    /// `ica`, whose caches it invalidates) can outlive a single run — a
    /// same-window "Close Recording" while a correction Task is still in
    /// flight, without a full view teardown — so the CROSS-domain
    /// invalidation is gated on `recordingSessionID`. Writes `apply` itself
    /// makes to its own VM are safe unconditionally (see
    /// `GradientViewModel.apply`'s doc comment).
    func applyGradientCorrection(to signal: MFFSignalData?) async {
        guard let signal else { return }
        let sessionID = recordingSessionID
        let pnsInput = gradient.appliesToPNS ? recording.pnsSignal : nil
        await processingQueue.run("Gradient Correction") { [self] in
            await gradient.apply(to: signal, pnsSignal: pnsInput) { [self] in
                guard sessionID == recordingSessionID else { return }
                // The base signal changed, so any ICA/band-pass output
                // computed on the old base is now stale.
                ica.cleanedSignal = nil
                ica.decomposition = nil
                filter.output = nil
                filter.pnsOutput = nil
                filter.pnsInputSignalType = nil
                clearAppliedArtifactCleaning()
                artifactVM.detectionRefreshToken += 1
                invalidateEpochsForSignalChange()
                invalidateInterpolations()
            }
        }
    }

    /// Tooltip for the Apply button explaining why it may be disabled.
    func applyButtonHelp(motionUsable: Bool, selectedCount: Int?, spacing: TRSpacingInfo, motionAlignmentOK: Bool) -> String {
        if (selectedCount ?? 0) < 2 {
            return "Select a TR marker event with at least two markers to enable Apply."
        }
        if !spacing.hasEnoughTriggers {
            return "Too few TR markers after trimming to run correction."
        }
        if !spacing.isEvenlySpaced {
            return "TRs are not evenly spaced"
        }
        if !motionAlignmentOK, let motion = gradient.motionParameters, let selectedCount {
            return "Motion file has \(motion.count) TRs, but \(trimmedMarkerCount(total: selectedCount)) \(gradient.trMarkerCode) markers are selected after trimming."
        }
        if gradient.method == .moosmann, !motionUsable {
            return "Moosmann requires a motion file. Load one via Configure Motion… to enable Apply."
        }
        return "Apply \(gradient.method.rawValue) gradient artifact removal."
    }

    /// Explanation of the AAS vs FASTR choice with references.
    @ViewBuilder
    func mriMethodHelp() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gradient Artifact Removal Methods")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("AAS — Average Artifact Subtraction")
                    .font(.subheadline.weight(.semibold))
                Text("Builds one artifact template per TR by averaging neighboring volumes and subtracts it. Fast and robust when motion is low. This is EVA's per-TR template method (Allen et al. 2000).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("MAS — Median Artifact Subtraction")
                    .font(.subheadline.weight(.semibold))
                Text("Same per-TR template family as AAS, but the template is the elementwise median of an AMRI-style centered moving window, excluding ignored, outlier, and too-near donor volumes. Inspired by the AMRI (Advanced MRI, NINDS/NIH) MATLAB toolbox's `amri_eeg_gac.m`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("MAR — Median Artifact Regression")
                    .font(.subheadline.weight(.semibold))
                Text("The AMRI-style MAS template, scaled by a least-squares fit before subtracting, so its amplitude can track slow gradient-artifact drift a fixed 1:1 subtraction can't. Inspired by `amri_eeg_gac.m`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("FASTR — fMRI Artifact Slice Template Removal")
                    .font(.subheadline.weight(.semibold))
                Text("Subdivides each volume into slice epochs, aligns them (optionally at sub-sample resolution), subtracts a per-slice template, then removes residual artifact with an Optimal Basis Set (OBS) and optional adaptive noise cancellation (ANC). Better suppression, more parameters (Niazy et al. 2005).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Moosmann — RP-informed averaging")
                    .font(.subheadline.weight(.semibold))
                Text("A FASTR variant (Bergen toolbox) that builds each volume's template from a motion-warped temporal window of low-motion volumes — excluding high-motion volumes and avoiding averaging across head-movement events. The default RP-info metric is BERGEN's translation-only motion; Motion Configuration can include all six parameters. Falls back to a plain moving average when no motion exceeds the threshold.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("FARM — most-correlated-epoch averaging")
                    .font(.subheadline.weight(.semibold))
                Text("A FASTR variant whose template, for each artifact, averages the most similar artifacts (highest waveform correlation, ≥ 0.9) rather than temporal neighbors. The BERGEN r² option switches FASTR-family donor ranking to squared correlation with self eligible, matching BERGEN's best-rsquare helper more closely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("References")
                    .font(.caption.weight(.semibold))
                Text("• Allen, Josephs & Turner (2000). NeuroImage 12:230–239.")
                Text("• Liu, de Zwart, van Gelderen, Kuo & Duyn (2012). NeuroImage 59(3):2073–2087 (MAS/MAR; AMRI toolbox, https://amri.ninds.nih.gov/software.html).")
                Text("• Niazy, Beckmann, Iannetti, Brady & Smith (2005). NeuroImage 28(3):720–737.")
                Text("• Moosmann et al. (2009). NeuroImage 45(4):1144–1150.")
                Text("• van der Meer et al. (2010). NeuroImage 49(3):2495–2505.")
                Text("• Glaser et al. (2013). FACET toolbox. BMC Neuroscience 14:138.")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text("EVA's FASTR is a port of the FMRIB/FACET implementations. See the in-app TODO for pending MATLAB-reference validation.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360)
    }

    @ViewBuilder
    func mriFastrOptionsHelp() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FASTR Options")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("AutoPreTrig")
                    .font(.subheadline.weight(.semibold))
                Text("FACET can re-estimate the artifact window's pre-trigger length by comparing the first two aligned artifacts near the first trigger and choosing the onset that minimizes their mismatch. It helps when scanner triggers are slightly inside the artifact rather than at a fixed relative position. EVA currently uses the relative trigger position plus alignment, not this onset-search step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("OBS Sampling")
                    .font(.subheadline.weight(.semibold))
                Text("OBS builds PCA components from a subset of residual artifact epochs. EVA's default subset is deterministic for reproducible replay. Random sampling follows FACET's rand-driven 2/3-step selection, which can slightly change the fitted residual basis between runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("ANC High-Pass")
                    .font(.subheadline.weight(.semibold))
                Text("ANC high-passes the signal before LMS adaptive filtering. The fixed 2 Hz cutoff matches EVA's current behavior and FACET's volume-trigger path. Slice-rate mode uses FACET's slice-trigger rule: 0.75 times the estimated trigger count per second, only when volumes are subdivided into slices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("FACET Window")
                    .font(.subheadline.weight(.semibold))
                Text("The FACET 30-artifact window uses FACET's AvgWindow/HalfWindow donor rows, including edge saturation and odd/even slice rows. Leave it off to use EVA's explicit Pre/Post template window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    @ViewBuilder
    func mriOBSRandomHelp() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Random OBS Sampling")
                .font(.headline)
            Text("FACET chooses OBS PCA epochs using random 2/3-step jumps through the artifact list. EVA leaves this off by default so repeated runs are exactly reproducible; turning it on is closer to FACET and may slightly change the residual basis each run.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder
    func mriANCHighPassHelp() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ANC High-Pass")
                .font(.headline)
            Text("Off keeps the current EVA/FMRIB behavior: a fixed 2 Hz high-pass before LMS ANC. On uses FACET's slice-trigger path: estimate the trigger count in the first second and use 0.75 times that rate. It only differs when FASTR is running with slice subdivision.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder
    func mriFastrDonorHelp() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FASTR Donor Selection")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Default")
                    .font(.subheadline.weight(.semibold))
                Text("Uses the selected method's donor rule: FASTR averages temporal pre/post neighbors, FARM chooses high-correlation epochs, and Moosmann uses BERGEN-style RP-informed low-motion donors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("BERGEN r²")
                    .font(.subheadline.weight(.semibold))
                Text("Uses BERGEN's best-rsquare donor ranking inside EVA's FASTR-family pipeline: candidates are scored by squared waveform correlation, with the target artifact eligible as a donor. FASTR/FARM rank same-slice candidates; Moosmann ranks within its RP-informed candidate pool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("This is the light BERGEN port. EVA does not yet support the full BERGEN generic matrix assignment workflow, where an arbitrary row-normalized weighting matrix directly controls every artifact's template donors.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 340)
    }

    func clearGradientCorrection() {
        gradient.correctedSignal = nil
        gradient.correctedPNSSignal = nil
        ica.cleanedSignal = nil
        ica.decomposition = nil
        filter.output = nil
        filter.pnsOutput = nil
        filter.pnsInputSignalType = nil
        clearAppliedArtifactCleaning()
        gradient.statusMessage = "Removed MRI gradient correction."
        gradient.statusIsError = false
        artifactVM.detectionRefreshToken += 1
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
    }
}
