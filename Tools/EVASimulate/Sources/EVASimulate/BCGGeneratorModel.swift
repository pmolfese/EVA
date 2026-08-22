//
//  BCGGeneratorModel.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The ballistocardiogram as several distinct physical generators, replacing the
//  single channel-index cosine (roadmap 4.1 and 4.2).
//
//  Two things were wrong with the old model, and they are different problems.
//
//  **It was not spatial.** Every channel's weight came from
//  `0.35 + 0.65·cos(2π·channel/N)` — a function of the channel's *index*, not of
//  where the electrode sits. That is the same circular-neighbour structure the
//  README already declares as a limitation of the default Grouiller spatial
//  model, except it survived `--eeg-model dipole`, so an otherwise physically
//  consistent run still handed every spatially-aware correction method a
//  topography no montage produces. PCA, ICA, and EVA's topography-gated,
//  -aligned and -weighted OBS strategies all key on exactly that structure.
//
//  **It was rank one.** One template times one scalar per channel. Per-channel
//  latency adds only approximate rank, so the whole artifact lived in about one
//  spatial dimension. Rusiniak et al. (2022) report 4-8 principal components per
//  subject (mean 5.7), and FMRIB's OBS default of 4 exists because the real
//  artifact has that rank. Against a rank-one artifact, OBS-4 is trivially
//  near-optimal and PCA-S, ICA-S and OBS become indistinguishable — the
//  comparison most worth running was the one the model could not resolve.
//
//  The fix for both is the same: stop asserting a topography, and let it fall
//  out of several generators that are actually different physical events. Rank
//  then *emerges* rather than being dialled in.
//
//  ## The generators
//
//  Four, in the order they arrive after the R wave:
//
//  1. **Aortic flow.** Blood ejected into the aortic arch moves through B0, and
//     the Hall separation of charge is seen from the head as a distant source.
//     Earliest, deep, spatially very broad.
//  2. **Vessel pulsation, left and right.** The pulse wave reaches the
//     superficial temporal arteries and moves the electrodes sitting over them.
//     Focal, lateral, and *separately* seeded left and right with slightly
//     different transit delays — which is a large part of where realistic rank
//     comes from.
//  3. **Head rotation.** Mechanical recoil nods the head in the static field.
//     Latest, largest, spatially broad but with a different structure from the
//     aortic term.
//
//  ## What is derived and what is modelled
//
//  Declared honestly, because it matters when interpreting a result:
//
//  * The **head-rotation topography is derived**. For a rigid rotation with
//    angular velocity ω about axis â in a uniform field B, a point at r moves
//    with v = ω(â × r) and sees a motional field E = v × B. Nodding about the
//    left-right axis (â = x̂) in a bore field along the head-foot axis (B = B ẑ)
//    gives E = -ωB·z·x̂, and with E = -∇Φ that integrates to **Φ ∝ x·z**. This
//    is the leading-order term for a uniform conductor; a full solution would
//    solve ∇·(σ(E - ∇Φ)) = 0 with the scalp boundary condition, which would
//    change the amplitude but not the qualitative structure.
//  * The **aortic topography is derived** in the same sense: a current dipole
//    in a homogeneous conductor, placed in the chest and oriented along the
//    Hall direction v × B. The head shells are not used because the source is
//    outside them.
//  * The **vessel topographies are modelled, not derived.** Electrode motion
//    over a vessel is a moving half-cell potential, not a current source, so
//    there is no dipole to project. A decaying kernel in geodesic distance from
//    the vessel site is a declared simulator choice.
//  * **Relative amplitudes and delays are plausible, not measured.** They are
//    chosen so the composite resembles a published BCG, and any claim that
//    turns on their exact values is weak evidence. Use `--bcg-template` when
//    morphology is central.
//

import Foundation

nonisolated enum BCGSpatialModel: String, Codable, Sendable {
    /// The original `0.35 + 0.65·cos(2π·channel/N)` weighting. Kept as the
    /// default so the published benchmark reproduces unchanged.
    case channelIndex
    /// Physically placed generators, per the documentation above.
    case generators
}

nonisolated struct BCGGeneratorTruth: Codable, Sendable {
    var id: String
    var kind: String
    /// Where the topography comes from, so a reader can tell derived from modelled.
    var provenance: String
    /// Per-channel weight, normalized to unit peak magnitude.
    var topography: [Double]
    /// Delay of this generator's peak after the R wave.
    var delaySeconds: Double
    var widthSeconds: Double
    /// Share of the composite artifact before per-beat variation.
    var relativeAmplitude: Double
    /// Per-beat multiplier actually used. Independent across generators, which
    /// is what makes composite *morphology* vary rather than only amplitude.
    var beatWeights: [Double]
}

nonisolated struct BCGGeneratorSet: Sendable {
    var generators: [BCGGeneratorTruth]
    /// Normalized singular values of the channels x generators topography
    /// matrix, largest first.
    var normalizedSingularValues: [Double]
    /// Count of singular values above 1% of the largest — the spatial rank a
    /// PCA-based method actually has to account for.
    var spatialRank: Int
    var fieldStrengthTesla: Double
}

