//
//  ArtifactCleaner.swift
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
//  Reversible artifact-cleaning methods built from user-defined artifact
//  templates and their detected event windows.
//

import Foundation

enum DefinedArtifactType: String, CaseIterable, Identifiable, Codable, Sendable {
    case ocular = "Ocular Artifact"
    case ecg = "ECG Artifact"
    case bcg = "BCG Artifact"
    case other = "Other"

    var id: String { rawValue }
}

enum ArtifactCleaningMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    case doNothing = "Do Nothing"
    case regression = "Regress"
    case obs = "OBS"
    case sspPCA = "SSP/PCA"

    var id: String { rawValue }

    nonisolated var removesArtifact: Bool {
        self != .doNothing
    }
}

struct DefinedArtifact: Identifiable, Sendable {
    nonisolated static let defaultOBSComponentCount = 2
    nonisolated static let maximumOBSComponentCount = 8
    nonisolated static let defaultOBSEdgeTaperSeconds = 0.10
    nonisolated static let maximumOBSEdgeTaperSeconds = 0.50

    var id = UUID()
    var type: DefinedArtifactType
    var name: String
    var eventCode: String
    var events: [MFFEvent]
    var selectedChannelIndices: [Int]
    var windowSizeSeconds: Double
    var average: ArtifactTemplateAverage?
    var topography: ArtifactTemplateTopography?
    var cleaningMethod: ArtifactCleaningMethod
    var obsPCAComponentCount = Self.defaultOBSComponentCount
    var obsEdgeTaperSeconds = Self.defaultOBSEdgeTaperSeconds
    var obsPreservesLocalBaseline = true
    var obsUsesOverlapAdd = true
    var appliedMethod: ArtifactCleaningMethod?
    var cleanedAt: Date?

    var eventCount: Int {
        events.count
    }
}

struct ArtifactCleaningSummary: Identifiable, Sendable {
    var artifactID: UUID
    var name: String
    var method: ArtifactCleaningMethod
    var eventCount: Int
    var channelCount: Int

    var id: UUID { artifactID }
}

struct OBSPCAComponentVariance: Identifiable, Sendable {
    var componentIndex: Int
    var explainedVariance: Double
    var cumulativeVariance: Double
    var remainingVariance: Double

    var id: Int { componentIndex }
}

struct OBSPCAVarianceReport: Sendable {
    var artifactID: UUID
    var eventCount: Int
    var validEventCount: Int
    var sampledEventCount: Int
    var channelCount: Int
    var windowSampleCount: Int
    var totalResidualVariance: Double
    var components: [OBSPCAComponentVariance]

    func cumulativeVariance(for componentCount: Int) -> Double {
        guard componentCount > 0 else { return 0 }
        let index = min(componentCount, components.count) - 1
        guard components.indices.contains(index) else { return 0 }
        return components[index].cumulativeVariance
    }
}

enum ArtifactCleaningProgressPhase: String, Sendable {
    case preparing = "Preparing"
    case cleaning = "Cleaning"
    case finalizing = "Finalizing"
}

