//
//  CombineRecordingsSheet.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Sheet presented when several recordings are dropped at once. Shows a sanity
//  table (categories, trial counts, SNR), lets the user pick Append vs. Grand
//  Average with weighting / bad-channel / re-baseline options, then builds a
//  combined .mff in the temp dir and hands its URL back to open.
//

import SwiftUI

struct CombineRecordingsSheet: View {
    let urls: [URL]
    /// Called with the combined package URL to open (dismisses the sheet).
    let onComplete: (URL) -> Void
    let onCancel: () -> Void

    @State private var inputs: [CombineInput] = []
    @State private var summaries: [RecordingSummary] = []
    @State private var isLoading = true
    @State private var loadError: String?

    @State private var mode = CombineMode.grandAverage
    @State private var weighting = WeightingMode.byInverseVariance
    @State private var badChannelPolicy = BadChannelPolicy.interpolatePerFile
    @State private var rebaseline = false
    @State private var showAllSNR = false
    @State private var comparePSAArtifactThresholds = false
    /// Per-file canonical category mapping (rawName → canonicalName), editable.
    @State private var categoryMap: [URL: [String: String]] = [:]

    @State private var isBuilding = false
    @State private var buildStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if isLoading {
                ProgressView("Reading \(urls.count) recordings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
            } else if let loadError {
                ContentUnavailableView("Couldn't read files", systemImage: "exclamationmark.triangle", description: Text(loadError))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sanityTable
                        Divider()
                        options
                        if mode == .grandAverage {
                            Divider()
                            categoryMappingSection
                        }
                    }
                    .padding(20)
                }
            }
            Divider()
            footer
        }
        .frame(width: comparePSAArtifactThresholds ? 940 : 780, height: 620)
        .task { await load() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Combine \(urls.count) Recordings")
                .font(.title3.weight(.semibold))
            Text("Pool trials from one subject's runs by appending them, or grand-average each category across files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var sanityTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Files")
                .font(.caption.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("File").gridColumnAlignment(.leading)
                    Text("Ch"); Text("Hz"); Text("Categories"); Text("Trials")
                    Text("±SNR"); Text("Base SNR")
                    if showAllSNR { Text("SME"); Text("Split½"); Text("GFP") }
                    if comparePSAArtifactThresholds { Text("PSA thresholds") }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(summaries) { s in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                if s.hasProcessingRecord {
                                    Image(systemName: "wand.and.stars")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                        .help("Preprocessed — carries an eva.xml processing record.")
                                }
                                Text(s.fileName).lineLimit(1)
                            }
                            if !s.isCompatible {
                                Text(s.compatibility.map(\.message).joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text("\(s.channelCount)")
                        Text("\(Int(s.samplingRate))")
                        Text("\(s.categories.count)")
                        Group {
                            if s.hasRejectionInfo {
                                Text("\(s.totalGoodTrials)/\(s.totalTrials)")
                                    .help(rejectionTooltip(s))
                            } else {
                                Text("\(s.totalGoodTrials)")
                            }
                        }
                        Text(fmt(s.snr.plusMinusSNR))
                        Text(fmt(s.snr.baselineSNR))
                        if showAllSNR {
                            Text(fmt(s.snr.standardizedMeasurementError, digits: 3))
                            Text(fmt(s.snr.splitHalfReliability))
                            Text(fmt(s.snr.gfpSNR))
                        }
                        if comparePSAArtifactThresholds {
                            psaThresholdStatus(for: s)
                        }
                    }
                    .font(.caption.monospacedDigit())
                }
            }
            HStack(spacing: 12) {
                Toggle("Show all SNR metrics", isOn: $showAllSNR)
                    .font(.caption)
                Toggle("Compare PSA artifact thresholds", isOn: $comparePSAArtifactThresholds)
                    .font(.caption)
                    .help("Compare the saved per-epoch bad-channel interpolation and reject-epoch thresholds in each file's eva.xml.")
                if summaries.contains(where: \.hasProcessingRecord) {
                    Label("preprocessed (has eva.xml)", systemImage: "wand.and.stars")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
            if comparePSAArtifactThresholds {
                psaThresholdComparison
            }
        }
    }

    private var referencePSAThresholds: PSAArtifactThresholdSnapshot? {
        summaries.first?.psaArtifactThresholds
    }

    @ViewBuilder
    private func psaThresholdStatus(for summary: RecordingSummary) -> some View {
        if summary.id == summaries.first?.id {
            if let thresholds = summary.psaArtifactThresholds, thresholds.isComplete {
                Label("Reference", systemImage: "flag.fill")
                    .foregroundStyle(.secondary)
                    .help(thresholds.detail)
            } else {
                Label("Unavailable", systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
                    .help(summary.psaArtifactThresholds?.detail ?? "No PSA artifact thresholds were recorded in eva.xml.")
            }
        } else if let reference = referencePSAThresholds,
                  reference.isComplete,
                  let thresholds = summary.psaArtifactThresholds,
                  thresholds.isComplete {
            let differences = thresholds.differingFields(from: reference)
            if differences.isEmpty {
                Label("Match", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help(thresholds.detail)
            } else {
                Label("Differs", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Different from the first file: \(differences.joined(separator: ", ")).\n\(thresholds.detail)")
            }
        } else {
            Label("Unavailable", systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
                .help(summary.psaArtifactThresholds?.detail ?? "No PSA artifact thresholds were recorded in eva.xml.")
        }
    }

    private var psaThresholdComparison: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let reference = referencePSAThresholds, reference.isComplete {
                Label(psaThresholdsAllMatch ? "PSA artifact thresholds match across all files" : "PSA artifact thresholds are not consistent across all files", systemImage: psaThresholdsAllMatch ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(psaThresholdsAllMatch ? .green : .orange)
                    .font(.caption.weight(.semibold))
                Text("Reference — \(summaries.first?.fileName ?? "first file"): \(reference.detail)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(summaries.dropFirst())) { summary in
                    if let thresholds = summary.psaArtifactThresholds, thresholds.isComplete {
                        let differences = thresholds.differingFields(from: reference)
                        if !differences.isEmpty {
                            Text("\(summary.fileName): differs in \(differences.joined(separator: ", ")) — \(thresholds.detail)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("\(summary.fileName): \(summary.psaArtifactThresholds?.detail ?? "PSA artifact thresholds not recorded")")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Label("Cannot compare PSA artifact thresholds: the first file has no complete saved PSA threshold record.", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background((psaThresholdsAllMatch ? Color.green : Color.orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.top, 4)
    }

    private var psaThresholdsAllMatch: Bool {
        guard let reference = referencePSAThresholds, reference.isComplete else { return false }
        return summaries.allSatisfy { summary in
            guard let thresholds = summary.psaArtifactThresholds, thresholds.isComplete else { return false }
            return thresholds.differingFields(from: reference).isEmpty
        }
    }

    @ViewBuilder
    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Mode", selection: $mode) {
                ForEach(CombineMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(mode.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if mode == .grandAverage, mixedPreprocessing {
                Label("Mixing preprocessed and unprocessed files — they may have had different filtering / referencing applied, which can bias the grand average. Consider matching processing first.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }

            if mode == .grandAverage {
                labeledPicker("Weighting", selection: $weighting, options: WeightingMode.allCases) { $0.label }
                Text(weighting.detail).font(.caption2).foregroundStyle(.secondary)

                labeledPicker("Bad channels", selection: $badChannelPolicy, options: BadChannelPolicy.allCases) { $0.label }
                Text(badChannelPolicy.detail).font(.caption2).foregroundStyle(.secondary)

                Toggle("Re-baseline epochs to the pre-stimulus window before averaging", isOn: $rebaseline)
                    .font(.caption)
            }
        }
    }

    /// True when the dropped set mixes preprocessed (eva.xml) and raw files.
    private var mixedPreprocessing: Bool {
        let processed = summaries.contains(where: \.hasProcessingRecord)
        let raw = summaries.contains(where: { !$0.hasProcessingRecord })
        return processed && raw
    }

    /// Distinct canonical category names currently assigned across all files.
    private var canonicalNames: [String] {
        Array(Set(categoryMap.values.flatMap { $0.values })).sorted()
    }

    private var categoryMappingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Category Mapping")
                .font(.caption.weight(.semibold))
            Text("Raw category names are auto-matched across files. Edit a canonical name to merge or split categories in the grand average.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("File").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Raw").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text("→ Canonical").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                ForEach(summaries) { s in
                    let raws = (categoryMap[s.url] ?? [:]).keys.sorted()
                    ForEach(raws, id: \.self) { raw in
                        GridRow {
                            Text(s.fileName).font(.caption2).lineLimit(1)
                            Text(raw).font(.caption2.monospaced())
                            TextField("canonical", text: canonicalBinding(url: s.url, raw: raw))
                                .textFieldStyle(.roundedBorder)
                                .font(.caption2)
                                .frame(width: 160)
                        }
                    }
                }
            }
        }
    }

    private func canonicalBinding(url: URL, raw: String) -> Binding<String> {
        Binding(
            get: { categoryMap[url]?[raw] ?? raw },
            set: { categoryMap[url, default: [:]][raw] = $0 }
        )
    }

    private var footer: some View {
        HStack {
            if let buildStatus {
                Text(buildStatus).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isBuilding { ProgressView().controlSize(.small) }
            Button("Cancel", role: .cancel) { onCancel() }
            Button(mode == .append ? "Append & Open" : "Grand Average & Open") {
                Task { await build() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isBuilding || summaries.count < 2)
        }
        .padding(20)
    }

    // MARK: - Load & build

    private func load() async {
        isLoading = true
        let urls = self.urls
        let loaded: (inputs: [CombineInput], summaries: [RecordingSummary], map: [URL: [String: String]])? =
            await Task.detached(priority: .userInitiated) {
                var inputs: [CombineInput] = []
                for url in urls {
                    guard let imported = try? SignalImportReader.load(from: url) else { continue }
                    inputs.append(CombineInput(
                        url: url,
                        signal: imported.signal,
                        segments: imported.signal.epochSegments,
                        badChannels: [],
                        geometry: imported.geometry
                    ))
                }
                guard !inputs.isEmpty else { return nil }
                var summaries = inputs.map { RecordingCombiner.summarize($0) }
                if let reference = summaries.first {
                    for i in summaries.indices {
                        summaries[i].compatibility = RecordingCombiner.compatibility(of: summaries[i], reference: reference)
                    }
                }
                // Fuzzy auto-map category names across files (user-editable).
                var rawByFile: [URL: [String]] = [:]
                for input in inputs {
                    rawByFile[input.url] = Array(Set(input.segments.map(\.category))).sorted()
                }
                let map = CategoryMatcher.autoMap(rawCategoriesByFile: rawByFile).map
                return (inputs, summaries, map)
            }.value

        if let loaded {
            self.inputs = loaded.inputs
            self.summaries = loaded.summaries
            self.categoryMap = loaded.map
        } else {
            self.loadError = "None of the dropped files could be read as segmented/averaged recordings."
        }
        isLoading = false
    }

    private func build() async {
        isBuilding = true
        buildStatus = "Building…"
        let inputs = self.inputs
        let mode = self.mode
        let weighting = self.weighting
        let policy = self.badChannelPolicy
        let rebaseline = self.rebaseline
        let map = self.categoryMap
        let summaries = self.summaries

        let result: URL? = await Task.detached(priority: .userInitiated) {
            let log = EVAProcessLog(header: "EVA combine — \(inputs.count) files")
            var script = EVAProcessingScript()

            let signal: MFFSignalData
            let segments: [EpochSegment]
            let kind: MFFExportKind
            var noiseByCategory: [String: [Float]] = [:]
            var weightByFile: [URL: Double] = [:]

            switch mode {
            case .append:
                let out = RecordingCombiner.append(inputs, log: log)
                signal = out.signal; segments = out.segments; kind = .epoched
                script.append(EVAProcessingStep(operation: .combine, parameters: ["mode": "append", "files": "\(inputs.count)"]))
            case .grandAverage:
                guard let out = RecordingCombiner.grandAverage(
                    inputs, categoryMap: map, weighting: weighting,
                    badChannelPolicy: policy, rebaseline: rebaseline, log: log
                ) else { return nil }
                signal = out.signal; segments = out.segments; kind = .averaged
                noiseByCategory = out.noiseByCategory
                weightByFile = out.weightByFile
                if rebaseline {
                    script.append(EVAProcessingStep(operation: .baseline, parameters: ["window": "pre-stimulus"]))
                }
                // Aggregate per-canonical-category total/included/reasons across
                // files so the combined package's eva.xml carries it forward.
                var agg: [String: CategoryRejection] = [:]
                for s in summaries {
                    let fileMap = map[s.url] ?? [:]
                    for cat in s.categories {
                        let canonical = fileMap[cat.name] ?? cat.name
                        var r = agg[canonical] ?? CategoryRejection(category: canonical, total: 0, included: 0)
                        r.total += cat.totalTrials
                        r.included += cat.goodTrials
                        for (reason, n) in cat.exclusionReasons { r.reasons[reason, default: 0] += n }
                        agg[canonical] = r
                    }
                }
                script.append(EVAProcessingStep(
                    operation: .average,
                    parameters: ["files": "\(inputs.count)"],
                    rejections: agg.values.sorted { $0.category < $1.category }
                ))
                script.append(EVAProcessingStep(operation: .combine, parameters: [
                    "mode": "grandAverage", "weighting": weighting.rawValue,
                    "badChannels": policy.rawValue, "rebaselined": "\(rebaseline)",
                    "files": "\(inputs.count)"
                ]))
            }

            // Look up each file's summary (for trial counts + SNR) by URL.
            let summaryByURL = Dictionary(uniqueKeysWithValues: summaries.map { ($0.url, $0) })
            let provenance = CombineProvenance(
                createdAt: Date(),
                mode: mode.rawValue,
                weighting: weighting.rawValue,
                badChannelPolicy: policy.rawValue,
                rebaselined: rebaseline,
                contributors: inputs.map { input in
                    let s = summaryByURL[input.url]
                    return CombineProvenance.Contributor(
                        fileName: input.url.lastPathComponent,
                        goodTrials: s?.totalGoodTrials ?? 0,
                        totalTrials: s?.totalTrials ?? s?.totalGoodTrials ?? 0,
                        weightApplied: weightByFile[input.url] ?? 0,
                        plusMinusSNR: s?.snr.plusMinusSNR,
                        baselineSNR: s?.snr.baselineSNR
                    )
                }
            )
            provenance.logLines().forEach { log.append($0) }

            return try? RecordingCombiner.writeTempPackage(
                signal: signal, segments: segments, kind: kind,
                script: script, log: log, noiseByCategory: noiseByCategory, baseName: "combined"
            )
        }.value

        isBuilding = false
        if let result {
            onComplete(result)
        } else {
            buildStatus = "Combine failed — check that files share categories and epoch structure."
        }
    }

    // MARK: - Small helpers

    private func labeledPicker<T: Hashable & Identifiable>(
        _ label: String, selection: Binding<T>, options: [T], title: @escaping (T) -> String
    ) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 100, alignment: .leading)
            Picker(label, selection: selection) {
                ForEach(options) { Text(title($0)).tag($0) }
            }
            .labelsHidden()
        }
    }

    /// "included/total" cell tooltip: excluded count + reasons from eva.xml.
    private func rejectionTooltip(_ s: RecordingSummary) -> String {
        let excluded = s.totalTrials - s.totalGoodTrials
        var lines = ["\(s.totalGoodTrials) included of \(s.totalTrials) (\(excluded) excluded)"]
        for (reason, n) in s.exclusionReasons.sorted(by: { $0.value > $1.value }) {
            lines.append("  \(reason): \(n)")
        }
        return lines.joined(separator: "\n")
    }

    private func fmt(_ value: Double?, digits: Int = 2) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(digits)f", value)
    }
}
