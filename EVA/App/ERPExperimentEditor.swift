// Copyright-free US Government work; see LICENSE.
import SwiftUI
import AppKit

struct ERPExperimentEditor: View {
    @Binding var erp: ERPConfig
    let seed: UInt64
    let samplingRate: Double
    @Binding var recordingDuration: Double
    @State private var conditionID = "target"
    @State private var peakID = "p1"
    @State private var showOtherConditions = true
    @State private var preview: ERPStudioPreview?
    @State private var previewError: String?
    @State private var updatingPreview = false

    private var design: ERPExperimentConfig { erp.experiment ?? ERPExperimentConfig() }
    private var condition: ERPConditionConfig {
        design.conditions.first { $0.id == conditionID } ?? design.conditions.first ?? ERPConditionConfig()
    }
    private var peak: ERPWaveformPeak { condition.peaks.first { $0.id == peakID } ?? condition.peaks.first ?? ERPWaveformPeak() }
    private var allocations: [Int] { ERPExperimentSampler.counts(total: erp.trialCount, fractions: design.conditions.map(\.fraction)) }
    private var previewIdentity: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return "\(seed):" + ((try? encoder.encode(erp).base64EncodedString()) ?? "invalid")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            conditionControls
            waveformEditor
            HStack(alignment: .top, spacing: 12) {
                variabilityControls
                noiseControls
                scheduleControls
            }
            recipeControls
            previewControls
        }
        .onChange(of: design.conditions.map(\.id), initial: true) {
            if !design.conditions.contains(where: { $0.id == conditionID }) { conditionID = design.conditions.first?.id ?? "" }
        }
        .onChange(of: condition.id) { peakID = condition.peaks.first?.id ?? "" }
        .task(id: previewIdentity) {
            updatingPreview = true
            do {
                try await Task.sleep(for: .milliseconds(150))
                let config = erp, currentSeed = seed
                let worker = Task.detached(priority: .userInitiated) {
                    try ERPStudioPreview.build(erp: config, seed: currentSeed)
                }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                preview = result
                previewError = nil
                updatingPreview = false
            } catch is CancellationError {
                // A newer edit owns the loading indicator and result.
            } catch {
                guard !Task.isCancelled else { return }
                preview = nil
                previewError = error.localizedDescription
                updatingPreview = false
            }
        }
    }

    private var conditionControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    heading("Conditions", ERPStudioHelp.conditions)
                    Spacer()
                    Button("Add condition", systemImage: "plus") { addCondition(duplicate: false) }
                    Button("Duplicate") { addCondition(duplicate: true) }
                    Button("Remove", role: .destructive) { removeCondition() }.disabled(design.conditions.count <= 1)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155))], alignment: .leading, spacing: 6) {
                    ForEach(Array(design.conditions.enumerated()), id: \.element.id) { index, item in
                        Button {
                            conditionID = item.id
                            peakID = item.peaks.first?.id ?? ""
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name.isEmpty ? "Unnamed condition" : item.name).lineLimit(1)
                                Text("\(item.fraction * 100, specifier: "%.1f")% · \(allocations[index]) trials")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(7)
                            .background(condition.id == item.id ? Color.accentColor.opacity(0.15) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit \(item.name), \(allocations[index]) trials")
                    }
                }
                HStack(spacing: 14) {
                    HStack { Text("Name"); HelpButton(topic: ERPStudioHelp.conditionName)
                        TextField("Condition name", text: conditionString(\.name)).textFieldStyle(.roundedBorder) }
                    HStack { Text("Code"); HelpButton(topic: ERPStudioHelp.eventCode)
                        TextField("Event code", text: conditionString(\.eventCode)).textFieldStyle(.roundedBorder).frame(width: 65) }
                    number("Trial share", conditionNumber(\.fraction, scale: 100), "%", ERPStudioHelp.share)
                    Button("Normalize shares") { normalize() }.help(ERPStudioHelp.share.summary)
                }
                Text("Total: \(design.conditions.reduce(0) { $0 + $1.fraction } * 100, specifier: "%.1f")% · editing \(condition.name)")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }

    private var waveformEditor: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    heading("\(condition.name) waveform", ERPStudioHelp.waveform)
                    Spacer()
                    Menu("Shape preset") {
                        Button("Single peak") { setShape(1) }
                        Button("Biphasic") { setShape(2) }
                        Button("Three peaks") { setShape(3) }
                    }
                    Button("Add point", systemImage: "plus") { addPeak(time: 0.5, value: -4) }
                }
                HStack(alignment: .top, spacing: 16) {
                    ERPWaveformPlot(condition: condition, selectedPeakID: peak.id,
                                    select: { peakID = $0 }, add: addPeak, move: movePeak)
                        .frame(minHeight: 270)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Picker("Peak", selection: Binding(get: { peak.id }, set: { peakID = $0 })) {
                                ForEach(Array(condition.peaks.enumerated()), id: \.element.id) { i, point in
                                    Text("Peak \(i + 1)").tag(point.id)
                                }
                            }
                            Button(role: .destructive) { removePeak() } label: { Image(systemName: "trash") }
                                .disabled(condition.peaks.count <= 1).help("Delete selected peak")
                        }
                        number("Latency", peakNumber(\.latencySeconds, scale: 1000), "ms", ERPStudioHelp.latency)
                        number("Amplitude", peakNumber(\.amplitudeMicrovolts), "µV", ERPStudioHelp.amplitude)
                        number("Width (σ)", peakNumber(\.widthSeconds, scale: 1000), "ms", ERPStudioHelp.width)
                        number("Present in", peakNumber(\.occurrenceFraction, scale: 100), "%", ERPStudioHelp.occurrence)
                        Text("Of non-omitted trials in this condition.").font(.caption).foregroundStyle(.secondary)
                        Text("Gaussian peaks · shared ERP source\nPositive voltage plotted upward")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(width: 255)
                }
                Text("Double-click to add a point. Drag ↔ latency · ↕ amplitude. Dashed line: selected component.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(6)
        }
    }

    private var variabilityControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                heading("Response variability", ERPStudioHelp.jitter)
                number("Latency SD", erpNumber(\.latencyJitterSDSeconds, scale: 1000), "ms", ERPStudioHelp.jitter)
                number("Amplitude SD", erpNumber(\.amplitudeJitterFraction, scale: 100), "%", ERPStudioHelp.amplitudeJitter)
                number("Peak jitter SD", designNumber(\.independentLatencyJitterSDSeconds, scale: 1000), "ms", ERPStudioHelp.independent)
                number("Width SD", designNumber(\.widthJitterFraction, scale: 100), "%", ERPStudioHelp.widthVariation)
            }.padding(4)
        }.frame(maxWidth: .infinity, alignment: .top)
    }

    private var noiseControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                heading("Noise & omissions", ERPStudioHelp.noise)
                number("Noise RMS", designNumber(\.addedNoiseRMSMicrovolts), "µV", ERPStudioHelp.noise)
                HStack {
                    Picker("Noise model", selection: Binding(get: { design.addedNoiseKind }, set: { value in
                        editDesign { $0.addedNoiseKind = value }
                    })) {
                        Text("White").tag(ERPAddedNoiseKind.white)
                        Text("Smoothed").tag(ERPAddedNoiseKind.smoothed)
                    }
                    HelpButton(topic: ERPStudioHelp.noise)
                }
                number("Omitted", erpNumber(\.omissionRate, scale: 100), "%", ERPStudioHelp.omissions)
                Text("Omissions retain events and noise. Applies within every condition.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(4)
        }.frame(maxWidth: .infinity, alignment: .top)
    }

    private var scheduleControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                heading("Trial schedule", ERPStudioHelp.trials)
                HStack {
                    Text("Trials"); HelpButton(topic: ERPStudioHelp.trials); Spacer()
                    TextField("Trials", value: $erp.trialCount, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 70)
                }
                number("First stimulus", erpNumber(\.startSeconds), "s", ERPStudioHelp.start)
                number("Mean ISI", erpNumber(\.interStimulusIntervalSeconds), "s", ERPStudioHelp.isi)
                number("ISI range ±", erpNumber(\.interStimulusJitterSeconds), "s", ERPStudioHelp.isi)
                HStack {
                    Button("Fit recording") {
                        if let required = preview?.requiredDuration { recordingDuration = max(recordingDuration, ceil(required + 1)) }
                    }.disabled(preview == nil || updatingPreview)
                    HelpButton(topic: ERPStudioHelp.duration)
                }
                if let preview {
                    Text("Needs >\(preview.requiredDuration + 1 / max(1, samplingRate), specifier: "%.2f") s · recording \(recordingDuration, specifier: "%.1f") s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(preview.requiredDuration + 1 / max(1, samplingRate) >= recordingDuration ? Color.orange : Color.secondary)
                }
            }.padding(4)
        }.frame(maxWidth: .infinity, alignment: .top)
    }

    private var recipeControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                heading("Trial recipes · \(condition.name)", ERPStudioHelp.recipes)
                HStack(spacing: 16) {
                    Text("Typical \(max(0, condition.recipes.typicalFraction) * 100, specifier: "%.1f")%")
                        .font(.callout.monospacedDigit())
                    number("Attenuated", recipeNumber(\.attenuatedFraction, scale: 100), "%", ERPStudioHelp.recipes)
                    number("Inverted", recipeNumber(\.invertedFraction, scale: 100), "%", ERPStudioHelp.recipes)
                    number("Divergent", recipeNumber(\.divergentFraction, scale: 100), "%", ERPStudioHelp.recipes)
                }
                Text("One recipe per non-omitted trial; Typical fills the remainder. Recipes set generation truth, not measured TrialsView labels.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Recipe parameters") {
                    HStack(alignment: .top, spacing: 16) {
                        number("Attenuated gain", recipeNumber(\.attenuatedGain), "×", ERPStudioHelp.attenuation)
                        number("Extra shift ±", recipeNumber(\.divergentLatencyRangeSeconds, scale: 1000), "ms", ERPStudioHelp.divergence)
                        number("Width min", recipeNumber(\.divergentWidthMinimum), "×", ERPStudioHelp.divergence)
                        number("Width max", recipeNumber(\.divergentWidthMaximum), "×", ERPStudioHelp.divergence)
                    }.padding(.top, 8)
                }
            }.padding(6)
        }
    }

    private var previewControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    heading("Trial preview", ERPStudioHelp.preview)
                    if updatingPreview { ProgressView().controlSize(.small) }
                    Spacer()
                    Toggle("Show other conditions", isOn: $showOtherConditions).toggleStyle(.checkbox)
                        .help("Compare all conditions on the same time and voltage scales")
                    HelpButton(topic: ERPStudioHelp.preview)
                }
                if let previewError {
                    Label(previewError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .accessibilityLabel("Invalid ERP settings: \(previewError)")
                }
                if let preview {
                    LazyVGrid(columns: showOtherConditions ? [GridItem(.adaptive(minimum: 330))] : [GridItem(.flexible())],
                              alignment: .leading, spacing: 14) {
                        ForEach(preview.conditions.filter { showOtherConditions || $0.id == condition.id }) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.name).font(.callout.weight(.semibold))
                                    if item.id == condition.id { Text("Editing").font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    Text("\(item.count) trials · \(item.omitted) omitted").font(.caption.monospacedDigit())
                                }
                                ERPPreviewPlot(item: item, end: preview.endSeconds, extent: preview.extent)
                                    .frame(height: 190)
                                Text(item.recipeSummary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.opacity(updatingPreview ? 0.5 : 1)
                    Text("Solid: all-trial mean · dashed: template · faint: up to 12 trials · shared axes · seed \(seed)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("ERP + added noise only; excludes other artifacts, background EEG, projection, and neighboring-response overlap.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6)
        }
    }

    private func heading(_ label: String, _ topic: HelpTopic) -> some View {
        HStack(spacing: 5) { Text(label).font(.callout.weight(.semibold)); HelpButton(topic: topic) }
    }
    private func number(_ label: String, _ value: Binding<Double>, _ unit: String, _ topic: HelpTopic) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption); HelpButton(topic: topic); Spacer(minLength: 2)
            TextField(label, value: value, format: .number.precision(.fractionLength(0...3)).grouping(.never))
                .textFieldStyle(.roundedBorder).frame(width: 62).accessibilityLabel("\(label), \(unit)")
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func editDesign(_ edit: (inout ERPExperimentConfig) -> Void) {
        var value = design; edit(&value); erp.experiment = value
    }
    private func editCondition(_ edit: (inout ERPConditionConfig) -> Void) {
        let id = condition.id
        editDesign { value in
            if let i = value.conditions.firstIndex(where: { $0.id == id }) { edit(&value.conditions[i]) }
        }
    }
    private func erpNumber(_ key: WritableKeyPath<ERPConfig, Double>, scale: Double = 1) -> Binding<Double> {
        Binding(get: { erp[keyPath: key] * scale }, set: { erp[keyPath: key] = $0 / scale })
    }
    private func designNumber(_ key: WritableKeyPath<ERPExperimentConfig, Double>, scale: Double = 1) -> Binding<Double> {
        Binding(get: { design[keyPath: key] * scale }, set: { new in editDesign { $0[keyPath: key] = new / scale } })
    }
    private func conditionString(_ key: WritableKeyPath<ERPConditionConfig, String>) -> Binding<String> {
        Binding(get: { condition[keyPath: key] }, set: { new in editCondition { $0[keyPath: key] = new } })
    }
    private func conditionNumber(_ key: WritableKeyPath<ERPConditionConfig, Double>, scale: Double = 1) -> Binding<Double> {
        Binding(get: { condition[keyPath: key] * scale }, set: { new in editCondition { $0[keyPath: key] = new / scale } })
    }
    private func recipeNumber(_ key: WritableKeyPath<ERPTrialRecipeMix, Double>, scale: Double = 1) -> Binding<Double> {
        Binding(get: { condition.recipes[keyPath: key] * scale }, set: { new in editCondition { $0.recipes[keyPath: key] = new / scale } })
    }
    private func peakNumber(_ key: WritableKeyPath<ERPWaveformPeak, Double>, scale: Double = 1) -> Binding<Double> {
        Binding(get: { peak[keyPath: key] * scale }, set: { new in
            let id = peak.id
            editCondition { if let i = $0.peaks.firstIndex(where: { $0.id == id }) { $0.peaks[i][keyPath: key] = new / scale } }
        })
    }
    private func normalize() {
        editDesign { value in
            let weights = value.conditions.map { $0.fraction.isFinite ? max(0, $0.fraction) : 0 }
            let sum = weights.reduce(0, +)
            for i in value.conditions.indices { value.conditions[i].fraction = sum > 0 ? weights[i] / sum : 1 / Double(weights.count) }
        }
    }
    private func addCondition(duplicate: Bool) {
        var item = duplicate ? condition : ERPConditionConfig()
        item.id = UUID().uuidString
        var number = design.conditions.count + 1
        while design.conditions.contains(where: { $0.eventCode.lowercased() == String(format: "C%03d", number).lowercased()
            || $0.name.lowercased() == "condition \(number)" }) { number += 1 }
        item.eventCode = String(format: "C%03d", number)
        item.name = "Condition \(number)"
        normalize()
        item.fraction = 0.2
        editDesign { value in
            for i in value.conditions.indices { value.conditions[i].fraction *= 0.8 }
            value.conditions.append(item)
        }
        conditionID = item.id; peakID = item.peaks.first?.id ?? ""
    }
    private func removeCondition() {
        guard design.conditions.count > 1 else { return }
        let id = condition.id
        editDesign { value in
            value.conditions.removeAll { $0.id == id }
            if value.groupReferenceConditionID == id { value.groupReferenceConditionID = nil }
            value.groupContrasts = value.groupContrasts?.filter { $0.weights[id] == nil }
        }
        normalize(); conditionID = design.conditions.first?.id ?? ""
    }
    private func addPeak(time: Double, value: Double) {
        let point = ERPWaveformPeak(latencySeconds: max(0.005, time),
                                    amplitudeMicrovolts: value - condition.value(at: time), widthSeconds: 0.04)
        editCondition { $0.peaks.append(point) }; peakID = point.id
    }
    private func movePeak(id: String, time: Double, value: Double) {
        peakID = id
        editCondition { condition in
            guard let i = condition.peaks.firstIndex(where: { $0.id == id }) else { return }
            let t = max(0.005, time)
            let other = condition.peaks.filter { $0.id != id }.reduce(0) { $0 + $1.value(at: t) }
            condition.peaks[i].latencySeconds = (t * 1000).rounded() / 1000
            condition.peaks[i].amplitudeMicrovolts = ((value - other) * 10).rounded() / 10
        }
    }
    private func removePeak() {
        guard condition.peaks.count > 1 else { return }
        let id = peak.id
        editCondition { $0.peaks.removeAll { $0.id == id } }; peakID = condition.peaks.first?.id ?? ""
    }
    private func setShape(_ count: Int) {
        var points = [ERPWaveformPeak(id: "p1")]
        if count >= 2 { points.append(ERPWaveformPeak(id: "p2", latencySeconds: 0.17, amplitudeMicrovolts: -5, widthSeconds: 0.035)) }
        if count >= 3 { points.append(ERPWaveformPeak(id: "p3", latencySeconds: 0.5, amplitudeMicrovolts: -3, widthSeconds: 0.07)) }
        editCondition { $0.peaks = points }; peakID = "p1"
    }
}

