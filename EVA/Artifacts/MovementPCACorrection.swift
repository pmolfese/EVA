//
//  MovementPCACorrection.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  MAAC-3 movement-artifact correction: temporal PCA followed by a Promax
//  oblique rotation, fitted independently to each epoch. Continuous recordings
//  use fixed, non-overlapping windows; segmented recordings use their stored
//  epoch boundaries. Factors whose channel-wise back-projection exceeds the
//  configured peak-to-peak threshold are subtracted.
//
//  The PCA/rotation implementation follows the equations described by Kaiser
//  (1958), Hendrickson & White (1964), Dien (2010), and Dien (2024). Its compact
//  Accelerate implementation adapts the behavior of the author's DENNIS PCA
//  routines while using a thin SVD so one-second epochs at
//  high sample rates never require a time×time covariance matrix.
//

import Accelerate
import Foundation

nonisolated enum MovementPCARangeMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic = "Automatic"
    case continuousWindows = "Fixed continuous windows"
    case epochSegments = "Recorded epoch boundaries"

    var id: String { rawValue }
}

nonisolated struct MovementPCAConfiguration: Codable, Sendable, Equatable {
    var rangeMode: MovementPCARangeMode = .automatic
    var continuousWindowSeconds: Double = 1
    var amplitudeThresholdMicrovolts: Double = 200
    var promaxPower: Double = 3
    var maximumFactorCount: Int = 8
    var seed: UInt64 = 0

    static let `default` = MovementPCAConfiguration()
}

nonisolated struct MovementPCAFactorDiagnostic: Sendable, Equatable {
    let factorIndex: Int
    let peakToPeakMicrovolts: Double
    let removed: Bool
}

nonisolated struct MovementPCAEpochDiagnostic: Sendable, Equatable {
    let sampleRange: Range<Int>
    let usableChannelCount: Int
    let retainedFactorCount: Int
    let factors: [MovementPCAFactorDiagnostic]
    let skippedReason: String?

    var removedFactorCount: Int { factors.count(where: \.removed) }
}

nonisolated struct MovementPCADiagnostics: Sendable, Equatable {
    let requestedMode: MovementPCARangeMode
    let resolvedMode: MovementPCARangeMode
    let epochs: [MovementPCAEpochDiagnostic]

    var analyzedEpochCount: Int { epochs.count(where: { $0.skippedReason == nil }) }
    var skippedEpochCount: Int { epochs.count - analyzedEpochCount }
    var removedFactorCount: Int { epochs.reduce(0) { $0 + $1.removedFactorCount } }
    var affectedEpochCount: Int { epochs.count(where: { $0.removedFactorCount > 0 }) }
}

nonisolated struct MovementPCACorrectionResult: Sendable {
    let correctedData: [[Float]]
    let diagnostics: MovementPCADiagnostics
}

nonisolated struct MovementPCAProgress: Sendable, Equatable {
    enum Phase: String, Sendable {
        case preparing = "Preparing analysis ranges"
        case decomposing = "Temporal PCA + Promax"
        case assembling = "Assembling ordered results"
        case complete = "MAAC-3 analysis complete"
    }

    let phase: Phase
    let completedRangeCount: Int
    let totalRangeCount: Int
    let completedSampleCount: Int
    let totalSampleCount: Int
    let affectedRangeCount: Int
    let skippedRangeCount: Int
    let removedFactorCount: Int
    let workerCount: Int
    let elapsedSeconds: Double

    var fraction: Double {
        switch phase {
        case .preparing:
            return 0.02
        case .decomposing:
            let workFraction = Double(completedSampleCount) / Double(max(totalSampleCount, 1))
            return min(max(0.05 + 0.90 * workFraction, 0.05), 0.95)
        case .assembling:
            return 0.98
        case .complete:
            return 1
        }
    }

    var rangesPerSecond: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return Double(completedRangeCount) / elapsedSeconds
    }

    var estimatedSecondsRemaining: Double? {
        guard completedSampleCount > 0,
              completedSampleCount < totalSampleCount,
              elapsedSeconds > 0 else { return nil }
        let samplesPerSecond = Double(completedSampleCount) / elapsedSeconds
        guard samplesPerSecond > 0 else { return nil }
        return Double(totalSampleCount - completedSampleCount) / samplesPerSecond
    }
}

