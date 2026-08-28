//
//  SurrogateBrainBasis.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The brain half of the surrogate model: regional sources spread through the
//  brain compartment, turned into the sensor-space basis that
//  `SourceInformedSeparation` regularizes (ROADMAP SI-3).
//
//  ## What a regional source is
//
//  One location, three orthogonal dipoles. Any source orientation at that
//  location is a linear combination of the three, so the basis represents
//  orientation without ever estimating it — 29 regional sources give 87 columns.
//  That is the Berg–Scherg construction the MSEC/PCA-S family is built on, and
//  it is why the brain block can describe plausible brain activity while a small
//  artifact dictionary describes the artifact.
//
//  ## Why the placement matters, and why it is deliberately volumetric
//
//  Radii vary with the cube root of a low-discrepancy sequence, so the sources
//  fill the compartment instead of sitting on a shell, and the basis reaches to
//  95% of the brain radius. A basis that stops short of the generators it has to
//  represent describes their topographies only with large coefficients, which
//  the regularization then suppresses — so the brain block explains less than it
//  should and the artifact block takes up the slack, removing brain signal.
//
//  The constants are the same ones EVASimulate uses (its roadmap 5.2), so a
//  correction measured against simulated truth is measured against the same
//  basis the app ships. Changing one and not the other silently invalidates
//  every published number.
//
//  ## What this is not
//
//  Not an inverse solution, and not a claim about where this subject's
//  generators are. It is a *span*: a description of the kinds of topographies
//  brains produce, used to decide what a filter is allowed to keep.
//

import Foundation

/// One regional source in a surrogate basis: a location, carrying three
/// orthogonal dipoles.
nonisolated struct SurrogateRegionalSource: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var positionMeters: SIMD3<Double>
}

/// The sensor-space brain basis and the facts needed to reproduce it.
nonisolated struct SurrogateBrainBasis: Sendable, Equatable {
    var sources: [SurrogateRegionalSource]
    /// electrodes × (3 × sources), in µV/(nA·m). The free-orientation operator.
    var matrix: [[Double]]
    var electrodeNames: [String]
    var reference: ForwardEEGReference
    var harmonicTerms: Int
    var headModelName: String
    var headShellRadiiMeters: [Double]

    var columnCount: Int { matrix.first?.count ?? 0 }
    var electrodeCount: Int { matrix.count }
}

nonisolated enum SurrogateBrainModel {

    /// How far out the basis reaches, as a fraction of the brain radius.
    ///
    /// Cortical generators are superficial and BESA's published surrogate model
    /// covers the whole brain volume including its surface, so the basis reaches
    /// past the depth simulated sources are placed at (0.85) rather than
    /// stopping inside it.
    static let maximumRadiusFraction = 0.95

    /// The published regional-source count for this family.
    static let defaultRegionalSourceCount = 29

    /// Deterministic volumetric placement of `count` regional sources.
    ///
    /// Pure function of the head model and the count: two runs, two machines,
    /// and the simulator all produce the same positions, which is what lets a
    /// history node claim to reproduce its own bytes.
    static func regionalSourcePositions(
        head: ForwardHeadModel,
        count: Int
    ) -> [SIMD3<Double>] {
        let maximumRadius = head.brainRadiusMeters * maximumRadiusFraction
        return (0..<max(count, 0)).map { index in
            let n = Double(index) + 0.5
            let u = fractionalPart(n * 0.383_248_248_248_2 + 0.137)
            let radius = maximumRadius * pow(u, 1.0 / 3.0)
            let z = 1 - 2 * fractionalPart(n * 0.723_606_797_749_979 + 0.271)
            let azimuth = 2 * Double.pi * fractionalPart(n * 0.381_966_011_250_105 + 0.613)
            let horizontal = max(0, 1 - z * z).squareRoot()
            let direction = SIMD3<Double>(
                horizontal * cos(azimuth),
                horizontal * sin(azimuth),
                z
            )
            return head.centerMeters + direction * radius
        }
    }

    /// Builds the basis for one electrode set.
    ///
    /// The `reference` is part of the basis, not a formatting detail: a lead
    /// field computed against a different reference than the data describes
    /// different topographies, and mixing the two is the quiet way to make a
    /// source-informed filter remove the wrong thing.
    static func basis(
        head: ForwardHeadModel = .classicThreeShell,
        electrodes: OrderedElectrodes,
        regionalSourceCount: Int = defaultRegionalSourceCount,
        reference: ForwardEEGReference = .average,
        harmonicTerms: Int
    ) throws -> SurrogateBrainBasis {
        let positions = regionalSourcePositions(head: head, count: regionalSourceCount)
        let dipoles = positions.enumerated().map { index, position in
            ForwardDipole(
                id: String(format: "R%03d", index + 1),
                positionMeters: position,
                // The oriented column is unused — the free-orientation operator
                // already carries all three axes, which is what a regional
                // source needs — but the solver requires a unit orientation.
                orientationUnit: SIMD3<Double>(0, 0, 1)
            )
        }
        let field = try SphericalForwardModel.leadField(
            head: head,
            electrodes: electrodes,
            dipoles: dipoles,
            reference: reference,
            harmonicTerms: harmonicTerms
        )
        return SurrogateBrainBasis(
            sources: dipoles.map {
                SurrogateRegionalSource(id: $0.id, positionMeters: $0.positionMeters)
            },
            matrix: field.freeMicrovoltsPerNanoampereMeter,
            electrodeNames: field.electrodeNames,
            reference: reference,
            harmonicTerms: harmonicTerms,
            headModelName: head.name,
            headShellRadiiMeters: head.shells.map(\.radiusMeters)
        )
    }

    private static func fractionalPart(_ value: Double) -> Double {
        value - value.rounded(.down)
    }
}
