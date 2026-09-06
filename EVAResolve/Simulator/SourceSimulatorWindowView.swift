//
//  SourceSimulatorWindowView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-2/SIM-3 — the Source Simulator window. A dedicated single-instance window
//  (File ▸ New ▸ Source Simulator), separate from the Simulator Studio because
//  this is live, spatial, direct-manipulation work. Three orthographic glass-brain
//  projections (SIM-3) sit beside the live scalp field (SIM-2), with an activation
//  timeline (Stage 3a) below — all coupled through the in-process forward solver.
//
//  `sourceSimulator` is owned by `EVAApp` and injected at the `Window` scene root.
//

import AppKit
import Combine
import SwiftUI

struct SourceSimulatorWindowView: View {
    @Environment(SourceSimulatorController.self) private var controller

    /// Height of the activation-timeline strip; dragged by `timelineSplitter`.
    @State private var timelineHeight: CGFloat = 210
    @State private var dragStartTimelineHeight: CGFloat?

    /// Drives the scrubber during playback; `advancePlayback` is a no-op when
    /// paused, so an idle window costs nothing but a discarded tick.
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 0) {
            HStack {
                Picker("Mode", selection: $controller.windowMode) {
                    ForEach(SourceSimulatorController.WindowMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if controller.windowMode == .simulate {
                simulateLayout(controller: controller)
            } else {
                SourceFitModeView(controller: controller)
            }
        }
        .frame(minWidth: 860, minHeight: 640)
        .onReceive(tick) { _ in controller.advancePlayback(by: 1.0 / 30.0) }
        .onAppear { claimPendingFit(controller: controller) }
        .onReceive(NotificationCenter.default.publisher(for: .evaPendingSourceFit)) { _ in
            claimPendingFit(controller: controller)
        }
        // Re-fit the dipole whenever an input changes (playhead, geometry, noise).
        // `localizationSignature()` reads all of them, so evaluating it here also
        // establishes the observation that makes this fire.
        .onChange(of: controller.localizationSignature()) { _, _ in
            if controller.showDipoleFit { controller.scheduleFit() }
        }
        .onChange(of: controller.showDipoleFit) { _, on in
            if on { controller.scheduleFit() } else { controller.fitResult = nil }
        }
    }

    private func claimPendingFit(controller: SourceSimulatorController) {
        if let message = PendingSourceFit.shared.lastError {
            controller.showStatus(message)
        }
        guard let payload = PendingSourceFit.shared.claim() else { return }
        controller.applyPendingFit(dataset: payload.dataset, selection: payload.selection)
    }

    /// Simulate mode shares the Fit-mode "Workbench" skeleton: a sources list on
    /// the left, the three orthogonal head views stacked in the centre, and the
    /// live scalp field over the authoring controls on the right — with the
    /// activation timeline as a full-width strip beneath.
    private func simulateLayout(controller: SourceSimulatorController) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sourcesColumn(controller: controller).frame(width: 196)
                Divider()
                headsColumn(controller: controller).frame(maxWidth: .infinity)
                Divider()
                simulateRightColumn(controller: controller).frame(width: 336)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            timelineSplitter
            bottomStrip(controller: controller)
                .frame(height: timelineHeight)
        }
    }

    /// Drag handle between the viewports and the timeline. Dragging it down
    /// shrinks the timeline and gives the space to the head views, which fill
    /// their cells and so grow with it.
    private var timelineSplitter: some View {
        ZStack {
            Divider()
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 40, height: 3)
        }
        .frame(height: 10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStartTimelineHeight ?? timelineHeight
                    if dragStartTimelineHeight == nil { dragStartTimelineHeight = start }
                    timelineHeight = min(max(start - value.translation.height, 80), 640)
                }
                .onEnded { _ in dragStartTimelineHeight = nil }
        )
        .accessibilityLabel("Resize timeline")
    }

    /// Generated recordings are reviewed in EVA, not here: hand the package to
    /// EVA when it is installed, else to whatever owns `.mff`.
    private func openRecording(_ url: URL) {
        let workspace = NSWorkspace.shared
        if let eva = workspace.urlForApplication(withBundleIdentifier: "gov.nih.nimh.cmn.eva") {
            workspace.open([url], withApplicationAt: eva, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            workspace.open(url)
        }
    }

    // MARK: Left column — sources

    private func sourcesColumn(controller: SourceSimulatorController) -> some View {
        @Bindable var controller = controller
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Sources").font(.headline).lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                Button { controller.loadDemoScene() } label: { Image(systemName: "sparkles") }
                    .help("Load a demo scene: three sources with distinct time courses")
                Button { controller.addSource() } label: { Image(systemName: "plus") }
                    .help("Add a dipole")
                Button { controller.removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(controller.selectedID == nil)
                    .help("Remove the selected dipole")
            }
            .buttonStyle(.borderless)
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 6)

            List(selection: $controller.selectedID) {
                ForEach(controller.sources) { source in
                    HStack {
                        Circle()
                            .fill(source.id == controller.selectedID ? Color.accentColor : .orange)
                            .frame(width: 8, height: 8)
                        Text(source.name).font(.callout)
                        Spacer()
                        Text("\(source.activations.count)")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .tag(source.id)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Centre column — three stacked orthogonal head views

    private func headsColumn(controller: SourceSimulatorController) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("Head — 3 views").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            // Two views on top, one below — fills the wide centre far better than a
            // single tall column of three squeezed squares.
            HStack(spacing: 10) {
                HeadProjectionView(plane: .axial, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HeadProjectionView(plane: .coronal, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 10) {
                HeadProjectionView(plane: .sagittal, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Right column — live scalp field over authoring controls

    private func simulateRightColumn(controller: SourceSimulatorController) -> some View {
        VStack(spacing: 0) {
            ScalpFieldView(controller: controller)
                .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    selectedSourceControls(controller: controller)
                    Divider()
                    selectedActivationControls(controller: controller)
                    Divider()
                    noiseControls(controller: controller)
                    Divider()
                    localizationControls(controller: controller)
                    Divider()
                    modelControls(controller: controller)
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Bottom strip — activation timeline (and interval butterfly)

    private func bottomStrip(controller: SourceSimulatorController) -> some View {
        VStack(spacing: 8) {
            if controller.showDipoleFit && controller.fitMode == .interval {
                SourceButterflyView(controller: controller)
            }
            SourceTimelineView(controller: controller, open: openRecording)
            if !controller.generationMessage.isEmpty {
                HStack {
                    Text(controller.generationMessage)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func selectedSourceControls(controller: SourceSimulatorController) -> some View {
        @Bindable var controller = controller
        if let index = controller.sources.firstIndex(where: { $0.id == controller.selectedID }) {
            let source = controller.sources[index]
            VStack(alignment: .leading, spacing: 10) {
                Text(source.name).font(.callout.weight(.semibold))

                Text("Drag a dipole to move it; ⌥-drag to grab its arrow and aim it. Each view rotates about its own axis, so use all three to point anywhere.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Orientation").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button("Radial") { controller.sources[index].orientationUnit = radial(source.positionMeters) }
                    Button("X") { controller.sources[index].orientationUnit = SIMD3(1, 0, 0) }
                    Button("Y") { controller.sources[index].orientationUnit = SIMD3(0, 1, 0) }
                    Button("Z") { controller.sources[index].orientationUnit = SIMD3(0, 0, 1) }
                }
                .controlSize(.small)

                Text(positionSummary(source.positionMeters))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        } else {
            Text("Select or add a dipole to edit it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func selectedActivationControls(controller: SourceSimulatorController) -> some View {
        @Bindable var controller = controller
        if let location = selectedActivationLocation(controller) {
            let (si, ai) = location
            let activation = controller.sources[si].activations[ai]
            VStack(alignment: .leading, spacing: 8) {
                Text("Activation").font(.callout.weight(.semibold))
                LabeledContent("Waveform") {
                    Picker("Waveform", selection: waveformKind(controller, si, ai)) {
                        Text("Hold").tag(0)
                        Text("Sine").tag(1)
                        Text("ERP bump").tag(2)
                        Text("Noise").tag(3)
                    }.labelsHidden()
                }
                if case .sine = activation.waveform {
                    sliderRow("Frequency", sineFrequency(controller, si, ai), 0.5...40, precision: 1)
                }
                if case .erp = activation.waveform {
                    sliderRow("Width", erpWidth(controller, si, ai), 0.01...0.4, precision: 2)
                }
                sliderRow("Amplitude", $controller.sources[si].activations[ai].amplitudeNanoampereMeters, -100...100, precision: 0)
                sliderRow("Start", $controller.sources[si].activations[ai].startSeconds, 0...max(controller.durationSeconds, 0.1), precision: 2)
                sliderRow("Length", $controller.sources[si].activations[ai].lengthSeconds, 0.02...max(controller.durationSeconds, 0.1), precision: 2)
            }
        } else {
            Text("Select an activation in the timeline, or add one to the selected dipole.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func noiseControls(controller: SourceSimulatorController) -> some View {
        @Bindable var controller = controller
        return VStack(alignment: .leading, spacing: 8) {
            Text("Noise & artifacts").font(.callout.weight(.semibold))
            Text("The clean field is the truth; noise and artifacts are added on top and scored against it.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Background noise", isOn: $controller.noiseEnabled)
            if controller.noiseEnabled {
                LabeledContent("Model") {
                    Picker("Model", selection: $controller.noiseModel) {
                        ForEach(SourceSimulatorNoise.Model.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                sliderRow("SNR (dB)", $controller.noiseTargetSNRdB, -10...30, precision: 0)
            }

            Text("Artifacts").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Toggle("Blink", isOn: $controller.artifacts.blink)
            Toggle("Saccade", isOn: $controller.artifacts.saccade)
            Toggle("EMG", isOn: $controller.artifacts.emg)
            Toggle("BCG (cardioballistic)", isOn: $controller.artifacts.bcg)

            if controller.hasContamination {
                Toggle("Show noisy field", isOn: $controller.showNoisyField)
                liveScoreReadout(controller: controller)
            }
        }
    }

    @ViewBuilder
    private func liveScoreReadout(controller: SourceSimulatorController) -> some View {
        let live = controller.liveScore()
        VStack(alignment: .leading, spacing: 2) {
            Text("Score vs clean truth").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let live {
                HStack(spacing: 12) {
                    Text("now: SNR \(fmt(live.snrDb)) dB").font(.caption2.monospacedDigit())
                    Text("r \(fmt(live.correlation))").font(.caption2.monospacedDigit())
                }
            }
            if let overall = controller.overallScore() {
                Text("whole: SNR \(fmt(overall.snrDb)) dB · r \(fmt(overall.correlation))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func localizationControls(controller: SourceSimulatorController) -> some View {
        @Bindable var controller = controller
        return VStack(alignment: .leading, spacing: 8) {
            Text("Localization diagnostic").font(.callout.weight(.semibold))
            Text("Fits one dipole per placed source and reports each one's error vs its nearest true source. A validation check, not source imaging. Right-click a glass-brain view to fit; each fit shows as a purple diamond with a dashed line to its true source.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Show dipole fit", isOn: $controller.showDipoleFit)
            if controller.showDipoleFit {
                LabeledContent("Fit over") {
                    Picker("Fit over", selection: $controller.fitMode) {
                        ForEach(SourceSimulatorController.FitMode.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                Text(controller.fitMode == .interval
                     ? "Interval (spatiotemporal): drag the butterfly to pick a window; separates simultaneous sources with distinct time courses."
                     : "Instant: fits the single topography at the playhead — can't separate simultaneous sources.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                localizationReadout(controller: controller)
            }
        }
    }

    @ViewBuilder
    private func localizationReadout(controller: SourceSimulatorController) -> some View {
        if let loc = controller.fitResult {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(loc.usedNoisyField ? "Fit to noisy field" : "Fit to clean field")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if controller.isFitting {
                        ProgressView().controlSize(.mini)
                    }
                }
                Text("\(loc.pairs.count) dipole\(loc.pairs.count == 1 ? "" : "s")  ·  GOF \(fmt(loc.goodnessOfFit * 100))%")
                    .font(.caption2.monospacedDigit())
                ForEach(Array(loc.pairs.enumerated()), id: \.offset) { _, pair in
                    if let name = pair.trueSourceName,
                       let mm = pair.positionErrorMillimeters,
                       let deg = pair.orientationErrorDegrees {
                        Text("→ \(name): \(fmt(mm)) mm · \(fmt(deg))°")
                            .font(.caption2.monospacedDigit())
                    }
                }
                Text("per dipole: localization · orientation error")
                    .font(.caption2).foregroundStyle(.secondary)
                if loc.spatioTemporal && !loc.varianceSpectrum.isEmpty {
                    svdSpectrum(loc.varianceSpectrum, dipoles: loc.pairs.count)
                }
            }
        } else if controller.isFitting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Fitting…").font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Text("Add a source and place the playhead where it fires.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// A tiny bar sparkline of the SVD variance spectrum — the "how many dipoles"
    /// picture. Bars for components beyond the dipole count are drawn faint, so an
    /// over- or under-specified model is visible at a glance.
    @ViewBuilder
    private func svdSpectrum(_ spectrum: [Double], dipoles: Int) -> some View {
        let shown = Array(spectrum.prefix(8))
        let maxValue = shown.first ?? 1
        VStack(alignment: .leading, spacing: 2) {
            Text("SVD spectrum (model order)")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index < dipoles ? Color.purple : Color.secondary.opacity(0.35))
                        .frame(width: 10, height: max(1, CGFloat(value / max(maxValue, 1e-9)) * 28))
                }
            }
            .frame(height: 30, alignment: .bottom)
            Text(shown.prefix(max(dipoles, 1)).map { String(format: "%.0f%%", $0 * 100) }.joined(separator: " · "))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func fmt(_ v: Double) -> String {
        if v.isNaN { return "—" }
        if v.isInfinite { return "∞" }
        return String(format: "%.2f", v)
    }

    private func modelControls(controller: SourceSimulatorController) -> some View {
        @Bindable var controller = controller
        return VStack(alignment: .leading, spacing: 10) {
            Text("Head & montage").font(.callout.weight(.semibold))
            LabeledContent("Head model") {
                Picker("Head model", selection: headModelChoice(controller)) {
                    Text("3-shell").tag(0)
                    Text("4-shell").tag(1)
                }.pickerStyle(.segmented).labelsHidden()
            }
            LabeledContent("Channels") {
                Picker("Channels", selection: $controller.channelCount) {
                    ForEach([19, 32, 64, 128, 256], id: \.self) { Text("\($0)").tag($0) }
                }.labelsHidden().frame(maxWidth: 100)
            }
            LabeledContent("Reference") {
                Picker("Reference", selection: $controller.reference) {
                    Text("Average").tag(EEGReference.average)
                    Text("Infinity").tag(EEGReference.infinity)
                }.labelsHidden().frame(maxWidth: 120)
            }

            Text("Head display").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Toggle("BEM wireframe", isOn: $controller.showWireframe)
            Toggle("Outline circle", isOn: $controller.showOutlineCircle)

            Text("The scalp field is computed in-process from the analytic forward model — no file is written until Generate.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Helpers

    private func headModelChoice(_ controller: SourceSimulatorController) -> Binding<Int> {
        Binding(
            get: { controller.headModel == .classicFourShell ? 1 : 0 },
            set: { controller.headModel = $0 == 1 ? .classicFourShell : .classicThreeShell }
        )
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, precision: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).frame(width: 68, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.\(precision)f", value.wrappedValue))
                .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }

    // Activation editing.

    private func selectedActivationLocation(_ controller: SourceSimulatorController) -> (Int, Int)? {
        guard let id = controller.selectedActivationID, let found = controller.locate(id) else { return nil }
        return (found.source, found.activation)
    }

    private func waveformKind(_ controller: SourceSimulatorController, _ si: Int, _ ai: Int) -> Binding<Int> {
        Binding(
            get: {
                switch controller.sources[si].activations[ai].waveform {
                case .hold: return 0
                case .sine: return 1
                case .erp: return 2
                case .noise: return 3
                }
            },
            set: { controller.sources[si].activations[ai].waveform = Self.defaultWaveform(for: $0) }
        )
    }

    private static func defaultWaveform(for kind: Int) -> SourceSimulatorController.Waveform {
        switch kind {
        case 1: return .sine(frequencyHz: 10)
        case 2: return .erp(widthSeconds: 0.05)
        case 3: return .noise(seed: 42)
        default: return .hold
        }
    }

    private func sineFrequency(_ controller: SourceSimulatorController, _ si: Int, _ ai: Int) -> Binding<Double> {
        Binding(
            get: { if case .sine(let f) = controller.sources[si].activations[ai].waveform { return f } else { return 10 } },
            set: { controller.sources[si].activations[ai].waveform = .sine(frequencyHz: $0) }
        )
    }
    private func erpWidth(_ controller: SourceSimulatorController, _ si: Int, _ ai: Int) -> Binding<Double> {
        Binding(
            get: { if case .erp(let w) = controller.sources[si].activations[ai].waveform { return w } else { return 0.05 } },
            set: { controller.sources[si].activations[ai].waveform = .erp(widthSeconds: $0) }
        )
    }

    private func radial(_ position: SIMD3<Double>) -> SIMD3<Double> {
        let n = (position.x * position.x + position.y * position.y + position.z * position.z).squareRoot()
        return n > 1e-6 ? position / n : SIMD3(0, 0, 1)
    }

    private func positionSummary(_ p: SIMD3<Double>) -> String {
        String(format: "x %.0f  y %.0f  z %.0f mm", p.x * 1000, p.y * 1000, p.z * 1000)
    }
}
