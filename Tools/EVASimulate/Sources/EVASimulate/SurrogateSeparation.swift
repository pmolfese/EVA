//
//  SurrogateSeparation.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Surrogate-source separation of the ballistocardiogram (roadmap 5.2).
//
//  Reimplements the PCA-surrogate method evaluated in:
//
//    Rusiniak M, Bornfleth H, Cho J-H, Wolak T, Ille N, Berg P, Scherg M (2022).
//    EEG-fMRI: Ballistocardiogram Artifact Reduction by Surrogate Method for
//    Improved Source Localization. Front. Neurosci. 16:842420.
//
//  which in turn applies the source-space separation of Berg & Scherg (1994).
//  Written from the published description; no implementation is copied.
//
//  ## The idea
//
//  Template subtraction removes an *average* artifact. Blind separation removes
//  *components* chosen by a statistical criterion. The surrogate method does
//  neither: it writes the recording as the sum of a fixed brain model and a
//  small artifact model, solves for both at once, and reconstructs using only
//  the brain part. Nothing that the brain model can explain is ever removed,
//  which is why it distorts evoked responses less.
//
//  Four steps:
//
//  1. **A brain surrogate basis.** Regional sources spread through the brain
//     compartment, each a triple of orthogonal dipoles, so any source
//     orientation is representable. 29 regional sources = 87 columns.
//  2. **Artifact topographies.** Average the artifact over detected beats, then
//     take the principal components of that template that carry more than 0.5%
//     of its variance. The paper reports 4-8 per subject, mean 5.7.
//  3. **One regularized joint solve for `[brain | artifact]`.** The brain block
//     is regularized at 2%; the artifact block is not. The implementation
//     partials out the free artifact block and solves the remaining
//     positive-definite brain system without materializing an inverse.
//  4. **Back-project the brain block only.**
//
//  ## Why the regularization *is* the method
//
//  Worth stating plainly, because it is easy to implement this and not realize
//  what is doing the work. With 20 channels and 87 brain columns, the brain
//  basis already spans the entire sensor space — it can represent the artifact
//  perfectly well. There is no dimension deficit forcing the artifact into the
//  artifact columns.
//
//  What separates them is the *asymmetry*: the brain block pays a penalty and
//  the artifact block does not, so any variance the artifact topographies can
//  explain is cheaper to put there. Separation is bought entirely by that
//  asymmetry.
//
//  Two consequences. The 2% figure is not a detail to be tuned away — halve it
//  and the method removes less; raise it and it starts eating brain signal. And
//  the channel count matters more than it appears: at 64 channels the brain
//  model is a tighter description of what brains can produce, so the artifact
//  columns take up more of the slack. A 20-channel evaluation understates the
//  method.
//
//  ## Scope
//
//  This implements **PCA-S**. ICA-S differs only in where the artifact
//  topographies come from — manually or automatically selected ICA components
//  instead of template principal components — and is deliberately left out for
//  now: it needs an ICA, and a *fair* evaluation of it additionally needs the
//  non-stationarity work, because stationary Gaussian sources satisfy ICA's
//  assumptions artificially well. See roadmap 5.3.
//

import Foundation

nonisolated struct SurrogateBrainModel: Sendable {
    var sources: [SimulatedSource]
    /// channels x (3 * sources), the free-orientation operator.
    var matrix: [[Double]]

    var columnCount: Int { matrix.first?.count ?? 0 }
}

/// How the representative BCG pattern is chosen before beat averaging.
///
/// `paper` follows the published procedure as closely as an unattended command
/// can: select one deterministic representative beat, correlate every candidate
/// against it once, then average the accepted beats. `iterative` is EVA's more
/// noise-tolerant variant: initialize from the all-beat average and refine the
/// accepted set twice. They are intentionally separate because the latter is a
/// useful algorithm, but it is not the procedure described in the paper.
nonisolated enum ArtifactPatternSearchMode: String, Codable, Sendable, CaseIterable {
    case paper
    case iterative
}

