//
//  ChannelsWindowModel.swift
//  EVA
//
//  Session-only context for the single Channels utility window. The focused
//  recording publishes here; persistent Channel Set storage remains in
//  ChannelSetStore.
//

import Foundation
import Observation

enum ChannelsWindowTab: String, CaseIterable, Identifiable {
    case channelSets = "Channel Sets"
    case health = "Health"
    case impedance = "Impedance"
    case relationships = "Relationships"
    case reference = "Reference"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .channelSets: return "square.3.layers.3d"
        case .health: return "heart.text.square"
        case .impedance: return "bolt.horizontal.circle"
        case .relationships: return "point.3.connected.trianglepath.dotted"
        case .reference: return "waveform.path.ecg.rectangle"
        }
    }
}

enum ChannelRelationshipAnalysisState: Sendable, Equatable {
    case notRun
    case analyzing
    case complete
}

@MainActor
@Observable
final class ChannelsWindowModel {
    private struct RecordingContext {
        var name: String
        var signal: MFFSignalData?
        var acquisitionSignal: MFFSignalData?
        var layout: SensorLayout?
        var channelNames: [String]?
        var healthResults: [Int: ChannelHealthResult]
        var isAnalyzingHealth: Bool
        var healthProgress: Double
        var refreshHealth: () -> Void
    }

    static let shared = ChannelsWindowModel()

    var selectedTab: ChannelsWindowTab = .channelSets
    var selectedChannel: Int?
    var selectedRelationshipID: String?

    private(set) var activeRecordingID: UUID?
    private(set) var activeRecordingName: String?
    private(set) var activeSignal: MFFSignalData?
    private(set) var activeAcquisitionSignal: MFFSignalData?
    private(set) var activeLayout: SensorLayout?
    private(set) var activeChannelNames: [String]?
    private(set) var healthResults = [Int: ChannelHealthResult]()
    private(set) var isAnalyzingHealth = false
    private(set) var healthProgress = 0.0

    private(set) var relationshipFindings: [ChannelRelationshipFinding] = []
    private(set) var strongestRelationships: [Int: ChannelRelationshipSummary] = [:]
    private(set) var relationshipAnalysisState: ChannelRelationshipAnalysisState = .notRun
    private(set) var referenceAssessment: ReferenceIntegrityAssessment?
    private(set) var acquisitionReferenceAssessment: ReferenceIntegrityAssessment?
    private(set) var averageReferenceCheck: ReferenceIntegrityAssessment?
    private(set) var isAnalyzingDiagnostics = false
    private(set) var relationshipDiagnosticStatus: String?
    private(set) var referenceDiagnosticStatus: String?

    @ObservationIgnored private var analyzedSignalRevision: UUID?
    @ObservationIgnored private var analyzedHealthResults = [Int: ChannelHealthResult]()
    @ObservationIgnored private var diagnosticTask: Task<Void, Never>?
    @ObservationIgnored private var healthRefreshAction: (() -> Void)?
    @ObservationIgnored private var recordingContexts = [UUID: RecordingContext]()

    private init() {}

    func publishRecording(
        id: UUID,
        name: String,
        signal: MFFSignalData?,
        acquisitionSignal: MFFSignalData?,
        layout: SensorLayout?,
        channelNames: [String]?,
        healthResults: [Int: ChannelHealthResult],
        isAnalyzingHealth: Bool,
        healthProgress: Double,
        refreshHealth: @escaping () -> Void
    ) {
        let context = RecordingContext(
            name: name,
            signal: signal,
            acquisitionSignal: acquisitionSignal,
            layout: layout,
            channelNames: channelNames,
            healthResults: healthResults,
            isAnalyzingHealth: isAnalyzingHealth,
            healthProgress: healthProgress,
            refreshHealth: refreshHealth
        )
        recordingContexts[id] = context
        if activeRecordingID == nil || activeRecordingID == id {
            apply(context, id: id)
        }
    }

    func activateRecording(id: UUID) {
        guard let context = recordingContexts[id] else { return }
        apply(context, id: id)
    }

    private func apply(_ context: RecordingContext, id: UUID) {
        let signalChanged = activeRecordingID != id || activeSignal?.dataRevision != context.signal?.dataRevision
        activeRecordingID = id
        activeRecordingName = context.name
        activeSignal = context.signal
        activeAcquisitionSignal = context.acquisitionSignal
        activeLayout = context.layout?.includingReference(forChannelCount: context.signal?.data.count ?? 0)
        activeChannelNames = context.channelNames
        ChannelSetStore.shared.activeSensorLayout = activeLayout
        ChannelSetStore.shared.activeChannelNames = activeChannelNames
        healthResults = context.healthResults
        isAnalyzingHealth = context.isAnalyzingHealth
        healthProgress = context.healthProgress
        healthRefreshAction = context.refreshHealth

        if signalChanged {
            clearDiagnostics()
            selectedChannel = selectedChannel.flatMap { index in
                context.signal?.data.indices.contains(index) == true ? index : nil
            }
        } else if analyzedHealthResults != context.healthResults {
            analyzedSignalRevision = nil
        }
    }

    func updateActiveRecording(
        id: UUID,
        signal: MFFSignalData,
        healthResults: [Int: ChannelHealthResult],
        isAnalyzingHealth: Bool,
        healthProgress: Double
    ) {
        guard var context = recordingContexts[id] else { return }
        context.signal = signal
        context.channelNames = signal.channelNames
        context.healthResults = healthResults
        context.isAnalyzingHealth = isAnalyzingHealth
        context.healthProgress = healthProgress
        recordingContexts[id] = context
        guard activeRecordingID == id else { return }
        let signalChanged = activeSignal?.dataRevision != signal.dataRevision
        activeSignal = signal
        activeLayout = context.layout?.includingReference(forChannelCount: signal.data.count)
        activeChannelNames = signal.channelNames
        ChannelSetStore.shared.activeSensorLayout = activeLayout
        ChannelSetStore.shared.activeChannelNames = activeChannelNames
        self.healthResults = healthResults
        self.isAnalyzingHealth = isAnalyzingHealth
        self.healthProgress = healthProgress
        if signalChanged {
            clearDiagnostics()
        } else if analyzedHealthResults != healthResults {
            analyzedSignalRevision = nil
        }
    }