struct ArtifactCleaningProgress: Sendable {
    var completed: Int
    var total: Int
    var artifactCompleted: Int
    var artifactTotal: Int
    var artifactIndex: Int
    var artifactCount: Int
    var artifactName: String
    var method: ArtifactCleaningMethod
    var phase: ArtifactCleaningProgressPhase
    var detail: String?

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

nonisolated enum ArtifactCleaner {
    static func obsVarianceReport(
        for artifact: DefinedArtifact,
        in signal: MFFSignalData,
        maximumComponents: Int = DefinedArtifact.maximumOBSComponentCount
    ) -> OBSPCAVarianceReport? {
        guard let sampleCount = signal.data.first?.count, sampleCount > 0 else { return nil }

        let windowSamples = obsPaddedWindowSamples(for: artifact, signal: signal)
        let ranges = artifact.events.compactMap {
            eventWindow(
                event: $0,
                windowSamples: windowSamples,
                sampleCount: sampleCount,
                samplingRate: signal.samplingRate
            )
        }
        guard !ranges.isEmpty else { return nil }

        let channels = SignalSelection.validChannels(in: signal.data, sampleCount: sampleCount)
        guard !channels.isEmpty else { return nil }

        let componentLimit = min(max(maximumComponents, 0), max(ranges.count - 1, 0))
        guard componentLimit > 0 else {
            return OBSPCAVarianceReport(
                artifactID: artifact.id,
                eventCount: artifact.events.count,
                validEventCount: ranges.count,
                sampledEventCount: ranges.count,
                channelCount: channels.count,
                windowSampleCount: windowSamples,
                totalResidualVariance: 0,
                components: []
            )
        }

        let sampledRanges = sampledRanges(from: ranges, maximumCount: 80)
        let sampledEventCount = sampledRanges.count
        var aggregateGram = Array(
            repeating: [Double](repeating: 0, count: sampledEventCount),
            count: sampledEventCount
        )
        let varianceContributions = obsVarianceContributions(
            data: signal.data,
            channels: channels,
            sampledRanges: sampledRanges,
            workerCount: workerCount(for: channels.count)
        )
        for contribution in varianceContributions {
            for row in contribution.gram.indices {
                for column in contribution.gram[row].indices {
                    aggregateGram[row][column] += contribution.gram[row][column]
                }
            }
        }
        let contributingChannels = varianceContributions.count

        let eigenvalues = principalComponentEigenvalues(fromGram: aggregateGram, maximumCount: max(sampledEventCount - 1, componentLimit))
        let totalResidualVariance = eigenvalues.reduce(0, +)

        guard totalResidualVariance > 1e-12, contributingChannels > 0 else {
            return OBSPCAVarianceReport(
                artifactID: artifact.id,
                eventCount: artifact.events.count,
                validEventCount: ranges.count,
                sampledEventCount: sampledEventCount,
                channelCount: channels.count,
                windowSampleCount: windowSamples,
                totalResidualVariance: 0,
                components: []
            )
        }

        var cumulative = 0.0
        let components = eigenvalues.prefix(componentLimit).enumerated().map { index, variance in
            let explained = max(variance / totalResidualVariance, 0)
            cumulative = min(cumulative + explained, 1)
            return OBSPCAComponentVariance(
                componentIndex: index + 1,
                explainedVariance: explained,
                cumulativeVariance: cumulative,
                remainingVariance: max(1 - cumulative, 0)
            )
        }

        return OBSPCAVarianceReport(
            artifactID: artifact.id,
            eventCount: artifact.events.count,
            validEventCount: ranges.count,
            sampledEventCount: sampledEventCount,
            channelCount: contributingChannels,
            windowSampleCount: windowSamples,
            totalResidualVariance: totalResidualVariance,
            components: components
        )
    }

    private static func obsVarianceContributions(
        data: [[Float]],
        channels: [Int],
        sampledRanges: [Range<Int>],
        workerCount: Int
    ) -> [OBSVarianceContribution] {
        guard sampledRanges.count > 1, !channels.isEmpty else { return [] }
        let boundedWorkerCount = min(max(workerCount, 1), channels.count)
        guard boundedWorkerCount > 1 else {
            return channels.compactMap {
                obsVarianceContribution(channelData: data[$0], sampledRanges: sampledRanges)
            }
        }

        var contributions: [OBSVarianceContribution] = []
        contributions.reserveCapacity(channels.count)
        let lock = NSLock()

        for batchStart in stride(from: 0, to: channels.count, by: boundedWorkerCount) {
            let batchEnd = min(batchStart + boundedWorkerCount, channels.count)
            let batchChannels = Array(channels[batchStart..<batchEnd])
            evaConcurrentPerform(iterations: batchChannels.count) { batchIndex in
                let channel = batchChannels[batchIndex]
                guard let contribution = obsVarianceContribution(
                    channelData: data[channel],
                    sampledRanges: sampledRanges
                ) else {
                    return
                }

                lock.lock()
                contributions.append(contribution)
                lock.unlock()
            }
        }

        return contributions
    }

    private static func obsVarianceContribution(
        channelData: [Float],
        sampledRanges: [Range<Int>]
    ) -> OBSVarianceContribution? {
        let windows = sampledRanges.map { Array(channelData[$0]) }
        guard windows.count > 1 else { return nil }

        let mean = meanWindow(windows)
        let residuals = windows.map { zip($0, mean).map { Double($0.0 - $0.1) } }
        var gram = Array(
            repeating: [Double](repeating: 0, count: residuals.count),
            count: residuals.count
        )
        var channelEnergy = 0.0

        for row in residuals.indices {
            for column in row..<residuals.count {
                let value = LinearAlgebra.dot(residuals[row], residuals[column])
                gram[row][column] = value
                gram[column][row] = value
                if row == column {
                    channelEnergy += value
                }
            }
        }

        guard channelEnergy > 1e-12 else { return nil }
        return OBSVarianceContribution(gram: gram)
    }

    static func cleanedSignal(
        from signal: MFFSignalData,
        artifacts: [DefinedArtifact],
        excluding badChannels: Set<Int>,
        progress: (@Sendable (ArtifactCleaningProgress) -> Void)? = nil
    ) -> (signal: MFFSignalData, summaries: [ArtifactCleaningSummary]) {
        var data = signal.data
        var summaries: [ArtifactCleaningSummary] = []
        let artifactsToClean = artifacts.filter { $0.cleaningMethod.removesArtifact && !$0.events.isEmpty }
        let artifactCount = artifactsToClean.count
        let totalEvents = artifactsToClean.reduce(0) { $0 + $1.events.count }
        var completedEvents = 0

        for (index, artifact) in artifactsToClean.enumerated() {
            let startingCompletedEvents = completedEvents

            let reportProgress: (ArtifactCleaningProgressPhase, Int, String?) -> Void = { phase, artifactCompletedEvents, detail in
                let boundedArtifactCompleted = min(max(artifactCompletedEvents, 0), artifact.events.count)
                completedEvents = max(completedEvents, startingCompletedEvents + boundedArtifactCompleted)
                progress?(ArtifactCleaningProgress(
                    completed: completedEvents,
                    total: totalEvents,
                    artifactCompleted: boundedArtifactCompleted,
                    artifactTotal: artifact.events.count,
                    artifactIndex: index + 1,
                    artifactCount: artifactCount,
                    artifactName: artifact.name,
                    method: artifact.cleaningMethod,
                    phase: phase,
                    detail: detail
                ))
            }
            let reportSetupProgress: (String) -> Void = { detail in
                reportProgress(.preparing, 0, detail)
            }
            let reportEventProgress: (Int) -> Void = { artifactCompletedEvents in
                reportProgress(.cleaning, artifactCompletedEvents, nil)
            }
            let reportFinalizingProgress: (String) -> Void = { detail in
                let artifactCompleted = min(max(completedEvents - startingCompletedEvents, 0), artifact.events.count)
                reportProgress(.finalizing, artifactCompleted, detail)
            }

            reportSetupProgress("Checking events and readable channels")

            let channelCount: Int
            switch artifact.cleaningMethod {
            case .doNothing:
                channelCount = 0
            case .regression:
                reportSetupProgress("Preparing saved average waveform templates")
                channelCount = applyTemplateRegression(
                    artifact: artifact,
                    signal: signal,
                    data: &data,
                    eventProgress: reportEventProgress
                )
            case .obs:
                channelCount = applyOBS(
                    artifact: artifact,
                    signal: signal,
                    data: &data,
                    setupProgress: reportSetupProgress,
                    finalizingProgress: reportFinalizingProgress,
                    eventProgress: reportEventProgress
                )
            case .sspPCA:
                channelCount = applySSPPCA(
                    artifact: artifact,
                    signal: signal,
                    data: &data,
                    excluding: badChannels,
                    setupProgress: reportSetupProgress,
                    finalizingProgress: reportFinalizingProgress,
                    eventProgress: reportEventProgress
                )
            }

            if channelCount > 0 {
                summaries.append(ArtifactCleaningSummary(
                    artifactID: artifact.id,
                    name: artifact.name,
                    method: artifact.cleaningMethod,
                    eventCount: artifact.events.count,
                    channelCount: channelCount
                ))
            }

            if completedEvents < startingCompletedEvents + artifact.events.count {
                reportEventProgress(artifact.events.count)
            }
        }

        let cleaned = MFFSignalData(
            signalURL: signal.signalURL,
            signalType: "\(signal.signalType) Artifact Cleaned",
            numberOfChannels: signal.numberOfChannels,
            samplingRate: signal.samplingRate,
            duration: signal.duration,
            recordingStartTime: signal.recordingStartTime,
            events: signal.events,
            data: data,
            channelNames: signal.channelNames
        )
        return (cleaned, summaries)
    }

    // MARK: - Methods

    private static func applyTemplateRegression(
        artifact: DefinedArtifact,
        signal: MFFSignalData,
        data: inout [[Float]],
        eventProgress: (Int) -> Void
    ) -> Int {
        guard let average = artifact.average,
              let sampleCount = data.first?.count,
              sampleCount > 0 else {
            return 0
        }

        let windowSamples = windowSamples(for: artifact, signal: signal)
        let channels = SignalSelection.validChannels(in: data, sampleCount: sampleCount)
        var cleanedChannels = Set<Int>()
        var channelTemplates: [(channel: Int, template: [Double])] = []

        for channel in channels {
            guard channel < average.allChannelSamples.count,
                  average.allChannelSamples[channel].count == windowSamples else {
                continue
            }
            let template = centeredUnitVector(average.allChannelSamples[channel])
            guard !template.isEmpty else { continue }
            channelTemplates.append((channel, template))
        }

        guard !channelTemplates.isEmpty else { return 0 }

        for (eventIndex, event) in artifact.events.enumerated() {
            defer { eventProgress(eventIndex + 1) }
            guard let range = eventWindow(
                event: event,
                windowSamples: windowSamples,
                sampleCount: sampleCount,
                samplingRate: signal.samplingRate
            ) else { continue }

            for channelTemplate in channelTemplates {
                subtractBasis([channelTemplate.template], from: &data[channelTemplate.channel], in: range)
                cleanedChannels.insert(channelTemplate.channel)
            }
        }

        return cleanedChannels.count
    }

    private static func applyOBS(
        artifact: DefinedArtifact,
        signal: MFFSignalData,
        data: inout [[Float]],
        setupProgress: (String) -> Void,
        finalizingProgress: (String) -> Void,
        eventProgress: (Int) -> Void
    ) -> Int {
        guard let sampleCount = data.first?.count, sampleCount > 0 else { return 0 }

        let coreWindowSamples = windowSamples(for: artifact, signal: signal)
        let edgeTaperSamples = obsEdgeTaperSamples(for: artifact, signal: signal, windowSamples: coreWindowSamples)
        let windowSamples = coreWindowSamples + 2 * edgeTaperSamples
        let coreWindowMilliseconds = milliseconds(for: coreWindowSamples, samplingRate: signal.samplingRate)
        let edgeTaperMilliseconds = milliseconds(for: edgeTaperSamples, samplingRate: signal.samplingRate)
        setupProgress("Resolving event windows (\(coreWindowMilliseconds) ms core, \(edgeTaperMilliseconds) ms edge taper)")
        let eventRanges = artifact.events.map {
            eventWindow(
                event: $0,
                windowSamples: windowSamples,
                sampleCount: sampleCount,
                samplingRate: signal.samplingRate
            )
        }
        let ranges = eventRanges.compactMap { $0 }
        guard !ranges.isEmpty else { return 0 }

        let channels = SignalSelection.validChannels(in: data, sampleCount: sampleCount)
        let workerCount = workerCount(for: channels.count)
        setupProgress("Fitting OBS bases from \(min(ranges.count, 80)) sampled windows across \(channels.count) channels on \(workerCount) worker\(workerCount == 1 ? "" : "s")")
        var cleanedChannels = Set<Int>()
        let componentLimit = max(artifact.obsPCAComponentCount, 0)
        let taper = raisedCosineTaper(count: windowSamples, edgeSamples: edgeTaperSamples)
        let channelBases = fitOBSChannelBases(
            data: data,
            ranges: ranges,
            channels: channels,
            componentLimit: componentLimit,
            workerCount: workerCount,
            setupProgress: setupProgress
        )

        guard !channelBases.isEmpty else { return 0 }
        setupProgress("Prepared \(channelBases.count) channel bases; starting per-event subtraction")

        // Snapshot channel data as an immutable capture so concurrent closures
        // can read it without inout aliasing issues.
        let channelSnapshot: [[Float]] = channelBases.map { data[$0.channel] }
        let basisCount = channelBases.count
        let preservesBaseline = artifact.obsPreservesLocalBaseline

        if artifact.obsUsesOverlapAdd {
            // One accumulator per basis (aligned by index, not by channel key) so
            // the concurrentPerform inner loop can index without a dictionary lookup
            // or any locking — each basisIndex owns exactly one accumulator.
            let accumulators = (0..<basisCount).map { _ in
                OBSCorrectionAccumulator(sampleCount: sampleCount)
            }

            for (eventIndex, maybeRange) in eventRanges.enumerated() {
                defer { eventProgress(eventIndex + 1) }
                guard let range = maybeRange else { continue }

                evaConcurrentPerform(iterations: basisCount) { basisIndex in
                    guard let correction = fittedCorrection(
                        basis: channelBases[basisIndex].basis,
                        from: channelSnapshot[basisIndex],
                        in: range,
                        taper: taper,
                        preservesLocalBaseline: preservesBaseline,
                        edgeTaperSamples: edgeTaperSamples
                    ) else { return }
                    accumulators[basisIndex].add(correction, in: range)
                }
            }

            finalizingProgress("Combining overlapping OBS corrections")
            for basisIndex in channelBases.indices {
                accumulators[basisIndex].apply(to: &data[channelBases[basisIndex].channel])
                cleanedChannels.insert(channelBases[basisIndex].channel)
            }
        } else {
            // Non-overlap-add: compute corrections concurrently per channel, then
            // apply to data serially (avoids inout aliasing across concurrent writes).
            for (eventIndex, maybeRange) in eventRanges.enumerated() {
                defer { eventProgress(eventIndex + 1) }
                guard let range = maybeRange else { continue }

                var corrections = [OBSCorrection?](repeating: nil, count: basisCount)
                evaConcurrentPerform(iterations: basisCount) { basisIndex in
                    corrections[basisIndex] = fittedCorrection(
                        basis: channelBases[basisIndex].basis,
                        from: channelSnapshot[basisIndex],
                        in: range,
                        taper: taper,
                        preservesLocalBaseline: preservesBaseline,
                        edgeTaperSamples: edgeTaperSamples
                    )
                }
                for basisIndex in channelBases.indices {
                    guard let correction = corrections[basisIndex] else { continue }
                    let channel = channelBases[basisIndex].channel
                    for offset in 0..<range.count {
                        data[channel][range.lowerBound + offset] -= Float(correction.weightedValues[offset])
                    }
                    cleanedChannels.insert(channel)
                }
            }
        }

        return cleanedChannels.count
    }

    private static func fitOBSChannelBases(
        data: [[Float]],
        ranges: [Range<Int>],
        channels: [Int],
        componentLimit: Int,
        workerCount: Int,
        setupProgress: (String) -> Void
    ) -> [OBSChannelBasis] {
        guard !channels.isEmpty else { return [] }
        let boundedWorkerCount = min(max(workerCount, 1), channels.count)
        guard boundedWorkerCount > 1 else {
            return channels.compactMap { channel in
                fitOBSChannelBasis(
                    channel: channel,
                    channelData: data[channel],
                    ranges: ranges,
                    componentLimit: componentLimit
                )
            }
        }

        var bases: [OBSChannelBasis] = []
        bases.reserveCapacity(channels.count)
        let lock = NSLock()
        let batchSize = boundedWorkerCount
        var completedChannels = 0

        for batchStart in stride(from: 0, to: channels.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, channels.count)
            let batchChannels = Array(channels[batchStart..<batchEnd])
            evaConcurrentPerform(iterations: batchChannels.count) { batchIndex in
                let channel = batchChannels[batchIndex]
                guard let basis = fitOBSChannelBasis(
                    channel: channel,
                    channelData: data[channel],
                    ranges: ranges,
                    componentLimit: componentLimit
                ) else {
                    return
                }

                lock.lock()
                bases.append(basis)
                lock.unlock()
            }

            completedChannels = batchEnd
            if completedChannels < channels.count {
                setupProgress("Fitting OBS bases \(completedChannels) of \(channels.count) channels on \(boundedWorkerCount) workers")
            }
        }

        return bases.sorted { $0.channel < $1.channel }
    }

