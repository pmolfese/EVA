//
//  WICAViewModel.swift
//  EVA
//
//  Experimental review state for wavelet-enhanced ICA. The fitted operator,
//  ICLabel evidence, manual component choices, and output remain together so a
//  user can inspect the decision before enabling the result.
//

import Foundation
import SwiftUI

nonisolated enum WICASelectionMode: String, CaseIterable, Identifiable, Sendable {
    case all = "All components"
    case selected = "Selected components"

    var id: String { rawValue }
}

@MainActor
@Observable
final class WICAViewModel {
    var showsSheet = false
    var isAnalyzing = false
    var isApplying = false
    var isEnabled = true
    var progress = 0.0
    var progressMessage = "Ready"
    var statusMessage: String?

    var method: ICAMethod = .picard
    var usesAutomaticComponentCount = true
    var componentCount = 20
    var downsampleRate = 100.0
    var maxIterations = 200
    var varianceThreshold = 0.999
    var thresholdScale = 1.0
    var selectionMode: WICASelectionMode = .all
    var selectedComponents: Set<Int> = []
    var coreCount = WaveletReducer.defaultCoreCount
    var usesMetal = ProcessingDefaults.shared.waveletUsesGPU && WaveletMetalBackend.isAvailable

    var decomposition: ICADecomposition?
    var decompositionInputRevision: UUID?
    var result: WICAResult?
    var cleanedSignal: MFFSignalData?
    var artifact: MFFSignalData?
    var outputInputRevision: UUID?
    var task: Task<Void, Never>?

    var effectiveComponents: Set<Int> {
        guard let decomposition else { return [] }
        switch selectionMode {
        case .all: return Set(0..<decomposition.componentCount)
        case .selected: return selectedComponents
        }
    }

    func open(for signal: MFFSignalData) {
        if usesAutomaticComponentCount {
            componentCount = Self.recommendedComponentCount(channelCount: signal.numberOfChannels)
        } else {
            componentCount = min(max(componentCount, 1), signal.numberOfChannels)
        }
        downsampleRate = min(max(downsampleRate, 20), signal.samplingRate)
        statusMessage = nil
        showsSheet = true
    }

    func setAutomaticComponentCount(_ enabled: Bool, for signal: MFFSignalData) {
        usesAutomaticComponentCount = enabled
        if enabled {
            componentCount = Self.recommendedComponentCount(channelCount: signal.numberOfChannels)
        }
    }