nonisolated struct ArtifactComponentSet: Sendable {
    /// channels x components, unit-norm topographies.
    var topographies: [[Double]]
    /// Share of template variance carried by each retained component.
    var varianceFractions: [Double]
    /// Beats that passed the pattern-search correlation threshold.
    var acceptedBeatCount: Int
    var candidateBeatCount: Int
    /// The averaged artifact template, channels x samples.
    var template: [[Double]]
    var templateStartSeconds: Double
    var patternSearchMode: ArtifactPatternSearchMode
    /// Candidate-epoch index selected as the representative beat in paper mode.
    /// Nil for iterative mode, which starts from the all-beat average.
    var representativeBeatIndex: Int?
}

nonisolated struct SurrogateFilterReport: Codable, Sendable {
    var method: String
    var regionalSourceCount: Int
    var brainColumnCount: Int
    var artifactComponentCount: Int
    var artifactVarianceFractions: [Double]
    var acceptedBeatCount: Int
    var candidateBeatCount: Int
    var patternSearchMode: String
    var representativeBeatIndex: Int?
    var brainRegularization: Double
    /// Stable-solve dimensions and numerical provenance from EVA's shared
    /// source-informed engine.
    var operatorDiagnostics: SourceInformedOperatorDiagnostics? = nil
    /// Provenance of the geometry actually used to build the brain basis.
    var geometrySource: String? = nil
    var geometryPath: String? = nil
    var montageName: String? = nil
    var electrodeCount: Int? = nil
    var assumedStandardMontage: Bool? = nil
    var headModelSource: String? = nil
    var headModelName: String? = nil
    var headShellRadiiMeters: [Double]? = nil
    var leadFieldTerms: Int? = nil
    /// PNS is not corrected by PCA-S, but must survive the MFF round trip.
    var pnsPreserved: Bool? = nil
    var pnsChannelCount: Int? = nil
    var pnsChannelNames: [String]? = nil
    /// Deliberate displacement applied to the surrogate basis, in millimetres.
    var surrogateOffsetMillimetres: Double = 0
    /// Distance from each surrogate regional source to the nearest simulated
    /// source, in millimetres. Present when the truth sidecar is available.
    ///
    /// This is not decoration. If the surrogate basis sits where the simulated
    /// sources sit, the brain model fits the simulated activity perfectly and
    /// the comparison is rigged in this method's favour before it starts — see
    /// roadmap 5.3. The number belongs in the report so a reader can check.
    var nearestSimulatedSourceMillimetres: [Double]?
    var minimumSourceSeparationMillimetres: Double?
}

