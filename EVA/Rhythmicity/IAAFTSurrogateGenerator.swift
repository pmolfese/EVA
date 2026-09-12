//
//  IAAFTSurrogateGenerator.swift
//  EVA
//
//  Independently implemented from the published IAAFT algorithm. No upstream
//  MATLAB or Python source is incorporated in this file.
//

import Foundation

nonisolated struct IAAFTSurrogate: Sendable, Equatable {
    var values: [Double]
    var diagnostics: IAAFTSurrogateDiagnostics
}

/// Immutable transform/rank workspace reusable across the 200 shuffles for a
/// signal run. This avoids rebuilding FFT plans and Bluestein chirps per draw.
nonisolated final class IAAFTWorkspace: @unchecked Sendable {
    fileprivate let targetFourierMagnitudes: [Double]
    fileprivate let sortedValues: [Double]
    fileprivate let standardDeviation: Double
    fileprivate let plan: RhythmicityDFTPlan

    fileprivate init(
        targetFourierMagnitudes: [Double],
        sortedValues: [Double],
        standardDeviation: Double,
        plan: RhythmicityDFTPlan
    ) {
        self.targetFourierMagnitudes = targetFourierMagnitudes
        self.sortedValues = sortedValues
        self.standardDeviation = standardDeviation
        self.plan = plan
    }
}

nonisolated enum IAAFTError: Error, Sendable, Equatable, LocalizedError {
    case emptyValues
    case magnitudeCountMismatch(expected: Int, actual: Int)
    case invalidMagnitude(index: Int, value: Double)
    case invalidConfiguration(String)
    case zeroVariance

    var errorDescription: String? {
        switch self {
        case .emptyValues: return "IAAFT requires a nonempty amplitude distribution."
        case let .magnitudeCountMismatch(expected, actual):
            return "IAAFT received \(actual) Fourier magnitudes; expected \(expected)."
        case let .invalidMagnitude(index, value):
            return "IAAFT target magnitude \(index) is invalid: \(value)."
        case let .invalidConfiguration(message): return "Invalid IAAFT configuration: \(message)"
        case .zeroVariance: return "IAAFT requires a finite, nonconstant amplitude distribution."
        }
    }
}

