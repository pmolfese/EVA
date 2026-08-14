//
//  PSAEpochingViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  PSA (post-stimulus average) epoching sheet and its supporting helpers,
//  extracted from WaveformView.swift during the L5 view-decomposition refactor.
//  This is an extension of WaveformView (not a standalone type), following the
//  same pattern as ECGDetectionViews.swift / BCGDetectionViews.swift — the
//  cluster reads/writes WaveformView's own stores (epoching, artifactVM,
//  template) and state, so this is a file split, not a state extraction.
//

import SwiftUI

extension WaveformView {
    // MARK: - PSA epoching

    func openPSASheet(for signal: MFFSignalData) {
        reconcilePSADefinedArtifactRejectionSelections()
        let events = segmentableEvents(for: signal)
        reconcilePSAEventSelection(for: events)
        epoching.statusMessage = nil
        epoching.showsSheet = true
    }

    func reconcilePSAEventSelection(for events: [MFFEvent]) {
        let summaries = groupedPSAEventSummaries(events)
        let availableValues = Set(summaries.map(\.code))
        epoching.selectedEventCodes = epoching.selectedEventCodes.intersection(availableValues)
        for summary in summaries where epoching.categoryNames[summary.code] == nil {
            epoching.categoryNames[summary.code] = summary.code
        }
        epoching.categoryGroups = epoching.categoryGroups.compactMapValues { members -> Set<String>? in
            let stillAvailable = members.intersection(availableValues)
            return stillAvailable.count >= 2 ? stillAvailable : nil
        }
        epoching.categoryRegexRules = epoching.categoryRegexRules.filter { availableValues.contains($0.value.sourceCode) }
        var enabledTimingValues = epoching.timingMarkerEnabledValues.intersection(availableValues)
        var timingMarkerValues = epoching.timingMarkerValuesBySegmentValue.filter { segmentValue, timingValue in
            availableValues.contains(segmentValue)
                && availableValues.contains(timingValue)
                && segmentValue != timingValue
        }
        var timingValuesWithoutOptions = Set<String>()
        for segmentValue in enabledTimingValues {
            let options = psaTimingMarkerOptions(in: summaries, excluding: segmentValue)
            if let currentValue = timingMarkerValues[segmentValue],
               options.contains(where: { $0.code == currentValue }) {
                continue
            }
            if let defaultValue = options.first?.code {
                timingMarkerValues[segmentValue] = defaultValue
            } else {
                timingValuesWithoutOptions.insert(segmentValue)
                timingMarkerValues[segmentValue] = nil
            }
        }
        enabledTimingValues.subtract(timingValuesWithoutOptions)
        epoching.timingMarkerEnabledValues = enabledTimingValues
        epoching.timingMarkerValuesBySegmentValue = timingMarkerValues
    }

    func segmentableEvents(for signal: MFFSignalData) -> [MFFEvent] {
        switch epoching.segmentField {
        case .artifact:
            return artifactVM.events.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        case .code, .label:
            return (signal.events + userMarkerEvents).sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        }
    }