private struct ERPStudioPreview: Sendable {
    struct Condition: Sendable, Identifiable {
        var id: String
        var name: String
        var count: Int
        var omitted: Int
        var recipeSummary: String
        var template: [Double]
        var mean: [Double]
        var examples: [[Double]]
    }
    var conditions: [Condition]
    var endSeconds: Double
    var extent: Double
    var requiredDuration: Double

    nonisolated static func build(erp: ERPConfig, seed: UInt64) throws -> ERPStudioPreview {
        let trials = try ERPExperimentSampler.trials(erp: erp, seed: seed)
        guard let design = erp.experiment else { throw SimulateError.usage("No editable experiment.") }
        let end = max(0.8, trials.map(\.windowSeconds).max() ?? 0,
                      design.conditions.flatMap(\.peaks).map { $0.latencySeconds + 6 * $0.widthSeconds }.max() ?? 0)
        let size = 321, rate = Double(size - 1) / (end + 0.1)
        var extent = 1.0
        var conditions: [Condition] = []
        for (c, condition) in design.conditions.enumerated() {
            try Task.checkCancellation()
            let selected = trials.enumerated().filter { $0.element.conditionIndex == c }
            let template = (0..<size).map { condition.value(at: -0.1 + Double($0) / rate) }
            var mean = [Double](repeating: 0, count: size), examples: [[Double]] = []
            for (index, pair) in selected.enumerated() {
                try Task.checkCancellation()
                let noise = ERPExperimentSampler.noise(count: size, samplingRate: rate,
                    rms: design.addedNoiseRMSMicrovolts, kind: design.addedNoiseKind,
                    seed: ERPExperimentSampler.seed(seed, "preview-noise/\(pair.offset)"))
                let values = (0..<size).map { pair.element.value(at: -0.1 + Double($0) / rate) + noise[$0] }
                for i in values.indices { mean[i] += values[i] / Double(selected.count) }
                if index < 12 { examples.append(values) }
            }
            let recipeSummary = [ERPTrialRecipe.typical, .attenuated, .inverted, .divergent].map { recipe in
                "\(selected.filter { $0.element.recipe == recipe }.count) \(recipe.rawValue)"
            }.joined(separator: " · ")
            for values in [template, mean] + examples { extent = max(extent, values.map(abs).max() ?? 0) }
            conditions.append(Condition(id: condition.id, name: condition.name, count: selected.count,
                omitted: selected.filter { $0.element.recipe == .omitted }.count, recipeSummary: recipeSummary,
                template: template, mean: mean, examples: examples))
        }
        return ERPStudioPreview(conditions: conditions, endSeconds: end, extent: ceil(extent * 1.1),
                                requiredDuration: ERPExperimentSampler.requiredDuration(trials))
    }
}