    private static func fitOBSChannelBasis(
        channel: Int,
        channelData: [Float],
        ranges: [Range<Int>],
        componentLimit: Int
    ) -> OBSChannelBasis? {
        let windows = sampledWindows(from: channelData, ranges: ranges, maximumCount: 80)
        guard !windows.isEmpty else { return nil }

        let mean = meanWindow(windows)
        var basis = [centeredUnitVector(mean)].filter { !$0.isEmpty }
        if windows.count > 1, componentLimit > 0 {
            let residuals = windows.map { zip($0, mean).map { Double($0.0 - $0.1) } }
            basis += principalComponents(from: residuals, maximumCount: min(componentLimit, windows.count - 1))
        }
        guard !basis.isEmpty else { return nil }
        return OBSChannelBasis(channel: channel, basis: basis)
    }

    private static func applySSPPCA(
        artifact: DefinedArtifact,
        signal: MFFSignalData,
        data: inout [[Float]],
        excluding badChannels: Set<Int>,
        setupProgress: (String) -> Void,
        finalizingProgress: (String) -> Void,
        eventProgress: (Int) -> Void
    ) -> Int {
        guard let sampleCount = data.first?.count, sampleCount > 0 else { return 0 }

        let coreWindowSamples = windowSamples(for: artifact, signal: signal)
        let edgeTaperSamples = obsEdgeTaperSamples(for: artifact, signal: signal, windowSamples: coreWindowSamples)
        let windowSamples = coreWindowSamples + 2 * edgeTaperSamples
        let coreWindowMilliseconds = milliseconds(for: coreWindowSamples, samplingRate: signal.samplingRate)
        let edgeTaperMilliseconds = milliseconds(for: edgeTaperSamples, samplingRate: signal.samplingRate)
        setupProgress("Resolving event windows (\(coreWindowMilliseconds) ms core, \(edgeTaperMilliseconds) ms edge taper)")
        let eventRanges = artifact.events.map {
            eventWindow(
                event: $0,
                windowSamples: windowSamples,
                sampleCount: sampleCount,
                samplingRate: signal.samplingRate
            )
        }
        let ranges = eventRanges.compactMap { $0 }
        let channels = SignalSelection.validChannels(in: data, sampleCount: sampleCount)
            .filter { !badChannels.contains($0) }
        guard channels.count > 1, !ranges.isEmpty else { return 0 }
        let taper = raisedCosineTaper(count: windowSamples, edgeSamples: edgeTaperSamples)

        setupProgress("Computing spatial covariance from \(ranges.count) windows across \(channels.count) channels")
        let covariance = spatialCovariance(data: data, ranges: ranges, channels: channels)
        setupProgress("Solving SSP/PCA projection components")
        let eigen = LinearAlgebra.symmetricEigenDecomposition(covariance)
        guard eigen.values.count == channels.count,
              eigen.vectors.count == channels.count else {
            return 0
        }

        let ordered = eigen.values.indices.sorted { eigen.values[$0] > eigen.values[$1] }
        let componentCount = min(2, ordered.filter { eigen.values[$0] > 1e-9 }.count)
        guard componentCount > 0 else { return 0 }

        let components = ordered.prefix(componentCount).map { component in
            (0..<channels.count).map { row in eigen.vectors[row][component] }
        }

        setupProgress("Prepared \(componentCount) spatial components; starting per-event projection")
        var cleanedChannels = Set<Int>()
        let channelCount = channels.count
        let preservesBaseline = artifact.obsPreservesLocalBaseline

        if artifact.obsUsesOverlapAdd {
            // One accumulator per channel offset (aligned with `channels` array).
            let accumulators = (0..<channelCount).map { _ in
                OBSCorrectionAccumulator(sampleCount: sampleCount)
            }

            for (eventIndex, maybeRange) in eventRanges.enumerated() {
                defer { eventProgress(eventIndex + 1) }
                guard let range = maybeRange else { continue }
                // sspCorrections is a single scan over samples; compute it once.
                let rawCorrections = sspCorrections(
                    data: data,
                    range: range,
                    channels: channels,
                    components: components
                )
                // Taper and accumulate per channel in parallel.
                evaConcurrentPerform(iterations: channelCount) { offset in
                    guard let correction = smoothedWindowCorrection(
                        rawCorrections[offset],
                        taper: taper,
                        preservesLocalBaseline: preservesBaseline,
                        edgeTaperSamples: edgeTaperSamples
                    ) else { return }
                    accumulators[offset].add(correction, in: range)
                }
            }

            finalizingProgress("Combining overlapping SSP/PCA corrections")
            for (offset, channel) in channels.enumerated() {
                accumulators[offset].apply(to: &data[channel])
                cleanedChannels.insert(channel)
            }
        } else {
            for (eventIndex, maybeRange) in eventRanges.enumerated() {
                defer { eventProgress(eventIndex + 1) }
                guard let range = maybeRange else { continue }
                let rawCorrections = sspCorrections(
                    data: data,
                    range: range,
                    channels: channels,
                    components: components
                )
                // Compute tapered corrections concurrently, apply serially.
                var smoothed = [OBSCorrection?](repeating: nil, count: channelCount)
                evaConcurrentPerform(iterations: channelCount) { offset in
                    smoothed[offset] = smoothedWindowCorrection(
                        rawCorrections[offset],
                        taper: taper,
                        preservesLocalBaseline: preservesBaseline,
                        edgeTaperSamples: edgeTaperSamples
                    )
                }
                for (offset, channel) in channels.enumerated() {
                    guard let correction = smoothed[offset] else { continue }
                    for sampleOffset in 0..<range.count {
                        data[channel][range.lowerBound + sampleOffset] -= Float(correction.weightedValues[sampleOffset])
                    }
                    cleanedChannels.insert(channel)
                }
            }
        }

        return cleanedChannels.count
    }

