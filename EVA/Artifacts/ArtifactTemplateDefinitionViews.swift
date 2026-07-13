//
//  ArtifactTemplateDefinitionViews.swift
//  EVA
//
//  Artifact template definition sheet (waveform/topography matching, defined
//  artifacts CRUD, and the artifact cleaning sheet), extracted from
//  WaveformView.swift during the L5 view-decomposition refactor. This is an
//  extension of WaveformView (not a standalone type), following the same
//  pattern as ECGDetectionViews.swift / BCGDetectionViews.swift — the cluster
//  reads/writes WaveformView's own stores (template, artifactVM, channels)
//  and state, so this is a file split, not a state extraction.
//

import SwiftUI

extension WaveformView {
    // MARK: - Artifact template definition

    /// Whether the topography panel is actually running the Continuous scan
    /// style right now — gated to Ocular artifacts using a single-map
    /// reference (Map sequence is always its own kind of "continuous").
    var isContinuousScan: Bool {
        template.type == .ocular
            && template.topographyMode != .trajectory
            && template.topographyScanStyle == .continuous
    }

    func defaultArtifactTemplateChannel(in signal: MFFSignalData) -> Int? {
        signal.data.indices.first { !channels.hidden.contains($0) && !channels.bad.contains($0) }
            ?? signal.data.indices.first { !channels.hidden.contains($0) }
            ?? signal.data.indices.first
    }

    func inferredArtifactType(name: String, eventCode: String) -> DefinedArtifactType {
        let text = "\(name) \(eventCode)".lowercased()
        if text.contains("ecg") || text.contains("heart") || text.contains("cardiac") {
            return .ecg
        }
        if text.contains("bcg") || text.contains("ballisto") {
            return .bcg
        }
        if text.contains("eye") || text.contains("blink") || text.contains("ocular") || text.contains("eog") {
            return .ocular
        }
        return .other
    }

    func artifactTemplateEventCodeSuffix(for type: DefinedArtifactType) -> String {
        switch type {
        case .ocular: return "AOC"
        case .ecg: return "ECG"
        case .bcg: return "BCG"
        case .other: return "AOT"
        }
    }

    func artifactTemplateEventCode(for type: DefinedArtifactType, number: Int) -> String {
        let suffix = artifactTemplateEventCodeSuffix(for: type)
        let maxTokenLength = max(4 - suffix.count, 1)
        let decimalToken = "\(number)"
        let token: String
        if decimalToken.count <= maxTokenLength {
            token = decimalToken
        } else {
            let base36Token = String(number, radix: 36, uppercase: true)
            token = base36Token.count <= maxTokenLength ? base36Token : decimalToken
        }
        return "\(token)\(suffix)"
    }

    func artifactTemplateCodeNumber(_ code: String, for type: DefinedArtifactType) -> Int? {
        let suffix = artifactTemplateEventCodeSuffix(for: type)
        let upperCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard upperCode.hasSuffix(suffix) else { return nil }

        let body = String(upperCode.dropLast(suffix.count))
        if let decimalNumber = Int(body) {
            return decimalNumber
        }
        return Int(body, radix: 36)
    }

    func nextArtifactTemplateNumber(for type: DefinedArtifactType) -> Int {
        let existingArtifacts = template.definedArtifacts.filter { $0.id != template.definedArtifactID }
        let sameTypeArtifacts = existingArtifacts.filter { $0.type == type }
        var maxNumber = sameTypeArtifacts.count

        for artifact in sameTypeArtifacts {
            if let number = artifactTemplateCodeNumber(artifact.eventCode, for: type) {
                maxNumber = max(maxNumber, number)
            }
        }

        let existingCodes = Set(existingArtifacts.map {
            $0.eventCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        })
        var candidate = maxNumber + 1
        while existingCodes.contains(artifactTemplateEventCode(for: type, number: candidate).uppercased()) {
            candidate += 1
        }
        return candidate
    }

    func applyDefaultArtifactTemplateIdentity(for type: DefinedArtifactType) {
        let number = nextArtifactTemplateNumber(for: type)
        template.name = "A\(number): \(type.rawValue)"
        template.eventCode = artifactTemplateEventCode(for: type, number: number)
    }

    func openArtifactTemplateSheet(for signal: MFFSignalData, clickedChannel: Int) {
        guard let range = activeSelectionRange(in: signal), signal.samplingRate > 0 else {
            template.statusMessage = "Highlight a waveform region before defining an artifact."
            return
        }

        template.selectionRange = range
        template.clickedChannel = clickedChannel
        template.definedArtifactID = nil
        template.type = .ocular
        applyDefaultArtifactTemplateIdentity(for: template.type)
        template.channelScope = .clickedChannel
        template.customChannels = "\(clickedChannel + 1)"
        template.windowSeconds = max(Double(range.upperBound - range.lowerBound + 1) / signal.samplingRate, 0.02)
        template.downsampleRate = min(250, signal.samplingRate)
        template.threshold = 0.70
        template.mergeWindowSeconds = template.type.defaultMergeWindowSeconds
        template.mergeBehavior = template.type.defaultMergeBehavior
        template.waveformStretchRange = 0
        template.polarity = .same
        template.topographyMode = .off
        template.topographyChannelScope = .allGood
        template.topographyTopN = 16
        template.topographyMetric = .pearson
        template.trajectoryShiftSeconds = 0.05
        template.trajectoryScaleRange = 0
        template.trajectoryGFPWeighted = true
        template.trajectoryExcludedFrameIndices = []
        template.trajectorySaveJSONIncludesRemovedFrames = false
        template.definitionPanel = .waveforms
        template.confirmedSource = nil
        template.statusMessage = nil
        template.result = nil
        template.lastScanSignature = nil
        template.selectedChannel = nil
        artifactVM.detectionMethod = .template
        template.showsSheet = true
    }