    func psaSheet(for signal: MFFSignalData) -> some View {
        let events = segmentableEvents(for: signal)
        let allSummaries = groupedPSAEventSummaries(events)
        let summaries = filteredPSAEventSummaries(allSummaries)
        let segmentFieldBinding = Binding<PSASegmentField>(
            get: { epoching.segmentField },
            set: { newField in
                epoching.segmentField = newField
                reconcilePSAEventSelection(for: events)
            }
        )

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("PSA Segmentation")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(events.count) available events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Segment On")
                    .font(.caption.weight(.semibold))
                    .fixedSize()

                Spacer(minLength: 10)

                Picker("Segment On", selection: segmentFieldBinding) {
                    ForEach(PSASegmentField.allCases) { field in
                        Text(field.rawValue).tag(field)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)

                Spacer(minLength: 12)

                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter events", text: $epoching.eventSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                if !epoching.eventSearchText.isEmpty {
                    Button {
                        epoching.eventSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear filter")
                }

                Spacer(minLength: 10)

                Button {
                    categoryGroupMode = .codes
                    categoryGroupSelectedCodes.removeAll()
                    categoryGroupName = ""
                    categoryRegexSourceCode = ""
                    categoryRegexPattern = ""
                    showsCategoryGroupPopover = true
                } label: {
                    Label("Group…", systemImage: "plus.circle")
                }
                .disabled(allSummaries.isEmpty)
                .help("Combine several event codes/labels into one pooled category, or sub-select one code's events by a regex on their description.")
                .popover(isPresented: binding(recordingStore.events, \.showsCategoryGroupPopover)) {
                    categoryGroupPopover(events: events, allSummaries: allSummaries)
                }
            }

            // Master/detail: the event list (left) grows to fill the sheet's
            // height, while the run parameters and options sit in a fixed-width
            // column on the right. The whole sheet is resizable (see the frame
            // at the end), so dragging it taller gives the list more rows.
            HStack(alignment: .top, spacing: 16) {
                if allSummaries.isEmpty {
                    ContentUnavailableView(
                        epoching.segmentField == .artifact ? "No Artifacts Detected" : "No Events",
                        systemImage: epoching.segmentField == .artifact ? "waveform.path.ecg.rectangle" : "list.bullet.rectangle",
                        description: Text(epoching.segmentField == .artifact
                            ? "Enable eye blink, eye movement, or ECG/QRS detection in the Artifacts panel first."
                            : "This recording has no events to segment on.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                } else if summaries.isEmpty {
                    ContentUnavailableView(
                        "No Matches",
                        systemImage: "magnifyingglass",
                        description: Text("No artifact types match the filter.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(summaries) { summary in
                                psaSegmentEventRow(summary: summary, allSummaries: allSummaries)
                            }
                            if !epoching.categoryGroups.isEmpty {
                                Divider().padding(.vertical, 2)
                                ForEach(epoching.categoryGroups.keys.sorted(), id: \.self) { groupName in
                                    psaCategoryGroupRow(groupName: groupName, allSummaries: allSummaries)
                                }
                            }
                            if !epoching.categoryRegexRules.isEmpty {
                                Divider().padding(.vertical, 2)
                                ForEach(epoching.categoryRegexRules.keys.sorted(), id: \.self) { ruleID in
                                    psaCategoryRegexRuleRow(ruleID: ruleID, events: events)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                Text("Pre-stimulus (s)")
                                    .font(.caption.weight(.semibold))
                                TextField("Pre", value: $epoching.preStimulus, format: .number.precision(.fractionLength(3)))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                            }
                            GridRow {
                                Text("Post-stimulus (s)")
                                    .font(.caption.weight(.semibold))
                                TextField("Post", value: $epoching.postStimulus, format: .number.precision(.fractionLength(3)))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                            }
                            GridRow {
                                Text("Offset (s)")
                                    .font(.caption.weight(.semibold))
                                TextField("Offset", value: $epoching.offset, format: .number.precision(.fractionLength(3)))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                                    .help("Ignored for categories that use a DIN timing marker.")
                            }
                            GridRow {
                                Text("DIN Tolerance (s)")
                                    .font(.caption.weight(.semibold))
                                TextField("Tolerance", value: $epoching.timingTolerance, format: .number.precision(.fractionLength(3)))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                                    .help("Maximum time between an event and a DIN marker for them to be paired. Events with no DIN within this window are skipped.")
                            }
                        }

                        let missedCount = psaMissedDINCount(events: events)
                        if missedCount > 0 {
                            Label("\(missedCount) selected event\(missedCount == 1 ? "" : "s") with no DIN within ±\(String(format: "%.3f", epoching.timingTolerance)) s — will be skipped", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Toggle("Skip if contains artifact", isOn: $epoching.skipIfContainsArtifact)
                                Button {
                                    epoching.showsArtifactRejectionOptions = true
                                } label: {
                                    Image(systemName: "slider.horizontal.3")
                                }
                                .buttonStyle(.borderless)
                                .disabled(!epoching.skipIfContainsArtifact)
                                .help("Choose which artifact kinds cause an epoch to be rejected.")
                                .popover(isPresented: $epoching.showsArtifactRejectionOptions) {
                                    psaArtifactRejectionOptionsPopover()
                                }
                            }

                            Toggle("Skip if labeled \"Bad\"", isOn: $epoching.skipIfLabeledBad)
                                .help("Excludes segments manually marked Bad in Segment Health (right-click a segment while View > Show Segment Health is on) from category averages.")

                            Toggle("Interpolate bad channels per epoch", isOn: $epoching.interpolatesBadChannelsPerEpoch)
                                .help("Detects channels that are only bad WITHIN a given epoch (min/max/slope/acceleration) and interpolates just that epoch, instead of leaving a transient per-trial artifact uncorrected.")

                            epochBadChannelInlineOptions()
                                .padding(.leading, 18)
                                .disabled(!epoching.interpolatesBadChannelsPerEpoch)

                            Toggle("Average by category", isOn: $epoching.averageOnApply)
                            Toggle("Average reference", isOn: $epoching.averageReference)
                                .help("Re-reference to the common average of the good channels (excludes bad channels, uses interpolated values).")
                            Toggle("Baseline correct (pre-stimulus)", isOn: $epoching.baselineCorrected)
                                .help("Subtract each epoch's mean over the pre-stimulus interval from the whole epoch.")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 380)
            }
            .frame(maxHeight: .infinity)

            if let psaStatus = epoching.statusMessage {
                Text(psaStatus)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Spacer()
                if epoching.isApplying {
                    if let segmentingProgress = epoching.segmentingProgress {
                        ProgressView(value: segmentingProgress)
                            .controlSize(.small)
                            .frame(width: 80)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(epoching.phaseMessage ?? "Working…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") {
                    epoching.showsSheet = false
                }
                .disabled(epoching.isApplying)
                Button("Apply") {
                    psaTask?.cancel()
                    psaTask = Task {
                        await applyPSA(to: signal)
                        if !Task.isCancelled {
                            psaTask = nil
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApplyPSA(events: events) || epoching.isApplying)
            }
        }
        .padding(20)
        .frame(
            minWidth: 1080, idealWidth: 1140, maxWidth: 1500,
            minHeight: 560, idealHeight: 660, maxHeight: 1300
        )
    }

    func psaSegmentEventRow(summary: EventSummary, allSummaries: [EventSummary]) -> some View {
        let timingOptions = psaTimingMarkerOptions(in: allSummaries, excluding: summary.code)
        let isSelected = epoching.selectedEventCodes.contains(summary.code)
        let usesTimingMarker = epoching.timingMarkerEnabledValues.contains(summary.code)

        return HStack(spacing: 12) {
            Toggle(isOn: psaEventCodeBinding(summary.code)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.code)
                        .font(.system(.body, design: .monospaced))
                    if let detail = summary.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 150, alignment: .leading)

            Text("\(summary.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)

            TextField("Category", text: psaCategoryBinding(summary.code))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 170)
                .disabled(!isSelected)

            Toggle("DIN", isOn: psaTimingMarkerEnabledBinding(summary.code, options: timingOptions))
                .toggleStyle(.checkbox)
                .disabled(!isSelected || timingOptions.isEmpty)
                .help("Use the nearest selected timing marker as this category's onset.")

            Picker("Timing Marker", selection: psaTimingMarkerSelectionBinding(summary.code, options: timingOptions)) {
                if timingOptions.isEmpty {
                    Text("No markers").tag("")
                } else {
                    ForEach(timingOptions) { option in
                        Text(option.code).tag(option.code)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 128)
            .disabled(!isSelected || !usesTimingMarker || timingOptions.isEmpty)
            .help("Marker group whose nearest event supplies the true onset time.")
        }
    }

    /// Popover listing which artifact kinds reject an epoch. Moved out of the
    /// main PSA panel so the panel stays compact; opened from the "Skip if
    /// contains artifact" row.
    @ViewBuilder
    func psaArtifactRejectionOptionsPopover() -> some View {
        // Only offer artifacts that have actually been detected as an operation:
        // the eye-blink/eye-movement threshold detectors when they're enabled,
        // and any user-defined artifacts. If a detector was never run there are
        // no events to reject on, so it isn't listed (and isn't rejected — see
        // `psaArtifactEventsForRejectionByLabel`).
        let hasBlink = detectsEyeBlinkArtifacts
        let hasMovement = detectsEyeMovementArtifacts
        let definedArtifacts = template.definedArtifacts
        let hasAny = hasBlink || hasMovement || !definedArtifacts.isEmpty
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Reject epochs containing")
                    .font(.headline)

                if hasAny {
                    VStack(alignment: .leading, spacing: 7) {
                        if hasBlink {
                            psaArtifactRejectionRow(
                                title: "Eye Blink",
                                detail: "Threshold detector",
                                isOn: $epoching.skipEyeBlinks,
                                help: "Rejects epochs containing detected eye blink artifact events."
                            )
                        }
                        if hasMovement {
                            psaArtifactRejectionRow(
                                title: "Eye Movement",
                                detail: "Threshold detector",
                                isOn: $epoching.skipEyeMovements,
                                help: "Rejects epochs containing detected eye movement artifact events."
                            )
                        }
                        if !definedArtifacts.isEmpty {
                            if hasBlink || hasMovement {
                                Divider()
                                    .padding(.vertical, 2)
                            }
                            ForEach(definedArtifacts) { artifact in
                                psaArtifactRejectionRow(
                                    title: artifact.name,
                                    detail: "\(artifact.events.count) events · \(artifact.type.rawValue)",
                                    isOn: psaDefinedArtifactBinding(artifact.id),
                                    help: "Rejects epochs containing events from this defined artifact."
                                )
                            }
                        }
                    }
                } else {
                    Text("No detected artifacts. Run eye-blink / eye-movement detection or define an artifact template first, then epochs containing those events can be rejected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                psaArtifactRejectionWindowSection()
            }
            .padding(16)
            .frame(width: 300, alignment: .leading)
        }
        .frame(maxHeight: 420)
    }

    /// Time-boxes rejection to part of the epoch, so an artifact late in a long
    /// post-stimulus interval need not cost the trial.
    @ViewBuilder
    func psaArtifactRejectionWindowSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where the artifact must occur")
                .font(.headline)

            Toggle("Only part of the epoch", isOn: Binding(
                get: { epoching.limitsArtifactRejectionWindow },
                set: { newValue in
                    // Seed from the epoch on the way on, so the window starts as
                    // "everything" and is narrowed from there rather than opening
                    // on stale bounds from a differently-sized epoch.
                    if newValue, !epoching.limitsArtifactRejectionWindow {
                        epoching.seedArtifactRejectionWindowFromEpoch()
                    }
                    epoching.limitsArtifactRejectionWindow = newValue
                }
            ))
            .help("Off: an artifact anywhere in the epoch rejects it. On: only artifacts inside the window below do.")

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("From (s)")
                        .font(.caption.weight(.semibold))
                    TextField("From", value: $epoching.artifactRejectionWindowStart,
                              format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                GridRow {
                    Text("To (s)")
                        .font(.caption.weight(.semibold))
                    TextField("To", value: $epoching.artifactRejectionWindowEnd,
                              format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }
            .disabled(!epoching.limitsArtifactRejectionWindow)

            Text(psaArtifactRejectionWindowSummary())
                .font(.caption)
                .foregroundStyle(epoching.artifactRejectionWindowIsInverted ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Spells out the window that will actually be used, in ms, including any
    /// clamping to the epoch — so a window wider than the epoch doesn't look
    /// like it is doing something it isn't.
    func psaArtifactRejectionWindowSummary() -> String {
        let epochText = String(
            format: "The epoch spans %.0f to %.0f ms.",
            -epoching.preStimulus * 1000, epoching.postStimulus * 1000
        )
        guard epoching.limitsArtifactRejectionWindow else {
            return "An artifact anywhere in the epoch rejects it. \(epochText)"
        }
        if epoching.artifactRejectionWindowIsInverted {
            return "“To” must be later than “From” — nothing will be rejected. \(epochText)"
        }
        guard let window = epoching.effectiveArtifactRejectionWindow else {
            return epochText
        }
        var text = String(
            format: "Rejecting only for artifacts between %.0f and %.0f ms.",
            window.lowerBound * 1000, window.upperBound * 1000
        )
        let clampedStart = epoching.artifactRejectionWindowStart < -epoching.preStimulus
        let clampedEnd = epoching.artifactRejectionWindowEnd > epoching.postStimulus
        if clampedStart || clampedEnd {
            text += " Clamped to the epoch."
        }
        return "\(text) \(epochText)"
    }

    func psaArtifactRejectionRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>,
        help: String
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(help)
    }

    func psaDefinedArtifactBinding(_ id: DefinedArtifact.ID) -> Binding<Bool> {
        Binding(
            get: { epoching.skippedDefinedArtifactIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    epoching.skippedDefinedArtifactIDs.insert(id)
                    epoching.knownArtifactIDsForRejection.insert(id)
                } else {
                    epoching.skippedDefinedArtifactIDs.remove(id)
                    epoching.knownArtifactIDsForRejection.insert(id)
                }
            }
        )
    }

    private var maxBadChannelPercentBinding: Binding<Double> {
        Binding(
            get: { epoching.epochBadChannelThresholds.maxBadChannelFraction * 100 },
            set: { epoching.epochBadChannelThresholds.maxBadChannelFraction = max(0, min($0, 100)) / 100 }
        )
    }

    /// e.g. "% (~13 of 129 channels)" in percent mode, or "channels (~10% of
    /// 129)" in count mode — shows what the current setting means in the
    /// *other* unit for the currently loaded net.
    private var maxBadChannelCaption: String {
        guard let channelCount = recording.signal?.numberOfChannels, channelCount > 0 else {
            return epoching.epochBadChannelThresholds.usesAbsoluteBadChannelCount ? "channels" : "%"
        }
        if epoching.epochBadChannelThresholds.usesAbsoluteBadChannelCount {
            let count = epoching.epochBadChannelThresholds.maxBadChannelCount
            let percent = Int((100 * Double(count) / Double(channelCount)).rounded())
            return "channels (~\(percent)% of \(channelCount))"
        } else {
            let count = Int((epoching.epochBadChannelThresholds.maxBadChannelFraction * Double(channelCount)).rounded())
            return "% (~\(count) of \(channelCount) channels)"
        }
    }

    /// Per-epoch bad-channel threshold settings, laid out inline under the
    /// "Interpolate bad channels per epoch" toggle in the main PSA panel. Sized
    /// to fit the options column (min/max and slope/acceleration paired two per
    /// row) and greyed out (via the caller's `.disabled`) when interpolation is
    /// off.
    @ViewBuilder
    func epochBadChannelInlineOptions() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Min (µV)")
                        .font(.caption.weight(.semibold))
                    TextField("Min", value: $epoching.epochBadChannelThresholds.minMicrovolts, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("Max (µV)")
                        .font(.caption.weight(.semibold))
                    TextField("Max", value: $epoching.epochBadChannelThresholds.maxMicrovolts, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                GridRow {
                    Text("Max slope")
                        .font(.caption.weight(.semibold))
                        .help("Maximum allowed sample-to-sample change, in µV per sample.")
                    TextField("Slope", value: $epoching.epochBadChannelThresholds.maxSlopeMicrovoltsPerSample, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .help("Maximum allowed sample-to-sample change, in µV per sample.")
                    Text("Max accel.")
                        .font(.caption.weight(.semibold))
                        .help("Maximum allowed change in slope (acceleration), in µV per sample — catches spikes distinct from a fast but smooth ramp.")
                    TextField("Acceleration", value: $epoching.epochBadChannelThresholds.maxAccelerationMicrovoltsPerSample, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .help("Maximum allowed change in slope (acceleration), in µV per sample — catches spikes distinct from a fast but smooth ramp.")
                }
                GridRow {
                    Text("Reject if bad >")
                        .font(.caption.weight(.semibold))
                        .help("Reject the whole epoch (and skip its interpolation) when more than this many channels are flagged bad at once.")
                    HStack(spacing: 6) {
                        if epoching.epochBadChannelThresholds.usesAbsoluteBadChannelCount {
                            TextField("Count", value: $epoching.epochBadChannelThresholds.maxBadChannelCount, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                        } else {
                            TextField("Percent", value: maxBadChannelPercentBinding, format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                        }
                        Picker("Unit", selection: $epoching.epochBadChannelThresholds.usesAbsoluteBadChannelCount) {
                            Text("%").tag(false)
                            Text("#").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 64)
                        .help("Define the reject-epoch threshold as a percentage of the net's channels, or as a fixed channel count.")
                    }
                }
            }

            Text(maxBadChannelCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Escalate to globally bad if flagged in", isOn: $epoching.escalatesBadChannelsToGlobal)
                .help("A channel that's flagged bad in enough epochs is more likely a genuinely bad channel than a per-trial artifact — mark it bad for the whole recording and interpolate it there instead of just per-epoch.")

            HStack(spacing: 4) {
                TextField(
                    "Percent",
                    value: $epoching.escalationThresholdPercent,
                    format: .number.precision(.fractionLength(0))
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                Text("% of epochs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!epoching.escalatesBadChannelsToGlobal)
            .padding(.leading, 18)

            Button("Reset to Defaults") {
                epoching.epochBadChannelThresholds = EpochBadChannelThresholds()
            }
            .controlSize(.small)
            .help("A channel is flagged bad for an epoch if any sample falls outside min/max, or the slope or acceleration exceeds these limits. Flagged channels are interpolated for just that epoch — unless too many are bad at once, in which case the epoch is rejected instead.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func psaEventCodeBinding(_ code: String) -> Binding<Bool> {
        Binding(
            get: { epoching.selectedEventCodes.contains(code) },
            set: { isSelected in
                if isSelected {
                    epoching.selectedEventCodes.insert(code)
                    if epoching.categoryNames[code]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        epoching.categoryNames[code] = code
                    }
                } else {
                    epoching.selectedEventCodes.remove(code)
                    epoching.timingMarkerEnabledValues.remove(code)
                }
            }
        )
    }

    /// Combines several event codes/labels into one shared category name.
    /// Pooling happens for free at averaging time — `buildEpochs`/averaging
    /// groups segments by `EpochSegment.category`, so codes sharing a category
    /// name pool into one averaged trace, while each code stays individually
    /// selectable/toggleable (the group isn't a distinct data structure).
    @ViewBuilder
    func categoryGroupPopover(events: [MFFEvent], allSummaries: [EventSummary]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Category")
                .font(.headline)

            Picker("Mode", selection: binding(recordingStore.events, \.categoryGroupMode)) {
                ForEach(CategoryGroupMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch categoryGroupMode {
            case .codes:
                categoryGroupCodesPopoverBody(allSummaries: allSummaries)
            case .regex:
                categoryGroupRegexPopoverBody(events: events, allSummaries: allSummaries)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    @ViewBuilder
    private func categoryGroupCodesPopoverBody(allSummaries: [EventSummary]) -> some View {
        Text("Pools the selected codes/labels into one category for averaging. Each one stays individually selectable.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        TextField("Category name (e.g. \"emotional\")", text: binding(recordingStore.events, \.categoryGroupName))
            .textFieldStyle(.roundedBorder)

        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(allSummaries) { summary in
                    Toggle(isOn: Binding(
                        get: { categoryGroupSelectedCodes.contains(summary.code) },
                        set: { isOn in
                            if isOn { categoryGroupSelectedCodes.insert(summary.code) }
                            else { categoryGroupSelectedCodes.remove(summary.code) }
                        }
                    )) {
                        HStack(spacing: 6) {
                            Text(summary.code)
                                .font(.system(.body, design: .monospaced))
                            Text("(\(epoching.categoryNames[summary.code] ?? summary.code))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(4)
        }
        .frame(maxHeight: 220)

        HStack {
            Spacer()
            Button("Cancel") {
                showsCategoryGroupPopover = false
            }
            Button("Create Group") {
                applyCategoryGroup()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(categoryGroupSelectedCodes.count < 2
                || categoryGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private func categoryGroupRegexPopoverBody(events: [MFFEvent], allSummaries: [EventSummary]) -> some View {
        let preview = regexMatchPreview(
            sourceCode: categoryRegexSourceCode,
            pattern: categoryRegexPattern,
            categoryNameTemplate: categoryGroupName,
            events: events
        )
        let patternIsValid = !categoryRegexPattern.isEmpty && preview != nil

        Text("Sub-selects the events of ONE code whose description matches a pattern into a new category, in addition to that event's own category.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Text("Source code")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

        Picker("Source code", selection: binding(recordingStore.events, \.categoryRegexSourceCode)) {
            Text("Choose a code…").tag("")
            ForEach(allSummaries) { summary in
                Text("\(summary.code) — \(summary.count) events").tag(summary.code)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)

        Text("Pattern (applied to description field)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        TextField("e.g. cond=(\\d+)_correct", text: binding(recordingStore.events, \.categoryRegexPattern))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))

        if categoryRegexSourceCode.isEmpty {
            Text("Choose a source code above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !categoryRegexPattern.isEmpty {
            if let preview {
                HStack(spacing: 6) {
                    Image(systemName: preview.matched > 0 ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(preview.matched > 0 ? .green : .orange)
                    Text("\(preview.matched) of \(preview.total) descriptions match")
                        .font(.caption)
                }
                if preview.matched > 0 {
                    let categoryNoun = preview.categories.count == 1 ? "category" : "categories"
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(.secondary)
                        Text("→ \(preview.categories.count) \(categoryNoun): \(regexCategoryListSummary(preview.categories))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if preview.categories.count == 1, categoryGroupName.contains("$") {
                        Label("Only one category — check that the pattern has a matching capture group for $1/$2/…", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !preview.samples.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(preview.samples, id: \.category) { sample in
                            HStack(spacing: 4) {
                                Text(sample.description)
                                Text("→")
                                    .foregroundStyle(.secondary)
                                Text(sample.category)
                                    .fontWeight(.semibold)
                            }
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                        }
                        if preview.categories.count > preview.samples.count {
                            Text("+ \(preview.categories.count - preview.samples.count) more categor\(preview.categories.count - preview.samples.count == 1 ? "y" : "ies")")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }
            } else {
                Label("Invalid regular expression", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        TextField("New category name (e.g. \"emotional\" or \"n2_$1\")", text: binding(recordingStore.events, \.categoryGroupName))
            .textFieldStyle(.roundedBorder)
            .help("Use $1, $2, … to reference the pattern's capture groups — one rule then fans out into a category per captured value instead of needing a separate rule for each.")

        HStack {
            Spacer()
            Button("Cancel") {
                showsCategoryGroupPopover = false
            }
            Button("Create Category") {
                applyCategoryRegexRule()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(categoryRegexSourceCode.isEmpty
                || !patternIsValid
                || categoryGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// "2 categories: n2_nov, n2_rep" / "1 category: n2_" / truncates past 6
    /// with a "+N more" tail so a high-cardinality capture group doesn't blow
    /// out the popover or the row.
    private func regexCategoryListSummary(_ categories: [String]) -> String {
        let shown = categories.prefix(6).joined(separator: ", ")
        let suffix = categories.count > 6 ? ", +\(categories.count - 6) more" : ""
        return shown + suffix
    }

    /// `nil` means the pattern doesn't compile as a regex; otherwise the match
    /// count against `sourceCode`'s events, the full distinct set of
    /// categories this rule would actually produce, and ONE example
    /// (description → resolved category) per distinct category — not just
    /// the first 2 raw matches, which can all collapse onto the same category
    /// and hide the fan-out you're trying to verify. Resolves
    /// `categoryNameTemplate`'s `$1`/`$2`/… references the same way
    /// `buildEpochs` does, so a missing capture group (everything collapsing
    /// into one category) is visible before you click Create.
    private func regexMatchPreview(
        sourceCode: String,
        pattern: String,
        categoryNameTemplate: String,
        events: [MFFEvent]
    ) -> (matched: Int, total: Int, samples: [(description: String, category: String)], categories: [String])? {
        guard !sourceCode.isEmpty, !pattern.isEmpty else { return nil }
        guard let regex = try? Regex(pattern).ignoresCase() else { return nil }
        let rule = CategoryRegexRule(sourceCode: sourceCode, pattern: pattern, categoryName: categoryNameTemplate)
        let codeEvents = events.filter { $0.code == sourceCode }
        var matchedCount = 0
        var exampleByCategory: [String: String] = [:]
        for event in codeEvents {
            guard let description = event.eventDescription,
                  let match = description.firstMatch(of: regex) else { continue }
            matchedCount += 1
            let category = rule.resolvedCategoryName(for: match)
            if exampleByCategory[category] == nil {
                exampleByCategory[category] = description
            }
        }
        let categories = exampleByCategory.keys.sorted()
        let samples = categories.prefix(8).map { (exampleByCategory[$0] ?? "", $0) }
        return (matchedCount, codeEvents.count, Array(samples), categories)
    }

    /// Creates a pooled group — each member code keeps its own category (set
    /// via `psaCategoryBinding`, untouched here); the group adds a second,
    /// shared category on top, so both the group's segments and each member's
    /// own segments get produced (see `selectedPSACategoriesByCode`).
    func applyCategoryGroup() {
        let name = categoryGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, categoryGroupSelectedCodes.count >= 2 else { return }
        epoching.categoryGroups[name] = categoryGroupSelectedCodes
        for code in categoryGroupSelectedCodes {
            epoching.selectedEventCodes.insert(code)
            if epoching.categoryNames[code]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                epoching.categoryNames[code] = code
            }
        }
        showsCategoryGroupPopover = false
        categoryGroupSelectedCodes.removeAll()
        categoryGroupName = ""
    }

    /// Creates a regex sub-selection rule — see `CategoryRegexRule`. Unlike
    /// `applyCategoryGroup`, the source code does NOT need to already be in
    /// `selectedEventCodes`; `psaBuildJob`/`makeBuildJob` pull in its events
    /// regardless so the regex-matched subset can be evaluated on its own.
    func applyCategoryRegexRule() {
        let name = categoryGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = categoryRegexPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !pattern.isEmpty, !categoryRegexSourceCode.isEmpty,
              (try? Regex(pattern)) != nil else { return }
        let rule = CategoryRegexRule(sourceCode: categoryRegexSourceCode, pattern: pattern, categoryName: name)
        epoching.categoryRegexRules[rule.id.uuidString] = rule
        showsCategoryGroupPopover = false
        categoryRegexSourceCode = ""
        categoryRegexPattern = ""
        categoryGroupName = ""
    }

    /// A row for a pooled category group, styled like `psaSegmentEventRow` so
    /// it sits in the same list. The DIN toggle is a bulk shortcut: it applies
    /// each member's OWN nearest-marker DIN setting (no separate group-level
    /// timing config) — the group's segments always share timing with that
    /// member's own individually-tagged segments.
    func psaCategoryGroupRow(groupName: String, allSummaries: [EventSummary]) -> some View {
        let members = epoching.categoryGroups[groupName] ?? []
        let selectedMembers = members.intersection(epoching.selectedEventCodes)
        let totalCount = allSummaries.filter { members.contains($0.code) }.reduce(0) { $0 + $1.count }

        return HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(groupName)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Text("\(selectedMembers.count) of \(members.count) codes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, alignment: .leading)

            Text("\(totalCount)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)

            Text(groupName)
                .foregroundStyle(.secondary)
                .frame(minWidth: 170, alignment: .leading)
                .help("Pooled category — produces averaged segments for the group in addition to each member's own category.")

            Toggle("DIN", isOn: psaCategoryGroupDINBinding(members: members, allSummaries: allSummaries))
                .toggleStyle(.checkbox)
                .disabled(selectedMembers.isEmpty)
                .help("Enable each member code's own nearest-marker DIN pairing, all at once.")

            Spacer(minLength: 0)
                .frame(width: 128)

            Button {
                epoching.categoryGroups.removeValue(forKey: groupName)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove this group. Member codes keep their own individual categories.")
        }
    }

    /// Bulk DIN toggle for a group: on = enable each selected member's own
    /// DIN pairing (seeding a default marker if it has none yet); off =
    /// disable DIN for all of them. Never introduces a separate group-level
    /// timing config.
    func psaCategoryGroupDINBinding(members: Set<String>, allSummaries: [EventSummary]) -> Binding<Bool> {
        Binding(
            get: {
                let selectedMembers = members.intersection(epoching.selectedEventCodes)
                guard !selectedMembers.isEmpty else { return false }
                return selectedMembers.allSatisfy { epoching.timingMarkerEnabledValues.contains($0) }
            },
            set: { isOn in
                for member in members.intersection(epoching.selectedEventCodes) {
                    let options = psaTimingMarkerOptions(in: allSummaries, excluding: member)
                    if isOn {
                        guard !options.isEmpty else { continue }
                        epoching.timingMarkerEnabledValues.insert(member)
                        if let current = epoching.timingMarkerValuesBySegmentValue[member],
                           options.contains(where: { $0.code == current }) {
                            continue
                        }
                        epoching.timingMarkerValuesBySegmentValue[member] = options.first?.code
                    } else {
                        epoching.timingMarkerEnabledValues.remove(member)
                    }
                }
            }
        )
    }

    /// A row for a regex sub-selection rule, styled like `psaCategoryGroupRow`
    /// so it sits in the same list — including the same count column, computed
    /// by re-running the rule's pattern against `sourceCode`'s current events
    /// (cheap: a handful of codes, not the whole recording).
    func psaCategoryRegexRuleRow(ruleID: String, events: [MFFEvent]) -> some View {
        let rule = epoching.categoryRegexRules[ruleID]
        let preview = rule.flatMap {
            regexMatchPreview(
                sourceCode: $0.sourceCode,
                pattern: $0.pattern,
                categoryNameTemplate: $0.categoryName,
                events: events
            )
        }
        let matchCount = preview?.matched ?? 0
        let categoryCount = preview?.categories.count ?? 0

        return HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule?.categoryName ?? "")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Text(rule?.sourceCode ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 150, alignment: .leading)

            Text("\(matchCount)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule?.pattern ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let rule, rule.categoryName.contains("$"), let categories = preview?.categories, !categories.isEmpty {
                    Text("→ \(regexCategoryListSummary(categories))")
                        .font(.caption2)
                        .foregroundStyle(categoryCount <= 1 ? .orange : .secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 170, alignment: .leading)
            .help("Regex sub-selection — matching events are filed under this category in addition to their own.")

            Spacer(minLength: 0)

            Button {
                epoching.categoryRegexRules.removeValue(forKey: ruleID)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove this rule.")
        }
    }

    func psaCategoryBinding(_ code: String) -> Binding<String> {
        Binding(
            get: { epoching.categoryNames[code] ?? code },
            set: { epoching.categoryNames[code] = $0 }
        )
    }

    func psaTimingMarkerEnabledBinding(_ segmentValue: String, options: [EventSummary]) -> Binding<Bool> {
        Binding(
            get: { epoching.timingMarkerEnabledValues.contains(segmentValue) },
            set: { isEnabled in
                if isEnabled {
                    epoching.timingMarkerEnabledValues.insert(segmentValue)
                    if let currentValue = epoching.timingMarkerValuesBySegmentValue[segmentValue],
                       options.contains(where: { $0.code == currentValue }) {
                        return
                    }
                    epoching.timingMarkerValuesBySegmentValue[segmentValue] = options.first?.code
                } else {
                    epoching.timingMarkerEnabledValues.remove(segmentValue)
                }
            }
        )
    }

    func psaTimingMarkerSelectionBinding(_ segmentValue: String, options: [EventSummary]) -> Binding<String> {
        Binding(
            get: {
                let validOptions = Set(options.map(\.code))
                if let currentValue = epoching.timingMarkerValuesBySegmentValue[segmentValue],
                   validOptions.contains(currentValue) {
                    return currentValue
                }
                return options.first?.code ?? ""
            },
            set: { newValue in
                if options.contains(where: { $0.code == newValue }) {
                    epoching.timingMarkerValuesBySegmentValue[segmentValue] = newValue
                }
            }
        )
    }

    func psaTimingMarkerOptions(in summaries: [EventSummary], excluding segmentValue: String) -> [EventSummary] {
        summaries.filter { $0.code != segmentValue }
    }

    func canApplyPSA(events: [MFFEvent]) -> Bool {
        !events.isEmpty
            && (!epoching.selectedEventCodes.isEmpty || !epoching.categoryRegexRules.isEmpty)
            && epoching.preStimulus >= 0
            && epoching.postStimulus > 0
            && selectedPSACategoriesByCode() != nil
            && selectedPSATimingMarkersBySegmentValue(events: events) != nil
    }

    /// Segment value (code) → categories its epochs are filed under: its own
    /// category, plus the category of any pooled group it's a member of (a
    /// selected code that belongs to a group produces segments for both).
    func selectedPSACategoriesByCode() -> [String: [String]]? {
        var categoriesByCode = [String: [String]]()
        for code in epoching.selectedEventCodes {
            let category = (epoching.categoryNames[code] ?? code).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty else { return nil }
            categoriesByCode[code] = [category]
        }
        for (groupName, members) in epoching.categoryGroups {
            let category = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty else { continue }
            for member in members where epoching.selectedEventCodes.contains(member) {
                categoriesByCode[member, default: []].append(category)
            }
        }
        return categoriesByCode
    }

    func selectedPSATimingMarkersBySegmentValue(events: [MFFEvent]) -> [String: String]? {
        let availableValues = Set(groupedPSAEventSummaries(events).map(\.code))
        var timingMarkersBySegmentValue = [String: String]()
        for segmentValue in epoching.selectedEventCodes where epoching.timingMarkerEnabledValues.contains(segmentValue) {
            guard let timingValue = epoching.timingMarkerValuesBySegmentValue[segmentValue],
                  availableValues.contains(timingValue),
                  timingValue != segmentValue else {
                return nil
            }
            timingMarkersBySegmentValue[segmentValue] = timingValue
        }
        return timingMarkersBySegmentValue
    }

    func applyPSA(to signal: MFFSignalData) async {
        // Validate and capture all inputs on the main actor before going off-thread.
        guard let job = psaBuildJob(from: signal) else { return }
        await processingQueue.run("PSA Segmentation") { [self] in
            await applyPSACore(to: signal, job: job)
        }
    }

    /// Computes per-category SNR from the RAW (pre-average) single trials off
    /// the interactive path, so the PSA sheet can close and the user can see
    /// their average immediately. The Averages workspace shows a spinner in the
    /// SNR area (driven by `isComputingAverageSNR`) until this lands. Any prior
    /// SNR task is cancelled, and the result is only applied if the session is
    /// still current.
    func computeAverageSNRInBackground(from base: PSABuildResult, excludedIndices: Set<Int>, sessionID: UUID) {
        snrTask?.cancel()
        epoching.averageSNRByCategory = [:]
        epoching.isComputingAverageSNR = true
        snrTask = Task {
            let worker = Task.detached(priority: .utility) {
                base.categorySNR(excludedIndices: excludedIndices)
            }
            let result = await withTaskCancellationHandler(
                operation: { await worker.value },
                onCancel: { worker.cancel() }
            )
            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            epoching.averageSNRByCategory = result
            epoching.isComputingAverageSNR = false
            snrTask = nil
        }
    }

    func enableSegmentHealthAfterSegmentationIfNeeded() {
        guard !epoching.isAveraged, epoching.epochedSignal?.isAveraged != true else {
            // Preserve manual labels long enough for re-averaging exclusions,
            // but remove results/overlays that belong to the single trials.
            segHealth.clearAnalysis(hide: true, clearLabels: false)
            return
        }
        guard processingDefaults.autoRunSegmentHealthAfterSegmentation else { return }
        segHealth.clearAnalysis(clearLabels: true)
        segHealth.shows = true
        segHealth.showsDetails = false
        segHealth.refreshRequest += 1
    }

    func psaSkippedLabeledBadSegmentsSummary(for segments: [EpochSegment], excludedIndices: Set<Int>) -> [String] {
        guard !excludedIndices.isEmpty else { return [] }
        return segments.enumerated()
            .filter { excludedIndices.contains($0.offset) }
            .map { index, segment in
                "#\(index + 1) \(epoching.displayCategory(segment.category))"
            }
    }

    func refreshPSAEpochDiagnostics(from result: PSABuildResult) {
        epoching.epochBadChannelSummary = result.epochBadChannelCounts.keys.sorted().map {
            "Ch\($0 + 1) (\(result.epochBadChannelCounts[$0] ?? 0) of \(result.totalEpochsEvaluated) epochs)"
        }
        epoching.epochBadChannelAllSegmentsSummary = result.epochBadChannelsInAllAcceptedSegments.map {
            "Ch\($0 + 1)"
        }
        epoching.interpolatedChannelsBySegmentSummary = result.interpolatedChannelSegments.keys.sorted().map { channel in
            let segments = result.interpolatedChannelSegments[channel, default: []]
                .map(String.init)
                .joined(separator: ",")
            return "Ch\(channel + 1)(\(segments))"
        }
    }

    func appendPSAEpochDiagnostics(
        to baseStatus: String,
        sourceSegments: [EpochSegment],
        skippedIndices: Set<Int> = [],
        includeSkippedLabeledBadSegments: Bool = false
    ) -> String {
        if includeSkippedLabeledBadSegments {
            epoching.skippedLabeledBadSegmentsSummary = psaSkippedLabeledBadSegmentsSummary(for: sourceSegments, excludedIndices: skippedIndices)
        } else {
            epoching.skippedLabeledBadSegmentsSummary.removeAll()
        }

        var clauses: [String] = []
        if !epoching.skippedLabeledBadSegmentsSummary.isEmpty {
            clauses.append("skipped labeled bad segments: \(epoching.skippedLabeledBadSegmentsSummary.joined(separator: ", "))")
        }
        if !epoching.epochBadChannelSummary.isEmpty {
            let channels = epoching.epochBadChannelSummary.map { summary in
                summary.split(separator: " ").first.map(String.init) ?? summary
            }
            clauses.append("\(channels.count) channel\(channels.count == 1 ? "" : "s") bad in \u{2265}1 segment (\(channels.joined(separator: ", ")))")
        }
        if !epoching.epochBadChannelAllSegmentsSummary.isEmpty {
            let channels = epoching.epochBadChannelAllSegmentsSummary.joined(separator: ", ")
            clauses.append("\(epoching.epochBadChannelAllSegmentsSummary.count) channel\(epoching.epochBadChannelAllSegmentsSummary.count == 1 ? "" : "s") bad in all kept segments (\(channels))")
        }
        guard !clauses.isEmpty else { return baseStatus }
        return baseStatus + " · " + clauses.joined(separator: " · ")
    }

    /// Interactive PSA apply.
    ///
    /// The build → average → post-process sequence lives in
    /// `EpochingViewModel.buildAndPostProcess`, shared with the headless path.
    /// What remains here is what genuinely differs: the session guard, the
    /// Segment Health label exclusions, background SNR so the sheet can close
    /// immediately, the richer status line, and the UI teardown.
    private func applyPSACore(to signal: MFFSignalData, job: PSABuildJob) async {
        let sessionID = recordingSessionID
        let shouldAverage = epoching.averageOnApply
        let badChannels = channels.bad
        let suffix = psaPostProcessingSuffix()

        guard let outcome = await epoching.buildAndPostProcess(
            job: job,
            shouldAverage: shouldAverage,
            averageReference: epoching.averageReference,
            baselineCorrect: epoching.baselineCorrected,
            badChannels: badChannels,
            excludedSegmentIndices: { [self] segments in excludedBadSegmentIndices(segments) },
            isCurrent: { [self] in sessionID == recordingSessionID }
        ) else {
            return
        }

        let built = outcome.built
        let finalResult = outcome.finalResult
        let epochBadChannelCounts = built.epochBadChannelCounts
        let totalEpochsEvaluated = built.totalEpochsEvaluated
        let rejectedForTooManyBadChannels = built.rejectedForTooManyBadChannels
        let skippedBadIndices = excludedBadSegmentIndices(built.segments)
        var exclusionSummary = built.exclusionSummary

        // Keep raw epochs as source so post-processing can be toggled later.
        segmentedEpochSignal = built.signal
        segmentedEpochSegments = built.segments

        if outcome.wasAveraged {
            // SNR is measured from the RAW single trials, but it does NOT block
            // closing the sheet — the user sees their average right away and the
            // Averages workspace shows a spinner until SNR lands.
            computeAverageSNRInBackground(
                from: built,
                excludedIndices: skippedBadIndices,
                sessionID: sessionID
            )
        } else {
            snrTask?.cancel()
            snrTask = nil
            epoching.isComputingAverageSNR = false
            epoching.averageSNRByCategory = [:]
        }

        epoching.epochedSignal = finalResult.signal
        epoching.epochSegments = finalResult.segments
        epoching.isAveraged = outcome.wasAveraged
        enableSegmentHealthAfterSegmentationIfNeeded()
        exclusionSummary.skippedLabeledBadSegments = shouldAverage ? skippedBadIndices.count : 0
        exclusionSummary.outputSegments = finalResult.segments.count
        exclusionSummary.badChannelCount = epochBadChannelCounts.count
        epoching.psaExclusionSummary = exclusionSummary
        if outcome.wasAveraged {
            epoching.showsButterflyPlot = true
        } else {
            epoching.showsButterflyPlot = false
            epoching.averagedDisplayMode = .waveform
        }
        refreshPSAEpochDiagnostics(from: built)

        // Bad-channel reporting is composed here (not read off finalResult.message)
        // because average()/postProcessed() replace the message wholesale —
        // relying on it would silently drop this whenever averaging is on.
        var statusText = finalResult.message + suffix
        if epoching.interpolatesBadChannelsPerEpoch, rejectedForTooManyBadChannels > 0 {
            statusText += " · \(rejectedForTooManyBadChannels) epoch\(rejectedForTooManyBadChannels == 1 ? "" : "s") rejected for too many bad channels"
        }
        statusText = appendPSAEpochDiagnostics(
            to: statusText,
            sourceSegments: built.segments,
            skippedIndices: skippedBadIndices,
            includeSkippedLabeledBadSegments: shouldAverage
        )
        epoching.statusMessage = statusText

        await escalateBadChannelsIfNeeded(
            counts: epochBadChannelCounts,
            totalEpochs: totalEpochsEvaluated,
            continuousSignal: signal
        )
        guard !Task.isCancelled, sessionID == recordingSessionID else {
            epoching.isApplying = false
            epoching.phaseMessage = nil
            return
        }
        if epoching.interpolatesBadChannelsPerEpoch, !channels.bad.isEmpty {
            let recordingBadChannels = channels.bad.sorted().map { "Ch\($0 + 1)" }
            epoching.statusMessage = (epoching.statusMessage ?? "")
                + " · Recording bad channels (\(channels.bad.count)): \(recordingBadChannels.joined(separator: ", "))"
        }
        selectedSampleRange = nil
        dragSelectionStartSample = nil
        dragSelectionEndSample = nil
        topomapSample = nil
        epoching.butterflyTopomapRelativeSample = nil
        selectedEventCodes.removeAll()
        horizontalScrollPosition.scrollTo(x: 0)
        epoching.isApplying = false
        epoching.phaseMessage = nil
        epoching.showsSheet = false
    }

    /// If enabled, marks any channel flagged bad in at least
    /// `escalationThresholdPercent`% of epochs bad for the WHOLE recording
    /// and interpolates it there. All escalated targets share one off-main
    /// spherical-spline factorization, and the completed batch patches
    /// `epoching.epochedSignal` in place rather than discarding the averages
    /// just computed. NOTE: does not patch
    /// `segmentedEpochSignal` (the pre-average raw-epoch cache) — toggling
    /// post-processing after an escalation will re-derive from the
    /// pre-escalation raw epochs. A known, narrow gap, not fixed here.
    /// Interactive wrapper around the shared escalation: adds the session guard
    /// (this can outlive a same-window "Close Recording") and the status-line
    /// reporting. The decision logic and interpolation live in
    /// `PSABadChannelEscalation`, shared with the headless path.
    private func escalateBadChannelsIfNeeded(
        counts: [Int: Int],
        totalEpochs: Int,
        continuousSignal: MFFSignalData
    ) async {
        let sessionID = recordingSessionID
        epoching.phaseMessage = "Interpolating global bad channels…"

        let outcome = await PSABadChannelEscalation.escalate(
            counts: counts,
            totalEpochs: totalEpochs,
            isEnabled: epoching.escalatesBadChannelsToGlobal,
            thresholdPercent: epoching.escalationThresholdPercent,
            continuousSignal: continuousSignal,
            epochedSignal: epoching.epochedSignal,
            positions: electrodeGeometry?.positions ?? [:],
            channels: channels
        )

        guard sessionID == recordingSessionID else { return }

        epoching.escalatedChannelSummaries = outcome.summaries
        guard !outcome.summaries.isEmpty else { return }

        if outcome.lackedGeometry {
            channelStatusMessage = "No electrode geometry is available; can't interpolate escalated channels."
            channelStatusIsError = true
            return
        }

        if !outcome.messages.isEmpty {
            artifactVM.detectionRefreshToken += 1
        }
        if let patched = outcome.patchedEpochedSignal {
            epoching.epochedSignal = patched
        } else if outcome.requiresEpochInvalidation {
            invalidateEpochsForSignalChange()
        }

        if !outcome.messages.isEmpty || !outcome.errors.isEmpty {
            channelStatusMessage = (outcome.messages + outcome.errors).joined(separator: " · ")
            channelStatusIsError = !outcome.errors.isEmpty
        }

        let escalatedChannels = outcome.summaries
            .compactMap { $0.split(separator: ":").first.map(String.init) }
            .joined(separator: ", ")
        epoching.statusMessage = (epoching.statusMessage ?? "")
            + " · Escalated \(outcome.summaries.count) channel\(outcome.summaries.count == 1 ? "" : "s") to globally bad (\(escalatedChannels))."
    }

    /// Validates PSA inputs on the main actor and packages them into a Sendable job
    /// that can run epoch-slicing off the main thread.
    func psaBuildJob(from signal: MFFSignalData) -> PSABuildJob? {
        guard let categoriesBySegmentValue = selectedPSACategoriesByCode() else {
            epoching.statusMessage = "Enter a category name for each selected event."
            return nil
        }
        let allEvents = segmentableEvents(for: signal)
            .sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        guard let timingMarkersBySegmentValue = selectedPSATimingMarkersBySegmentValue(events: allEvents) else {
            epoching.statusMessage = "Choose a timing marker for each DIN-adjusted event."
            return nil
        }
        let timingEventsBySegmentValue = Dictionary(grouping: allEvents, by: psaSegmentValue(for:))
        for (segmentValue, timingValue) in timingMarkersBySegmentValue {
            guard timingEventsBySegmentValue[timingValue]?.isEmpty == false else {
                epoching.statusMessage = "No \(timingValue) timing markers found for \(segmentValue)."
                return nil
            }
        }
        let regexSourceCodes = Set(epoching.categoryRegexRules.values.map(\.sourceCode))
        let events = allEvents.filter {
            let value = psaSegmentValue(for: $0)
            return epoching.selectedEventCodes.contains(value) || regexSourceCodes.contains(value)
        }
        guard !events.isEmpty else {
            epoching.statusMessage = epoching.segmentField == .artifact
                ? "Select at least one artifact type."
                : "Select at least one event \(epoching.segmentField.rawValue.lowercased())."
            return nil
        }
        guard signal.samplingRate > 0, let sampleCount = signal.data.first?.count, sampleCount > 0 else {
            epoching.statusMessage = "This signal has no readable samples."
            return nil
        }
        let preSamples = max(Int((epoching.preStimulus * signal.samplingRate).rounded()), 0)
        let epochLength = max(Int(((epoching.preStimulus + epoching.postStimulus) * signal.samplingRate).rounded()), 1)
        guard epochLength > 0 else {
            epoching.statusMessage = "Epoch duration must be greater than zero."
            return nil
        }
        let artifactEventsByLabel = psaArtifactEventsForRejectionByLabel(in: signal)
        let regexRules = Array(epoching.categoryRegexRules.values)
        return PSABuildJob(
            signal: signal,
            events: events,
            categoriesBySegmentValue: categoriesBySegmentValue,
            categoryRegexRules: regexRules,
            timingMarkersBySegmentValue: timingMarkersBySegmentValue,
            timingEventsBySegmentValue: timingEventsBySegmentValue,
            artifactEventsForRejection: artifactEventsByLabel.values.flatMap { $0 },
            artifactEventsForRejectionByLabel: artifactEventsByLabel,
            preSamples: preSamples,
            epochLength: epochLength,
            psaOffset: epoching.offset,
            sampleCount: sampleCount,
            colorIndices: categoryColorIndices(for: categoriesBySegmentValue.values.flatMap { $0 } + regexRules.map(\.categoryName)),
            skipIfContainsArtifact: epoching.skipIfContainsArtifact && epoching.segmentField != .artifact,
            artifactRejectionLabel: psaArtifactRejectionLabel(),
            timingTolerance: epoching.timingTolerance,
            interpolatesBadChannelsPerEpoch: epoching.interpolatesBadChannelsPerEpoch,
            epochBadChannelThresholds: epoching.epochBadChannelThresholds,
            electrodePositions: electrodeGeometry?.positions ?? [:],
            globallyBadChannels: channels.bad,
            artifactRejectionWindow: epoching.effectiveArtifactRejectionWindow
        )
    }

    /// Count of selected events that have no DIN candidate within the current tolerance window.
    /// Used for the live unmatched-DIN warning in the PSA sheet.
    func psaMissedDINCount(events: [MFFEvent]) -> Int {
        let tolerance = epoching.timingTolerance
        var missed = 0
        for event in events {
            let segValue = psaSegmentValue(for: event)
            guard epoching.timingMarkerEnabledValues.contains(segValue),
                  let timingValue = epoching.timingMarkerValuesBySegmentValue[segValue] else { continue }
            let candidates = events.filter { psaSegmentValue(for: $0) == timingValue }
            let hasMatch = candidates.contains { abs($0.beginTimeSeconds - event.beginTimeSeconds) <= tolerance }
            if !hasMatch { missed += 1 }
        }
        return missed
    }

    func nearestPSATimingEvent(to event: MFFEvent, in candidates: [MFFEvent]) -> MFFEvent? {
        candidates.min { lhs, rhs in
            let lhsDistance = abs(lhs.beginTimeSeconds - event.beginTimeSeconds)
            let rhsDistance = abs(rhs.beginTimeSeconds - event.beginTimeSeconds)
            if lhsDistance == rhsDistance {
                return lhs.beginTimeSeconds < rhs.beginTimeSeconds
            }
            return lhsDistance < rhsDistance
        }
    }

    func psaArtifactEventsForRejection(in signal: MFFSignalData) -> [MFFEvent] {
        psaArtifactEventsForRejectionByLabel(in: signal).values.flatMap { $0 }
    }

    func psaArtifactEventsForRejectionByLabel(in signal: MFFSignalData) -> [String: [MFFEvent]] {
        // When segmenting on artifacts themselves, don't reject epochs for containing those artifacts.
        guard epoching.skipIfContainsArtifact, epoching.segmentField != .artifact else { return [:] }

        var eventsByLabel: [String: [MFFEvent]] = [:]
        // Only reject on eye artifacts whose detector was actually enabled/run —
        // matching what the rejection popover offers. A disabled detector has no
        // events, so it must not trigger on-the-fly detection here.
        if epoching.skipEyeBlinks, detectsEyeBlinkArtifacts {
            eventsByLabel["Eye Blink", default: []] += artifactEventsOrDetection(for: .blink, in: signal)
        }
        if epoching.skipEyeMovements, detectsEyeMovementArtifacts {
            eventsByLabel["Eye Movement", default: []] += artifactEventsOrDetection(for: .movement, in: signal)
        }
        for artifact in template.definedArtifacts where epoching.skippedDefinedArtifactIDs.contains(artifact.id) {
            eventsByLabel[artifact.name, default: []] += artifact.events
        }

        return eventsByLabel.filter { !$0.value.isEmpty }
    }

    func artifactEventsOrDetection(for kind: EyeArtifactKind, in signal: MFFSignalData) -> [MFFEvent] {
        let existingEvents = artifactVM.events.filter { $0.code == kind.eventCode }
        if !existingEvents.isEmpty {
            return existingEvents
        }

        let configuration = kind == .blink
            ? artifactVM.blinkThresholdConfig
            : artifactVM.movementThresholdConfig
        return EyeArtifactThresholdDetector.detect(
            kind: kind,
            channels: signal.data,
            samplingRate: signal.samplingRate,
            duration: signal.duration,
            sensorLayoutName: recording.sensorLayout?.name,
            configuration: configuration
        )
    }

    func shouldSkipEpochForArtifact(
        startSample: Int,
        endSample: Int,
        samplingRate: Double,
        artifactEvents: [MFFEvent]
    ) -> Bool {
        guard epoching.skipIfContainsArtifact,
              !artifactEvents.isEmpty,
              samplingRate > 0 else { return false }
        let startSeconds = Double(startSample) / samplingRate
        let endSeconds = Double(endSample) / samplingRate
        return artifactEvents.contains { event in
            event.beginTimeSeconds >= startSeconds && event.beginTimeSeconds <= endSeconds
        }
    }

    func psaArtifactRejectionLabel() -> String {
        var labels: [String] = []
        if epoching.skipEyeBlinks {
            labels.append("eye blinks")
        }
        if epoching.skipEyeMovements {
            labels.append("eye movements")
        }
        let definedCount = template.definedArtifacts.filter {
            epoching.skippedDefinedArtifactIDs.contains($0.id)
        }.count
        if definedCount == 1 {
            labels.append("1 defined artifact")
        } else if definedCount > 1 {
            labels.append("\(definedCount) defined artifacts")
        }
        return labels.isEmpty ? "artifacts" : labels.joined(separator: "/")
    }

    /// Indices (into `segments`, matching `SegmentHealthAnalyzer.segmentID`'s
    /// indexing) of segments the user labeled "Bad" in Segment Health, when
    /// "Skip if labeled Bad" is on. Empty (average() takes the fast path) when
    /// the toggle is off or nothing's been labeled.
    func excludedBadSegmentIndices(_ segments: [EpochSegment], requiresOptIn: Bool = true) -> Set<Int> {
        guard (!requiresOptIn || epoching.skipIfLabeledBad), !segHealth.qualityLabels.isEmpty else { return [] }
        var result = Set<Int>()
        if !epoching.isAveraged,
           epoching.epochSegments.count == segments.count,
           let analysisResults = segHealth.analysis?.results {
            for visible in analysisResults where segHealth.qualityLabels[visible.segmentID] == .bad {
                guard segments.indices.contains(visible.segmentIndex) else { continue }
                result.insert(visible.segmentIndex)
            }
        }
        for (index, segment) in segments.enumerated() {
            let id = SegmentHealthAnalyzer.segmentID(index: index, segment: segment)
            if segHealth.qualityLabels[id] == .bad {
                result.insert(index)
            }
        }
        return result
    }

    func averageCurrentEpochs() {
        guard let segmentedEpochSignal, !segmentedEpochSegments.isEmpty else {
            epoching.statusMessage = "Create epochs before averaging."
            return
        }
        let shouldAvgRef = epoching.averageReference
        let shouldBaseline = epoching.baselineCorrected
        let badChannels = channels.bad
        let suffix = psaPostProcessingSuffix()
        let base = PSABuildResult(
            signal: segmentedEpochSignal,
            segments: segmentedEpochSegments,
            message: "\(segmentedEpochSegments.count) epochs"
        )
        let colorIndices = categoryColorIndices(for: base.segments.map(\.category))
        let excludedIndices = excludedBadSegmentIndices(base.segments, requiresOptIn: false)
        psaTask?.cancel()
        let sessionID = recordingSessionID
        psaTask = Task {
            let averageWorker = Task.detached(priority: .userInitiated) {
                base.average(colorIndices: colorIndices, excludedIndices: excludedIndices)
            }
            let averagedOpt = await withTaskCancellationHandler(
                operation: {
                    await averageWorker.value
                },
                onCancel: {
                    averageWorker.cancel()
                }
            )
            guard !Task.isCancelled, sessionID == recordingSessionID, let averaged = averagedOpt else {
                epoching.statusMessage = "No averages could be computed."
                return
            }
            let displayWorker = Task.detached(priority: .userInitiated) {
                averaged.postProcessed(averageReference: shouldAvgRef, baselineCorrect: shouldBaseline, badChannels: badChannels)
            }
            let display = await withTaskCancellationHandler(
                operation: {
                    await displayWorker.value
                },
                onCancel: {
                    displayWorker.cancel()
                }
            )
            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            computeAverageSNRInBackground(from: base, excludedIndices: excludedIndices, sessionID: sessionID)
            PSAAveraging.commit(
                averaged: display,
                sourceSegmentCount: base.segments.count,
                excludedSegmentCount: excludedIndices.count,
                statusMessage: appendPSAEpochDiagnostics(
                    to: averaged.message + suffix,
                    sourceSegments: base.segments,
                    skippedIndices: excludedIndices,
                    includeSkippedLabeledBadSegments: true
                ),
                epoching: epoching,
                segHealth: segHealth,
                store: recordingStore
            )
            psaTask = nil
        }
    }

    func averageEpochResult(_ result: PSABuildResult) -> PSABuildResult? {
        guard result.signal.samplingRate > 0, !result.segments.isEmpty else {
            epoching.statusMessage = "No epochs are available to average."
            return nil
        }
        let colorIndices = categoryColorIndices(for: result.segments.map(\.category))
        return result.average(colorIndices: colorIndices, excludedIndices: excludedBadSegmentIndices(result.segments, requiresOptIn: false))
    }

    /// Subtracts each epoch's pre-stimulus mean (per channel) from the whole
    /// epoch. Because this is a per-sample subtraction of a per-epoch constant,
    /// it commutes with averaging, so it can be applied to either single epochs
    /// or category averages with identical results.
    func baselineCorrectedEpochs(_ result: PSABuildResult) -> PSABuildResult {
        var data = result.signal.data
        for segment in result.segments {
            let preCount = segment.stimulusOffsetSamples
            guard preCount > 0 else { continue }   // no pre-stimulus window to use
            let preStart = segment.startSample
            let preEnd = preStart + preCount        // exclusive
            for channel in data.indices {
                guard preEnd <= data[channel].count, segment.endSample < data[channel].count else { continue }
                var sum = 0.0
                for sample in preStart..<preEnd { sum += Double(data[channel][sample]) }
                let baseline = Float(sum / Double(preCount))
                // Skip only non-finite baselines (e.g. NaN from corrupt data);
                // a baseline of exactly 0 is valid and subtracting it is a no-op.
                guard baseline.isFinite else { continue }
                for sample in segment.startSample...segment.endSample {
                    data[channel][sample] -= baseline
                }
            }
        }

        let corrected = MFFSignalData(
            signalURL: result.signal.signalURL,
            signalType: result.signal.signalType,
            numberOfChannels: result.signal.numberOfChannels,
            samplingRate: result.signal.samplingRate,
            duration: result.signal.duration,
            recordingStartTime: result.signal.recordingStartTime,
            events: result.signal.events,
            data: data,
            channelNames: result.signal.channelNames
        )
        return PSABuildResult(signal: corrected, segments: result.segments, message: result.message)
    }

    /// Applies a common-average reference to the epoch data, computed from the
    /// good (non-bad) channels. Because interpolated channels are already swapped
    /// into the epoched signal, the reference correctly uses their reconstructed
    /// values and excludes bad channels.
    func averageReferencedEpochs(_ result: PSABuildResult) -> PSABuildResult {
        let referencedData = EEGSignalFilter.averageReferenced(result.signal.data, excluding: channels.bad)
        let referenced = MFFSignalData(
            signalURL: result.signal.signalURL,
            signalType: result.signal.signalType,
            numberOfChannels: result.signal.numberOfChannels,
            samplingRate: result.signal.samplingRate,
            duration: result.signal.duration,
            recordingStartTime: result.signal.recordingStartTime,
            events: result.signal.events,
            data: referencedData,
            channelNames: result.signal.channelNames
        )
        return PSABuildResult(signal: referenced, segments: result.segments, message: result.message)
    }

    func psaPostProcessingSuffix() -> String {
        var parts: [String] = []
        if epoching.averageReference { parts.append("avg ref") }
        if epoching.baselineCorrected { parts.append("baseline corrected") }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: ", ")
    }

    /// Re-derives the displayed epochs from the raw segmented source, applying
    /// averaging and the active post-processing per the current toggles. Used when
    /// a post-processing toggle changes after epochs already exist.
    func refreshEpochDisplay() {
        guard let segmentedEpochSignal, !segmentedEpochSegments.isEmpty else { return }
        let shouldAvgRef = epoching.averageReference
        let shouldBaseline = epoching.baselineCorrected
        let badChannels = channels.bad
        let suffix = psaPostProcessingSuffix()
        let base = PSABuildResult(
            signal: segmentedEpochSignal,
            segments: segmentedEpochSegments,
            message: "\(segmentedEpochSegments.count) epochs"
        )
        let isAveraged = epoching.isAveraged
        let colorIndices = categoryColorIndices(for: base.segments.map(\.category))
        let excludedIndices = excludedBadSegmentIndices(base.segments, requiresOptIn: !isAveraged)
        psaTask?.cancel()
        let sessionID = recordingSessionID
        psaTask = Task {
            let result: PSABuildResult
            if isAveraged {
                let averageWorker = Task.detached(priority: .userInitiated) {
                    base.average(colorIndices: colorIndices, excludedIndices: excludedIndices)
                }
                let averagedOpt2 = await withTaskCancellationHandler(
                    operation: {
                        await averageWorker.value
                    },
                    onCancel: {
                        averageWorker.cancel()
                    }
                )
                guard !Task.isCancelled, sessionID == recordingSessionID, let averaged = averagedOpt2 else { return }
                result = averaged
            } else {
                result = base
            }
            let displayWorker = Task.detached(priority: .userInitiated) {
                result.postProcessed(averageReference: shouldAvgRef, baselineCorrect: shouldBaseline, badChannels: badChannels)
            }
            let display = await withTaskCancellationHandler(
                operation: {
                    await displayWorker.value
                },
                onCancel: {
                    displayWorker.cancel()
                }
            )
            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            if isAveraged {
                computeAverageSNRInBackground(from: base, excludedIndices: excludedIndices, sessionID: sessionID)
            } else {
                snrTask?.cancel()
                snrTask = nil
                epoching.isComputingAverageSNR = false
                epoching.averageSNRByCategory = [:]
            }
            epoching.epochedSignal = display.signal
            epoching.epochSegments = display.segments
            var exclusionSummary = epoching.psaExclusionSummary
            exclusionSummary.skippedLabeledBadSegments = isAveraged ? excludedIndices.count : 0
            exclusionSummary.outputSegments = display.segments.count
            epoching.psaExclusionSummary = exclusionSummary
            epoching.statusMessage = appendPSAEpochDiagnostics(
                to: result.message + suffix,
                sourceSegments: base.segments,
                skippedIndices: excludedIndices,
                includeSkippedLabeledBadSegments: isAveraged
            )
            psaTask = nil
        }
    }

    func clearEpochs() {
        // Task handles stay with the view — cancelling one is lifecycle, not
        // domain state, so it does not belong in the shared toggle.
        snrTask?.cancel()
        snrTask = nil
        PipelineStageToggles.clearEpochs(
            epoching: epoching, segHealth: segHealth, store: recordingStore
        )
    }

    func epochCategorySummaries() -> [EpochCategorySummary] {
        let grouped = Dictionary(grouping: epoching.epochSegments, by: \.category)
        return grouped.map { category, segments in
            EpochCategorySummary(
                category: category,
                count: segments.reduce(0) { $0 + $1.contributingEpochCount },
                color: epochColor(for: segments.first?.colorIndex ?? 0)
            )
        }
        .sorted { $0.category.localizedStandardCompare($1.category) == .orderedAscending }
    }

    func epochColor(for index: Int) -> Color {
        let palette: [Color] = [.green, .blue, .orange, .pink, .teal, .indigo]
        return palette[index % palette.count]
    }
}