    // MARK: - Basis fitting

    private static func subtractBasis(_ basis: [[Double]], from channel: inout [Float], in range: Range<Int>) {
        let taper = [Double](repeating: 1, count: range.count)
        subtractBasis(
            basis,
            from: &channel,
            in: range,
            taper: taper,
            preservesLocalBaseline: false,
            edgeTaperSamples: 0
        )
    }

    private static func subtractBasis(
        _ basis: [[Double]],
        from channel: inout [Float],
        in range: Range<Int>,
        taper: [Double],
        preservesLocalBaseline: Bool,
        edgeTaperSamples: Int
    ) {
        guard let correction = fittedCorrection(
            basis: basis,
            from: channel,
            in: range,
            taper: taper,
            preservesLocalBaseline: preservesLocalBaseline,
            edgeTaperSamples: edgeTaperSamples
        ) else { return }

        for offset in 0..<range.count {
            channel[range.lowerBound + offset] -= Float(correction.weightedValues[offset])
        }
    }

    private static func fittedCorrection(
        basis: [[Double]],
        from channel: [Float],
        in range: Range<Int>,
        taper: [Double],
        preservesLocalBaseline: Bool,
        edgeTaperSamples: Int
    ) -> OBSCorrection? {
        let basis = basis.filter { $0.count == range.count && SignalStatistics.vectorEnergy($0) > 1e-12 }
        guard !basis.isEmpty, taper.count == range.count else { return nil }

        let samples = range.map { channel[$0] }
        let y = centeredVector(samples)
        let coefficients = coefficientsForBasis(basis, y: y)
        guard coefficients.count == basis.count else { return nil }

        var correction = [Double](repeating: 0, count: range.count)
        for offset in 0..<range.count {
            for basisIndex in basis.indices {
                correction[offset] += coefficients[basisIndex] * basis[basisIndex][offset]
            }
        }

        if preservesLocalBaseline {
            preserveLocalBaseline(in: &correction, edgeTaperSamples: edgeTaperSamples)
        }
        return smoothedWindowCorrection(
            correction,
            taper: taper,
            preservesLocalBaseline: false,
            edgeTaperSamples: edgeTaperSamples
        )
    }