/// Converts the ranges MAAC-3 identified into ordinary duration-bearing EVA
/// artifact events. Detection and correction intentionally remain separate:
/// these markers are reviewable/rejectable metadata, while Clean Artifacts
/// reruns the saved PCA configuration only after the user asks it to.
nonisolated enum MovementPCAArtifactMarkerBuilder {
    static let eventCode = "MOV"
    static let sourceFile = "MAAC-3 Movement PCA"

    static func events(
        from diagnostics: MovementPCADiagnostics,
        samplingRate: Double
    ) -> [MFFEvent] {
        guard samplingRate.isFinite, samplingRate > 0 else { return [] }
        return diagnostics.epochs.enumerated().compactMap { index, epoch in
            guard epoch.removedFactorCount > 0 else { return nil }
            let onset = Double(epoch.sampleRange.lowerBound) / samplingRate
            let duration = Double(epoch.sampleRange.count) / samplingRate
            let peak = epoch.factors.filter(\.removed).map(\.peakToPeakMicrovolts).max() ?? 0
            return MFFEvent(
                id: "maac-movement-\(index)-\(epoch.sampleRange.lowerBound)-\(epoch.sampleRange.upperBound)",
                code: eventCode,
                label: "MAAC Movement",
                eventDescription: String(
                    format: "%d PCA factor(s) above threshold; largest back-projection %.1f µV peak-to-peak",
                    epoch.removedFactorCount,
                    peak
                ),
                beginTimeSeconds: onset,
                rawBeginTime: String(format: "%.6f", onset),
                sourceFile: sourceFile,
                durationSeconds: duration,
                timeAnchor: .onset
            )
        }
    }
}

nonisolated enum MovementPCACorrectionError: Error, LocalizedError, Equatable {
    case invalidSignal
    case invalidSamplingRate
    case invalidConfiguration
    case noEpochSegments

    var errorDescription: String? {
        switch self {
        case .invalidSignal:
            return "MAAC-3 needs a rectangular, non-empty signal."
        case .invalidSamplingRate:
            return "MAAC-3 needs a positive sampling rate."
        case .invalidConfiguration:
            return "MAAC-3 settings must use positive window, threshold, Promax-power, and factor-count values."
        case .noEpochSegments:
            return "Recorded epoch boundaries were requested, but this signal contains no epochs."
        }
    }
}

private nonisolated final class MovementPCAProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let totalRangeCount: Int
    private let totalSampleCount: Int
    private let workerCount: Int
    private let callback: (@Sendable (MovementPCAProgress) -> Void)?
    private let startedAt = Date()
    private var completedRangeCount = 0
    private var completedSampleCount = 0
    private var affectedRangeCount = 0
    private var skippedRangeCount = 0
    private var removedFactorCount = 0

    init(
        totalRangeCount: Int,
        totalSampleCount: Int,
        workerCount: Int,
        callback: (@Sendable (MovementPCAProgress) -> Void)?
    ) {
        self.totalRangeCount = totalRangeCount
        self.totalSampleCount = totalSampleCount
        self.workerCount = workerCount
        self.callback = callback
    }

    func recordCompleted(_ diagnostic: MovementPCAEpochDiagnostic) {
        lock.lock()
        completedRangeCount += 1
        completedSampleCount += diagnostic.sampleRange.count
        if diagnostic.removedFactorCount > 0 { affectedRangeCount += 1 }
        if diagnostic.skippedReason != nil { skippedRangeCount += 1 }
        removedFactorCount += diagnostic.removedFactorCount
        emitLocked(phase: .decomposing)
        lock.unlock()
    }

    func report(phase: MovementPCAProgress.Phase) {
        lock.lock()
        emitLocked(phase: phase)
        lock.unlock()
    }

    private func emitLocked(phase: MovementPCAProgress.Phase) {
        callback?(MovementPCAProgress(
            phase: phase,
            completedRangeCount: completedRangeCount,
            totalRangeCount: totalRangeCount,
            completedSampleCount: completedSampleCount,
            totalSampleCount: totalSampleCount,
            affectedRangeCount: affectedRangeCount,
            skippedRangeCount: skippedRangeCount,
            removedFactorCount: removedFactorCount,
            workerCount: workerCount,
            elapsedSeconds: Date().timeIntervalSince(startedAt)
        ))
    }
}

