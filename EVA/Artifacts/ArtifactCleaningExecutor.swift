//
//  ArtifactCleaningExecutor.swift
//  EVA
//
//  Async orchestration for Clean Artifacts. Most cleaners remain synchronous;
//  manual-exemplar PCA-S awaits EVA's shared zero-phase filter and is kept here
//  so the UI and headless replay execute the same ordered pipeline.
//

import Foundation

nonisolated struct ArtifactCleaningExecutionResult: Sendable {
    var signal: MFFSignalData
    var summaries: [ArtifactCleaningSummary]
    var pcaSReports: [UUID: BCGSurrogateReport]
    var failures: [UUID: String]
}

nonisolated enum ArtifactCleaningExecutor {
    static func cleanedSignal(
        from signal: MFFSignalData,
        artifacts: [DefinedArtifact],
        excluding excludedChannels: Set<Int>,
        geometry: ElectrodeGeometry?,
        broadbandSource: MFFSignalData? = nil,
        rWaveTimes: [Double] = [],
        ordering: ArtifactCleaningOrdering = .asDefined,
        availableBandwidthHz: Double? = nil,
        progress: (@Sendable (ArtifactCleaningProgress) -> Void)? = nil
    ) async -> ArtifactCleaningExecutionResult {
        let ordered = ArtifactCleaner.orderedArtifacts(artifacts, ordering: ordering).filter {
            let settings = $0.pcaSSettings ?? .default
            let hasPCASAnchors = $0.cleaningMethod == .pcaS
                && settings.beatSource == .rWaves
                && !rWaveTimes.isEmpty
            return $0.cleaningMethod.removesArtifact
                && (!$0.events.isEmpty || hasPCASAnchors
                    || $0.cleaningMethod == .corneoRetinalRegression
                    || $0.cleaningMethod == .movementPCA
                    || $0.cleaningMethod == .bssCCA)
        }
        func workloadCount(for artifact: DefinedArtifact) -> Int {
            let settings = artifact.pcaSSettings ?? .default
            if artifact.cleaningMethod == .pcaS, settings.beatSource == .rWaves {
                return max(rWaveTimes.count, 1)
            }
            return max(artifact.eventCount, 1)
        }
        let totalEvents = ordered.reduce(0) { $0 + workloadCount(for: $1) }
        var completedEvents = 0
        var current = signal
        var summaries: [ArtifactCleaningSummary] = []
        var reports: [UUID: BCGSurrogateReport] = [:]
        var failures: [UUID: String] = [:]

        for (index, artifact) in ordered.enumerated() {
            guard !Task.isCancelled else { break }
            let artifactTotal = workloadCount(for: artifact)
            let completedBeforeArtifact = completedEvents

            if artifact.cleaningMethod != .pcaS {
                let outcome = ArtifactCleaner.cleanedSignal(
                    from: current,
                    artifacts: [artifact],
                    excluding: excludedChannels,
                    availableBandwidthHz: availableBandwidthHz,
                    progress: { local in
                        progress?(ArtifactCleaningProgress(
                            completed: completedBeforeArtifact + local.artifactCompleted,
                            total: totalEvents,
                            artifactCompleted: local.artifactCompleted,
                            artifactTotal: artifactTotal,
                            artifactIndex: index + 1,
                            artifactCount: ordered.count,
                            artifactName: artifact.name,
                            method: artifact.cleaningMethod,
                            phase: local.phase,
                            detail: local.detail
                        ))
                    }
                )
                current = outcome.signal
                summaries.append(contentsOf: outcome.summaries)
                completedEvents += artifactTotal
                continue
            }

            progress?(ArtifactCleaningProgress(
                completed: completedEvents,
                total: totalEvents,
                artifactCompleted: 0,
                artifactTotal: artifactTotal,
                artifactIndex: index + 1,
                artifactCount: ordered.count,
                artifactName: artifact.name,
                method: .pcaS,
                phase: .preparing,
                detail: "Building source-informed model from detected matches"
            ))

            guard artifact.type == .bcg else {
                failures[artifact.id] = "PCA-S is available only for artifacts defined as BCG."
                continue
            }

            var settings = artifact.pcaSSettings ?? BCGSurrogateSettings.default
            let halfWindow = max(artifact.windowSizeSeconds, 0.02) / 2
            settings.windowStartSeconds = -halfWindow
            settings.windowEndSeconds = halfWindow
            let eventTimes: [Double]
            switch settings.beatSource {
            case .artifactEvents:
                eventTimes = artifact.events.map(\.centerTimeSeconds).sorted()
            case .rWaves:
                eventTimes = rWaveTimes.map { $0 + settings.rWaveLagSeconds }.sorted()
            }
            guard !eventTimes.isEmpty else {
                failures[artifact.id] = BCGSurrogateError.noBeats.localizedDescription
                continue
            }
            let correctedRows = current.data.indices.filter { !excludedChannels.contains($0) }

            let fittingData: [[Float]]
            switch settings.inputSource {
            case .currentFiltered:
                fittingData = current.data
            case .broadband:
                guard let broadbandSource,
                      broadbandSource.samplingRate == current.samplingRate
                else {
                    failures[artifact.id] = BCGSurrogateError.incompatibleFittingSignal.localizedDescription
                    continue
                }
                fittingData = broadbandSource.data
            }

            do {
                let output = try await BCGSurrogateCorrection.correct(
                    data: current.data,
                    fittingData: fittingData,
                    samplingRate: current.samplingRate,
                    correctedRows: correctedRows,
                    geometry: geometry,
                    channelNames: current.channelNames,
                    beatSeconds: eventTimes,
                    settings: settings
                ) { modelProgress in
                    let fraction = min(max(modelProgress.fraction, 0), 1)
                    let localCompleted = min(
                        artifactTotal,
                        Int((fraction * Double(artifactTotal)).rounded(.down))
                    )
                    let phase: ArtifactCleaningProgressPhase
                    if fraction < 0.56 {
                        phase = .preparing
                    } else if fraction < 0.99 {
                        phase = .cleaning
                    } else {
                        phase = .finalizing
                    }
                    progress?(ArtifactCleaningProgress(
                        completed: completedBeforeArtifact + localCompleted,
                        total: totalEvents,
                        artifactCompleted: localCompleted,
                        artifactTotal: artifactTotal,
                        artifactIndex: index + 1,
                        artifactCount: ordered.count,
                        artifactName: artifact.name,
                        method: .pcaS,
                        phase: phase,
                        detail: modelProgress.detail
                    ))
                }
                current = current.replacingSamples(output.data, signalTypeSuffix: "PCAS")
                reports[artifact.id] = output.report
                summaries.append(ArtifactCleaningSummary(
                    artifactID: artifact.id,
                    name: artifact.name,
                    method: .pcaS,
                    eventCount: output.report.acceptedBeatCount,
                    channelCount: output.report.correctedChannelCount
                ))
                progress?(ArtifactCleaningProgress(
                    completed: completedEvents + artifactTotal,
                    total: totalEvents,
                    artifactCompleted: artifactTotal,
                    artifactTotal: artifactTotal,
                    artifactIndex: index + 1,
                    artifactCount: ordered.count,
                    artifactName: artifact.name,
                    method: .pcaS,
                    phase: .finalizing,
                    detail: output.report.summary
                ))
            } catch {
                failures[artifact.id] = error.localizedDescription
            }
            completedEvents += artifactTotal
        }

        return ArtifactCleaningExecutionResult(
            signal: current,
            summaries: summaries,
            pcaSReports: reports,
            failures: failures
        )
    }
}