    private static func coefficientsForBasis(_ basis: [[Double]], y: [Double]) -> [Double] {
        let count = basis.count
        var gram = Array(repeating: [Double](repeating: 0, count: count), count: count)
        var rhs = [Double](repeating: 0, count: count)

        for row in 0..<count {
            rhs[row] = LinearAlgebra.dot(basis[row], y)
            for column in row..<count {
                let value = LinearAlgebra.dot(basis[row], basis[column])
                gram[row][column] = value
                gram[column][row] = value
            }
        }

        for index in 0..<count {
            gram[index][index] += max(abs(gram[index][index]) * 1e-6, 1e-9)
        }
        return LinearAlgebra.solveLinearSystem(gram, rhs) ?? []
    }

    private static func sspCorrections(
        data: [[Float]],
        range: Range<Int>,
        channels: [Int],
        components: [[Double]]
    ) -> [[Double]] {
        var corrections = Array(
            repeating: [Double](repeating: 0, count: range.count),
            count: channels.count
        )

        for (sampleOffset, sample) in range.enumerated() {
            var values = channels.map { Double(data[$0][sample]) }
            let mean = values.reduce(0, +) / Double(max(values.count, 1))
            for index in values.indices {
                values[index] -= mean
            }

            var removal = [Double](repeating: 0, count: channels.count)
            for component in components {
                let coefficient = LinearAlgebra.dot(values, component)
                for index in removal.indices {
                    removal[index] += coefficient * component[index]
                }
            }

            for channelOffset in channels.indices {
                corrections[channelOffset][sampleOffset] = removal[channelOffset]
            }
        }

        return corrections
    }

