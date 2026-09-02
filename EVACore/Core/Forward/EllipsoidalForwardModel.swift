//
//  EllipsoidalForwardModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Affine-scaled ellipsoidal EEG forward model (BESA-style). The concentric
//  sphere is stretched by a per-axis factor, which is how the "ellipsoidal"
//  head model used in the Rusiniak et al. (2022) PCA-S paper — and the wider
//  Berg–Scherg / BESA lineage — is actually built: not with ellipsoidal
//  harmonics (Lamé functions), but as an affine warp of a solved concentric
//  sphere.
//
//  ## What it computes, and what it approximates
//
//  Let `S = diag(axisScale)` map sphere-space coordinates to physical
//  (ellipsoidal) space. This model evaluates the surface potential by warping
//  the physical electrode and source geometry back into sphere space with
//  `S⁻¹`, running the exact analytic `SphericalForwardModel` there, and
//  returning the result under the original physical electrode identity. The
//  spherical solver already uses only the *direction* of each electrode, so an
//  electrode's physical radius never has to sit exactly on the ellipsoid — its
//  warped direction is what selects the field point.
//
//  This is a first-order **geometric** approximation and says so. The affine
//  map that stretches the geometry also renders the medium anisotropic and
//  transforms current density non-trivially; those effects are not modeled.
//  What is captured is the dominant effect for a source-informed spatial
//  filter — the change in the *shape* of the scalp topography a given generator
//  produces — which is exactly the geometry sensitivity SI-4 measures. With
//  `axisScale == (1,1,1)` the model is bit-for-bit the concentric sphere.
//
//  ## Orientation, and why the free-orientation output is the honest one
//
//  A dipole moment does not transform like a position under `S`. For the
//  oriented lead field this model maps each orientation by `S⁻¹` and
//  renormalizes — a documented approximation. The **free-orientation** matrix
//  carries all three sphere-space axes as independent columns, so its column
//  *span* is exact under the warp even though the per-axis frame is
//  sphere-space rather than physical; PCA-S and the other source-informed
//  methods consume that span and re-derive their own components, so they are
//  invariant to the frame. Prefer the free-orientation output for those.
//

import Foundation

/// A concentric sphere stretched by a per-axis factor into an ellipsoid.
nonisolated struct ForwardEllipsoidModel: Codable, Sendable, Equatable {
    var name: String
    /// The reference concentric sphere. All shells are warped by the same
    /// `axisScale`, so they stay nested and each keeps its conductivity.
    var sphere: ForwardHeadModel
    /// Dimensionless per-axis stretch relative to the sphere. `(1,1,1)` is the
    /// sphere itself; e.g. `(0.95, 1.0, 1.08)` is a head narrower left-right and
    /// taller than it is wide, a typical adult proportion.
    var axisScale: SIMD3<Double>

    /// The physical outer (scalp) semi-axes in metres, for reporting.
    var scalpSemiAxesMeters: SIMD3<Double> {
        let r = sphere.scalpRadiusMeters
        return SIMD3<Double>(r * axisScale.x, r * axisScale.y, r * axisScale.z)
    }

    /// A mild, plausible adult-head ellipsoid built on the classic three-shell
    /// sphere: slightly narrower than tall/long. An *assumption*, like every
    /// head model here — anything built on it must say so.
    static let classicThreeShellEllipsoid = ForwardEllipsoidModel(
        name: "Three-shell affine ellipsoid",
        sphere: .classicThreeShell,
        axisScale: SIMD3<Double>(0.94, 1.0, 1.08)
    )

    /// The four-shell (brain/CSF/skull/scalp) counterpart — the closest analogue
    /// to the Rusiniak et al. (2022) 4-shell ellipsoidal model this codebase
    /// offers.
    static let classicFourShellEllipsoid = ForwardEllipsoidModel(
        name: "Four-shell affine ellipsoid",
        sphere: .classicFourShell,
        axisScale: SIMD3<Double>(0.94, 1.0, 1.08)
    )
}