nonisolated enum MovementPCACorrector {
    private static let minimumEpochSamples = 3

    static func correct(
        data: [[Float]],
        samplingRate: Double,
        epochSegments: [EpochSegment] = [],
        configuration: MovementPCAConfiguration = .default,
        excluding excludedChannels: Set<Int> = [],
        progress: (@Sendable (MovementPCAProgress) -> Void)? = nil
    ) throws -> MovementPCACorrectionResult {
        guard samplingRate.isFinite, samplingRate > 0 else {
            throw MovementPCACorrectionError.invalidSamplingRate
        }
        guard configuration.continuousWindowSeconds.isFinite,
              configuration.continuousWindowSeconds > 0,
              configuration.amplitudeThresholdMicrovolts.isFinite,
              configuration.amplitudeThresholdMicrovolts > 0,
              configuration.promaxPower.isFinite,
              configuration.promaxPower > 0,
              configuration.maximumFactorCount > 0 else {
            throw MovementPCACorrectionError.invalidConfiguration
        }
        guard let sampleCount = data.first?.count,
              sampleCount > 0,
              !data.isEmpty,
              data.allSatisfy({ $0.count == sampleCount }) else {
            throw MovementPCACorrectionError.invalidSignal
        }

        let (resolvedMode, ranges) = try analysisRanges(
            sampleCount: sampleCount,
            samplingRate: samplingRate,
            epochSegments: epochSegments,
            configuration: configuration
        )
        let workerCount = workerCount(for: ranges.count)
        let tracker = MovementPCAProgressTracker(
            totalRangeCount: ranges.count,
            totalSampleCount: ranges.reduce(0) { $0 + $1.count },
            workerCount: workerCount,
            callback: progress
        )
        tracker.report(phase: .preparing)

        var epochResults = [EpochCorrection?](repeating: nil, count: ranges.count)
        epochResults.withUnsafeMutableBufferPointer { output in
            // Every worker writes a distinct slot. The ordered merge below is
            // deliberately serial so overlapping stored epoch ranges retain
            // the same last-range-wins behavior as the original implementation.
            nonisolated(unsafe) let output = output
            evaConcurrentPerform(iterations: ranges.count) { epochIndex in
                guard !Task.isCancelled else { return }
                let result = correctEpoch(
                    original: data,
                    range: ranges[epochIndex],
                    configuration: configuration,
                    excludedChannels: excludedChannels
                )
                output[epochIndex] = result
                tracker.recordCompleted(result.diagnostic)
            }
        }
        if Task.isCancelled { throw CancellationError() }

        tracker.report(phase: .assembling)
        var corrected = data
        var epochDiagnostics: [MovementPCAEpochDiagnostic] = []
        epochDiagnostics.reserveCapacity(ranges.count)

        for result in epochResults.compactMap({ $0 }) {
            for (channel, samples) in result.correctedRows {
                corrected[channel].replaceSubrange(result.diagnostic.sampleRange, with: samples)
            }
            epochDiagnostics.append(result.diagnostic)
        }

        tracker.report(phase: .complete)

        return MovementPCACorrectionResult(
            correctedData: corrected,
            diagnostics: MovementPCADiagnostics(
                requestedMode: configuration.rangeMode,
                resolvedMode: resolvedMode,
                epochs: epochDiagnostics
            )
        )
    }

    static func workerCount(for rangeCount: Int) -> Int {
        min(max(rangeCount, 1), evaMaxWorkers)
    }

    /// Public to the test target so the two range contracts stay pinned without
    /// needing a numerically non-trivial PCA fixture for every boundary case.
    static func analysisRanges(
        sampleCount: Int,
        samplingRate: Double,
        epochSegments: [EpochSegment],
        configuration: MovementPCAConfiguration
    ) throws -> (mode: MovementPCARangeMode, ranges: [Range<Int>]) {
        guard sampleCount > 0 else { throw MovementPCACorrectionError.invalidSignal }
        let resolvedMode: MovementPCARangeMode
        switch configuration.rangeMode {
        case .automatic:
            resolvedMode = epochSegments.isEmpty ? .continuousWindows : .epochSegments
        case .continuousWindows:
            resolvedMode = .continuousWindows
        case .epochSegments:
            guard !epochSegments.isEmpty else { throw MovementPCACorrectionError.noEpochSegments }
            resolvedMode = .epochSegments
        }

        switch resolvedMode {
        case .automatic:
            preconditionFailure("Automatic mode must resolve before ranges are built.")
        case .continuousWindows:
            let windowSamples = max(Int((configuration.continuousWindowSeconds * samplingRate).rounded()), 1)
            var ranges: [Range<Int>] = []
            var start = 0
            while start < sampleCount {
                let end = min(start + windowSamples, sampleCount)
                ranges.append(start..<end)
                start = end
            }
            return (resolvedMode, ranges)
        case .epochSegments:
            let ranges = epochSegments
                .sorted { $0.startSample < $1.startSample }
                .compactMap { segment -> Range<Int>? in
                    let lower = min(max(segment.startSample, 0), sampleCount)
                    let upper = min(max(segment.endSample + 1, lower), sampleCount)
                    return upper > lower ? lower..<upper : nil
                }
            guard !ranges.isEmpty else { throw MovementPCACorrectionError.noEpochSegments }
            return (resolvedMode, ranges)
        }
    }

    private struct EpochCorrection: Sendable {
        let correctedRows: [(Int, [Float])]
        let diagnostic: MovementPCAEpochDiagnostic
    }

    private static func correctEpoch(
        original: [[Float]],
        range: Range<Int>,
        configuration: MovementPCAConfiguration,
        excludedChannels: Set<Int>
    ) -> EpochCorrection {
        guard range.count >= minimumEpochSamples else {
            return skipped(range: range, reason: "fewer than \(minimumEpochSamples) samples")
        }
        let channels = original.indices.filter { channel in
            !excludedChannels.contains(channel)
                && original[channel][range].allSatisfy(\.isFinite)
        }
        guard channels.count >= 3 else {
            return skipped(range: range, usableChannels: channels.count, reason: "fewer than three finite, usable channels")
        }

        let observationCount = channels.count
        let timeCount = range.count
        var means = [Double](repeating: 0, count: timeCount)
        var standardDeviations = [Double](repeating: 0, count: timeCount)
        for time in 0..<timeCount {
            let sample = range.lowerBound + time
            let values = channels.map { Double(original[$0][sample]) }
            let mean = values.reduce(0, +) / Double(observationCount)
            means[time] = mean
            let sumSquares = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            standardDeviations[time] = sqrt(sumSquares / Double(observationCount - 1))
        }
        let scale = standardDeviations.max() ?? 0
        let flatTolerance = max(scale * 1e-12, Double.leastNonzeroMagnitude)
        let activeTimes = (0..<timeCount).filter { standardDeviations[$0] > flatTolerance }
        guard activeTimes.count >= 2 else {
            return skipped(range: range, usableChannels: channels.count, reason: "epoch has no cross-channel variance")
        }

        var rawWork = MovementDenseMatrix(rows: observationCount, cols: activeTimes.count)
        var centeredWork = MovementDenseMatrix(rows: observationCount, cols: activeTimes.count)
        for (row, channel) in channels.enumerated() {
            for (column, time) in activeTimes.enumerated() {
                let sample = range.lowerBound + time
                let value = Double(original[channel][sample])
                rawWork[row, column] = value
                centeredWork[row, column] = value - means[time]
            }
        }

        guard let svd = try? centeredWork.svd(),
              let largestSingular = svd.s.first,
              largestSingular > 0 else {
            return skipped(range: range, usableChannels: channels.count, reason: "PCA decomposition failed")
        }
        let rankTolerance = Double(max(centeredWork.rows, centeredWork.cols)) * Double.ulpOfOne * largestSingular
        let numericalRank = svd.s.count(where: { $0 > rankTolerance })
        let requestedFactorCount = min(configuration.maximumFactorCount, numericalRank)
        guard requestedFactorCount > 0 else {
            return skipped(range: range, usableChannels: channels.count, reason: "epoch has zero numerical rank")
        }

        // A rare ill-conditioned Promax target can lose rank. Reduce the
        // retained subspace one factor at a time rather than silently switching
        // to an orthogonal rotation that no longer implements MAAC-3.
        var decomposition: (pattern: MovementDenseMatrix, scores: MovementDenseMatrix, count: Int)?
        for factorCount in stride(from: requestedFactorCount, through: 1, by: -1) {
            if let fitted = try? fittedFactors(
                scoringWork: rawWork,
                variableSD: activeTimes.map { standardDeviations[$0] },
                svd: svd,
                factorCount: factorCount,
                power: configuration.promaxPower,
                seed: configuration.seed
            ) {
                decomposition = (fitted.pattern, fitted.scores, factorCount)
                break
            }
        }
        guard let decomposition else {
            return skipped(range: range, usableChannels: channels.count, reason: "Promax rotation failed")
        }

        var factorDiagnostics: [MovementPCAFactorDiagnostic] = []
        var removedFactors: [Int] = []
        for factor in 0..<decomposition.count {
            var largestPeakToPeak = 0.0
            for row in 0..<observationCount {
                var minimum = Double.infinity
                var maximum = -Double.infinity
                for column in 0..<activeTimes.count {
                    let value = decomposition.scores[row, factor] * decomposition.pattern[column, factor]
                    minimum = min(minimum, value)
                    maximum = max(maximum, value)
                }
                largestPeakToPeak = max(largestPeakToPeak, maximum - minimum)
            }
            let remove = largestPeakToPeak > configuration.amplitudeThresholdMicrovolts
            factorDiagnostics.append(MovementPCAFactorDiagnostic(
                factorIndex: factor + 1,
                peakToPeakMicrovolts: largestPeakToPeak,
                removed: remove
            ))
            if remove { removedFactors.append(factor) }
        }

        guard !removedFactors.isEmpty else {
            return EpochCorrection(
                correctedRows: [],
                diagnostic: MovementPCAEpochDiagnostic(
                    sampleRange: range,
                    usableChannelCount: channels.count,
                    retainedFactorCount: decomposition.count,
                    factors: factorDiagnostics,
                    skippedReason: nil
                )
            )
        }

        var correctedRows: [(Int, [Float])] = []
        correctedRows.reserveCapacity(channels.count)
        for (row, channel) in channels.enumerated() {
            var samples = Array(original[channel][range])
            for (column, time) in activeTimes.enumerated() {
                var removed = 0.0
                for factor in removedFactors {
                    removed += decomposition.scores[row, factor] * decomposition.pattern[column, factor]
                }
                samples[time] = Float(Double(samples[time]) - removed)
            }
            correctedRows.append((channel, samples))
        }
        return EpochCorrection(
            correctedRows: correctedRows,
            diagnostic: MovementPCAEpochDiagnostic(
                sampleRange: range,
                usableChannelCount: channels.count,
                retainedFactorCount: decomposition.count,
                factors: factorDiagnostics,
                skippedReason: nil
            )
        )
    }

    private static func skipped(
        range: Range<Int>,
        usableChannels: Int = 0,
        reason: String
    ) -> EpochCorrection {
        EpochCorrection(
            correctedRows: [],
            diagnostic: MovementPCAEpochDiagnostic(
                sampleRange: range,
                usableChannelCount: usableChannels,
                retainedFactorCount: 0,
                factors: [],
                skippedReason: reason
            )
        )
    }

    private static func fittedFactors(
        scoringWork: MovementDenseMatrix,
        variableSD: [Double],
        svd: (u: MovementDenseMatrix, s: [Double], vt: MovementDenseMatrix),
        factorCount: Int,
        power: Double,
        seed: UInt64
    ) throws -> (pattern: MovementDenseMatrix, scores: MovementDenseMatrix) {
        let variables = scoringWork.cols
        var loadings = MovementDenseMatrix(rows: variables, cols: factorCount)
        let scoreScale = sqrt(Double(scoringWork.rows - 1))
        for factor in 0..<factorCount {
            let scoreSD = svd.s[factor] / scoreScale
            for variable in 0..<variables {
                loadings[variable, factor] = svd.vt[factor, variable] * scoreSD / variableSD[variable]
            }
        }

        let communalities = (0..<variables).map { variable in
            (0..<factorCount).reduce(0.0) { $0 + loadings[variable, $1] * loadings[variable, $1] }
        }
        for variable in 0..<variables {
            let norm = sqrt(communalities[variable])
            if norm > 0 {
                for factor in 0..<factorCount { loadings[variable, factor] /= norm }
            }
        }

        let varimax = MovementPCARotations.varimax(loadings, seed: seed)
        var pattern = try MovementPCARotations.promax(varimax, power: power)
        // Undo Kaiser normalization and convert the temporal pattern directly
        // into microvolts. Each factor's channel score is dimensionless.
        for variable in 0..<variables {
            let undoKaiser = sqrt(communalities[variable]) * variableSD[variable]
            for factor in 0..<factorCount { pattern[variable, factor] *= undoKaiser }
        }

        let coefficients = try pattern.pseudoinverse().transposed()
        var scores = scoringWork.multiply(coefficients)
        for factor in 0..<factorCount {
            let values = scores.column(factor)
            let mean = values.reduce(0, +) / Double(values.count)
            let sumSquares = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            let sd = sqrt(sumSquares / Double(max(values.count - 1, 1)))
            guard sd.isFinite, sd > 0 else { throw MovementDenseMatrix.Error.singular }
            for row in 0..<scores.rows { scores[row, factor] /= sd }
        }
        return (pattern, scores)
    }
}