    private static func smoothedWindowCorrection(
        _ values: [Double],
        taper: [Double],
        preservesLocalBaseline: Bool,
        edgeTaperSamples: Int
    ) -> OBSCorrection? {
        guard values.count == taper.count, !values.isEmpty else { return nil }
        var correction = values
        if preservesLocalBaseline {
            preserveLocalBaseline(in: &correction, edgeTaperSamples: edgeTaperSamples)
        }
        forceZeroAtBoundaries(&correction)
        let weighted = correction.indices.map { correction[$0] * taper[$0] }
        return OBSCorrection(weightedValues: weighted, weights: taper)
    }

    // MARK: - Window helpers

    private static func windowSamples(for artifact: DefinedArtifact, signal: MFFSignalData) -> Int {
        if let count = artifact.average?.allChannelSamples.first?.count, count > 1 {
            return count
        }
        return max(Int((artifact.windowSizeSeconds * signal.samplingRate).rounded()), 3)
    }

    private static func workerCount(for itemCount: Int) -> Int {
        guard itemCount > 1 else { return 1 }
        return min(itemCount, evaMaxWorkers)
    }

    private static func milliseconds(for sampleCount: Int, samplingRate: Double) -> Int {
        guard samplingRate > 0 else { return 0 }
        return Int((Double(sampleCount) / samplingRate * 1000).rounded())
    }

