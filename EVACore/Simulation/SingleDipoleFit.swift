//
//  SingleDipoleFit.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-3 Stage 3c — the single equivalent-current-dipole (ECD) fit used purely as
//  a *localization diagnostic* for the Source Simulator.
//
//  This is deliberately the smallest, most classical inverse there is: one dipole,
//  nonlinear in position and linear in moment. Given the scalp field at one instant
//  it searches head positions for the one whose forward field best explains the
//  measurement, solving the 3-component moment in closed form at each candidate.
//  It is a *check on the forward truth*, not source imaging — fitting a single ECD
//  says nothing about a distributed generator and is intentionally kept on the far
//  side of the EVA Resolve boundary. On a clean single-dipole field it recovers the
//  generator to sub-millimetre; the point of the diagnostic is what happens as
//  noise, depth, or multiple simultaneous sources pull that error up.
//
//  The forward half is EVA's shared spherical solver: every candidate position is
//  submitted as one dipole in a single batched `leadField` call, so the whole grid
//  costs one spherical-harmonic setup rather than one per position. The linear
//  moment step reads the free-orientation (x/y/z) columns that call already keeps.
//

import Foundation

nonisolated enum SingleDipoleFit {

    /// One fitted equivalent dipole for a single field snapshot.
    struct Result: Sendable, Equatable {
        var positionMeters: Vector3D
        /// The fitted current moment in the montage frame, nA·m.
        var momentNanoampereMeters: Vector3D
        /// Unit direction of the moment (undefined sign — a dipole is a line).
        var orientationUnit: Vector3D
        var magnitudeNanoampereMeters: Double
        /// Fraction of the measured field variance the fitted dipole explains,
        /// 0…1. A clean single dipole scores ~1; a poor or multi-source field
        /// scores lower. Reported so a small localization error on a badly
        /// explained field is not mistaken for a good fit.
        var goodnessOfFit: Double
        /// RMS of the unexplained field, µV.
        var residualMicrovolts: Double
    }

    /// A fit paired with its error against the true active generator, when one
    /// is known (the simulator always knows its truth).
    struct Localization: Sendable {
        var fit: Result
        /// Whether the fit was run on the clean field or the contaminated one.
        var usedNoisyField: Bool
        var trueSourceName: String?
        var truePositionMeters: Vector3D?
        var positionErrorMillimeters: Double?
        /// Angle between fitted and true moment directions, folded for the
        /// dipole's inherent sign ambiguity (0° = aligned or anti-aligned).
        var orientationErrorDegrees: Double?
    }

    /// Several fitted dipoles for one field snapshot, from a sequential fit.
    struct MultiResult: Sendable {
        /// Per-dipole positions/moments/orientations. Each dipole's
        /// `goodnessOfFit` / `residualMicrovolts` carry the *overall* joint values
        /// (they describe the whole model, not the dipole alone).
        var dipoles: [Result]
        var goodnessOfFit: Double
        var residualMicrovolts: Double
    }

    /// A multi-dipole fit paired to the true generators, one pair per fitted
    /// dipole. Pairing is done by the caller (it knows the truth).
    struct MultiLocalization: Sendable {
        struct Pair: Sendable {
            var fit: Result
            var trueSourceName: String?
            var truePositionMeters: Vector3D?
            var positionErrorMillimeters: Double?
            var orientationErrorDegrees: Double?
        }
        var pairs: [Pair]
        var usedNoisyField: Bool
        var goodnessOfFit: Double
        var residualMicrovolts: Double
        /// True when the fit used a time interval (spatiotemporal) rather than a
        /// single playhead sample.
        var spatioTemporal: Bool = false
        /// Variance fraction per spatial principal component, descending — the
        /// SVD model-order spectrum of the fitted interval (how many dipoles the
        /// data actually supports). Empty for an instantaneous fit.
        var varianceSpectrum: [Double] = []
    }

    /// Fits one equivalent dipole to a single field snapshot.
    ///
    /// - Parameters:
    ///   - potentialsMicrovolts: measured scalp potentials in montage channel
    ///     order, µV. Must match `montage`'s channel count.
    ///   - head/montage/reference/harmonicTerms: the *same* forward description
    ///     the field was produced under. Fitting through a different head than the
    ///     one that generated the field is a mismatch experiment, not a bug — but
    ///     the caller must choose it deliberately.
    ///
    /// Returns `nil` when there is no field to fit (all-zero potentials), when the
    /// geometry yields no interior candidate, or when the batched forward solve
    /// fails.
    static func fit(
        potentialsMicrovolts b: [Double],
        head: SphericalHeadModel,
        montage: Montage,
        reference: EEGReference,
        harmonicTerms: Int
    ) -> Result? {
        let channelCount = montage.electrodes.count
        guard b.count == channelCount, channelCount >= 3 else { return nil }
        let total = b.reduce(0.0) { $0 + $1 * $1 }
        guard total > 1e-18 else { return nil }

        let brainRadius = head.brainRadiusMeters
        guard brainRadius > 0 else { return nil }
        let maxRadius = brainRadius * 0.97
        let center = head.centerMeters
        return search(
            field: b, total: total, channelCount: channelCount,
            brainRadius: brainRadius, maxRadius: maxRadius, center: center,
            head: head, montage: montage, reference: reference, harmonicTerms: harmonicTerms,
            seed: nil
        )
    }

    /// The position search shared by the global fit and the seeded re-fit. With
    /// `seed == nil` it opens with a coarse grid over the whole brain, then
    /// refines; with a seed it skips the global grid and refines locally around it
    /// (used by the multi-dipole relaxation, where each dipole is already close).
    private static func search(
        field b: [Double], total: Double, channelCount: Int,
        brainRadius: Double, maxRadius: Double, center: Vector3D,
        head: SphericalHeadModel, montage: Montage, reference: EEGReference, harmonicTerms: Int,
        seed: Vector3D?
    ) -> Result? {
        var best: (result: Result, position: Vector3D, rss: Double)?
        let global = seed == nil
        var searchCenter = seed ?? center
        // The global search opens coarse (~14 mm); a seeded search opens wide
        // enough (~18 mm cells, ±2 → ±36 mm reach) to correct the deflation seed.
        var step = global ? brainRadius / 5.0 : brainRadius / 4.0
        let levels = global ? 6 : 5

        for level in 0..<levels {
            let candidates: [Vector3D]
            if level == 0 && global {
                candidates = gridInsideSphere(center: center, maxRadius: maxRadius, step: step)
            } else {
                candidates = localGrid(
                    around: searchCenter, step: step, halfWidthInSteps: 2,
                    center: center, maxRadius: maxRadius
                )
            }
            guard !candidates.isEmpty else { break }

            guard let free = freeLeadField(
                candidates: candidates, head: head, montage: montage,
                reference: reference, harmonicTerms: harmonicTerms
            ) else {
                if level == 0 { return nil } else { break }
            }

            for (k, position) in candidates.enumerated() {
                guard let solved = solveMoment(
                    free: free, dipoleIndex: k, channelCount: channelCount, b: b
                ) else { continue }
                if best == nil || solved.residualSumOfSquares < best!.rss {
                    let gof = max(0.0, 1.0 - solved.residualSumOfSquares / total)
                    let magnitude = solved.moment.norm
                    let result = Result(
                        positionMeters: position,
                        momentNanoampereMeters: solved.moment,
                        orientationUnit: magnitude > 1e-15 ? solved.moment * (1 / magnitude) : Vector3D(x: 0, y: 0, z: 1),
                        magnitudeNanoampereMeters: magnitude,
                        goodnessOfFit: gof,
                        residualMicrovolts: (solved.residualSumOfSquares / Double(channelCount)).squareRoot()
                    )
                    best = (result, position, solved.residualSumOfSquares)
                }
            }

            guard let winner = best else { break }
            searchCenter = winner.position
            step *= 0.45
        }

        return best?.result
    }

    // MARK: - Multiple dipoles (sequential)

    /// Fits `count` equivalent dipoles: **sequential deflation** for an initial
    /// guess, then **block-coordinate relaxation** to the joint solution, then a
    /// final **joint moment re-solve**.
    ///
    /// Deflation alone (fit one ECD, subtract it, fit the next) leaves every dipole
    /// at a compromise position, because each is fit to a residual still polluted
    /// by the others' fitting error — two equal sources can each land tens of
    /// millimetres off. So deflation is only the seed. The refinement then sweeps
    /// the dipoles: for each one it subtracts the *current* fields of all the
    /// others and re-fits that dipole (position and moment) to what's left, which
    /// is nearly a clean single-dipole field once the others are roughly right.
    /// A few sweeps converge to the true multi-dipole configuration. A closing
    /// joint moment re-solve makes the moments mutually consistent and yields an
    /// honest joint goodness-of-fit.
    ///
    /// This is still not the global gold standard — a fully simultaneous position
    /// search over all dipoles at once localizes better when sources are close,
    /// synchronous, or noisy, where the relaxation can converge to a swapped or
    /// merged configuration. That instability is itself information the diagnostic
    /// surfaces; it is not hidden.
    static func fitMultiple(
        potentialsMicrovolts b: [Double],
        count: Int,
        head: SphericalHeadModel,
        montage: Montage,
        reference: EEGReference,
        harmonicTerms: Int
    ) -> MultiResult? {
        let channelCount = montage.electrodes.count
        guard count >= 1, b.count == channelCount, channelCount >= 3 else { return nil }
        let total = b.reduce(0.0) { $0 + $1 * $1 }
        guard total > 1e-18 else { return nil }

        func fitOne(_ field: [Double]) -> Result? {
            fit(potentialsMicrovolts: field, head: head, montage: montage,
                reference: reference, harmonicTerms: harmonicTerms)
        }
        // The channels-space field of one dipole (free operator × moment).
        func contribution(position: Vector3D, moment: Vector3D) -> [Double]? {
            guard let free = freeLeadField(
                candidates: [position], head: head, montage: montage,
                reference: reference, harmonicTerms: harmonicTerms
            ) else { return nil }
            return (0..<channelCount).map {
                free[$0][0] * moment.x + free[$0][1] * moment.y + free[$0][2] * moment.z
            }
        }

        // 1) Sequential deflation → initial positions (moments come from the joint
        //    solves below). Peeling one ECD at a time gives a rough starting guess.
        var residual = b
        var positions: [Vector3D] = []
        for _ in 0..<count {
            guard let one = fitOne(residual) else { break }
            positions.append(one.positionMeters)
            guard let cvec = contribution(position: one.positionMeters, moment: one.momentNanoampereMeters)
            else { break }
            for c in 0..<channelCount { residual[c] -= cvec[c] }
        }
        guard !positions.isEmpty else { return nil }
        let k = positions.count

        // 2) Joint coordinate descent on the *true* joint objective. For each
        //    dipole we search its position while holding the others fixed, and at
        //    every candidate we re-solve ALL moments together and score the full
        //    joint residual. This is the crucial difference from peeling: fitting a
        //    dipole to the deflated residual `b − others` only ever reaches a
        //    coordinated compromise (~1.5 cm off here) because the deflated field
        //    is not that dipole's true field; scoring the joint residual instead
        //    descends the actual least-squares surface and recovers well-separated
        //    sources to a few millimetres.
        if k >= 2 {
            let brainRadius = head.brainRadiusMeters
            let maxRadius = brainRadius * 0.97
            let center = head.centerMeters
            for _ in 0..<4 {
                var maxShift = 0.0
                for i in 0..<k {
                    let otherPositions = positions.enumerated().filter { $0.offset != i }.map(\.element)
                    guard let otherFree = otherPositions.isEmpty ? [[Double]]() : freeLeadField(
                        candidates: otherPositions, head: head, montage: montage,
                        reference: reference, harmonicTerms: harmonicTerms
                    ) else { continue }
                    var searchCenter = positions[i]
                    var step = brainRadius / 4.0
                    var bestPosition = positions[i]
                    for _ in 0..<5 {
                        let candidates = localGrid(
                            around: searchCenter, step: step, halfWidthInSteps: 2,
                            center: center, maxRadius: maxRadius)
                        guard !candidates.isEmpty,
                              let candidateFree = freeLeadField(
                                candidates: candidates, head: head, montage: montage,
                                reference: reference, harmonicTerms: harmonicTerms)
                        else { break }
                        var bestRss = Double.greatestFiniteMagnitude
                        for (m, candidate) in candidates.enumerated() {
                            let rss = jointResidual(
                                otherFree: otherFree, candidateFree: candidateFree, candidateIndex: m,
                                channelCount: channelCount, field: b)
                            if rss < bestRss { bestRss = rss; bestPosition = candidate }
                        }
                        searchCenter = bestPosition
                        step *= 0.45
                    }
                    maxShift = max(maxShift, (bestPosition - positions[i]).norm)
                    positions[i] = bestPosition
                }
                if maxShift < 5e-4 { break }   // converged to <0.5 mm
            }
        }

        // 3) Final joint moment re-solve at the converged positions.
        guard let joint = jointMomentSolve(
            positions: positions, field: b, channelCount: channelCount,
            head: head, montage: montage, reference: reference, harmonicTerms: harmonicTerms
        ) else { return nil }
        let gof = max(0.0, 1.0 - joint.rss / total)
        let residualRMS = (joint.rss / Double(channelCount)).squareRoot()

        var dipoles: [Result] = []
        for (index, position) in positions.enumerated() {
            let m = joint.moments[index]
            let magnitude = m.norm
            dipoles.append(Result(
                positionMeters: position,
                momentNanoampereMeters: m,
                orientationUnit: magnitude > 1e-15 ? m * (1 / magnitude) : Vector3D(x: 0, y: 0, z: 1),
                magnitudeNanoampereMeters: magnitude,
                goodnessOfFit: gof,
                residualMicrovolts: residualRMS
            ))
        }
        return MultiResult(dipoles: dipoles, goodnessOfFit: gof, residualMicrovolts: residualRMS)
    }

    /// Solves all dipole moments jointly at fixed positions against `field`, one
    /// linear least-squares over 3·positions unknowns. Returns per-dipole moments
    /// and the residual sum of squares.
    private static func jointMomentSolve(
        positions: [Vector3D], field b: [Double], channelCount: Int,
        head: SphericalHeadModel, montage: Montage, reference: EEGReference, harmonicTerms: Int
    ) -> (moments: [Vector3D], rss: Double)? {
        guard let free = freeLeadField(
            candidates: positions, head: head, montage: montage,
            reference: reference, harmonicTerms: harmonicTerms
        ) else { return nil }
        let unknowns = 3 * positions.count
        var normal = [[Double]](repeating: [Double](repeating: 0, count: unknowns), count: unknowns)
        var projection = [Double](repeating: 0, count: unknowns)
        for c in 0..<channelCount {
            let row = free[c]
            guard row.count >= unknowns else { return nil }
            for i in 0..<unknowns {
                projection[i] += row[i] * b[c]
                for j in i..<unknowns { normal[i][j] += row[i] * row[j] }
            }
        }
        for i in 0..<unknowns { for j in (i + 1)..<unknowns { normal[j][i] = normal[i][j] } }
        var trace = 0.0
        for i in 0..<unknowns { trace += normal[i][i] }
        let ridge = 1e-9 * trace / Double(unknowns)
        for i in 0..<unknowns { normal[i][i] += ridge }
        guard let solved = solveLinearSystem(normal, projection) else { return nil }

        var rss = 0.0
        for c in 0..<channelCount {
            var predicted = 0.0
            for i in 0..<unknowns { predicted += free[c][i] * solved[i] }
            let d = predicted - b[c]
            rss += d * d
        }
        var moments: [Vector3D] = []
        for index in positions.indices {
            moments.append(Vector3D(x: solved[3 * index], y: solved[3 * index + 1], z: solved[3 * index + 2]))
        }
        return (moments, rss)
    }

    /// The joint residual sum of squares if dipole `candidateIndex` takes the
    /// position whose free columns are in `candidateFree`, with the other dipoles
    /// held at the positions whose free columns are in `otherFree`. Solves all
    /// moments jointly and scores the full field — the objective the position
    /// search descends. Returns `+∞` for a singular system.
    private static func jointResidual(
        otherFree: [[Double]], candidateFree: [[Double]], candidateIndex: Int,
        channelCount: Int, field b: [Double]
    ) -> Double {
        let otherColumns = otherFree.first?.count ?? 0
        let unknowns = otherColumns + 3
        let base = 3 * candidateIndex
        func column(_ c: Int, _ i: Int) -> Double {
            i < otherColumns ? otherFree[c][i] : candidateFree[c][base + (i - otherColumns)]
        }
        var normal = [[Double]](repeating: [Double](repeating: 0, count: unknowns), count: unknowns)
        var projection = [Double](repeating: 0, count: unknowns)
        for c in 0..<channelCount {
            for i in 0..<unknowns {
                let vi = column(c, i)
                projection[i] += vi * b[c]
                for j in i..<unknowns { normal[i][j] += vi * column(c, j) }
            }
        }
        for i in 0..<unknowns { for j in (i + 1)..<unknowns { normal[j][i] = normal[i][j] } }
        var trace = 0.0
        for i in 0..<unknowns { trace += normal[i][i] }
        let ridge = 1e-9 * trace / Double(unknowns)
        for i in 0..<unknowns { normal[i][i] += ridge }
        guard let solved = solveLinearSystem(normal, projection) else { return .greatestFiniteMagnitude }
        var rss = 0.0
        for c in 0..<channelCount {
            var predicted = 0.0
            for i in 0..<unknowns { predicted += column(c, i) * solved[i] }
            let d = predicted - b[c]
            rss += d * d
        }
        return rss
    }

    // MARK: - Spatiotemporal (interval) fit

    /// Fits `count` dipoles to a whole time interval rather than one sample — the
    /// Scherg/Berg spatiotemporal approach.
    ///
    /// A single instantaneous topography is one spatial vector: two simultaneous
    /// sources collapse into one weighted sum, so an instant can't separate them.
    /// An interval can, *if* the sources have distinct time courses — then the
    /// channels×time data has rank ≥ 2 and the dipoles become identifiable. The
    /// whole computation reduces to the channels×channels covariance
    /// `C = data · dataᵀ`: the least-squares residual of a dipole set with free
    /// (per-sample) moments is `trace(C) − trace((LᵀL)⁻¹ LᵀC L)`, which needs the
    /// data only to form `C` once. Positions come from the same deflation +
    /// joint-objective coordinate descent as the instantaneous fit, scored on `C`;
    /// per-dipole orientation/magnitude and the model-order spectrum then come
    /// straight from `C` too.
    ///
    /// - Parameter data: channels × samples over the interval to fit.
    /// Returns the fitted dipoles and the variance spectrum (eigenvalues of `C`
    /// as fractions of the total, descending — the "how many dipoles" picture).
    static func fitSpatioTemporal(
        data: [[Double]],
        count: Int,
        head: SphericalHeadModel,
        montage: Montage,
        reference: EEGReference,
        harmonicTerms: Int
    ) -> (result: MultiResult, varianceSpectrum: [Double])? {
        let channelCount = montage.electrodes.count
        guard count >= 1, data.count == channelCount, channelCount >= 3 else { return nil }
        let sampleCount = data.first?.count ?? 0
        guard sampleCount >= 1,
              let (covariance, total) = covarianceOf(
                data: data, channelCount: channelCount, sampleCount: sampleCount)
        else { return nil }
        let spectrum = varianceSpectrum(of: covariance, total: total)
        guard let positions = fitPositionsFromCovariance(
            covariance: covariance, total: total, count: count, channelCount: channelCount,
            head: head, montage: montage, reference: reference, harmonicTerms: harmonicTerms
        ) else { return nil }
        guard let finalized = finalize(
            positions: positions, covariance: covariance, total: total, sampleCount: sampleCount,
            channelCount: channelCount, head: head, montage: montage,
            reference: reference, harmonicTerms: harmonicTerms
        ) else { return nil }
        return (MultiResult(
            dipoles: finalized.dipoles, goodnessOfFit: finalized.gof,
            residualMicrovolts: finalized.residualRMS), spectrum)
    }

    // MARK: - Shared-geometry multi-condition fit

    /// One condition's fit at the shared geometry.
    struct ConditionFit: Sendable {
        var name: String
        /// Dipoles at the shared positions, with this condition's orientation and
        /// RMS moment magnitude.
        var dipoles: [Result]
        var goodnessOfFit: Double
        var residualMicrovolts: Double
    }

    /// A shared-geometry fit across several conditions.
    struct SharedGeometryResult: Sendable {
        /// Dipole positions, shared by every condition.
        var positions: [Vector3D]
        var conditions: [ConditionFit]
        /// Variance spectrum of the *combined* covariance — the overall model order.
        var varianceSpectrum: [Double]
    }

    /// Fits `count` dipoles whose *positions are shared across all conditions*,
    /// then solves each condition's own orientation/moment at those positions.
    ///
    /// This is how "is the source model different between conditions?" is asked
    /// cleanly: fix the generators (positions come from the combined covariance of
    /// every condition, so they're not pulled around by one condition's noise) and
    /// let only the per-condition moments vary. Two conditions that share a
    /// generator then differ only in that dipole's amplitude/orientation — directly
    /// comparable — rather than in positions that wander from fit jitter.
    ///
    /// - Parameter conditions: `(name, channels × samples)` per condition, all on
    ///   the same channels/interval.
    static func fitSharedGeometry(
        conditions: [(name: String, data: [[Double]])],
        count: Int,
        head: SphericalHeadModel,
        montage: Montage,
        reference: EEGReference,
        harmonicTerms: Int
    ) -> SharedGeometryResult? {
        let channelCount = montage.electrodes.count
        guard count >= 1, !conditions.isEmpty, channelCount >= 3 else { return nil }

        var combined = [[Double]](repeating: [Double](repeating: 0, count: channelCount), count: channelCount)
        var combinedTotal = 0.0
        var perCondition: [(name: String, covariance: [[Double]], total: Double, sampleCount: Int)] = []
        for condition in conditions {
            let sampleCount = condition.data.first?.count ?? 0
            guard sampleCount >= 1, condition.data.count == channelCount,
                  let (covariance, total) = covarianceOf(
                    data: condition.data, channelCount: channelCount, sampleCount: sampleCount)
            else { return nil }
            for i in 0..<channelCount { for j in 0..<channelCount { combined[i][j] += covariance[i][j] } }
            combinedTotal += total
            perCondition.append((condition.name, covariance, total, sampleCount))
        }
        guard combinedTotal > 1e-18 else { return nil }

        let spectrum = varianceSpectrum(of: combined, total: combinedTotal)
        // Shared positions from the combined covariance of all conditions.
        guard let positions = fitPositionsFromCovariance(
            covariance: combined, total: combinedTotal, count: count, channelCount: channelCount,
            head: head, montage: montage, reference: reference, harmonicTerms: harmonicTerms
        ) else { return nil }

        var conditionFits: [ConditionFit] = []
        for condition in perCondition {
            guard let finalized = finalize(
                positions: positions, covariance: condition.covariance, total: condition.total,
                sampleCount: condition.sampleCount, channelCount: channelCount,
                head: head, montage: montage, reference: reference, harmonicTerms: harmonicTerms
            ) else { continue }
            conditionFits.append(ConditionFit(
                name: condition.name, dipoles: finalized.dipoles,
                goodnessOfFit: finalized.gof, residualMicrovolts: finalized.residualRMS))
        }
        guard !conditionFits.isEmpty else { return nil }
        return SharedGeometryResult(positions: positions, conditions: conditionFits, varianceSpectrum: spectrum)
    }

    // MARK: - Covariance-fit building blocks

    /// `C = data · dataᵀ` (channels × channels) and its total variance (trace).
    private static func covarianceOf(
        data: [[Double]], channelCount: Int, sampleCount: Int
    ) -> (covariance: [[Double]], total: Double)? {
        var covariance = [[Double]](repeating: [Double](repeating: 0, count: channelCount), count: channelCount)
        for i in 0..<channelCount {
            let xi = data[i]
            guard xi.count == sampleCount else { return nil }
            for j in i..<channelCount {
                let xj = data[j]
                var sum = 0.0
                for t in 0..<sampleCount { sum += xi[t] * xj[t] }
                covariance[i][j] = sum
                covariance[j][i] = sum
            }
        }
        var total = 0.0
        for i in 0..<channelCount { total += covariance[i][i] }
        guard total > 1e-18 else { return nil }
        return (covariance, total)
    }

    /// Eigenvalues of `C` as descending variance fractions — the model-order picture.
    private static func varianceSpectrum(of covariance: [[Double]], total: Double) -> [Double] {
        let eigen = LinearAlgebra.symmetricEigenDecomposition(covariance)
        return eigen.values.map { max(0.0, $0) / total }.sorted(by: >)
    }

    /// Deflation seed + joint coordinate descent for `count` positions on `C`.
    private static func fitPositionsFromCovariance(
        covariance: [[Double]], total: Double, count: Int, channelCount: Int,
        head: SphericalHeadModel, montage: Montage, reference: EEGReference, harmonicTerms: Int
    ) -> [Vector3D]? {
        let brainRadius = head.brainRadiusMeters
        guard brainRadius > 0 else { return nil }
        let maxRadius = brainRadius * 0.97
        let center = head.centerMeters

        var residualCovariance = covariance
        var residualTotal = total
        var positions: [Vector3D] = []
        for _ in 0..<count {
            guard let position = covarianceSearch(
                covariance: residualCovariance, total: residualTotal, channelCount: channelCount,
                brainRadius: brainRadius, maxRadius: maxRadius, center: center,
                head: head, montage: montage, reference: reference, harmonicTerms: harmonicTerms
            ) else { break }
            positions.append(position)
            deflateCovariance(
                &residualCovariance, at: position, channelCount: channelCount,
                head: head, montage: montage, reference: reference, harmonicTerms: harmonicTerms)
            residualTotal = 0.0
            for i in 0..<channelCount { residualTotal += residualCovariance[i][i] }
        }
        guard !positions.isEmpty else { return nil }
        let k = positions.count

        if k >= 2 {
            for _ in 0..<4 {
                var maxShift = 0.0
                for i in 0..<k {
                    let others = positions.enumerated().filter { $0.offset != i }.map(\.element)
                    guard let otherFree = others.isEmpty ? [[Double]]() : freeLeadField(
                        candidates: others, head: head, montage: montage,
                        reference: reference, harmonicTerms: harmonicTerms) else { continue }
                    var searchCenter = positions[i]
                    var step = brainRadius / 4.0
                    var bestPosition = positions[i]
                    for _ in 0..<5 {
                        let candidates = localGrid(
                            around: searchCenter, step: step, halfWidthInSteps: 2,
                            center: center, maxRadius: maxRadius)
                        guard !candidates.isEmpty,
                              let candidateFree = freeLeadField(
                                candidates: candidates, head: head, montage: montage,
                                reference: reference, harmonicTerms: harmonicTerms) else { break }
                        var bestResidual = Double.greatestFiniteMagnitude
                        for (m, candidate) in candidates.enumerated() {
                            let design = assembleDesign(
                                otherFree: otherFree, candidateFree: candidateFree,
                                candidateIndex: m, channelCount: channelCount)
                            let residual = covarianceResidual(
                                design: design, covariance: covariance, total: total,
                                channelCount: channelCount, columns: design.first?.count ?? 0)
                            if residual < bestResidual { bestResidual = residual; bestPosition = candidate }
                        }
                        searchCenter = bestPosition
                        step *= 0.45
                    }
                    maxShift = max(maxShift, (bestPosition - positions[i]).norm)
                    positions[i] = bestPosition
                }
                if maxShift < 5e-4 { break }
            }
        }
        return positions
    }

    /// Per-dipole orientation + RMS magnitude at fixed `positions` against `C`,
    /// plus the joint goodness-of-fit and residual RMS.
    private static func finalize(
        positions: [Vector3D], covariance: [[Double]], total: Double, sampleCount: Int,
        channelCount: Int, head: SphericalHeadModel, montage: Montage,
        reference: EEGReference, harmonicTerms: Int
    ) -> (dipoles: [Result], gof: Double, residualRMS: Double)? {
        guard let free = freeLeadField(
            candidates: positions, head: head, montage: montage,
            reference: reference, harmonicTerms: harmonicTerms) else { return nil }
        let unknowns = 3 * positions.count
        let residual = covarianceResidual(
            design: free, covariance: covariance, total: total,
            channelCount: channelCount, columns: unknowns)
        let gof = max(0.0, 1.0 - residual / total)
        let residualRMS = (residual / Double(channelCount * max(sampleCount, 1))).squareRoot()

        guard let momentCovariance = momentCovariance(
            design: free, covariance: covariance, channelCount: channelCount, columns: unknowns)
        else { return nil }

        var dipoles: [Result] = []
        for index in positions.indices {
            let base = 3 * index
            let block = [
                [momentCovariance[base][base], momentCovariance[base][base + 1], momentCovariance[base][base + 2]],
                [momentCovariance[base + 1][base], momentCovariance[base + 1][base + 1], momentCovariance[base + 1][base + 2]],
                [momentCovariance[base + 2][base], momentCovariance[base + 2][base + 1], momentCovariance[base + 2][base + 2]],
            ]
            let blockEigen = LinearAlgebra.symmetricEigenDecomposition(block)
            let last = blockEigen.values.count - 1
            let orientation = last >= 0
                ? Vector3D(x: blockEigen.vectors[0][last], y: blockEigen.vectors[1][last], z: blockEigen.vectors[2][last]).normalized()
                : Vector3D(x: 0, y: 0, z: 1)
            let traceBlock = block[0][0] + block[1][1] + block[2][2]
            let magnitude = (max(0.0, traceBlock) / Double(max(sampleCount, 1))).squareRoot()
            dipoles.append(Result(
                positionMeters: positions[index],
                momentNanoampereMeters: orientation * magnitude,
                orientationUnit: orientation,
                magnitudeNanoampereMeters: magnitude,
                goodnessOfFit: gof,
                residualMicrovolts: residualRMS
            ))
        }
        return (dipoles, gof, residualRMS)
    }

    /// Single-dipole position search scored on a covariance matrix (the interval
    /// objective). Mirrors `search` but maximizes explained covariance variance.
    private static func covarianceSearch(
        covariance C: [[Double]], total: Double, channelCount: Int,
        brainRadius: Double, maxRadius: Double, center: Vector3D,
        head: SphericalHeadModel, montage: Montage, reference: EEGReference, harmonicTerms: Int
    ) -> Vector3D? {
        var best: (position: Vector3D, residual: Double)?
        var searchCenter = center
        var step = brainRadius / 5.0
        for level in 0..<6 {
            let candidates = level == 0
                ? gridInsideSphere(center: center, maxRadius: maxRadius, step: step)
                : localGrid(around: searchCenter, step: step, halfWidthInSteps: 2,
                            center: center, maxRadius: maxRadius)
            guard !candidates.isEmpty else { break }
            guard let free = freeLeadField(
                candidates: candidates, head: head, montage: montage,
                reference: reference, harmonicTerms: harmonicTerms) else {
                if level == 0 { return nil } else { break }
            }
            for (m, position) in candidates.enumerated() {
                let base = 3 * m
                let design = (0..<channelCount).map { [free[$0][base], free[$0][base + 1], free[$0][base + 2]] }
                let residual = covarianceResidual(
                    design: design, covariance: C, total: total, channelCount: channelCount, columns: 3)
                if best == nil || residual < best!.residual { best = (position, residual) }
            }
            guard let winner = best else { break }
            searchCenter = winner.position
            step *= 0.45
        }
        return best?.position
    }

    /// Subtracts a fitted dipole's covariance contribution from `C` in place, so
    /// the next deflation step sees what it leaves behind.
    private static func deflateCovariance(
        _ C: inout [[Double]], at position: Vector3D, channelCount: Int,
        head: SphericalHeadModel, montage: Montage, reference: EEGReference, harmonicTerms: Int
    ) {
        guard let free = freeLeadField(
            candidates: [position], head: head, montage: montage,
            reference: reference, harmonicTerms: harmonicTerms) else { return }
        let design = (0..<channelCount).map { [free[$0][0], free[$0][1], free[$0][2]] }
        guard let momentCovariance = momentCovariance(
            design: design, covariance: C, channelCount: channelCount, columns: 3) else { return }
        // Contribution covariance = L · (M Mᵀ) · Lᵀ (channels × channels).
        for a in 0..<channelCount {
            for b in 0..<channelCount {
                var sum = 0.0
                for i in 0..<3 {
                    for j in 0..<3 {
                        sum += design[a][i] * momentCovariance[i][j] * design[b][j]
                    }
                }
                C[a][b] -= sum
            }
        }
    }

    /// Assembles the channels × 3K design matrix `[otherFree | candidate]`.
    private static func assembleDesign(
        otherFree: [[Double]], candidateFree: [[Double]], candidateIndex: Int, channelCount: Int
    ) -> [[Double]] {
        let otherColumns = otherFree.first?.count ?? 0
        let base = 3 * candidateIndex
        var design = [[Double]](repeating: [Double](repeating: 0, count: otherColumns + 3), count: channelCount)
        for c in 0..<channelCount {
            for i in 0..<otherColumns { design[c][i] = otherFree[c][i] }
            design[c][otherColumns] = candidateFree[c][base]
            design[c][otherColumns + 1] = candidateFree[c][base + 1]
            design[c][otherColumns + 2] = candidateFree[c][base + 2]
        }
        return design
    }

    /// `trace(C) − trace((LᵀL)⁻¹ LᵀC L)`: the spatiotemporal residual for a design
    /// `L` (channels × columns) against covariance `C`, with free per-sample moments.
    private static func covarianceResidual(
        design L: [[Double]], covariance C: [[Double]], total: Double,
        channelCount: Int, columns p: Int
    ) -> Double {
        guard p > 0, let (gram, lcl) = gramAndLCL(design: L, covariance: C, channelCount: channelCount, columns: p)
        else { return total }
        var explained = 0.0
        for column in 0..<p {
            let rhs = (0..<p).map { lcl[$0][column] }
            guard let z = solveLinearSystem(gram, rhs) else { return total }
            explained += z[column]   // diagonal of (LᵀL)⁻¹ LᵀC L
        }
        return max(0.0, total - explained)
    }

    /// The interval moment covariance `M Mᵀ = G⁻¹ (LᵀC L) G⁻¹` (columns × columns),
    /// whose per-dipole 3×3 blocks give orientation (top eigenvector) and RMS
    /// magnitude (sqrt(trace / samples)).
    private static func momentCovariance(
        design L: [[Double]], covariance C: [[Double]], channelCount: Int, columns p: Int
    ) -> [[Double]]? {
        guard let (gram, lcl) = gramAndLCL(design: L, covariance: C, channelCount: channelCount, columns: p)
        else { return nil }
        // Ginv (p×p) by solving G against identity columns.
        var gramInverse = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        for column in 0..<p {
            var e = [Double](repeating: 0, count: p); e[column] = 1
            guard let col = solveLinearSystem(gram, e) else { return nil }
            for row in 0..<p { gramInverse[row][column] = col[row] }
        }
        // Z = Ginv · LCL, then MomentCov = Z · Ginv.
        func multiply(_ A: [[Double]], _ B: [[Double]]) -> [[Double]] {
            var out = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
            for i in 0..<p { for j in 0..<p {
                var s = 0.0
                for t in 0..<p { s += A[i][t] * B[t][j] }
                out[i][j] = s
            } }
            return out
        }
        return multiply(multiply(gramInverse, lcl), gramInverse)
    }

    /// `G = LᵀL` (ridge-stabilized) and `LᵀC L`, both columns × columns.
    private static func gramAndLCL(
        design L: [[Double]], covariance C: [[Double]], channelCount: Int, columns p: Int
    ) -> (gram: [[Double]], lcl: [[Double]])? {
        guard L.count == channelCount, (L.first?.count ?? 0) >= p else { return nil }
        var gram = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        for i in 0..<p { for j in i..<p {
            var s = 0.0
            for ch in 0..<channelCount { s += L[ch][i] * L[ch][j] }
            gram[i][j] = s; gram[j][i] = s
        } }
        // CL = C · L (channels × p).
        var cl = [[Double]](repeating: [Double](repeating: 0, count: p), count: channelCount)
        for ch in 0..<channelCount {
            let crow = C[ch]
            for j in 0..<p {
                var s = 0.0
                for c2 in 0..<channelCount { s += crow[c2] * L[c2][j] }
                cl[ch][j] = s
            }
        }
        // LCL = Lᵀ · CL (p × p).
        var lcl = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        for i in 0..<p { for j in 0..<p {
            var s = 0.0
            for ch in 0..<channelCount { s += L[ch][i] * cl[ch][j] }
            lcl[i][j] = s
        } }
        var trace = 0.0
        for i in 0..<p { trace += gram[i][i] }
        let ridge = 1e-9 * trace / Double(p)
        for i in 0..<p { gram[i][i] += ridge }
        return (gram, lcl)
    }

    // MARK: - Truth comparison

    /// Position and orientation error of a fit against a known true generator.
    static func localization(
        fit: Result,
        trueName: String,
        truePositionMeters: Vector3D,
        trueOrientationUnit: Vector3D,
        usedNoisyField: Bool
    ) -> Localization {
        let positionError = (fit.positionMeters - truePositionMeters).norm * 1000.0
        let trueUnit = trueOrientationUnit.normalized()
        let alignment = min(1.0, abs(fit.orientationUnit.dot(trueUnit)))
        let orientationError = acos(alignment) * 180.0 / .pi
        return Localization(
            fit: fit,
            usedNoisyField: usedNoisyField,
            trueSourceName: trueName,
            truePositionMeters: truePositionMeters,
            positionErrorMillimeters: positionError,
            orientationErrorDegrees: orientationError
        )
    }

    // MARK: - Forward batching

    private static func freeLeadField(
        candidates: [Vector3D],
        head: SphericalHeadModel,
        montage: Montage,
        reference: EEGReference,
        harmonicTerms: Int
    ) -> [[Double]]? {
        let sims = candidates.enumerated().map { index, position in
            SimulatedSource(
                id: "fit\(index)",
                positionMeters: position,
                orientation: Vector3D(x: 0, y: 0, z: 1),   // unused: we read free columns
                bandName: "alpha",
                seed: 0,
                rmsMomentNanoampereMeters: 1
            )
        }
        guard let leadField = try? SphericalForwardModel.leadField(
            head: head, montage: montage, sources: sims,
            reference: reference, terms: harmonicTerms
        ) else { return nil }
        return leadField.freeOrientationMatrixMicrovoltsPerNanoampereMeter
    }

    /// Closed-form least-squares moment for one candidate's three free columns.
    private static func solveMoment(
        free: [[Double]], dipoleIndex k: Int, channelCount: Int, b: [Double]
    ) -> (moment: Vector3D, residualSumOfSquares: Double)? {
        let cx = 3 * k, cy = 3 * k + 1, cz = 3 * k + 2
        guard free.count == channelCount, cz < (free.first?.count ?? 0) else { return nil }

        // Normal equations: (LᵀL) m = Lᵀb, with L the channels×3 free operator.
        var a00 = 0.0, a01 = 0.0, a02 = 0.0, a11 = 0.0, a12 = 0.0, a22 = 0.0
        var g0 = 0.0, g1 = 0.0, g2 = 0.0
        for c in 0..<channelCount {
            let lx = free[c][cx], ly = free[c][cy], lz = free[c][cz]
            a00 += lx * lx; a01 += lx * ly; a02 += lx * lz
            a11 += ly * ly; a12 += ly * lz; a22 += lz * lz
            let value = b[c]
            g0 += lx * value; g1 += ly * value; g2 += lz * value
        }
        // A whisper of Tikhonov on the diagonal keeps a near-degenerate deep or
        // central position (where two orientation columns nearly coincide on the
        // scalp) from producing a wild moment; it is far below the forward-model
        // error and does not move well-posed fits.
        let ridge = 1e-9 * (a00 + a11 + a22)
        guard let m = solveSymmetric3x3(
            a00 + ridge, a01, a02, a11 + ridge, a12, a22 + ridge, g0, g1, g2
        ) else { return nil }

        var rss = 0.0
        for c in 0..<channelCount {
            let predicted = free[c][cx] * m.x + free[c][cy] * m.y + free[c][cz] * m.z
            let residual = predicted - b[c]
            rss += residual * residual
        }
        return (m, rss)
    }

    // MARK: - Geometry helpers

    private static func gridInsideSphere(
        center: Vector3D, maxRadius: Double, step: Double
    ) -> [Vector3D] {
        guard step > 0 else { return [] }
        var points: [Vector3D] = []
        let n = Int((maxRadius / step).rounded(.down))
        guard n >= 1 else { return [center] }
        let maxRadiusSquared = maxRadius * maxRadius
        for i in -n...n {
            for j in -n...n {
                for k in -n...n {
                    let dx = Double(i) * step, dy = Double(j) * step, dz = Double(k) * step
                    if dx * dx + dy * dy + dz * dz <= maxRadiusSquared {
                        points.append(Vector3D(x: center.x + dx, y: center.y + dy, z: center.z + dz))
                    }
                }
            }
        }
        return points
    }

    private static func localGrid(
        around anchor: Vector3D, step: Double, halfWidthInSteps: Int,
        center: Vector3D, maxRadius: Double
    ) -> [Vector3D] {
        guard step > 0, halfWidthInSteps >= 1 else { return [] }
        var points: [Vector3D] = []
        let maxRadiusSquared = maxRadius * maxRadius
        for i in -halfWidthInSteps...halfWidthInSteps {
            for j in -halfWidthInSteps...halfWidthInSteps {
                for k in -halfWidthInSteps...halfWidthInSteps {
                    let position = Vector3D(
                        x: anchor.x + Double(i) * step,
                        y: anchor.y + Double(j) * step,
                        z: anchor.z + Double(k) * step
                    )
                    let dx = position.x - center.x, dy = position.y - center.y, dz = position.z - center.z
                    if dx * dx + dy * dy + dz * dz <= maxRadiusSquared {
                        points.append(position)
                    }
                }
            }
        }
        return points
    }

    /// Solves a symmetric positive-(semi)definite 3×3 system by cofactor
    /// expansion. Returns `nil` for a singular matrix.
    private static func solveSymmetric3x3(
        _ a00: Double, _ a01: Double, _ a02: Double,
        _ a11: Double, _ a12: Double, _ a22: Double,
        _ g0: Double, _ g1: Double, _ g2: Double
    ) -> Vector3D? {
        let c00 = a11 * a22 - a12 * a12
        let c01 = a12 * a02 - a01 * a22
        let c02 = a01 * a12 - a11 * a02
        let determinant = a00 * c00 + a01 * c01 + a02 * c02
        guard abs(determinant) > 1e-30 else { return nil }
        let inverseDet = 1.0 / determinant
        let c11 = a00 * a22 - a02 * a02
        let c12 = a02 * a01 - a00 * a12
        let c22 = a00 * a11 - a01 * a01
        let x = (c00 * g0 + c01 * g1 + c02 * g2) * inverseDet
        let y = (c01 * g0 + c11 * g1 + c12 * g2) * inverseDet
        let z = (c02 * g0 + c12 * g1 + c22 * g2) * inverseDet
        guard x.isFinite, y.isFinite, z.isFinite else { return nil }
        return Vector3D(x: x, y: y, z: z)
    }

    /// Solves `A x = g` for a general (small) system by Gaussian elimination with
    /// partial pivoting. Used for the joint moment re-solve, where `A` is the
    /// 3·count × 3·count symmetric normal matrix. Returns `nil` if singular.
    private static func solveLinearSystem(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        guard matrix.count == n, n > 0 else { return nil }
        var a = matrix
        var b = rhs
        for column in 0..<n {
            // Partial pivot.
            var pivotRow = column
            var pivotValue = abs(a[column][column])
            for row in (column + 1)..<n where abs(a[row][column]) > pivotValue {
                pivotValue = abs(a[row][column]); pivotRow = row
            }
            guard pivotValue > 1e-30 else { return nil }
            if pivotRow != column { a.swapAt(pivotRow, column); b.swapAt(pivotRow, column) }
            let pivot = a[column][column]
            for row in (column + 1)..<n {
                let factor = a[row][column] / pivot
                guard factor != 0 else { continue }
                for k in column..<n { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
            x[row] = sum / a[row][row]
        }
        guard x.allSatisfy({ $0.isFinite }) else { return nil }
        return x
    }
}
