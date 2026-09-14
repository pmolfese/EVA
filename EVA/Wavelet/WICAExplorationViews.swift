//
//  WICAExplorationViews.swift
//  EVA
//
//  Experimental W-ICA component review. A row layout makes it practical to
//  scan many ICs without the oversized card grid used by the general ICA tool.
//

import SwiftUI

extension WaveformView {
    func openWICASheet(for signal: MFFSignalData) {
        wica.open(for: signal)
    }

    func wicaSheet(for signal: MFFSignalData) -> some View {
        WICAReviewSheet(
            model: wica,
            signal: signal,
            layout: recording.sensorLayout,
            onApply: {
                wavelet.clearResults()
                invalidateInterpolations()
                invalidateEpochsForSignalChange()
                artifactVM.detectionRefreshToken += 1
                wica.apply(signal: signal)
            }
        )
    }
}

private struct WICAReviewSheet: View {
    @Bindable var model: WICAViewModel
    let signal: MFFSignalData
    let layout: SensorLayout?
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Wavelet-Enhanced ICA")
                            .font(.title3.weight(.semibold))
                        Text("EXPERIMENTAL")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.18), in: Capsule())
                    }
                    Text("Wavelet-threshold ICA activations, then back-project only the removed coefficients.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let decomposition = model.decomposition {
                    Text("\(decomposition.componentCount) ICs · \(Int(decomposition.analysisSamplingRate)) Hz")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            controls

            if model.isAnalyzing || model.isApplying {
                ProgressView(value: model.progress, total: 1) {
                    HStack {
                        Text(model.progressMessage)
                        Spacer()
                        Text(String(format: "%.0f%%", model.progress * 100))
                            .monospacedDigit()
                    }
                }
            }

            if let decomposition = model.decomposition {
                componentList(decomposition)
            } else {
                ContentUnavailableView(
                    "Run ICA to inspect components",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: Text("The fit is temporary and the W-ICA result remains reversible in this recording window.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Button(model.isAnalyzing ? "Cancel ICA" : "Run ICA") {
                    if model.isAnalyzing { model.cancel() }
                    else { model.analyze(signal: signal, layout: layout) }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isApplying)

                Spacer()

                Button("Close") { dismiss() }
                Button("Apply W-ICA") { onApply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        model.decomposition == nil || model.isAnalyzing || model.isApplying
                            || model.effectiveComponents.isEmpty
                    )
            }
        }
        .padding(18)
        .frame(minWidth: 1_260, idealWidth: 1_420, minHeight: 650, idealHeight: 780)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Process", selection: $model.selectionMode) {
                    ForEach(WICASelectionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 310)

                Picker("ICA", selection: $model.method) {
                    ForEach(ICAMethod.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .frame(width: 190)
                .help(model.method.summary)

                Toggle("Auto components", isOn: Binding(
                    get: { model.usesAutomaticComponentCount },
                    set: { model.setAutomaticComponentCount($0, for: signal) }
                ))
                .toggleStyle(.checkbox)

                LabeledContent("Max ICs") {
                    TextField("Count", value: $model.componentCount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 62)
                        .disabled(model.usesAutomaticComponentCount)
                }
                LabeledContent("Search Hz") {
                    TextField("Hz", value: $model.downsampleRate, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 62)
                }
            }

            HStack(spacing: 12) {
                LabeledContent("Iterations") {
                    TextField("Maximum", value: $model.maxIterations, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
                LabeledContent("PCA variance") {
                    TextField("Retained", value: $model.varianceThreshold, format: .number.precision(.fractionLength(4)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 76)
                }
                LabeledContent("Wavelet threshold") {
                    TextField("Scale", value: $model.thresholdScale, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 62)
                }
                Toggle("Metal", isOn: $model.usesMetal)
                    .toggleStyle(.checkbox)
                    .disabled(!WaveletMetalBackend.isAvailable)
                    .help("Uses EVA's Metal wavelet backend when available; otherwise W-ICA uses bounded CPU parallelism.")

                Text(model.usesAutomaticComponentCount
                     ? "Auto uses min(channels − 1, 32); PCA may retain fewer."
                     : "Manual maximum; PCA may retain fewer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.selectionMode == .selected {
                Text("ICLabel suggestions are preselected, but the fixture currently shows that labels can miss the true artifact IC. Review and override the checkboxes before applying.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("All-component mode is the original W-ICA form and is EVA's experimental default based on the seeded preservation fixture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(model.isAnalyzing || model.isApplying)
    }

    private func componentList(_ decomposition: ICADecomposition) -> some View {
        VStack(spacing: 0) {
            componentHeader
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<decomposition.componentCount, id: \.self) { component in
                        componentRow(component, decomposition: decomposition)
                        Divider()
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.6)) }
    }

    private var componentHeader: some View {
        HStack(spacing: 10) {
            Text("Use").frame(width: 36)
            Text("IC").frame(width: 34, alignment: .leading)
            Text("Variance").frame(width: 70, alignment: .trailing)
            Text("ICLabel categories").frame(width: 190, alignment: .leading)
            Text("Topomap").frame(width: 130, alignment: .leading)
            Text("Original component").frame(maxWidth: .infinity, alignment: .leading)
            Text("Cleaned component").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func componentRow(_ component: Int, decomposition: ICADecomposition) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: componentBinding(component))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 36)
                .disabled(model.selectionMode == .all)
            Text("\(component + 1)")
                .font(.body.monospacedDigit().weight(.medium))
                .frame(width: 34, alignment: .leading)
            Text(explainedVariance(component, decomposition: decomposition))
                .font(.caption.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            categoryView(decomposition.labelSuggestions[component])
                .frame(width: 190, alignment: .leading)

            if let layout,
               decomposition.componentMaps.indices.contains(component) {
                TopomapView(
                    layout: layout,
                    values: normalizedTopography(decomposition.componentMaps[component]),
                    timeSeconds: 0,
                    fixedScale: 1,
                    unitLabel: "a.u.",
                    showsHeader: false,
                    colorBarPlacement: .none,
                    minimumMapHeight: 90
                )
                .frame(width: 130, height: 105)
            } else {
                Text("No layout")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 130, height: 105)
            }

            if decomposition.componentSources.indices.contains(component) {
                let cleaned = model.result?.cleanedComponentPreviews[component]
                ICATimeCoursePreview(
                    samples: decomposition.componentSources[component],
                    visibleRange: nil,
                    scaleSamples: cleaned
                )
                .frame(minWidth: 280, maxWidth: .infinity, minHeight: 86, maxHeight: 86)
            }

            if let cleaned = model.result?.cleanedComponentPreviews[component] {
                let original = decomposition.componentSources.indices.contains(component)
                    ? decomposition.componentSources[component]
                    : nil
                ICATimeCoursePreview(samples: cleaned, visibleRange: nil, scaleSamples: original)
                    .frame(minWidth: 280, maxWidth: .infinity, minHeight: 86, maxHeight: 86)
            } else {
                Text(model.result == nil ? "Apply W-ICA to preview" : "Not processed")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 280, maxWidth: .infinity, minHeight: 86, maxHeight: 86)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(model.effectiveComponents.contains(component) ? Color.accentColor.opacity(0.055) : .clear)
        .help(decomposition.labelSuggestions[component]?.reason ?? "No classifier explanation is available.")
    }

    @ViewBuilder
    private func categoryView(_ suggestion: ICAComponentSuggestion?) -> some View {
        if let suggestion {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.label)
                    .font(.caption.weight(.medium))
                if !suggestion.probabilities.isEmpty {
                    Text(suggestion.probabilities.sorted { $0.value > $1.value }.prefix(3)
                        .map { "\($0.key) \(Int(($0.value * 100).rounded()))%" }
                        .joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } else {
            Text("Unlabeled").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func componentBinding(_ component: Int) -> Binding<Bool> {
        Binding(
            get: { model.selectionMode == .all || model.selectedComponents.contains(component) },
            set: { selected in
                if selected { model.selectedComponents.insert(component) }
                else { model.selectedComponents.remove(component) }
            }
        )
    }

    private func explainedVariance(_ component: Int, decomposition: ICADecomposition) -> String {
        guard decomposition.explainedVariance.indices.contains(component) else { return "—" }
        let total = decomposition.explainedVariance.reduce(0, +)
        guard total > 0 else { return "—" }
        return String(format: "%.1f%%", 100 * decomposition.explainedVariance[component] / total)
    }
}