nonisolated enum SurrogateSeparation {

    // MARK: - Brain surrogate model

    /// Regional sources spread through the brain volume.
    ///
    /// Deliberately **volumetric** — radii vary with the cube root of a
    /// low-discrepancy sequence, so the set fills the compartment rather than
    /// sitting on a shell. `DipoleEEGGenerator.stableDirection` places simulated
    /// sources on a shell at a fixed radius fraction, and a surrogate basis that
    /// happened to coincide with it would make this method look better than it
    /// is. Different sequence offsets are used here for the same reason.
    /// How far out the basis reaches, as a fraction of the brain radius.
    ///
    /// A basis that stops short of the sources it has to represent describes
    /// their topographies only with large coefficients, which the regularization
    /// then suppresses — so the brain block explains less than it should and the
    /// artifact block takes up the slack. Cortical generators are superficial,
    /// and BESA's published surrogate model covers the whole brain volume
    /// including its surface, so the basis reaches past the depth the simulator
    /// places sources at (0.85) rather than stopping inside it.
    ///
    /// Verified by `selftest`: dipole topographies at 0.85 survive the filter
    /// with correlation 1.000 unregularized and 0.995 at the paper's 2%.
    static let maximumRadiusFraction = 0.95

    /// Displaces the whole basis by `offsetMillimetres` in a deterministic,
    /// per-source direction.
    ///
    /// The point of a *controlled* mismatch: the surrogate model in a real
    /// analysis is never where the subject's generators actually are, and the
    /// method's tolerance to that is the question the original paper could not
    /// ask — it had no ground truth for source position. Sweeping this
    /// parameter turns "we did not rig it" from an assurance into a measurement.
    ///
    /// The displacement is **tangential**: each source is rotated about the head
    /// centre by `offset / radius` radians, so its depth is preserved exactly
    /// and only its lateral position changes.
    ///
    /// A free displacement is the obvious implementation and it is wrong. Moving
    /// sources in arbitrary directions pushes some of them out of the brain
    /// compartment, which then has to be clamped — and the clamp drags them
    /// *outward*, toward the superficial shell where the simulated sources live.
    /// Measured with that version: the basis's minimum distance to a simulated
    /// source went 15.9 mm at zero offset to 6.5 mm at 20 mm offset, and
    /// correction quality *improved* with mismatch. The knob was measuring
    /// depth, not mismatch. Rotating preserves depth and leaves lateral
    /// displacement as the only thing varying.
    static func regionalSourcePositions(
        head: SphericalHeadModel, count: Int, offsetMillimetres: Double = 0
    ) -> [Vector3D] {
        let maximumRadius = head.brainRadiusMeters * maximumRadiusFraction
        let offset = offsetMillimetres / 1000
        return (0..<count).map { index in
            let n = Double(index) + 0.5
            let u = fractionalPart(n * 0.383_248_248_248_2 + 0.137)
            let radius = maximumRadius * pow(u, 1.0 / 3.0)
            let z = 1 - 2 * fractionalPart(n * 0.723_606_797_749_979 + 0.271)
            let azimuth = 2 * Double.pi * fractionalPart(n * 0.381_966_011_250_105 + 0.613)
            let horizontal = max(0, 1 - z * z).squareRoot()
            let direction = Vector3D(
                x: horizontal * cos(azimuth), y: horizontal * sin(azimuth), z: z
            )
            var finalDirection = direction
            if offset != 0, radius > 1e-9 {
                let n = Double(index) + 0.5
                let phi = 2 * Double.pi * fractionalPart(n * 0.618_033_988_749_895 + 0.041)
                // Any axis perpendicular to the radius rotates the source
                // tangentially; spread the choice so the basis deforms rather
                // than rotating rigidly, which would leave relative geometry
                // intact and understate the effect.
                let reference = abs(direction.z) < 0.9
                    ? Vector3D(x: 0, y: 0, z: 1)
                    : Vector3D(x: 1, y: 0, z: 0)
                let tangentA = direction.cross(reference).normalized()
                let tangentB = direction.cross(tangentA).normalized()
                let axis = (tangentA * cos(phi) + tangentB * sin(phi)).normalized()
                finalDirection = direction.rotated(around: axis, radians: offset / radius)
                    .normalized()
            }
            return head.centerMeters + finalDirection * radius
        }
    }

    static func brainModel(
        head: SphericalHeadModel,
        montage: Montage,
        count: Int,
        reference: EEGReference,
        terms: Int,
        offsetMillimetres: Double = 0
    ) throws -> SurrogateBrainModel {
        let positions = regionalSourcePositions(
            head: head, count: count, offsetMillimetres: offsetMillimetres
        )
        let sources = positions.enumerated().map { index, position in
            SimulatedSource(
                id: String(format: "R%03d", index + 1),
                positionMeters: position,
                // A regional source is three orthogonal dipoles at one location.
                // The oriented column is unused; the free-orientation operator
                // already carries all three axes, which is exactly what a
                // regional source needs.
                orientation: Vector3D(x: 0, y: 0, z: 1),
                bandName: "surrogate regional source",
                seed: 0,
                rmsMomentNanoampereMeters: 0,
                scenarioRole: "brain surrogate basis"
            )
        }
        let field = try SphericalForwardModel.leadField(
            head: head, montage: montage, sources: sources,
            reference: reference, terms: terms
        )
        return SurrogateBrainModel(
            sources: sources,
            matrix: field.freeOrientationMatrixMicrovoltsPerNanoampereMeter
        )
    }

    // MARK: - Artifact template and its principal components

    /// Builds the averaged artifact template and its principal components.
    ///
    /// In `.paper` mode: band-pass to the BCG range, use the explicitly requested
    /// representative beat or choose the median-energy beat as a deterministic
    /// stand-in for the paper's manual selection, retain beats whose
    /// spatio-temporal correlation with it exceeds `correlationThreshold` (the
    /// paper uses 60%), and average them.
    /// `.iterative` mode instead initializes from all beats and refines twice.
    /// Both modes then retain principal components above `varianceThreshold` of
    /// template variance (the paper uses 0.5%).
    static func artifactComponents(
        channels: [[Double]],
        samplingRate: Double,
        beatSeconds: [Double],
        windowStartSeconds: Double = -0.1,
        windowEndSeconds: Double = 0.6,
        lowHz: Double = 1,
        highHz: Double = 20,
        correlationThreshold: Double = 0.6,
        varianceThreshold: Double = 0.005,
        patternSearchMode: ArtifactPatternSearchMode = .paper,
        representativeBeatIndex requestedRepresentativeBeatIndex: Int? = nil
    ) -> ArtifactComponentSet? {
        guard !channels.isEmpty, !beatSeconds.isEmpty else { return nil }
        let filtered = channels.map {
            Filtering.bandPassZeroPhase(
                $0, samplingRate: samplingRate, lowHz: lowHz, highHz: highHz
            )
        }
        let sampleCount = filtered[0].count
        let offset = Int((windowStartSeconds * samplingRate).rounded())
        let length = max(2, Int(((windowEndSeconds - windowStartSeconds) * samplingRate).rounded()))

        var epochs: [[[Double]]] = []
        for beat in beatSeconds {
            let start = Int((beat * samplingRate).rounded()) + offset
            guard start >= 0, start + length <= sampleCount else { continue }
            epochs.append(filtered.map { Array($0[start..<(start + length)]) })
        }
        guard epochs.count >= 2 else { return nil }

        // Why expose two pattern-search modes instead of quietly choosing one.
        //
        // The paper's operator picks one representative beat by eye and matches
        // against it. Matching against a *single* epoch is a poor automatic
        // substitute: an individual beat carries a full share of ongoing EEG, so
        // the correlation it produces is diluted and the threshold rejects most
        // of the recording. Measured here: seeding from one median-energy beat
        // accepted 30 of 149, and the resulting template was contaminated enough
        // that its lower-variance components were EEG rather than artifact —
        // which the filter then removed from the data.
        //
        // Averaging first and re-matching against the average suppresses EEG by
        // sqrt(N) before the comparison, so the threshold judges beats against
        // the artifact rather than against one noisy example. That is the
        // `.iterative` variant. `.paper` retains the single-beat procedure so a
        // methods comparison can distinguish fidelity from the practical
        // improvement instead of conflating them.
        func average(_ selection: [[[Double]]]) -> [[Double]] {
            var result = [[Double]](
                repeating: [Double](repeating: 0, count: length), count: filtered.count
            )
            guard !selection.isEmpty else { return result }
            for epoch in selection {
                for channel in result.indices {
                    for sample in 0..<length { result[channel][sample] += epoch[channel][sample] }
                }
            }
            for channel in result.indices {
                for sample in 0..<length { result[channel][sample] /= Double(selection.count) }
            }
            return result
        }

        let template: [[Double]]
        let accepted: [[[Double]]]
        let selectedRepresentativeBeatIndex: Int?
        switch patternSearchMode {
        case .paper:
            // The publication chooses a representative beat manually. An
            // unattended, deterministic harness needs an explicit rule, so use
            // the median-energy epoch: unlike the largest beat it does not select
            // an outlier, and unlike an all-beat average it does not leak every
            // candidate into the reference pattern.
            var ranked: [(index: Int, energy: Double)] = []
            ranked.reserveCapacity(epochs.count)
            for (index, epoch) in epochs.enumerated() {
                var energy = 0.0
                for channel in epoch {
                    for value in channel { energy += value * value }
                }
                ranked.append((index: index, energy: energy))
            }
            ranked.sort {
                $0.energy == $1.energy ? $0.index < $1.index : $0.energy < $1.energy
            }
            let representative = requestedRepresentativeBeatIndex
                ?? ranked[ranked.count / 2].index
            guard epochs.indices.contains(representative) else { return nil }
            let seedTemplate = epochs[representative]
            let matched = epochs.filter {
                spatioTemporalCorrelation($0, seedTemplate) >= correlationThreshold
            }
            guard matched.count >= 2 else { return nil }
            accepted = matched
            template = average(matched)
            selectedRepresentativeBeatIndex = representative

        case .iterative:
            var refinedTemplate = average(epochs)
            var refinedAccepted = epochs
            for _ in 0..<2 {
                let matched = epochs.filter {
                    spatioTemporalCorrelation($0, refinedTemplate) >= correlationThreshold
                }
                // Never end up with nothing: if the threshold rejects everything
                // the previous selection stands, and the accepted count makes
                // that visible rather than silent.
                guard matched.count >= 2 else { break }
                refinedAccepted = matched
                refinedTemplate = average(refinedAccepted)
            }
            accepted = refinedAccepted
            template = refinedTemplate
            selectedRepresentativeBeatIndex = nil
        }

        // PCA over channels: the covariance is channels x channels, and its
        // eigenvectors are the spatial patterns the template is built from.
        let channelCount = template.count
        var covariance = [[Double]](
            repeating: [Double](repeating: 0, count: channelCount), count: channelCount
        )
        for row in 0..<channelCount {
            for column in row..<channelCount {
                var sum = 0.0
                for sample in 0..<length { sum += template[row][sample] * template[column][sample] }
                covariance[row][column] = sum
                covariance[column][row] = sum
            }
        }
        let decomposition = LinearAlgebra.symmetricEigenDecomposition(covariance)
        let total = decomposition.values.reduce(0.0) { $0 + max(0, $1) }
        guard total > 1e-30 else { return nil }

        var topographies: [[Double]] = []
        var fractions: [Double] = []
        // EVA's LAPACK wrapper stores eigenvectors as columns and values in
        // ascending order. PCA-S consumes the same eigenpairs largest-first.
        for component in decomposition.values.indices.reversed() {
            let value = decomposition.values[component]
            let vector = (0..<channelCount).map { decomposition.vectors[$0][component] }
            let fraction = max(0, value) / total
            guard fraction > varianceThreshold else { break }
            let norm = vector.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 1e-15 else { continue }
            topographies.append(vector.map { $0 / norm })
            fractions.append(fraction)
        }
        guard !topographies.isEmpty else { return nil }

        return ArtifactComponentSet(
            topographies: topographies,
            varianceFractions: fractions,
            acceptedBeatCount: accepted.count,
            candidateBeatCount: epochs.count,
            template: template,
            templateStartSeconds: windowStartSeconds,
            patternSearchMode: patternSearchMode,
            representativeBeatIndex: selectedRepresentativeBeatIndex
        )
    }

    /// Correlation over channels and time at once, which is what makes the
    /// pattern search spatio-temporal rather than a per-channel match.
    static func spatioTemporalCorrelation(_ lhs: [[Double]], _ rhs: [[Double]]) -> Double {
        var dot = 0.0
        var leftSquares = 0.0
        var rightSquares = 0.0
        for channel in 0..<min(lhs.count, rhs.count) {
            for sample in 0..<min(lhs[channel].count, rhs[channel].count) {
                let a = lhs[channel][sample]
                let b = rhs[channel][sample]
                dot += a * b
                leftSquares += a * a
                rightSquares += b * b
            }
        }
        let denominator = (leftSquares * rightSquares).squareRoot()
        return denominator > 1e-30 ? dot / denominator : 0
    }

    // MARK: - The spatial filter

    /// Adapts the simulator's regional-source value to EVA's UI-free engine.
    /// BCG discovery and regional placement remain simulator policies; all
    /// operator construction, validation, diagnostics, and application are
    /// app-owned.
    static func sourceInformedOperator(
        brain: SurrogateBrainModel,
        artifactTopographies: [[Double]],
        brainRegularization: Double
    ) throws -> SourceInformedOperator {
        try SourceInformedSeparation.makeOperator(
            brainBasis: brain.matrix,
            artifactTopographies: artifactTopographies,
            brainRegularization: brainRegularization
        )
    }

    /// Compatibility boundary for truth reports and existing simulator tests.
    static func spatialFilter(
        brain: SurrogateBrainModel,
        artifactTopographies: [[Double]],
        brainRegularization: Double
    ) throws -> [[Double]] {
        try sourceInformedOperator(
            brain: brain,
            artifactTopographies: artifactTopographies,
            brainRegularization: brainRegularization
        ).matrix
    }

    static func apply(filter: [[Double]], to channels: [[Double]]) throws -> [[Double]] {
        try SourceInformedSeparation.apply(matrix: filter, to: channels)
    }

    private static func fractionalPart(_ value: Double) -> Double { value - floor(value) }
}

