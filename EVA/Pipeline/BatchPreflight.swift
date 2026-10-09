//
//  BatchPreflight.swift
//  EVA
//
//  Setup-time, sample-free compatibility inspection for Batch Process.
//

import Foundation
import Observation

nonisolated struct BatchPreflightIssue: Identifiable, Sendable, Equatable {
    let stepIndex: Int
    let operation: EVAProcessingStep.Operation
    let flag: ReplayCompatibilityFlag

    var id: Int { stepIndex }
    var stepName: String { ReplayStepDisplay.label(for: operation) }
}

nonisolated struct BatchPreflightResult: Identifiable, Sendable, Equatable {
    let url: URL
    let numberOfChannels: Int?
    let samplingRate: Double?
    let eventCodes: Set<String>
    let hasICAPayload: Bool
    let hasArtifactPayload: Bool
    let hasElectrodeGeometry: Bool
    let issues: [BatchPreflightIssue]
    let inspectionError: String?

    var id: URL { url }
    var hasWarnings: Bool { inspectionError != nil || !issues.isEmpty }
    var payloadAvailability: ReplayPayloadAvailability {
        ReplayPayloadAvailability(
            hasICAPayload: hasICAPayload,
            hasArtifactPayload: hasArtifactPayload,
            hasElectrodeGeometry: hasElectrodeGeometry,
            beatEventCodes: eventCodes
        )
    }

    init(
        url: URL,
        numberOfChannels: Int?,
        samplingRate: Double?,
        eventCodes: Set<String>,
        hasICAPayload: Bool = false,
        hasArtifactPayload: Bool = false,
        hasElectrodeGeometry: Bool = false,
        issues: [BatchPreflightIssue],
        inspectionError: String?
    ) {
        self.url = url
        self.numberOfChannels = numberOfChannels
        self.samplingRate = samplingRate
        self.eventCodes = eventCodes
        self.hasICAPayload = hasICAPayload
        self.hasArtifactPayload = hasArtifactPayload
        self.hasElectrodeGeometry = hasElectrodeGeometry
        self.issues = issues
        self.inspectionError = inspectionError
    }
}

nonisolated enum BatchPreflightInspector {
    static func inspect(
        url: URL,
        steps: [EVAProcessingStep]
    ) -> BatchPreflightResult {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let metadata = try MFFReader().inspectSignalMetadata(from: url)
            let target = ReplayCompatibilityTarget(metadata: metadata)
            let issues = steps.enumerated().compactMap { index, step -> BatchPreflightIssue? in
                guard let flag = ReplayCompatibility.check(step, against: target) else { return nil }
                return BatchPreflightIssue(
                    stepIndex: index,
                    operation: step.operation,
                    flag: flag
                )
            }
            return BatchPreflightResult(
                url: url,
                numberOfChannels: metadata.numberOfChannels,
                samplingRate: metadata.samplingRate,
                eventCodes: Set(metadata.events.map(\.code)),
                hasICAPayload: ICAReplayPayload.read(fromPackage: url) != nil,
                hasArtifactPayload: ArtifactReplayPayload.read(fromPackage: url) != nil,
                hasElectrodeGeometry: !(ElectrodeGeometry
                    .load(fromPackageContaining: metadata.signalURL)?.positions.isEmpty ?? true),
                issues: issues,
                inspectionError: nil
            )
        } catch {
            return BatchPreflightResult(
                url: url,
                numberOfChannels: nil,
                samplingRate: nil,
                eventCodes: [],
                issues: [],
                inspectionError: error.localizedDescription
            )
        }
    }
}

/// Revisioned state keeps results from a cancelled inspection from returning
/// after a file/script change. Filtering on accept is a second safety net: even
/// a same-revision result for a file no longer selected cannot reappear.
nonisolated struct BatchPreflightState: Sendable, Equatable {
    private(set) var revision = 0
    private(set) var selectedFiles: [URL] = []
    private(set) var results: [URL: BatchPreflightResult] = [:]
    private(set) var pendingFiles: Set<URL> = []

    mutating func begin(files: [URL]) -> Int {
        revision &+= 1
        selectedFiles = files
        results = [:]
        pendingFiles = Set(files)
        return revision
    }

    @discardableResult
    mutating func accept(
        _ incoming: [BatchPreflightResult],
        revision incomingRevision: Int
    ) -> Bool {
        guard incomingRevision == revision else { return false }
        let selected = Set(selectedFiles)
        results = Dictionary(
            uniqueKeysWithValues: incoming
                .filter { selected.contains($0.url) }
                .map { ($0.url, $0) }
        )
        pendingFiles.subtract(results.keys)
        return true
    }
}

@MainActor
@Observable
final class BatchPreflightModel {
    typealias Inspect = @Sendable (URL, [EVAProcessingStep]) -> BatchPreflightResult

    private(set) var state = BatchPreflightState()
    private let inspect: Inspect
    private var task: Task<Void, Never>?

    init(inspect: @escaping Inspect = BatchPreflightInspector.inspect) {
        self.inspect = inspect
    }

    var isChecking: Bool { !state.pendingFiles.isEmpty }

    func refresh(files: [URL], script: EVAProcessingScript?) {
        task?.cancel()
        guard !files.isEmpty, let script else {
            _ = state.begin(files: [])
            return
        }
        let revision = state.begin(files: files)

        let steps = script.steps
        let inspect = self.inspect
        task = Task { [weak self] in
            let incoming = await Task.detached(priority: .utility) {
                var results: [BatchPreflightResult] = []
                results.reserveCapacity(files.count)
                for url in files {
                    guard !Task.isCancelled else { break }
                    results.append(inspect(url, steps))
                }
                return results
            }.value
            guard !Task.isCancelled else { return }
            self?.state.accept(incoming, revision: revision)
        }
    }
}
