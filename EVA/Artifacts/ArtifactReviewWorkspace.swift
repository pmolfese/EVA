import SwiftUI

/// A stable frame keeps workflow tabs in the same place throughout artifact work.
struct ArtifactWorkspace<Content: View>: View {
    @Binding var tab: ArtifactTemplateViewModel.WorkspaceTab
    let isBusy: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Picker("Artifact workflow", selection: $tab) {
                ForEach(ArtifactTemplateViewModel.WorkspaceTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isBusy)
            .frame(width: 360)
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .background(.primary.opacity(0.025))
            .overlay(alignment: .bottom) { Divider() }

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 1060, height: 820)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct ArtifactReviewWorkspace: View {
    @Binding var artifacts: [DefinedArtifact]
    @Binding var selectedArtifactID: UUID?
    let signal: MFFSignalData
    let excludedChannels: Set<Int>
    let sensorLayoutName: String?
    let sensorLayout: SensorLayout?
    let onChange: () -> Void
    let onClose: () -> Void
    let onClean: () -> Void

    @State private var analysis: ArtifactReviewAnalysis?
    @State private var loadedKey = ""
    @State private var selectedEventID: String?
    @State private var usesSpatialGroups = true
    @State private var spatialHierarchy: ArtifactSpatialHierarchy?
    @State private var spatialLoadedKey = ""
    @State private var spatialGroupID: Int?
    @State private var spatialThreshold = 0.85
    @State private var spatialPolarityOverride: ArtifactSpatialPolarityMode?
    @State private var spatialSimilarityMetric = ArtifactSpatialSimilarityMetric.globalPearson
    @State private var waveformGrouping: ArtifactWaveformGroupingResult?
    @State private var waveformLoadedKey = ""
    @State private var waveformGroupID: Int?
    @State private var waveformThreshold = 0.90
    @State private var waveformPolarityOverride: ArtifactWaveformPolarityMode?
    @State private var band: ArtifactReviewBand?
    @State private var channel = 0
    @State private var tilePreview = ArtifactReviewTilePreview.waveforms
    @State private var displayMode = ArtifactReviewDisplayMode.top3
    @State private var contextSeconds = 0.5
    @State private var showsSplit = false
    @State private var splitName = "Artifact variation"
    @State private var splitMethod = ArtifactCleaningMethod.obs
    @State private var ruleUndo: [String: ArtifactReviewChoice]?
    @FocusState private var eventFocus: Bool

    private var reviewable: [DefinedArtifact] {
        artifacts.filter { ArtifactReviewEngine.canReview($0) && !ArtifactReviewEngine.candidates(for: $0).isEmpty }
    }
    private var selected: DefinedArtifact? {
        reviewable.first { $0.id == selectedArtifactID } ?? reviewable.first
    }
    private var analysisKey: String {
        guard let artifact = selected else { return "empty" }
        var hasher = Hasher()
        hasher.combine(signal.dataRevision)
        hasher.combine(artifact.id)
        hasher.combine(artifact.windowSizeSeconds)
        hasher.combine(artifact.obsEdgeTaperSeconds)
        hasher.combine(artifact.selectedChannelIndices)
        hasher.combine(artifact.reviewState?.referenceEventIDs ?? ArtifactReviewEngine.candidates(for: artifact).map(\.id))
        hasher.combine(ArtifactReviewEngine.candidates(for: artifact))
        hasher.combine(excludedChannels.sorted())
        hasher.combine(sensorLayout?.positions.map(\.channelIndex))
        return String(hasher.finalize())
    }
    private var currentAnalysis: ArtifactReviewAnalysis? { loadedKey == analysisKey ? analysis : nil }
    private var defaultSpatialPolarityMode: ArtifactSpatialPolarityMode {
        switch selected?.type {
        case .ocular, .saccadicSpike, .corneoRetinal: return .ignoreGlobalPolarity
        default: return .signed
        }
    }
    private var spatialPolarityMode: ArtifactSpatialPolarityMode {
        spatialPolarityOverride ?? defaultSpatialPolarityMode
    }
    private var waveformPolarityMode: ArtifactWaveformPolarityMode {
        waveformPolarityOverride ?? (spatialPolarityMode == .ignoreGlobalPolarity ? .orientToSpatialFamily : .preserve)
    }
    private var effectiveSpatialSimilarityMetric: ArtifactSpatialSimilarityMetric {
        spatialPolarityMode == .signed ? .globalPearson : spatialSimilarityMetric
    }
    private var spatialScoreLabel: String {
        effectiveSpatialSimilarityMetric == .globalPearson ? (spatialPolarityMode == .signed ? "r" : "|r|") : "score"
    }
    private var spatialTaskKey: String {
        usesSpatialGroups && currentAnalysis != nil
            ? "\(analysisKey)/spatial/\(spatialPolarityMode.rawValue)/\(effectiveSpatialSimilarityMetric.rawValue)" : ""
    }
    private var currentSpatial: ArtifactSpatialHierarchy? { spatialLoadedKey == spatialTaskKey ? spatialHierarchy : nil }
    private var spatialGroups: [ArtifactSpatialGroup] { currentSpatial?.groups(minimumCorrelation: spatialThreshold) ?? [] }
    private var selectedSpatialFamily: ArtifactSpatialGroup? {
        spatialGroups.first { $0.id == spatialGroupID }
    }
    private var waveformTaskKey: String {
        guard usesSpatialGroups, let family = selectedSpatialFamily else { return "" }
        return "\(spatialTaskKey)/waveform/\(family.id)/\(waveformPolarityMode.rawValue)"
    }
    private var currentWaveform: ArtifactWaveformGroupingResult? {
        !waveformTaskKey.isEmpty && waveformLoadedKey == waveformTaskKey ? waveformGrouping : nil
    }
    private var waveformEventIDs: Set<String>? {
        guard let id = waveformGroupID, let result = currentWaveform else { return nil }
        return Set(id == -1 ? result.hierarchy.unassignedIDs
            : result.hierarchy.groups(minimumCorrelation: waveformThreshold).first { $0.id == id }?.eventIDs ?? [])
    }
    private var spatialEventIDs: Set<String>? {
        guard usesSpatialGroups, let id = spatialGroupID else { return nil }
        return Set(id == -1 ? currentSpatial?.unassignedIDs ?? [] : spatialGroups.first { $0.id == id }?.eventIDs ?? [])
    }
    private var examples: [ArtifactReviewExample] {
        let spatialIDs = spatialEventIDs
        let waveformIDs = waveformEventIDs
        return (currentAnalysis?.examples ?? []).filter {
            if usesSpatialGroups {
                return (spatialIDs?.contains($0.id) ?? true) && (waveformIDs?.contains($0.id) ?? true)
            }
            return band == nil || $0.band == band
        }.sorted {
            if $0.correlation == $1.correlation { return $0.event.centerTimeSeconds < $1.event.centerTimeSeconds }
            return ($0.correlation ?? -2) > ($1.correlation ?? -2)
        }
    }
    private var navigation: ArtifactReviewNavigation {
        let items = examples
        return ArtifactReviewNavigation(count: items.count,
            selectedIndex: items.firstIndex { $0.id == selectedEventID } ?? 0)
    }
    private var topographyScale: Double {
        let items = examples
        let page = ArtifactReviewNavigation(count: items.count,
            selectedIndex: items.firstIndex { $0.id == selectedEventID } ?? 0).visibleRange
        return max(items[page].compactMap { $0.topography?.maximumAbsoluteAmplitude }.max() ?? 1, 1e-6)
    }
    private var selectedExample: ArtifactReviewExample? {
        examples.first { $0.id == selectedEventID } ?? examples.first
    }
    private var activeChannel: Int {
        currentAnalysis?.channelIndices.contains(channel) == true ? channel : currentAnalysis?.channelIndices.first ?? 0
    }
    private var rules: ArtifactReviewRules { selected?.reviewState?.rules ?? ArtifactReviewRules() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                classList
                Divider()
                if let artifact = selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            reviewHeader(artifact)
                            autoRules(artifact)
                            if let result = currentAnalysis {
                                if result.channelIndices.isEmpty {
                                    Text("No usable definition channels. Check the definition’s channel selection and marked-bad channels.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Picker("Group by", selection: $usesSpatialGroups) {
                                    Text("Waveform bands").tag(false)
                                    Text("Spatial groups").tag(true)
                                }.pickerStyle(.segmented).frame(width: 310)
                                if usesSpatialGroups {
                                    spatialGroupingPreview(result)
                                    waveformGroupingPreview()
                                }
                                else { similarityGroups(result) }
                                splitControls(artifact)
                                eventWorkspace(artifact, result)
                            } else {
                                ProgressView("Comparing detected examples…")
                                    .frame(maxWidth: .infinity, minHeight: 330)
                            }
                        }
                        .padding(18)
                    }
                } else {
                    ContentUnavailableView("No Detected Artifacts", systemImage: "waveform",
                        description: Text("Run an artifact detector or define an artifact, then review its matches here."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text("Review selects the events used to fit and apply each artifact’s treatment.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Button("Clean Artifacts…", action: onClean)
                    .disabled(!artifacts.contains { !$0.events.isEmpty })
            }.padding(16)
        }
        .frame(height: 770)
        .task(id: analysisKey) { await loadAnalysis() }
        .task(id: spatialTaskKey) { await loadSpatialGrouping() }
        .task(id: waveformTaskKey) { await loadWaveformGrouping() }
        .onChange(of: waveformTaskKey) { _, _ in
            waveformGroupID = nil
        }
        .onChange(of: waveformThreshold) { _, _ in
            waveformGroupID = nil; selectedEventID = nil
        }
        .onChange(of: spatialThreshold) { _, _ in
            spatialGroupID = nil; selectedEventID = nil; showsSplit = false
        }
        .onChange(of: usesSpatialGroups) { _, _ in
            spatialGroupID = nil; band = nil; selectedEventID = nil; showsSplit = false
        }
        .onChange(of: analysisKey) { _, _ in
            ruleUndo = nil; spatialGroupID = nil; selectedEventID = nil; showsSplit = false
        }
        .onChange(of: selected?.id) { _, _ in
            band = nil
            spatialGroupID = nil
            spatialPolarityOverride = nil
            spatialSimilarityMetric = .globalPearson
            waveformPolarityOverride = nil
            selectedEventID = nil
            showsSplit = false
            ruleUndo = nil
        }
    }

    private var classList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text("ARTIFACTS & CLASSES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ArtifactReviewHelp(title: "Artifacts and classes", text: "Select the detector or artifact class to review. Indented classes are shape groups split from an original definition. Each class can have its own average, correction window, and cleaning treatment.")
                }
                    .padding(.bottom, 6)
                ForEach(reviewable) { artifact in
                    Button {
                        selectedArtifactID = artifact.id
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(artifact.name).font(.callout.weight(.medium)).lineLimit(2)
                            Text("\(ArtifactReviewEngine.candidates(for: artifact).count) examples · \(artifact.cleaningMethod.rawValue)")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("\(artifact.events.count) included")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(selected?.id == artifact.id ? Color.accentColor.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, artifact.reviewState?.sourceArtifactID == nil ? 0 : 10)
                }
            }.padding(12)
        }.frame(width: 180)
    }

    private func reviewHeader(_ artifact: DefinedArtifact) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(artifact.name).font(.title3.weight(.semibold))
                let choices = ArtifactReviewEngine.candidates(for: artifact).map { ArtifactReviewEngine.choice(for: $0.id, artifact: artifact).decision }
                HStack(spacing: 5) {
                    Text("\(choices.filter { $0 == .include }.count) included · \(choices.filter { $0 == .exclude }.count) excluded · \(choices.filter { $0 == .hold }.count) held · \(ArtifactReviewEngine.candidates(for: artifact).count - (artifact.reviewState?.choices.count ?? 0)) unreviewed")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    ArtifactReviewHelp(title: "Review counts", text: "Included events are eligible for cleaning. Held and excluded events stay out of the active cleaning event set. Unreviewed counts examples without an explicit decision; they initially remain included, so it overlaps the included count. Opening Review does not remove anything.")
                }
            }
            Spacer()
            ArtifactReviewHelp(title: "Treatment", text: "Choose the cleaning method for this class. This sets the method only; use the Clean tab to configure it and Apply cleaning. OBS fits a basis of artifact shapes; SSP/PCA removes the artifact subspace; Regress subtracts a fitted template. Do Nothing leaves this class uncorrected.")
            Picker("Treatment", selection: Binding(
                get: { selected?.cleaningMethod ?? .doNothing },
                set: { value in edit { $0.cleaningMethod = value; ArtifactReviewEngine.commitChoices(&$0) } }
            )) {
                ForEach(cleaningMethods(artifact)) { method in Text(method.rawValue).tag(method) }
            }.frame(width: 205)
        }
    }

    private func autoRules(_ artifact: DefinedArtifact) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Text("Include when r ≥ \(rules.includeCorrelation, specifier: "%.2f")").font(.caption)
                            ArtifactReviewHelp(title: "Include threshold", text: "r is signed waveform-shape correlation across the definition channels, after centering each channel. Values near 1 have a similar shape and polarity; negative values have opposite polarity. Scores at or above this threshold are proposed for inclusion unless a safety limit excludes them. Changing a slider only changes the preview until Apply rules.")
                        }
                        Slider(value: ruleBinding(\.includeCorrelation), in: 0.50...0.99, step: 0.01)
                        HStack(spacing: 5) {
                            Text("Exclude when r < \(rules.excludeCorrelation, specifier: "%.2f")").font(.caption)
                            ArtifactReviewHelp(title: "Exclude threshold", text: "Scores below this threshold are proposed for exclusion. Scores between the two thresholds are held for review. Examples without a usable similarity score are also held, unless a safety limit excludes them. This is a shape score, not a probability that an event is an artifact.")
                        }
                        Slider(value: ruleBinding(\.excludeCorrelation), in: -1...0.95, step: 0.01)
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            HStack(spacing: 5) {
                                Toggle("Max peak (µV)", isOn: ruleBinding(\.limitsPeak)).toggleStyle(.checkbox)
                                ArtifactReviewHelp(title: "Maximum peak", text: "When checked, propose exclusion if the largest absolute, baseline-centered amplitude in the core window across the definition channels exceeds this value. This gate is applied before similarity thresholds. It does not measure every channel in the recording.")
                            }
                            TextField("µV", value: ruleBinding(\.maximumPeakMicrovolts), format: .number)
                                .frame(width: 65).disabled(!rules.limitsPeak)
                        }
                        HStack {
                            HStack(spacing: 5) {
                                Toggle("Max duration (s)", isOn: ruleBinding(\.limitsDuration)).toggleStyle(.checkbox)
                                ArtifactReviewHelp(title: "Maximum duration", text: "When checked, propose exclusion for measured event durations longer than this limit. Duration is the detector’s measured span when available, not the correction-window width. Unknown durations do not trigger this gate.")
                            }
                            TextField("Seconds", value: ruleBinding(\.maximumDurationSeconds), format: .number)
                                .frame(width: 65).disabled(!rules.limitsDuration)
                        }
                        HStack(spacing: 5) {
                            Toggle("Require complete padded window", isOn: ruleBinding(\.requiresCompleteWindow)).toggleStyle(.checkbox)
                            ArtifactReviewHelp(title: "Complete padded window", text: "Require the core correction window plus its edge taper to fit inside the recording. Events too close to the recording boundaries are proposed for exclusion. The cleaner skips incomplete padded windows even if manually included.")
                        }
                        HStack(spacing: 5) {
                            Toggle("Measured span must fit core", isOn: ruleBinding(\.requiresSpanInsideCore)).toggleStyle(.checkbox)
                            ArtifactReviewHelp(title: "Measured span and core", text: "For threshold detections with known onset and offset, propose exclusion if their measured span extends outside the core correction window. Unknown spans do not trigger this gate. Widen Core (s) if the correction window is too short.")
                        }
                    }.font(.caption)
                }
                HStack {
                    if let result = currentAnalysis {
                        let choices = result.examples.map { ArtifactReviewEngine.proposedChoice(for: $0, artifact: artifact, rules: rules).decision }
                        Text("Preview: \(choices.filter { $0 == .include }.count) include · \(choices.filter { $0 == .exclude }.count) exclude · \(choices.filter { $0 == .hold }.count) hold")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        Toggle("Keep manual decisions", isOn: ruleBinding(\.preservesManualChoices))
                        ArtifactReviewHelp(title: "Keep manual decisions", text: "Preserve Include, Hold, or Exclude choices made by hand when applying rules. Turn this off to let the new rules replace those choices too. Undo rules restores earlier automatic choices and keeps subsequent manual decisions.")
                    }
                        .toggleStyle(.checkbox).font(.caption)
                    Button("Undo rules", action: undoRules).disabled(ruleUndo == nil)
                    Button("Apply rules") {
                        guard let result = currentAnalysis else { return }
                        ruleUndo = selected?.reviewState?.choices ?? [:]
                        edit { ArtifactReviewEngine.applyRules(rules, analysis: result, artifact: &$0) }
                    }.disabled(currentAnalysis == nil)
                }
                Text("Middle scores stay on hold. Unusable or flat examples have no similarity score. Peak and shape metrics use the selected definition channels; unknown durations/spans do not trigger those limits.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(5)
        } label: {
            HStack(spacing: 5) {
                Text("Auto-selection · preview before applying").font(.callout.weight(.medium))
                ArtifactReviewHelp(title: "Auto-selection", text: "These rules propose Include, Hold, or Exclude choices. Preview counts reflect the current rules and any protected manual choices. Apply rules commits the choices to this class and changes which events feed cleaning; it does not clean the recording. Undo rules reverses the last rule application while preserving manual decisions.")
            }
        }
    }

    private func spatialGroupingPreview(_ result: ArtifactReviewAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Spatial grouping · preview").font(.callout.weight(.medium))
                ArtifactReviewHelp(title: "Spatial grouping", text: "Groups compare electrode vectors at each event’s peak global field power, not rendered images. Features are centered and normalized, so strength is ignored. Signed mode keeps opposite polarities separate; Ignore global polarity treats a whole-map sign reversal as the same spatial axis, sign-aligns members before averaging, and retains each event’s orientation. A deterministic divisive spherical clustering tree is computed in the background and cached for this signal revision, definition, channel mask, polarity mode, and comparison cost. Broader/Finer cuts that tree using the minimum selected comparison score to each group’s centroid. The common sensor set must cover at least 80% of the largest usable map; sensors must occur in at least 90% of maps. Events missing any common sensor, incomplete windows, or flat maps remain unassigned. Cards show a representative real event, not an average map. Singletons can appear at fine settings; they are not evidence of a new artifact type. Select a spatial family to inspect waveform subgroups within it. These previews do not change inclusion, waveform scores, or cleaning. Spatial class splitting is a later step.")
                Spacer()
                Text("Preview only").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Picker("Polarity", selection: Binding(
                    get: { spatialPolarityMode },
                    set: { value in
                        spatialPolarityOverride = value
                        waveformPolarityOverride = nil
                        spatialGroupID = nil; waveformGroupID = nil; selectedEventID = nil
                    }
                )) {
                    ForEach(ArtifactSpatialPolarityMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented).frame(width: 310)
                ArtifactReviewHelp(title: "Spatial polarity", text: "Signed keeps globally inverted scalp fields in separate families. Ignore global polarity treats a field and its exact sign reversal as the same spatial axis using absolute correlation, while retaining every event’s + or − orientation relative to the family centroid. It does not take the absolute value of individual sensors. Ocular classes default to ignoring global polarity; other classes default to Signed.")
            }
            HStack(spacing: 8) {
                Picker("Comparison", selection: $spatialSimilarityMetric) {
                    ForEach(ArtifactSpatialSimilarityMetric.allCases) { metric in Text(metric.rawValue).tag(metric) }
                }
                .pickerStyle(.menu).frame(width: 260)
                .disabled(spatialPolarityMode == .signed)
                .onChange(of: spatialSimilarityMetric) { _, _ in
                    spatialGroupID = nil; waveformGroupID = nil; selectedEventID = nil
                }
                ArtifactReviewHelp(title: "Spatial comparison", text: "Global Pearson is the current whole-map |r| method. Local Pearson averages correlations over overlapping physical electrode neighborhoods after choosing one global sign. Spearman compares electrode ranks and is less sensitive to extreme amplitudes. Robust composite blends global, local, rank, and trimmed correlations. Information composite blends electrode-wise correlation with normalized mutual information, Hellinger histogram affinity, and symmetric correlation ratio; it is experimental because histogram estimates are weak for small montages. Signed polarity always uses ordinary Pearson. All modes preserve electrode identity and use one global orientation—individual regions never flip independently.")
            }
            HStack {
                Text("Broader").font(.caption)
                Slider(value: $spatialThreshold, in: 0.65...0.98, step: 0.01)
                    .accessibilityLabel("Spatial grouping detail")
                Text("Finer").font(.caption)
                Text("\(spatialScoreLabel) ≥ \(spatialThreshold, specifier: "%.2f")").font(.caption.monospacedDigit()).frame(width: 85)
            }
            if let hierarchy = currentSpatial {
                Text("\(spatialGroups.count) groups · \(hierarchy.features.count) mapped · \(hierarchy.unassignedIDs.count) unassigned · \(hierarchy.channels.count) shared sensors")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(spatialGroups.enumerated()), id: \.element.id) { index, group in
                            let example = result.examples.first { $0.id == group.representativeID }
                            Button {
                                spatialGroupID = group.id
                                selectedEventID = group.representativeID
                                eventFocus = true
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Group \(index + 1) · \(group.eventIDs.count)").font(.caption.weight(.medium))
                                    ArtifactReviewTopomapPreview(topography: example?.topography,
                                        layout: sensorLayout, scale: example?.topography?.maximumAbsoluteAmplitude ?? 1)
                                        .frame(height: 68)
                                    Text("Representative event").font(.caption2).foregroundStyle(.secondary)
                                    if group.polarityMode == .ignoreGlobalPolarity {
                                        Text("+ \(group.positiveOrientationCount) · − \(group.negativeOrientationCount)")
                                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                            .help("Orientation relative to this family’s canonical centroid; the raw event maps are unchanged.")
                                    }
                                    Text(group.eventIDs.count == 1 ? "Single example" : String(format: "Minimum %@ %.2f", group.similarityMetric == .globalPearson ? (group.polarityMode == .ignoreGlobalPolarity ? "|r|" : "r") : "score", group.minimumCorrelation))
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }.frame(width: 145).padding(8)
                                    .background(spatialGroupID == group.id ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                        if !hierarchy.unassignedIDs.isEmpty {
                            Button("Unassigned · \(hierarchy.unassignedIDs.count)") {
                                spatialGroupID = -1; selectedEventID = nil; eventFocus = true
                            }.tint(spatialGroupID == -1 ? .accentColor : .secondary)
                        }
                    }
                }.frame(height: spatialPolarityMode == .ignoreGlobalPolarity ? 150 : 133)
                if hierarchy.features.isEmpty {
                    Text("No comparable spatial features. Check the sensor layout, complete windows, and common good channels.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Building spatial groups in the background…")
                    .font(.caption).frame(maxWidth: .infinity, minHeight: 90)
            }
        }
    }

    @ViewBuilder
    private func waveformGroupingPreview() -> some View {
        if selectedSpatialFamily != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Text("Waveform subgroups · selected spatial family").font(.callout.weight(.medium))
                    ArtifactReviewHelp(title: "Waveform subgroups", text: "These groups compare temporal shapes only within the spatial family you selected; they cannot combine events from different spatial families. Up to five definition channels are chosen by typical normalized energy across this family and remain fixed across its events. Profiles use up to 64 points per channel, centered separately, then normalized together so overall strength is ignored while relative channel amplitudes and polarity are preserved. Each event is aligned to the family's representative usable waveform using a small shared time shift, at most 20 ms and four profile points; the same interior support is used for every event. This tolerates small timing errors without stretching the waveform. The broader/finer control uses minimum signed correlation to each subgroup centroid. Previews show the normalized aligned mean in blue and a real representative in gray on the labeled channel. Cohesion is descriptive and includes group members themselves; it is not independent confidence or an artifact probability. Incomplete, nonfinite, or flat waveforms remain unassigned. The hierarchy is built off the main thread and cached. Selecting a subgroup filters the examples only; cleaning, decisions, and original waveform confidence scores remain unchanged.")
                    Spacer()
                    Text("Preview only").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Picker("Waveform polarity", selection: Binding(
                        get: { waveformPolarityMode },
                        set: { value in
                            waveformPolarityOverride = value
                            waveformGroupID = nil; selectedEventID = nil
                        }
                    )) {
                        ForEach(ArtifactWaveformPolarityMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }
                    .pickerStyle(.segmented).frame(width: 360)
                    .disabled(spatialPolarityMode == .signed)
                    ArtifactReviewHelp(title: "Waveform polarity", text: "Preserve polarity clusters the recorded waveform signs as-is. Orient to spatial family multiplies an event’s complete multichannel profile by its retained spatial orientation before temporal clustering, so global sign reversals can share a shape subgroup. Within-waveform positive and negative lobes, relative channel strengths, raw data, decisions, and cleaning are unchanged. Spatially signed families have no orientation reversal to apply.")
                }
                HStack {
                    Text("Broader").font(.caption)
                    Slider(value: $waveformThreshold, in: 0.65...0.98, step: 0.01)
                        .accessibilityLabel("Waveform subgroup detail")
                    Text("Finer").font(.caption)
                    Text("r ≥ \(waveformThreshold, specifier: "%.2f")").font(.caption.monospacedDigit()).frame(width: 65)
                }
                if let result = currentWaveform {
                    ArtifactWaveformSubgroupCards(result: result, threshold: waveformThreshold,
                        preferredChannel: activeChannel, selectedGroupID: $waveformGroupID) { eventID in
                        selectedEventID = eventID; eventFocus = true
                    }
                    let labels = result.channelIndices.map(channelName).joined(separator: ", ")
                    Text("Channels: \(labels.isEmpty ? "none usable" : labels) · alignment up to ±\(result.maximumAlignmentSeconds * 1000, specifier: "%.0f") ms · normalized shapes\(result.polarityMode == .orientToSpatialFamily ? " · \(result.reorientedEventCount) polarity-oriented" : "")")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    ProgressView("Building waveform subgroups in the background…")
                        .font(.caption).frame(maxWidth: .infinity, minHeight: 90)
                }
            }
        } else if spatialGroupID == nil, currentSpatial?.features.isEmpty == false {
            Text("Select a spatial group to explore its waveform subgroups.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func similarityGroups(_ result: ArtifactReviewAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text("Waveform similarity bands").font(.caption.weight(.medium))
                ArtifactReviewHelp(title: "Similarity groups", text: "Click a card to filter examples by shape. Close match is r ≥ 0.90; Shape variation is 0.75 ≤ r < 0.90; Low similarity is r < 0.75. These fixed browsing bands do not change with the auto-selection sliders and do not include or exclude events by themselves. Blue is that group’s mean; gray traces show up to eight examples on the displayed channel. Unscored examples are available under All.")
            }
            HStack(spacing: 10) {
                ForEach(ArtifactReviewBand.allCases) { value in
                    let members = result.examples.filter { $0.band == value }
                    Button {
                        band = value
                        selectedEventID = members.sorted { ($0.correlation ?? -2) > ($1.correlation ?? -2) }.first?.id
                        eventFocus = true
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(value.rawValue).font(.callout.weight(.medium))
                            if members.isEmpty {
                                Text("No examples").font(.caption2).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 55)
                            } else {
                                ArtifactReviewTracePlot(
                                    traces: members.prefix(8).map { result.waveform($0.samples, channel: activeChannel) },
                                    reference: result.meanWaveform(of: members, channel: activeChannel))
                                    .frame(height: 55)
                            }
                            Text("\(members.count) examples · \(bandDescription(value))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(band == value ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.025),
                                    in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).disabled(members.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func splitControls(_ artifact: DefinedArtifact) -> some View {
        HStack {
            Button("All \(currentAnalysis?.examples.count ?? 0)") { band = nil; spatialGroupID = nil; waveformGroupID = nil; eventFocus = true }
            if usesSpatialGroups, let id = spatialGroupID {
                Text(id == -1 ? "Spatially unassigned" : waveformGroupID == nil
                    ? "Spatial family · \(examples.count) examples"
                    : waveformGroupID == -1 ? "Waveform unassigned · \(examples.count) examples"
                    : "Waveform subgroup · \(examples.count) examples")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let band { Text(band.rawValue).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button("Split group into class…", systemImage: "arrow.triangle.branch") {
                splitName = "\(artifact.name) variation"
                splitMethod = .obs
                showsSplit = true
            }
            .disabled(usesSpatialGroups || band == nil || examples.isEmpty || examples.count == ArtifactReviewEngine.candidates(for: artifact).count)
            ArtifactReviewHelp(title: "Split into a class", text: "Choose a similarity card, then split that entire group into a new artifact class. This moves all events in the filtered group, including examples on other pages, out of the parent class. The new class gets its own average and treatment. This does not perform cleaning.")
        }
        if showsSplit {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New class name").font(.caption)
                    TextField("Artifact variation", text: $splitName)
                }
                Picker("Treatment", selection: $splitMethod) {
                    Text("OBS").tag(ArtifactCleaningMethod.obs)
                    Text("SSP/PCA").tag(ArtifactCleaningMethod.sspPCA)
                    Text("Regress").tag(ArtifactCleaningMethod.regression)
                }.frame(width: 180)
                Text("Move \(examples.count) events; build a separate average.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { showsSplit = false }
                Button("Create class", action: splitClass)
            }
        }
    }

    private func eventWorkspace(_ artifact: DefinedArtifact, _ result: ArtifactReviewAnalysis) -> some View {
        let browsedExamples = examples
        let mapScale = topographyScale
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Text("Individual examples · best match first").font(.caption.weight(.medium))
                    ArtifactReviewHelp(title: "Browse examples", text: "Examples are sorted from highest to lowest similarity, with unscored examples last. Each tile shows event time in seconds, waveform or peak-GFP topomap, an uncalibrated waveform shape-match score out of 100, and the current decision. The selected example explains the score and its supporting reference count. Click a tile to inspect it. With multiple sets, arrow buttons and left/right keys move between sets of eighteen and select the first example in the destination set. With one set, the detail arrows and keys move one example at a time. Click a tile or navigation arrow to focus keyboard navigation; Space toggles Include/Exclude.")
                }
                Picker("Exemplar preview", selection: $tilePreview) {
                    ForEach(ArtifactReviewTilePreview.allCases) { preview in Text(preview.rawValue).tag(preview) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if tilePreview == .topomaps {
                    HStack(spacing: 4) {
                        Group {
                            if sensorLayout == nil { Text("Sensor layout required") }
                            else { Text("Peak GFP · page scale ±\(mapScale, specifier: "%.1f") µV") }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        ArtifactReviewHelp(title: "Exemplar topomaps", text: "Each map shows the instant of greatest global field power (spatial standard deviation) within that event’s core. The core mean is removed per channel, then the map is average-referenced across finite, mapped good channels. Bad/interpolated and nonfinite-core channels are omitted. All eighteen tiles share one color scale for the current page. Red and blue show opposite signed potentials, not good versus bad. A flat map, incomplete core, fewer than three valid sensors, or missing sensor coordinates shows Unavailable. The timestamps on tiles are event times; the larger selected map shows its peak time. The Wave match score, example ordering, auto-selection rules, and Waveform bands use waveform correlation. Spatial groups are a separate preview based on normalized signed electrode values. Switching thumbnail views does not change decisions or grouping.")
                    }
                }
                let navigation = navigation
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(Array(browsedExamples[navigation.visibleRange])) { example in
                        Button {
                            selectedEventID = example.id
                            eventFocus = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(example.event.centerTimeSeconds, format: .number.precision(.fractionLength(2)))
                                    .font(.caption2.monospacedDigit())
                                if tilePreview == .waveforms {
                                    ArtifactReviewTracePlot(
                                        traces: [result.waveform(example.samples, channel: activeChannel)],
                                        reference: result.waveform(result.reference, channel: activeChannel))
                                        .frame(height: 54)
                                } else {
                                    ArtifactReviewTopomapPreview(topography: example.topography,
                                        layout: sensorLayout, scale: mapScale)
                                        .frame(height: 54)
                                }
                                Text(example.matchConfidence.score.map { "\(tilePreview == .topomaps ? "Wave" : "Match") \($0)/100" } ?? "Match unavailable")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(confidenceColor(example.matchConfidence))
                                    .help(example.matchConfidence.explanation)
                                Text(ArtifactReviewEngine.choice(for: example.id, artifact: artifact).decision.rawValue.capitalized)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            .background(selectedExample?.id == example.id ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.03),
                                        in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }
                HStack {
                    Button { move(-1, byPage: true) } label: { Image(systemName: "chevron.left") }
                        .disabled(navigation.destination(-1, byPage: true) == nil)
                        .accessibilityLabel("Previous set").help("Previous set of examples")
                    Spacer()
                    Text(examples.isEmpty ? "No examples" : "Set \(navigation.page + 1) of \(navigation.pageCount) · \(navigation.visibleRange.lowerBound + 1)–\(navigation.visibleRange.upperBound) of \(examples.count)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button { move(1, byPage: true) } label: { Image(systemName: "chevron.right") }
                        .disabled(navigation.destination(1, byPage: true) == nil)
                        .accessibilityLabel("Next set").help("Next set of examples")
                }
            }.frame(width: 290)
            VStack(alignment: .leading, spacing: 9) {
                if let example = selectedExample {
                    HStack {
                        Text("Event at \(example.event.centerTimeSeconds, specifier: "%.3f") s").font(.callout.weight(.medium))
                        Spacer()
                        Button { move(-1) } label: { Image(systemName: "chevron.left") }
                            .disabled(navigation.destination(-1) == nil)
                            .accessibilityLabel(navigation.pageCount > 1 ? "Previous set" : "Previous example")
                            .help(navigation.pageCount > 1 ? "Previous set of eighteen examples" : "Previous example")
                        Button { move(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(navigation.destination(1) == nil)
                            .accessibilityLabel(navigation.pageCount > 1 ? "Next set" : "Next example")
                            .help(navigation.pageCount > 1 ? "Next set of eighteen examples" : "Next example")
                    }
                    confidenceSummary(example)
                    HStack(spacing: 5) {
                        Text(metricDescription(example)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        ArtifactReviewHelp(title: "Example metrics", text: "r measures signed multichannel shape similarity to the class reference, not artifact probability. Peak is the largest absolute baseline-centered core amplitude across the definition channels. Span is the measured detector duration when available. The detail plot can show one channel or the top 3/5 impacted channels. Display controls do not change multichannel scoring.")
                    }
                    HStack {
                        ForEach(ArtifactReviewDecision.allCases, id: \.self) { decision in
                            Button(decision.rawValue.capitalized) { choose(decision) }
                                .tint(ArtifactReviewEngine.choice(for: example.id, artifact: artifact).decision == decision ? .accentColor : .secondary)
                        }
                        ArtifactReviewHelp(title: "Include, Hold, Exclude", text: "Include makes an event eligible for this class’s treatment. Hold leaves an uncertain event out of cleaning until you decide. Exclude leaves it out of this class’s treatment. These choices do not delete the detected candidate or alter the recording immediately. Use Clean → Apply to run the selected treatment. Space toggles Include and Exclude for the selected tile.")
                    }
                    Text(navigation.pageCount > 1 ? "← → Previous / next set · Click a tile to select · Space Include / exclude" : "← → Previous / next example · Space Include / exclude").font(.caption2).foregroundStyle(.secondary)
                    if tilePreview == .topomaps {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Selected exemplar · peak-GFP topography").font(.caption.weight(.medium))
                            ArtifactReviewTopomapPreview(topography: example.topography,
                                layout: sensorLayout, scale: mapScale, showsScale: true)
                                .frame(height: 220)
                            if let map = example.topography {
                                Text("Map at \(map.timeSeconds, specifier: "%.3f") s · \((map.timeSeconds - example.event.centerTimeSeconds) * 1000, specifier: "%+.0f") ms from event · \(map.channelIndices.count) channels")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    eventDisplay(artifact, example, result)
                    HStack(spacing: 12) {
                        Label("Event", systemImage: "waveform").foregroundStyle(.primary)
                        Label("Class average", systemImage: "line.diagonal").foregroundStyle(.blue)
                        Label("Core / taper", systemImage: "rectangle.fill").foregroundStyle(.secondary)
                    }.font(.caption2)
                    HStack {
                        Picker("Overview", selection: $channel) {
                            ForEach(result.channelIndices, id: \.self) { index in Text(channelName(index)).tag(index) }
                        }
                        Text("Core (s)").font(.caption)
                        TextField("Seconds", value: Binding(
                            get: { selected?.windowSizeSeconds ?? 0.5 },
                            set: { value in edit { $0.windowSizeSeconds = min(max(value.isFinite ? value : 0.5, 0.1), 5) } }
                        ), format: .number.precision(.fractionLength(2))).frame(width: 55)
                        ArtifactReviewHelp(title: "Display channel and correction window", text: "Overview selects the channel used for similarity cards, tiles, the class-average preview, and Single mode. Top 3/5 ranks good recording channels for the selected event by peak-to-peak amplitude inside the core, without DC offsets or surrounding context affecting that order. Core (s) changes the correction-window duration for the whole artifact class and recomputes its similarity analysis. Blue shading marks the core, pale cyan the added edge taper, and orange the measured threshold span when available. The vertical marker is the event center; the dashed blue trace is the class average.")
                    }
                    Text(example.hasCompleteWindow ? (example.spanInsideCore == false ? "Measured span extends beyond the core window." : "Complete padded correction window.") : "Incomplete recording-edge window; the cleaner skips this event.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        HStack(spacing: 5) {
                            Text("Class average · \(result.referenceCount) examples").font(.caption)
                            ArtifactReviewHelp(title: "Class average", text: "Blue shows the reference average; gray traces show up to sixteen candidates, including held and excluded examples. The reference initially uses all usable examples and stays fixed while you make decisions. Rebuild from included recomputes it using included examples and refreshes similarity scores. Reference members are scored against an average that leaves themselves out, so an event cannot artificially improve its own match score.")
                        }
                        Spacer()
                        Button("Rebuild from included") {
                            edit(invalidates: false) { ArtifactReviewEngine.rebuildReference(&$0) }
                        }.disabled(artifact.events.isEmpty)
                    }
                    ArtifactReviewTracePlot(
                        traces: result.examples.prefix(16).map { result.waveform($0.samples, channel: activeChannel) },
                        reference: result.waveform(result.reference, channel: activeChannel))
                        .frame(height: 95)
                    Text("Signed shape correlation across definition channels; members are scored against a leave-one-out average. The reference stays fixed until rebuilt.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ContentUnavailableView("No Examples in This Group", systemImage: "waveform",
                        description: Text("Choose All to inspect unscored or other examples."))
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusable().focused($eventFocus)
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.space) {
            guard let artifact = selected, let example = selectedExample else { return .ignored }
            choose(ArtifactReviewEngine.choice(for: example.id, artifact: artifact).decision == .include ? .exclude : .include)
            return .handled
        }
    }

    private func eventDisplay(_ artifact: DefinedArtifact, _ example: ArtifactReviewExample,
                              _ result: ArtifactReviewAnalysis) -> some View {
        let displayed = displayMode == .single ? [activeChannel]
            : Array(example.impactedChannels.prefix(displayMode.channelLimit).map(\.channelIndex))
        let window = ArtifactReviewEngine.contextWindow(for: example.event, artifact: artifact,
            signal: signal, contextSeconds: contextSeconds)
        let scale = window.map { ArtifactReviewEngine.displayScale(channels: displayed, window: $0,
            signal: signal, analysis: result) } ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Display channels", selection: $displayMode) {
                    ForEach(ArtifactReviewDisplayMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Picker("Context", selection: $contextSeconds) {
                    ForEach([0.25, 0.5, 1.0, 2.0], id: \.self) { seconds in
                        Text("\(seconds, specifier: "%g") s each side").tag(seconds)
                    }
                }
                ArtifactReviewHelp(title: "Multi-channel context", text: "Top 3 and Top 5 show the good recording channels with the largest peak-to-peak amplitude within this event’s core window, ranked separately for each event. Bad/interpolated channels, flat channels, incomplete cores, and channels with nonfinite core samples are omitted. The rows share a time axis and amplitude scale so their timing, polarity, and strength can be compared. Context adds raw data before and after the padded window; it does not change detection, scoring, or the correction window. The class-average overlay is available on definition channels; other channels show the event only. Overview controls the thumbnails and Single mode. Scroll down to see all rows; recording-edge gaps remain blank.")
            }
            if displayMode != .single {
                Text("\(displayed.count) most impacted channel\(displayed.count == 1 ? "" : "s") · ranked for this event · shared µV scale")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let window, !displayed.isEmpty {
                ForEach(displayed, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(channelName(index)).font(.caption.weight(.semibold))
                            if let impact = example.impactedChannels.first(where: { $0.channelIndex == index }) {
                                Text("\(impact.peakToPeakMicrovolts, specifier: "%.1f") µV p–p")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !result.channelIndices.contains(index) {
                                Text("Event only · outside definition channels")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        ArtifactReviewEventPlot(artifact: artifact, example: example, analysis: result,
                            signal: signal, channel: index, window: window, sharedScale: scale)
                            .frame(height: displayMode == .single ? 180 : 105)
                    }
                }
            } else {
                Text("No usable channels with a complete, non-flat core window for this event.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func confidenceSummary(_ example: ArtifactReviewExample) -> some View {
        let confidence = example.matchConfidence
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Waveform similarity").font(.caption.weight(.semibold))
                ArtifactReviewHelp(title: "Waveform similarity", text: "This is a transparent shape-match score, not the probability that an event is an artifact. It is the positive part of signed multichannel correlation × 100, rounded to a whole number: r = 0.92 gives 92/100; opposite polarity gives 0. The score is withheld for incomplete correction windows, unusable waveforms, missing independent references, or undefined correlation. Reference members are compared to an average that excludes themselves. Limited reference means only one or two comparison examples; even a high score then has little supporting evidence. Decisions and cleaning remain controlled by your rules and manual choices.")
                Spacer()
                Text(confidence.score.map { "\($0)/100" } ?? "Unavailable")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(confidenceColor(confidence))
            }
            if let score = confidence.score {
                ProgressView(value: Double(score), total: 100)
                    .tint(confidenceColor(confidence))
                    .accessibilityLabel("Waveform similarity score")
                    .accessibilityValue("\(score) out of 100")
            }
            Text(confidence.explanation).font(.caption)
            if confidence.referenceCount > 0 {
                Text("Compared with \(confidence.referenceCount) other reference example\(confidence.referenceCount == 1 ? "" : "s")\(confidence.hasLimitedReference ? " · Limited reference" : "")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }

    private func confidenceColor(_ confidence: ArtifactReviewMatchConfidence) -> Color {
        guard let score = confidence.score else { return .secondary }
        return score >= 90 ? .blue : score >= 75 ? .orange : .secondary
    }

    private func ruleBinding<Value>(_ key: WritableKeyPath<ArtifactReviewRules, Value>) -> Binding<Value> {
        Binding(get: { rules[keyPath: key] }, set: { value in
            edit(invalidates: false) { artifact in
                ArtifactReviewEngine.prepare(&artifact)
                artifact.reviewState?.rules[keyPath: key] = value
                guard var updated = artifact.reviewState?.rules else { return }
                updated.includeCorrelation = min(max(updated.includeCorrelation, 0.50), 0.99)
                updated.excludeCorrelation = min(max(updated.excludeCorrelation, -1), updated.includeCorrelation)
                updated.maximumPeakMicrovolts = min(max(updated.maximumPeakMicrovolts.isFinite ? updated.maximumPeakMicrovolts : 300, 1), 1e6)
                updated.maximumDurationSeconds = min(max(updated.maximumDurationSeconds.isFinite ? updated.maximumDurationSeconds : 1, 0.001), 60)
                artifact.reviewState?.rules = updated
            }
        })
    }

    private func edit(invalidates: Bool = true, _ mutation: (inout DefinedArtifact) -> Void) {
        guard let id = selected?.id, let index = artifacts.firstIndex(where: { $0.id == id }) else { return }
        var updated = artifacts[index]
        mutation(&updated)
        artifacts[index] = updated
        if invalidates { onChange() }
    }

    private func choose(_ decision: ArtifactReviewDecision) {
        guard let example = selectedExample else { return }
        edit { ArtifactReviewEngine.setChoice(decision, eventID: example.id, artifact: &$0) }
        eventFocus = true
    }

    private func undoRules() {
        guard let previous = ruleUndo else { return }
        edit { artifact in
            for event in artifact.reviewState?.candidates ?? [] {
                if ArtifactReviewEngine.choice(for: event.id, artifact: artifact).isManual { continue }
                artifact.reviewState?.choices[event.id] = previous[event.id]
            }
            ArtifactReviewEngine.commitChoices(&artifact)
        }
        ruleUndo = nil
    }

    private func splitClass() {
        let ids = Set(examples.map(\.id))
        guard let id = selected?.id, let index = artifacts.firstIndex(where: { $0.id == id }),
              let child = ArtifactReviewEngine.split(eventIDs: ids, name: splitName, method: splitMethod, parent: &artifacts[index]) else { return }
        artifacts.append(child)
        onChange()
        selectedArtifactID = child.id
        band = nil
        showsSplit = false
        ruleUndo = nil
    }

    private func move(_ direction: Int, byPage: Bool? = nil) {
        guard let index = navigation.destination(direction, byPage: byPage) else { return }
        selectedEventID = examples[index].id
        eventFocus = true
    }

    @MainActor
    private func loadWaveformGrouping() async {
        let key = waveformTaskKey
        guard !key.isEmpty, let analysis = currentAnalysis, let family = selectedSpatialFamily,
              let artifact = selected else { return }
        if waveformLoadedKey == key { return }
        if let cached = await ArtifactWaveformGroupingCache.shared.value(for: key) {
            guard !Task.isCancelled, waveformTaskKey == key else { return }
            waveformGrouping = cached; waveformLoadedKey = key
            return
        }
        let windowSeconds = artifact.windowSizeSeconds
        let polarityMode = waveformPolarityMode
        let worker = Task.detached(priority: .userInitiated) {
            await ArtifactWaveformGrouping.build(analysis: analysis, family: family,
                windowSeconds: windowSeconds, polarityMode: polarityMode)
        }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, waveformTaskKey == key, let result else { return }
        await ArtifactWaveformGroupingCache.shared.insert(result, for: key)
        guard !Task.isCancelled, waveformTaskKey == key else { return }
        waveformGrouping = result; waveformLoadedKey = key
    }

    @MainActor
    private func loadSpatialGrouping() async {
        let key = spatialTaskKey
        guard !key.isEmpty, let result = currentAnalysis else { return }
        if spatialLoadedKey == key { return }
        if let cached = await ArtifactSpatialGroupingCache.shared.value(for: key) {
            guard !Task.isCancelled, spatialTaskKey == key else { return }
            spatialHierarchy = cached; spatialLoadedKey = key
            return
        }
        let hasLayout = sensorLayout != nil
        let layout = sensorLayout
        let polarityMode = spatialPolarityMode
        let similarityMetric = effectiveSpatialSimilarityMetric
        let worker = Task.detached(priority: .userInitiated) {
            if !hasLayout {
                return ArtifactSpatialHierarchy(channels: [], features: [], unassignedIDs: result.examples.map(\.id), nodes: [], root: nil) as ArtifactSpatialHierarchy?
            }
            return await ArtifactSpatialGrouping.build(examples: result.examples, layout: layout,
                polarityMode: polarityMode, similarityMetric: similarityMetric)
        }
        let hierarchy = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, spatialTaskKey == key, let hierarchy else { return }
        await ArtifactSpatialGroupingCache.shared.insert(hierarchy, for: key)
        guard !Task.isCancelled, spatialTaskKey == key else { return }
        spatialHierarchy = hierarchy; spatialLoadedKey = key
    }

    @MainActor
    private func loadAnalysis() async {
        guard let id = selected?.id, let index = artifacts.firstIndex(where: { $0.id == id }) else { return }
        ArtifactReviewEngine.prepare(&artifacts[index])
        let artifact = artifacts[index]
        let key = analysisKey
        let source = signal
        let excluded = excludedChannels
        let layout = sensorLayoutName
        let mappedChannels = sensorLayout.map { Set($0.positions.map(\.channelIndex)) }
        let worker = Task.detached(priority: .userInitiated) {
            ArtifactReviewEngine.analyze(artifact: artifact, signal: source, excluding: excluded,
                sensorLayoutName: layout, topographyChannelIndices: mappedChannels)
        }
        let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, analysisKey == key else { return }
        analysis = result
        loadedKey = key
        if !result.channelIndices.contains(channel) { channel = result.channelIndices.first ?? 0 }
    }

    private func channelName(_ index: Int) -> String {
        guard let names = signal.channelNames, names.indices.contains(index) else { return "Ch \(index + 1)" }
        return names[index]
    }
    private func bandDescription(_ band: ArtifactReviewBand) -> String {
        switch band { case .close: return "r ≥ 0.90"; case .variation: return "0.75 ≤ r < 0.90"; case .low: return "r < 0.75" }
    }
    private func metricDescription(_ example: ArtifactReviewExample) -> String {
        let r = example.correlation.map { String(format: "r %.3f", $0) } ?? "No similarity score"
        let peak = example.peakMicrovolts.map { String(format: "%.1f µV peak", $0) } ?? "No finite waveform"
        let duration = example.durationSeconds.map { String(format: "%.0f ms span", $0 * 1000) } ?? "Span unknown"
        return "\(r) · \(peak) · \(duration)"
    }
    private func cleaningMethods(_ artifact: DefinedArtifact) -> [ArtifactCleaningMethod] {
        var methods: [ArtifactCleaningMethod] = [.doNothing, .obs, .sspPCA, .regression, .mas, .mar, .waas, .waar, .wavelet]
        if artifact.type == .bcg { methods.append(.pcaS) }
        if !methods.contains(artifact.cleaningMethod) { methods.append(artifact.cleaningMethod) }
        return methods
    }
}

/// The same cards are used by the live review and native render checks.
struct ArtifactWaveformSubgroupCards: View {
    let result: ArtifactWaveformGroupingResult
    let threshold: Double
    let preferredChannel: Int
    @Binding var selectedGroupID: Int?
    let onSelect: (String?) -> Void

    var body: some View {
        let groups = result.hierarchy.groups(minimumCorrelation: threshold)
        let channel = result.channelIndices.contains(preferredChannel) ? preferredChannel : result.channelIndices.first ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(groups.count) subgroups · \(result.hierarchy.features.count) usable · \(result.hierarchy.unassignedIDs.count) unassigned")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Whole spatial family") { selectedGroupID = nil; onSelect(nil) }
                    .font(.caption)
            }
            if !groups.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            let representative = result.hierarchy.features.first { $0.eventID == group.representativeID }
                            Button {
                                selectedGroupID = group.id; onSelect(group.representativeID)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Shape \(index + 1) · \(group.eventIDs.count)").font(.caption.weight(.medium))
                                    ArtifactReviewTracePlot(
                                        traces: [result.waveform(representative?.vector ?? [], channel: channel)],
                                        reference: result.waveform(group.meanFeature, channel: channel), minimumScale: 1e-6)
                                        .frame(height: 55)
                                    Text("Ch \(channel + 1) · normalized mean + example")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(group.eventIDs.count == 1 ? "Single example" : String(format: "Minimum waveform r %.2f", group.minimumCorrelation))
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }.frame(width: 175).padding(8)
                                    .background(selectedGroupID == group.id ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: 124)
            }
            if !result.hierarchy.unassignedIDs.isEmpty {
                Button("Waveform unassigned · \(result.hierarchy.unassignedIDs.count)") {
                    selectedGroupID = -1; onSelect(result.hierarchy.unassignedIDs.first)
                }.font(.caption).tint(selectedGroupID == -1 ? .accentColor : .secondary)
            }
        }
    }
}

struct ArtifactReviewTopomapPreview: View {
    let topography: ArtifactReviewTopography?
    let layout: SensorLayout?
    let scale: Double
    var showsScale = false

    var body: some View {
        if let layout, let topography {
            TopomapView(layout: layout, values: topography.values, timeSeconds: topography.timeSeconds,
                fixedScale: scale, showsHeader: false,
                colorBarPlacement: showsScale ? .trailing : .none,
                minimumMapHeight: showsScale ? 180 : 48, contentPadding: 0,
                fieldResolution: showsScale ? 96 : 64, showsElectrodes: showsScale,
                visibleChannels: Set(topography.channelIndices))
                .allowsHitTesting(false)
                .accessibilityLabel("Exemplar scalp topography at peak field strength")
        } else {
            VStack(spacing: 2) {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                Text("Unavailable").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(layout == nil ? "Topomap unavailable: missing sensor layout" : "Topomap unavailable: insufficient finite spatial signal")
        }
    }
}

private struct ArtifactReviewHelp: View {
    let title: String
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Help: \(title)")
        .help(title)
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 320, alignment: .leading)
        }
    }
}

private struct ArtifactReviewTracePlot: View {
    let traces: [[Float]]
    let reference: [Float]
    var minimumScale: Float = 1
    var body: some View {
        Canvas { context, size in
            let all = traces.flatMap { $0 } + reference
            let scale = max(all.filter(\.isFinite).map { abs($0) }.max() ?? minimumScale, minimumScale)
            func path(_ values: [Float]) -> Path {
                Path { p in
                    var started = false
                    for (index, value) in values.enumerated() {
                        guard value.isFinite else { started = false; continue }
                        let point = CGPoint(x: CGFloat(index) / CGFloat(max(values.count - 1, 1)) * size.width,
                                            y: size.height / 2 - CGFloat(value / scale) * size.height * 0.43)
                        if started { p.addLine(to: point) } else { p.move(to: point); started = true }
                    }
                }
            }
            for trace in traces { context.stroke(path(trace), with: .color(.secondary.opacity(traces.count > 1 ? 0.25 : 0.85)), lineWidth: 1) }
            context.stroke(path(reference), with: .color(.blue), lineWidth: 1.6)
        }
        .accessibilityLabel("Artifact examples and class average waveform")
    }
}

private struct ArtifactReviewEventPlot: View {
    let artifact: DefinedArtifact
    let example: ArtifactReviewExample
    let analysis: ArtifactReviewAnalysis
    let signal: MFFSignalData
    let channel: Int
    let window: ArtifactReviewContextWindow
    let sharedScale: Double

    var body: some View {
        Canvas { context, size in
            guard signal.data.indices.contains(channel), signal.samplingRate > 0 else { return }
            let core = window.core, padded = window.padded
            let row = signal.data[channel]
            let center = example.event.centerTimeSeconds * signal.samplingRate
            let start = window.displayed.lowerBound, end = window.displayed.upperBound
            let availableStart = max(0, start), availableEnd = min(row.count, end)
            guard availableEnd > availableStart else { return }
            let available = availableStart..<availableEnd
            let baselineStart = max(0, core.lowerBound), baselineEnd = min(row.count, core.upperBound)
            guard baselineEnd > baselineStart else { return }
            let baselineRange = baselineStart..<baselineEnd
            let finite = baselineRange.map { row[$0] }.filter(\.isFinite)
            let baseline = finite.reduce(0.0) { $0 + Double($1) } / Double(max(finite.count, 1))
            let indices = ArtifactReviewEngine.traceIndices(row, range: available)
            let reference = analysis.waveform(analysis.reference, channel: channel)
            let scale = sharedScale
            func x(_ sample: Double) -> Double { 5 + (sample - Double(start)) / Double(max(end - start, 1)) * (size.width - 10) }
            func y(_ value: Double) -> Double { 15 + (1 - value / scale) / 2 * (size.height - 42) }
            func shade(_ range: Range<Int>, _ color: Color) {
                context.fill(Path(CGRect(x: x(Double(range.lowerBound)), y: 0,
                    width: x(Double(range.upperBound)) - x(Double(range.lowerBound)), height: size.height - 23)), with: .color(color))
            }
            shade(padded, .cyan.opacity(0.11))
            shade(core, .blue.opacity(0.12))
            if let detail = artifact.thresholdOcularCandidates?.first(where: { $0.id == example.id }) {
                let lower = max(start, Int((detail.startTimeSeconds * signal.samplingRate).rounded()))
                let upper = min(end, Int((detail.endTimeSeconds * signal.samplingRate).rounded()))
                if upper > lower { shade(lower..<upper, .orange.opacity(0.15)) }
            }
            var raw = Path(), drawing = false
            for index in indices {
                guard row[index].isFinite else { drawing = false; continue }
                let point = CGPoint(x: x(Double(index)), y: y(Double(row[index]) - baseline))
                if drawing { raw.addLine(to: point) } else { raw.move(to: point); drawing = true }
            }
            context.stroke(raw, with: .color(.primary), lineWidth: 1)
            var average = Path()
            for (index, value) in reference.enumerated() {
                let sample = Double(core.lowerBound) + Double(index) / Double(max(reference.count - 1, 1)) * Double(core.count - 1)
                let point = CGPoint(x: x(sample), y: y(Double(value)))
                if index == 0 { average.move(to: point) } else { average.addLine(to: point) }
            }
            context.stroke(average, with: .color(.blue), style: StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
            let peak = Path { p in p.move(to: CGPoint(x: x(center), y: 0)); p.addLine(to: CGPoint(x: x(center), y: size.height - 23)) }
            context.stroke(peak, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            context.draw(Text(String(format: "−%.0f µV / +%.0f µV", scale, scale)).font(.caption2),
                         at: CGPoint(x: 6, y: 8), anchor: .leading)
            context.draw(Text(String(format: "%.0f ms", (Double(start) - center) / signal.samplingRate * 1000)).font(.caption2),
                         at: CGPoint(x: 6, y: size.height - 8), anchor: .leading)
            context.draw(Text(String(format: "%.0f ms", (Double(end) - center) / signal.samplingRate * 1000)).font(.caption2),
                         at: CGPoint(x: size.width - 6, y: size.height - 8), anchor: .trailing)
        }
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Selected event and class average, with core, taper, measured span, and event-center marker")
    }
}