private struct ERPPlotScale {
    var size: CGSize
    var end: Double
    var extent: Double
    var frame: CGRect { CGRect(x: 42, y: 18, width: max(1, size.width - 54), height: max(1, size.height - 52)) }
    func point(time: Double, value: Double) -> CGPoint {
        CGPoint(x: frame.minX + (time + 0.1) / (end + 0.1) * frame.width,
                y: frame.midY - value / extent * frame.height / 2)
    }
    func values(_ p: CGPoint) -> (Double, Double) {
        ((p.x - frame.minX) / frame.width * (end + 0.1) - 0.1,
         (frame.midY - p.y) / (frame.height / 2) * extent)
    }
    func axes(_ context: GraphicsContext) {
        for value in [-extent, 0, extent] {
            let y = point(time: 0, value: value).y
            var line = Path(); line.move(to: CGPoint(x: frame.minX, y: y)); line.addLine(to: CGPoint(x: frame.maxX, y: y))
            context.stroke(line, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
            context.draw(Text(value.formatted(.number.precision(.fractionLength(0...1)))).font(.system(size: 10)).foregroundStyle(.secondary),
                         at: CGPoint(x: frame.minX - 5, y: y), anchor: .trailing)
        }
        for time in [0, end / 2, end] {
            let x = point(time: time, value: 0).x
            context.draw(Text("\(time * 1000, specifier: "%.0f")").font(.system(size: 10)).foregroundStyle(.secondary),
                         at: CGPoint(x: x, y: frame.maxY + 12), anchor: time == end ? .trailing : .center)
        }
        context.draw(Text("µV").font(.system(size: 10)).foregroundStyle(.secondary), at: CGPoint(x: frame.minX, y: 6), anchor: .leading)
        context.draw(Text("Time from stimulus (ms)").font(.system(size: 10)).foregroundStyle(.secondary),
                     at: CGPoint(x: frame.maxX, y: size.height - 4), anchor: .trailing)
    }
    func line(_ values: [Double], context: GraphicsContext, color: Color, width: Double = 1, dashed: Bool = false) {
        guard values.count > 1, values.allSatisfy(\.isFinite) else { return }
        var path = Path()
        for (i, v) in values.enumerated() {
            let p = point(time: -0.1 + Double(i) / Double(values.count - 1) * (end + 0.1), value: v)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        var clipped = context; clipped.clip(to: Path(frame))
        clipped.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, dash: dashed ? [5, 4] : []))
    }
}

