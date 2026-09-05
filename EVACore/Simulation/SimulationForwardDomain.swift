//
//  SimulationForwardDomain.swift
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

    /// Four-shell brain/CSF/skull/scalp sphere, mirroring EVA's
    /// `ForwardHeadModel.classicFourShell` number-for-number so a correction
    /// measured against simulated truth is measured against the same head. The
    /// CSF layer (0.074 m, 1.79 S/m) is inserted between the brain and skull of
    /// `classicThreeShell`; every other value is unchanged. Used to generate
    /// truth under one geometry and invert under another for SI-4's
    /// head-model-mismatch sweeps.
    static let classicFourShell = SphericalHeadModel(
        name: "Four-shell brain/CSF/skull/scalp sphere",
        centerMeters: .zero,
        shells: [
            HeadShell(name: "brain", radiusMeters: 0.072, conductivitySiemensPerMeter: 0.33),
            HeadShell(name: "csf", radiusMeters: 0.074, conductivitySiemensPerMeter: 1.79),
            HeadShell(name: "skull", radiusMeters: 0.079, conductivitySiemensPerMeter: 0.0042),
            HeadShell(name: "scalp", radiusMeters: 0.085, conductivitySiemensPerMeter: 0.33)
        ]
    )

    /// Mirrors `ForwardHeadModel.threeShell(...)` so simulator scenarios can
    /// generate truth under any standard 3-shell parameterization and invert
    /// under another (SI-4 skull-ratio and radius sweeps).
    static func threeShell(
        name: String,
        scalpRadiusMeters: Double = 0.092,
        brainFraction: Double = 80.0 / 92.0,
        skullFraction: Double = 86.0 / 92.0,
        skullConductivityRatio: Double = 40,
        brainConductivity: Double = 0.33,
        scalpConductivity: Double = 0.33
    ) -> SphericalHeadModel {
        SphericalHeadModel(
            name: name,
            centerMeters: .zero,
            shells: [
                HeadShell(name: "brain", radiusMeters: scalpRadiusMeters * brainFraction,
                          conductivitySiemensPerMeter: brainConductivity),
                HeadShell(name: "skull", radiusMeters: scalpRadiusMeters * skullFraction,
                          conductivitySiemensPerMeter: brainConductivity / skullConductivityRatio),
                HeadShell(name: "scalp", radiusMeters: scalpRadiusMeters,
                          conductivitySiemensPerMeter: scalpConductivity)
            ]
        )
    }

    static let rushDriscollThreeShell = threeShell(
        name: "Rush–Driscoll three-shell (1:80 skull)", skullConductivityRatio: 80)
    static let standardThreeShell = threeShell(
        name: "Standard three-shell (1:40 skull)", skullConductivityRatio: 40)
    static let highSkullConductivityThreeShell = threeShell(
        name: "High-skull-conductivity three-shell (1:20 skull)", skullConductivityRatio: 20)

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

// MARK: - EVASimulate boundary adapters

private extension Vector3D {
    nonisolated var forwardSIMD: SIMD3<Double> { SIMD3<Double>(x, y, z) }
}

private extension SphericalHeadModel {
    nonisolated var forwardModel: ForwardHeadModel {
        ForwardHeadModel(
            name: name,
            centerMeters: centerMeters.forwardSIMD,
            shells: shells.map {
                ForwardHeadShell(
                    name: $0.name,
                    radiusMeters: $0.radiusMeters,
                    conductivitySiemensPerMeter: $0.conductivitySiemensPerMeter
                )
            }
        )
    }
}

private extension EEGReference {
    nonisolated var forwardReference: ForwardEEGReference {
        switch self {
        case .average: return .average
        case .infinity: return .infinity
        }
    }
}

private extension Montage {
    nonisolated func forwardElectrodes(head: SphericalHeadModel) -> OrderedElectrodes {
        OrderedElectrodes(
            names: channelNames,
            positionsMeters: positions.map {
                SIMD3<Double>(
                    $0.x * head.scalpRadiusMeters + head.centerMeters.x,
                    $0.y * head.scalpRadiusMeters + head.centerMeters.y,
                    $0.z * head.scalpRadiusMeters + head.centerMeters.z
                )
            }
        )
    }
}

private extension SimulatedSource {
    nonisolated var forwardDipole: ForwardDipole {
        ForwardDipole(
            id: id,
            positionMeters: positionMeters.forwardSIMD,
            orientationUnit: orientation.forwardSIMD
        )
    }
}

extension SphericalForwardModel {
    /// EVASimulate retains its stable scenario and truth types at this boundary;
    /// all forward mathematics is delegated to EVA's shared solver overload.
    nonisolated static func leadField(
        head: SphericalHeadModel,
        montage: Montage,
        sources: [SimulatedSource],
        reference: EEGReference,
        terms: Int,
        verifyConvergence: Bool = false
    ) throws -> LeadField {
        let shared = try leadField(
            head: head.forwardModel,
            electrodes: montage.forwardElectrodes(head: head),
            dipoles: sources.map(\.forwardDipole),
            reference: reference.forwardReference,
            harmonicTerms: terms,
            verifyConvergence: verifyConvergence
        )
        return LeadField(
            channelNames: shared.electrodeNames,
            sourceIDs: shared.dipoleIDs,
            reference: reference,
            freeOrientationMatrixMicrovoltsPerNanoampereMeter:
                shared.freeMicrovoltsPerNanoampereMeter,
            matrixMicrovoltsPerNanoampereMeter:
                shared.orientedMicrovoltsPerNanoampereMeter
        )
    }

