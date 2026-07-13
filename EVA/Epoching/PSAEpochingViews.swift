//
//  PSAEpochingViews.swift
//  EVA
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

            VStack(alignment: .leading, spacing: 8) {
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
                        categoryGroupSelectedCodes.removeAll()
                        categoryGroupName = ""
                        showsCategoryGroupPopover = true
                    } label: {
                        Label("Group…", systemImage: "plus.circle")
                    }
                    .disabled(allSummaries.isEmpty)
                    .help("Combine several event codes/labels into one pooled category for averaging.")
                    .popover(isPresented: $showsCategoryGroupPopover) {
                        categoryGroupPopover(allSummaries: allSummaries)
                    }
                }

                if allSummaries.isEmpty {
                    ContentUnavailableView(
                        epoching.segmentField == .artifact ? "No Artifacts Detected" : "No Events",
                        systemImage: epoching.segmentField == .artifact ? "waveform.path.ecg.rectangle" : "list.bullet.rectangle",
                        description: Text(epoching.segmentField == .artifact
                            ? "Enable eye blink, eye movement, or ECG/QRS detection in the Artifacts panel first."
                            : "This recording has no events to segment on.")
                    )
                    .frame(height: 120)
                } else if summaries.isEmpty {
                    ContentUnavailableView(
                        "No Matches",
                        systemImage: "magnifyingglass",
                        description: Text("No artifact types match the filter.")
                    )
                    .frame(height: 120)
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
                        }
                        .padding(10)
                    }
                    .frame(height: 160)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Pre-stimulus (s)")
                        .font(.caption.weight(.semibold))
                    TextField("Pre", value: $epoching.preStimulus, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)

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

                    Text("DIN Tolerance (s)")
                        .font(.caption.weight(.semibold))
                    let missedCount = psaMissedDINCount(events: events)
                    HStack(spacing: 8) {
                        TextField("Tolerance", value: $epoching.timingTolerance, format: .number.precision(.fractionLength(3)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .help("Maximum time between an event and a DIN marker for them to be paired. Events with no DIN within this window are skipped.")
                        if missedCount > 0 {
                            Label("\(missedCount) unmatched", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help("\(missedCount) selected event\(missedCount == 1 ? "" : "s") have no DIN within ±\(String(format: "%.3f", epoching.timingTolerance)) s and will be skipped.")
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Skip if contains artifact", isOn: $epoching.skipIfContainsArtifact)
                VStack(alignment: .leading, spacing: 7) {
                    psaArtifactRejectionRow(
                        title: "Eye Blink",
                        detail: "Default detector",
                        isOn: $epoching.skipEyeBlinks,
                        help: "Rejects epochs containing default eye blink artifact events."
                    )
                    psaArtifactRejectionRow(
                        title: "Eye Movement",
                        detail: "Default detector",
                        isOn: $epoching.skipEyeMovements,
                        help: "Rejects epochs containing default eye movement artifact events."
                    )
                    if !template.definedArtifacts.isEmpty {
                        Divider()
                            .padding(.vertical, 2)
                        ForEach(template.definedArtifacts) { artifact in
                            psaArtifactRejectionRow(
                                title: artifact.name,
                                detail: "\(artifact.events.count) events · \(artifact.type.rawValue)",
                                isOn: psaDefinedArtifactBinding(artifact.id),
                                help: "Rejects epochs containing events from this defined artifact."
                            )
                        }
                    }
                }
                .disabled(!epoching.skipIfContainsArtifact)
                .padding(.leading, 18)

                Toggle("Skip if labeled \"Bad\"", isOn: $epoching.skipIfLabeledBad)
                    .help("Excludes segments manually marked Bad in Segment Health (right-click a segment while View > Show Segment Health is on) from category averages.")

                HStack(spacing: 8) {
                    Toggle("Interpolate bad channels per epoch", isOn: $epoching.interpolatesBadChannelsPerEpoch)
                        .help("Detects channels that are only bad WITHIN a given epoch (min/max/slope/acceleration) and interpolates just that epoch, instead of leaving a transient per-trial artifact uncorrected.")
                    Button {
                        epoching.showsEpochBadChannelOptions = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!epoching.interpolatesBadChannelsPerEpoch)
                    .help("Set the min/max/slope/acceleration thresholds that define a bad channel within one epoch.")
                    .popover(isPresented: $epoching.showsEpochBadChannelOptions) {
                        epochBadChannelOptionsPopover()
                    }
                }

                Toggle("Average by category", isOn: $epoching.averageOnApply)
                Toggle("Average reference", isOn: $epoching.averageReference)
                    .help("Re-reference to the common average of the good channels (excludes bad channels, uses interpolated values).")
                Toggle("Baseline correct (pre-stimulus)", isOn: $epoching.baselineCorrected)
                    .help("Subtract each epoch's mean over the pre-stimulus interval from the whole epoch.")
            }

            if let psaStatus = epoching.statusMessage {
                Text(psaStatus)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
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
                Spacer()
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
        .frame(width: 760)
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

    /// Thresholds that define a "bad" channel WITHIN one epoch (absolute µV
    /// bounds, not the whole-recording ratio-vs-median scoring ChannelHealth
    /// uses — an epoch window is too short for a stable median).
    @ViewBuilder
    func epochBadChannelOptionsPopover() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Per-epoch bad-channel thresholds")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Min (µV)")
                        .font(.caption.weight(.semibold))
                    TextField("Min", value: $epoching.epochBadChannelThresholds.minMicrovolts, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                GridRow {
                    Text("Max (µV)")
                        .font(.caption.weight(.semibold))
                    TextField("Max", value: $epoching.epochBadChannelThresholds.maxMicrovolts, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                GridRow {
                    Text("Max slope (µV/sample)")
                        .font(.caption.weight(.semibold))
                    TextField("Slope", value: $epoching.epochBadChannelThresholds.maxSlopeMicrovoltsPerSample, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                GridRow {
                    Text("Max acceleration (µV/sample)")
                        .font(.caption.weight(.semibold))
                    TextField("Acceleration", value: $epoching.epochBadChannelThresholds.maxAccelerationMicrovoltsPerSample, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                GridRow {
                    Text("Reject epoch if bad channels >")
                        .font(.caption.weight(.semibold))
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
                        .frame(width: 70)
                        .help("Define the reject-epoch threshold as a percentage of the net's channels, or as a fixed channel count.")
                        Text(maxBadChannelCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
            }

            Text("A channel is flagged bad for an epoch if any sample falls outside min/max, or the sample-to-sample change (slope) or change-in-slope (acceleration) exceeds these limits. Flagged channels are interpolated for just that epoch — unless too many channels are bad at once, in which case the whole epoch is rejected instead (and the expensive interpolation is skipped for it).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

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

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    epoching.epochBadChannelThresholds = EpochBadChannelThresholds()
                }
            }
        }
        .padding(16)
        .frame(width: 520)
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
    func categoryGroupPopover(allSummaries: [EventSummary]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Group into Category")
                .font(.headline)
            Text("Pools the selected codes/labels into one category for averaging. Each one stays individually selectable.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Category name (e.g. \"emotional\")", text: $categoryGroupName)
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
        .padding(16)
        .frame(width: 320)
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
            && !epoching.selectedEventCodes.isEmpty
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

    private func applyPSACore(to signal: MFFSignalData, job: PSABuildJob) async {
        let sessionID = recordingSessionID
        let shouldAverage = epoching.averageOnApply
        let shouldAvgRef = epoching.averageReference
        let shouldBaseline = epoching.baselineCorrected
        let badChannels = channels.bad
        let suffix = psaPostProcessingSuffix()

        epoching.isApplying = true
        epoching.phaseMessage = "Segmenting…"
        epoching.segmentingProgress = nil

        let (progressContinuation, progressTask) = ProgressBridge.make { [self] (update: EpochBuildProgress) in
            epoching.phaseMessage = "Segmenting… (\(update.completed) of \(update.total))"
            epoching.segmentingProgress = update.fraction
        }

        let buildWorker = Task.detached(priority: .userInitiated) {
            await job.buildEpochs { completed, total in
                progressContinuation.yield(EpochBuildProgress(completed: completed, total: total))
            }
        }
        let built = await withTaskCancellationHandler(
            operation: {
                await buildWorker.value
            },
            onCancel: {
                buildWorker.cancel()
            }
        )
        progressContinuation.finish()
        progressTask.cancel()
        epoching.segmentingProgress = nil

        guard !Task.isCancelled, sessionID == recordingSessionID else {
            epoching.isApplying = false
            epoching.phaseMessage = nil
            return
        }
        guard let built else {
            epoching.isApplying = false
            epoching.phaseMessage = nil
            epoching.statusMessage = "No trials survived PSA segmentation. All candidate epochs were rejected, skipped, or out of bounds."
            return
        }

        // Captured from the RAW (pre-average) build — per-trial bad-channel
        // detection only exists at this stage; `average()`/`postProcessed()`
        // below construct fresh `PSABuildResult`s that don't carry it, so
        // relying on `finalResult.message` for this would silently lose it
        // whenever averaging is on (which `average()` always overwrites with
        // its own "N categories, N epochs averaged" message).
        let epochBadChannelCounts = built.epochBadChannelCounts
        let totalEpochsEvaluated = built.totalEpochsEvaluated
        let rejectedForTooManyBadChannels = built.rejectedForTooManyBadChannels
        let skippedBadIndices = excludedBadSegmentIndices(built.segments)
        var exclusionSummary = built.exclusionSummary

        // Keep raw epochs as source so post-processing can be toggled later.
        segmentedEpochSignal = built.signal
        segmentedEpochSegments = built.segments

        let finalResult: PSABuildResult
        let wasAveraged: Bool
        if shouldAverage {
            epoching.phaseMessage = "Averaging…"
            let colorIndices = categoryColorIndices(for: built.segments.map(\.category))
            let excludedIndices = excludedBadSegmentIndices(built.segments)
            let averageWorker = Task.detached(priority: .userInitiated) {
                built.average(colorIndices: colorIndices, excludedIndices: excludedIndices)
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
                epoching.isApplying = false
                epoching.phaseMessage = nil
                epoching.statusMessage = "No averages could be computed."
                return
            }
            epoching.phaseMessage = "Post-processing…"
            let postWorker = Task.detached(priority: .userInitiated) {
                averaged.postProcessed(averageReference: shouldAvgRef, baselineCorrect: shouldBaseline, badChannels: badChannels)
            }
            finalResult = await withTaskCancellationHandler(
                operation: {
                    await postWorker.value
                },
                onCancel: {
                    postWorker.cancel()
                }
            )
            wasAveraged = true
        } else {
            epoching.phaseMessage = "Post-processing…"
            let postWorker = Task.detached(priority: .userInitiated) {
                built.postProcessed(averageReference: shouldAvgRef, baselineCorrect: shouldBaseline, badChannels: badChannels)
            }
            finalResult = await withTaskCancellationHandler(
                operation: {
                    await postWorker.value
                },
                onCancel: {
                    postWorker.cancel()
                }
            )
            wasAveraged = false
        }

        guard !Task.isCancelled, sessionID == recordingSessionID else {
            epoching.isApplying = false
            epoching.phaseMessage = nil
            return
        }
        epoching.epochedSignal = finalResult.signal
        epoching.epochSegments = finalResult.segments
        epoching.isAveraged = wasAveraged
        enableSegmentHealthAfterSegmentationIfNeeded()
        exclusionSummary.skippedLabeledBadSegments = shouldAverage ? skippedBadIndices.count : 0
        exclusionSummary.outputSegments = finalResult.segments.count
        exclusionSummary.badChannelCount = epochBadChannelCounts.count
        epoching.psaExclusionSummary = exclusionSummary
        if wasAveraged {
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
        escalateBadChannelsIfNeeded(
            counts: epochBadChannelCounts,
            totalEpochs: totalEpochsEvaluated,
            continuousSignal: signal
        )
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
    /// and interpolates it there — reuses `interpolate(_:in:)`, so it also
    /// patches `epoching.epochedSignal` in place (see that function) rather
    /// than discarding the averages just computed. NOTE: does not patch
    /// `segmentedEpochSignal` (the pre-average raw-epoch cache) — toggling
    /// post-processing after an escalation will re-derive from the
    /// pre-escalation raw epochs. A known, narrow gap, not fixed here.
    private func escalateBadChannelsIfNeeded(
        counts: [Int: Int],
        totalEpochs: Int,
        continuousSignal: MFFSignalData
    ) {
        guard epoching.escalatesBadChannelsToGlobal, totalEpochs > 0, !counts.isEmpty else {
            epoching.escalatedChannelSummaries = []
            return
        }
        let thresholdFraction = epoching.escalationThresholdPercent / 100
        let toEscalate = counts
            .filter { Double($0.value) / Double(totalEpochs) >= thresholdFraction }
            .sorted { $0.key < $1.key }
        guard !toEscalate.isEmpty else {
            epoching.escalatedChannelSummaries = []
            return
        }

        var summaries: [String] = []
        var interpolationMessages: [String] = []
        var interpolationErrors: [String] = []
        summaries.reserveCapacity(toEscalate.count)
        interpolationMessages.reserveCapacity(toEscalate.count)
        for (channelIndex, count) in toEscalate {
            let interpolationStatus = interpolate(channelIndex, in: continuousSignal, updatesStatus: false)
            let percent = Double(count) / Double(totalEpochs) * 100
            summaries.append("Ch\(channelIndex + 1): bad in \(String(format: "%.0f", percent))% of epochs (\(count)/\(totalEpochs))")
            if interpolationStatus.isError {
                interpolationErrors.append(interpolationStatus.message)
            } else {
                interpolationMessages.append(interpolationStatus.message)
            }
        }
        epoching.escalatedChannelSummaries = summaries
        let escalatedChannels = toEscalate.map { "Ch\($0.key + 1)" }.joined(separator: ", ")
        if !interpolationMessages.isEmpty || !interpolationErrors.isEmpty {
            let combined = (interpolationMessages + interpolationErrors).joined(separator: " · ")
            channelStatusMessage = combined
            channelStatusIsError = !interpolationErrors.isEmpty
        }
        epoching.statusMessage = (epoching.statusMessage ?? "")
            + " · Escalated \(toEscalate.count) channel\(toEscalate.count == 1 ? "" : "s") to globally bad (\(escalatedChannels))."
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
        let events = allEvents.filter { epoching.selectedEventCodes.contains(psaSegmentValue(for: $0)) }
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
        return PSABuildJob(
            signal: signal,
            events: events,
            categoriesBySegmentValue: categoriesBySegmentValue,
            timingMarkersBySegmentValue: timingMarkersBySegmentValue,
            timingEventsBySegmentValue: timingEventsBySegmentValue,
            artifactEventsForRejection: artifactEventsByLabel.values.flatMap { $0 },
            artifactEventsForRejectionByLabel: artifactEventsByLabel,
            preSamples: preSamples,
            epochLength: epochLength,
            psaOffset: epoching.offset,
            sampleCount: sampleCount,
            colorIndices: categoryColorIndices(for: categoriesBySegmentValue.values.flatMap { $0 }),
            skipIfContainsArtifact: epoching.skipIfContainsArtifact && epoching.segmentField != .artifact,
            artifactRejectionLabel: psaArtifactRejectionLabel(),
            timingTolerance: epoching.timingTolerance,
            interpolatesBadChannelsPerEpoch: epoching.interpolatesBadChannelsPerEpoch,
            epochBadChannelThresholds: epoching.epochBadChannelThresholds,
            electrodePositions: electrodeGeometry?.positions ?? [:],
            globallyBadChannels: channels.bad
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
        if epoching.skipEyeBlinks {
            eventsByLabel["Eye Blink", default: []] += artifactEventsOrDetection(for: .blink, in: signal)
        }
        if epoching.skipEyeMovements {
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
            epoching.epochedSignal = display.signal
            epoching.epochSegments = display.segments
            epoching.isAveraged = true
            segHealth.clearAnalysis(hide: true, clearLabels: false)
            selectedSampleRange = nil
            dragSelectionStartSample = nil
            dragSelectionEndSample = nil
            topomapSample = nil
            epoching.butterflyTopomapRelativeSample = nil
            selectedEventCodes.removeAll()
            horizontalScrollPosition.scrollTo(x: 0)
            var exclusionSummary = epoching.psaExclusionSummary
            if exclusionSummary.acceptedEpochs == 0 {
                exclusionSummary.acceptedEpochs = base.segments.count
            }
            exclusionSummary.skippedLabeledBadSegments = excludedIndices.count
            exclusionSummary.outputSegments = display.segments.count
            epoching.psaExclusionSummary = exclusionSummary
            epoching.statusMessage = appendPSAEpochDiagnostics(
                to: averaged.message + suffix,
                sourceSegments: base.segments,
                skippedIndices: excludedIndices,
                includeSkippedLabeledBadSegments: true
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
        epoching.epochedSignal = nil
        epoching.epochSegments = []
        segmentedEpochSignal = nil
        segmentedEpochSegments = []
        epoching.isAveraged = false
        selectedSampleRange = nil
        dragSelectionStartSample = nil
        dragSelectionEndSample = nil
        topomapSample = nil
        epoching.butterflyTopomapRelativeSample = nil
        epoching.psaExclusionSummary = PSAExclusionSummary()
        epoching.averagedDisplayMode = .waveform
        epoching.showsButterflyPlot = false
        selectedEventCodes.removeAll()
        epoching.statusMessage = nil
        epoching.epochBadChannelSummary.removeAll()
        epoching.epochBadChannelAllSegmentsSummary.removeAll()
        epoching.interpolatedChannelsBySegmentSummary.removeAll()
        epoching.skippedLabeledBadSegmentsSummary.removeAll()
        segHealth.clearAnalysis(hide: true, clearLabels: true)
        horizontalScrollPosition.scrollTo(x: 0)
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
