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

import Combine
import SwiftUI

struct SourceSimulatorWindowView: View {
    @Environment(SourceSimulatorController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    /// Drives the scrubber during playback; `advancePlayback` is a no-op when
    /// paused, so an idle window costs nothing but a discarded tick.
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var controller = controller
        HStack(spacing: 0) {
            viewports(controller: controller)
            Divider()
            inspector(controller: controller)
                .frame(width: 288)
        }
        .frame(minWidth: 860, minHeight: 640)
        .onReceive(tick) { _ in controller.advancePlayback(by: 1.0 / 30.0) }
    }

    private func openRecording(_ url: URL) {
        PendingWindowOpens.shared.push([url])
        openWindow(id: "main")
    }

    // MARK: Viewports (2×2 glass brain + field, then the activation timeline)

    private func viewports(controller: SourceSimulatorController) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HeadProjectionView(plane: .axial, controller: controller)
                HeadProjectionView(plane: .coronal, controller: controller)
            }
            HStack(spacing: 10) {
                HeadProjectionView(plane: .sagittal, controller: controller)
                ScalpFieldView(controller: controller)
            }
            Divider()
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Inspector

    private func inspector(controller: SourceSimulatorController) -> some View {
        @Bindable var controller = controller
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sources").font(.headline)
                Spacer()
                Button { controller.addSource() } label: { Image(systemName: "plus") }
                    .help("Add a dipole")
                Button { controller.removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(controller.selectedID == nil)
                    .help("Remove the selected dipole")
            }
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
            .frame(minHeight: 100, maxHeight: 150)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    selectedSourceControls(controller: controller)
                    Divider()
                    selectedActivationControls(controller: controller)
                    Divider()
                    modelControls(controller: controller)
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