// MARK: - Compact dense linear algebra

/// Column-major storage keeps the SVD/solve paths native to Accelerate and
/// avoids adding a second app-wide matrix abstraction for one bounded engine.
private nonisolated struct MovementDenseMatrix {
    enum Error: Swift.Error { case decomposition(Int), solve(Int), singular }

    let rows: Int
    let cols: Int
    var grid: [Double]

    init(rows: Int, cols: Int, repeating value: Double = 0) {
        self.rows = rows
        self.cols = cols
        grid = [Double](repeating: value, count: rows * cols)
    }

    init(rows: Int, cols: Int, columnMajor: [Double]) {
        precondition(columnMajor.count == rows * cols)
        self.rows = rows
        self.cols = cols
        grid = columnMajor
    }

    subscript(_ row: Int, _ column: Int) -> Double {
        get { grid[column * rows + row] }
        set { grid[column * rows + row] = newValue }
    }

    func column(_ column: Int) -> [Double] {
        Array(grid[(column * rows)..<((column + 1) * rows)])
    }

    func settingColumn(_ column: Int, to values: [Double]) -> Self {
        var result = self
        for row in 0..<rows { result[row, column] = values[row] }
        return result
    }

    func transposed() -> Self {
        var result = Self(rows: cols, cols: rows)
        for column in 0..<cols {
            for row in 0..<rows { result[column, row] = self[row, column] }
        }
        return result
    }

    func multiply(_ other: Self) -> Self {
        precondition(cols == other.rows)
        var result = Self(rows: rows, cols: other.cols)
        cblas_dgemm(
            CblasColMajor, CblasNoTrans, CblasNoTrans,
            Int32(rows), Int32(other.cols), Int32(cols),
            1, grid, Int32(rows), other.grid, Int32(other.rows),
            0, &result.grid, Int32(rows)
        )
        return result
    }

    static func identity(_ size: Int) -> Self {
        var result = Self(rows: size, cols: size)
        for index in 0..<size { result[index, index] = 1 }
        return result
    }

    func solve(_ rightHandSide: Self) throws -> Self {
        guard rows == cols, rightHandSide.rows == rows else { throw Error.singular }
        var matrix = grid
        var solution = rightHandSide.grid
        var dimension = LAPACKInt(rows)
        var rightHandSideCount = LAPACKInt(rightHandSide.cols)
        var leadingDimension = dimension
        var pivot = [LAPACKInt](repeating: 0, count: rows)
        var info = LAPACKInt(0)
        dgesv_(
            &dimension, &rightHandSideCount, &matrix, &leadingDimension,
            &pivot, &solution, &leadingDimension, &info
        )
        guard info == 0 else { throw Error.solve(Int(info)) }
        return Self(rows: rows, cols: rightHandSide.cols, columnMajor: solution)
    }

    func inverse() throws -> Self { try solve(.identity(rows)) }

    func svd() throws -> (u: Self, s: [Double], vt: Self) {
        let minimum = min(rows, cols)
        var matrix = grid
        var singularValues = [Double](repeating: 0, count: minimum)
        var u = [Double](repeating: 0, count: rows * minimum)
        var vt = [Double](repeating: 0, count: minimum * cols)
        var jobU: CChar = 83
        var jobVT: CChar = 83
        var rowCount = LAPACKInt(rows)
        var columnCount = LAPACKInt(cols)
        var leadingA = rowCount
        var leadingU = rowCount
        var leadingVT = LAPACKInt(minimum)
        var info = LAPACKInt(0)
        var workQuery = 0.0
        var workCount = LAPACKInt(-1)
        dgesvd_(
            &jobU, &jobVT, &rowCount, &columnCount, &matrix, &leadingA,
            &singularValues, &u, &leadingU, &vt, &leadingVT,
            &workQuery, &workCount, &info
        )
        guard info == 0 else { throw Error.decomposition(Int(info)) }
        workCount = max(LAPACKInt(workQuery.rounded(.up)), 1)
        var work = [Double](repeating: 0, count: Int(workCount))
        dgesvd_(
            &jobU, &jobVT, &rowCount, &columnCount, &matrix, &leadingA,
            &singularValues, &u, &leadingU, &vt, &leadingVT,
            &work, &workCount, &info
        )
        guard info == 0 else { throw Error.decomposition(Int(info)) }
        return (
            Self(rows: rows, cols: minimum, columnMajor: u),
            singularValues,
            Self(rows: minimum, cols: cols, columnMajor: vt)
        )
    }

    func pseudoinverse(relativeTolerance: Double = 1e-12) throws -> Self {
        let (u, singularValues, vt) = try svd()
        let cutoff = relativeTolerance * Double(max(rows, cols)) * (singularValues.first ?? 0)
        let inverseValues = singularValues.map { $0 > cutoff ? 1 / $0 : 0 }
        guard inverseValues.contains(where: { $0 > 0 }) else { throw Error.singular }
        var vScaled = vt.transposed()
        for column in 0..<vScaled.cols {
            for row in 0..<vScaled.rows { vScaled[row, column] *= inverseValues[column] }
        }
        return vScaled.multiply(u.transposed())
    }
}

