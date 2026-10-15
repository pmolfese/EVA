//
//  BatchSetupSheet.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Setup for Batch Process: choose the MFF files to process, the processing
//  source (a standalone eva.xml or an MFF containing one), the shared step config,
//  and an output folder. Start hands everything to the app-level BatchController.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BatchSetupSheet: View {
    @Environment(BatchController.self) private var batch
    let onCancel: () -> Void
    let onStart: () -> Void

    @State private var files: [URL] = []
    /// Beat/event codes shared by every selected file — see
    /// `refreshSharedBeatEventCodes`.
    @State private var sharedBeatEventCodes: Set<String> = []
    @State private var outputFolder: URL?
    @State private var sourceName = ""
    @State private var script: EVAProcessingScript?
    @State private var config = ReplayController()
    @State private var settingsPopoverStepID: Int?
    @State private var inputDropIsTargeted = false
    @State private var sourceDropIsTargeted = false
    @State private var inputDropMessage: String?
    @State private var sourceDropMessage: String?
    @State private var preflight = BatchPreflightModel()
    @State private var selectedPreflightURL: URL?
    @State private var showsStartWarning = false
    @State private var skipsUnsupportedDecisions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Batch Process")
                    .font(.headline)
                Text("Apply one processing script to many recordings. Portable steps run automatically; review and decision steps can pause or use the options below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    filesSection
                    sourceSection
                    outputSection
                }
                .padding(20)
            }
            .frame(minHeight: 260, maxHeight: 420)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if script != nil {
                    Label(
                        canRunHeadless
                            ? "No steps need review — runs in the background with no windows."
                            : "Some steps need your input — files will open one at a time.",
                        systemImage: canRunHeadless ? "bolt.fill" : "macwindow"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                HStack {
                    Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .cancel) { onCancel() }
                    Button("Start") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canStart)
                }
            }
            .padding(20)
        }
        .frame(width: 520)
        .onChange(of: files, initial: true) { _, _ in
            sharedBeatEventCodes = []
            reclassifySteps()
            preflight.refresh(files: files, script: script)
            if let selectedPreflightURL, !files.contains(selectedPreflightURL) {
                self.selectedPreflightURL = nil
            }
        }
        .onChange(of: preflight.state.results) { _, _ in
            refreshSharedBeatEventCodesFromPreflight()
            reclassifySteps()
        }
        .alert("Some recordings need attention", isPresented: $showsStartWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Start Anyway") { performStart() }
        } message: {
            Text(startWarningMessage)
        }
    }

    // MARK: Sections

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Files").font(.callout.weight(.semibold))
                Spacer()
                Button("Add Files…") { addFiles() }
                if !files.isEmpty { Button("Clear") { files.removeAll() } }
            }
            if files.isEmpty {
                Text("No files chosen.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(files, id: \.self) { url in
                    HStack(spacing: 7) {
                        Image(systemName: "waveform")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let metadata = preflight.state.results[url],
                               let channelCount = metadata.numberOfChannels,
                               let samplingRate = metadata.samplingRate {
                                Text("\(channelCount) channels · \(samplingRate.formatted(.number.precision(.fractionLength(0...2)))) Hz")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        preflightStatus(for: url)
                        Button {
                            files.removeAll { $0 == url }
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                    }
                }
                preflightSummary
                if let selectedPreflightURL,
                   let result = preflight.state.results[selectedPreflightURL],
                   result.inspectionError != nil || !relevantIssues(in: result).isEmpty
                    || !policyDrops(in: result).isEmpty {
                    preflightDetail(result)
                }
            }
            if let inputDropMessage {
                Text(inputDropMessage)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(dropTargetBackground(isTargeted: inputDropIsTargeted))
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            addInputFiles(urls)
        } isTargeted: { targeted in
            inputDropIsTargeted = targeted
        }
        .help("Drop MFF files here")
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Processing Source").font(.callout.weight(.semibold))
                Spacer()
                Button(script == nil ? "Choose…" : "Change…") { chooseSource() }
            }
            if script == nil {
                Text("Pick an eva.xml or an MFF that was processed in EVA.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("From \(sourceName)").font(.caption).foregroundStyle(.secondary)
                Picker("Mode", selection: Binding(get: { config.mode }, set: { config.mode = $0 })) {
                    ForEach(ReplayController.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                if showsSkipDecisionPolicy {
                    Toggle("Skip unsupported decisions for each recording", isOn: $skipsUnsupportedDecisions)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help("A decision step runs when that recording can resolve it. Otherwise EVA drops only that step, continues the file, and records the reason in its process log.")
                }
                ForEach($config.steps) { $step in
                    batchStepRow($step)
                }
            }
            if let sourceDropMessage {
                Text(sourceDropMessage)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(dropTargetBackground(isTargeted: sourceDropIsTargeted))
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            handleProcessingSourceDrop(urls)
        } isTargeted: { targeted in
            sourceDropIsTargeted = targeted
        }
        .help("Drop an eva.xml file or processed MFF here")
    }

    private func dropTargetBackground(isTargeted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isTargeted ? Color.accentColor.opacity(0.07) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isTargeted ? Color.accentColor : Color.secondary.opacity(0.22),
                        style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 4])
                    )
            )
    }

    @ViewBuilder
    private func preflightStatus(for url: URL) -> some View {
        if let result = preflight.state.results[url] {
            let issues = relevantIssues(in: result)
            let drops = policyDrops(in: result)
            if result.inspectionError != nil || !issues.isEmpty {
                Button {
                    selectedPreflightURL = selectedPreflightURL == url ? nil : url
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("Show compatibility warnings")
                .accessibilityLabel("Show compatibility warnings for \(url.lastPathComponent)")
            } else if !drops.isEmpty {
                Button {
                    selectedPreflightURL = selectedPreflightURL == url ? nil : url
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.borderless)
                .help("Show decisions that will be skipped")
                .accessibilityLabel("Show skipped decisions for \(url.lastPathComponent)")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Compatible with the included steps")
                    .accessibilityLabel("Compatible")
            }
        } else if preflight.state.pendingFiles.contains(url) {
            ProgressView()
                .controlSize(.small)
                .help("Checking compatibility")
                .accessibilityLabel("Checking compatibility for \(url.lastPathComponent)")
        }
    }

    @ViewBuilder
    private var preflightSummary: some View {
        if preflight.isChecking {
            Label("Checking compatibility…", systemImage: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if !files.isEmpty {
            let flagged = flaggedFileURLs
            let dropCount = files.reduce(0) { count, url in
                count + (preflight.state.results[url].map { policyDrops(in: $0).count } ?? 0)
            }
            HStack {
                Label(
                    flagged.isEmpty
                        ? (dropCount == 0
                            ? "All \(files.count) recordings are compatible with the included steps."
                            : "All \(files.count) ready · \(dropCount) decision\(dropCount == 1 ? "" : "s") will be skipped")
                        : "\(files.count - flagged.count) ready · \(flagged.count) warning\(flagged.count == 1 ? "" : "s")",
                    systemImage: flagged.isEmpty
                        ? (dropCount == 0 ? "checkmark.circle" : "arrow.right.circle")
                        : "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(flagged.isEmpty
                    ? (dropCount == 0 ? Color.secondary : Color.blue)
                    : Color.orange)
                Spacer()
                if !flagged.isEmpty {
                    Button("Remove Flagged Files") {
                        let flaggedSet = Set(flagged)
                        files.removeAll { flaggedSet.contains($0) }
                    }
                    .font(.caption2)
                }
            }
        }
    }

    private func preflightDetail(_ result: BatchPreflightResult) -> some View {
        let issues = relevantIssues(in: result)
        let drops = policyDrops(in: result)
        let hasWarning = result.inspectionError != nil || !issues.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(result.url.lastPathComponent)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    selectedPreflightURL = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close compatibility details")
            }

            if let inspectionError = result.inspectionError {
                Label("EVA could not inspect this recording.", systemImage: "exclamationmark.octagon")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(inspectionError)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Starting is still allowed; processing may fail while loading this file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(issues.enumerated()), id: \.element.id) { offset, issue in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(issue.stepName)
                            .font(.caption.weight(.semibold))
                        Text(issue.flag.message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Label("Automatic: stops this recording at this step → Needs Input", systemImage: "bolt.slash")
                            .font(.caption2)
                        Label("Windowed: leaves this step out for this recording", systemImage: "macwindow")
                            .font(.caption2)
                    }
                    if offset < issues.count - 1 { Divider() }
                }
                if !issues.isEmpty, !drops.isEmpty { Divider() }
                ForEach(Array(drops.enumerated()), id: \.element.id) { offset, drop in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ReplayStepDisplay.label(for: drop.operation))
                            .font(.caption.weight(.semibold))
                        Text(drop.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Label("This step will be dropped; later steps continue.", systemImage: "arrow.right")
                            .font(.caption2)
                        Text("Recorded in this file’s process log.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if offset < drops.count - 1 { Divider() }
                }
            }
        }
        .padding(9)
        .background((hasWarning ? Color.orange : Color.blue).opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder((hasWarning ? Color.orange : Color.blue).opacity(0.32))
        )
    }

    private func batchStepRow(_ step: Binding<ReplayController.StepConfig>) -> some View {
        let kind = step.wrappedValue.kind
        return HStack(spacing: 8) {
            Toggle("", isOn: step.included)
                .labelsHidden()
                .disabled(kind == .skip)
            VStack(alignment: .leading, spacing: 1) {
                Text(ReplayStepDisplay.label(for: step.wrappedValue.step.operation))
                    .font(.caption)
                if kind == .skip {
                    Text(ReplayStepDisplay.kindDescription(kind))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                settingsPopoverStepID = step.wrappedValue.id
            } label: {
                Image(systemName: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Show settings")
            .accessibilityLabel("Show step settings")
            .popover(isPresented: settingsPopoverBinding(for: step.wrappedValue.id)) {
                ReplayStepSettingsPopover(step: step.wrappedValue.step)
            }
            if kind == .review {
                Toggle("Review", isOn: step.pauseToReview)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(!step.wrappedValue.included)
            } else if isChannelDecision(step.wrappedValue.step.operation) {
                // Classified `.decision` because *windowed* replay pauses to ask
                // about it. A batch cannot ask, so the tick in this row is the
                // answer — and the label says whose channels it would carry
                // rather than promising a pause that will not happen.
                Label("carries the source's channels", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("These channel numbers come from the recording the script was copied from, not from each input file. Tick it only if the same electrodes are bad in every file.")
            } else if kind == .decision {
                Label(
                    skipsUnsupportedDecisions ? "skips only if unsupported" : "Pauses",
                    systemImage: skipsUnsupportedDecisions ? "arrow.right.circle" : "hand.raised"
                )
                    .font(.caption2)
                    .foregroundStyle(skipsUnsupportedDecisions ? Color.blue : Color.orange)
            } else if kind == .skip {
                Label("not replayable", systemImage: "nosign")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Specific to the recording it came from, so it is recorded for provenance and not applied to other files.")
            } else if kind == .resolvedFromPayload {
                // The third state between "portable" and "subject-specific",
                // now decided once in `EVAProcessingStep.replayInteraction(given:)`
                // rather than privately here (ROADMAP RW-1 item 6).
                Label("from this file's own record", systemImage: "checkmark.seal")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .help("Every selected file carries its own saved settings for this step, so it re-applies exactly without needing a decision.")
            }
        }
        .opacity(kind == .skip ? 0.5 : 1)
    }

    private func isChannelDecision(_ operation: EVAProcessingStep.Operation) -> Bool {
        operation == .markBad || operation == .interpolateChannels
    }

    /// What every selected file carries, as one value the shared classification
    /// can be asked with. All-or-nothing across the batch: a step is only
    /// "resolved from this file's own record" if that is true of *each* file, so
    /// one file without a sidecar keeps the step a decision for the whole run.
    private var batchPayloadAvailability: ReplayPayloadAvailability {
        ReplayPayloadAvailability(
            hasICAPayload: everyFileHasItsOwn(ICAReplayPayload.read),
            hasArtifactPayload: everyFileHasItsOwn(ArtifactReplayPayload.read),
            hasElectrodeGeometry: everyFileHasItsOwn { url in
                ElectrodeGeometry.load(from: url).flatMap { $0.positions.isEmpty ? nil : $0 }
            },
            // Beat codes present in *every* selected file, on the same
            // all-or-nothing rule as the payloads: one file with no beats keeps
            // a recorded PCA-S step a decision for the whole run rather than
            // letting it fail partway through (ROADMAP SI-3).
            beatEventCodes: sharedBeatEventCodes
        )
    }

    private func settingsPopoverBinding(for id: Int) -> Binding<Bool> {
        Binding(
            get: { settingsPopoverStepID == id },
            set: { isPresented in
                if isPresented {
                    settingsPopoverStepID = id
                } else if settingsPopoverStepID == id {
                    settingsPopoverStepID = nil
                }
            }
        )
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Output Folder").font(.callout.weight(.semibold))
                Spacer()
                Button(outputFolder == nil ? "Choose…" : "Change…") { chooseOutputFolder() }
            }
            Text(outputFolder?.path ?? "Outputs are written here as <name>-processed, -segmented, or -average.mff.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: Actions

    private var canStart: Bool {
        !files.isEmpty && script != nil && outputFolder != nil
            && config.steps.contains { $0.included && $0.kind != .skip }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mff]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        _ = addInputFiles(panel.urls)
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mff, .xml]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = loadProcessingSource(from: url)
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { outputFolder = panel.url }
    }

    /// Full Auto, with no *included* step that would ever pause for a human
    /// (an unresolved decision without the opt-in skip policy, or a review step
    /// with "pause to review" on) — the whole batch can run headlessly, with no
    /// window opened for any file. See `BatchController.startHeadless`.
    private var canRunHeadless: Bool {
        guard config.mode == .fullAuto else { return false }
        return !config.steps.contains { step in
            guard step.included else { return false }
            if step.kind == .review, step.pauseToReview { return true }
            guard step.kind == .decision else { return false }
            // A decision step is a decision only while the decision is unmade.
            // When every input package carries its own payload — the ICA
            // operator, the drawn artifact definitions — the answer is already
            // recorded and re-applying it asks nobody anything, so it stops
            // being a reason to open a window.
            // Channel decisions are `.decision` because windowed replay pauses
            // to ask about them. A batch does not ask — the operator already
            // answered by ticking the step in this sheet — so they do not force
            // a window; `ProcessingCore` applies exactly the ones left checked.
            if isChannelDecision(step.step.operation) { return false }
            if skipsUnsupportedDecisions { return false }
            return true
        }
    }

    private var showsSkipDecisionPolicy: Bool {
        config.steps.contains { $0.kind == .decision }
    }

    /// Whether every selected file carries its own payload of the given kind.
    ///
    /// Checked per *file*, not per script, and deliberately so: an ICA operator
    /// belongs to one subject's electrodes and a drawn template to one subject's
    /// blink, so "this script contains ICA" says nothing about whether any given
    /// file can re-apply it. A file without a sidecar needs a human, which is
    /// exactly the window this gate exists to open. Reading a few tens of KB of
    /// JSON per file at setup is cheap next to being wrong about it.
    /// Event codes every selected file carries, derived from the off-main
    /// preflight rather than parsing `Events*.xml` a second time on the UI
    /// thread.
    private func refreshSharedBeatEventCodesFromPreflight() {
        guard !files.isEmpty,
              !preflight.isChecking,
              files.allSatisfy({ preflight.state.results[$0]?.inspectionError == nil }) else {
            sharedBeatEventCodes = []
            return
        }
        var shared: Set<String>?
        for url in files {
            guard let result = preflight.state.results[url] else {
                sharedBeatEventCodes = []
                return
            }
            let codes = result.eventCodes
            shared = shared.map { $0.intersection(codes) } ?? codes
        }
        sharedBeatEventCodes = shared ?? []
    }

    private func everyFileHasItsOwn<Payload>(_ read: (URL) -> Payload?) -> Bool {
        !files.isEmpty && files.allSatisfy { read($0) != nil }
    }

    private func start() {
        if preflight.isChecking || !flaggedFileURLs.isEmpty {
            showsStartWarning = true
        } else {
            performStart()
        }
    }

    private func performStart() {
        guard let script, let outputFolder else { return }
        var scoped = files
        scoped.append(outputFolder)
        if canRunHeadless {
            // Only the steps the user left checked. The windowed path has always
            // honoured `included` (it takes `config.steps`); headless received the
            // whole script and applied every auto step regardless, so unchecking
            // one did nothing there. Filtering here makes the two agree — and it
            // is what lets a *checked* provenance step, like `markBad`, mean
            // "yes, apply this" rather than being indistinguishable from one the
            // user deliberately left off.
            //
            // **Only steps the user could actually uncheck are dropped.** A
            // `.skip`-classified step is forced to `included = false` and its
            // toggle is `.disabled`, so its inclusion state is not a decision —
            // it is a default nobody can change. Honouring it stripped `icaClean`
            // and `artifactClean` out of the headless script, which meant neither
            // ran even when the file carried its own payload, and the batch
            // output silently described a chain that had not happened. Whether a
            // provenance step runs is decided by payload presence in
            // `ProcessingCore`, not by a checkbox that cannot be ticked.
            var includedScript = script
            let toggleable = Set(config.steps.filter { $0.kind != .skip }.map(\.id))
            let excluded = Set(config.steps.filter { !$0.included }.map(\.id))
            includedScript.steps = script.steps.enumerated()
                .filter { index, _ in !(toggleable.contains(index) && excluded.contains(index)) }
                .map(\.element)
            Task {
                await batch.startHeadless(
                    files: files,
                    script: includedScript,
                    sourceName: sourceName,
                    outputFolder: outputFolder,
                    skipUnsupportedDecisions: skipsUnsupportedDecisions,
                    scopedURLs: scoped
                )
            }
        } else {
            batch.start(
                files: files,
                script: script,
                sourceName: sourceName,
                steps: config.steps,
                mode: config.mode,
                outputFolder: outputFolder,
                skipUnsupportedDecisions: skipsUnsupportedDecisions,
                scopedURLs: scoped
            )
        }
        onStart()
    }

    private var includedStepIndices: Set<Int> {
        Set(config.steps.filter { $0.included && $0.kind != .skip }.map(\.id))
    }

    private func relevantIssues(in result: BatchPreflightResult) -> [BatchPreflightIssue] {
        let dropped = Set(policyDrops(in: result).map(\.stepIndex))
        return result.issues.filter {
            includedStepIndices.contains($0.stepIndex) && !dropped.contains($0.stepIndex)
        }
    }

    private func policyDrops(in result: BatchPreflightResult) -> [BatchDecisionDrop] {
        guard skipsUnsupportedDecisions, let script else { return [] }
        return BatchDecisionPolicy.apply(
            to: script,
            availability: result.payloadAvailability,
            enabled: true
        ).drops.filter { includedStepIndices.contains($0.stepIndex) }
    }

    private var flaggedFileURLs: [URL] {
        files.filter { url in
            guard let result = preflight.state.results[url] else { return false }
            return result.inspectionError != nil || !relevantIssues(in: result).isEmpty
        }
    }

    private var startWarningMessage: String {
        var lines: [String] = []
        if preflight.isChecking {
            lines.append("Compatibility inspection has not finished for every recording.")
        }
        let flagged = flaggedFileURLs
        if !flagged.isEmpty {
            let issueCount = flagged.reduce(0) { count, url in
                guard let result = preflight.state.results[url] else { return count }
                let inspectionFailure = result.inspectionError == nil ? 0 : 1
                return count + max(relevantIssues(in: result).count, inspectionFailure)
            }
            lines.append("\(flagged.count) recording\(flagged.count == 1 ? "" : "s") ha\(flagged.count == 1 ? "s" : "ve") \(issueCount) unresolved compatibility warning\(issueCount == 1 ? "" : "s").")
            lines.append(canRunHeadless
                ? "Automatic processing stops an affected recording at its flagged step and marks it Needs Input."
                : "Windowed processing leaves incompatible steps out for the affected recording.")
        }
        lines.append("You can start anyway; no source recording will be changed.")
        return lines.joined(separator: "\n\n")
    }

    @discardableResult
    private func addInputFiles(_ urls: [URL]) -> Bool {
        let candidates = urls.filter(isInputMFF)
        guard !candidates.isEmpty else {
            inputDropMessage = "Only MFF packages can be used as batch input."
            return false
        }

        var added = 0
        for url in candidates where !containsInputFile(url) {
            files.append(url)
            added += 1
        }

        let ignored = urls.count - candidates.count
        if added == 0 {
            inputDropMessage = "Those MFF files are already in the batch."
        } else if ignored > 0 {
            inputDropMessage = "Ignored \(ignored) non-MFF item\(ignored == 1 ? "" : "s")."
        } else {
            inputDropMessage = nil
        }
        return true
    }

    /// Re-runs the shared classification against the current file selection,
    /// preserving the include/review ticks the operator has already made.
    private func reclassifySteps() {
        guard let script else { return }
        let previous = config.steps
        let previousMode = config.mode
        config.configure(
            script: script, sourceName: sourceName, availability: batchPayloadAvailability
        )
        for index in config.steps.indices where previous.indices.contains(index) {
            config.steps[index].included = previous[index].included
            config.steps[index].pauseToReview = previous[index].pauseToReview
        }
        config.mode = previousMode
    }

    private func handleProcessingSourceDrop(_ urls: [URL]) -> Bool {
        let candidates = urls.filter(isProcessingSource)
        guard !candidates.isEmpty else {
            sourceDropMessage = "Drop an eva.xml file or an MFF that contains one."
            return false
        }
        for url in candidates where loadProcessingSource(from: url) {
            return true
        }
        sourceDropMessage = "No eva.xml processing steps were found in the dropped source."
        return false
    }

    @discardableResult
    private func loadProcessingSource(from url: URL) -> Bool {
        guard isProcessingSource(url) else {
            sourceDropMessage = "Drop an eva.xml file or an MFF that contains one."
            return false
        }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let read = EVAProcessingScriptXML.read(fromFile: url) else {
            sourceDropMessage = "No eva.xml processing steps were found in \(url.lastPathComponent)."
            return false
        }
        script = read
        sourceName = url.lastPathComponent
        skipsUnsupportedDecisions = false
        settingsPopoverStepID = nil
        sourceDropMessage = nil
        config.configure(
            script: read, sourceName: sourceName, availability: batchPayloadAvailability
        )
        config.showsConfigPane = false
        preflight.refresh(files: files, script: read)
        return true
    }

    private func containsInputFile(_ url: URL) -> Bool {
        let normalized = url.standardizedFileURL
        return files.contains { $0.standardizedFileURL == normalized }
    }

    private func isInputMFF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "mff"
    }

    private func isProcessingSource(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "mff" || ext == "xml"
    }

}
