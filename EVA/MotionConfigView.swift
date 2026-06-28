//
//  MotionConfigView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Configuration panel for the MR gradient-artifact tool. Lets the user load
//  AFNI 3dvolreg motion parameters (-1Dfile / -dfile), inspect them as a motion
//  plot, and set a framewise-displacement threshold for downstream algorithms.
//

import Charts
import SwiftUI
import UniformTypeIdentifiers

struct MotionConfigView: View {
    @Binding var parameters: MotionParameters?
    @Binding var fdThreshold: Double
    @Binding var radiusMm: Double

    // Current MR gradient-removal configuration, shown for reference.
    let trMarkerCode: String
    let trMarkerCount: Int?
    let windowBefore: Int
    let windowAfter: Int

    let onClose: () -> Void

    @State private var loadError: String?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("MR Gradient — Motion Configuration")
                    .font(.title3.weight(.semibold))
                Spacer()
                if let parameters {
                    Text("\(parameters.count) volumes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            currentConfigSection

            Divider()

            motionFileSection

            if let parameters {
                plotSection(for: parameters)
                thresholdSection(for: parameters)
            } else {
                ContentUnavailableView(
                    "No Motion File Loaded",
                    systemImage: "arrow.down.doc",
                    description: Text("Drag a 3dvolreg motion file (.1D, -1Dfile or -dfile) here, or use Load Motion File…")
                )
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                )
            }

            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Current config

    private var currentConfigSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Current Configuration")
                .font(.caption.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("TR marker event").foregroundStyle(.secondary)
                    Text(trMarkerCount.map { "\(trMarkerCode)  (\($0) markers)" } ?? trMarkerCode)
                        .monospacedDigit()
                }
                GridRow {
                    Text("Template window").foregroundStyle(.secondary)
                    Text("\(windowBefore) pre / \(windowAfter) post TRs")
                        .monospacedDigit()
                }
                GridRow {
                    Text("Motion source").foregroundStyle(.secondary)
                    Text(parameters?.sourceName ?? "none")
                }
            }
            .font(.caption)
        }
    }

    // MARK: - File loading

    private var motionFileSection: some View {
        HStack(spacing: 12) {
            Button {
                loadMotionFile()
            } label: {
                Label("Load Motion File…", systemImage: "doc.badge.plus")
            }

            if parameters != nil {
                Button(role: .destructive) {
                    parameters = nil
                    loadError = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }

            Spacer()
            Text("Accepts 3dvolreg -1Dfile (6 col) or -dfile (9 col). Drag a file in or browse.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func loadMotionFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // .1D files have no registered UTI, so allow plain text and generic data.
        panel.allowedContentTypes = [.plainText, .data, .text]
        panel.allowsOtherFileTypes = true
        panel.prompt = "Load"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(from: url)
    }

    /// Parse a motion file at `url` into the bound parameters, reporting errors.
    private func load(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            parameters = try MotionParameters.parse(text: text, sourceName: url.lastPathComponent)
            loadError = nil
        } catch {
            loadError = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Handle a Finder drag-and-drop of a single motion file.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { load(from: url) }
        }
        return true
    }

    // MARK: - Motion plot

    private func plotSection(for parameters: MotionParameters) -> some View {
        let fd = parameters.framewiseDisplacement(radiusMm: radiusMm)

        return VStack(alignment: .leading, spacing: 14) {
            // Rotations (degrees).
            VStack(alignment: .leading, spacing: 4) {
                Text("Rotation (degrees)")
                    .font(.caption.weight(.semibold))
                Chart {
                    rotationSeries(parameters, axis: "roll (I-S)", value: \.roll)
                    rotationSeries(parameters, axis: "pitch (R-L)", value: \.pitch)
                    rotationSeries(parameters, axis: "yaw (A-P)", value: \.yaw)
                }
                .chartForegroundStyleScale([
                    "roll (I-S)": Color.red,
                    "pitch (R-L)": Color.green,
                    "yaw (A-P)": Color.blue,
                ])
                .chartXAxisLabel("Volume")
                .frame(height: 130)
            }

            // Translations (mm).
            VStack(alignment: .leading, spacing: 4) {
                Text("Translation (mm)")
                    .font(.caption.weight(.semibold))
                Chart {
                    rotationSeries(parameters, axis: "dS (Superior)", value: \.dS)
                    rotationSeries(parameters, axis: "dL (Left)", value: \.dL)
                    rotationSeries(parameters, axis: "dP (Posterior)", value: \.dP)
                }
                .chartForegroundStyleScale([
                    "dS (Superior)": Color.orange,
                    "dL (Left)": Color.purple,
                    "dP (Posterior)": Color.teal,
                ])
                .chartXAxisLabel("Volume")
                .frame(height: 130)
            }

            // Framewise displacement with the threshold rule.
            VStack(alignment: .leading, spacing: 4) {
                Text("Framewise Displacement (mm)")
                    .font(.caption.weight(.semibold))
                Chart {
                    ForEach(Array(fd.enumerated()), id: \.offset) { index, value in
                        LineMark(
                            x: .value("Volume", index),
                            y: .value("FD", value)
                        )
                        .foregroundStyle(Color.gray)
                    }
                    RuleMark(y: .value("Threshold", fdThreshold))
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("threshold \(fdThreshold, specifier: "%.2f") mm")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                }
                .chartXAxisLabel("Volume")
                .frame(height: 130)
            }
        }
    }

    private func rotationSeries(
        _ parameters: MotionParameters,
        axis: String,
        value: KeyPath<MotionSample, Double>
    ) -> some ChartContent {
        ForEach(parameters.samples) { sample in
            LineMark(
                x: .value("Volume", sample.id),
                y: .value(axis, sample[keyPath: value]),
                series: .value("Axis", axis)
            )
            .foregroundStyle(by: .value("Axis", axis))
        }
    }

    // MARK: - Threshold

    private func thresholdSection(for parameters: MotionParameters) -> some View {
        let exceeding = parameters.volumesExceeding(threshold: fdThreshold, radiusMm: radiusMm)
        let maxFD = parameters.framewiseDisplacement(radiusMm: radiusMm).max() ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text("Motion Threshold (FD)")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(exceeding.count) of \(parameters.count) volumes flagged")
                    .font(.caption)
                    .foregroundStyle(exceeding.isEmpty ? Color.secondary : Color.red)
            }

            HStack(spacing: 12) {
                Slider(value: $fdThreshold, in: 0.05...max(1.0, maxFD), step: 0.05)
                TextField("mm", value: $fdThreshold, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("mm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text("Rotation radius")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("mm", value: $radiusMm, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Text("mm (converts rotation to mm for FD)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label {
                Text("At \(fdThreshold, specifier: "%.2f") mm, **\(exceeding.count)** of \(parameters.count) TRs (\(percentExceeding(exceeding.count, of: parameters.count))) would be excluded as template donors when “Exclude high-motion TRs” is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "scissors")
                    .foregroundStyle(exceeding.isEmpty ? Color.secondary : Color.orange)
            }
        }
    }

    private func percentExceeding(_ count: Int, of total: Int) -> String {
        guard total > 0 else { return "0%" }
        return String(format: "%.1f%%", 100 * Double(count) / Double(total))
    }
}