private nonisolated enum MovementPCARotations {
    static func varimax(
        _ loadings: MovementDenseMatrix,
        restartCount: Int = 10,
        maximumIterations: Int = 1_000,
        tolerance: Double = 1e-5,
        seed: UInt64
    ) -> MovementDenseMatrix {
        let variableCount = loadings.rows
        let factorCount = loadings.cols
        guard factorCount > 1 else { return loadings }
        var generator = MovementSplitMix64(seed: seed)
        var best = loadings
        var bestCriterion = -Double.infinity

        for _ in 0..<restartCount {
            let start = loadings.multiply(randomOrthogonal(factorCount, generator: &generator))
            let candidate = varimaxSweep(
                start,
                variableCount: variableCount,
                factorCount: factorCount,
                maximumIterations: maximumIterations,
                tolerance: tolerance
            )
            let value = criterion(candidate)
            if value > bestCriterion {
                bestCriterion = value
                best = candidate
            }
        }
        return best
    }

    static func promax(_ varimaxLoadings: MovementDenseMatrix, power: Double) throws -> MovementDenseMatrix {
        guard varimaxLoadings.cols > 1 else { return varimaxLoadings }
        let factorCount = varimaxLoadings.cols
        var target = rowNormalized(varimaxLoadings)
        for factor in 0..<factorCount {
            let maximum = (0..<target.rows).map { abs(target[$0, factor]) }.max() ?? 0
            if maximum > 0 {
                for row in 0..<target.rows { target[row, factor] /= maximum }
            }
        }
        for factor in 0..<factorCount {
            for row in 0..<target.rows {
                let sign = varimaxLoadings[row, factor].sign == .minus ? -1.0 : 1.0
                target[row, factor] = sign * pow(abs(target[row, factor]), power)
            }
        }

        let transpose = varimaxLoadings.transposed()
        var transform = try transpose.multiply(varimaxLoadings)
            .solve(transpose.multiply(target))
        for factor in 0..<factorCount {
            let norm = sqrt((0..<transform.rows).reduce(0) {
                $0 + transform[$1, factor] * transform[$1, factor]
            })
            guard norm.isFinite, norm > 0 else { throw MovementDenseMatrix.Error.singular }
            for row in 0..<transform.rows { transform[row, factor] /= norm }
        }

        let inversePsi = try transform.transposed().multiply(transform).inverse()
        for factor in 0..<factorCount {
            let diagonal = inversePsi[factor, factor]
            guard diagonal.isFinite, diagonal > 0 else { throw MovementDenseMatrix.Error.singular }
            let scale = sqrt(diagonal)
            for row in 0..<transform.rows { transform[row, factor] *= scale }
        }
        return varimaxLoadings.multiply(transform)
    }

    private static func varimaxSweep(
        _ start: MovementDenseMatrix,
        variableCount: Int,
        factorCount: Int,
        maximumIterations: Int,
        tolerance: Double
    ) -> MovementDenseMatrix {
        var rotated = start
        let pairCount = factorCount * (factorCount - 1) / 2
        var unchangedPairs = pairCount
        var iteration = 0
        while unchangedPairs > 0, iteration < maximumIterations {
            for first in 0..<(factorCount - 1) {
                for second in (first + 1)..<factorCount {
                    let firstColumn = rotated.column(first)
                    let secondColumn = rotated.column(second)
                    var a = 0.0, b = 0.0, c = 0.0, d = 0.0
                    for row in 0..<variableCount {
                        let u = firstColumn[row] * firstColumn[row] - secondColumn[row] * secondColumn[row]
                        let v = 2 * firstColumn[row] * secondColumn[row]
                        a += u
                        b += v
                        c += u * u - v * v
                        d += 2 * u * v
                    }
                    let numerator = d - 2 * a * b / Double(variableCount)
                    let denominator = c - (a * a - b * b) / Double(variableCount)
                    if denominator != 0, abs(numerator / denominator) > tolerance {
                        let magnitude = hypot(numerator, denominator)
                        let cosine4 = denominator / magnitude
                        let cosine2 = sqrt(max((1 + cosine4) / 2, 0))
                        let cosine = sqrt(max((1 + cosine2) / 2, 0))
                        let sineMagnitude = sqrt(max((1 - cosine2) / 2, 0))
                        let sine = numerator < 0 ? -sineMagnitude : sineMagnitude
                        var newFirst = firstColumn
                        var newSecond = secondColumn
                        for row in 0..<variableCount {
                            newFirst[row] = firstColumn[row] * cosine + secondColumn[row] * sine
                            newSecond[row] = -firstColumn[row] * sine + secondColumn[row] * cosine
                        }
                        rotated = rotated.settingColumn(first, to: newFirst)
                            .settingColumn(second, to: newSecond)
                        unchangedPairs = pairCount
                    } else {
                        unchangedPairs -= 1
                    }
                }
            }
            iteration += 1
        }
        return rotated
    }

    private static func criterion(_ matrix: MovementDenseMatrix) -> Double {
        guard matrix.cols > 1 else { return 0 }
        var result = 0.0
        for row in 0..<matrix.rows {
            let squares = (0..<matrix.cols).map { matrix[row, $0] * matrix[row, $0] }
            let mean = squares.reduce(0, +) / Double(squares.count)
            result += squares.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                / Double(squares.count - 1)
        }
        return result
    }

    private static func rowNormalized(_ matrix: MovementDenseMatrix) -> MovementDenseMatrix {
        var result = matrix
        for row in 0..<matrix.rows {
            let norm = sqrt((0..<matrix.cols).reduce(0) {
                $0 + matrix[row, $1] * matrix[row, $1]
            })
            if norm > 0 {
                for column in 0..<matrix.cols { result[row, column] /= norm }
            }
        }
        return result
    }

    private static func randomOrthogonal(
        _ size: Int,
        generator: inout MovementSplitMix64
    ) -> MovementDenseMatrix {
        var result = MovementDenseMatrix.identity(size)
        guard size > 1 else { return result }
        for first in 0..<(size - 1) {
            for second in (first + 1)..<size {
                let angle = generator.nextUnit() * 2 * Double.pi
                let cosine = cos(angle)
                let sine = sin(angle)
                let firstColumn = result.column(first)
                let secondColumn = result.column(second)
                var newFirst = firstColumn
                var newSecond = secondColumn
                for row in 0..<size {
                    newFirst[row] = cosine * firstColumn[row] - sine * secondColumn[row]
                    newSecond[row] = sine * firstColumn[row] + cosine * secondColumn[row]
                }
                result = result.settingColumn(first, to: newFirst)
                    .settingColumn(second, to: newSecond)
            }
        }
        return result
    }
}

private nonisolated struct MovementSplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1 / 9_007_199_254_740_992.0)
    }
}