private struct ERPPreviewPlot: View {
    let item: ERPStudioPreview.Condition
    let end: Double
    let extent: Double
    var body: some View {
        Canvas { context, size in
            let scale = ERPPlotScale(size: size, end: end, extent: extent)
            scale.axes(context)
            for example in item.examples { scale.line(example, context: context, color: .secondary.opacity(0.18)) }
            scale.line(item.template, context: context, color: .teal, width: 1.5, dashed: true)
            if item.count > 0 { scale.line(item.mean, context: context, color: .accentColor, width: 2) }
        }
        .accessibilityLabel("\(item.name) ERP preview, \(item.count) trials, \(item.omitted) omitted. Solid average, dashed template.")
    }
}

private struct ERPWaveformPlot: View {
    var condition: ERPConditionConfig
    var selectedPeakID: String
    var select: (String) -> Void
    var add: (Double, Double) -> Void
    var move: (String, Double, Double) -> Void
    private var end: Double {
        max(0.8, condition.peaks.filter { $0.latencySeconds.isFinite && $0.widthSeconds.isFinite }
            .map { $0.latencySeconds + 4 * $0.widthSeconds }.filter(\.isFinite).max() ?? 0)
    }
    private var values: [Double] { (0...320).map { condition.value(at: -0.1 + Double($0) / 320 * (end + 0.1)) } }
    var body: some View {
        GeometryReader { geometry in
            let extent = max(12, (values.filter(\.isFinite).map(abs).max() ?? 8) * 1.2)
            let scale = ERPPlotScale(size: geometry.size, end: end, extent: extent)
            ZStack {
                Canvas { context, _ in
                    scale.axes(context)
                    scale.line(values, context: context, color: .accentColor, width: 2)
                    if let selected = condition.peaks.first(where: { $0.id == selectedPeakID }) {
                        scale.line((0...320).map { selected.value(at: -0.1 + Double($0) / 320 * (end + 0.1)) },
                                   context: context, color: .secondary, dashed: true)
                    }
                    for (i, peak) in condition.peaks.enumerated() where peak.latencySeconds.isFinite && peak.amplitudeMicrovolts.isFinite {
                        let p = scale.point(time: peak.latencySeconds, value: condition.value(at: peak.latencySeconds))
                        let circle = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
                        context.fill(circle, with: .color(Color(nsColor: .controlBackgroundColor)))
                        context.stroke(circle, with: .color(.accentColor), lineWidth: peak.id == selectedPeakID ? 3 : 1.5)
                        context.draw(Text("P\(i + 1)").font(.system(size: 10)).foregroundStyle(.secondary),
                                     at: CGPoint(x: p.x + 10, y: max(26, p.y - 12)), anchor: .leading)
                    }
                }
                ERPPlotInteraction(scale: scale, handles: condition.peaks.map {
                    ($0.id, scale.point(time: $0.latencySeconds, value: condition.value(at: $0.latencySeconds)))
                }, select: select, add: add, move: move)
            }
        }
        .accessibilityLabel("Editable waveform for \(condition.name). Use peak selector and numeric fields for keyboard editing.")
    }
}