nonisolated enum BCGGeneratorModel {

    /// Builds the generator set for a montage. Deterministic given the config;
    /// the per-beat weights come from a dedicated stream so adding or removing
    /// generators cannot move any other layer's realization.
    static func makeGenerators(
        config: SimulationConfig,
        montage: Montage,
        beatCount: Int
    ) -> BCGGeneratorSet {
        let head = config.sphericalHeadModel
        let radius = head.scalpRadiusMeters
        let sensors = montage.positions.map {
            head.centerMeters + Vector3D(x: $0.x, y: $0.y, z: $0.z) * radius
        }

        var specifications = [
            aorticFlow(sensors: sensors, head: head),
            vesselPulsation(sensors: sensors, head: head, side: .left),
            vesselPulsation(sensors: sensors, head: head, side: .right),
            headRotation(sensors: sensors, head: head)
        ]

        // Per-beat weights: each generator varies independently around its
        // nominal share. Because the generators differ in both topography and
        // delay, independent weights make the composite change *shape* from beat
        // to beat, not just size — the property the README previously listed as
        // a limitation and the one that separates PCA-based from ICA-based
        // correction.
        for index in specifications.indices {
            var random = GaussianSource(
                seed: SimulationSeedStreams.bcgGenerator(base: config.seed, index: index)
            )
            specifications[index].beatWeights = (0..<beatCount).map { _ in
                max(0, 1 + config.effectiveBCGMorphologyJitterFraction * random.gaussian())
            }
        }

        let matrix = specifications.map(\.topography)
        let singularValues = normalizedSingularValues(topographies: matrix)
        return BCGGeneratorSet(
            generators: specifications,
            normalizedSingularValues: singularValues,
            spatialRank: singularValues.filter { $0 > 0.01 }.count,
            fieldStrengthTesla: config.effectiveBCGFieldStrengthTesla
        )
    }

    /// Amplitude scaling relative to the 3 T reference the paper's 10-200 µV
    /// range describes. Both motional EMF and the Hall separation are linear in
    /// B, so one factor covers every generator.
    static func fieldStrengthScale(_ config: SimulationConfig) -> Double {
        config.effectiveBCGFieldStrengthTesla / 3.0
    }

    // MARK: - Individual generators

    private enum Side { case left, right }

    /// Distant current dipole in the chest. Derived: a dipole field in a
    /// homogeneous conductor, seen from far enough away that it reaches the
    /// scalp as a broad, smooth gradient.
    private static func aorticFlow(
        sensors: [Vector3D], head: SphericalHeadModel
    ) -> BCGGeneratorTruth {
        // Roughly the aortic arch: below the head, slightly anterior. Flow there
        // is superior-then-anterior, and v x B with B along the head-foot axis
        // puts the Hall separation along the left-right axis.
        let position = head.centerMeters + Vector3D(x: 0, y: 0.02, z: -0.26)
        let orientation = Vector3D(x: 1, y: 0, z: 0)
        let topography = normalized(sensors.map {
            homogeneousDipolePotential(sensor: $0, source: position, orientation: orientation)
        })
        return BCGGeneratorTruth(
            id: "BCG-aortic",
            kind: "aorticFlow",
            provenance: "derived: homogeneous-conductor current dipole in the chest, "
                + "oriented along the Hall direction v x B",
            topography: topography,
            delaySeconds: 0.085,
            widthSeconds: 0.055,
            relativeAmplitude: 0.30,
            beatWeights: []
        )
    }

    /// Electrode motion over a superficial temporal artery. Modelled, not
    /// derived: a moving half-cell potential is not a current source, so there
    /// is nothing to project through a volume conductor. The kernel decays in
    /// angular distance from the vessel site.
    private static func vesselPulsation(
        sensors: [Vector3D], head: SphericalHeadModel, side: Side
    ) -> BCGGeneratorTruth {
        let sign: Double = side == .left ? -1 : 1
        // Lateral and slightly anterior, above the ear: where the superficial
        // temporal artery runs.
        let site = Vector3D(x: sign * 0.93, y: 0.22, z: 0.30).normalized()
        let concentration = 0.40 // radians; focal, unlike the other two
        let topography = normalized(sensors.map { sensor in
            let direction = (sensor - head.centerMeters).normalized()
            let angle = acos(max(-1, min(1, direction.dot(site))))
            return exp(-0.5 * (angle / concentration) * (angle / concentration))
        })
        return BCGGeneratorTruth(
            id: side == .left ? "BCG-vessel-left" : "BCG-vessel-right",
            kind: "vesselPulsation",
            provenance: "modelled: Gaussian kernel in angular distance from the "
                + "superficial temporal artery; electrode motion is not a current source",
            topography: topography,
            // The pulse reaches one side marginally before the other. Small, but
            // it is real, and it stops the pair from being a single symmetric
            // component that PCA would collapse.
            delaySeconds: side == .left ? 0.158 : 0.166,
            widthSeconds: 0.038,
            relativeAmplitude: 0.22,
            beatWeights: []
        )
    }

    /// Rigid head nodding in the static field. Derived: see the file comment —
    /// rotation about the left-right axis in a head-foot bore field gives a
    /// motional field E = -wB·z·x, whose potential is proportional to x·z.
    private static func headRotation(
        sensors: [Vector3D], head: SphericalHeadModel
    ) -> BCGGeneratorTruth {
        let radius = max(head.scalpRadiusMeters, 1e-9)
        let topography = normalized(sensors.map { sensor in
            let offset = (sensor - head.centerMeters) * (1 / radius)
            return offset.x * offset.z
        })
        return BCGGeneratorTruth(
            id: "BCG-rotation",
            kind: "headRotation",
            provenance: "derived: leading-order motional potential of a rigid "
                + "rotation about the left-right axis in a uniform B0, phi ∝ x·z",
            topography: topography,
            delaySeconds: 0.212,
            widthSeconds: 0.062,
            relativeAmplitude: 0.40,
            beatWeights: []
        )
    }

    // MARK: - Helpers

    /// Current-dipole potential in an unbounded homogeneous conductor, up to a
    /// constant. `OcularDipoleModel` keeps its own copy of this deliberately:
    /// sharing one would be tidier, but it would change ocular output and move
    /// determinism baselines for a refactor that buys nothing.
    static func homogeneousDipolePotential(
        sensor: Vector3D, source: Vector3D, orientation: Vector3D
    ) -> Double {
        let displacement = sensor - source
        let distance = displacement.norm
        guard distance > 1e-9 else { return 0 }
        return orientation.dot(displacement) / (distance * distance * distance)
    }

    /// Scales to unit peak magnitude. The reference is *not* applied here — the
    /// composite meets one declared reference at the injection boundary
    /// (roadmap 4.6), and subtracting a mean per layer would break that.
    private static func normalized(_ values: [Double]) -> [Double] {
        let peak = values.map(abs).max() ?? 0
        guard peak > 1e-15 else { return values }
        return values.map { $0 / peak }
    }

    /// Singular values of the channels x generators topography matrix,
    /// normalized to the largest. Computed as the square roots of the
    /// eigenvalues of the (small) Gram matrix, which avoids needing a full SVD.
    ///
    /// This is the number that answers roadmap 4.2: the old model had one
    /// non-negligible value, and a correction method that removes four
    /// components was therefore being handed a problem it could not fail.
    static func normalizedSingularValues(topographies: [[Double]]) -> [Double] {
        guard !topographies.isEmpty else { return [] }
        let count = topographies.count
        var gram = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
        for row in 0..<count {
            for column in row..<count {
                let value = zip(topographies[row], topographies[column])
                    .reduce(0.0) { $0 + $1.0 * $1.1 }
                gram[row][column] = value
                gram[column][row] = value
            }
        }
        let eigenvalues = SymmetricEigen.eigenvalues(gram)
        let singular = eigenvalues.map { max(0, $0).squareRoot() }.sorted(by: >)
        guard let largest = singular.first, largest > 1e-15 else { return singular }
        return singular.map { $0 / largest }
    }
}