    nonisolated static func convergenceReport(
        head: SphericalHeadModel,
        montage: Montage,
        sources: [SimulatedSource],
        reference: EEGReference,
        terms: Int,
        tolerance: Double = defaultConvergenceTolerance
    ) throws -> LeadFieldConvergenceReport {
        let shared = try convergenceReport(
            head: head.forwardModel,
            electrodes: montage.forwardElectrodes(head: head),
            dipoles: sources.map(\.forwardDipole),
            reference: reference.forwardReference,
            harmonicTerms: terms,
            tolerance: tolerance
        )
        return LeadFieldConvergenceReport(
            terms: shared.harmonicTerms,
            comparisonTerms: shared.comparisonHarmonicTerms,
            tolerance: shared.tolerance,
            maximumRelativeColumnChange: shared.maximumRelativeColumnChange,
            rootMeanSquareRelativeChange: shared.rootMeanSquareRelativeChange,
            worstSourceID: shared.worstDipoleID,
            worstOrientationAxis: shared.worstOrientationAxis
        )
    }
}

/// An affine-warped ellipsoidal head for the simulator, mirroring EVA's
/// `ForwardEllipsoidModel`. Kept as a stable EVASimulate scenario type; all
/// mathematics is delegated to EVA's shared solver through the boundary
/// adapter. Generating truth through an ellipsoid and inverting through the
/// sphere (or vice versa) is what SI-4's head-model-mismatch sweep needs.
nonisolated struct SimulatedEllipsoidModel: Codable, Sendable, Equatable {
    var name: String
    var sphere: SphericalHeadModel
    var axisScale: Vector3D

    /// Mild adult-head proportions on the classic three-shell sphere.
    static let classicThreeShellEllipsoid = SimulatedEllipsoidModel(
        name: "Three-shell affine ellipsoid",
        sphere: .classicThreeShell,
        axisScale: Vector3D(x: 0.94, y: 1.0, z: 1.08)
    )

    /// The four-shell (brain/CSF/skull/scalp) counterpart.
    static let classicFourShellEllipsoid = SimulatedEllipsoidModel(
        name: "Four-shell affine ellipsoid",
        sphere: .classicFourShell,
        axisScale: Vector3D(x: 0.94, y: 1.0, z: 1.08)
    )

    nonisolated var forwardModel: ForwardEllipsoidModel {
        ForwardEllipsoidModel(
            name: name,
            sphere: sphere.forwardModel,
            axisScale: axisScale.forwardSIMD
        )
    }

    /// Electrodes warp with the head, so the montage is expressed against the
    /// ellipsoid's own scalp using its longest semi-axis as the nominal radius —
    /// the warp back into sphere space then recovers per-electrode direction.
    var scalpRadiusMeters: Double {
        sphere.scalpRadiusMeters * max(axisScale.x, max(axisScale.y, axisScale.z))
    }
}

extension EllipsoidalForwardModel {
    /// EVASimulate retains its stable scenario and truth types at this boundary;
    /// all forward mathematics is delegated to EVA's shared ellipsoidal solver.
    static func leadField(
        ellipsoid: SimulatedEllipsoidModel,
        montage: Montage,
        sources: [SimulatedSource],
        reference: EEGReference,
        terms: Int,
        verifyConvergence: Bool = false
    ) throws -> LeadField {
        let head = ellipsoid.forwardModel
        // Place electrodes on the ellipsoid scalp: scale the unit montage
        // directions by the per-axis semi-axes, centred on the head.
        let semiAxes = head.scalpSemiAxesMeters
        let electrodes = OrderedElectrodes(
            names: montage.channelNames,
            positionsMeters: montage.positions.map {
                SIMD3<Double>(
                    $0.x * semiAxes.x + head.sphere.centerMeters.x,
                    $0.y * semiAxes.y + head.sphere.centerMeters.y,
                    $0.z * semiAxes.z + head.sphere.centerMeters.z
                )
            }
        )
        let shared = try leadField(
            ellipsoid: head,
            electrodes: electrodes,
            dipoles: sources.map { source in
                ForwardDipole(
                    id: source.id,
                    positionMeters: source.positionMeters.forwardSIMD,
                    orientationUnit: source.orientation.forwardSIMD
                )
            },
            reference: reference.forwardReference,
            harmonicTerms: terms,
            verifyConvergence: verifyConvergence
        )
        return LeadField(
            channelNames: shared.electrodeNames,
            sourceIDs: shared.dipoleIDs,
            reference: reference,
            freeOrientationMatrixMicrovoltsPerNanoampereMeter:
                shared.freeMicrovoltsPerNanoampereMeter,
            matrixMicrovoltsPerNanoampereMeter:
                shared.orientedMicrovoltsPerNanoampereMeter
        )
    }
}