/// Minimal zero-phase filtering, enough for the paper's 1-20 Hz template band.
///
/// Cascaded second-order Butterworth sections applied forward then backward, so
/// the template is not phase-shifted relative to the beat times it is averaged
/// on — which would smear it.
nonisolated enum Filtering {
    static func bandPassZeroPhase(
        _ signal: [Double], samplingRate: Double, lowHz: Double, highHz: Double
    ) -> [Double] {
        var output = signal
        if highHz > 0, highHz < samplingRate / 2 {
            output = filtfilt(output, coefficients: lowPass(cutoff: highHz, rate: samplingRate))
        }
        if lowHz > 0 {
            output = filtfilt(output, coefficients: highPass(cutoff: lowHz, rate: samplingRate))
        }
        return output
    }

    struct Biquad { var b0, b1, b2, a1, a2: Double }

    private static func lowPass(cutoff: Double, rate: Double) -> Biquad {
        let omega = tan(Double.pi * cutoff / rate)
        let norm = 1 / (1 + Double(2).squareRoot() * omega + omega * omega)
        return Biquad(
            b0: omega * omega * norm,
            b1: 2 * omega * omega * norm,
            b2: omega * omega * norm,
            a1: 2 * (omega * omega - 1) * norm,
            a2: (1 - Double(2).squareRoot() * omega + omega * omega) * norm
        )
    }

    private static func highPass(cutoff: Double, rate: Double) -> Biquad {
        let omega = tan(Double.pi * cutoff / rate)
        let norm = 1 / (1 + Double(2).squareRoot() * omega + omega * omega)
        return Biquad(
            b0: norm,
            b1: -2 * norm,
            b2: norm,
            a1: 2 * (omega * omega - 1) * norm,
            a2: (1 - Double(2).squareRoot() * omega + omega * omega) * norm
        )
    }

    private static func filtfilt(_ signal: [Double], coefficients: Biquad) -> [Double] {
        let forward = filter(signal, coefficients: coefficients)
        let backward = filter(Array(forward.reversed()), coefficients: coefficients)
        return Array(backward.reversed())
    }

    private static func filter(_ signal: [Double], coefficients c: Biquad) -> [Double] {
        var output = [Double](repeating: 0, count: signal.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for index in signal.indices {
            let x0 = signal[index]
            let y0 = c.b0 * x0 + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            output[index] = y0
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
        }
        return output
    }
}