    func artifactTemplateSheet(for signal: MFFSignalData) -> some View {
        let selectedChannels = artifactTemplateSelectedChannels(in: signal)
        let comparisonChannels = Array(signal.data.indices)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Define Artifact")
                    .font(.title3.weight(.semibold))
                Spacer()
                if let range = template.selectionRange {
                    Text(selectionDescription(range, in: signal))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            artifactIdentitySection

            Picker("Artifact definition section", selection: $template.definitionPanel) {
                ForEach(ArtifactDefinitionPanel.allCases) { panel in
                    Text(panel.rawValue).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            artifactDefinitionPanelContent(signal: signal, selectedChannels: selectedChannels)

            artifactDefinitionComparisonSection(signal: signal)

            HStack {
                Button("Save JSON…") {
                    saveArtifactTemplateJSON(template.result?.savedTemplate)
                }
                .disabled(template.result == nil)

                if template.topographyMode == .trajectory, !template.trajectoryExcludedFrameIndices.isEmpty {
                    Toggle("Include \(template.trajectoryExcludedFrameIndices.count) removed frame(s) in JSON", isOn: $template.trajectorySaveJSONIncludesRemovedFrames)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help("When off, map-sequence frames you removed from the frame strip are left out of the exported JSON's trajectory reference, matching what was actually scored.")
                }

                Spacer()

                Button(artifactDefinitionCloseTitle) {
                    template.showsSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button(artifactDefinitionApplyTitle) {
                    applyActiveArtifactDefinitionPanel(to: signal)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    template.isApplying
                        || template.selectionRange == nil
                        || selectedChannels.isEmpty
                        || comparisonChannels.isEmpty
                        || template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || template.eventCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !activeArtifactDefinitionPanelCanRun
                )
            }
        }
        .padding(20)
        .frame(width: 760)
        .onChange(of: template.definitionPanel) { _, panel in
            if panel == .topography, !template.topographyMode.isEnabled {
                template.topographyMode = .peak
            }
        }
        .onChange(of: template.type) { _, newType in
            applyDefaultArtifactTemplateIdentity(for: newType)
            let defaultMergeWindow = newType.defaultMergeWindowSeconds
            if template.mergeWindowSeconds != defaultMergeWindow {
                template.mergeWindowSeconds = defaultMergeWindow
            }
            let defaultMergeBehavior = newType.defaultMergeBehavior
            if template.mergeBehavior != defaultMergeBehavior {
                template.mergeBehavior = defaultMergeBehavior
            }
            // Continuous topography scanning is gated to Ocular artifacts.
            if newType != .ocular, template.topographyScanStyle != .windowed {
                template.topographyScanStyle = .windowed
            }
        }
        .onChange(of: template.name) { _, _ in
            scheduleDefinedArtifactIdentityRefresh()
        }
        .onChange(of: template.eventCode) { _, _ in
            scheduleDefinedArtifactIdentityRefresh()
        }
        .onChange(of: template.topographyMode) { _, newMode in
            // Continuous scanning only applies to the single-map reference
            // modes — Map sequence is already its own kind of "continuous".
            if newMode == .trajectory, template.topographyScanStyle != .windowed {
                template.topographyScanStyle = .windowed
            }
            refreshTopographyIfNeeded(for: signal)
        }
        .onChange(of: template.topographyChannelScope) { _, _ in
            refreshTopographyIfNeeded(for: signal)
        }
        .onChange(of: template.topographyChannelSetID) { _, _ in
            if template.topographyChannelScope == .channelSet {
                refreshTopographyIfNeeded(for: signal)
            }
        }
        .onChange(of: template.topographyTopN) { _, _ in
            guard template.topographyChannelScope == .topN else { return }
            refreshTopographyIfNeeded(for: signal)
        }
        .onChange(of: template.topographyMetric) { _, _ in
            refreshTopographyIfNeeded(for: signal)
        }
        .onChange(of: template.trajectoryShiftSeconds) { _, _ in
            guard template.topographyMode == .trajectory else { return }
            refreshTopographyIfNeeded(for: signal)
        }
        .onChange(of: template.trajectoryScaleRange) { _, _ in
            guard template.topographyMode == .trajectory else { return }
            refreshTopographyIfNeeded(for: signal)
        }
        .onChange(of: template.trajectoryGFPWeighted) { _, _ in
            guard template.topographyMode == .trajectory else { return }
            refreshTopographyIfNeeded(for: signal)
        }
        .onChange(of: template.trajectoryExcludedFrameIndices) { _, _ in
            guard template.topographyMode == .trajectory else { return }
            refreshTopographyIfNeeded(for: signal)
        }
    }

    var artifactIdentitySection: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                ArtifactTemplateFieldLabel(
                    title: "Type",
                    help: "Used by Clean Artifacts to group ocular, ECG, BCG, and other artifact definitions."
                )
                Picker("Type", selection: $template.type) {
                    ForEach(DefinedArtifactType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 180)

                ArtifactTemplateFieldLabel(
                    title: "Event Code",
                    help: "The event marker name inserted for each match. These generated markers appear in the Events panel and can be used by PSA artifact rejection."
                )
                TextField("Event code", text: $template.eventCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            GridRow {
                ArtifactTemplateFieldLabel(
                    title: "Name",
                    help: "A human-readable label for this artifact template. This is saved in the JSON so you can recognize the exemplar later."
                )
                TextField("Artifact name", text: $template.name)
                    .textFieldStyle(.roundedBorder)
                    .gridCellColumns(3)
            }
        }
    }

    func artifactWaveformConfigurationSection(selectedChannels: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                waveformChannelGridRows
                waveformThresholdGridRows
                waveformWindowGridRows
            }

            Text("\(selectedChannels.count) selected channels · all-channel comparison enabled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var waveformChannelGridRows: some View {
        Group {
            GridRow {
                ArtifactTemplateFieldLabel(
                    title: "Channels",
                    help: "Chooses which channels define the template score. Clicked Channel is fastest and easiest to interpret; Ocular Channels is useful for blinks; All Channels uses a weighted spatial template."
                )
                Picker("Channels", selection: $template.channelScope) {
                    ForEach(ArtifactTemplateChannelScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .labelsHidden()
                .frame(width: 180)

                ArtifactTemplateFieldLabel(
                    title: "Specific",
                    help: "A comma- or space-separated list of 1-based channel numbers, such as 8, 25, 126. Used only when Channels is set to Specific Channels."
                )
                TextField("1, 8, 25", text: $template.customChannels)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .disabled(template.channelScope != .specificChannels)
            }
        }
    }

    var waveformThresholdGridRows: some View {
        Group {
            GridRow {
                ArtifactTemplateFieldLabel(
                    title: "Threshold",
                    help: "Minimum normalized cross-correlation required to count a match. 70% is a permissive starting point; higher values find fewer, more template-like events."
                )
                HStack {
                    Slider(value: $template.threshold, in: 0.30...0.98, step: 0.01)
                    Text("\(Int((template.threshold * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                }
                .frame(width: 180)

                ArtifactTemplateFieldLabel(
                    title: "Polarity",
                    help: "Controls whether matches must have the same direction as the exemplar, the opposite direction, or either direction. Either is useful when channel reference or artifact direction varies."
                )
                Picker("Polarity", selection: $template.polarity) {
                    ForEach(ArtifactTemplatePolarity.allCases) { polarity in
                        Text(polarity.rawValue).tag(polarity)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }
        }
    }

    var waveformWindowGridRows: some View {
        Group {
            GridRow {
                ArtifactTemplateFieldLabel(
                    title: "Window (s)",
                    help: "Duration of the template window centered on the highlighted exemplar. Larger windows capture more context but can make matching more specific."
                )
                TextField("Window", value: $template.windowSeconds, format: .number.precision(.fractionLength(3)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)

                ArtifactTemplateFieldLabel(
                    title: "Search Hz",
                    help: "Temporary downsample rate used while searching. Lower values are faster; 250 Hz is usually enough for slow artifacts like blinks."
                )
                TextField("Hz", value: $template.downsampleRate, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }

            GridRow {
                ArtifactTemplateFieldLabel(
                    title: "Stretch",
                    help: "Fractional waveform time-scaling tolerance. 0.10 lets the search shrink or stretch the exemplar window by ±10% before scoring, which helps match artifacts with the same shape but slightly different duration. Set to 0 to keep a fixed window."
                )
                TextField("Stretch", value: $template.waveformStretchRange, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .help("0.10 = ±10% stretch/compression.")

                ArtifactTemplateFieldLabel(
                    title: "Merge (s)",
                    help: "Hits within this time window of each other are merged into one artifact event, keeping the highest-scoring match. This prevents double-counting the same artifact. Pre-filled from the artifact Type — BCG/ECG default to 0.25 s (a 240 BPM physiological ceiling), since two hits closer than that are almost certainly the same beat; adjust freely."
                )
                TextField("Merge", value: $template.mergeWindowSeconds, format: .number.precision(.fractionLength(3)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }

            GridRow {
                ArtifactTemplateFieldLabel(
                    title: "On Merge",
                    help: "Extend: span merged hits from the first one's onset to the last one's offset, so one long artifact matched at several overlapping offsets is reported as a single event covering its full duration. Discard: keep only the single best-scoring hit and drop the rest (the original behavior) — better suited to point-like, fixed-duration artifacts like a heartbeat. Pre-filled from the artifact Type; adjust freely."
                )
                Picker("On Merge", selection: $template.mergeBehavior) {
                    ForEach(ArtifactTemplateMergeBehavior.allCases) { behavior in
                        Text(behavior.rawValue).tag(behavior)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
                .gridCellColumns(3)
            }
        }
    }

    func artifactTopographyConfigurationSection(signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Reference",
                        help: "Scans for the exemplar's scalp voltage pattern across electrodes. Middle map, Peak map, and Average map use one reference map. Map sequence uses the whole time course across the highlighted window and can shift or stretch to match artifacts with similar spatial evolution."
                    )
                    Picker("Reference", selection: $template.topographyMode) {
                        ForEach(ArtifactTopographyMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)

                    ArtifactTemplateFieldLabel(
                        title: "Fit Metric",
                        help: "Cost function for scalp-map similarity, independent of the waveform polarity. Pearson r matches same-polarity maps; |Pearson r| also matches polarity-inverted maps; Opposite (-r) matches only the inverted map."
                    )
                    Picker("Fit Metric", selection: $template.topographyMetric) {
                        ForEach(ArtifactTopographyMetric.allCases) { metric in
                            Text(metric.rawValue).tag(metric)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Scan",
                        help: "Windowed scores fixed-length candidate windows against the reference map (the original behavior). Continuous instead traces how closely every sample matches the reference and marks each continuous above-threshold stretch as one artifact, so its reported duration reflects how long the topography actually stayed similar — no fixed window length. Only available for Ocular artifacts using a single-map reference (Middle/Peak/Average, not Map sequence)."
                    )
                    Picker("Scan", selection: $template.topographyScanStyle) {
                        ForEach(ArtifactTopographyScanStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .disabled(template.type != .ocular || template.topographyMode == .trajectory)

                    if template.type != .ocular {
                        Text("Ocular artifacts only")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if template.topographyMode == .trajectory {
                        Text("Map sequence is always continuous")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if isContinuousScan {
                    GridRow {
                        ArtifactTemplateFieldLabel(
                            title: "Min Dur (s)",
                            help: "Shortest contiguous above-threshold run that counts as an artifact. Shorter runs are rejected as noise."
                        )
                        TextField("Min", value: $template.continuousMinDurationSeconds, format: .number.precision(.fractionLength(3)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)

                        ArtifactTemplateFieldLabel(
                            title: "Max Dur (s)",
                            help: "Longest contiguous run allowed; longer runs are rejected. 0 = uncapped."
                        )
                        TextField("Max", value: $template.continuousMaxDurationSeconds, format: .number.precision(.fractionLength(3)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }

                    GridRow {
                        ArtifactTemplateFieldLabel(
                            title: "Smoothing (s)",
                            help: "Boxcar-smooths the per-sample similarity trace over this window before thresholding, so brief noise-driven dips (e.g. a low-amplitude moment mid-movement) don't fragment one continuous artifact into several short runs. Merge (s) below still bridges separate nearby runs afterward."
                        )
                        TextField("Smoothing", value: $template.continuousSmoothingSeconds, format: .number.precision(.fractionLength(3)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Topo Channels",
                        help: "Which channels the scalp-topography correlation uses. Bad channels are always excluded. Channel clusters (regions of interest) are coming soon."
                    )
                    HStack(spacing: 8) {
                        Picker("Topo Channels", selection: $template.topographyChannelScope) {
                            ForEach(ArtifactTopographyChannelScope.allCases) { scope in
                                Text(scope.label).tag(scope)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 170)

                        if template.topographyChannelScope == .topN {
                            Stepper(value: $template.topographyTopN, in: 3...128) {
                                Text("N = \(template.topographyTopN)")
                                    .font(.caption.monospacedDigit())
                            }
                            .help("Number of channels selected by highest RMS amplitude in the exemplar window. Fewer channels focus the spatial correlation on those that express the artifact most strongly.")
                        }
                    }

                    if template.topographyChannelScope == .channelSet {
                        ChannelSetPickerView(
                            label: "Channel Set",
                            selectedSetID: $template.topographyChannelSetID,
                            channelCount: signal.numberOfChannels
                        )
                    }

                    ArtifactTemplateFieldLabel(
                        title: "Threshold",
                        help: "Minimum spatial correlation required to count a scalp-map match."
                    )
                    HStack {
                        Slider(value: $template.threshold, in: 0.30...0.98, step: 0.01)
                        Text("\(Int((template.threshold * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                    .frame(width: 180)
                }

                if template.topographyMode == .trajectory {
                    GridRow {
                        ArtifactTemplateFieldLabel(
                            title: "Shift (s)",
                            help: "Maximum time shift (±seconds) applied to the reference trajectory when searching for the best-fitting alignment. Handles beat-to-beat onset jitter. Set to 0 to disable."
                        )
                        TextField("Shift", value: $template.trajectoryShiftSeconds, format: .number.precision(.fractionLength(3)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Stretch",
                        help: "Fractional time-scale tolerance for Map sequence references. 0.10 lets the map sequence shrink or stretch by ±10% before scoring, which helps match artifacts with the same spatial evolution but slightly different duration. Set to 0 to keep a fixed trajectory length."
                    )
                    HStack(spacing: 8) {
                        TextField("Stretch", value: $template.trajectoryScaleRange, format: .number.precision(.fractionLength(2)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .disabled(template.topographyMode != .trajectory)
                        if template.topographyMode != .trajectory {
                            Text("Map sequence only")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            if let ref = template.result?.topographyReference,
                               let frames = ref.trajectoryFrameCount {
                                Text("\(frames)-frame trajectory")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .gridCellColumns(3)
                }

                if template.topographyMode == .trajectory {
                    GridRow {
                        ArtifactTemplateFieldLabel(
                            title: "GFP Weighting",
                            help: "When on, each frame's spatial-correlation score is weighted by the reference frame's Global Field Power (amplitude). Peak-amplitude frames drive the match; quiet frames barely count. Good for artifacts with a clear temporal peak (BCG, saccades, muscle bursts). Turn off for sustained or amplitude-flat artifacts where the quiet periods are part of the signature."
                        )
                        Toggle("Weight frames by amplitude", isOn: $template.trajectoryGFPWeighted)
                            .toggleStyle(.checkbox)
                    }
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Window (s)",
                        help: "Duration of the exemplar window used to build the reference map (or trajectory). Centered on your highlighted region."
                    )
                    TextField("Window", value: $template.windowSeconds, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)

                    ArtifactTemplateFieldLabel(
                        title: "Sample Hz",
                        help: "Internal downsample rate used during the scan. Lower values run faster; 250 Hz is enough for scalp-map artifacts. Does not affect output event precision."
                    )
                    TextField("Hz", value: $template.downsampleRate, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }

                GridRow {
                    ArtifactTemplateFieldLabel(
                        title: "Merge (s)",
                        help: isContinuousScan
                            ? "Separate contiguous runs closer than this are bridged into one event."
                            : "Hits within this time window of each other are merged into a single event (keeping the highest-scoring one). Prevents double-counting a single artifact. Pre-filled from the artifact Type — BCG/ECG default to 0.25 s (a 240 BPM physiological ceiling), since two hits closer than that are almost certainly the same beat; adjust freely."
                    )
                    TextField("Merge", value: $template.mergeWindowSeconds, format: .number.precision(.fractionLength(3)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }

                if !isContinuousScan {
                    GridRow {
                        ArtifactTemplateFieldLabel(
                            title: "On Merge",
                            help: "Extend: span merged hits from the first one's onset to the last one's offset, so a long artifact matched at several overlapping window positions is reported as a single event covering its full duration. Discard: keep only the single best-scoring hit and drop the rest (the original behavior) — better suited to point-like, fixed-duration artifacts like a heartbeat. Pre-filled from the artifact Type; adjust freely."
                        )
                        Picker("On Merge", selection: $template.mergeBehavior) {
                            ForEach(ArtifactTemplateMergeBehavior.allCases) { behavior in
                                Text(behavior.rawValue).tag(behavior)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                }
            }

            if template.topographyMode.isEnabled {
                Text(template.topographyMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("\(artifactTopographyChannels(in: signal).count) topography channels · bad channels excluded")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var artifactDefinitionCloseTitle: String {
        guard let confirmedSource = template.confirmedSource else {
            return "Close"
        }
        return "Confirm \(confirmedSource.confirmationName) Selection"
    }

    var artifactDefinitionApplyTitle: String {
        switch template.definitionPanel {
        case .waveforms:
            return template.result == nil ? "Run Waveform Scan" : "Rescan Waveforms"
        case .topography:
            return template.result?.topographyReference == nil ? "Run Topography Scan" : "Rescan Topography"
        }
    }

    var activeArtifactDefinitionPanelCanRun: Bool {
        switch template.definitionPanel {
        case .waveforms:
            return template.result == nil || artifactTemplateScanIsStale
        case .topography:
            return template.topographyMode.isEnabled
        }
    }

    func applyActiveArtifactDefinitionPanel(to signal: MFFSignalData) {
        switch template.definitionPanel {
        case .waveforms:
            applyArtifactTemplate(to: signal, preferredSource: .waveform)
        case .topography:
            applyArtifactTemplate(to: signal, preferredSource: .topography)
        }
    }

    @ViewBuilder
    func artifactDefinitionPanelContent(signal: MFFSignalData, selectedChannels: [Int]) -> some View {
        switch template.definitionPanel {
        case .waveforms:
            artifactWaveformsPanel(signal: signal, selectedChannels: selectedChannels)
        case .topography:
            artifactTopographyPanel(signal: signal)
        }
    }

    func artifactWaveformsPanel(signal: MFFSignalData, selectedChannels: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            artifactWaveformConfigurationSection(selectedChannels: selectedChannels)
            artifactDefinitionActivityView(
                isRunning: template.isApplying,
                runningText: "Scanning waveform matches..."
            )

            if let templateResult = template.result {
                artifactWaveformResultView(templateResult, signal: signal)
            } else {
                artifactDefinitionEmptyPreview(
                    title: "No waveform scan yet",
                    detail: "Run waveform matching to inspect the exemplar average and channel-scope behavior."
                )
            }
        }
    }

    func artifactTopographyPanel(signal: MFFSignalData) -> some View {
        let isRunning = template.isApplying || template.isRefreshingTopography
        let runningText = template.isRefreshingTopography
            ? "Refreshing topography matches..."
            : "Scanning topography matches..."

        return VStack(alignment: .leading, spacing: 12) {
            artifactTopographyConfigurationSection(signal: signal)
            artifactDefinitionActivityView(isRunning: isRunning, runningText: runningText)

            if let topography = template.result?.topographyReference {
                artifactTopographyResultView(topography)
            } else {
                artifactDefinitionEmptyPreview(
                    title: "No topography scan yet",
                    detail: "Run a topography scan to inspect the scalp map and spatial match settings."
                )
            }
        }
    }

    @ViewBuilder
    func artifactDefinitionActivityView(isRunning: Bool, runningText: String) -> some View {
        if isRunning {
            HStack(spacing: 10) {
                if template.scanTotal > 0 {
                    let fraction = Double(template.scanCompleted) / Double(template.scanTotal)
                    ProgressView(value: fraction)
                        .frame(width: 100)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                Text(runningText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let templateStatus = template.statusMessage {
            Text(templateStatus)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    func artifactDefinitionEmptyPreview(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    func artifactDefinitionComparisonSection(signal: MFFSignalData) -> some View {
        if template.result != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Run Comparison")
                    .font(.caption.weight(.semibold))

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    GridRow {
                        Text("Selection")
                        Text("Found")
                        Text("Evidence")
                        Text("")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                    if let result = template.result {
                        artifactDefinitionComparisonRow(
                            source: .waveform,
                            count: result.selectedEvents.count,
                            detail: waveformComparisonDetail(result, signal: signal),
                            score: nil
                        ) {
                            useWaveformMatches(result, signal: signal)
                        }

                        if let topography = result.topographyReference {
                            artifactDefinitionComparisonRow(
                                source: .topography,
                                count: topography.matchCount,
                                detail: "\(topography.channelIndices.count) channels · \(template.topographyMetric.rawValue)",
                                score: nil
                            ) {
                                useTopographyMatches(result, signal: signal)
                            }
                        }
                    }

                }

                Text("The selected row becomes the artifact event set used by Clean Artifacts and PSA rejection.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    func artifactDefinitionComparisonRow(
        source: ArtifactDefinitionResultSource,
        count: Int,
        detail: String,
        score: Double?,
        action: @escaping () -> Void
    ) -> some View {
        GridRow {
            Label(source.displayName, systemImage: template.confirmedSource == source ? "checkmark.circle.fill" : source.systemImage)
                .font(.caption)
                .foregroundStyle(template.confirmedSource == source ? .green : .primary)
            Text("\(count)")
                .font(.caption.monospacedDigit().weight(.semibold))
            HStack(spacing: 6) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let score {
                    Text(String(format: "best %.2f", score))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Button(template.confirmedSource == source ? "Selected" : "Use") {
                action()
            }
            .font(.caption)
            .disabled(count == 0 || template.confirmedSource == source)
        }
    }

    func waveformComparisonDetail(_ result: ArtifactTemplateDetectionResult, signal: MFFSignalData) -> String {
        let allChannelText = result.comparisonEvents.count == result.selectedEvents.count
            ? "all-channel same"
            : "all-channel \(result.comparisonEvents.count)"
        return "\(artifactTemplateSelectedChannels(in: signal).count) selected · \(allChannelText)"
    }

    /// Recomputes only the topography result (reference map + matches) when the
    /// reference mode or channel scope changes, but only after a full detection
    /// has already been run once. Keeps the displayed topomap in sync without a
    /// new Apply.
    func refreshTopographyIfNeeded(for signal: MFFSignalData) {
        guard template.result != nil,
              let range = template.selectionRange else {
            return
        }

        guard template.topographyMode.isEnabled else {
            if template.result?.topographyEvents.isEmpty == false {
                template.result?.topographyEvents = []
            }
            if template.result?.topographyReference != nil {
                template.result?.topographyReference = nil
            }
            return
        }

        let configuration = artifactTemplateConfiguration(for: signal, range: range)
        template.topographyRefreshGeneration += 1
        let generation = template.topographyRefreshGeneration
        template.isRefreshingTopography = true
        template.scanCompleted = 0
        template.scanTotal = 0
        topographyTask?.cancel()
        let sessionID = recordingSessionID
        topographyTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                ArtifactTemplateDetector.detectTopography(in: signal, configuration: configuration) { completed, total in
                    Task { @MainActor in
                        self.template.scanCompleted = completed
                        self.template.scanTotal = total
                    }
                }
            }
            let outcome = await withTaskCancellationHandler(
                operation: {
                    await worker.value
                },
                onCancel: {
                    worker.cancel()
                }
            )
            // Ignore stale completions: a newer refresh has superseded this one
            // and will publish its own result (and clear the spinner).
            guard !Task.isCancelled,
                  sessionID == recordingSessionID,
                  generation == template.topographyRefreshGeneration else { return }
            template.result?.topographyEvents = outcome.events
            template.result?.topographyReference = outcome.reference
            template.isRefreshingTopography = false
            topographyTask = nil
        }
    }

    func artifactWaveformResultView(_ result: ArtifactTemplateDetectionResult, signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let average = result.templateAverage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Average waveform")
                        .font(.caption.weight(.semibold))
                    ArtifactTemplateAveragePlot(
                        average: average,
                        primaryChannel: template.clickedChannel,
                        highlightedChannels: Set(average.selectedChannelIndices)
                    )
                    .frame(height: 170)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let average = result.templateAverage {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Strongest average channels")
                        .font(.caption.weight(.semibold))
                    HStack(spacing: 8) {
                        ForEach(average.channelSummaries.prefix(8)) { summary in
                            Button {
                                selectArtifactTemplateChannel(summary.channelIndex, autoApplyIn: signal)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Ch \(summary.channelIndex + 1)")
                                        .font(.caption2.weight(.semibold))
                                    Text(String(format: "%.1f µV", summary.peakAbsoluteMicrovolts))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(artifactTemplateChannelChipColor(summary, average: average))
                                )
                            }
                            .buttonStyle(.plain)
                            .help("Use Ch \(summary.channelIndex + 1) as the defining artifact channel.")
                        }
                    }
                }
            }

            if !result.scopeCounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Channel selection comparison")
                        .font(.caption.weight(.semibold))

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                        GridRow {
                            Text("Option")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("Channels")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("Found")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        ForEach(result.scopeCounts) { scope in
                            GridRow {
                                Text(scope.name)
                                    .font(.caption)
                                Text("\(scope.channelCount)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("\(scope.matchCount)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(scope.matchCount > result.selectedEvents.count ? .orange : .primary)
                            }
                        }

                        if let selectedChannel = template.selectedChannel,
                           let matchCount = result.singleChannelMatchCounts[selectedChannel] {
                            GridRow {
                                Text("Selected Channel: Ch \(selectedChannel + 1)")
                                    .font(.caption)
                                Text("1")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("\(matchCount)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(matchCount > result.selectedEvents.count ? .orange : .primary)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    func artifactTopographyResultView(_ topography: ArtifactTemplateTopography) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Label("Scalp-topography template", systemImage: "circle.grid.3x3.fill")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(topography.channelIndices.count) channels · \(template.topographyMetric.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            artifactTopographyMapView(topography)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The template scalp map. For trajectory mode shows a clickable frame strip;
    /// for single-map modes shows a single topomap.
    @ViewBuilder
    func artifactTopographyMapView(_ topography: ArtifactTemplateTopography) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Scalp topography")
                    .font(.caption.weight(.semibold))
                if template.isRefreshingTopography {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Text(topography.mode.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Trajectory strip — the frame-by-frame sequence already shows how
            // the map evolves, so map-sequence mode stops here (no separate
            // large preview below it — see single-map branch for that).
            if let frames = topography.trajectoryDisplayFrames, frames.count > 1 {
                trajectoryFrameStrip(frames: frames, topography: topography)
            } else if let layout = recording.sensorLayout {
                TopomapView(
                    layout: layout,
                    values: topography.channelValues.map(Double.init),
                    timeSeconds: topography.referenceTimeSeconds,
                    fixedScale: nil,
                    showsHeader: false,
                    colorBarPlacement: .trailing,
                    minimumMapHeight: 150
                )
                .frame(width: 230, height: 170)
            } else {
                Text("No sensor layout — topography matching still ran.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 230, height: 170, alignment: .topLeading)
            }
        }
    }

    /// Horizontal strip of topomap thumbnails for map-sequence mode. Clicking
    /// the \u{2715} on a frame removes it from the match score; this strip is the
    /// only scalp-map display for map-sequence mode (no separate large preview
    /// — the sequence already shows how the map evolves over time).
    @ViewBuilder
    func trajectoryFrameStrip(
        frames: [ArtifactTrajectoryFrame],
        topography: ArtifactTemplateTopography
    ) -> some View {
        let thumbW: CGFloat = 126
        let thumbH: CGFloat = 108

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text("Map sequence frames")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !template.trajectoryExcludedFrameIndices.isEmpty {
                    Text("· \(template.trajectoryExcludedFrameIndices.count) removed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !template.trajectoryExcludedFrameIndices.isEmpty {
                    Button("Restore All") { template.trajectoryExcludedFrameIndices.removeAll() }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }

            Text("Click the \u{2715} to remove a frame from the match score.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 10) {
                    ForEach(frames) { frame in
                        trajectoryFrameThumb(
                            frame: frame,
                            thumbW: thumbW,
                            thumbH: thumbH
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    func trajectoryFrameThumb(
        frame: ArtifactTrajectoryFrame,
        thumbW: CGFloat,
        thumbH: CGFloat
    ) -> some View {
        let isExcluded = template.trajectoryExcludedFrameIndices.contains(frame.frameIndex)

        VStack(spacing: 2) {
            Group {
                if let layout = recording.sensorLayout {
                    TopomapView(
                        layout: layout,
                        values: frame.channelValues.map(Double.init),
                        timeSeconds: frame.timeSeconds,
                        fixedScale: nil,
                        showsHeader: false,
                        colorBarPlacement: .none,
                        minimumMapHeight: thumbH,
                        contentPadding: 0
                    )
                    .frame(width: thumbW, height: thumbH)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: thumbW, height: thumbH)
                }
            }
            .opacity(isExcluded ? 0.35 : 1.0)
            .overlay(alignment: .topTrailing) {
                Button {
                    if isExcluded {
                        template.trajectoryExcludedFrameIndices.remove(frame.frameIndex)
                    } else {
                        template.trajectoryExcludedFrameIndices.insert(frame.frameIndex)
                    }
                } label: {
                    Image(systemName: isExcluded ? "arrow.uturn.backward.circle.fill" : "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isExcluded ? Color.accentColor : Color.secondary)
                        .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                }
                .buttonStyle(.plain)
                .help(isExcluded ? "Restore this frame to the match score" : "Remove this frame from the match score")
                .padding(3)
            }

            Text(String(format: "+%.0f ms", frame.relativeSeconds * 1000))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color.secondary.opacity(isExcluded ? 0.6 : 1.0))
                .frame(width: thumbW)
        }
    }

    func useWaveformMatches(_ result: ArtifactTemplateDetectionResult, signal: MFFSignalData) {
        guard let range = template.selectionRange else { return }
        let configuration = artifactTemplateConfiguration(for: signal, range: range)
        upsertDefinedArtifact(from: result, configuration: configuration, source: .waveform)
        artifactVM.events = definedArtifactEventList()
        selectedEventCodes = [configuration.eventCode]
        showsEventsPanel = true
        template.confirmedSource = .waveform
        artifactVM.statusMessage = "\(result.selectedEvents.count) waveform matches"
    }

    func useTopographyMatches(_ result: ArtifactTemplateDetectionResult, signal: MFFSignalData? = nil) {
        if let range = template.selectionRange,
           let signalForConfiguration = signal ?? recording.signal {
            let configuration = artifactTemplateConfiguration(for: signalForConfiguration, range: range)
            upsertDefinedArtifact(from: result, configuration: configuration, source: .topography)
        } else if let artifactID = template.definedArtifactID,
                  let index = template.definedArtifacts.firstIndex(where: { $0.id == artifactID }) {
            let name = template.definedArtifacts[index].name
            template.definedArtifacts[index].events = definedArtifactEvents(result.topographyEvents, label: name)
            template.definedArtifacts[index].topography = result.topographyReference
            invalidateOBSVarianceCache(for: artifactID)
            clearAppliedArtifactCleaning()
        }
        artifactVM.events = template.definedArtifacts.isEmpty ? result.topographyEvents : definedArtifactEventList()
        selectedEventCodes = [template.eventCode.trimmingCharacters(in: .whitespacesAndNewlines)]
        showsEventsPanel = true
        template.confirmedSource = .topography
        artifactVM.statusMessage = "\(result.topographyEvents.count) topography matches"
    }

    func isCenteredArtifactDetectionEvent(_ event: MFFEvent) -> Bool {
        guard event.durationSeconds != nil else { return false }
        if event.sourceFile == EyeArtifactThresholdDetector.sourceFile {
            return true
        }
        return template.definedArtifacts.contains { artifact in
            artifact.events.contains { $0.id == event.id }
        }
    }

    func artifactTemplateChannelChipColor(
        _ summary: ArtifactTemplateChannelSummary,
        average: ArtifactTemplateAverage
    ) -> Color {
        if template.clickedChannel == summary.channelIndex {
            return Color.blue.opacity(0.24)
        }

        if template.selectedChannel == summary.channelIndex {
            return Color.blue.opacity(0.18)
        }

        if average.selectedChannelIndices.contains(summary.channelIndex) {
            return Color.accentColor.opacity(0.14)
        }

        return Color.secondary.opacity(0.08)
    }

    func selectArtifactTemplateChannel(_ channelIndex: Int, autoApplyIn signal: MFFSignalData? = nil) {
        template.clickedChannel = channelIndex
        template.selectedChannel = channelIndex
        template.channelScope = .clickedChannel
        template.customChannels = "\(channelIndex + 1)"
        guard let signal,
              !template.isApplying else {
            return
        }
        if template.result != nil {
            applyArtifactTemplate(to: signal, preferredSource: .waveform)
        }
    }

    func applyArtifactTemplate(
        to signal: MFFSignalData,
        preferredSource: ArtifactDefinitionResultSource = .waveform
    ) {
        guard let range = template.selectionRange else {
            template.statusMessage = "Highlight a waveform region before applying."
            return
        }

        let selectedChannels = artifactTemplateSelectedChannels(in: signal)
        guard !selectedChannels.isEmpty else {
            template.statusMessage = "Choose at least one readable channel."
            return
        }

        let configuration = artifactTemplateConfiguration(for: signal, range: range)

        template.isApplying = true
        template.statusMessage = nil
        template.scanCompleted = 0
        template.scanTotal = 0

        let signature = artifactScanSignature
        artifactTemplateTask?.cancel()
        let sessionID = recordingSessionID
        artifactTemplateTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                ArtifactTemplateDetector.detect(in: signal, configuration: configuration) { completed, total in
                    Task { @MainActor in
                        self.template.scanCompleted = completed
                        self.template.scanTotal = total
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

            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            template.result = result
            template.lastScanSignature = signature
            template.selectedChannel = nil
            let source: ArtifactDefinitionResultSource = preferredSource == .topography ? .topography : .waveform
            upsertDefinedArtifact(from: result, configuration: configuration, source: source)
            artifactVM.events = definedArtifactEventList()
            selectedEventCodes = [configuration.eventCode]
            showsEventsPanel = true
            template.confirmedSource = source
            artifactVM.statusMessage = source == .topography
                ? "\(result.topographyEvents.count) topography matches"
                : "\(result.selectedEvents.count) template matches"
            template.isApplying = false
            artifactTemplateTask = nil
        }
    }

    func upsertDefinedArtifact(
        from result: ArtifactTemplateDetectionResult,
        configuration: ArtifactTemplateConfiguration,
        source: ArtifactDefinitionResultSource = .waveform
    ) {
        let name = configuration.name.nilIfEmpty ?? "Artifact"
        let eventCode = configuration.eventCode.nilIfEmpty ?? name
        let selectedEvents = definedArtifactEvents(
            source == .topography ? result.topographyEvents : result.selectedEvents,
            label: name
        )
        // Continuous-scan events (see ArtifactTopographyScanStyle) genuinely
        // vary in duration, and SSP/PCA — the usual Topography default —
        // can't use a per-event window (it pools every event into one shared
        // basis, which needs uniform-length epochs). Default those to Regress
        // with variable-event-duration on, so a freshly-detected Continuous
        // artifact is usable out of the box instead of quietly performing
        // poorly until the user finds and flips both settings themselves.
        let isContinuousSourced = source == .topography
            && result.topographyEvents.first?.sourceFile.hasPrefix("Continuous") == true
        let artifact = DefinedArtifact(
            id: template.definedArtifactID ?? UUID(),
            type: template.type,
            name: name,
            eventCode: eventCode,
            events: selectedEvents,
            selectedChannelIndices: configuration.selectedChannelIndices,
            windowSizeSeconds: configuration.windowSizeSeconds,
            average: result.templateAverage,
            topography: source == .topography ? result.topographyReference : nil,
            cleaningMethod: isContinuousSourced ? .regression : (source == .topography ? .sspPCA : .obs),
            obsStrategy: source == .topography ? .topographyAligned : .standard,
            usesVariableEventDuration: isContinuousSourced,
            appliedMethod: nil,
            cleanedAt: nil
        )

        if let index = template.definedArtifacts.firstIndex(where: { $0.id == artifact.id }) {
            let previous = template.definedArtifacts[index]
            template.definedArtifacts[index] = artifact
            template.definedArtifacts[index].preserveCleaningSettings(from: previous)
        } else {
            template.definedArtifacts.append(artifact)
            registerPSADefinedArtifactForRejection(artifact.id)
        }
        invalidateOBSVarianceCache(for: artifact.id)
        template.definedArtifactID = artifact.id
        clearAppliedArtifactCleaning()
    }

    /// Debounces `refreshDefinedArtifactIdentity()` behind the Name/Event Code
    /// fields' `.onChange` — those fire on every keystroke, and the refresh
    /// remaps every event in the artifact (plus rebuilds `artifactVM.events`
    /// from every defined artifact), which is O(events) and was making typing
    /// visibly laggy for artifacts with more than a couple hundred events
    /// (routine for Continuous-scan artifacts). Waiting for a short pause in
    /// typing means the remap runs once per edit instead of once per character.
    func scheduleDefinedArtifactIdentityRefresh() {
        artifactIdentityRefreshTask?.cancel()
        artifactIdentityRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            refreshDefinedArtifactIdentity()
        }
    }

    /// Re-stamps the current Name/Event Code onto the already-detected events
    /// of the in-progress defined artifact, without requiring a rescan —
    /// renaming doesn't change *which* samples were detected, just how
    /// they're labeled, so there's no need to redo the (expensive) scan just
    /// to reflect a text-field edit. No-ops until a scan has actually been
    /// run/confirmed at least once (`template.definedArtifactID` is nil).
    func refreshDefinedArtifactIdentity() {
        guard let artifactID = template.definedArtifactID,
              let index = template.definedArtifacts.firstIndex(where: { $0.id == artifactID }) else { return }

        let name = template.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Artifact"
        let eventCode = template.eventCode.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? name
        let previousEventCode = template.definedArtifacts[index].eventCode

        template.definedArtifacts[index].name = name
        template.definedArtifacts[index].eventCode = eventCode
        template.definedArtifacts[index].events = template.definedArtifacts[index].events.map { event in
            MFFEvent(
                id: event.id,
                code: eventCode,
                label: name,
                eventDescription: event.eventDescription,
                cell: event.cell,
                beginTimeSeconds: event.beginTimeSeconds,
                rawBeginTime: event.rawBeginTime,
                sourceFile: event.sourceFile,
                durationSeconds: event.durationSeconds
            )
        }

        artifactVM.events = definedArtifactEventList()
        // Keep the Events panel's code filter pointed at the (possibly
        // renamed) code, so the just-renamed events don't silently vanish
        // from view because the filter still names the old code.
        if selectedEventCodes.contains(previousEventCode), previousEventCode != eventCode {
            selectedEventCodes.remove(previousEventCode)
            selectedEventCodes.insert(eventCode)
        }
    }

    func definedArtifactEvents(_ events: [MFFEvent], label: String) -> [MFFEvent] {
        events.map { event in
            MFFEvent(
                id: event.id,
                code: event.code,
                label: label,
                eventDescription: event.eventDescription,
                cell: event.cell,
                beginTimeSeconds: event.beginTimeSeconds,
                rawBeginTime: event.rawBeginTime,
                sourceFile: event.sourceFile,
                durationSeconds: event.durationSeconds
            )
        }
    }

    func definedArtifactEventList() -> [MFFEvent] {
        template.definedArtifacts.flatMap { artifact in
            definedArtifactEvents(artifact.events, label: artifact.name)
        }
    }

    func deleteDefinedArtifact(id: DefinedArtifact.ID) {
        guard let index = template.definedArtifacts.firstIndex(where: { $0.id == id }) else { return }
        let name = template.definedArtifacts[index].name
        template.definedArtifacts.remove(at: index)

        if template.definedArtifactID == id {
            template.definedArtifactID = nil
            template.result = nil
            template.confirmedSource = nil
            template.lastScanSignature = nil
            template.selectedChannel = nil
        }

        invalidateOBSVarianceCache(for: id)
        removePSADefinedArtifactForRejection(id)
        refreshAfterDeletingArtifacts(message: "Deleted \(name).")
    }

    func deleteAllDefinedArtifacts() {
        guard !template.definedArtifacts.isEmpty else { return }
        template.definedArtifacts.removeAll()
        template.definedArtifactID = nil
        template.result = nil
        template.confirmedSource = nil
        template.lastScanSignature = nil
        template.selectedChannel = nil
        invalidateOBSVarianceCache()
        epoching.skippedDefinedArtifactIDs.removeAll()
        epoching.knownArtifactIDsForRejection.removeAll()
        refreshAfterDeletingArtifacts(message: "Deleted all defined artifacts.")
    }

    func registerPSADefinedArtifactForRejection(_ id: DefinedArtifact.ID) {
        if epoching.knownArtifactIDsForRejection.insert(id).inserted {
            epoching.skippedDefinedArtifactIDs.insert(id)
        }
    }

    func removePSADefinedArtifactForRejection(_ id: DefinedArtifact.ID) {
        epoching.skippedDefinedArtifactIDs.remove(id)
        epoching.knownArtifactIDsForRejection.remove(id)
    }

    func reconcilePSADefinedArtifactRejectionSelections() {
        let currentIDs = Set(template.definedArtifacts.map(\.id))
        epoching.skippedDefinedArtifactIDs.formIntersection(currentIDs)
        epoching.knownArtifactIDsForRejection.formIntersection(currentIDs)
        for id in currentIDs where !epoching.knownArtifactIDsForRejection.contains(id) {
            registerPSADefinedArtifactForRejection(id)
        }
    }

    func invalidateOBSVarianceCache(for artifactID: DefinedArtifact.ID? = nil) {
        guard let artifactID else {
            template.obsVarianceReportCache.removeAll()
            return
        }
        let prefix = "\(artifactID.uuidString)|"
        template.obsVarianceReportCache = template.obsVarianceReportCache.filter { !$0.key.hasPrefix(prefix) }
    }

    func refreshAfterDeletingArtifacts(message: String) {
        clearAppliedArtifactCleaning()
        artifactVM.events = definedArtifactEventList()
        artifactVM.detectionRefreshToken += 1
        artifactVM.statusMessage = template.definedArtifacts.isEmpty ? nil : "\(template.definedArtifacts.count) artifact definitions"
        artifactVM.cleaningStatusMessage = message
    }

    func artifactCleaningSheet(for signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Clean Artifacts")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(template.definedArtifacts.count) defined")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if template.definedArtifacts.isEmpty {
                ContentUnavailableView(
                    "No Artifacts Defined",
                    systemImage: "scope",
                    description: Text("Use Define Artifact first, then return here to choose a cleanup method.")
                )
                .frame(minHeight: 220)
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                        GridRow {
                            Text("")
                                .frame(width: 24)
                            Text("Type")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("Name")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ArtifactTemplateFieldLabel(title: "Treatment", help: artifactTreatmentHelpText)
                        }

                        Divider()
                            .gridCellColumns(4)

                        ForEach($template.definedArtifacts) { $artifact in
                            GridRow {
                                Button {
                                    deleteDefinedArtifact(id: artifact.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(artifactVM.isCleaning)
                                .help("Delete this artifact definition.")
                                .frame(width: 24)

                                Picker("Type", selection: $artifact.type) {
                                    ForEach(DefinedArtifactType.allCases) { type in
                                        Text(type.rawValue).tag(type)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 150)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(artifact.name)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(1)
                                    Text("\(artifact.eventCount) events · \(artifact.eventCode)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 210, alignment: .leading)

                                artifactTreatmentControl(
                                    artifact: $artifact,
                                    signal: signal,
                                    cleanedSignal: artifactVM.cleanedSignal,
                                    layout: recording.sensorLayout
                                )
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 220, maxHeight: 340)
            }

            if artifactVM.isCleaning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: artifactVM.cleaningProgress?.fraction ?? 0)
                        .progressViewStyle(.linear)
                    Text(artifactCleaningProgressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let cleaningStatus = artifactVM.cleaningStatusMessage {
                Text(cleaningStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Button("Restore Original") {
                    restoreArtifactCleaning()
                }
                .disabled(artifactVM.cleanedSignal == nil && template.definedArtifacts.allSatisfy { $0.appliedMethod == nil })

                Spacer()

                Button("Close") {
                    artifactVM.showsCleaningSheet = false
                    // Closing without applying cleaning skips this replay step.
                    if replay.state.isAwaitingDecision { replay.resume(.skip) }
                }
                .keyboardShortcut(.cancelAction)

                Button("Apply") {
                    applyArtifactCleaning(to: signal)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(artifactVM.isCleaning || !template.definedArtifacts.contains { $0.cleaningMethod.removesArtifact })
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 22)
        .frame(width: 800)
    }

    func artifactTreatmentControl(
        artifact: Binding<DefinedArtifact>,
        signal: MFFSignalData,
        cleanedSignal: MFFSignalData?,
        layout: SensorLayout?
    ) -> some View {
        HStack(spacing: 8) {
            Picker("Treatment", selection: artifact.cleaningMethod) {
                ForEach(ArtifactCleaningMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            .help(artifactTreatmentHelpText)

            if artifact.wrappedValue.cleaningMethod == .obs || artifact.wrappedValue.cleaningMethod == .sspPCA {
                ArtifactOBSOptionsButton(
                    artifact: artifact,
                    signal: signal,
                    reportCache: $template.obsVarianceReportCache,
                    onSettingsChange: clearAppliedArtifactCleaning
                )
            }

            if artifact.wrappedValue.cleaningMethod.supportsVariableEventDuration {
                ArtifactLocalTemplateOptionsButton(
                    artifact: artifact,
                    onSettingsChange: clearAppliedArtifactCleaning
                )
            }

            if let appliedMethod = artifact.wrappedValue.appliedMethod {
                if appliedMethod == artifact.wrappedValue.cleaningMethod {
                    HStack(spacing: 6) {
                        Label("Applied", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        ArtifactCleaningPreviewButton(
                            artifact: artifact.wrappedValue,
                            beforeSignal: signal,
                            afterSignal: cleanedSignal,
                            layout: layout,
                            cleaningPreviewCache: template.cleaningPreviewCache
                        )
                    }
                } else {
                    Text("Applied: \(appliedMethod.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 340, alignment: .leading)
    }

    var artifactTreatmentHelpText: String {
        """
        Do Nothing: keep the artifact definition but do not alter the data.
        Regress: subtracts the average artifact waveform; useful as a historical/simple comparison.
        OBS: subtracts the mean artifact plus residual PCA components with padded, tapered edges; Options includes topography-aware OBS strategies.
        SSP/PCA: projects out stable spatial artifact patterns across channels; default for topography-defined artifacts.
        MAS/MAR: local (moving-window) median template — robust to an occasional distorted event; MAR additionally scales the template by a least-squares fit.
        wAAS/wAAR: exponentially weighted template (Goldman 2000); Options defaults to AMRI global weighting, where every valid event contributes by decay^distance, and wAAR additionally scales the template by a least-squares fit.

        Regress and MAS/MAR/wAAS/wAAR can size each event's correction window from that event's own measured duration instead of one shared window — see Options — needed for artifacts whose events genuinely vary in length (auto-enabled for Continuous topography scanning). For BCG artifacts, Local-template Options also includes AMRI BCG epoch preprocessing for R-marker-style inputs; EVA's default assumes events are already centered. OBS and SSP/PCA can't: they pool every event into one shared basis, which requires uniform-length epochs.
        """
    }

    var artifactCleaningProgressText: String {
        guard let progress = artifactVM.cleaningProgress else {
            return "Preparing artifact cleanup..."
        }
        let artifactPosition = progress.artifactCount > 1
            ? "\(progress.artifactIndex) of \(progress.artifactCount): "
            : ""
        let detail = progress.detail.map { " · \($0)" } ?? ""
        switch progress.phase {
        case .preparing:
            return "Setting up \(artifactPosition)\(progress.artifactName) (\(progress.artifactTotal) events) with \(progress.method.rawValue)\(detail)"
        case .cleaning:
            let current = min(progress.artifactCompleted, progress.artifactTotal)
            let overall = progress.total > progress.artifactTotal
                ? " · \(progress.completed) of \(progress.total) overall"
                : ""
            return "Cleaning \(current) of \(progress.artifactTotal) \(artifactPosition)\(progress.artifactName) events with \(progress.method.rawValue)\(overall)"
        case .finalizing:
            return "Finalizing \(artifactPosition)\(progress.artifactName) with \(progress.method.rawValue)\(detail)"
        }
    }

    func setArtifactCleaningEnabled(_ isEnabled: Bool) {
        guard artifactVM.cleanedSignal != nil,
              artifactVM.cleaningIsEnabled != isEnabled else {
            return
        }
        artifactVM.cleaningIsEnabled = isEnabled
        invalidateEpochsForSignalChange()
        invalidateInterpolations()
    }

}