nonisolated enum EllipsoidalForwardModel {
    static let defaultConvergenceTolerance = SphericalForwardModel.defaultConvergenceTolerance

    enum EllipsoidalForwardError: LocalizedError, Sendable, Equatable {
        case nonPositiveAxisScale(SIMD3<Double>)

        var errorDescription: String? {
            switch self {
            case .nonPositiveAxisScale(let scale):
                return "Invalid ellipsoidal forward model: axis scale components must be positive and finite (received \(scale.x), \(scale.y), \(scale.z))"
            }
        }
    }

    /// Lead field for an ellipsoidal head, by affine warp of a concentric
    /// sphere. Electrode names and dipole IDs are preserved from the physical
    /// inputs; the returned field is expressed at the physical electrodes.
    static func leadField(
        ellipsoid: ForwardEllipsoidModel,
        electrodes: OrderedElectrodes,
        dipoles: [ForwardDipole],
        reference: ForwardEEGReference,
        harmonicTerms: Int,
        verifyConvergence: Bool = false
    ) throws -> ForwardLeadField {
        let scale = ellipsoid.axisScale
        guard scale.x.isFinite, scale.y.isFinite, scale.z.isFinite,
              scale.x > 0, scale.y > 0, scale.z > 0 else {
            throw EllipsoidalForwardError.nonPositiveAxisScale(scale)
        }

        let center = ellipsoid.sphere.centerMeters
        let inverse = SIMD3<Double>(1 / scale.x, 1 / scale.y, 1 / scale.z)

        // Warp physical geometry into sphere space: p_sphere = center + S⁻¹·(p − center).
        let warpedElectrodes = OrderedElectrodes(
            names: electrodes.names,
            positionsMeters: electrodes.positionsMeters.map { warp($0, center: center, by: inverse) }
        )
        let warpedDipoles = dipoles.map { dipole in
            ForwardDipole(
                id: dipole.id,
                positionMeters: warp(dipole.positionMeters, center: center, by: inverse),
                // Orientation is a moment, not a position; map covariantly by
                // S⁻¹ and renormalize. Documented approximation — see the file
                // header; the free-orientation output does not depend on it.
                orientationUnit: warpedUnitOrientation(dipole.orientationUnit, by: inverse)
            )
        }

        return try SphericalForwardModel.leadField(
            head: ellipsoid.sphere,
            electrodes: warpedElectrodes,
            dipoles: warpedDipoles,
            reference: reference,
            harmonicTerms: harmonicTerms,
            verifyConvergence: verifyConvergence
        )
    }

    static func convergenceReport(
        ellipsoid: ForwardEllipsoidModel,
        electrodes: OrderedElectrodes,
        dipoles: [ForwardDipole],
        reference: ForwardEEGReference,
        harmonicTerms: Int,
        tolerance: Double = defaultConvergenceTolerance
    ) throws -> ForwardLeadFieldConvergenceReport {
        let scale = ellipsoid.axisScale
        guard scale.x.isFinite, scale.y.isFinite, scale.z.isFinite,
              scale.x > 0, scale.y > 0, scale.z > 0 else {
            throw EllipsoidalForwardError.nonPositiveAxisScale(scale)
        }
        let center = ellipsoid.sphere.centerMeters
        let inverse = SIMD3<Double>(1 / scale.x, 1 / scale.y, 1 / scale.z)
        let warpedElectrodes = OrderedElectrodes(
            names: electrodes.names,
            positionsMeters: electrodes.positionsMeters.map { warp($0, center: center, by: inverse) }
        )
        let warpedDipoles = dipoles.map { dipole in
            ForwardDipole(
                id: dipole.id,
                positionMeters: warp(dipole.positionMeters, center: center, by: inverse),
                orientationUnit: warpedUnitOrientation(dipole.orientationUnit, by: inverse)
            )
        }
        return try SphericalForwardModel.convergenceReport(
            head: ellipsoid.sphere,
            electrodes: warpedElectrodes,
            dipoles: warpedDipoles,
            reference: reference,
            harmonicTerms: harmonicTerms,
            tolerance: tolerance
        )
    }

    private static func warp(
        _ point: SIMD3<Double>,
        center: SIMD3<Double>,
        by factor: SIMD3<Double>
    ) -> SIMD3<Double> {
        SIMD3<Double>(
            center.x + (point.x - center.x) * factor.x,
            center.y + (point.y - center.y) * factor.y,
            center.z + (point.z - center.z) * factor.z
        )
    }

    private static func warpedUnitOrientation(
        _ orientation: SIMD3<Double>,
        by factor: SIMD3<Double>
    ) -> SIMD3<Double> {
        let mapped = SIMD3<Double>(
            orientation.x * factor.x,
            orientation.y * factor.y,
            orientation.z * factor.z
        )
        let length = (mapped.x * mapped.x + mapped.y * mapped.y + mapped.z * mapped.z).squareRoot()
        // Fall back to the original orientation if the warp collapses it, so the
        // spherical solver still receives a unit vector rather than NaN.
        return length > 1e-15
            ? SIMD3<Double>(mapped.x / length, mapped.y / length, mapped.z / length)
            : orientation
    }
}
