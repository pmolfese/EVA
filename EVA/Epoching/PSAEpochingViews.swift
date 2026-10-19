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
        recordingStore.selection.matrixReviewRequest = nil
        epoching.showsDecisionMatrix = false
        epoching.decisionMatrixIsInSheet = false
        // Opening configuration is presentation only. Actual evidence inputs
        // are validated when the existing review is reopened or averaged.
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

    @ViewBuilder
    func psaSheet(for signal: MFFSignalData) -> some View {
        if epoching.decisionMatrixIsInSheet, let matrix = epoching.decisionMatrix {
            decisionMatrixReview(for: signal, model: matrix, isFloating: false)
        } else {
            psaConfigurationSheet(for: signal)
        }
    }

    @ViewBuilder
    var decisionMatrixPanelHost: some View {
        if !epoching.decisionMatrixIsInSheet, let matrix = epoching.decisionMatrix {
            let signal = continuousProcessedSignal ?? recording.signal ?? matrix.preparation.signal
            PSADecisionMatrixPanel(
                isPresented: $epoching.showsDecisionMatrix,
                title: recording.packageName
            ) {
                decisionMatrixReview(for: signal, model: matrix, isFloating: true)
            }
            .frame(width: 0, height: 0)
        }
    }

    private func decisionMatrixReview(
        for signal: MFFSignalData, model: PSADecisionMatrixModel, isFloating: Bool
    ) -> some View {
        PSADecisionMatrixView(
            model: model,
            isApplying: epoching.isApplying,
            isRunningFullChannelHealth: channels.isAnalyzingHealth || epoching.isAnalyzingDecisionMatrixChannelPrior,
            allowsFullHealthUpgrade: goodnessSettings.psaDecisionMatrixHealthStrategy == .adaptive,
            fallbackMessage: decisionMatrixFallbackMessage,
            progress: channels.isAnalyzingHealth
                ? channels.healthProgress
                : (epoching.decisionMatrixChannelPriorProgress ?? epoching.segmentingProgress),
            progressMessage: channels.isAnalyzingHealth
                ? (chanHealth.statusMessage ?? "Running full Channel Health…")
                : (epoching.decisionMatrixChannelPriorMessage ?? epoching.phaseMessage),
            onBack: { openPSASheet(for: signal) },
            onCancel: {
                epoching.showsDecisionMatrix = false
                if !isFloating {
                    epoching.showsSheet = false
                    epoching.decisionMatrixIsInSheet = false
                }
            },
            onRunFullChannelHealth: { runFullChannelHealthForDecisionMatrix(signal: signal, model: model) },
            onAverage: { averageReviewedDecisionMatrix() },
            onNavigate: { channel, epoch in
                if isFloating { navigateDecisionMatrix(channel: channel, epoch: epoch) }
            },
            isFloating: isFloating
        )
        .onAppear { ensurePreferredDecisionMatrixChannelPrior(signal: signal, model: model) }
    }

    var decisionMatrixFallbackMessage: String {
        switch goodnessSettings.psaDecisionMatrixHealthStrategy {
        case .adaptive:
            return "Full Channel Health is unavailable for this signal. Cells currently use the fast epoch scan and a robust epoch-set channel prior."
        case .fullRecording:
            return "The matrix is using its segment prior while the requested full recording suite is prepared."
        case .fastRecording:
            return "The matrix is using its segment prior while the requested fast recording suite is prepared."
        case .segmentOnly:
            return "Segment-only mode uses the abbreviated scan and each channel's median score across the epochs shown."
        }
    }

    func psaConfigurationSheet(for signal: MFFSignalData) -> some View {
        let events = segmentableEvents(for: signal)
        let allSummaries = groupedPSAEventSummaries(events)
        let summaries = filteredPSAEventSummaries(allSummaries)

        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("PSA Segmentation")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(events.count) available events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()
            HSplitView {
                psaCategoryTable(events: events, allSummaries: allSummaries, summaries: summaries)
                    .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
                psaConfigurationInspector(events: events)
                    .frame(minWidth: 380, idealWidth: 400, maxWidth: 480, maxHeight: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                // The running pipeline used to flash its accumulating audit/status
                // string here (often a long red list of bad channels and segments).
                // Keep errors available after a run stops, but do not present an
                // internal log beside the single progress indicator.
                if !epoching.isApplying, let psaStatus = epoching.statusMessage {
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
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(
            minWidth: 1060, idealWidth: 1200, maxWidth: 1700,
            minHeight: 560, idealHeight: 720, maxHeight: 1300
        )
    }

    private func psaConfigurationInspector(events: [MFFEvent]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Epoch Window")
                    .font(.headline)
                PSAEpochWindowPreview(
                    preStimulus: epoching.preStimulus,
                    postStimulus: epoching.postStimulus,
                    baselineCorrected: epoching.baselineCorrected
                )
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
                        TextField(
                            "Tolerance", value: $epoching.timingTolerance, format: .number.precision(.fractionLength(3))
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .help(
                            "Maximum time between an event and a DIN marker for them to be paired. Events with no DIN within this window are skipped."
                        )
                    }
                }

                let missedCount = psaMissedDINCount(events: events)
                if missedCount > 0 {
                    Label(
                        "\(missedCount) selected event\(missedCount == 1 ? "" : "s") with no DIN within ±\(String(format: "%.3f", epoching.timingTolerance)) s — will be skipped",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                PSAInspectorSection("Artifact Handling") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Skip epochs containing artifacts", isOn: $epoching.skipIfContainsArtifact)
                        HStack(spacing: 8) {
                            Text("Reject").foregroundStyle(.secondary)
                            Picker("Artifact rule", selection: $epoching.artifactRejectionPolicy) {
                                ForEach(PSAArtifactRejectionPolicy.allCases) { policy in
                                    Text(policy.rawValue).tag(policy)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            .disabled(!epoching.skipIfContainsArtifact)
                            Button {
                                epoching.showsArtifactRejectionOptions = true
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!epoching.skipIfContainsArtifact)
                            .accessibilityLabel("Artifact rejection options")
                            .help("Choose which artifact kinds cause an epoch to be rejected.")
                            .popover(isPresented: $epoching.showsArtifactRejectionOptions) {
                                psaArtifactRejectionOptionsPopover()
                            }
                        }

                        Toggle("Skip if labeled \"Bad\"", isOn: $epoching.skipIfLabeledBad)
                            .help(
                                "Excludes segments manually marked Bad in Segment Health (right-click a segment while View > Show Segment Health is on) from category averages."
                            )

                    }
                }
                Divider()
                PSAInspectorSection("Channel Interpolation") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Interpolate bad channels per epoch", isOn: $epoching.interpolatesBadChannelsPerEpoch)
                            .help(
                                "Detects channels that are only bad WITHIN a given epoch (min/max/slope/acceleration) and interpolates just that epoch, instead of leaving a transient per-trial artifact uncorrected."
                            )

                        epochBadChannelInlineOptions()
                            .disabled(!epoching.interpolatesBadChannelsPerEpoch)

                    }
                }
                Divider()
                PSAInspectorSection("Output", initiallyExpanded: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Average by category", isOn: $epoching.averageOnApply)
                            Toggle("Use Decision Matrix", isOn: $epoching.usesDecisionMatrix)
                                .toggleStyle(.checkbox)
                                .disabled(!epoching.averageOnApply)
                                .help(
                                    "Review channel × epoch health before averaging. Cell decisions override the automatic thresholds."
                                )
                        }
                        Toggle("Average reference", isOn: $epoching.averageReference)
                            .help(
                                "Re-reference to the common average of the good channels (excludes bad channels, uses interpolated values)."
                            )
                        Toggle("Baseline correct (pre-stimulus)", isOn: $epoching.baselineCorrected)
                            .help("Subtract each epoch's mean over the pre-stimulus interval from the whole epoch.")
                    }
                }
            }
            .toggleStyle(.checkbox)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func psaCategoryTable(
        events: [MFFEvent], allSummaries: [EventSummary], summaries: [EventSummary]
    ) -> some View {
        let rows = psaCategoryTableRows(events: events, allSummaries: allSummaries, summaries: summaries)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Events & Categories").font(.headline)
                Spacer()
                Picker(
                    "Segment On",
                    selection: Binding(
                        get: { epoching.segmentField },
                        set: {
                            epoching.segmentField = $0
                            reconcilePSAEventSelection(for: events)
                        }
                    )
                ) {
                    ForEach(PSASegmentField.allCases) { field in
                        Text(field.rawValue).tag(field)
                    }
                }
                .frame(width: 190)
            }
            .padding(16)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter events", text: $epoching.eventSearchText)
                    .textFieldStyle(.roundedBorder)
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
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Table(rows) {
                TableColumn("Event / Group") { row in
                    psaCategoryEventCell(row)
                }
                .width(min: 135, ideal: 150)
                TableColumn("Count") { row in
                    Text("\(row.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(40)
                TableColumn("Category") { row in
                    psaCategoryNameCell(row, events: events)
                }
                .width(min: 115, ideal: 140)
                TableColumn("Onset") { row in
                    psaCategoryOnsetCell(row, allSummaries: allSummaries)
                }
                .width(min: 150, ideal: 160)
                TableColumn("") { row in
                    psaCategoryRemoveCell(row)
                }
                .width(22)
            }
            .overlay {
                if allSummaries.isEmpty {
                    ContentUnavailableView(
                        epoching.segmentField == .artifact ? "No Artifacts Detected" : "No Events",
                        systemImage: epoching.segmentField == .artifact
                            ? "waveform.path.ecg.rectangle" : "list.bullet.rectangle",
                        description: Text(
                            epoching.segmentField == .artifact
                                ? "Enable eye blink, eye movement, or ECG/QRS detection in the Artifacts panel first."
                                : "This recording has no events to segment on.")
                    )
                } else if rows.isEmpty {
                    ContentUnavailableView(
                        "No Matches", systemImage: "magnifyingglass",
                        description: Text("No events match the filter."))
                }
            }

            HStack {
                Button {
                    categoryGroupMode = .codes
                    categoryGroupSelectedCodes.removeAll()
                    categoryGroupName = ""
                    categoryRegexSourceCode = ""
                    categoryRegexPattern = ""
                    categoryRegexMatchField = .description
                    showsCategoryGroupPopover = true
                } label: {
                    Label("Group…", systemImage: "plus.circle")
                }
                .disabled(allSummaries.isEmpty)
                .help(
                    "Combine several event codes/labels into one pooled category, or sub-select one code's events by a regex on their description."
                )
                .popover(isPresented: binding(recordingStore.events, \.showsCategoryGroupPopover)) {
                    categoryGroupPopover(events: events, allSummaries: allSummaries)
                }
                Spacer()
                Text(
                    "\(epoching.selectedEventCodes.count) selected · \(epoching.categoryGroups.count) groups · \(epoching.categoryRegexRules.count) regex rules"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    func psaCategoryTableRows(
        events: [MFFEvent], allSummaries: [EventSummary], summaries: [EventSummary]
    ) -> [PSACategoryTableRow] {
        var rows = summaries.map { PSACategoryTableRow(id: "event:\($0.code)", kind: .event($0), count: $0.count) }
        // Groups and regex rules remain available while filtering event codes,
        // including regex-only configurations with no source code selected.
        rows += epoching.categoryGroups.keys.sorted().map { name in
            let members = epoching.categoryGroups[name] ?? []
            let count = allSummaries.filter { members.contains($0.code) }.reduce(0) { $0 + $1.count }
            return PSACategoryTableRow(id: "group:\(name)", kind: .group(name), count: count)
        }
        rows += epoching.categoryRegexRules.keys.sorted().map { id in
            let rule = epoching.categoryRegexRules[id]
            let count =
                rule.flatMap {
                    regexMatchPreview(
                        sourceCode: $0.sourceCode, pattern: $0.pattern,
                        matchField: $0.matchField, categoryNameTemplate: $0.categoryName, events: events)
                }?.matched ?? 0
            return PSACategoryTableRow(id: "regex:\(id)", kind: .regex(id), count: count)
        }
        return rows
    }

    @ViewBuilder
    private func psaCategoryEventCell(_ row: PSACategoryTableRow) -> some View {
        switch row.kind {
        case .event(let summary):
            Toggle(isOn: psaEventCodeBinding(summary.code)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.code).font(.system(.body, design: .monospaced))
                    if let detail = summary.detail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(detail)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("Include \(summary.code)")
        case .group(let name):
            let members = epoching.categoryGroups[name] ?? []
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text("\(members.intersection(epoching.selectedEventCodes).count) of \(members.count) codes")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
            }
        case .regex(let id):
            if let rule = epoching.categoryRegexRules[id] {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.categoryName)
                        Text("\(rule.sourceCode) · \(rule.matchField.rawValue)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func psaCategoryNameCell(_ row: PSACategoryTableRow, events: [MFFEvent]) -> some View {
        switch row.kind {
        case .event(let summary):
            TextField("Category", text: psaCategoryBinding(summary.code))
                .textFieldStyle(.plain)
                .disabled(!epoching.selectedEventCodes.contains(summary.code))
                .accessibilityLabel("Category for \(summary.code)")
        case .group(let name):
            Text(name).foregroundStyle(.secondary)
                .help(
                    "Pooled category — produces averaged segments for the group in addition to each member's own category."
                )
        case .regex(let id):
            if let rule = epoching.categoryRegexRules[id] {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.pattern).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).help(rule.pattern)
                    if rule.categoryName.contains("$"),
                        let preview = regexMatchPreview(
                            sourceCode: rule.sourceCode, pattern: rule.pattern, matchField: rule.matchField,
                            categoryNameTemplate: rule.categoryName, events: events
                        ), !preview.categories.isEmpty
                    {
                        Text("→ \(regexCategoryListSummary(preview.categories))")
                            .font(.caption2)
                            .foregroundStyle(preview.categories.count <= 1 ? .orange : .secondary)
                            .lineLimit(1)
                    }
                }
                .help("Regex sub-selection — matching events are filed under this category in addition to their own.")
            }
        }
    }

    @ViewBuilder
    private func psaCategoryOnsetCell(_ row: PSACategoryTableRow, allSummaries: [EventSummary]) -> some View {
        switch row.kind {
        case .event(let summary):
            psaEventOnsetControls(summary: summary, allSummaries: allSummaries)
        case .group(let name):
            let members = epoching.categoryGroups[name] ?? []
            Toggle("DIN", isOn: psaCategoryGroupDINBinding(members: members, allSummaries: allSummaries))
                .toggleStyle(.checkbox)
                .disabled(members.intersection(epoching.selectedEventCodes).isEmpty)
                .help("Enable each member code's own nearest-marker DIN pairing, all at once.")
        case .regex(let id):
            if let rule = epoching.categoryRegexRules[id] {
                Text("From \(rule.sourceCode)").font(.caption).foregroundStyle(.secondary)
                    .help(
                        "Uses the source code's onset and DIN settings, even when that code is not individually selected."
                    )
            }
        }
    }

    @ViewBuilder
    private func psaCategoryRemoveCell(_ row: PSACategoryTableRow) -> some View {
        switch row.kind {
        case .event:
            EmptyView()
        case .group(let name):
            Button {
                epoching.categoryGroups.removeValue(forKey: name)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this group. Member codes keep their own individual categories.")
            .accessibilityLabel("Remove group \(name)")
        case .regex(let id):
            Button {
                epoching.categoryRegexRules.removeValue(forKey: id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this rule.")
            .accessibilityLabel("Remove regex rule")
        }
    }

    private func psaEventOnsetControls(summary: EventSummary, allSummaries: [EventSummary]) -> some View {
        let timingOptions = psaTimingMarkerOptions(in: allSummaries, excluding: summary.code)
        let isSelected = epoching.selectedEventCodes.contains(summary.code)
        let usesTimingMarker = epoching.timingMarkerEnabledValues.contains(summary.code)
        // A code doesn't need its own checkbox to be DIN-eligible — a
        // `CategoryRegexRule` sourced from it needs the same nearest-marker
        // correction its own events would get, so DIN stays enabled whenever
        // this code feeds a regex rule too, even with the plain category off.
        let isRegexSource = epoching.categoryRegexRules.values.contains { $0.sourceCode == summary.code }
        let isDINEligible = isSelected || isRegexSource

        return HStack(spacing: 6) {
            Toggle("DIN", isOn: psaTimingMarkerEnabledBinding(summary.code, options: timingOptions))
                .toggleStyle(.checkbox)
                .disabled(!isDINEligible || timingOptions.isEmpty)
                .help(
                    isSelected || !isRegexSource
                        ? "Use the nearest selected timing marker as this category's onset."
                        : "This code isn't selected on its own, but feeds a regex category below — DIN still applies to that category's onset."
                )

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
            .frame(maxWidth: .infinity)
            .disabled(!isDINEligible || !usesTimingMarker || timingOptions.isEmpty)
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
        // Threshold ocular detections are also materialized as DefinedArtifact
        // records for review/correction. They are the same source as the two
        // detector toggles above, not additional rejection classes, so showing
        // them again here was both visually confusing and could double-count
        // their events. Keep genuinely user-defined artifact classes only.
        let definedArtifacts = template.definedArtifacts.filter {
            !ArtifactReviewEngine.isThresholdFamily($0)
        }
        let mriUnreliableCount = psaUnreliableMRIEvents(
            in: continuousProcessedSignal ?? recording.signal
        ).count
        // Offered once a correction has run — even one that marked nothing, so
        // the choice can be made before it matters — or when the file already
        // carries spans from an earlier export.
        let hasMRI = gradient.isActive || mriUnreliableCount > 0
        let hasAny = hasBlink || hasMovement || hasMRI || !definedArtifacts.isEmpty
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
                        if hasMRI {
                            psaArtifactRejectionRow(
                                title: GradientCoverage.unreliableEventLabel,
                                detail: "\(mriUnreliableCount) span\(mriUnreliableCount == 1 ? "" : "s") · MRI gradient",
                                isOn: $epoching.skipUnreliableMRI,
                                help: "Rejects epochs that overlap a stretch the MRI gradient correction could not be trusted on (\(GradientCoverage.unreliableEventCode)): epochs left uncorrected with no usable donors or an empty template, or corrected from donors across a motion event."
                            )
                        }
                        if !definedArtifacts.isEmpty {
                            if hasBlink || hasMovement || hasMRI {
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
            matchField: categoryRegexMatchField,
            categoryNameTemplate: categoryGroupName,
            events: events
        )
        let patternIsValid = !categoryRegexPattern.isEmpty && preview != nil

        Text("Sub-selects the events of ONE code whose description or label matches a pattern into a new category, in addition to that event's own category.")
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

        Text("Match against")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

        Picker("Match against", selection: binding(recordingStore.events, \.categoryRegexMatchField)) {
            ForEach(CategoryRegexMatchField.allCases) { field in
                Text(field.rawValue).tag(field)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)

        HStack {
            Text("Pattern (applied to \(categoryRegexMatchField.rawValue.lowercased()) field)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(RegexPatternPreset.library) { preset in
                    Button {
                        categoryRegexPattern = preset.pattern
                    } label: {
                        Text(preset.title)
                    }
                    .help("\(preset.pattern) — \(preset.example)")
                }
            } label: {
                Label("Examples", systemImage: "list.bullet.rectangle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pick a common pattern shape to start from, then tweak it and check the preview below.")
        }
        TextField("e.g. cond=(\\d+)_correct", text: binding(recordingStore.events, \.categoryRegexPattern))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))

        if categoryRegexPattern.isEmpty, !categoryRegexSourceCode.isEmpty,
           let suggestion = RegexPatternSuggester.suggest(
               from: regexSourceTexts(sourceCode: categoryRegexSourceCode, matchField: categoryRegexMatchField, events: events)
           ) {
            Button {
                categoryRegexPattern = suggestion.pattern
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggested: \(suggestion.pattern)")
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.semibold)
                        Text(suggestion.rationale)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(8)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .help("Inferred from this code's own \(categoryRegexMatchField.rawValue.lowercased())s — tap to use it, then edit as needed.")
        }

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

        let groupCount = captureGroupCount(in: categoryRegexPattern)

        HStack {
            Text("New category name")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if groupCount > 0 {
                HStack(spacing: 4) {
                    Text("Insert:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(1...groupCount, id: \.self) { index in
                        Button("$\(index)") {
                            categoryGroupName += "$\(index)"
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .font(.system(.caption2, design: .monospaced))
                        .help("Append $\(index) (this pattern's capture group \(index)) to the category name.")
                    }
                }
            }
        }
        TextField("e.g. \"emotional\" or \"n2_$1\"", text: binding(recordingStore.events, \.categoryGroupName))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .help("Use $1, $2, … to reference the pattern's capture groups — one rule then fans out into a category per captured value instead of needing a separate rule for each.")

        if categoryGroupName.isEmpty, !categoryRegexSourceCode.isEmpty, !categoryRegexPattern.isEmpty,
           let templateSuggestion = CategoryTemplateSuggester.suggest(
               pattern: categoryRegexPattern,
               samples: regexSourceTexts(sourceCode: categoryRegexSourceCode, matchField: categoryRegexMatchField, events: events)
           ) {
            Button {
                categoryGroupName = templateSuggestion.template
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggested: \(templateSuggestion.template)")
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.semibold)
                        Text(templateSuggestion.rationale)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(8)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .help("Inferred from what this pattern's capture group(s) actually match — tap to use it, then edit as needed.")
        }

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

    /// Raw description/label values for `sourceCode`'s own events — feeds
    /// `RegexPatternSuggester`, which diffs these to infer a starting pattern.
    private func regexSourceTexts(sourceCode: String, matchField: CategoryRegexMatchField, events: [MFFEvent]) -> [String] {
        events
            .filter { $0.code == sourceCode }
            .compactMap { matchField == .label ? $0.label : $0.eventDescription }
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
        matchField: CategoryRegexMatchField,
        categoryNameTemplate: String,
        events: [MFFEvent]
    ) -> (matched: Int, total: Int, samples: [(description: String, category: String)], categories: [String])? {
        guard !sourceCode.isEmpty, !pattern.isEmpty else { return nil }
        guard let regex = try? Regex(pattern).ignoresCase() else { return nil }
        let rule = CategoryRegexRule(sourceCode: sourceCode, pattern: pattern, matchField: matchField, categoryName: categoryNameTemplate)
        let codeEvents = events.filter { $0.code == sourceCode }
        var matchedCount = 0
        var exampleByCategory: [String: String] = [:]
        for event in codeEvents {
            let matchText = matchField == .label ? event.label : event.eventDescription
            guard let matchText,
                  let match = matchText.firstMatch(of: regex) else { continue }
            matchedCount += 1
            let category = rule.resolvedCategoryName(for: match)
            if exampleByCategory[category] == nil {
                exampleByCategory[category] = matchText
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
        let rule = CategoryRegexRule(sourceCode: categoryRegexSourceCode, pattern: pattern, matchField: categoryRegexMatchField, categoryName: name)
        epoching.categoryRegexRules[rule.id.uuidString] = rule
        showsCategoryGroupPopover = false
        categoryRegexSourceCode = ""
        categoryRegexPattern = ""
        categoryRegexMatchField = .description
        categoryGroupName = ""
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
            && epoching.hasSegmentSelection
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
        epoching.epochBadChannelSegments = result.epochBadChannelSegments
        epoching.epochNonArtifactRejectionReasons = result.suggestedRejectedEpochReasons.compactMapValues { reasons in
            let retained = reasons.filter {
                $0 == "Missing timing marker" || $0 == "Too many bad channels"
            }
            return retained.isEmpty ? nil : retained
        }
        epoching.epochBadChannelSummary = result.epochBadChannelCounts.keys.sorted().map {
            "Ch\($0 + 1) (\(result.epochBadChannelCounts[$0] ?? 0) of \(result.totalEpochsEvaluated) epochs)"
        }
        epoching.epochBadChannelAllSegmentsSummary = result.epochBadChannelsInAllAcceptedSegments.map {
            "Ch\($0 + 1)"
        }
        let affectedSegments = result.interpolatedChannelSegments.isEmpty
            ? result.epochBadChannelSegments
            : result.interpolatedChannelSegments
        epoching.interpolatedChannelsBySegmentSummary = affectedSegments.keys.sorted().map { channel in
            let segments = affectedSegments[channel, default: []]
                .map(String.init)
                .joined(separator: ",")
            return "Ch\(channel + 1)(\(segments))"
        }
    }

    /// Re-evaluates artifact rejection against the source times carried by the
    /// saved epochs. This is shared by the immediate and "Average Current
    /// Epochs" paths, so changing the PSA artifact selection or its partial-
    /// epoch window has exactly the same effect in either workflow.
    func psaArtifactRejectionReasons(
        for segments: [EpochSegment],
        sourceSignal: MFFSignalData
    ) -> [Int: [String]] {
        let groups = psaArtifactEventsForRejectionByLabel(in: sourceSignal)
        guard !groups.isEmpty, sourceSignal.samplingRate > 0 else { return [:] }
        let samplingRate = sourceSignal.samplingRate
        var reasons: [Int: [String]] = [:]
        for (index, segment) in segments.enumerated() {
            let epochStart = -Double(segment.stimulusOffsetSamples) / samplingRate
            let epochEnd = Double(segment.endSample - segment.startSample + 1 - segment.stimulusOffsetSamples) / samplingRate
            let relativeWindow = epoching.effectiveArtifactRejectionWindow ?? epochStart...epochEnd
            let start = segment.sourceTimeSeconds + relativeWindow.lowerBound
            let end = segment.sourceTimeSeconds + relativeWindow.upperBound
            let matched = groups.compactMap { label, events in
                events.contains { $0.overlaps(startSeconds: start, endSeconds: end) }
                    ? label : nil
            }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if !matched.isEmpty { reasons[index] = matched }
        }
        return reasons
    }

    func psaDecisionMatrixRejectionReasons(
        for segments: [EpochSegment],
        sourceSignal: MFFSignalData
    ) -> [Int: [String]] {
        var result = epoching.epochNonArtifactRejectionReasons
        for (index, artifactReasons) in psaArtifactRejectionReasons(
            for: segments,
            sourceSignal: sourceSignal
        ) {
            result[index, default: []].append(contentsOf: artifactReasons)
        }
        return result.mapValues { Array(Set($0)).sorted() }
    }

    /// Compact, event-aware cleaning context for the matrix. Cleaning method
    /// and RMS evidence live once on the artifact summary; each epoch receives
    /// only the overlapping event details it needs to draw and explain.
    func psaArtifactEventDetails(
        for segments: [EpochSegment],
        sourceSignal: MFFSignalData
    ) -> [Int: [PSAArtifactEventDetail]] {
        guard sourceSignal.samplingRate > 0 else { return [:] }
        let cleaningIsActive = artifactVM.cleaningIsEnabled && artifactVM.cleanedSignal != nil
        let summaries = Dictionary(uniqueKeysWithValues: artifactVM.cleaningSummaries.map { ($0.artifactID, $0) })
        var catalog: [(event: MFFEvent, label: String, summary: ArtifactCleaningSummary?)] = []
        var definedEventIDs = Set<String>()
        for artifact in template.definedArtifacts {
            let summary = summaries[artifact.id]
            for event in artifact.events {
                definedEventIDs.insert(event.id)
                catalog.append((event, artifact.name, summary))
            }
        }
        for event in artifactVM.events where !definedEventIDs.contains(event.id) {
            let label: String
            switch event.code {
            case EyeArtifactKind.blink.eventCode: label = "Eye Blink"
            case EyeArtifactKind.movement.eventCode: label = "Eye Movement"
            default: label = event.code
            }
            catalog.append((event, label, nil))
        }

        var result: [Int: [PSAArtifactEventDetail]] = [:]
        for (index, segment) in segments.enumerated() {
            let epochStart = segment.sourceTimeSeconds
                - Double(segment.stimulusOffsetSamples) / sourceSignal.samplingRate
            let epochEnd = epochStart
                + Double(segment.endSample - segment.startSample + 1) / sourceSignal.samplingRate
            let details = catalog.compactMap { item -> PSAArtifactEventDetail? in
                guard item.event.overlaps(startSeconds: epochStart, endSeconds: epochEnd) else { return nil }
                let hasCorrection = item.summary?.correctedEventIDs.contains(item.event.id) == true
                let corrected = cleaningIsActive && hasCorrection
                return PSAArtifactEventDetail(
                    eventID: item.event.id,
                    label: item.label,
                    code: item.event.code,
                    relativeTimeSeconds: item.event.centerTimeSeconds - segment.sourceTimeSeconds,
                    hasCorrection: hasCorrection,
                    isCorrected: corrected,
                    method: hasCorrection ? item.summary?.method.rawValue : nil,
                    inputRMSMicrovolts: hasCorrection ? item.summary?.inputRMSMicrovolts : nil,
                    outputRMSMicrovolts: hasCorrection ? item.summary?.outputRMSMicrovolts : nil,
                    rmsChangeFraction: hasCorrection ? item.summary?.rmsChangeFraction : nil
                )
            }.sorted { $0.relativeTimeSeconds < $1.relativeTimeSeconds }
            if !details.isEmpty { result[index] = details }
        }
        return result
    }

    /// Uses the same Segment Health engine and settings as the normal health
    /// band. A matching completed analysis is reused; otherwise it is computed
    /// once and published to the ordinary Segment Health UI as well as the
    /// Decision Matrix.
    func decisionMatrixSegmentHealthScores(
        signal: MFFSignalData,
        segments: [EpochSegment],
        progressRange: ClosedRange<Double>
    ) async -> [Int] {
        let inputs = SegmentHealthAnalyzer.analysisSegments(for: signal, epochSegments: segments)
        guard !inputs.isEmpty else { return [Int](repeating: 100, count: segments.count) }
        let signature = segmentHealthSignature(for: signal)
        let expectedIDs = inputs.map(\.segmentID)
        let analysis: SegmentHealthAnalysis
        if segHealth.signature == signature,
           let cached = segHealth.analysis,
           cached.results.map(\.segmentID) == expectedIDs {
            analysis = cached
        } else {
            let excludedChannels = channels.bad
            let artifacts = segmentHealthArtifactAssessment(for: signal)
            let settings = segmentGoodnessSettings.base
            let (progressContinuation, progressTask) = ProgressBridge.make { [weak epoching = epoching] (fraction: Double) in
                epoching?.phaseMessage = "Scoring Segment Health…"
                let bounded = min(max(fraction, 0), 1)
                epoching?.segmentingProgress = progressRange.lowerBound
                    + (progressRange.upperBound - progressRange.lowerBound) * bounded
            }
            let worker = Task.detached(priority: .userInitiated) {
                SegmentHealthAnalyzer.analyze(
                    signal: signal,
                    segments: inputs,
                    excludedChannelIndices: excludedChannels,
                    artifacts: artifacts,
                    base: settings,
                    progress: { progressContinuation.yield($0) }
                )
            }
            analysis = await withTaskCancellationHandler(
                operation: { await worker.value },
                onCancel: { worker.cancel(); progressContinuation.finish() }
            )
            progressContinuation.finish()
            progressTask.cancel()
            guard !Task.isCancelled else { return [Int](repeating: 100, count: segments.count) }
            segHealth.signature = signature
            segHealth.analysis = analysis
            segHealth.progress = 1
            segHealth.isAnalyzing = false
            segHealth.statusMessage = "Segment health scored \(analysis.results.count) segments."
            if processingDefaults.autoRunSegmentHealthAfterSegmentation {
                segHealth.shows = true
                segHealth.showsDetails = false
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: analysis.results.map { ($0.segmentID, $0.goodPercentage) })
        epoching.segmentingProgress = progressRange.upperBound
        return inputs.map { byID[$0.segmentID] ?? 100 }
    }

    func applySegmentHealthLabels(to model: PSADecisionMatrixModel, segments: [EpochSegment]) {
        for (index, segment) in segments.enumerated() {
            switch segHealth.qualityLabels[SegmentHealthAnalyzer.segmentID(index: index, segment: segment)] {
            case .good: model.trustEpochHealth(index)
            case .bad: model.suggestEpochRejection(index, reason: "Labeled Bad")
            case nil: break
            }
        }
    }

    /// Artifact/window selections change decisions, not waveform evidence.
    /// Refresh this inexpensive context on reuse without rerunning either
    /// Segment Health or the channel-in-epoch scan. Explicit edits stay intact.
    func refreshDecisionMatrixRejectionContext(
        _ model: PSADecisionMatrixModel,
        segments: [EpochSegment], sourceSignal: MFFSignalData
    ) {
        let settings = epoching.decisionMatrixRejectionSettings
        guard model.psaRejectionSettings != settings else { return }
        var reasons = psaDecisionMatrixRejectionReasons(for: segments, sourceSignal: sourceSignal)
        for (index, segment) in segments.enumerated() {
            switch segHealth.qualityLabels[SegmentHealthAnalyzer.segmentID(index: index, segment: segment)] {
            case .good:
                if !model.trustedEpochHealth.contains(index) { model.trustEpochHealth(index) }
            case .bad:
                reasons[index, default: []].append("Labeled Bad")
            case nil:
                break
            }
        }
        for excluded in epoching.resolvedTrialExclusion(for: segments)?.excludedIndices ?? [] {
            reasons[excluded, default: []].append("Previously excluded")
        }
        reasons = reasons.compactMapValues { entries in
            entries.isEmpty ? nil : Array(Set(entries)).sorted()
        }
        if model.suggestedRejectedEpochReasons != reasons {
            model.suggestedRejectedEpochReasons = reasons
        }
        model.psaRejectionSettings = settings
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
        if let resolution = epoching.trialExclusionResolution {
            let count = resolution.excludedIndices.count
            if count > 0 {
                clauses.append("\(count) reviewed trial\(count == 1 ? "" : "s") excluded")
            }
            // Loud, and not merely a count: the average on screen is not the one
            // that was reviewed, and the operator is the only one who can decide
            // whether that matters.
            if !resolution.unresolved.isEmpty {
                clauses.append("\(resolution.unresolved.count) reviewed exclusion\(resolution.unresolved.count == 1 ? "" : "s") no longer match any trial — re-review before trusting this average")
            }
            if !resolution.movedIndices.isEmpty {
                clauses.append("\(resolution.movedIndices.count) reviewed trial\(resolution.movedIndices.count == 1 ? "" : "s") renumbered since review")
            }
        }
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
        let pausesForDecisionMatrix = epoching.defersPSADecisionsForReview
        let reviewInSheet = epoching.presentsPSADecisionMatrixSheet
        epoching.showsDecisionMatrix = false
        epoching.decisionMatrixIsInSheet = reviewInSheet
        epoching.decisionMatrix = nil
        let shouldAverage = epoching.averageOnApply && !pausesForDecisionMatrix
        let badChannels = channels.bad
        let suffix = psaPostProcessingSuffix()

        guard let outcome = await epoching.buildAndPostProcess(
            job: job,
            shouldAverage: shouldAverage,
            averageReference: epoching.averageReference,
            baselineCorrect: epoching.baselineCorrected,
            badChannels: badChannels,
            excludedSegmentIndices: { [self] segments in excludedBadSegmentIndices(segments) },
            isCurrent: { [self] in sessionID == recordingSessionID },
            progressRange: pausesForDecisionMatrix ? 0...0.30 : 0...1
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
        epoching.foldTrialExclusion(
            outcome.trialExclusion,
            step: epoching.committedTrialExclusion,
            segments: built.segments,
            into: &exclusionSummary
        )

        // Keep raw epochs as source so post-processing can be toggled later.
        segmentedEpochSignal = built.signal
        segmentedEpochSegments = built.segments

        if outcome.wasAveraged {
            // SNR is measured from the RAW single trials, but it does NOT block
            // closing the sheet — the user sees their average right away and the
            // Averages workspace shows a spinner until SNR lands.
            computeAverageSNRInBackground(
                from: built,
                // Every trial the average dropped, reviewed exclusions
                // included — SNR measured over trials that are not in the
                // average describes an average nobody has.
                excludedIndices: outcome.excludedSegmentIndices,
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
        // Decision Matrix preparation below computes/publishes the regular
        // Segment Health result itself. Starting the ordinary auto-run here as
        // well produced two competing scans over the same epochs.
        if !pausesForDecisionMatrix {
            enableSegmentHealthAfterSegmentationIfNeeded()
        }
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

        if pausesForDecisionMatrix {
            epoching.phaseMessage = "Scoring Segment Health…"
            let thresholds = epoching.epochBadChannelThresholds
            let detectorSegments = built.epochBadChannelSegments
            let strategy = goodnessSettings.psaDecisionMatrixHealthStrategy
            // A valid full run is always the best recording-wide prior, even
            // when the saved fallback preference is Fast recording. Previously
            // Fast ignored this cache and could make two poor core metrics look
            // disproportionately severe (notably on VREF).
            let hasCurrentFullHealth = strategy != .segmentOnly
                && chanHealth.signature == channelHealthSignature(for: signal)
                && channels.healthResults.count >= signal.numberOfChannels
            let fastPriorSignature = decisionMatrixFastChannelPriorSignature(for: signal)
            let hasCurrentFastHealth = strategy == .fastRecording
                && epoching.decisionMatrixFastChannelPriorSignature == fastPriorSignature
                && epoching.decisionMatrixFastChannelGoodness.count >= signal.numberOfChannels
            var recordingGoodness = hasCurrentFullHealth
                ? channels.healthResults.mapValues(\.goodPercentage)
                : (hasCurrentFastHealth ? epoching.decisionMatrixFastChannelGoodness : [:])
            var usesFastRecordingPrior = hasCurrentFastHealth && !hasCurrentFullHealth
            var healthProgressRange: ClosedRange<Double> = 0.30...0.50
            var scanProgressStart = 0.50
            if strategy == .fastRecording && !hasCurrentFullHealth && !hasCurrentFastHealth {
                recordingGoodness = await decisionMatrixFastRecordingGoodness(
                    signal: signal,
                    progressRange: 0.30...0.45
                )
                usesFastRecordingPrior = !recordingGoodness.isEmpty
                healthProgressRange = 0.45...0.60
                scanProgressStart = 0.60
            }
            let preparedRecordingGoodness = recordingGoodness
            let preparedUsesFastRecordingPrior = usesFastRecordingPrior
            let preparedScanProgressStart = scanProgressStart
            let baseSettings = goodnessSettings.base
            let positions = electrodeGeometry?.positions ?? [:]
            let globallyBad = channels.bad
            let shouldAverageReference = epoching.averageReference
            let shouldBaselineCorrect = epoching.baselineCorrected
            let segmentHealthScores = await decisionMatrixSegmentHealthScores(
                signal: finalResult.signal,
                segments: built.segments,
                progressRange: healthProgressRange
            )
            guard !Task.isCancelled, sessionID == recordingSessionID else {
                epoching.isApplying = false
                epoching.phaseMessage = nil
                return
            }
            let rejectionReasons = psaDecisionMatrixRejectionReasons(
                for: built.segments,
                sourceSignal: signal
            )
            let artifactDetails = psaArtifactEventDetails(for: built.segments, sourceSignal: signal)
            let (progressContinuation, progressTask) = ProgressBridge.make { [weak epoching = epoching] (update: EpochBuildProgress) in
                epoching?.phaseMessage = "Scanning channel-in-epoch evidence… (\(update.completed) of \(update.total))"
                epoching?.segmentingProgress = preparedScanProgressStart
                    + (1 - preparedScanProgressStart) * update.fraction
            }
            let preparationWorker = Task.detached(priority: .userInitiated) {
                PSADecisionMatrixPreparation.make(
                    signal: built.signal,
                    segments: built.segments,
                    thresholds: thresholds,
                    detectorSegments: detectorSegments,
                    recordingChannelGoodness: preparedRecordingGoodness,
                    baseSettings: baseSettings,
                    electrodePositions: positions,
                    globallyBadChannels: globallyBad,
                    averageReference: shouldAverageReference,
                    baselineCorrect: shouldBaselineCorrect,
                    segmentHealthGoodnessScores: segmentHealthScores,
                    suggestedRejectedEpochReasons: rejectionReasons,
                    artifactEventsByEpoch: artifactDetails,
                    progress: { completed, total in
                        progressContinuation.yield(EpochBuildProgress(completed: completed, total: total))
                    }
                )
            }
            let preparation = await withTaskCancellationHandler(
                operation: { await preparationWorker.value },
                onCancel: { preparationWorker.cancel() }
            )
            progressContinuation.finish()
            progressTask.cancel()
            epoching.segmentingProgress = nil
            guard !Task.isCancelled, sessionID == recordingSessionID else {
                epoching.isApplying = false
                epoching.phaseMessage = nil
                return
            }
            let matrix = PSADecisionMatrixModel(preparation: preparation)
            matrix.recordingInterpolatedChannels = Set(channels.interpolated.keys)
            if preparedUsesFastRecordingPrior && !hasCurrentFullHealth {
                matrix.adoptRecordingChannelGoodness(preparedRecordingGoodness, kind: .fastRecording)
            }
            applySegmentHealthLabels(to: matrix, segments: built.segments)
            for excluded in epoching.resolvedTrialExclusion(for: built.segments)?.excludedIndices ?? [] {
                matrix.suggestEpochRejection(excluded, reason: "Previously excluded")
            }
            epoching.decisionMatrix = matrix
            matrix.psaRejectionSettings = epoching.decisionMatrixRejectionSettings
            epoching.decisionMatrixNeedsRefresh = false
            epoching.showsSheet = reviewInSheet
            epoching.showsDecisionMatrix = !reviewInSheet
            epoching.statusMessage = "Review all epochs in the Decision Matrix. Rejected trials remain visible and are excluded only when averaging."
            epoching.isApplying = false
            epoching.phaseMessage = nil
            return
        }

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
            defersBadChannelDecisions: epoching.defersPSADecisionsForReview,
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
        let correctedIDs: Set<String> = artifactVM.cleaningIsEnabled && artifactVM.cleanedSignal != nil
            && epoching.artifactRejectionPolicy == .uncorrected
            ? Set(artifactVM.cleaningSummaries.flatMap(\.correctedEventIDs))
            : []
        func eligible(_ events: [MFFEvent]) -> [MFFEvent] {
            correctedIDs.isEmpty ? events : events.filter { !correctedIDs.contains($0.id) }
        }
        // Only reject on eye artifacts whose detector was actually enabled/run —
        // matching what the rejection popover offers. A disabled detector has no
        // events, so it must not trigger on-the-fly detection here.
        if epoching.skipEyeBlinks, detectsEyeBlinkArtifacts {
            eventsByLabel["Eye Blink", default: []] += eligible(artifactEventsOrDetection(for: .blink, in: signal))
        }
        if epoching.skipEyeMovements, detectsEyeMovementArtifacts {
            eventsByLabel["Eye Movement", default: []] += eligible(artifactEventsOrDetection(for: .movement, in: signal))
        }
        for artifact in template.definedArtifacts
        where !ArtifactReviewEngine.isThresholdFamily(artifact)
            && epoching.skippedDefinedArtifactIDs.contains(artifact.id) {
            eventsByLabel[artifact.name, default: []] += eligible(artifact.events)
        }
        if epoching.skipUnreliableMRI {
            eventsByLabel[GradientCoverage.unreliableEventLabel, default: []] += psaUnreliableMRIEvents(in: signal)
        }

        return eventsByLabel.filter { !$0.value.isEmpty }
    }

    /// The gradient correction's unreliable spans carried on `signal` — they
    /// ride on the corrected signal's events, so every downstream stage (and an
    /// exported, reopened file) still has them.
    func psaUnreliableMRIEvents(in signal: MFFSignalData?) -> [MFFEvent] {
        signal?.events.filter { $0.code == GradientCoverage.unreliableEventCode } ?? []
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
        return artifactEvents.contains { $0.overlaps(startSeconds: startSeconds, endSeconds: endSeconds) }
    }

    func psaArtifactRejectionLabel() -> String {
        var labels: [String] = []
        if epoching.skipEyeBlinks {
            labels.append("eye blinks")
        }
        if epoching.skipEyeMovements {
            labels.append("eye movements")
        }
        if epoching.skipUnreliableMRI, gradient.isActive {
            labels.append("unreliable MRI correction")
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

    func averageCurrentEpochs(reviewInSheet: Bool = false) {
        guard let segmentedEpochSignal, !segmentedEpochSegments.isEmpty else {
            epoching.statusMessage = "Create epochs before averaging."
            return
        }
        epoching.decisionMatrixIsInSheet = reviewInSheet
        if !epoching.decisionMatrixNeedsRefresh,
           let matrix = epoching.decisionMatrix,
           matrix.preparation.matchesCurrentReviewInputs(
               signal: segmentedEpochSignal, segments: segmentedEpochSegments,
               averageReference: epoching.averageReference,
               baselineCorrect: epoching.baselineCorrected,
               globallyBadChannels: channels.bad, thresholds: epoching.epochBadChannelThresholds
           ) {
            refreshDecisionMatrixRejectionContext(
                matrix, segments: segmentedEpochSegments,
                sourceSignal: continuousProcessedSignal ?? recording.signal ?? segmentedEpochSignal
            )
            epoching.showsSheet = reviewInSheet
            epoching.showsDecisionMatrix = !reviewInSheet
            showDecisionMatrixSourceEpochs()
            return
        }
        let previousMatrix = epoching.decisionMatrix
        epoching.showsDecisionMatrix = false
        epoching.decisionMatrix = nil
        psaTask?.cancel()
        let sessionID = recordingSessionID
        let thresholds = epoching.epochBadChannelThresholds
        let strategy = goodnessSettings.psaDecisionMatrixHealthStrategy
        let sourceForChannelPrior = continuousProcessedSignal ?? recording.signal ?? segmentedEpochSignal
        let hasCurrentFullHealth = strategy != .segmentOnly
            && chanHealth.signature == channelHealthSignature(for: sourceForChannelPrior)
            && channels.healthResults.count >= segmentedEpochSignal.numberOfChannels
        let fastPriorSignature = decisionMatrixFastChannelPriorSignature(for: sourceForChannelPrior)
        let hasCurrentFastHealth = strategy == .fastRecording
            && epoching.decisionMatrixFastChannelPriorSignature == fastPriorSignature
            && epoching.decisionMatrixFastChannelGoodness.count >= segmentedEpochSignal.numberOfChannels
        let initialRecordingGoodness = hasCurrentFullHealth
            ? channels.healthResults.mapValues(\.goodPercentage)
            : (hasCurrentFastHealth ? epoching.decisionMatrixFastChannelGoodness : [:])
        let baseSettings = goodnessSettings.base
        let positions = electrodeGeometry?.positions ?? [:]
        let globallyBad = channels.bad
        let detectorSegments = epoching.epochBadChannelSegments
        let sourceSegments = segmentedEpochSegments
        let shouldAverageReference = epoching.averageReference
        let shouldBaselineCorrect = epoching.baselineCorrected
        let artifactSourceSignal = continuousProcessedSignal ?? recording.signal ?? segmentedEpochSignal
        epoching.isApplying = true
        epoching.phaseMessage = "Scoring Segment Health…"
        epoching.segmentingProgress = 0
        epoching.showsSheet = true
        psaTask = Task {
            var recordingGoodness = initialRecordingGoodness
            var usesFastRecordingPrior = hasCurrentFastHealth && !hasCurrentFullHealth
            var healthProgressRange: ClosedRange<Double> = 0...0.25
            var scanProgressStart = 0.25
            if strategy == .fastRecording && !hasCurrentFullHealth && !hasCurrentFastHealth {
                recordingGoodness = await decisionMatrixFastRecordingGoodness(
                    signal: sourceForChannelPrior,
                    progressRange: 0...0.20
                )
                usesFastRecordingPrior = !recordingGoodness.isEmpty
                healthProgressRange = 0.20...0.40
                scanProgressStart = 0.40
            }
            let preparedRecordingGoodness = recordingGoodness
            let preparedUsesFastRecordingPrior = usesFastRecordingPrior
            let preparedScanProgressStart = scanProgressStart
            let healthSignalWorker = Task.detached(priority: .userInitiated) {
                PSABuildResult(
                    signal: segmentedEpochSignal,
                    segments: sourceSegments,
                    message: "Current epochs"
                ).postProcessed(
                    averageReference: shouldAverageReference,
                    baselineCorrect: shouldBaselineCorrect,
                    badChannels: globallyBad
                ).signal
            }
            let healthSignal = await healthSignalWorker.value
            let segmentHealthScores = await decisionMatrixSegmentHealthScores(
                signal: healthSignal,
                segments: sourceSegments,
                progressRange: healthProgressRange
            )
            let rejectionReasons = psaDecisionMatrixRejectionReasons(
                for: sourceSegments,
                sourceSignal: artifactSourceSignal
            )
            let artifactDetails = psaArtifactEventDetails(
                for: sourceSegments,
                sourceSignal: artifactSourceSignal
            )
            let (progressContinuation, progressTask) = ProgressBridge.make { [weak epoching = epoching] (update: EpochBuildProgress) in
                epoching?.phaseMessage = "Scanning channel-in-epoch evidence… (\(update.completed) of \(update.total))"
                epoching?.segmentingProgress = preparedScanProgressStart
                    + (1 - preparedScanProgressStart) * update.fraction
            }
            let worker = Task.detached(priority: .userInitiated) {
                return PSADecisionMatrixPreparation.make(
                    signal: segmentedEpochSignal,
                    segments: sourceSegments,
                    thresholds: thresholds,
                    detectorSegments: detectorSegments,
                    recordingChannelGoodness: preparedRecordingGoodness,
                    baseSettings: baseSettings,
                    electrodePositions: positions,
                    globallyBadChannels: globallyBad,
                    averageReference: shouldAverageReference,
                    baselineCorrect: shouldBaselineCorrect,
                    segmentHealthGoodnessScores: segmentHealthScores,
                    suggestedRejectedEpochReasons: rejectionReasons,
                    artifactEventsByEpoch: artifactDetails,
                    progress: { completed, total in
                        progressContinuation.yield(EpochBuildProgress(completed: completed, total: total))
                    }
                )
            }
            let preparation = await withTaskCancellationHandler(
                operation: { await worker.value },
                onCancel: { worker.cancel() }
            )
            progressContinuation.finish()
            progressTask.cancel()
            epoching.segmentingProgress = nil
            guard !Task.isCancelled, sessionID == recordingSessionID else {
                epoching.isApplying = false
                epoching.phaseMessage = nil
                return
            }
            let model = PSADecisionMatrixModel(preparation: preparation)
            model.recordingInterpolatedChannels = Set(channels.interpolated.keys)
            if let previousMatrix {
                model.restoreManualDecisions(from: previousMatrix)
            }
            if preparedUsesFastRecordingPrior && !hasCurrentFullHealth {
                model.adoptRecordingChannelGoodness(preparedRecordingGoodness, kind: .fastRecording)
            }
            applySegmentHealthLabels(to: model, segments: sourceSegments)
            for excluded in epoching.resolvedTrialExclusion(for: sourceSegments)?.excludedIndices ?? [] {
                model.suggestEpochRejection(excluded, reason: "Previously excluded")
            }
            epoching.decisionMatrix = model
            model.psaRejectionSettings = epoching.decisionMatrixRejectionSettings
            epoching.decisionMatrixNeedsRefresh = false
            epoching.showsSheet = reviewInSheet
            epoching.showsDecisionMatrix = !reviewInSheet
            epoching.isApplying = false
            epoching.phaseMessage = nil
            psaTask = nil
            showDecisionMatrixSourceEpochs()
        }
    }

    @MainActor
    func ensurePreferredDecisionMatrixChannelPrior(
        signal: MFFSignalData, model: PSADecisionMatrixModel
    ) {
        switch goodnessSettings.psaDecisionMatrixHealthStrategy {
        case .adaptive, .segmentOnly:
            return
        case .fullRecording:
            guard !model.hasFullRecordingChannelHealth else { return }
            runFullChannelHealthForDecisionMatrix(signal: signal, model: model)
        case .fastRecording:
            // Either kind of recording-wide result is already better than the
            // epoch-set fallback. In particular, never replace a valid full
            // result with the smaller fast suite merely because Fast is the
            // saved fallback preference.
            guard !model.hasRecordingWideChannelHealth else { return }
            runFastChannelHealthForDecisionMatrix(signal: signal, model: model)
        }
    }

    func decisionMatrixFastChannelPriorSignature(for signal: MFFSignalData) -> String {
        let encoder = JSONEncoder()
        let base = (try? encoder.encode(goodnessSettings.base).base64EncodedString()) ?? ""
        let impedance = (try? encoder.encode(goodnessSettings.impedance).base64EncodedString()) ?? ""
        return [channelHealthSignature(for: signal), base, impedance].joined(separator: "|")
    }

    /// Computes the optional core-only recording prior as part of the same PSA
    /// operation and progress bar. The result is session-cached so reopening a
    /// matrix only recomputes channel-in-epoch evidence when its inputs changed.
    func decisionMatrixFastRecordingGoodness(
        signal: MFFSignalData,
        progressRange: ClosedRange<Double>
    ) async -> [Int: Int] {
        let signature = decisionMatrixFastChannelPriorSignature(for: signal)
        if epoching.decisionMatrixFastChannelPriorSignature == signature,
           epoching.decisionMatrixFastChannelGoodness.count >= signal.numberOfChannels {
            epoching.segmentingProgress = progressRange.upperBound
            return epoching.decisionMatrixFastChannelGoodness
        }
        let base = goodnessSettings.base
        let impedance = goodnessSettings.impedance
        let impedances = recording.signal?.impedancesKOhm
        let (progressContinuation, progressTask) = ProgressBridge.make { [weak epoching = epoching] (fraction: Double) in
            let bounded = min(max(fraction, 0), 1)
            epoching?.phaseMessage = "Scoring recording channel health…"
            epoching?.segmentingProgress = progressRange.lowerBound
                + (progressRange.upperBound - progressRange.lowerBound) * bounded
        }
        let worker = Task.detached(priority: .utility) {
            ChannelHealthAnalyzer.analyze(
                signal: signal,
                layout: nil,
                base: base,
                spectral: nil,
                ransac: nil,
                includeAdvancedSpectral: false,
                impedance: impedance,
                impedancesKOhm: impedances,
                progress: { progressContinuation.yield($0) }
            )
        }
        let analysis = await withTaskCancellationHandler(
            operation: { await worker.value },
            onCancel: { worker.cancel(); progressContinuation.finish() }
        )
        progressContinuation.finish()
        progressTask.cancel()
        guard !Task.isCancelled else { return [:] }
        let goodness = analysis.resultsByChannel.mapValues { $0.goodPercentage }
        guard goodness.count >= signal.numberOfChannels else { return [:] }
        epoching.decisionMatrixFastChannelPriorSignature = signature
        epoching.decisionMatrixFastChannelGoodness = goodness
        epoching.segmentingProgress = progressRange.upperBound
        return goodness
    }

    /// Runs the core whole-recording metrics without spectral, neighbor, or
    /// wavelet analysis. Results remain private to the matrix so other Channel
    /// Health UI never mistakes this abbreviated suite for a full run.
    @MainActor
    func runFastChannelHealthForDecisionMatrix(
        signal: MFFSignalData, model: PSADecisionMatrixModel
    ) {
        guard !channels.isAnalyzingHealth,
              !epoching.isAnalyzingDecisionMatrixChannelPrior else { return }
        let signature = decisionMatrixFastChannelPriorSignature(for: signal)
        if epoching.decisionMatrixFastChannelPriorSignature == signature,
           epoching.decisionMatrixFastChannelGoodness.count >= signal.numberOfChannels {
            model.adoptRecordingChannelGoodness(
                epoching.decisionMatrixFastChannelGoodness,
                kind: .fastRecording
            )
            return
        }
        let sessionID = recordingSessionID
        let base = goodnessSettings.base
        let impedance = goodnessSettings.impedance
        let impedances = recording.signal?.impedancesKOhm
        epoching.isAnalyzingDecisionMatrixChannelPrior = true
        epoching.decisionMatrixChannelPriorProgress = 0
        epoching.decisionMatrixChannelPriorMessage = "Running fast recording health…"

        let (progressContinuation, progressTask) = ProgressBridge.make { [weak epoching = epoching] (fraction: Double) in
            epoching?.decisionMatrixChannelPriorProgress = min(max(fraction, 0), 1)
            epoching?.decisionMatrixChannelPriorMessage = "Running fast recording health…"
        }
        psaTask?.cancel()
        psaTask = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                ChannelHealthAnalyzer.analyze(
                    signal: signal,
                    layout: nil,
                    base: base,
                    spectral: nil,
                    ransac: nil,
                    includeAdvancedSpectral: false,
                    impedance: impedance,
                    impedancesKOhm: impedances,
                    progress: { progressContinuation.yield($0) }
                )
            }
            let analysis = await withTaskCancellationHandler(
                operation: { await worker.value },
                onCancel: { worker.cancel(); progressContinuation.finish() }
            )
            progressContinuation.finish()
            progressTask.cancel()
            epoching.isAnalyzingDecisionMatrixChannelPrior = false
            epoching.decisionMatrixChannelPriorProgress = nil
            epoching.decisionMatrixChannelPriorMessage = nil
            guard !Task.isCancelled,
                  sessionID == recordingSessionID,
                  epoching.decisionMatrix === model else {
                psaTask = nil
                return
            }
            let goodness = analysis.resultsByChannel.mapValues(\.goodPercentage)
            guard goodness.count >= signal.numberOfChannels else {
                epoching.statusMessage = "Fast recording health did not return every channel; the matrix is using the segment-only prior."
                psaTask = nil
                return
            }
            epoching.decisionMatrixFastChannelPriorSignature = signature
            epoching.decisionMatrixFastChannelGoodness = goodness
            model.adoptRecordingChannelGoodness(goodness, kind: .fastRecording)
            psaTask = nil
        }
    }

    /// Upgrades the matrix's channel prior in place. The abbreviated scan still
    /// supplies transient per-cell evidence; only its recording-wide context is
    /// replaced, so explicit keep/interpolate/reject decisions are preserved.
    @MainActor
    func runFullChannelHealthForDecisionMatrix(signal: MFFSignalData, model: PSADecisionMatrixModel) {
        guard !channels.isAnalyzingHealth else { return }
        let sessionID = recordingSessionID
        runChannelHealthOnDemand(for: signal, force: true)
        guard let healthTask = chanHealth.task else { return }
        psaTask?.cancel()
        psaTask = Task { @MainActor in
            await healthTask.value
            guard !Task.isCancelled,
                  sessionID == recordingSessionID,
                  epoching.decisionMatrix === model,
                  chanHealth.signature == channelHealthSignature(for: signal) else {
                psaTask = nil
                return
            }
            let goodness = channels.healthResults.mapValues(\.goodPercentage)
            guard goodness.count >= signal.numberOfChannels else {
                epoching.statusMessage = "Full Channel Health did not return every channel; the matrix is still using the fast fallback prior."
                psaTask = nil
                return
            }
            model.adoptRecordingChannelGoodness(goodness, kind: .fullRecording)
            epoching.statusMessage = "Full Channel Health now supplies the matrix channel prior. Your matrix decisions were preserved."
            psaTask = nil
        }
    }

    func averageReviewedDecisionMatrix() {
        guard let matrix = epoching.decisionMatrix,
              let currentSource = segmentedEpochSignal else { return }
        guard matrix.preparation.matchesCurrentReviewInputs(
            signal: currentSource,
            segments: segmentedEpochSegments,
            averageReference: epoching.averageReference,
            baselineCorrect: epoching.baselineCorrected,
            globallyBadChannels: channels.bad,
            thresholds: epoching.epochBadChannelThresholds
        ) else {
            epoching.statusMessage = "Decision Matrix inputs changed; recalculating the review before averaging."
            epoching.decisionMatrixNeedsRefresh = true
            averageCurrentEpochs(reviewInSheet: epoching.decisionMatrixIsInSheet)
            return
        }
        refreshDecisionMatrixRejectionContext(
            matrix, segments: segmentedEpochSegments,
            sourceSignal: continuousProcessedSignal ?? recording.signal ?? currentSource
        )
        let snapshot = matrix.snapshot()
        let sourceCount = snapshot.preparation.segments.count
        let shouldAvgRef = epoching.averageReference
        let shouldBaseline = epoching.baselineCorrected
        let badChannels = channels.bad
        let suffix = psaPostProcessingSuffix()
        let sessionID = recordingSessionID
        epoching.isApplying = true
        epoching.phaseMessage = "Applying decisions…"
        epoching.segmentingProgress = 0
        psaTask?.cancel()
        psaTask = Task {
            let materializeWorker = Task.detached(priority: .userInitiated) { snapshot.materializedResult() }
            guard let reviewed = await materializeWorker.value,
                  !Task.isCancelled, sessionID == recordingSessionID else {
                epoching.isApplying = false
                epoching.phaseMessage = nil
                epoching.segmentingProgress = nil
                epoching.statusMessage = "Keep at least one epoch before averaging."
                return
            }
            epoching.segmentingProgress = 0.25
            epoching.phaseMessage = "Averaging…"
            let colors = categoryColorIndices(for: reviewed.segments.map(\.category))
            let averageWorker = Task.detached(priority: .userInitiated) {
                reviewed.average(colorIndices: colors)
            }
            guard let averaged = await averageWorker.value,
                  !Task.isCancelled, sessionID == recordingSessionID else {
                epoching.isApplying = false
                epoching.phaseMessage = nil
                epoching.segmentingProgress = nil
                epoching.statusMessage = "No averages could be computed."
                return
            }
            epoching.segmentingProgress = 0.75
            epoching.phaseMessage = "Post-processing…"
            let displayWorker = Task.detached(priority: .userInitiated) {
                averaged.postProcessed(
                    averageReference: shouldAvgRef,
                    baselineCorrect: shouldBaseline,
                    badChannels: badChannels
                )
            }
            let display = await displayWorker.value
            guard !Task.isCancelled, sessionID == recordingSessionID else {
                epoching.isApplying = false
                epoching.phaseMessage = nil
                epoching.segmentingProgress = nil
                return
            }
            epoching.segmentingProgress = 1
            // Retain every original trial so the floating review can revisit
            // and rescue exclusions, and interpolation never stacks on itself.
            computeAverageSNRInBackground(from: reviewed, excludedIndices: [], sessionID: sessionID)
            let rejected = sourceCount - reviewed.segments.count
            PSAAveraging.commit(
                averaged: display,
                sourceSegmentCount: sourceCount,
                excludedSegmentCount: rejected,
                statusMessage: averaged.message + suffix + " · \(rejected) rejected in Decision Matrix",
                epoching: epoching,
                segHealth: segHealth,
                store: recordingStore
            )
            epoching.showsDecisionMatrix = false
            epoching.showsSheet = false
            epoching.decisionMatrixIsInSheet = false
            epoching.isApplying = false
            epoching.phaseMessage = nil
            epoching.segmentingProgress = nil
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
        let referenced = Rereferencing.applied(result.signal, excluding: channels.bad)
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
        let reviewedSnapshot = epoching.decisionMatrix.flatMap { matrix in
            matrix.preparation.sourceSignal.dataRevision == base.signal.dataRevision
                && matrix.preparation.segments.map(\.id) == base.segments.map(\.id)
                ? matrix.snapshot() : nil
        }
        let colorIndices = categoryColorIndices(for: base.segments.map(\.category))
        // Segment Health labels and the committed reviewed exclusion are kept
        // apart on purpose: they average together, but `skippedLabeledBadSegments`
        // below counts only the labels, and folding the two would attribute
        // reviewed exclusions to a control the operator never touched.
        let labeledBadIndices = excludedBadSegmentIndices(base.segments, requiresOptIn: !isAveraged)
        let trialExclusion = epoching.resolvedTrialExclusion(for: base.segments)
        epoching.trialExclusionResolution = isAveraged ? trialExclusion : nil
        let excludedIndices = isAveraged
            ? labeledBadIndices.union(trialExclusion?.excludedIndices ?? [])
            : labeledBadIndices
        psaTask?.cancel()
        let sessionID = recordingSessionID
        psaTask = Task {
            let result: PSABuildResult
            var averageSource = base
            if isAveraged {
                let averageWorker = Task.detached(priority: .userInitiated) {
                    if let reviewedSnapshot {
                        guard let reviewed = reviewedSnapshot.materializedResult() else { return (Optional<PSABuildResult>.none, base) }
                        return (reviewed.average(colorIndices: colorIndices), reviewed)
                    }
                    return (base.average(colorIndices: colorIndices, excludedIndices: excludedIndices), base)
                }
                let averagedOpt2 = await withTaskCancellationHandler(
                    operation: {
                        await averageWorker.value
                    },
                    onCancel: {
                        averageWorker.cancel()
                    }
                )
                guard !Task.isCancelled, sessionID == recordingSessionID, let averaged = averagedOpt2.0 else { return }
                result = averaged
                averageSource = averagedOpt2.1
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
                computeAverageSNRInBackground(from: averageSource, excludedIndices: reviewedSnapshot == nil ? excludedIndices : [], sessionID: sessionID)
            } else {
                snrTask?.cancel()
                snrTask = nil
                epoching.isComputingAverageSNR = false
                epoching.averageSNRByCategory = [:]
            }
            epoching.epochedSignal = display.signal
            epoching.epochSegments = display.segments
            var exclusionSummary = epoching.psaExclusionSummary
            // Idempotent by construction — see `recordExclusions` — so a
            // toggle-driven re-average restates this reason rather than adding
            // to what the last one recorded.
            epoching.foldTrialExclusion(
                isAveraged ? trialExclusion : Optional<TrialExclusionResolver.Resolution>.none,
                step: epoching.committedTrialExclusion,
                segments: base.segments,
                into: &exclusionSummary
            )
            exclusionSummary.skippedLabeledBadSegments = isAveraged ? labeledBadIndices.count : 0
            exclusionSummary.outputSegments = display.segments.count
            epoching.psaExclusionSummary = exclusionSummary
            epoching.statusMessage = appendPSAEpochDiagnostics(
                to: result.message + suffix,
                sourceSegments: base.segments,
                skippedIndices: labeledBadIndices,
                includeSkippedLabeledBadSegments: isAveraged
            )
            psaTask = nil
            if epoching.showsDecisionMatrix,
               let matrix = epoching.decisionMatrix,
               !matrix.preparation.matchesCurrentReviewInputs(
                   signal: base.signal, segments: base.segments,
                   averageReference: shouldAvgRef, baselineCorrect: shouldBaseline,
                   globallyBadChannels: badChannels, thresholds: epoching.epochBadChannelThresholds
               ) {
                averageCurrentEpochs()
            }
        }
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