    func removeRecording(id: UUID) {
        recordingContexts[id] = nil
        guard activeRecordingID == id else { return }
        diagnosticTask?.cancel()
        activeRecordingID = nil
        activeRecordingName = nil
        activeSignal = nil
        activeAcquisitionSignal = nil
        activeLayout = nil
        activeChannelNames = nil
        healthResults = [:]
        isAnalyzingHealth = false
        healthProgress = 0
        healthRefreshAction = nil
        clearDiagnostics()
    }

    func present(
        tab: ChannelsWindowTab,
        channel: Int? = nil,
        relationshipID: String? = nil
    ) {
        selectedTab = tab
        selectedChannel = channel
        selectedRelationshipID = relationshipID
    }

    func requestHealthRefresh() {
        healthRefreshAction?()
    }

    func relationships(for channel: Int) -> [ChannelRelationshipFinding] {
        relationshipFindings.filter { $0.contains(channel: channel) }
    }

    func strongestRelationship(for channel: Int) -> ChannelRelationshipSummary? {
        strongestRelationships[channel]
    }

    func cluster(containing finding: ChannelRelationshipFinding) -> [Int] {
        var members: Set<Int> = [finding.firstChannel, finding.secondChannel]
        var changed = true
        while changed {
            changed = false
            for candidate in relationshipFindings where candidate.kind == .likelyBridge {
                if members.contains(candidate.firstChannel) || members.contains(candidate.secondChannel) {
                    let oldCount = members.count
                    members.insert(candidate.firstChannel)
                    members.insert(candidate.secondChannel)
                    changed = changed || members.count != oldCount
                }
            }
        }
        return members.sorted()
    }

    func refreshDiagnostics(force: Bool = false) {
        guard let signal = activeSignal else {
            clearDiagnostics()
            relationshipDiagnosticStatus = "Open a recording to inspect channel relationships."
            referenceDiagnosticStatus = "Open a recording to inspect common-mode structure."
            return
        }
        if !force,
           analyzedSignalRevision == signal.dataRevision,
           analyzedHealthResults == healthResults {
            return
        }

        diagnosticTask?.cancel()
        isAnalyzingDiagnostics = true
        relationshipAnalysisState = .analyzing
        relationshipDiagnosticStatus = "Analyzing channel relationships…"
        referenceDiagnosticStatus = "Analyzing common-mode structure…"
        let revision = signal.dataRevision
        let layout = activeLayout
        let health = healthResults
        let acquisitionSignal = activeAcquisitionSignal

        diagnosticTask = Task { @MainActor in
            let output = await Task.detached(priority: .utility) {
                let relationships = ChannelRelationshipAnalyzer.analyzeDetailed(
                    signal: signal,
                    layout: layout,
                    healthResults: health
                )
                let reference = ChannelReferenceAnalyzer.analyze(signal: signal)
                let acquisitionReference: ReferenceIntegrityAssessment?
                if let acquisitionSignal, acquisitionSignal.dataRevision != signal.dataRevision {
                    acquisitionReference = ChannelReferenceAnalyzer.analyze(signal: acquisitionSignal)
                } else {
                    acquisitionReference = reference
                }
                let averageCheck: ReferenceIntegrityAssessment?
                if signal.referenceState == .average {
                    averageCheck = reference
                } else {
                    averageCheck = ChannelReferenceAnalyzer.analyze(
                        signal: Rereferencing.applied(signal, scheme: .average)
                    )
                }
                return (relationships, reference, acquisitionReference, averageCheck)
            }.value

            guard !Task.isCancelled, activeSignal?.dataRevision == revision else { return }
            relationshipFindings = output.0.findings
            strongestRelationships = output.0.strongestByChannel
            relationshipAnalysisState = .complete
            referenceAssessment = output.1
            acquisitionReferenceAssessment = output.2
            averageReferenceCheck = output.3
            analyzedSignalRevision = revision
            analyzedHealthResults = health
            isAnalyzingDiagnostics = false
            relationshipDiagnosticStatus = output.0.findings.isEmpty
                ? "No persistent channel-pair findings."
                : "Found \(output.0.findings.count) relationship\(output.0.findings.count == 1 ? "" : "s") for review."
            referenceDiagnosticStatus = output.1.map {
                "\($0.structureLevel.lowercased()) common-mode structure in the current signal."
            } ?? "Not enough usable data for a common-mode assessment."

            if let selectedRelationshipID,
               !output.0.findings.contains(where: { $0.id == selectedRelationshipID }) {
                self.selectedRelationshipID = nil
            }
        }
    }

    private func clearDiagnostics() {
        diagnosticTask?.cancel()
        diagnosticTask = nil
        relationshipFindings = []
        strongestRelationships = [:]
        relationshipAnalysisState = .notRun
        referenceAssessment = nil
        acquisitionReferenceAssessment = nil
        averageReferenceCheck = nil
        analyzedSignalRevision = nil
        analyzedHealthResults = [:]
        isAnalyzingDiagnostics = false
        relationshipDiagnosticStatus = nil
        referenceDiagnosticStatus = nil
        selectedRelationshipID = nil
    }
}
