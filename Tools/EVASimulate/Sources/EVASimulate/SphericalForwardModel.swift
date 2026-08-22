//
//  SphericalForwardModel.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Concentric-sphere EEG forward model. The implementation follows the
//  spherical-harmonic formulation and iterative shell recurrence described by
//  Bruña, Fuggetta & Pereda (2023), written independently from the published
//  equations. No implementation from their GPL reference code is copied here.
//

import Foundation

nonisolated struct Vector3D: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = Vector3D(x: 0, y: 0, z: 0)

    static func + (lhs: Vector3D, rhs: Vector3D) -> Vector3D {
        Vector3D(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    static func - (lhs: Vector3D, rhs: Vector3D) -> Vector3D {
        Vector3D(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    static prefix func - (value: Vector3D) -> Vector3D {
        Vector3D(x: -value.x, y: -value.y, z: -value.z)
    }

    static func * (lhs: Vector3D, rhs: Double) -> Vector3D {
        Vector3D(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    func dot(_ other: Vector3D) -> Double { x * other.x + y * other.y + z * other.z }

    func cross(_ other: Vector3D) -> Vector3D {
        Vector3D(
            x: y * other.z - z * other.y,
            y: z * other.x - x * other.z,
            z: x * other.y - y * other.x
        )
    }

    var norm: Double { dot(self).squareRoot() }

    func normalized() -> Vector3D {
        let length = norm
        return length > 1e-15 ? self * (1 / length) : .zero
    }


    func rotated(around rawAxis: Vector3D, radians: Double) -> Vector3D {
        let axis = rawAxis.normalized()
        guard axis.norm > 0 else { return self }
        let cosine = cos(radians)
        let sine = sin(radians)
        return self * cosine
            + axis.cross(self) * sine
            + axis * (axis.dot(self) * (1 - cosine))
    }
}

nonisolated struct HeadShell: Codable, Sendable, Equatable {
    var name: String
    var radiusMeters: Double
    var conductivitySiemensPerMeter: Double
}

nonisolated struct SphericalHeadModel: Codable, Sendable, Equatable {
    var name: String
    var centerMeters: Vector3D
    /// Innermost to outermost. A source must lie inside the first shell.
    var shells: [HeadShell]

    /// Classic brain/skull/scalp model used in three-sphere validation studies:
    /// 72/79/85 mm and 0.33/0.0042/0.33 S/m.
    static let classicThreeShell = SphericalHeadModel(
        name: "Classic three-shell sphere",
        centerMeters: .zero,
        shells: [
            HeadShell(name: "brain", radiusMeters: 0.072, conductivitySiemensPerMeter: 0.33),
            HeadShell(name: "skull", radiusMeters: 0.079, conductivitySiemensPerMeter: 0.0042),
            HeadShell(name: "scalp", radiusMeters: 0.085, conductivitySiemensPerMeter: 0.33)
        ]
    )

    var brainRadiusMeters: Double { shells.first?.radiusMeters ?? 0 }
    var scalpRadiusMeters: Double { shells.last?.radiusMeters ?? 0 }

    func validationError() -> String? {
        guard !shells.isEmpty else { return "head model needs at least one shell" }
        var previousRadius = 0.0
        for shell in shells {
            guard shell.radiusMeters > previousRadius else {
                return "head-shell radii must increase from brain to scalp"
            }
            guard shell.conductivitySiemensPerMeter > 0 else {
                return "head-shell conductivities must be positive"
            }
            previousRadius = shell.radiusMeters
        }
        return nil
    }
}

nonisolated enum EEGReference: String, Codable, Sendable {
    case average
    case infinity
}

/// Applies the recording reference once to a complete additive sensor-space
/// mixture. Recording defects are intentionally applied afterward because a
/// bad physical reference, bridge, or clipped amplifier can break the nominal
/// reference of the underlying voltages.
nonisolated enum EEGReferencing {
    static func apply(_ reference: EEGReference, to channels: inout [[Double]]) {
        guard reference == .average, !channels.isEmpty else { return }
        let sampleCount = channels.map(\.count).min() ?? 0
        guard sampleCount > 0 else { return }
        for sample in 0..<sampleCount {
            let mean = channels.reduce(0.0) { $0 + $1[sample] } / Double(channels.count)
            for channel in channels.indices { channels[channel][sample] -= mean }
        }
    }

    static func maximumAbsoluteMean(_ channels: [[Double]]) -> Double {
        guard !channels.isEmpty else { return 0 }
        let sampleCount = channels.map(\.count).min() ?? 0
        var maximum = 0.0
        for sample in 0..<sampleCount {
            let mean = channels.reduce(0.0) { $0 + $1[sample] } / Double(channels.count)
            maximum = max(maximum, abs(mean))
        }
        return maximum
    }
}

nonisolated struct SimulatedSource: Codable, Sendable, Equatable {
    var id: String
    var positionMeters: Vector3D
    /// Unit vector in the same +x right, +y anterior, +z vertex frame as Montage.
    var orientation: Vector3D
    var bandName: String
    var seed: UInt64
    /// RMS after calibration to the requested sensor-space EEG standard deviation.
    var rmsMomentNanoampereMeters: Double
    /// Human-readable declaration of a deliberately difficult scenario.
    var scenarioRole: String? = nil
}

nonisolated struct SourceMotionTruth: Codable, Sendable {
    var sourceID: String
    var startTimeSeconds: Double
    var endTimeSeconds: Double
    var endPositionMeters: Vector3D
    var endOrientation: Vector3D
    /// One-source endpoint operator, including free x/y/z columns.
    var endLeadField: LeadField
}

nonisolated struct LeadField: Codable, Sendable {
    var channelNames: [String]
    var sourceIDs: [String]
    var reference: EEGReference
    /// channels x (3 * sources), with x/y/z columns for each source. Keeping
    /// this free-orientation operator makes later inverse-method scoring
    /// possible without rerunning the forward model.
    var freeOrientationMatrixMicrovoltsPerNanoampereMeter: [[Double]]
    /// channels x sources, in µV / (nA·m), after orientation projection.
    var matrixMicrovoltsPerNanoampereMeter: [[Double]]
}

/// Numerical convergence diagnostic for the truncated spherical-harmonic
/// series. Relative changes use complete free-orientation columns, avoiding
/// unstable element-wise ratios at electrodes where the true gain is near zero.
nonisolated struct LeadFieldConvergenceReport: Sendable {
    var terms: Int
    var comparisonTerms: Int
    var tolerance: Double
    var maximumRelativeColumnChange: Double
    var rootMeanSquareRelativeChange: Double
    var worstSourceID: String?
    var worstOrientationAxis: String?

    var converged: Bool { maximumRelativeColumnChange <= tolerance }
}

nonisolated enum SphericalForwardError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return "Invalid spherical forward model: \(message)"
        }
    }
}

nonisolated enum SphericalForwardModel {
    /// A 0.01% maximum relative change in every free-orientation column is
    /// strict enough that truncation is negligible relative to model error.
    static let defaultConvergenceTolerance = 1e-4

    /// Computes the oriented gain matrix once. Sensor positions are projected
    /// onto the outer shell because the current Montage is angular geometry on
    /// a unit sphere; the physical radius belongs to the head model.
    static func leadField(
        head: SphericalHeadModel,
        montage: Montage,
        sources: [SimulatedSource],
        reference: EEGReference,
        terms: Int
    ) throws -> LeadField {
        if let error = head.validationError() { throw SphericalForwardError.invalid(error) }
        guard terms >= 1 else { throw SphericalForwardError.invalid("series needs at least one term") }

        let electrodes = montage.positions.map {
            Vector3D(x: $0.x, y: $0.y, z: $0.z) * head.scalpRadiusMeters + head.centerMeters
        }
        let transfers = (1...terms).map { surfaceTransfer(order: $0, head: head) }
        var freeMatrix = [[Double]](
            repeating: [Double](repeating: 0, count: 3 * sources.count),
            count: electrodes.count
        )

        for (sourceIndex, source) in sources.enumerated() {
            let relativePosition = source.positionMeters - head.centerMeters
            guard relativePosition.norm < head.brainRadiusMeters else {
                throw SphericalForwardError.invalid("source \(source.id) is not inside the brain shell")
            }
            guard abs(source.orientation.norm - 1) < 1e-8 else {
                throw SphericalForwardError.invalid("source \(source.id) orientation is not a unit vector")
            }
            let bases = [
                Vector3D(x: 1, y: 0, z: 0),
                Vector3D(x: 0, y: 1, z: 0),
                Vector3D(x: 0, y: 0, z: 1)
            ]
            for (axis, basis) in bases.enumerated() {
                for (channel, electrode) in electrodes.enumerated() {
                    freeMatrix[channel][3 * sourceIndex + axis] = potentialPerUnitMoment(
                        sourcePosition: relativePosition,
                        orientation: basis,
                        electrodePosition: electrode - head.centerMeters,
                        head: head,
                        transfers: transfers
                    )
                }
            }
        }

        if reference == .average, !freeMatrix.isEmpty {
            for column in 0..<(3 * sources.count) {
                let mean = freeMatrix.reduce(0.0) { $0 + $1[column] } / Double(freeMatrix.count)
                for channel in freeMatrix.indices { freeMatrix[channel][column] -= mean }
            }
        }

        var matrix = [[Double]](
            repeating: [Double](repeating: 0, count: sources.count),
            count: electrodes.count
        )
        for channel in matrix.indices {
            for (sourceIndex, source) in sources.enumerated() {
                matrix[channel][sourceIndex] =
                    freeMatrix[channel][3 * sourceIndex] * source.orientation.x
                    + freeMatrix[channel][3 * sourceIndex + 1] * source.orientation.y
                    + freeMatrix[channel][3 * sourceIndex + 2] * source.orientation.z
            }
        }

        return LeadField(
            channelNames: montage.channelNames,
            sourceIDs: sources.map(\.id),
            reference: reference,
            freeOrientationMatrixMicrovoltsPerNanoampereMeter: freeMatrix,
            matrixMicrovoltsPerNanoampereMeter: matrix
        )
    }

    /// Compares the requested truncation with twice as many terms. This is a
    /// numerical adequacy check, not an independent validation of the forward
    /// equations themselves.
    static func convergenceReport(
        head: SphericalHeadModel,
        montage: Montage,
        sources: [SimulatedSource],
        reference: EEGReference,
        terms: Int,
        tolerance: Double = defaultConvergenceTolerance
    ) throws -> LeadFieldConvergenceReport {
        guard tolerance > 0, tolerance.isFinite else {
            throw SphericalForwardError.invalid("convergence tolerance must be positive and finite")
        }
        guard terms <= Int.max / 2 else {
            throw SphericalForwardError.invalid("series term count is too large to double")
        }
        let requested = try leadField(
            head: head, montage: montage, sources: sources,
            reference: reference, terms: terms
        )
        let doubled = try leadField(
            head: head, montage: montage, sources: sources,
            reference: reference, terms: 2 * terms
        )
        let requestedMatrix = requested.freeOrientationMatrixMicrovoltsPerNanoampereMeter
        let doubledMatrix = doubled.freeOrientationMatrixMicrovoltsPerNanoampereMeter
        let columnCount = doubledMatrix.first?.count ?? 0
        var maximum = 0.0
        var relativeSquares = 0.0
        var worstColumn: Int?

        for column in 0..<columnCount {
            var differenceSquares = 0.0
            var comparisonSquares = 0.0
            for channel in doubledMatrix.indices {
                let comparison = doubledMatrix[channel][column]
                let difference = requestedMatrix[channel][column] - comparison
                differenceSquares += difference * difference
                comparisonSquares += comparison * comparison
            }
            let relative = sqrt(differenceSquares / max(comparisonSquares, 1e-300))
            relativeSquares += relative * relative
            if relative > maximum {
                maximum = relative
                worstColumn = column
            }
        }

        let sourceIndex = worstColumn.map { $0 / 3 }
        let axes = ["x", "y", "z"]
        return LeadFieldConvergenceReport(
            terms: terms,
            comparisonTerms: 2 * terms,
            tolerance: tolerance,
            maximumRelativeColumnChange: maximum,
            rootMeanSquareRelativeChange: columnCount > 0
                ? sqrt(relativeSquares / Double(columnCount)) : 0,
            worstSourceID: sourceIndex.flatMap {
                sources.indices.contains($0) ? sources[$0].id : nil
            },
            worstOrientationAxis: worstColumn.map { axes[$0 % 3] }
        )
    }

    /// Surface potential for a one nA·m oriented dipole, returned in µV.
    /// The 1e-3 factor converts V/(A·m) to µV/(nA·m).
    private static func potentialPerUnitMoment(
        sourcePosition: Vector3D,
        orientation: Vector3D,
        electrodePosition: Vector3D,
        head: SphericalHeadModel,
        transfers: [Double]
    ) -> Double {
        let brainRadius = head.brainRadiusMeters
        let sourceRadius = sourcePosition.norm
        let sensorDirection = electrodePosition.normalized()
        let sigma = head.shells[0].conductivitySiemensPerMeter
        let unitScale = 1e-3 / (4 * Double.pi * sigma)

        // At the exact center only l=1 survives. Handling the limit explicitly
        // avoids dividing by r0² and provides a closed-form validation case.
        if sourceRadius < 1e-12 {
            let transfer = transfers[0]
            return unitScale * transfer * orientation.dot(sensorDirection) / (brainRadius * brainRadius)
        }

        let sourceDirection = sourcePosition * (1 / sourceRadius)
        let cosine = max(-1.0, min(1.0, sourceDirection.dot(sensorDirection)))
        let radialMoment = orientation.dot(sourceDirection)
        let tangentialMoment = orientation - sourceDirection * radialMoment
        let tangentialProjection = tangentialMoment.dot(sensorDirection)

        var pPrevious = 1.0
        var pCurrent = cosine
        var derivativePrevious = 0.0
        var derivativeCurrent = 1.0
        var sum = 0.0

        for order in 1...transfers.count {
            let p: Double
            let derivative: Double
            if order == 1 {
                p = pCurrent
                derivative = derivativeCurrent
            } else {
                let n = Double(order)
                p = ((2 * n - 1) * cosine * pCurrent - (n - 1) * pPrevious) / n
                derivative = ((2 * n - 1) * (pCurrent + cosine * derivativeCurrent)
                              - (n - 1) * derivativePrevious) / n
                pPrevious = pCurrent
                pCurrent = p
                derivativePrevious = derivativeCurrent
                derivativeCurrent = derivative
            }

            let angular = Double(order) * radialMoment * p + tangentialProjection * derivative
            let radialPower = pow(sourceRadius / brainRadius, Double(order + 1))
            sum += radialPower * transfers[order - 1] * angular
        }

        return unitScale * sum / (sourceRadius * sourceRadius)
    }

    /// A_l(out) + B_l(out), with source-radius dependence factored out.
    /// This is the iterative arbitrary-shell recurrence from Bruña et al. (2023).
    private static func surfaceTransfer(order: Int, head: SphericalHeadModel) -> Double {
        let count = head.shells.count
        let l = Double(order)
        var ratio = [Double](repeating: 0, count: count) // B_l / A_l at each boundary
        ratio[count - 1] = l / (l + 1) // no current escapes the scalp

        if count > 1 {
            for index in stride(from: count - 2, through: 0, by: -1) {
                let inner = head.shells[index]
                let outer = head.shells[index + 1]
                let radiusRatio = inner.radiusMeters / outer.radiusMeters
                let forward = pow(radiusRatio, l)
                let backward = pow(1 / radiusRatio, l + 1)
                let outerBoundary = ratio[count - 1]
                let nextBoundary = ratio[index + 1]
                let repeated = (outerBoundary * forward - nextBoundary * backward)
                    / (forward + nextBoundary * backward)
                let conductivityRatio = inner.conductivitySiemensPerMeter
                    / outer.conductivitySiemensPerMeter
                ratio[index] = (outerBoundary * conductivityRatio - repeated)
                    / (conductivityRatio + repeated)
            }
        }

        var amplitude = 1 / ratio[0]
        if count > 1 {
            for index in 1..<count {
                let radiusRatio = head.shells[index - 1].radiusMeters / head.shells[index].radiusMeters
                let denominator = pow(radiusRatio, l) + ratio[index] * pow(1 / radiusRatio, l + 1)
                amplitude *= (1 + ratio[index - 1]) / denominator
            }
        }
        return amplitude * (1 + ratio[count - 1])
    }
}