/// Cyclic Jacobi eigenvalue solver for small real symmetric matrices.
///
/// Written for the BCG spatial-rank diagnostic, but deliberately general: the
/// surrogate separation in roadmap 5.2 needs a PCA of the beat-averaged artifact
/// template, which is the same computation on a channels x channels covariance.
nonisolated enum SymmetricEigen {
    static func eigenvalues(_ matrix: [[Double]]) -> [Double] {
        decompose(matrix).values
    }

    /// Returns eigenvalues in descending order with the matching eigenvectors as
    /// rows, so `vectors[i]` belongs to `values[i]`.
    static func decompose(
        _ matrix: [[Double]], sweeps: Int = 60, tolerance: Double = 1e-14
    ) -> (values: [Double], vectors: [[Double]]) {
        let n = matrix.count
        guard n > 0, matrix.allSatisfy({ $0.count == n }) else { return ([], []) }
        var a = matrix
        var v = (0..<n).map { row in
            (0..<n).map { column in row == column ? 1.0 : 0.0 }
        }

        for _ in 0..<sweeps {
            var offDiagonal = 0.0
            for row in 0..<n {
                for column in (row + 1)..<n { offDiagonal += a[row][column] * a[row][column] }
            }
            if offDiagonal <= tolerance { break }

            for p in 0..<n {
                for q in (p + 1)..<n {
                    guard abs(a[p][q]) > tolerance else { continue }
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let sign: Double = theta >= 0 ? 1 : -1
                    let t = sign / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot()
                    let s = t * c

                    for k in 0..<n {
                        let akp = a[k][p]
                        let akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p][k]
                        let aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k][p]
                        let vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }

        let order = (0..<n).sorted { a[$0][$0] > a[$1][$1] }
        return (
            order.map { a[$0][$0] },
            order.map { column in (0..<n).map { row in v[row][column] } }
        )
    }
}