    func analyze(signal: MFFSignalData, layout: SensorLayout?) {
        task?.cancel()
        isAnalyzing = true
        progress = 0
        progressMessage = "Preparing \(method.displayName) ICA"
        statusMessage = "Fitting \(method.displayName) ICA…"
        let method = self.method
        let configuration = ICAConfiguration(
            method: method,
            componentCount: min(max(componentCount, 1), signal.numberOfChannels),
            varianceThreshold: min(max(varianceThreshold, 0.01), 1),
            averageReference: true,
            downsampleRate: min(max(downsampleRate, 20), signal.samplingRate),
            maxIterations: max(maxIterations, 1),
            learningRate: nil,
            fitFilter: nil,
            convergenceTolerance: 1e-7,
            minimumIterations: 1
        )
        let (progressContinuation, progressTask) = ProgressBridge.make {
            [weak self] (update: ICAProgressUpdate) in
            self?.progress = min(max(update.fraction, 0), 1)
            self?.progressMessage = update.message
        }
        task = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try ICAArtifactDetector.fit(
                        signal: signal,
                        configuration: configuration,
                        progress: { fraction in
                            progressContinuation.yield(ICAProgressUpdate(
                                fraction: fraction,
                                message: Self.icaProgressMessage(
                                    fraction: fraction, method: method
                                )
                            ))
                        }
                    )
                }
                let decomposition = try await withTaskCancellationHandler(
                    operation: { try await worker.value },
                    onCancel: {
                        worker.cancel()
                        progressContinuation.finish()
                    }
                )
                progressContinuation.finish()
                progressTask.cancel()
                try Task.checkCancellation()
                self.progress = 0.97
                self.progressMessage = "Classifying components with ICLabel"
                var labeled = decomposition
                let suggestions = ICAComponentAutoLabeler.suggestions(
                    for: decomposition, layout: layout
                )
                labeled.labelSuggestions = suggestions
                labeled.labels = suggestions.mapValues(\.label)
                self.decomposition = labeled
                self.decompositionInputRevision = signal.dataRevision
                self.selectedComponents = Set(suggestions.compactMap { component, suggestion in
                    Self.isArtifactSuggestion(suggestion.label) ? component : nil
                })
                self.progress = 1
                self.progressMessage = "ICA and component labeling complete"
                self.statusMessage = self.selectedComponents.isEmpty
                    ? "ICA complete. ICLabel found no artifact components; review the rows or use all components."
                    : "ICA complete. ICLabel preselected \(self.selectedComponents.count) possible artifact components; review before applying."
            } catch is CancellationError {
                progressContinuation.finish()
                progressTask.cancel()
                return
            } catch {
                progressContinuation.finish()
                progressTask.cancel()
                self.progressMessage = "ICA failed"
                self.statusMessage = error.localizedDescription
            }
            self.isAnalyzing = false
            self.task = nil
        }
    }

    func apply(signal: MFFSignalData) {
        guard let decomposition else {
            statusMessage = "Run ICA before applying W-ICA."
            return
        }
        guard decompositionInputRevision == signal.dataRevision else {
            statusMessage = "The W-ICA input changed. Run ICA again before applying."
            return
        }
        let components = effectiveComponents
        guard !components.isEmpty else {
            statusMessage = "Select at least one component."
            return
        }
        task?.cancel()
        isApplying = true
        progress = 0
        progressMessage = "Preparing component wavelets"
        statusMessage = "Thresholding \(components.count) component\(components.count == 1 ? "" : "s")…"
        var wavelet = WaveletReductionMode.continuousEEG.defaultConfiguration(
            samplingRate: signal.samplingRate
        )
        wavelet.thresholdScale = min(max(thresholdScale, 0.05), 20)
        wavelet.useGPU = usesMetal && WaveletMetalBackend.isAvailable
        let configuration = WICAConfiguration(
            wavelet: wavelet,
            coreCount: coreCount,
            componentBatchSize: 16
        )
        task = Task {
            let (continuation, listener) = ProgressBridge.make { [weak self] value in
                self?.progress = min(max(value, 0), 1)
                self?.progressMessage = String(
                    format: "Thresholding component batches · %.0f%%", value * 100
                )
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try WICAProcessor.reduce(
                        signal: signal,
                        decomposition: decomposition,
                        componentIndices: components,
                        configuration: configuration,
                        progress: { continuation.yield($0) }
                    )
                }.value
                continuation.finish()
                listener.cancel()
                try Task.checkCancellation()
                self.result = result
                self.cleanedSignal = result.cleaned
                self.artifact = result.artifact
                self.outputInputRevision = signal.dataRevision
                self.isEnabled = true
                self.progress = 1
                self.progressMessage = "W-ICA complete"
                self.statusMessage = String(
                    format: "W-ICA applied to %d components · %.1f%% total variance retained",
                    result.processedComponents.count, result.varianceRetainedPercent
                )
            } catch is CancellationError {
                continuation.finish()
                listener.cancel()
                return
            } catch {
                continuation.finish()
                listener.cancel()
                self.statusMessage = error.localizedDescription
            }
            self.isApplying = false
            self.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isAnalyzing = false
        isApplying = false
    }

    func revert() {
        result = nil
        cleanedSignal = nil
        artifact = nil
        outputInputRevision = nil
        isEnabled = false
        statusMessage = "W-ICA result reverted."
    }

    func resetForClose() {
        cancel()
        showsSheet = false
        isEnabled = true
        progress = 0
        progressMessage = "Ready"
        statusMessage = nil
        selectedComponents = []
        decomposition = nil
        decompositionInputRevision = nil
        result = nil
        cleanedSignal = nil
        artifact = nil
        outputInputRevision = nil
    }

    private nonisolated static func isArtifactSuggestion(_ label: String) -> Bool {
        ["Eye", "Muscle", "Heart", "Line Noise", "Channel Noise"]
            .contains { label.hasPrefix($0) }
    }

    /// Average referencing costs one rank. Thirty-two is a practical interactive
    /// ceiling: it avoids the severe under-decomposition of a fixed 20 on common
    /// 32-channel recordings without making a first look at 128/256-channel data
    /// unexpectedly enormous. The manual field remains available for full-rank
    /// validation and difficult high-density recordings.
    private nonisolated static func recommendedComponentCount(channelCount: Int) -> Int {
        min(max(channelCount - 1, 1), 32)
    }

    private nonisolated static func icaProgressMessage(
        fraction: Double,
        method: ICAMethod
    ) -> String {
        switch fraction {
        case ..<0.08: return "Downsampling ICA data"
        case ..<0.16: return "Centering average-referenced channels"
        case ..<0.30: return "Building channel covariance"
        case ..<0.40: return "Solving PCA and selecting retained rank"
        case ..<0.42: return "Whitening retained components"
        case ..<0.88:
            let solver = min(max((fraction - 0.42) / 0.44, 0), 1)
            return String(
                format: "Optimizing %@ unmixing · %.0f%%",
                method.displayName, solver * 100
            )
        case ..<1: return "Back-projecting component maps"
        default: return "ICA decomposition complete"
        }
    }
}