    private static func obsPaddedWindowSamples(for artifact: DefinedArtifact, signal: MFFSignalData) -> Int {
        let windowSamples = windowSamples(for: artifact, signal: signal)
        let edgeSamples = obsEdgeTaperSamples(for: artifact, signal: signal, windowSamples: windowSamples)
        return max(windowSamples + 2 * edgeSamples, windowSamples)
    }

    private static func obsEdgeTaperSamples(
        for artifact: DefinedArtifact,
        signal: MFFSignalData,
        windowSamples: Int
    ) -> Int {
        guard signal.samplingRate > 0 else { return 0 }
        let seconds = min(
            max(artifact.obsEdgeTaperSeconds, 0),
            DefinedArtifact.maximumOBSEdgeTaperSeconds
        )
        let requested = Int((seconds * signal.samplingRate).rounded())
        return min(max(requested, 0), max(windowSamples / 2 - 1, 0))
    }

    private static func eventWindow(
        event: MFFEvent,
        windowSamples: Int,
        sampleCount: Int,
        samplingRate: Double
    ) -> Range<Int>? {
        guard samplingRate > 0, windowSamples > 1, sampleCount >= windowSamples else { return nil }
        let center = Int((event.beginTimeSeconds * samplingRate).rounded())
        let start = center - windowSamples / 2
        let end = start + windowSamples
        guard start >= 0, end <= sampleCount else { return nil }
        return start..<end
    }

    private static func sampledWindows(from channel: [Float], ranges: [Range<Int>], maximumCount: Int) -> [[Float]] {
        sampledRanges(from: ranges, maximumCount: maximumCount).map { Array(channel[$0]) }
    }

    private static func sampledRanges(from ranges: [Range<Int>], maximumCount: Int) -> [Range<Int>] {
        guard ranges.count > maximumCount, maximumCount > 0 else {
            return ranges
        }

        return (0..<maximumCount).map { index in
            let rangeIndex = index * ranges.count / maximumCount
            return ranges[rangeIndex]
        }
    }

    private static func raisedCosineTaper(count: Int, edgeSamples: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard edgeSamples > 0 else { return [Double](repeating: 1, count: count) }

        return (0..<count).map { index in
            let distanceFromEdge = min(index, count - 1 - index)
            guard distanceFromEdge < edgeSamples else { return 1 }
            let phase = Double(distanceFromEdge) / Double(edgeSamples)
            return 0.5 - 0.5 * cos(.pi * phase)
        }
    }

    private static func preserveLocalBaseline(in correction: inout [Double], edgeTaperSamples: Int) {
        guard correction.count > 2 else { return }
        let anchorCount = min(max(edgeTaperSamples, 1), max(correction.count / 4, 1))
        let leftMean = mean(correction.prefix(anchorCount))
        let rightMean = mean(correction.suffix(anchorCount))
        let denominator = Double(max(correction.count - 1, 1))

        for index in correction.indices {
            let fraction = Double(index) / denominator
            let localBaseline = leftMean + (rightMean - leftMean) * fraction
            correction[index] -= localBaseline
        }
    }

    private static func forceZeroAtBoundaries(_ correction: inout [Double]) {
        guard correction.count > 1 else { return }
        let start = correction.first ?? 0
        let end = correction.last ?? 0
        let denominator = Double(max(correction.count - 1, 1))

        for index in correction.indices {
            let fraction = Double(index) / denominator
            correction[index] -= start + (end - start) * fraction
        }
    }

    private static func mean<S: Sequence>(_ values: S) -> Double where S.Element == Double {
        var total = 0.0
        var count = 0.0
        for value in values {
            total += value
            count += 1
        }
        return count > 0 ? total / count : 0
    }

    // MARK: - PCA helpers

    private static func principalComponents(from residuals: [[Double]], maximumCount: Int) -> [[Double]] {
        guard let sampleCount = residuals.first?.count,
              residuals.count > 1,
              residuals.allSatisfy({ $0.count == sampleCount }),
              maximumCount > 0 else {
            return []
        }

        var gram = Array(repeating: [Double](repeating: 0, count: residuals.count), count: residuals.count)
        for row in residuals.indices {
            for column in row..<residuals.count {
                let value = LinearAlgebra.dot(residuals[row], residuals[column])
                gram[row][column] = value
                gram[column][row] = value
            }
        }

        let eigen = LinearAlgebra.symmetricEigenDecomposition(gram)
        guard eigen.values.count == residuals.count,
              eigen.vectors.count == residuals.count else {
            return []
        }

        let ordered = eigen.values.indices.sorted { eigen.values[$0] > eigen.values[$1] }
        var components: [[Double]] = []
        for component in ordered.prefix(maximumCount) {
            let eigenvalue = eigen.values[component]
            guard eigenvalue > 1e-9 else { continue }

            var vector = [Double](repeating: 0, count: sampleCount)
            for residualIndex in residuals.indices {
                let weight = eigen.vectors[residualIndex][component]
                for sample in 0..<sampleCount {
                    vector[sample] += weight * residuals[residualIndex][sample]
                }
            }

            let scale = sqrt(eigenvalue)
            if scale > 1e-12 {
                for sample in vector.indices {
                    vector[sample] /= scale
                }
            }
            let normalized = centeredUnitVector(vector)
            if !normalized.isEmpty {
                components.append(normalized)
            }
        }
        return components
    }

