//
//  HeadModelWindowView.swift
//  EVA Resolve
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The Head Model window (R2.4 first pass): MRI slices + 3-D view on the left,
//  a step-by-step inspector on the right — MRI, Fiducials, Electrodes, Fit,
//  Export. Every load goes through NSOpenPanel; every export through NSSavePanel.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import simd

struct HeadModelWindowView: View {
    @Environment(HeadModelController.self) private var controller
    @State private var axialIndex = 0
    @State private var coronalIndex = 0
    @State private var sagittalIndex = 0
    @State private var nudgeStepDegrees = 2.0
    @State private var nudgeStepMillimeters = 2.0

    var body: some View {
        @Bindable var controller = controller
        HStack(spacing: 0) {
            viewports
            Divider()
            inspector(controller: controller)
                .frame(width: 300)
        }
        .frame(minWidth: 1000, minHeight: 680)
        .onChange(of: controller.t1?.dimensions) { _, dims in
            guard let dims else { return }
            axialIndex = dims.z / 2; coronalIndex = dims.y / 2; sagittalIndex = dims.x / 2
        }
    }

    // MARK: Viewports

    private var viewports: some View {
        @Bindable var controller = controller
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                slicePane(.axial, index: $axialIndex, count: controller.t1?.nz ?? 1)
                slicePane(.coronal, index: $coronalIndex, count: controller.t1?.ny ?? 1)
            }
            HStack(spacing: 6) {
                slicePane(.sagittal, index: $sagittalIndex, count: controller.t1?.nx ?? 1)
                CoregistrationSceneView(controller: controller)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Text(controller.statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if controller.t1 != nil {
                    Text("Brightness").font(.caption2)
                    Slider(value: $controller.brightness, in: 0.2...4).frame(width: 120)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
    }

    private func slicePane(_ plane: MRISliceView.Plane, index: Binding<Int>, count: Int) -> some View {
        @Bindable var controller = controller
        return VStack(spacing: 2) {
            MRISliceView(plane: plane, controller: controller, sliceIndex: index)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Slider(value: Binding(get: { Double(index.wrappedValue) }, set: { index.wrappedValue = Int($0.rounded()) }),
                   in: 0...Double(max(count - 1, 1)))
                .controlSize(.mini)
                .disabled(controller.t1 == nil)
        }
    }

    // MARK: Inspector

    private func inspector(controller: HeadModelController) -> some View {
        @Bindable var controller = controller
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("1 · MRI") {
                    Button("Open T1 (NIfTI)…") { openPanel(types: ["nii", "gz"], message: "Choose a T1 NIfTI") { controller.loadT1(from: $0) } }
                    Button("Load scalp surface (-head.fif / .gii)…") { openPanel(types: ["fif", "gii"], message: "Choose a scalp surface") { controller.loadScalp(from: $0) } }
                    LabeledContent("Volume", value: controller.t1URL?.lastPathComponent ?? "none")
                    LabeledContent("Scalp", value: controller.scalpSource)
                }
                section("2 · Fiducials on the MRI") {
                    Picker("Pick", selection: $controller.fiducialToPick) {
                        ForEach(HeadModelController.FiducialKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("Click the point on any slice.").font(.caption).foregroundStyle(.secondary)
                    ForEach(HeadModelController.FiducialKind.allCases) { kind in
                        LabeledContent(kind.label, value: controller.mriFiducials[kind].map { mm($0) } ?? "—")
                    }
                    HStack {
                        Button("Clear") { controller.clearFiducials() }
                        Button("From -fiducials.fif…") { openPanel(types: ["fif"], message: "Choose an MNE fiducials file") { controller.loadFiducials(from: $0) } }
                    }
                }
                section("3 · Electrodes") {
                    Button("Open electrode file / .mff…") {
                        openPanel(types: ["mff", "xml", "sfp", "elc", "xyz", "csv", "tsv", "txt", "fif"], message: "Choose coordinates.xml, an .mff, a digitizer file, or an MNE dig file", directories: true) { controller.loadElectrodes(from: $0) }
                    }
                    Menu("Use template montage") {
                        ForEach(StandardMontage.allCases) { m in Button(m.displayName) { controller.useTemplate(m) } }
                    }
                    LabeledContent("Set", value: controller.electrodesSource)
                    if let e = controller.electrodes {
                        LabeledContent("Count", value: "\(e.eeg.count)" + (e.hasFiducials ? " · fiducials" : " · no fiducials"))
                    }
                }
                section("4 · Fit") {
                    Toggle("Allow scaling (template heads)", isOn: $controller.icpAllowScale)
                    HStack {
                        Text("Trim worst").font(.caption)
                        Slider(value: $controller.icpTrimFraction, in: 0...0.3).controlSize(.small)
                        Text("\(Int(controller.icpTrimFraction * 100))%").font(.caption.monospacedDigit())
                    }
                    HStack {
                        Button("Fit") { controller.refit() }
                        Button("Refine from here") { controller.refineFromCurrentPose() }.disabled(controller.headToMRI == nil)
                    }
                    if let r = controller.fitResult {
                        LabeledContent("RMS", value: String(format: "%.1f mm", r.rms * 1000))
                        LabeledContent("Median / max", value: String(format: "%.1f / %.1f mm", r.median * 1000, r.maximum * 1000))
                        if controller.icpAllowScale { LabeledContent("Scale", value: String(format: "%.3f", controller.templateScale)) }
                    }
                    nudgeControls(controller: controller)
                }
                section("5 · Save / export") {
                    Button("Save head model (.evahead)…") {
                        savePanel(name: "head-model.evahead") { try controller.save(to: $0) }
                    }
                    Button("Open head model…") { openPanel(types: ["evahead"], message: "Choose a head model package", directories: true) { controller.open(packageURL: $0) } }
                    Divider()
                    Button("Export MNE -trans.fif…") { savePanel(name: "head-mri-trans.fif") { try controller.exportTrans(to: $0) } }
                    Button("Export MNE -dig.fif (MRI frame)…") { savePanel(name: "electrodes-dig.fif") { try controller.exportDig(to: $0, inMRIFrame: true) } }
                    Button("Export scalp -head.fif…") { savePanel(name: "scalp-head.fif") { try controller.exportScalp(to: $0) } }
                }
            }
            .padding(12)
        }
    }

    private func nudgeControls(controller: HeadModelController) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nudge").font(.caption.bold())
            HStack {
                Text("Step").font(.caption2)
                Stepper(value: $nudgeStepDegrees, in: 0.5...10, step: 0.5) { Text("\(nudgeStepDegrees, specifier: "%.1f")°").font(.caption2.monospacedDigit()) }
                Stepper(value: $nudgeStepMillimeters, in: 0.5...10, step: 0.5) { Text("\(nudgeStepMillimeters, specifier: "%.1f") mm").font(.caption2.monospacedDigit()) }
            }
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    Text("Rotate").font(.caption2)
                    ForEach(["X", "Y", "Z"], id: \.self) { axis in
                        HStack(spacing: 2) {
                            Button("−") { rotate(axis, -nudgeStepDegrees) }
                            Button("+") { rotate(axis, nudgeStepDegrees) }
                        }
                    }
                }
                GridRow {
                    Text("Move").font(.caption2)
                    ForEach(["X", "Y", "Z"], id: \.self) { axis in
                        HStack(spacing: 2) {
                            Button("−") { translate(axis, -nudgeStepMillimeters) }
                            Button("+") { translate(axis, nudgeStepMillimeters) }
                        }
                    }
                }
                GridRow {
                    Text("Scale").font(.caption2)
                    Button("−1%") { controller.nudge(scale: 0.99) }
                    Button("+1%") { controller.nudge(scale: 1.01) }
                    Text("")
                }
            }
            .controlSize(.small)
            .disabled(controller.electrodes == nil)
        }
    }

    private func rotate(_ axis: String, _ degrees: Double) {
        var r = SIMD3<Double>(0, 0, 0)
        switch axis { case "X": r.x = degrees; case "Y": r.y = degrees; default: r.z = degrees }
        controller.nudge(rotationDegrees: r)
    }

    private func translate(_ axis: String, _ mm: Double) {
        var t = SIMD3<Double>(0, 0, 0)
        switch axis { case "X": t.x = mm; case "Y": t.y = mm; default: t.z = mm }
        controller.nudge(translationMillimeters: t)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 6) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func mm(_ p: SIMD3<Double>) -> String {
        String(format: "%.1f, %.1f, %.1f mm", p.x * 1000, p.y * 1000, p.z * 1000)
    }

    // MARK: Panels

    private func openPanel(types: [String], message: String, directories: Bool = false, _ action: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) } + [.data, .directory]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        action(url)
    }

    private func savePanel(name: String, _ action: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try action(url) } catch { controller.showStatus(error.localizedDescription) }
    }
}

extension HeadModelController {
    func showStatus(_ text: String) { statusMessage = text }
}
