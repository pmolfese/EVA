//
//  ArtifactCleaner.swift
//  EVA
//
//  Reversible artifact-cleaning methods built from user-defined artifact
//  templates and their detected event windows.
//

import Accelerate
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

        let windowSamples = windowSamples(for: artifact, signal: signal)
        let ranges = artifact.events.compactMap {
            eventWindow(
                event: $0,
                windowSamples: windowSamples,
                sampleCount: sampleCount,
                samplingRate: signal.samplingRate
            )
        }
        guard !ranges.isEmpty else { return nil }

        let channels = validChannels(in: signal.data, sampleCount: sampleCount)
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
        var contributingChannels = 0

        for channel in channels where sampledEventCount > 1 {
            let windows = sampledRanges.map { Array(signal.data[channel][$0]) }
            guard windows.count > 1 else { continue }

            let mean = meanWindow(windows)
            let residuals = windows.map { zip($0, mean).map { Double($0.0 - $0.1) } }

            var channelEnergy = 0.0
            for row in residuals.indices {
                for column in row..<residuals.count {
                    let value = dot(residuals[row], residuals[column])
                    aggregateGram[row][column] += value
                    if row != column {
                        aggregateGram[column][row] += value
                    }
                    if row == column {
                        channelEnergy += value
                    }
                }
            }

            guard channelEnergy > 1e-12 else { continue }
            contributingChannels += 1
        }

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
            progress?(ArtifactCleaningProgress(
                completed: completedEvents,
                total: totalEvents,
                artifactCompleted: 0,
                artifactTotal: artifact.events.count,
                artifactIndex: index + 1,
                artifactCount: artifactCount,
                artifactName: artifact.name,
                method: artifact.cleaningMethod,
                phase: .preparing
            ))
            let startingCompletedEvents = completedEvents
            let reportEventProgress: (Int) -> Void = { artifactCompletedEvents in
                let boundedArtifactCompleted = min(max(artifactCompletedEvents, 0), artifact.events.count)
                completedEvents = startingCompletedEvents + boundedArtifactCompleted
                progress?(ArtifactCleaningProgress(
                    completed: completedEvents,
                    total: totalEvents,
                    artifactCompleted: boundedArtifactCompleted,
                    artifactTotal: artifact.events.count,
                    artifactIndex: index + 1,
                    artifactCount: artifactCount,
                    artifactName: artifact.name,
                    method: artifact.cleaningMethod,
                    phase: .cleaning
                ))
            }

            let channelCount: Int
            switch artifact.cleaningMethod {
            case .doNothing:
                channelCount = 0
            case .regression:
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
                    eventProgress: reportEventProgress
                )
            case .sspPCA:
                channelCount = applySSPPCA(
                    artifact: artifact,
                    signal: signal,
                    data: &data,
                    excluding: badChannels,
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
            data: data
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
        let channels = validChannels(in: data, sampleCount: sampleCount)
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
        eventProgress: (Int) -> Void
    ) -> Int {
        guard let sampleCount = data.first?.count, sampleCount > 0 else { return 0 }

        let windowSamples = windowSamples(for: artifact, signal: signal)
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

        let channels = validChannels(in: data, sampleCount: sampleCount)
        var cleanedChannels = Set<Int>()
        var channelBases: [(channel: Int, basis: [[Double]])] = []
        let componentLimit = max(artifact.obsPCAComponentCount, 0)

        for channel in channels {
            let windows = sampledWindows(from: data[channel], ranges: ranges, maximumCount: 80)
            guard !windows.isEmpty else { continue }

            let mean = meanWindow(windows)
            var basis = [centeredUnitVector(mean)].filter { !$0.isEmpty }
            if windows.count > 1, componentLimit > 0 {
                let residuals = windows.map { zip($0, mean).map { Double($0.0 - $0.1) } }
                basis += principalComponents(from: residuals, maximumCount: min(componentLimit, windows.count - 1))
            }
            guard !basis.isEmpty else { continue }
            channelBases.append((channel, basis))
        }

        guard !channelBases.isEmpty else { return 0 }

        for (eventIndex, maybeRange) in eventRanges.enumerated() {
            defer { eventProgress(eventIndex + 1) }
            guard let range = maybeRange else { continue }

            for channelBasis in channelBases {
                subtractBasis(channelBasis.basis, from: &data[channelBasis.channel], in: range)
                cleanedChannels.insert(channelBasis.channel)
            }
        }

        return cleanedChannels.count
    }

    private static func applySSPPCA(
        artifact: DefinedArtifact,
        signal: MFFSignalData,
        data: inout [[Float]],
        excluding badChannels: Set<Int>,
        eventProgress: (Int) -> Void
    ) -> Int {
        guard let sampleCount = data.first?.count, sampleCount > 0 else { return 0 }

        let windowSamples = windowSamples(for: artifact, signal: signal)
        let eventRanges = artifact.events.map {
            eventWindow(
                event: $0,
                windowSamples: windowSamples,
                sampleCount: sampleCount,
                samplingRate: signal.samplingRate
            )
        }
        let ranges = eventRanges.compactMap { $0 }
        let channels = validChannels(in: data, sampleCount: sampleCount)
            .filter { !badChannels.contains($0) }
        guard channels.count > 1, !ranges.isEmpty else { return 0 }

        let covariance = spatialCovariance(data: data, ranges: ranges, channels: channels)
        let eigen = symmetricEigenDecomposition(covariance)
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

        for (eventIndex, maybeRange) in eventRanges.enumerated() {
            defer { eventProgress(eventIndex + 1) }
            guard let range = maybeRange else { continue }

            for sample in range {
                var values = channels.map { Double(data[$0][sample]) }
                let mean = values.reduce(0, +) / Double(max(values.count, 1))
                for index in values.indices {
                    values[index] -= mean
                }

                var removal = [Double](repeating: 0, count: channels.count)
                for component in components {
                    let coefficient = dot(values, component)
                    for index in removal.indices {
                        removal[index] += coefficient * component[index]
                    }
                }

                for (offset, channel) in channels.enumerated() {
                    data[channel][sample] -= Float(removal[offset])
                }
            }
        }

        return channels.count
    }

    // MARK: - Basis fitting

    private static func subtractBasis(_ basis: [[Double]], from channel: inout [Float], in range: Range<Int>) {
        let basis = basis.filter { $0.count == range.count && vectorEnergy($0) > 1e-12 }
        guard !basis.isEmpty else { return }

        let samples = range.map { channel[$0] }
        let y = centeredVector(samples)
        let coefficients = coefficientsForBasis(basis, y: y)
        guard coefficients.count == basis.count else { return }

        for offset in 0..<range.count {
            var fitted = 0.0
            for basisIndex in basis.indices {
                fitted += coefficients[basisIndex] * basis[basisIndex][offset]
            }
            channel[range.lowerBound + offset] -= Float(fitted)
        }
    }

    private static func coefficientsForBasis(_ basis: [[Double]], y: [Double]) -> [Double] {
        let count = basis.count
        var gram = Array(repeating: [Double](repeating: 0, count: count), count: count)
        var rhs = [Double](repeating: 0, count: count)

        for row in 0..<count {
            rhs[row] = dot(basis[row], y)
            for column in row..<count {
                let value = dot(basis[row], basis[column])
                gram[row][column] = value
                gram[column][row] = value
            }
        }

        for index in 0..<count {
            gram[index][index] += max(abs(gram[index][index]) * 1e-6, 1e-9)
        }
        return solveLinearSystem(gram, rhs) ?? []
    }

    // MARK: - Window helpers

    private static func windowSamples(for artifact: DefinedArtifact, signal: MFFSignalData) -> Int {
        if let count = artifact.average?.allChannelSamples.first?.count, count > 1 {
            return count
        }
        return max(Int((artifact.windowSizeSeconds * signal.samplingRate).rounded()), 3)
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

    private static func validChannels(in data: [[Float]], sampleCount: Int) -> [Int] {
        data.indices.filter { data[$0].count == sampleCount }
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
                let value = dot(residuals[row], residuals[column])
                gram[row][column] = value
                gram[column][row] = value
            }
        }

        let eigen = symmetricEigenDecomposition(gram)
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
                let value = dot(residuals[row], residuals[column])
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

        let eigen = symmetricEigenDecomposition(gram)
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
        let norm = sqrt(vectorEnergy(centered))
        guard norm > 1e-12 else { return [] }
        for index in centered.indices {
            centered[index] /= norm
        }
        return centered
    }

    private static func vectorEnergy(_ values: [Double]) -> Double {
        values.reduce(0) { $0 + ($1 * $1) }
    }

    private static func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count else { return 0 }
        var total = 0.0
        for index in lhs.indices {
            total += lhs[index] * rhs[index]
        }
        return total
    }

    private static func solveLinearSystem(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = matrix.count
        guard n > 0, rhs.count == n, matrix.allSatisfy({ $0.count == n }) else { return nil }

        var a = matrix
        var b = rhs
        for pivot in 0..<n {
            var bestRow = pivot
            var bestValue = abs(a[pivot][pivot])
            for row in (pivot + 1)..<n {
                let value = abs(a[row][pivot])
                if value > bestValue {
                    bestValue = value
                    bestRow = row
                }
            }
            guard bestValue > 1e-12 else { return nil }

            if bestRow != pivot {
                a.swapAt(bestRow, pivot)
                b.swapAt(bestRow, pivot)
            }

            let divisor = a[pivot][pivot]
            for column in pivot..<n {
                a[pivot][column] /= divisor
            }
            b[pivot] /= divisor

            for row in 0..<n where row != pivot {
                let factor = a[row][pivot]
                guard abs(factor) > 0 else { continue }
                for column in pivot..<n {
                    a[row][column] -= factor * a[pivot][column]
                }
                b[row] -= factor * b[pivot]
            }
        }
        return b
    }

    private static func symmetricEigenDecomposition(_ matrix: [[Double]]) -> (values: [Double], vectors: [[Double]]) {
        let n = matrix.count
        guard n > 0, matrix.allSatisfy({ $0.count == n }) else {
            return ([], [])
        }

        var columnMajor = Array(repeating: 0.0, count: n * n)
        for row in 0..<n {
            for column in 0..<n {
                columnMajor[column * n + row] = matrix[row][column]
            }
        }

        var eigenvalues = Array(repeating: 0.0, count: n)
        var jobz = Int8(UnicodeScalar("V").value)
        var uplo = Int8(UnicodeScalar("U").value)
        var dimension = __CLPK_integer(n)
        var leadingDimension = __CLPK_integer(n)
        var queryWork = 0.0
        var querySize = __CLPK_integer(-1)
        var info = __CLPK_integer(0)

        dsyev_(
            &jobz,
            &uplo,
            &dimension,
            &columnMajor,
            &leadingDimension,
            &eigenvalues,
            &queryWork,
            &querySize,
            &info
        )

        guard info == 0 else {
            return jacobiEigenDecomposition(matrix)
        }

        var workSize = __CLPK_integer(max(Int(queryWork.rounded(.up)), 3 * n - 1))
        var work = Array(repeating: 0.0, count: Int(workSize))
        info = 0

        dsyev_(
            &jobz,
            &uplo,
            &dimension,
            &columnMajor,
            &leadingDimension,
            &eigenvalues,
            &work,
            &workSize,
            &info
        )

        guard info == 0 else {
            return jacobiEigenDecomposition(matrix)
        }

        let eigenvectors = (0..<n).map { row in
            (0..<n).map { column in
                columnMajor[column * n + row]
            }
        }
        return (eigenvalues, eigenvectors)
    }

    private static func jacobiEigenDecomposition(_ matrix: [[Double]]) -> (values: [Double], vectors: [[Double]]) {
        let n = matrix.count
        guard n > 0 else { return ([], []) }
        guard n > 1 else { return ([matrix[0][0]], [[1]]) }
        var a = matrix
        var v = identity(n)
        let maxIterations = max(100, n * n * 8)

        for _ in 0..<maxIterations {
            var p = 0
            var q = min(1, n - 1)
            var maxValue = 0.0
            for row in 0..<n {
                for column in (row + 1)..<n {
                    let value = abs(a[row][column])
                    if value > maxValue {
                        maxValue = value
                        p = row
                        q = column
                    }
                }
            }
            if maxValue < 1e-10 { break }

            let app = a[p][p]
            let aqq = a[q][q]
            let apq = a[p][q]
            let tau = (aqq - app) / (2 * apq)
            let t = (tau >= 0 ? 1.0 : -1.0) / (abs(tau) + sqrt(1 + tau * tau))
            let c = 1.0 / sqrt(1 + t * t)
            let s = t * c

            for k in 0..<n where k != p && k != q {
                let akp = a[k][p]
                let akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[p][k] = a[k][p]
                a[k][q] = s * akp + c * akq
                a[q][k] = a[k][q]
            }

            a[p][p] = c * c * app - 2 * s * c * apq + s * s * aqq
            a[q][q] = s * s * app + 2 * s * c * apq + c * c * aqq
            a[p][q] = 0
            a[q][p] = 0

            for k in 0..<n {
                let vkp = v[k][p]
                let vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }

        return ((0..<n).map { a[$0][$0] }, v)
    }

    private static func identity(_ n: Int) -> [[Double]] {
        (0..<n).map { row in
            (0..<n).map { column in row == column ? 1.0 : 0.0 }
        }
    }
}
