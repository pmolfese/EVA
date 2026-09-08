//
//  SphericalForwardModel.swift
//  EVA
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

/// App-neutral concentric-sphere EEG forward solver.
nonisolated enum SphericalForwardModel {
    /// A 0.01% maximum relative change in every free-orientation column makes
    /// truncation negligible relative to head-model error.
    static let defaultConvergenceTolerance = 1e-4

    static func leadField(
        head: ForwardHeadModel,
        electrodes: OrderedElectrodes,
        dipoles: [ForwardDipole],
        reference: ForwardEEGReference,
        harmonicTerms: Int,
        verifyConvergence: Bool = false
    ) throws -> ForwardLeadField {
        if verifyConvergence {
            let report = try convergenceReport(
                head: head,
                electrodes: electrodes,
                dipoles: dipoles,
                reference: reference,
                harmonicTerms: harmonicTerms
            )
            guard report.converged else {
                throw SphericalForwardError.convergenceFailed(report)
            }
        }

        try validate(
            head: head,
            electrodes: electrodes,
            dipoles: dipoles,
            harmonicTerms: harmonicTerms
        )

        let transfers = (1...harmonicTerms).map { surfaceTransfer(order: $0, head: head) }
        var freeMatrix = [[Double]](
            repeating: [Double](repeating: 0, count: 3 * dipoles.count),
            count: electrodes.positionsMeters.count
        )
        let bases = [
            SIMD3<Double>(1, 0, 0),
            SIMD3<Double>(0, 1, 0),
            SIMD3<Double>(0, 0, 1)
        ]

        for (dipoleIndex, dipole) in dipoles.enumerated() {
            let relativePosition = subtract(dipole.positionMeters, head.centerMeters)
            for (axis, basis) in bases.enumerated() {
                for (electrodeIndex, electrode) in electrodes.positionsMeters.enumerated() {
                    freeMatrix[electrodeIndex][3 * dipoleIndex + axis] = potentialPerUnitMoment(
                        sourcePosition: relativePosition,
                        orientation: basis,
                        electrodePosition: subtract(electrode, head.centerMeters),
                        head: head,
                        transfers: transfers
                    )
                }
            }
        }

        if reference == .average {
            for column in 0..<(3 * dipoles.count) {
                let mean = freeMatrix.reduce(0.0) { $0 + $1[column] }
                    / Double(freeMatrix.count)
                for electrodeIndex in freeMatrix.indices {
                    freeMatrix[electrodeIndex][column] -= mean
                }
            }
        }

        var orientedMatrix = [[Double]](
            repeating: [Double](repeating: 0, count: dipoles.count),
            count: electrodes.positionsMeters.count
        )
        for electrodeIndex in orientedMatrix.indices {
            for (dipoleIndex, dipole) in dipoles.enumerated() {
                orientedMatrix[electrodeIndex][dipoleIndex] =
                    freeMatrix[electrodeIndex][3 * dipoleIndex] * dipole.orientationUnit.x
                    + freeMatrix[electrodeIndex][3 * dipoleIndex + 1] * dipole.orientationUnit.y
                    + freeMatrix[electrodeIndex][3 * dipoleIndex + 2] * dipole.orientationUnit.z
            }
        }

        guard freeMatrix.allSatisfy({ $0.allSatisfy(\.isFinite) }),
              orientedMatrix.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw SphericalForwardError.nonFiniteNumericalOutput
        }

        return ForwardLeadField(
            electrodeNames: electrodes.names,
            dipoleIDs: dipoles.map(\.id),
            reference: reference,
            freeMicrovoltsPerNanoampereMeter: freeMatrix,
            orientedMicrovoltsPerNanoampereMeter: orientedMatrix
        )
    }

    /// Compares the requested truncation with twice as many terms. This checks
    /// numerical adequacy, not the physical validity of the forward equations.
    static func convergenceReport(
        head: ForwardHeadModel,
        electrodes: OrderedElectrodes,
        dipoles: [ForwardDipole],
        reference: ForwardEEGReference,
        harmonicTerms: Int,
        tolerance: Double = defaultConvergenceTolerance
    ) throws -> ForwardLeadFieldConvergenceReport {
        guard tolerance > 0, tolerance.isFinite else {
            throw SphericalForwardError.invalidConvergenceTolerance(tolerance)
        }
        guard harmonicTerms <= Int.max / 2 else {
            throw SphericalForwardError.harmonicTermCountTooLarge(harmonicTerms)
        }

        let requested = try leadField(
            head: head,
            electrodes: electrodes,
            dipoles: dipoles,
            reference: reference,
            harmonicTerms: harmonicTerms
        )
        let doubled = try leadField(
            head: head,
            electrodes: electrodes,
            dipoles: dipoles,
            reference: reference,
            harmonicTerms: 2 * harmonicTerms
        )
        let requestedMatrix = requested.freeMicrovoltsPerNanoampereMeter
        let doubledMatrix = doubled.freeMicrovoltsPerNanoampereMeter
        let columnCount = doubledMatrix.first?.count ?? 0
        var maximum = 0.0
        var relativeSquares = 0.0
        var worstColumn: Int?

        for column in 0..<columnCount {
            var differenceSquares = 0.0
            var comparisonSquares = 0.0
            for electrodeIndex in doubledMatrix.indices {
                let comparison = doubledMatrix[electrodeIndex][column]
                let difference = requestedMatrix[electrodeIndex][column] - comparison
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

        let dipoleIndex = worstColumn.map { $0 / 3 }
        let axes = ["x", "y", "z"]
        return ForwardLeadFieldConvergenceReport(
            harmonicTerms: harmonicTerms,
            comparisonHarmonicTerms: 2 * harmonicTerms,
            tolerance: tolerance,
            maximumRelativeColumnChange: maximum,
            rootMeanSquareRelativeChange: columnCount > 0
                ? sqrt(relativeSquares / Double(columnCount)) : 0,
            worstDipoleID: dipoleIndex.flatMap {
                dipoles.indices.contains($0) ? dipoles[$0].id : nil
            },
            worstOrientationAxis: worstColumn.map { axes[$0 % 3] }
        )
    }

    private static func validate(
        head: ForwardHeadModel,
        electrodes: OrderedElectrodes,
        dipoles: [ForwardDipole],
        harmonicTerms: Int
    ) throws {
        guard harmonicTerms >= 1 else {
            throw SphericalForwardError.invalidHarmonicTermCount(harmonicTerms)
        }
        guard isFinite(head.centerMeters) else {
            throw SphericalForwardError.invalidHeadModel("head center must be finite")
        }
        guard !head.shells.isEmpty else {
            throw SphericalForwardError.invalidHeadModel("head model needs at least one shell")
        }
        var previousRadius = 0.0
        for shell in head.shells {
            guard shell.radiusMeters.isFinite, shell.radiusMeters > previousRadius else {
                throw SphericalForwardError.invalidHeadModel(
                    "head-shell radii must be finite and increase from brain to scalp"
                )
            }
            guard shell.conductivitySiemensPerMeter.isFinite,
                  shell.conductivitySiemensPerMeter > 0 else {
                throw SphericalForwardError.invalidHeadModel(
                    "head-shell conductivities must be positive and finite"
                )
            }
            previousRadius = shell.radiusMeters
        }

        guard !electrodes.positionsMeters.isEmpty else {
            throw SphericalForwardError.emptyElectrodes
        }
        guard electrodes.names.count == electrodes.positionsMeters.count else {
            throw SphericalForwardError.electrodeCountMismatch(
                names: electrodes.names.count,
                positions: electrodes.positionsMeters.count
            )
        }
        var electrodeNames = Set<String>()
        for (index, pair) in zip(electrodes.names, electrodes.positionsMeters).enumerated() {
            let (name, position) = pair
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SphericalForwardError.emptyElectrodeName(index: index)
            }
            guard electrodeNames.insert(name).inserted else {
                throw SphericalForwardError.duplicateElectrodeName(name)
            }
            guard isFinite(position) else {
                throw SphericalForwardError.nonFiniteElectrodePosition(index: index)
            }
        }

        guard !dipoles.isEmpty else { throw SphericalForwardError.emptyDipoles }
        var dipoleIDs = Set<String>()
        for (index, dipole) in dipoles.enumerated() {
            guard !dipole.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SphericalForwardError.emptyDipoleID(index: index)
            }
            guard dipoleIDs.insert(dipole.id).inserted else {
                throw SphericalForwardError.duplicateDipoleID(dipole.id)
            }
            guard isFinite(dipole.positionMeters) else {
                throw SphericalForwardError.nonFiniteDipolePosition(id: dipole.id)
            }
            let relativePosition = subtract(dipole.positionMeters, head.centerMeters)
            guard norm(relativePosition) < head.brainRadiusMeters else {
                throw SphericalForwardError.dipoleOutsideBrain(id: dipole.id)
            }
            guard isFinite(dipole.orientationUnit) else {
                throw SphericalForwardError.nonFiniteDipoleOrientation(id: dipole.id)
            }
            guard abs(norm(dipole.orientationUnit) - 1) < 1e-8 else {
                throw SphericalForwardError.nonUnitDipoleOrientation(id: dipole.id)
            }
        }
    }

    /// Surface potential for a one nA·m oriented dipole, returned in µV.
    /// The 1e-3 factor converts V/(A·m) to µV/(nA·m).
    private static func potentialPerUnitMoment(
        sourcePosition: SIMD3<Double>,
        orientation: SIMD3<Double>,
        electrodePosition: SIMD3<Double>,
        head: ForwardHeadModel,
        transfers: [Double]
    ) -> Double {
        let brainRadius = head.brainRadiusMeters
        let sourceRadius = norm(sourcePosition)
        let sensorDirection = normalized(electrodePosition)
        let sigma = head.shells[0].conductivitySiemensPerMeter
        let unitScale = 1e-3 / (4 * Double.pi * sigma)

        if sourceRadius < 1e-12 {
            let transfer = transfers[0]
            return unitScale * transfer * dot(orientation, sensorDirection)
                / (brainRadius * brainRadius)
        }

        let sourceDirection = scaled(sourcePosition, 1 / sourceRadius)
        let cosine = max(-1.0, min(1.0, dot(sourceDirection, sensorDirection)))
        let radialMoment = dot(orientation, sourceDirection)
        let tangentialMoment = subtract(orientation, scaled(sourceDirection, radialMoment))
        let tangentialProjection = dot(tangentialMoment, sensorDirection)

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

            let angular = Double(order) * radialMoment * p
                + tangentialProjection * derivative
            let radialPower = pow(sourceRadius / brainRadius, Double(order + 1))
            sum += radialPower * transfers[order - 1] * angular
        }

        return unitScale * sum / (sourceRadius * sourceRadius)
    }

    /// A_l(out) + B_l(out), with source-radius dependence factored out.
    private static func surfaceTransfer(order: Int, head: ForwardHeadModel) -> Double {
        let count = head.shells.count
        let l = Double(order)
        var ratio = [Double](repeating: 0, count: count)
        ratio[count - 1] = l / (l + 1)

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
                let radiusRatio = head.shells[index - 1].radiusMeters
                    / head.shells[index].radiusMeters
                let denominator = pow(radiusRatio, l)
                    + ratio[index] * pow(1 / radiusRatio, l + 1)
                amplitude *= (1 + ratio[index - 1]) / denominator
            }
        }
        return amplitude * (1 + ratio[count - 1])
    }

    private static func isFinite(_ value: SIMD3<Double>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static func dot(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private static func norm(_ value: SIMD3<Double>) -> Double {
        dot(value, value).squareRoot()
    }

    private static func normalized(_ value: SIMD3<Double>) -> SIMD3<Double> {
        let length = norm(value)
        return length > 1e-15 ? scaled(value, 1 / length) : SIMD3<Double>(repeating: 0)
    }

    private static func scaled(_ value: SIMD3<Double>, _ scalar: Double) -> SIMD3<Double> {
        SIMD3<Double>(value.x * scalar, value.y * scalar, value.z * scalar)
    }

    private static func subtract(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }
}
