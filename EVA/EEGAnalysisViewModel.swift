//
//  EEGAnalysisViewModel.swift
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
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//

import Combine
import Foundation

@MainActor
final class EEGAnalysisViewModel: ObservableObject {
    @Published var showsSheet = false

    @Published var segmentLengthSeconds = 4.0
    @Published var keepsGoodSegments = true
    @Published var keepsWatchSegments = true
    @Published var keepsPoorSegments = false
    @Published var artifactRejectionThreshold = 0.10
    @Published var selectedArtifactSourceIDs = Set<String>()

    @Published var frequencyBands = EEGFrequencyBand.restingDefaults
    @Published var selectedConnectivityBandName = "Alpha"
    @Published var selectedConnectivityMetrics = EEGConnectivityMetric.allCases
    @Published var includesChannelConnectivity = true
    @Published var includesRegionConnectivity = true

    @Published var exportIncludesPerChannelDetails = true
    @Published var exportIncludesSegmentDetails = false
    @Published var exportIncludesConnectivityPairs = true

    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var statusMessage: String?
    @Published var result: EEGAnalysisResult?

    private var task: Task<Void, Never>?
    private var hasInitializedArtifactSources = false

    deinit {
        task?.cancel()
    }

    var keptGrades: [ChannelHealthGrade] {
        var grades: [ChannelHealthGrade] = []
        if keepsGoodSegments { grades.append(.good) }
        if keepsWatchSegments { grades.append(.watch) }
        if keepsPoorSegments { grades.append(.poor) }
        return grades
    }

    var selectedConnectivityBand: EEGFrequencyBand {
        frequencyBands.first { $0.name == selectedConnectivityBandName } ?? frequencyBands.first ?? EEGFrequencyBand(name: "Alpha", lowHz: 8, highHz: 13)
    }

    var exportOptions: EEGAnalysisExportOptions {
        EEGAnalysisExportOptions(
            includesPerChannelDetails: exportIncludesPerChannelDetails,
            includesSegmentDetails: exportIncludesSegmentDetails,
            includesConnectivityPairs: exportIncludesConnectivityPairs
        )
    }

    func syncArtifactSources(_ sources: [EEGArtifactRejectionSource]) {
        let knownIDs = Set(sources.map(\.id))
        if !hasInitializedArtifactSources, !knownIDs.isEmpty {
            selectedArtifactSourceIDs = knownIDs
            hasInitializedArtifactSources = true
            return
        }
        selectedArtifactSourceIDs.formIntersection(knownIDs)
    }

    func toggleConnectivityMetric(_ metric: EEGConnectivityMetric, isSelected: Bool) {
        if isSelected {
            if !selectedConnectivityMetrics.contains(metric) {
                selectedConnectivityMetrics.append(metric)
            }
        } else {
            selectedConnectivityMetrics.removeAll { $0 == metric }
        }
    }

    func run(
        packageName: String,
        signal: MFFSignalData,
        processing: EEGAnalysisProcessingSnapshot,
        artifactSources: [EEGArtifactRejectionSource],
        excludedChannelIndices: Set<Int>,
        channelSets: [ChannelSet]
    ) {
        guard !isRunning else { return }
        guard !keptGrades.isEmpty else {
            statusMessage = "Choose at least one segment health grade to keep."
            return
        }
        guard !selectedConnectivityMetrics.isEmpty else {
            statusMessage = "Choose at least one connectivity metric."
            return
        }

        task?.cancel()
        isRunning = true
        progress = 0
        statusMessage = "Running EEG analysis..."

        let request = EEGAnalysisRequest(
            packageName: packageName,
            signal: signal,
            processing: processing,
            segmentLengthSeconds: segmentLengthSeconds,
            keptGrades: keptGrades,
            artifactRejectionThreshold: artifactRejectionThreshold,
            artifactSources: artifactSources,
            selectedArtifactSourceIDs: selectedArtifactSourceIDs,
            excludedChannelIndices: excludedChannelIndices,
            frequencyBands: frequencyBands,
            connectivityBand: selectedConnectivityBand,
            connectivityMetrics: selectedConnectivityMetrics,
            channelSets: channelSets,
            includesChannelConnectivity: includesChannelConnectivity,
            includesRegionConnectivity: includesRegionConnectivity
        )

        let (progressContinuation, progressTask) = ProgressBridge.make { [weak self] fraction in
            self?.progress = min(max(fraction, 0), 1)
        }

        task = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                await EEGAnalysisEngine.analyze(
                    request: request,
                    progress: { fraction in
                        progressContinuation.yield(fraction)
                    }
                )
            }

            let output = await withTaskCancellationHandler(
                operation: {
                    await worker.value
                },
                onCancel: {
                    worker.cancel()
                    progressContinuation.finish()
                }
            )

            progressContinuation.finish()
            progressTask.cancel()

            guard !Task.isCancelled else { return }
            result = output
            isRunning = false
            progress = 1
            statusMessage = "EEG analysis complete: \(output.segments.includedSegmentCount)/\(output.segments.totalSegmentCount) segments kept."
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        progress = 0
        statusMessage = "EEG analysis cancelled."
    }

    func jsonData() throws -> Data {
        guard let result else { return Data() }
        let export = EEGAnalysisEngine.exportResult(result, options: exportOptions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    func csvData() -> Data {
        guard let result else { return Data() }
        let rows = EEGAnalysisEngine.csvRows(for: result, options: exportOptions)
        let text = rows.map { row in
            row.map(Self.csvEscape).joined(separator: ",")
        }
        .joined(separator: "\n") + "\n"
        return Data(text.utf8)
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
