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
    @State private var outputFolder: URL?
    @State private var sourceName = ""
    @State private var script: EVAProcessingScript?
    @State private var config = ReplayController()
    @State private var settingsPopoverStepID: Int?
    @State private var inputDropIsTargeted = false
    @State private var sourceDropIsTargeted = false
    @State private var inputDropMessage: String?
    @State private var sourceDropMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Batch Process")
                    .font(.headline)
                Text("Apply one processing script to many recordings. Portable steps run automatically; decision steps (ICA) pause on each file so you can choose, then it continues.")
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
                    HStack {
                        Image(systemName: "waveform")
                        Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            files.removeAll { $0 == url }
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                    }
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
                Label("Pauses", systemImage: "hand.raised")
                    .font(.caption2)
                    .foregroundStyle(.orange)
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
            }
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
    /// (a decision step like ICA/drawn-artifact-cleaning, or a review step
    /// with "pause to review" on) — the whole batch can run headlessly, with
    /// no window opened for any file. See `BatchController.startHeadless`.
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
            return true
        }
    }

    /// Whether every selected file carries its own payload of the given kind.
    ///
    /// Checked per *file*, not per script, and deliberately so: an ICA operator
    /// belongs to one subject's electrodes and a drawn template to one subject's
    /// blink, so "this script contains ICA" says nothing about whether any given
    /// file can re-apply it. A file without a sidecar needs a human, which is
    /// exactly the window this gate exists to open. Reading a few tens of KB of
    /// JSON per file at setup is cheap next to being wrong about it.
    private func everyFileHasItsOwn<Payload>(_ read: (URL) -> Payload?) -> Bool {
        !files.isEmpty && files.allSatisfy { read($0) != nil }
    }

    private func start() {
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
                scopedURLs: scoped
            )
        }
        onStart()
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
        // Availability is a property of the *files*, so adding one can change
        // how a step classifies (a file with no ICA sidecar turns "from this
        // file's own record" back into a decision). Re-classify rather than
        // leaving a label that was true of the earlier selection.
        reclassifySteps()
        return true
    }

    /// Re-runs the shared classification against the current file selection,
    /// preserving the include/review ticks the operator has already made.
    private func reclassifySteps() {
        guard let script else { return }
        let previous = config.steps
        config.configure(
            script: script, sourceName: sourceName, availability: batchPayloadAvailability
        )
        for index in config.steps.indices where previous.indices.contains(index) {
            config.steps[index].included = previous[index].included
            config.steps[index].pauseToReview = previous[index].pauseToReview
        }
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
        settingsPopoverStepID = nil
        sourceDropMessage = nil
        config.configure(
            script: read, sourceName: sourceName, availability: batchPayloadAvailability
        )
        config.showsConfigPane = false
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