    private static func principalComponentEigenvalues(from residuals: [[Double]], maximumCount: Int) -> [Double] {
        guard let sampleCount = residuals.first?.count,
              sampleCount > 0,
              residuals.count > 1,
              residuals.allSatisfy({ $0.count == sampleCount }),
              maximumCount > 0 else {
            return []
        }

        var gram = Array(repeating: [Double](repeating: 0, count: residuals.count), count: residuals.count)
        for row in residuals.indices {
            for column in row..<residuals.count {
                let value = LinearAlgebra.dot(residuals[row], residuals[column])
                gram[row][column] = value
                gram[column][row] = value
            }
        }

        return principalComponentEigenvalues(fromGram: gram, maximumCount: maximumCount)
    }

    private static func principalComponentEigenvalues(fromGram gram: [[Double]], maximumCount: Int) -> [Double] {
        guard maximumCount > 0,
              !gram.isEmpty,
              gram.allSatisfy({ $0.count == gram.count }) else {
            return []
        }

        let eigen = LinearAlgebra.symmetricEigenDecomposition(gram)
        guard eigen.values.count == gram.count else { return [] }

        return eigen.values
            .filter { $0 > 1e-12 }
            .sorted(by: >)
            .prefix(maximumCount)
            .map { $0 }
    }

    private static func spatialCovariance(
        data: [[Float]],
        ranges: [Range<Int>],
        channels: [Int]
    ) -> [[Double]] {
        var covariance = Array(repeating: [Double](repeating: 0, count: channels.count), count: channels.count)
        var sampleTotal = 0.0

        for range in ranges {
            let stride = max(range.count / 16, 1)
            var sample = range.lowerBound
            while sample < range.upperBound {
                var values = channels.map { Double(data[$0][sample]) }
                let mean = values.reduce(0, +) / Double(max(values.count, 1))
                for index in values.indices {
                    values[index] -= mean
                }

                for row in channels.indices {
                    for column in row..<channels.count {
                        let value = values[row] * values[column]
                        covariance[row][column] += value
                        if row != column {
                            covariance[column][row] += value
                        }
                    }
                }
                sampleTotal += 1
                sample += stride
            }
        }

        guard sampleTotal > 0 else { return covariance }
        for row in covariance.indices {
            for column in covariance[row].indices {
                covariance[row][column] /= sampleTotal
            }
        }
        return covariance
    }

    // MARK: - Small linear algebra

    private static func meanWindow(_ windows: [[Float]]) -> [Float] {
        guard let count = windows.first?.count, count > 0 else { return [] }
        var mean = [Float](repeating: 0, count: count)
        for window in windows where window.count == count {
            for sample in 0..<count {
                mean[sample] += window[sample]
            }
        }
        let divisor = Float(max(windows.count, 1))
        for sample in mean.indices {
            mean[sample] /= divisor
        }
        return mean
    }

    private static func centeredVector(_ samples: [Float]) -> [Double] {
        centeredVector(samples.map(Double.init))
    }

    private static func centeredVector(_ samples: [Double]) -> [Double] {
        guard !samples.isEmpty else { return [] }
        let mean = samples.reduce(0, +) / Double(samples.count)
        return samples.map { $0 - mean }
    }

    private static func centeredUnitVector(_ samples: [Float]) -> [Double] {
        centeredUnitVector(samples.map(Double.init))
    }

    private static func centeredUnitVector(_ samples: [Double]) -> [Double] {
        var centered = centeredVector(samples)
        let norm = sqrt(SignalStatistics.vectorEnergy(centered))
        guard norm > 1e-12 else { return [] }
        for index in centered.indices {
            centered[index] /= norm
        }
        return centered
    }

}

nonisolated private struct OBSCorrection {
    var weightedValues: [Double]
    var weights: [Double]
}

nonisolated private struct OBSChannelBasis: Sendable {
    var channel: Int
    var basis: [[Double]]
}

nonisolated private struct OBSVarianceContribution: Sendable {
    var gram: [[Double]]
}

nonisolated private final class OBSCorrectionAccumulator {
    private var weightedValues: [Double]
    private var weights: [Double]

    init(sampleCount: Int) {
        weightedValues = [Double](repeating: 0, count: sampleCount)
        weights = [Double](repeating: 0, count: sampleCount)
    }

    func add(_ correction: OBSCorrection, in range: Range<Int>) {
        guard correction.weightedValues.count == range.count,
              correction.weights.count == range.count,
              range.upperBound <= weightedValues.count else {
            return
        }

        for offset in 0..<range.count {
            let sample = range.lowerBound + offset
            weightedValues[sample] += correction.weightedValues[offset]
            weights[sample] += correction.weights[offset]
        }
    }

    func apply(to channel: inout [Float]) {
        let count = min(channel.count, weightedValues.count)
        for sample in 0..<count where weights[sample] > 0 {
            let divisor = max(weights[sample], 1)
            channel[sample] -= Float(weightedValues[sample] / divisor)
        }
    }
}
