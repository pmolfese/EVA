//
//  SimulatorGenerateView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-1 Generate mode: the tabbed inspector over a `SimulationConfig`, plus a
//  persistent bottom bar (seed · summary · Generate) and a status strip. Each tab
//  is a curated slice of the ~50-knob config grouped by its `// MARK:` sections;
//  the whole config still round-trips through the scenario JSON, so anything not
//  surfaced keeps its default. Binds straight to the shared `SimulatorController`.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SimulatorGenerateView: View {
    @Environment(SimulatorController.self) private var simulator
    /// Called with the generated recording so the window can open it.
    let open: (URL) -> Void

    var body: some View {
        @Bindable var simulator = simulator
        VStack(spacing: 0) {
            presetBar(simulator: simulator)
            TabView {
                RecordingTab().tabItem { Label("Recording", systemImage: "waveform") }
                SourcesTab().tabItem { Label("Sources & Head", systemImage: "brain.head.profile") }
                BackgroundTab().tabItem { Label("Background", systemImage: "waveform.path") }
                GradientTab().tabItem { Label("Gradient", systemImage: "waveform.path.ecg") }
                CardiacTab().tabItem { Label("Cardiac", systemImage: "heart") }
                OcularTab().tabItem { Label("Ocular", systemImage: "eye") }
                MuscleTab().tabItem { Label("Muscle & Other", systemImage: "bolt.horizontal") }
                ERPTab().tabItem { Label("ERP", systemImage: "chart.xyaxis.line") }
                DefectsTab().tabItem { Label("Defects", systemImage: "exclamationmark.triangle") }
                OutputTab().tabItem { Label("Output", systemImage: "folder") }
            }
            .padding([.horizontal, .top], 12)

            if simulator.phase != .idle {
                Divider()
                statusStrip(simulator: simulator)
            }

            Divider()
            bottomBar(simulator: simulator)
        }
    }

    // MARK: Preset bar

    private func presetBar(simulator: SimulatorController) -> some View {
        HStack(spacing: 8) {
            Text("Preset").font(.caption).foregroundStyle(.secondary)
            Menu {
                if SimulatorScenarioLibrary.all.isEmpty {
                    Text("No bundled scenarios found")
                } else {
                    ForEach(SimulatorScenarioLibrary.all) { preset in
                        Button {
                            load(preset, into: simulator)
                        } label: {
                            Text(preset.name)
                            if !preset.description.isEmpty { Text(preset.description) }
                        }
                    }
                }
            } label: {
                Label("Load a preset…", systemImage: "square.stack.3d.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Text("Presets are the same scenarios the CLI ships; each replaces the settings below.")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func load(_ preset: SimulatorScenarioLibrary.Preset, into simulator: SimulatorController) {
        guard let loaded = SimulatorScenarioLibrary.config(for: preset) else { return }
        simulator.config = loaded.config
        simulator.scenarioName = loaded.name
        simulator.options.coordinatesFile = nil
    }

    // MARK: Bottom bar

    private func bottomBar(simulator: SimulatorController) -> some View {
        @Bindable var simulator = simulator
        return HStack(spacing: 12) {
            Text("Seed").font(.callout)
            TextField("Seed", value: $simulator.config.seed, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 130)
            Button {
                simulator.config.seed = UInt64.random(in: 1...UInt64(UInt32.max))
            } label: {
                Image(systemName: "die.face.5")
            }
            .buttonStyle(.borderless)
            .help("Randomize the seed")

            Spacer()

            Text(summary(simulator.config))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                simulator.generate(open: open)
            } label: {
                Label("Generate", systemImage: "play.fill")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(simulator.isGenerating || !isValid(simulator.config))
        }
        .padding(12)
    }

    private func statusStrip(simulator: SimulatorController) -> some View {
        HStack(spacing: 10) {
            switch simulator.phase {
            case .generating:
                ProgressView().controlSize(.small)
                Text("Generating simulated recording…").font(.callout)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(simulator.statusMessage).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let output = simulator.lastOutput {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([output.directory])
                    }
                    Button("Open Again") { simulator.reopenLast(open: open) }
                }
                Button("Dismiss") { simulator.clearStatus() }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.tail)
                Spacer()
                Button("Dismiss") { simulator.clearStatus() }
            case .idle:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }

    private func summary(_ c: SimulationConfig) -> String {
        "\(c.channelCount) ch · \(Int(c.durationSeconds)) s · \(Int(c.samplingRate)) Hz"
    }

    private func isValid(_ c: SimulationConfig) -> Bool {
        c.channelCount >= 4 && c.durationSeconds > 0 && c.samplingRate > 0
    }
}

// MARK: - Shared field helpers

/// A labeled numeric text field row for a `Double`, with an optional unit label.
private struct DoubleRow: View {
    let title: String
    @Binding var value: Double
    var unit: String? = nil
    var width: CGFloat = 90
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: $value, format: .number)
                    .textFieldStyle(.roundedBorder).labelsHidden().frame(width: width)
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// A labeled numeric text field row for an `Int`, with an optional stepper range.
private struct IntRow: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int>? = nil
    var unit: String? = nil
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: $value, format: .number)
                    .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 80)
                if let range {
                    Stepper("", value: $value, in: range).labelsHidden()
                }
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