nonisolated enum IAAFTSurrogateGenerator {
    static func prepare(
        targetFourierMagnitudes: [Double],
        sortedValues: [Double]
    ) throws -> IAAFTWorkspace {
        guard !sortedValues.isEmpty else { throw IAAFTError.emptyValues }
        guard targetFourierMagnitudes.count == sortedValues.count else {
            throw IAAFTError.magnitudeCountMismatch(
                expected: sortedValues.count,
                actual: targetFourierMagnitudes.count
            )
        }
        for index in targetFourierMagnitudes.indices {
            let value = targetFourierMagnitudes[index]
            guard value.isFinite, value >= 0 else {
                throw IAAFTError.invalidMagnitude(index: index, value: value)
            }
        }
        guard sortedValues.allSatisfy(\.isFinite) else {
            throw IAAFTError.invalidConfiguration("amplitude values must all be finite")
        }
        let ordered = sortedValues.sorted()
        let mean = ordered.reduce(0, +) / Double(ordered.count)
        let variance = ordered.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(ordered.count)
        let standardDeviation = sqrt(variance)
        guard standardDeviation.isFinite, standardDeviation > 0 else {
            throw IAAFTError.zeroVariance
        }
        return try IAAFTWorkspace(
            targetFourierMagnitudes: targetFourierMagnitudes,
            sortedValues: ordered,
            standardDeviation: standardDeviation,
            plan: RhythmicityDFTPlan(count: ordered.count)
        )
    }

    static func generate(
        targetFourierMagnitudes: [Double],
        sortedValues: [Double],
        seed: UInt64,
        configuration: IAAFTConfiguration = .paper2026,
        cancellation: RhythmicityCancellation = RhythmicityCancellation()
    ) throws -> IAAFTSurrogate {
        let workspace = try prepare(
            targetFourierMagnitudes: targetFourierMagnitudes,
            sortedValues: sortedValues
        )
        return try generate(
            workspace: workspace,
            seed: seed,
            configuration: configuration,
            cancellation: cancellation
        )
    }

    static func generate(
        workspace: IAAFTWorkspace,
        seed: UInt64,
        configuration: IAAFTConfiguration = .paper2026,
        cancellation: RhythmicityCancellation = RhythmicityCancellation(),
        progress: (@Sendable (_ iteration: Int, _ maximumIterations: Int) -> Void)? = nil
    ) throws -> IAAFTSurrogate {
        guard configuration.errorThreshold.isFinite, configuration.errorThreshold > 0 else {
            throw IAAFTError.invalidConfiguration("error threshold must be finite and positive")
        }
        guard configuration.speedThreshold.isFinite, configuration.speedThreshold >= 0 else {
            throw IAAFTError.invalidConfiguration("speed threshold must be finite and nonnegative")
        }
        guard configuration.maximumIterations > 0 else {
            throw IAAFTError.invalidConfiguration("maximum iterations must be positive")
        }
        try cancellation.check()
        var random = RhythmicityRandomNumberGenerator(seed: seed)
        var candidate = workspace.sortedValues
        if candidate.count > 1 {
            for index in stride(from: candidate.count - 1, through: 1, by: -1) {
                let swapIndex = Int(random.next() % UInt64(index + 1))
                candidate.swapAt(index, swapIndex)
            }
        }

        var previousTotalError = Double.infinity
        var amplitudeError = Double.infinity
        var spectralError = Double.infinity
        var status = IAAFTConvergenceStatus.iterationLimit
        var iterations = 0

        for iteration in 1...configuration.maximumIterations {
            if iteration == 1 || iteration & 0x07 == 0 {
                try cancellation.check()
            }
            if iteration == 1 || iteration & 0x1f == 0 {
                progress?(iteration, configuration.maximumIterations)
            }
            iterations = iteration
            let transformed = workspace.plan.forward(candidate)
            var constrainedReal = [Double](repeating: 0, count: candidate.count)
            var constrainedImaginary = [Double](repeating: 0, count: candidate.count)
            for index in candidate.indices {
                let magnitude = hypot(transformed.real[index], transformed.imaginary[index])
                if magnitude > Double.leastNonzeroMagnitude {
                    let scale = workspace.targetFourierMagnitudes[index] / magnitude
                    constrainedReal[index] = transformed.real[index] * scale
                    constrainedImaginary[index] = transformed.imaginary[index] * scale
                } else {
                    constrainedReal[index] = workspace.targetFourierMagnitudes[index]
                }
            }
            let spectrallyAdjusted = workspace.plan.inverse(
                real: constrainedReal,
                imaginary: constrainedImaginary
            )
            spectralError = normalizedMeanAbsoluteDifference(
                spectrallyAdjusted,
                candidate,
                scale: workspace.standardDeviation
            )
            let next = rankMap(spectrallyAdjusted, onto: workspace.sortedValues)
            amplitudeError = normalizedMeanAbsoluteDifference(
                next,
                spectrallyAdjusted,
                scale: workspace.standardDeviation
            )
            candidate = next

            let totalError = spectralError + amplitudeError
            if spectralError <= configuration.errorThreshold,
               amplitudeError <= configuration.errorThreshold {
                status = .converged
                break
            }
            if previousTotalError.isFinite {
                let speed = abs(previousTotalError - totalError) / max(totalError, Double.leastNonzeroMagnitude)
                if speed <= configuration.speedThreshold {
                    status = .stalled
                    break
                }
            }
            previousTotalError = totalError
        }
        progress?(iterations, configuration.maximumIterations)
        return IAAFTSurrogate(
            values: candidate,
            diagnostics: IAAFTSurrogateDiagnostics(
                seed: seed,
                iterations: iterations,
                amplitudeError: amplitudeError,
                spectralError: spectralError,
                status: status
            )
        )
    }

    private static func rankMap(_ values: [Double], onto sortedValues: [Double]) -> [Double] {
        let order = values.indices.sorted { left, right in
            values[left] == values[right] ? left < right : values[left] < values[right]
        }
        var output = [Double](repeating: 0, count: values.count)
        for rank in order.indices { output[order[rank]] = sortedValues[rank] }
        return output
    }

    private static func normalizedMeanAbsoluteDifference(
        _ left: [Double],
        _ right: [Double],
        scale: Double
    ) -> Double {
        zip(left, right).reduce(0.0) { $0 + abs($1.0 - $1.1) }
            / (Double(left.count) * scale)
    }
}

/// SplitMix64 is small, stable across platforms, and sufficient for deriving
/// reproducible surrogate shuffles. It is not used for cryptography.
nonisolated struct RhythmicityRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
}

nonisolated enum RhythmicitySeed {
    static func derived(from base: UInt64, channel: Int, surrogate: Int, run: Int) -> UInt64 {
        var generator = RhythmicityRandomNumberGenerator(
            seed: base
                ^ UInt64(truncatingIfNeeded: channel) &* 0x9e37_79b9_7f4a_7c15
                ^ UInt64(truncatingIfNeeded: surrogate + 1) &* 0xbf58_476d_1ce4_e5b9
                ^ UInt64(truncatingIfNeeded: run + 1) &* 0x94d0_49bb_1331_11eb
        )
        return generator.next()
    }
}
