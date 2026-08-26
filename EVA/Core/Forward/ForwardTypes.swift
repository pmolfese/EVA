//
//  ForwardTypes.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation

/// One conductive shell in a concentric spherical head model.
nonisolated struct ForwardHeadShell: Codable, Sendable, Equatable {
    var name: String
    var radiusMeters: Double
    var conductivitySiemensPerMeter: Double
}

/// App-neutral physical geometry for a concentric spherical forward model.
nonisolated struct ForwardHeadModel: Codable, Sendable, Equatable {
    var name: String
    var centerMeters: SIMD3<Double>
    /// Innermost to outermost. Dipoles must lie inside the first shell.
    var shells: [ForwardHeadShell]

    var brainRadiusMeters: Double { shells.first?.radiusMeters ?? 0 }
    var scalpRadiusMeters: Double { shells.last?.radiusMeters ?? 0 }
}

/// Physical electrode locations in authoritative row order.
nonisolated struct OrderedElectrodes: Codable, Sendable, Equatable {
    var names: [String]
    var positionsMeters: [SIMD3<Double>]
}

/// A fixed-orientation current dipole. Moment time series are applied later.
nonisolated struct ForwardDipole: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var positionMeters: SIMD3<Double>
    var orientationUnit: SIMD3<Double>
}

nonisolated enum ForwardEEGReference: String, Codable, Sendable, Equatable {
    case average
    case infinity
}

/// Forward operator in µV/(nA·m), preserving input electrode and dipole order.
nonisolated struct ForwardLeadField: Codable, Sendable, Equatable {
    var electrodeNames: [String]
    var dipoleIDs: [String]
    var reference: ForwardEEGReference
    /// electrodes × (3 * dipoles), with x/y/z columns for each dipole.
    var freeMicrovoltsPerNanoampereMeter: [[Double]]
    /// electrodes × dipoles, after orientation projection.
    var orientedMicrovoltsPerNanoampereMeter: [[Double]]
}

/// Numerical convergence diagnostic for the truncated spherical-harmonic series.
nonisolated struct ForwardLeadFieldConvergenceReport: Sendable, Equatable {
    var harmonicTerms: Int
    var comparisonHarmonicTerms: Int
    var tolerance: Double
    var maximumRelativeColumnChange: Double
    var rootMeanSquareRelativeChange: Double
    var worstDipoleID: String?
    var worstOrientationAxis: String?

    var converged: Bool { maximumRelativeColumnChange <= tolerance }
}

/// Validation failures are typed so callers can distinguish bad geometry,
/// dipoles, numerical configuration, and numerical output without parsing text.
nonisolated enum SphericalForwardError: LocalizedError, Sendable, Equatable {
    case emptyElectrodes
    case electrodeCountMismatch(names: Int, positions: Int)
    case emptyElectrodeName(index: Int)
    case duplicateElectrodeName(String)
    case nonFiniteElectrodePosition(index: Int)
    case invalidHeadModel(String)
    case emptyDipoles
    case emptyDipoleID(index: Int)
    case duplicateDipoleID(String)
    case nonFiniteDipolePosition(id: String)
    case dipoleOutsideBrain(id: String)
    case nonFiniteDipoleOrientation(id: String)
    case nonUnitDipoleOrientation(id: String)
    case invalidHarmonicTermCount(Int)
    case invalidConvergenceTolerance(Double)
    case harmonicTermCountTooLarge(Int)
    case convergenceFailed(ForwardLeadFieldConvergenceReport)
    case nonFiniteNumericalOutput

    var errorDescription: String? {
        switch self {
        case .emptyElectrodes:
            return "Invalid spherical forward model: at least one electrode is required"
        case .electrodeCountMismatch(let names, let positions):
            return "Invalid spherical forward model: electrode name count (\(names)) does not match position count (\(positions))"
        case .emptyElectrodeName(let index):
            return "Invalid spherical forward model: electrode \(index) has an empty name"
        case .duplicateElectrodeName(let name):
            return "Invalid spherical forward model: duplicate electrode name \(name)"
        case .nonFiniteElectrodePosition(let index):
            return "Invalid spherical forward model: electrode \(index) has a non-finite position"
        case .invalidHeadModel(let message):
            return "Invalid spherical forward model: \(message)"
        case .emptyDipoles:
            return "Invalid spherical forward model: at least one dipole is required"
        case .emptyDipoleID(let index):
            return "Invalid spherical forward model: dipole \(index) has an empty ID"
        case .duplicateDipoleID(let id):
            return "Invalid spherical forward model: duplicate dipole ID \(id)"
        case .nonFiniteDipolePosition(let id):
            return "Invalid spherical forward model: dipole \(id) has a non-finite position"
        case .dipoleOutsideBrain(let id):
            return "Invalid spherical forward model: dipole \(id) is not inside the brain shell"
        case .nonFiniteDipoleOrientation(let id):
            return "Invalid spherical forward model: dipole \(id) has a non-finite orientation"
        case .nonUnitDipoleOrientation(let id):
            return "Invalid spherical forward model: dipole \(id) orientation is not a unit vector"
        case .invalidHarmonicTermCount(let count):
            return "Invalid spherical forward model: harmonic term count must be positive (received \(count))"
        case .invalidConvergenceTolerance(let tolerance):
            return "Invalid spherical forward model: convergence tolerance must be positive and finite (received \(tolerance))"
        case .harmonicTermCountTooLarge(let count):
            return "Invalid spherical forward model: harmonic term count \(count) is too large to double"
        case .convergenceFailed(let report):
            return String(
                format: "Invalid spherical forward model: lead field has not converged: %.4g relative change between %d and %d terms (%@ %@ axis, tolerance %.4g)",
                report.maximumRelativeColumnChange,
                report.harmonicTerms,
                report.comparisonHarmonicTerms,
                report.worstDipoleID ?? "unknown",
                report.worstOrientationAxis ?? "?",
                report.tolerance
            )
        case .nonFiniteNumericalOutput:
            return "Invalid spherical forward model: lead field contains a non-finite numerical result"
        }
    }
}