/// The consistent form scaffold each tab uses: a scrolling, left-aligned column.
private struct TabForm<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.callout.weight(.semibold)).padding(.top, 2)
    }
}

// MARK: - Tabs

private struct RecordingTab: View {
    @Environment(SimulatorController.self) private var simulator
    var body: some View {
        @Bindable var simulator = simulator
        TabForm {
            SectionHeader(title: "Geometry")
            LabeledContent("Name") {
                TextField("Name", text: $simulator.scenarioName)
                    .textFieldStyle(.roundedBorder).labelsHidden().frame(maxWidth: 260)
            }
            IntRow(title: "Channels", value: $simulator.config.channelCount, range: 4...256)
            DoubleRow(title: "Duration", value: $simulator.config.durationSeconds, unit: "seconds")
            LabeledContent("Sampling rate") {
                Picker("Sampling rate", selection: $simulator.config.samplingRate) {
                    ForEach(sampleRateChoices, id: \.self) { Text("\(Int($0)) Hz").tag($0) }
                }.labelsHidden().frame(maxWidth: 160)
            }
            Text("Seed lives in the bar below and is shared across every tab.")
                .font(.caption2).foregroundStyle(.secondary)

            SectionHeader(title: "Artifact rendering")
            IntRow(title: "Oversample ×", value: $simulator.config.artifactOversampleFactor, range: 1...256)
            DoubleRow(title: "Anti-alias fraction", value: $simulator.config.artifactAntiAliasFraction)
            Text("Higher oversampling renders sharp artifacts (gradient, BCG) more faithfully at a compute cost.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var sampleRateChoices: [Double] {
        var c: [Double] = [250, 256, 500, 512, 1000, 1024, 2000]
        if !c.contains(simulator.config.samplingRate) { c.append(simulator.config.samplingRate); c.sort() }
        return c
    }
}

private struct SourcesTab: View {
    @Environment(SimulatorController.self) private var simulator
    private enum HeadModel: String, CaseIterable, Identifiable { case threeShell, fourShell
        var id: String { rawValue }
        var title: String { self == .fourShell ? "4-shell" : "3-shell" }
    }
    var body: some View {
        @Bindable var simulator = simulator
        TabForm {
            SectionHeader(title: "EEG model")
            LabeledContent("Generator") {
                Picker("Generator", selection: $simulator.config.eegGenerationModel) {
                    Text("Grouiller (spatial)").tag(EEGGenerationModel.grouiller)
                    Text("Dipole (forward)").tag(EEGGenerationModel.dipole)
                }.labelsHidden().frame(maxWidth: 220)
            }
            DoubleRow(title: "Target amplitude", value: $simulator.config.eegTargetStdMicrovolts, unit: "µV")

            SectionHeader(title: "Dipole sources")
            IntRow(title: "Source count", value: $simulator.config.dipoleSourceCount, range: 1...64)
            DoubleRow(title: "Radius fraction", value: $simulator.config.dipoleSourceRadiusFraction)
            LabeledContent("Orientation") {
                Picker("Orientation", selection: $simulator.config.dipoleOrientationPattern) {
                    ForEach(DipoleOrientationPattern.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }.labelsHidden().frame(maxWidth: 180)
            }
            DoubleRow(title: "Source motion", value: $simulator.config.dipoleMotionDegrees, unit: "°")

            SectionHeader(title: "Head model")
            LabeledContent("Shells") {
                Picker("Shells", selection: headModel) {
                    ForEach(HeadModel.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 200)
            }
            LabeledContent("Reference") {
                Picker("Reference", selection: $simulator.config.dipoleReference) {
                    Text("Average").tag(EEGReference.average)
                    Text("Infinity").tag(EEGReference.infinity)
                }.labelsHidden().frame(maxWidth: 160)
            }
            IntRow(title: "Lead-field terms", value: $simulator.config.leadFieldTerms, range: 10...400)

            SectionHeader(title: "Montage")
            LabeledContent("Coordinates") {
                HStack(spacing: 8) {
                    Text(simulator.options.coordinatesFile?.lastPathComponent ?? "Built-in montage")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Import…") { chooseCoordinates() }
                    if simulator.options.coordinatesFile != nil {
                        Button("Clear") { simulator.options.coordinatesFile = nil }
                    }
                }
            }
            DoubleRow(title: "Electrode jitter", value: jitter, unit: "°")
            Text("Import a coordinates.xml or an MFF to use its montage; jitter perturbs electrode angles. Named nets (HydroCel 64/128/256) come with SI-4.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var headModel: Binding<HeadModel> {
        Binding(
            get: { simulator.config.sphericalHeadModel == .classicFourShell ? .fourShell : .threeShell },
            set: { simulator.config.sphericalHeadModel = $0 == .fourShell ? .classicFourShell : .classicThreeShell }
        )
    }
    private var jitter: Binding<Double> {
        Binding(
            get: { simulator.config.montageJitterDegrees ?? 0 },
            set: { simulator.config.montageJitterDegrees = $0 > 0 ? $0 : nil }
        )
    }
    private func chooseCoordinates() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml, .mff]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a coordinates.xml or an MFF recording whose montage to use."
        if panel.runModal() == .OK, let url = panel.url {
            simulator.options.coordinatesFile = url
        }
    }
}

private struct BackgroundTab: View {
    @Environment(SimulatorController.self) private var simulator
    var body: some View {
        @Bindable var simulator = simulator
        TabForm {
            SectionHeader(title: "Overall")
            DoubleRow(title: "Target σ", value: $simulator.config.eegTargetStdMicrovolts, unit: "µV")

            SectionHeader(title: "Alpha (eyes open / closed)")
            DoubleRow(title: "Alpha low", value: $simulator.config.alphaLowMicrovolts, unit: "µV")
            DoubleRow(title: "Alpha high", value: $simulator.config.alphaHighMicrovolts, unit: "µV")
            DoubleRow(title: "Alpha cycle", value: $simulator.config.alphaCycleSeconds, unit: "s")

            SectionHeader(title: "Band amplitudes")
            ForEach(bandIndices, id: \.self) { index in
                DoubleRow(title: simulator.config.eegBands[index].name.capitalized,
                          value: bandAmplitude(index), unit: "µV")
            }
            Text("Per-band σ (delta / theta / beta / gamma) before the global scale to the target σ. Alpha is driven by the envelope above rather than a fixed amplitude.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var bandIndices: [Int] {
        simulator.config.eegBands.indices.filter { !simulator.config.eegBands[$0].isAlpha }
    }
    private func bandAmplitude(_ index: Int) -> Binding<Double> {
        Binding(
            get: { simulator.config.eegBands[index].amplitudeMicrovolts ?? 0 },
            set: { simulator.config.eegBands[index].amplitudeMicrovolts = $0 }
        )
    }
}

private struct GradientTab: View {
    @Environment(SimulatorController.self) private var simulator
    var body: some View {
        @Bindable var simulator = simulator
        TabForm {
            Toggle("MRI gradient artifact (EEG–fMRI)", isOn: $simulator.config.gradientEnabled)
                .font(.callout.weight(.semibold))
            Group {
                DoubleRow(title: "Repetition time (TR)", value: $simulator.config.repetitionTimeSeconds, unit: "s")
                IntRow(title: "Slices / volume", value: $simulator.config.slicesPerVolume, range: 1...200)
                DoubleRow(title: "Amplitude min", value: $simulator.config.gradientAmplitudeMinMicrovolts, unit: "µV", width: 110)
                DoubleRow(title: "Amplitude max", value: $simulator.config.gradientAmplitudeMaxMicrovolts, unit: "µV", width: 110)
                DoubleRow(title: "Clock offset", value: $simulator.config.clockOffsetMicrosecondsPerSecond, unit: "µs/s", width: 110)
                DoubleRow(title: "Pre-scan", value: $simulator.config.preScanSeconds, unit: "s")
                DoubleRow(title: "Post-scan", value: $simulator.config.postScanSeconds, unit: "s")
                DoubleRow(title: "Slow modulation", value: $simulator.config.slowModulationFraction)
            }
            .disabled(!simulator.config.gradientEnabled)
            Text("A non-integer clock offset is what makes gradient residuals realistic — the scanner and amplifier clocks drift.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct CardiacTab: View {
    @Environment(SimulatorController.self) private var simulator
    var body: some View {
        @Bindable var simulator = simulator
        TabForm {
            Toggle("Ballistocardiogram (BCG)", isOn: $simulator.config.bcgEnabled)
                .font(.callout.weight(.semibold))
            Group {
                DoubleRow(title: "Heart rate min", value: $simulator.config.heartRateMinBPM, unit: "bpm", width: 100)
                DoubleRow(title: "Heart rate max", value: $simulator.config.heartRateMaxBPM, unit: "bpm", width: 100)
                DoubleRow(title: "Amplitude", value: $simulator.config.bcgAmplitudeMicrovolts, unit: "µV")
                DoubleRow(title: "Amplitude jitter", value: $simulator.config.bcgAmplitudeJitterFraction)
                DoubleRow(title: "Heart-rate variability", value: $simulator.config.heartRateVariability)
                DoubleRow(title: "Respiration", value: $simulator.config.respirationHz, unit: "Hz")
                LabeledContent("Spatial model") {
                    Picker("Spatial model", selection: bcgSpatialModel) {
                        Text("Channel index (default)").tag(BCGSpatialModel.channelIndex)
                        Text("Physical generators").tag(BCGSpatialModel.generators)
                    }.labelsHidden().frame(maxWidth: 220)
                }
            }
            .disabled(!simulator.config.bcgEnabled)

            SectionHeader(title: "Auxiliary channels")
            Toggle("ECG channel", isOn: $simulator.config.includeECG)
            Toggle("Motion sensor channel", isOn: $simulator.config.includeMotionSensor)
        }
    }
    private var bcgSpatialModel: Binding<BCGSpatialModel> {
        Binding(
            get: { simulator.config.bcgSpatialModel ?? .channelIndex },
            set: { simulator.config.bcgSpatialModel = $0 }
        )
    }
}

private struct OcularTab: View {
    @Environment(SimulatorController.self) private var simulator
    var body: some View {
        @Bindable var simulator = simulator
        TabForm {
            Toggle("Eye blinks", isOn: $simulator.blinksEnabled).font(.callout.weight(.semibold))
            Group {
                DoubleRow(title: "Blinks / min", value: $simulator.config.blinksPerMinute)
                DoubleRow(title: "Blink amplitude", value: $simulator.config.blinkAmplitudeMicrovolts, unit: "µV")
                DoubleRow(title: "Blink duration", value: $simulator.config.blinkDurationSeconds, unit: "s")
            }
            .disabled(!simulator.blinksEnabled)

            Toggle("Saccades / eye movements", isOn: $simulator.saccadesEnabled)
                .font(.callout.weight(.semibold))
            Group {
                DoubleRow(title: "Saccades / min", value: $simulator.config.saccadesPerMinute)
                DoubleRow(title: "Movement amplitude", value: $simulator.config.eyeMovementAmplitudeMicrovolts, unit: "µV", width: 100)
                DoubleRow(title: "Transition", value: $simulator.config.saccadeTransitionSeconds, unit: "s")
            }
            .disabled(!simulator.saccadesEnabled)

            LabeledContent("Spatial model") {
                Picker("Spatial model", selection: $simulator.config.ocularSpatialModel) {
                    ForEach(OcularSpatialModel.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }.labelsHidden().frame(maxWidth: 180)
            }
        }
    }
}

private struct MuscleTab: View {
    @Environment(SimulatorController.self) private var simulator
    var body: some View {
        @Bindable var simulator = simulator
        TabForm {
            SectionHeader(title: "Muscle (EMG)")
            Toggle("Broadband EMG", isOn: $simulator.emgEnabled)
            if simulator.config.emg != nil {
                Group {
                    DoubleRow(title: "Bursts / min", value: emgBinding(\.burstsPerMinute))
                    DoubleRow(title: "Amplitude", value: emgBinding(\.amplitudeMicrovolts), unit: "µV")
                    DoubleRow(title: "Burst duration", value: emgBinding(\.burstDurationSeconds), unit: "s")
                }
            }
            Toggle("Chewing", isOn: optionalToggle(\.chewing, make: ChewingConfig()))
            Toggle("Swallowing", isOn: optionalToggle(\.swallowing, make: SwallowingConfig()))
            Toggle("Cable movement", isOn: optionalToggle(\.cableMovement, make: CableMovementConfig()))
            Toggle("Sweat / drift", isOn: optionalToggle(\.sweat, make: SweatConfig()))

            SectionHeader(title: "Other")
            LabeledContent("Line noise") {
                Picker("Line noise", selection: $simulator.config.lineNoiseHz) {
                    Text("Off").tag(0.0)
                    Text("50 Hz").tag(50.0)
                    Text("60 Hz").tag(60.0)
                }.labelsHidden().frame(maxWidth: 140)
            }
            if simulator.config.lineNoiseHz > 0 {
                DoubleRow(title: "Line amplitude", value: $simulator.config.lineNoiseAmplitudeMicrovolts, unit: "µV", width: 100)
            }
            Toggle("Clipping", isOn: $simulator.clippingEnabled)
            if simulator.clippingEnabled {
                DoubleRow(title: "Clip threshold", value: clipBinding, unit: "µV", width: 100)
            }
        }
    }
    private func emgBinding(_ keyPath: WritableKeyPath<EMGConfig, Double>) -> Binding<Double> {
        Binding(
            get: { simulator.config.emg?[keyPath: keyPath] ?? 0 },
            set: { if simulator.config.emg != nil { simulator.config.emg![keyPath: keyPath] = $0 } }
        )
    }
    private func optionalToggle<T>(_ keyPath: WritableKeyPath<SimulationConfig, T?>, make: @autoclosure @escaping () -> T) -> Binding<Bool> {
        Binding(
            get: { simulator.config[keyPath: keyPath] != nil },
            set: { simulator.config[keyPath: keyPath] = $0 ? make() : nil }
        )
    }
    private var clipBinding: Binding<Double> {
        Binding(
            get: { simulator.config.clippingThresholdMicrovolts ?? 200 },
            set: { simulator.config.clippingThresholdMicrovolts = $0 }
        )
    }
}

private struct ERPTab: View {
    @Environment(SimulatorController.self) private var simulator
    var body: some View {
        @Bindable var simulator = simulator
        TabForm {
            Toggle("Event-related potentials", isOn: erpEnabled).font(.callout.weight(.semibold))
            if simulator.config.erp != nil {
                Group {
                    IntRow(title: "Trials", value: erpInt(\.trialCount), range: 1...2000)
                    DoubleRow(title: "Target fraction", value: erpDouble(\.targetFraction))
                    DoubleRow(title: "Peak latency", value: erpDouble(\.peakLatencySeconds), unit: "s")
                    DoubleRow(title: "Target amplitude", value: erpDouble(\.targetAmplitudeMicrovolts), unit: "µV", width: 100)
                    DoubleRow(title: "ISI", value: erpDouble(\.interStimulusIntervalSeconds), unit: "s")
                }
                Text("Trials are written as events; the ERP overlays and single-trial tools read them like any real recording.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Adds an oddball-style stimulus train with standard/target conditions.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private var erpEnabled: Binding<Bool> {
        Binding(
            get: { simulator.config.erp != nil },
            set: { simulator.config.erp = $0 ? ERPConfig() : nil }
        )
    }
    private func erpInt(_ keyPath: WritableKeyPath<ERPConfig, Int>) -> Binding<Int> {
        Binding(
            get: { simulator.config.erp?[keyPath: keyPath] ?? 0 },
            set: { if simulator.config.erp != nil { simulator.config.erp![keyPath: keyPath] = $0 } }
        )
    }
    private func erpDouble(_ keyPath: WritableKeyPath<ERPConfig, Double>) -> Binding<Double> {
        Binding(
            get: { simulator.config.erp?[keyPath: keyPath] ?? 0 },
            set: { if simulator.config.erp != nil { simulator.config.erp![keyPath: keyPath] = $0 } }
        )
    }
}

private struct DefectsTab: View {
    @Environment(SimulatorController.self) private var simulator
    var body: some View {
        @Bindable var simulator = simulator
        TabForm {
            SectionHeader(title: "Impedance")
            Toggle("Include impedance measurements", isOn: $simulator.config.includeImpedance)
            if simulator.config.includeImpedance {
                DoubleRow(title: "Typical impedance", value: $simulator.config.impedanceTypicalKOhm, unit: "kΩ", width: 100)
            }
            SectionHeader(title: "Bad channels")
            Text("\(simulator.config.badChannels.count) channel\(simulator.config.badChannels.count == 1 ? "" : "s") flagged.")
                .font(.callout)
            Text("Per-channel defect authoring (flat, noisy, drifting, bridged) is planned; v1 generates a clean montage unless a scenario sets it.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct OutputTab: View {
    @Environment(SimulatorController.self) private var simulator
    var body: some View {
        @Bindable var simulator = simulator
        TabForm {
            SectionHeader(title: "Destination")
            LabeledContent("Folder") {
                HStack(spacing: 8) {
                    Text(simulator.options.outputDirectory?.path ?? "Temporary folder (not kept)")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                    if simulator.options.outputDirectory != nil {
                        Button("Use Temp") { simulator.options.outputDirectory = nil }
                    }
                }
            }
            LabeledContent("Filename prefix") {
                TextField("Prefix", text: $simulator.options.prefix)
                    .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 140)
            }
            Text("Writes \(prefix)_noisy.mff (opened), \(prefix)_clean.mff, \(prefix)_truth.json, \(prefix)_scenario.json, and \(prefix)_command.json.")
                .font(.caption2).foregroundStyle(.secondary)

            SectionHeader(title: "Options")
            Toggle("Write source-space ground truth (dipole model only)", isOn: $simulator.options.writeSources)
            Toggle("Open the recording after generating", isOn: $simulator.openAfterGenerate)
        }
    }
    private var prefix: String {
        simulator.options.prefix.isEmpty ? "sim" : simulator.options.prefix
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder to save generated recordings into."
        if panel.runModal() == .OK, let url = panel.url {
            simulator.options.outputDirectory = url
        }
    }
}
