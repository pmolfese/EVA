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

    /// Classic brain/skull/scalp model used in three-sphere validation studies:
    /// 72/79/85 mm and 0.33/0.0042/0.33 S/m.
    ///
    /// This is an *assumption*, not a measurement of the subject in front of
    /// you, and anything built on it has to say so — see
    /// `BCGSurrogateReport.headModelName`. EVASimulate's `classicThreeShell`
    /// carries the identical numbers so a correction measured against simulated
    /// truth is measured against the same head.
    static let classicThreeShell = ForwardHeadModel(
        name: "Classic three-shell sphere",
        centerMeters: SIMD3<Double>(0, 0, 0),
        shells: [
            ForwardHeadShell(name: "brain", radiusMeters: 0.072, conductivitySiemensPerMeter: 0.33),
            ForwardHeadShell(name: "skull", radiusMeters: 0.079, conductivitySiemensPerMeter: 0.0042),
            ForwardHeadShell(name: "scalp", radiusMeters: 0.085, conductivitySiemensPerMeter: 0.33)
        ]
    )

    /// Four-shell brain/CSF/skull/scalp sphere: the classic three-shell with a
    /// cerebrospinal-fluid layer inserted between brain and skull. This is the
    /// shell structure the Rusiniak et al. (2022) PCA-S paper's 4-shell model
    /// carries; adding CSF (thin and highly conductive) changes how the skull's
    /// insulation shapes the surface field, which is exactly the geometry
    /// difference a source-informed filter is sensitive to.
    ///
    /// Radii: brain 0.072, CSF 0.074, skull 0.079, scalp 0.085 m. Conductivities:
    /// brain/scalp 0.33, CSF 1.79, skull 0.0042 S/m — the CSF value is the
    /// commonly cited 1.79 S/m (Baumann et al. 1997); the others match
    /// `classicThreeShell` so the two models differ only by the CSF layer.
    ///
    /// Like every head model here this is an *assumption*, not a measurement of
    /// the subject — anything built on it must say so (see
    /// `BCGSurrogateReport.headModelName`). EVASimulate's `classicFourShell`
    /// carries the identical numbers so a correction measured against simulated
    /// truth is measured against the same head.
    static let classicFourShell = ForwardHeadModel(
        name: "Four-shell brain/CSF/skull/scalp sphere",
        centerMeters: SIMD3<Double>(0, 0, 0),
        shells: [
            ForwardHeadShell(name: "brain", radiusMeters: 0.072, conductivitySiemensPerMeter: 0.33),
            ForwardHeadShell(name: "csf", radiusMeters: 0.074, conductivitySiemensPerMeter: 1.79),
            ForwardHeadShell(name: "skull", radiusMeters: 0.079, conductivitySiemensPerMeter: 0.0042),
            ForwardHeadShell(name: "scalp", radiusMeters: 0.085, conductivitySiemensPerMeter: 0.33)
        ]
    )

    /// Brain (soft-tissue) conductivity used by every preset here, S/m. The 0.33
    /// value is the long-standing consensus for brain and scalp alike.
    static let standardBrainConductivity = 0.33

    /// Builds a brain/skull/scalp sphere from a scalp radius, two thickness
    /// fractions, and a skull-conductivity *ratio* (brain:skull). The ratio is
    /// the parameter that actually moves EEG topographies and the one real
    /// pipelines most often get wrong, so it is named explicitly rather than
    /// buried as an absolute conductivity.
    ///
    /// - Parameters:
    ///   - scalpRadiusMeters: outer radius.
    ///   - brainFraction: brain radius as a fraction of the scalp radius.
    ///   - skullFraction: skull *outer* radius as a fraction of the scalp radius
    ///     (must sit between `brainFraction` and 1).
    ///   - skullConductivityRatio: brain-to-skull conductivity ratio (e.g. 80
    ///     for the classic 1:80, 20 for the modern 1:20). Larger = more
    ///     insulating skull.
    ///   - brainConductivity / scalpConductivity: soft-tissue conductivities.
    static func threeShell(
        name: String,
        scalpRadiusMeters: Double = 0.092,
        brainFraction: Double = 80.0 / 92.0,
        skullFraction: Double = 86.0 / 92.0,
        skullConductivityRatio: Double = 40,
        brainConductivity: Double = standardBrainConductivity,
        scalpConductivity: Double = standardBrainConductivity,
        centerMeters: SIMD3<Double> = SIMD3<Double>(0, 0, 0)
    ) -> ForwardHeadModel {
        ForwardHeadModel(
            name: name,
            centerMeters: centerMeters,
            shells: [
                ForwardHeadShell(
                    name: "brain",
                    radiusMeters: scalpRadiusMeters * brainFraction,
                    conductivitySiemensPerMeter: brainConductivity
                ),
                ForwardHeadShell(
                    name: "skull",
                    radiusMeters: scalpRadiusMeters * skullFraction,
                    conductivitySiemensPerMeter: brainConductivity / skullConductivityRatio
                ),
                ForwardHeadShell(
                    name: "scalp",
                    radiusMeters: scalpRadiusMeters,
                    conductivitySiemensPerMeter: scalpConductivity
                )
            ]
        )
    }

    /// Rush & Driscoll (1968) proportions with the classic, highly insulating
    /// 1:80 skull. This is the historical default much of the EEG-fMRI artifact
    /// literature — including the surrogate-method family — implicitly assumes.
    static let rushDriscollThreeShell = threeShell(
        name: "Rush–Driscoll three-shell (1:80 skull)",
        scalpRadiusMeters: 0.092,
        brainFraction: 80.0 / 92.0,
        skullFraction: 86.0 / 92.0,
        skullConductivityRatio: 80
    )

    /// The modern consensus skull conductivity (~1:40 rather than 1:80). Direct
    /// in-vivo measurement (e.g. Oostendorp et al. 2000; Lai et al. 2005) puts
    /// the skull far less insulating than Rush & Driscoll assumed, and the
    /// difference changes surface-field spread enough to matter to a
    /// source-informed filter — this is the recommended modern default.
    static let standardThreeShell = threeShell(
        name: "Standard three-shell (1:40 skull)",
        scalpRadiusMeters: 0.092,
        brainFraction: 80.0 / 92.0,
        skullFraction: 86.0 / 92.0,
        skullConductivityRatio: 40
    )

    /// The low end of the credible skull-conductivity range (~1:20). Offered so
    /// SI-4 can sweep the skull ratio — the single parameter most responsible
    /// for forward-model disagreement — across its full plausible span rather
    /// than at one point.
    static let highSkullConductivityThreeShell = threeShell(
        name: "High-skull-conductivity three-shell (1:20 skull)",
        scalpRadiusMeters: 0.092,
        brainFraction: 80.0 / 92.0,
        skullFraction: 86.0 / 92.0,
        skullConductivityRatio: 20
    )
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