private struct ERPPlotInteraction: NSViewRepresentable {
    let scale: ERPPlotScale
    let handles: [(String, CGPoint)]
    let select: (String) -> Void
    let add: (Double, Double) -> Void
    let move: (String, Double, Double) -> Void
    func makeNSView(context: Context) -> ERPPlotMouseView { ERPPlotMouseView() }
    func updateNSView(_ view: ERPPlotMouseView, context: Context) {
        view.scale = scale; view.handles = handles; view.select = select; view.add = add; view.move = move
    }
}

private final class ERPPlotMouseView: NSView {
    var scale = ERPPlotScale(size: .zero, end: 0.8, extent: 12)
    var handles: [(String, CGPoint)] = []
    var select: ((String) -> Void)?
    var add: ((Double, Double) -> Void)?
    var move: ((String, Double, Double) -> Void)?
    private var dragged: String?
    private var dragScale: ERPPlotScale?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard scale.frame.contains(p) else { return }
        if let nearest = handles.min(by: { hypot($0.1.x - p.x, $0.1.y - p.y) < hypot($1.1.x - p.x, $1.1.y - p.y) }),
           hypot(nearest.1.x - p.x, nearest.1.y - p.y) <= 18 {
            dragged = nearest.0; dragScale = scale; select?(nearest.0)
        } else if event.clickCount == 2 {
            let (t, v) = scale.values(p); add?(max(0.005, t), v)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragged, let dragScale else { return }
        let p = convert(event.locationInWindow, from: nil)
        let clamped = CGPoint(x: min(max(p.x, dragScale.frame.minX), dragScale.frame.maxX),
                              y: min(max(p.y, dragScale.frame.minY), dragScale.frame.maxY))
        let (t, v) = dragScale.values(clamped); move?(dragged, max(0.005, t), v)
    }
    override func mouseUp(with event: NSEvent) { dragged = nil; dragScale = nil }
}
