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
                // Two levels rather than one flat list: the tab is the decision
                // that actually changes the shape of the panel below it, and the
                // dropdown is the variant within that family.
                Picker("Family", selection: gradient.categoryBinding) {
                    ForEach(MRIGradientCategory.allCases) { category in
                        Text(category.rawValue).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // A retired method is not offered, but it is still shown while
                // it is the selection — a replay can load one, and a Picker
                // whose selection is absent from its content renders blank.
                Picker("Method", selection: $gradient.method) {
                    ForEach(gradient.selectableMethods) { method in
                        Text(method.isDeprecated ? "\(method.label) (retired)" : method.label)
                            .tag(method)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 200, alignment: .leading)

                if let note = gradient.method.deprecationNote {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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

            if gradient.method.usesDonorWindow {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Donor Volumes")
                        .font(.caption.weight(.semibold))
                    HStack {
                        TextField("Volumes", value: $gradient.donorVolumes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Stepper("", value: $gradient.donorVolumes, in: 1...128)
                            .labelsHidden()
                        Text("neighbouring volumes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help("How many neighbouring volumes contribute to each artifact template, in total. The methods take them from both sides of the target and keep reaching outward at the ends of the recording, so an early or late volume still gets a full set rather than half of one.")
                }
            }

            if gradient.method.supportsSliceEpochs {
                HStack {
                    Text("Slices / volume")
                        .font(.caption)
                        .frame(width: 96, alignment: .leading)
                    TextField("Slices", value: $gradient.slicesPerVolume, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Stepper("", value: $gradient.slicesPerVolume, in: 1...128)
                        .labelsHidden()
                }
                .help("Number of fMRI slices per volume. Each TR interval is split into this many equal slice epochs.")
            }

            let motionLoaded = (gradient.motionParameters?.count ?? 0) >= 2

            if gradient.method.usesMotion, motionLoaded {
                mriMotionSummary()
            }

            // Optional motion-censoring for every method except Moosmann, which
            // censors intrinsically, so the toggle is hidden there.
            if motionLoaded, !gradient.method.usesMotion {
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

            mriMethodOptions()

            mriAdvancedOptions()

            if !gradient.auditLogLines.isEmpty {
                DisclosureGroup(isExpanded: $gradient.showsRunDetails) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(gradient.auditLogLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                } label: {
                    Text("What the last run did")
                        .font(.caption.weight(.semibold))
                }
                .help("Epochs left uncorrected, donors turned away, and stages that stood down. These same lines are written into log_eva_<date>_<time>.txt when the recording is exported.")
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
                Button("Reset \(GradientViewModel.defaultDonorVolumes)") {
                    gradient.donorVolumes = GradientViewModel.defaultDonorVolumes
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
        return "Apply \(gradient.method.label) gradient artifact removal."
    }

    // MARK: - Small control rows

    /// Kept as small typed helpers rather than inline expressions: a popover
    /// with this many controls will otherwise blow the SwiftUI type-checker's
    /// budget, which is what "unable to type-check this expression in
    /// reasonable time" means when it appears here.
    func mriIntRow(
        _ title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        help: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .frame(width: 132, alignment: .leading)
            TextField(title, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
            Stepper("", value: value, in: range)
                .labelsHidden()
        }
        .help(help)
    }

    func mriDoubleRow(
        _ title: String,
        value: Binding<Double>,
        suffix: String = "",
        help: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .frame(width: 132, alignment: .leading)
            TextField(title, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
            if !suffix.isEmpty {
                Text(suffix)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help(help)
    }

    /// Motion source line for Moosmann, assembled outside the view body for the
    /// same type-checking reason.
    @ViewBuilder
    func mriMotionSummary() -> some View {
        let name = gradient.motionParameters?.sourceName ?? ""
        let volumes = gradient.motionParameters?.count ?? 0
        let metric = gradient.motionMetric.label.lowercased()
        let threshold = String(format: "%.2f", gradient.motionFDThreshold)
        Text("Using motion: \(name) (\(volumes) vols), \(metric) metric, threshold \(threshold) mm")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Per-method options

    @ViewBuilder
    func mriMethodOptions() -> some View {
        switch gradient.method.engine {
        case .sliceTemplate: mriSliceTemplateOptions()
        case .averageTemplate: mriAverageTemplateOptions()
        case .localTemplate: mriLocalTemplateOptions()
        }
    }

    @ViewBuilder
    func mriSliceTemplateOptions() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FASTR Options")
                .font(.caption.weight(.semibold))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Template scaling")
                        .font(.caption)
                    Button {
                        gradient.showsSafetyHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("About template scaling and EVA's signal-preservation guards")
                    .popover(isPresented: $gradient.showsSafetyHelp, arrowEdge: .trailing) {
                        mriSafetyHelp()
                    }
                }
                Picker("Template scaling", selection: $gradient.templateScaling) {
                    ForEach(GradientTemplateScaling.allCases) { scaling in
                        Text(scaling.label).tag(scaling)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 220, alignment: .leading)
            }

            Toggle("Epoch alignment", isOn: $gradient.alignmentEnabled)
                .font(.caption)
                .help("Search for a small per-epoch integer shift so triggers that do not land on the same sample of the artifact still average cleanly.")
            if gradient.alignmentEnabled {
                Toggle("Sub-sample alignment", isOn: $gradient.subSampleAlignment)
                    .font(.caption)
                    .help("Additionally estimate a fractional-sample offset per epoch and resample onto a shared sub-sample grid before averaging.")
            }

            HStack(spacing: 6) {
                Text("OBS residual removal")
                    .font(.caption)
                Picker("OBS", selection: $gradient.obsSelection) {
                    ForEach(GradientOBSSelection.allCases) { selection in
                        Text(selection.label).tag(selection)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }
            .help("Remove what template subtraction leaves behind by projecting each epoch onto an optimal basis set of the residuals.")
            if gradient.obsSelection == .fixed {
                mriIntRow(
                    "Components",
                    value: $gradient.obsFixedComponents,
                    range: 1...32,
                    help: "Remove exactly this many components per chunk."
                )
            }

            Toggle("Adaptive noise cancellation (ANC)", isOn: $gradient.ancEnabled)
                .font(.caption)
                .help("Adapt against the artifact estimate the epoch-wise stages removed and take out whatever of it is still present. Follows artifact that drifts continuously, which the epoch-wise stages cannot.")
            if gradient.ancEnabled {
                Toggle("Slice-rate ANC high-pass", isOn: $gradient.ancSliceHighPass)
                    .font(.caption)
                    .help("Derive the pre-filter cutoff from the epoch rate rather than using a fixed 2 Hz. Only differs when volumes are subdivided into slices.")
            }

            if gradient.obsSelection != .off || gradient.ancEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Template-only channels")
                        .font(.caption)
                    ChannelSetPickerView(
                        label: "Template-only channels",
                        selectedSetID: $gradient.templateOnlyChannelSetID,
                        channelCount: recording.signal?.numberOfChannels ?? 0
                    )
                    Text(gradient.templateOnlyChannelSetID == nil
                         ? "Every channel gets the full pipeline."
                         : "\(gradient.templateOnlyChannels.count) channels get template subtraction only.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help("These channels are still corrected, but skip OBS and ANC. Both stages model the residual — OBS pools epochs into a shared basis, ANC adapts against the artifact estimate — so a questionable channel distorts them for itself and, in OBS's case, is best kept out. Use Excluded Channels instead if a channel should not be corrected at all.")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Donor ranking")
                        .font(.caption)
                    Button {
                        gradient.showsDonorHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("About donor ranking")
                    .popover(isPresented: $gradient.showsDonorHelp, arrowEdge: .trailing) {
                        mriDonorHelp()
                    }
                }
                Picker("Donor ranking", selection: $gradient.donorRanking) {
                    ForEach(GradientDonorRanking.allCases) { ranking in
                        Text(ranking.label).tag(ranking)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(gradient.donorRanking.help)
            }
        }
    }

    @ViewBuilder
    func mriAverageTemplateOptions() -> some View {
        if gradient.method == .allenIAR {
            VStack(alignment: .leading, spacing: 8) {
                Text("Allen IAR Options")
                    .font(.caption.weight(.semibold))
                mriIntRow(
                    "Section epochs",
                    value: $gradient.allenSectionEpochs,
                    range: 0...400,
                    help: "How many epochs the running average template spans. Allen et al. use a fixed section rather than a window centred on the target. Leave at 0 to let the preset choose: the slice preset derives roughly 7.5 seconds of epochs from the epoch rate, which is far more than the volume preset's 25."
                )
                if gradient.allenSectionEpochs == 0 {
                    Text("0 = automatic, from the epoch rate.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                mriDoubleRow(
                    "Correlation gate",
                    value: $gradient.allenCorrelationGate,
                    help: "An epoch only updates the running template if it correlates with the current template at least this well. Keeps a disturbed epoch from contaminating everything after it."
                )
                mriIntRow(
                    "Always include first",
                    value: $gradient.allenInitialEpochs,
                    range: 0...64,
                    help: "Accept this many epochs at the start unconditionally, before there is a template stable enough to gate against."
                )
                Toggle("Adaptive noise cancellation (ANC)", isOn: $gradient.ancEnabled)
                    .font(.caption)
                    .help("Allen's method pairs template subtraction with adaptive noise cancellation; it is on by default for this preset.")
                if gradient.ancEnabled {
                    Toggle("Slice-rate ANC high-pass", isOn: $gradient.ancSliceHighPass)
                        .font(.caption)
                        .help("Derive the pre-filter cutoff from the epoch rate rather than using a fixed 2 Hz.")
                }
            }
        }
    }

    @ViewBuilder
    func mriLocalTemplateOptions() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(gradient.method.label) Options")
                .font(.caption.weight(.semibold))
            mriIntRow(
                "Min donor distance",
                value: $gradient.localMinimumDonorDistance,
                range: 0...100_000,
                help: "Samples a donor must be from the target before it may contribute. Keeps an artifact from helping to build the template that will be subtracted from it."
            )
            mriIntRow(
                "Min donor count",
                value: $gradient.localMinimumDonorCount,
                range: 1...64,
                help: "Fewest donors a usable template may be built from."
            )
            if gradient.method.weightsDonorsByDistance {
                mriDoubleRow(
                    "Weighting constant",
                    value: $gradient.localWeightingTimeConstantSeconds,
                    suffix: "s",
                    help: "Donors are weighted by exp(-distance / this). A donor this far from the target counts for 1/e of an adjacent one, so nearer artifacts dominate the template. Shorter tracks a changing artifact faster; longer averages more donors together."
                )
            }
            Toggle("Reject uncorrelated donors", isOn: $gradient.localRejectsUncorrelatedDonors)
                .font(.caption)
                .help("Nearness in time is a proxy for similarity, and usually a good one — but a donor interrupted by movement or a dropout is still a near neighbour. This compares each donor's waveform against the target's directly and drops the ones that do not match. Scored on the highest-variance channel, so every channel corrects with the same donor set.")
            if gradient.localRejectsUncorrelatedDonors {
                mriDoubleRow(
                    "Minimum donor r",
                    value: $gradient.localMinimumDonorCorrelation,
                    help: "Smallest Pearson correlation a donor must reach against the target. A target that no donor reaches is left uncorrected and reported, rather than having a template subtracted that does not describe it — so a floor set too high shows up as skipped events, not as silently worse output."
                )
            }
            Toggle("Skip targets with too few donors", isOn: $gradient.localSkipsTargetsWithoutEnoughDonors)
                .font(.caption)
                .help("On: an event without enough donors is left uncorrected and reported. Off: it is corrected with whatever donors are available.")
        }
    }

    // MARK: - Advanced

    @ViewBuilder
    func mriAdvancedOptions() -> some View {
        if gradient.method.isFASTR || gradient.method == .allenIAR {
            DisclosureGroup(isExpanded: $gradient.showsAdvanced) {
                VStack(alignment: .leading, spacing: 6) {
                    if gradient.method.isFASTR {
                        mriAdvancedAlignment()
                        Divider()
                        mriAdvancedScaling()
                        Divider()
                        if gradient.method == .farm || gradient.donorRanking == .squaredCorrelation {
                            mriAdvancedCorrelation()
                            Divider()
                        }
                        if gradient.obsSelection != .off {
                            mriAdvancedOBS()
                            Divider()
                        }
                    }
                    if gradient.ancEnabled {
                        mriAdvancedANC()
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Advanced")
                    .font(.caption.weight(.semibold))
            }
        }
    }

    @ViewBuilder
    func mriAdvancedAlignment() -> some View {
        mriIntRow(
            "Upsample factor",
            value: $gradient.upsampleFactor,
            range: 1...10,
            help: "Correct on an internally upsampled axis so epochs can be aligned on a finer grid than the recorded rate. What is downsampled afterwards is the artifact estimate, not the signal, so samples outside a corrected epoch are untouched at any factor."
        )
        mriDoubleRow(
            "Trigger position",
            value: $gradient.relativeTriggerPosition,
            help: "Where the trigger sits inside its artifact epoch, as a fraction of the epoch. 0 puts the whole window after the trigger."
        )
    }

    @ViewBuilder
    func mriAdvancedScaling() -> some View {
        mriIntRow(
            "Scale smoothing epochs",
            value: $gradient.templateScaleSmoothingEpochs,
            range: 1...201,
            help: "Epochs the drift-tracking median spans. Wider rejects more epoch-to-epoch scatter but takes longer to follow a real amplitude change."
        )
        mriDoubleRow(
            "Scale minimum",
            value: $gradient.templateScaleMinimum,
            help: "A fitted scale below this is treated as a failed fit rather than applied."
        )
        mriDoubleRow(
            "Scale maximum",
            value: $gradient.templateScaleMaximum,
            help: "A fitted scale above this is treated as a failed fit. A template needing 10x scaling to match its epoch did not describe that epoch."
        )
    }

    @ViewBuilder
    func mriAdvancedCorrelation() -> some View {
        mriDoubleRow(
            "Correlation threshold",
            value: $gradient.correlationThreshold,
            help: "Minimum correlation a candidate must reach to qualify as a donor. Too few qualifying candidates falls back to temporal neighbours for that epoch."
        )
        mriIntRow(
            "Min qualified donors",
            value: $gradient.minimumCorrelatedDonors,
            range: 1...64,
            help: "If fewer than this many candidates qualify, that epoch falls back to temporal neighbours."
        )
        mriIntRow(
            "Search window",
            value: $gradient.correlationSearchWindow,
            range: 1...5000,
            help: "How many same-slice epochs on each side of the target are considered. Bounds an otherwise quadratic search."
        )
    }

    @ViewBuilder
    func mriAdvancedOBS() -> some View {
        if gradient.obsSelection == .automatic {
            mriDoubleRow(
                "Variance threshold",
                value: $gradient.obsVarianceThreshold,
                help: "Share of residual variance the retained components must explain."
            )
            mriIntRow(
                "Max components",
                value: $gradient.obsMaximumComponents,
                range: 1...32,
                help: "Ceiling on automatic component selection."
            )
        }
        mriDoubleRow(
            "Chunk length",
            value: $gradient.obsChunkSeconds,
            suffix: "s",
            help: "Length of recording each basis is estimated over. The residual's shape drifts across a long scan, so one basis for the whole session fits none of it well."
        )
        mriIntRow(
            "Epochs per basis",
            value: $gradient.obsMaximumEpochsPerChunk,
            range: 8...1024,
            help: "Cap on epochs contributing to one basis. Raising this no longer costs much: only the leading components are ever computed."
        )
        mriDoubleRow(
            "Residual floor",
            value: $gradient.obsResidualEnergyFloor,
            help: "Minimum residual energy, as a fraction of what template subtraction already removed, for OBS to run on a chunk. This is the guard that stops OBS removing brain signal once the artifact is already gone — see the template scaling help."
        )
    }

    @ViewBuilder
    func mriAdvancedANC() -> some View {
        mriIntRow(
            "ANC filter length",
            value: $gradient.ancFilterLength,
            range: 1...512,
            help: "Adaptive filter taps."
        )
        mriDoubleRow(
            "ANC step size",
            value: $gradient.ancStepSize,
            help: "Normalized-LMS step. Stable below 2, but stability is not the only concern: a large step lets the weights chase sample-to-sample detail and start fitting brain signal that has nothing to do with the reference. The default is deliberately small."
        )
    }

    // MARK: - Help

    /// Explanation of the method choice with references.
    @ViewBuilder
    func mriMethodHelp() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Gradient Artifact Removal Methods")
                    .font(.headline)

                mriMethodEntry(
                    "Fast AAS — retired",
                    "Built one artifact template per TR by averaging neighbouring volumes. It existed to be the quick option; the other methods are now GPU-backed and faster, so it has been withdrawn from the picker. MAS is the nearer replacement. Files that already select it still reproduce."
                )
                mriMethodEntry(
                    "Allen AAS — Imaging Artifact Reduction",
                    "Allen et al.'s running-template variant: the template spans a fixed section of epochs rather than a window centred on the target, an epoch only updates it if it correlates well enough, and adaptive noise cancellation follows subtraction."
                )
                mriMethodEntry(
                    "MAS — Median Artifact Subtraction",
                    "Same per-TR template family, but the template is the elementwise median of a centred moving window, excluding ignored, outlier, and too-near donor volumes. The median resists a single contaminated donor in a way a mean does not."
                )
                mriMethodEntry(
                    "MAR — Median Artifact Regression",
                    "The MAS template, scaled by a least-squares fit before subtracting, so its amplitude can track slow artifact drift a fixed 1:1 subtraction cannot."
                )
                mriMethodEntry(
                    "wAAS / wAAR — distance-weighted templates",
                    "The same local-template family as MAS/MAR, but donors are weighted by how far they sit from the target rather than reduced with an unweighted median, so nearby artifacts dominate. wAAR additionally fits the template's amplitude by least squares before subtracting."
                )
                mriMethodEntry(
                    "FASTR Original — Slice Template Removal",
                    "Subdivides each volume into slice epochs, aligns them (optionally at sub-sample resolution), subtracts a per-slice template, then optionally removes residual artifact with an Optimal Basis Set and adaptive noise cancellation. Better suppression, more parameters."
                )
                mriMethodEntry(
                    "Moosmann — motion-informed averaging",
                    "A FASTR variant that builds each volume's template from motion-free neighbours, treating a high-motion volume as a wall rather than averaging across it. Requires a motion file. Falls back to temporal neighbours when no volume exceeds the threshold."
                )
                mriMethodEntry(
                    "FARM — most-correlated-epoch averaging",
                    "A FASTR variant whose template averages the most similar artifacts by waveform correlation rather than temporal neighbours."
                )

                Divider()

                VStack(alignment: .leading, spacing: 3) {
                    Text("Method references")
                        .font(.caption.weight(.semibold))
                    Text("• Allen, Josephs & Turner (2000). NeuroImage 12:230–239.")
                    Text("• Liu, de Zwart, van Gelderen, Kuo & Duyn (2012). NeuroImage 59(3):2073–2087.")
                    Text("• Niazy, Beckmann, Iannetti, Brady & Smith (2005). NeuroImage 28(3):720–737.")
                    Text("• Moosmann et al. (2009). NeuroImage 45(4):1144–1150.")
                    Text("• van der Meer et al. (2010). Clinical Neurophysiology 121(5):766–776.")
                    Text("• Glaser et al. (2013). BMC Neuroscience 14:138.")
                    Text("• Power et al. (2012). NeuroImage 59(3):2142–2154 (framewise displacement).")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Text("These are EVA's own implementations, written from the published method descriptions and EVA's functional specifications. The toolboxes associated with these papers are cited as historical and scientific references; their source code is not incorporated. See THIRD_PARTY_NOTICES.md.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(width: 380, height: 520)
    }

    @ViewBuilder
    func mriMethodEntry(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The three signal-preservation guards, which are EVA-specific and worth
    /// explaining where the user meets them.
    @ViewBuilder
    func mriSafetyHelp() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Template Scaling and Signal Preservation")
                    .font(.headline)

                mriMethodEntry(
                    "Why scaling is a trade-off",
                    "The scale is fitted from a single epoch-length window, and over a window that short a physiological rhythm is not orthogonal to the artifact. Part of the brain signal is absorbed into the fitted scale and subtracted along with the artifact."
                )
                mriMethodEntry(
                    "Drift-Tracking (default)",
                    "Fits a scale per epoch, then takes a running median across neighbouring epochs. An amplitude change that persists — what motion and hardware drift produce — survives the median and is tracked; epoch-to-epoch scatter does not. A median also passes a step change through sharply rather than ramping across it."
                )
                mriMethodEntry(
                    "Unscaled Average",
                    "Subtracts the donor average as-is. Cannot absorb correlated signal; cannot follow a changing artifact amplitude either. Note that a sustained amplitude change needs no scaling at all — once the donor window has moved past the transition, the donors already carry the new amplitude."
                )
                mriMethodEntry(
                    "Per-Epoch Least Squares",
                    "Uses each epoch's raw fit. Tracks any amplitude change immediately, including a single-epoch spike, at the cost of absorbing whatever signal correlates with the template in that window. This is the mode for a one-volume spike, which drift tracking rejects by design."
                )

                Divider()

                mriMethodEntry(
                    "OBS residual floor",
                    "Variance-explained component selection is scale-free: it removes whatever dominates the residual, and PCA cannot tell structured brain signal from structured artifact. Where template subtraction has already explained the artifact, the residual is the signal. The floor makes OBS stand down there rather than delete data."
                )
                mriMethodEntry(
                    "ANC step size",
                    "A short adaptive filter driven by a periodic reference cannot synthesize an unrelated frequency with fixed weights, but weights that adapt every sample can, because the weight trajectory itself carries the beat. The default step is deliberately small, trading convergence speed for a filter that tracks artifact drift and little else."
                )

                Text("Fitted scales outside the configured range are treated as failed fits rather than applied, and neighbouring epochs are used instead.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(width: 380, height: 480)
    }

    @ViewBuilder
    func mriDonorHelp() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Donor Ranking")
                .font(.headline)
            mriMethodEntry("Default", GradientDonorRanking.methodDefault.help)
            mriMethodEntry("Squared r", GradientDonorRanking.squaredCorrelation.help)
            Text("Squared ranking replaces the method's own donor rule and lets the target epoch contribute to its own template, which is why it is a separate choice rather than a modifier.")
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
