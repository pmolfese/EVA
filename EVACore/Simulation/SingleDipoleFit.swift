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
    /// Progress and cancellation for the long shared-geometry fit. `report` is
    /// called from the fitting thread with a 0…1 fraction and a human-readable
    /// message describing the phase; `isCancelled` lets the caller abort a slow
    /// search between chunks. The fit is dominated by forward solves over
    /// candidate grids, so reporting happens inside those loops, not just at
    /// phase boundaries.
    /// Wall-clock time per named phase of a fit, so the solve can be profiled
    /// instead of guessed at. Thread-safe: phases are marked from the solver's
    /// own thread while chunks run on workers.
    final class PhaseTimings: @unchecked Sendable {
        private let lock = NSLock()
        private var totals: [String: Double] = [:]
        private var order: [String] = []
        private var current: (name: String, start: Date)?

        public init() {}

        /// Closes the running phase and opens `name`.
        func begin(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            closeCurrentLocked()
            if totals[name] == nil { totals[name] = 0; order.append(name) }
            current = (name, Date())
        }

        /// Closes the running phase, if any.
        func finish() {
            lock.lock(); defer { lock.unlock() }
            closeCurrentLocked()
        }

        private func closeCurrentLocked() {
            guard let current else { return }
            totals[current.name, default: 0] += Date().timeIntervalSince(current.start)
            self.current = nil
        }

        var breakdown: [(name: String, seconds: Double)] {
            lock.lock(); defer { lock.unlock() }
            return order.map { ($0, totals[$0] ?? 0) }
        }

        /// `"coarse search 4.10s (65%) · refinement 2.05s (32%)"`, strongest first.
        var summary: String {
            let entries = breakdown.sorted { $0.seconds > $1.seconds }
            let total = entries.reduce(0) { $0 + $1.seconds }
            guard total > 0 else { return "" }
            return entries
                .filter { $0.seconds / total > 0.005 }
                .map { String(format: "%@ %.2fs (%.0f%%)", $0.name, $0.seconds, $0.seconds / total * 100) }
                .joined(separator: " · ")
        }
    }

    struct ProgressReporter: Sendable {
        var report: @Sendable (Double, String) -> Void
        var isCancelled: @Sendable () -> Bool
        /// Optional profiler; phases are marked with `phase(_:)`.
        var timings: PhaseTimings?

        init(report: @escaping @Sendable (Double, String) -> Void,
             isCancelled: @escaping @Sendable () -> Bool = { false },
             timings: PhaseTimings? = nil) {
            self.report = report
            self.isCancelled = isCancelled
            self.timings = timings
        }

        /// Marks the start of a named phase for the profiler.
        func phase(_ name: String) { timings?.begin(name) }

        /// A child reporter whose own 0…1 maps into `[lower, upper]` of this one.
        func scoped(_ lower: Double, _ upper: Double) -> ProgressReporter {
            let report = self.report, isCancelled = self.isCancelled
            return ProgressReporter(
                report: { fraction, message in
                    report(lower + (upper - lower) * min(max(fraction, 0), 1), message)
                },
                isCancelled: isCancelled,
                timings: timings)
        }
    }

    static func fitSharedGeometry(
        conditions: [(name: String, data: [[Double]])],
        count: Int,
        head: SphericalHeadModel,
        montage: Montage,
        reference: EEGReference,
        harmonicTerms: Int,
        seeds: [Vector3D]? = nil,
        reporter: ProgressReporter? = nil
    ) -> SharedGeometryResult? {
        let channelCount = montage.electrodes.count
        guard count >= 1, !conditions.isEmpty, channelCount >= 3 else { return nil }
        reporter?.phase("covariance")
        reporter?.report(0.0, "Preparing \(conditions.count) condition\(conditions.count == 1 ? "" : "s") on \(channelCount) channels…")

        var combined = [[Double]](repeating: [Double](repeating: 0, count: channelCount), count: channelCount)
        var combinedTotal = 0.0
        var perCondition: [(name: String, covariance: [[Double]], total: Double, sampleCount: Int)] = []
        for (index, condition) in conditions.enumerated() {
            if reporter?.isCancelled() == true { return nil }
            let sampleCount = condition.data.first?.count ?? 0
            reporter?.report(0.02 + 0.10 * Double(index) / Double(conditions.count),
                             "Building covariance — \(condition.name) (\(index + 1) of \(conditions.count)), \(sampleCount) samples")
            guard sampleCount >= 1, condition.data.count == channelCount,
                  let (covariance, total) = covarianceOf(
                    data: condition.data, channelCount: channelCount, sampleCount: sampleCount)
            else { return nil }
            for i in 0..<channelCount { for j in 0..<channelCount { combined[i][j] += covariance[i][j] } }
            combinedTotal += total
            perCondition.append((condition.name, covariance, total, sampleCount))
        }
        guard combinedTotal > 1e-18 else { return nil }

        if reporter?.isCancelled() == true { return nil }
        reporter?.phase("svd spectrum")
        reporter?.report(0.12, "Computing SVD spectrum (model order) on a \(channelCount)×\(channelCount) covariance…")
        let spectrum = varianceSpectrum(of: combined, total: combinedTotal)

        // Shared positions from the combined covariance of all conditions. A
        // supplied seed (dragged dipoles) starts the refinement in place of the
        // deflation search.
        guard let positions = fitPositionsFromCovariance(
            covariance: combined, total: combinedTotal, count: count, channelCount: channelCount,
            head: head, montage: montage, reference: reference, harmonicTerms: harmonicTerms,
            seeds: seeds, reporter: reporter?.scoped(0.15, 0.85)
        ) else { return nil }

        reporter?.phase("finalize")
        var conditionFits: [ConditionFit] = []
        for (index, condition) in perCondition.enumerated() {
            if reporter?.isCancelled() == true { return nil }
            reporter?.report(0.85 + 0.14 * Double(index) / Double(perCondition.count),
                             "Fitting per-condition moments — \(condition.name) (\(index + 1) of \(perCondition.count))")
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
        let bestGOF = conditionFits.map(\.goodnessOfFit).max() ?? 0
        reporter?.report(1.0, String(format: "Done — %d dipole%@, best GOF %.1f%%",
                                     positions.count, positions.count == 1 ? "" : "s", bestGOF * 100))
        reporter?.timings?.finish()
        return SharedGeometryResult(positions: positions, conditions: conditionFits, varianceSpectrum: spectrum)
    }

    // MARK: - Source waveforms and residual PCA

    /// One principal component of what the dipole model has *not* explained.
    struct ResidualComponent: Sendable {
        /// Share of the ORIGINAL data variance still carried by this component,
        /// so the numbers shrink as dipoles are added to the model.
        var varianceFraction: Double
        /// Scalp pattern (one weight per channel).
        var topography: [Double]
        /// This component's time course over the interval.
        var timeCourse: [Double]
    }

    /// The per-dipole time courses of a fitted model plus a PCA of the residual.
    ///
    /// This is the BESA-style reading of a fit: the model's *source waveforms*
    /// say what each dipole is doing over time, and the residual components say
    /// what is left over — place dipoles that explain the highlighted interval
    /// and the remaining components show the parts of the data still unmodelled.
    struct SourceDecomposition: Sendable {
        /// Per-dipole moment time course in nA·m, signed along the fitted
        /// orientation (dipoles × samples).
        var sourceWaveforms: [[Double]]
        /// Leftover structure, strongest first.
        var residualComponents: [ResidualComponent]
        /// Fraction of the original variance the dipole model accounts for.
        var explainedFraction: Double
        /// `1 − explainedFraction`, i.e. what the components above describe.
        var residualFraction: Double
    }

    /// Projects `data` through the lead field of `positions` to get each dipole's
    /// moment over time, subtracts the modelled field, and decomposes what is
    /// left. `orientations` fixes each waveform's sign convention; pass the
    /// orientations the fit reported.
    static func decompose(
        data: [[Double]],
        positions: [Vector3D],
        orientations: [Vector3D],
        head: SphericalHeadModel,
        montage: Montage,
        reference: EEGReference,
        harmonicTerms: Int,
        maxResidualComponents: Int = 4
    ) -> SourceDecomposition? {
        let channelCount = montage.electrodes.count
        let sampleCount = data.first?.count ?? 0
        guard !positions.isEmpty, sampleCount >= 1, data.count == channelCount, channelCount >= 3,
              let lead = freeLeadField(
                candidates: positions, head: head, montage: montage,
                reference: reference, harmonicTerms: harmonicTerms)
        else { return nil }

        let columns = 3 * positions.count
        // Gram = LᵀL (columns × columns).
        var gram = [[Double]](repeating: [Double](repeating: 0, count: columns), count: columns)
        for i in 0..<columns {
            for j in i..<columns {
                var sum = 0.0
                for c in 0..<channelCount { sum += lead[c][i] * lead[c][j] }
                gram[i][j] = sum
                gram[j][i] = sum
            }
        }
        // Pseudo-inverse rows: solve (LᵀL) z = Lᵀ eₖ once per channel, giving
        // `pinv` (columns × channels) so moments are a single matrix product.
        var pinv = [[Double]](repeating: [Double](repeating: 0, count: channelCount), count: columns)
        for c in 0..<channelCount {
            let rhs = (0..<columns).map { lead[c][$0] }
            guard let z = solveLinearSystem(gram, rhs) else { return nil }
            for i in 0..<columns { pinv[i][c] = z[i] }
        }

        // Moments over time: M = pinv · X (columns × samples).
        var moments = [[Double]](repeating: [Double](repeating: 0, count: sampleCount), count: columns)
        for i in 0..<columns {
            let row = pinv[i]
            for t in 0..<sampleCount {
                var sum = 0.0
                for c in 0..<channelCount { sum += row[c] * data[c][t] }
                moments[i][t] = sum
            }
        }

        // Source waveforms: the moment projected on each dipole's orientation.
        var waveforms: [[Double]] = []
        waveforms.reserveCapacity(positions.count)
        for (index, _) in positions.enumerated() {
            let base = 3 * index
            let orientation = index < orientations.count
                ? orientations[index].normalized() : Vector3D(x: 0, y: 0, z: 1)
            var series = [Double](repeating: 0, count: sampleCount)
            for t in 0..<sampleCount {
                series[t] = moments[base][t] * orientation.x
                    + moments[base + 1][t] * orientation.y
                    + moments[base + 2][t] * orientation.z
            }
            waveforms.append(series)
        }

        // Residual = data − modelled field (L · M).
        var residual = [[Double]](repeating: [Double](repeating: 0, count: sampleCount), count: channelCount)
        var originalTotal = 0.0
        var residualTotal = 0.0
        for c in 0..<channelCount {
            let leadRow = lead[c]
            for t in 0..<sampleCount {
                var modelled = 0.0
                for i in 0..<columns { modelled += leadRow[i] * moments[i][t] }
                let value = data[c][t]
                let left = value - modelled
                residual[c][t] = left
                originalTotal += value * value
                residualTotal += left * left
            }
        }
        guard originalTotal > 1e-18 else { return nil }

        // PCA of the residual: eigenvectors are topographies, and projecting the
        // residual on them gives each component's time course.
        var components: [ResidualComponent] = []
        if let (covariance, _) = covarianceOf(
            data: residual, channelCount: channelCount, sampleCount: sampleCount) {
            let eigen = LinearAlgebra.symmetricEigenDecomposition(covariance)
            // `values` come back ascending, so walk from the end.
            let order = eigen.values.indices.sorted { eigen.values[$0] > eigen.values[$1] }
            for index in order.prefix(max(0, maxResidualComponents)) {
                let value = max(0.0, eigen.values[index])
                guard value / originalTotal > 1e-6 else { continue }
                var topography = (0..<channelCount).map { eigen.vectors[$0][index] }
                var timeCourse = [Double](repeating: 0, count: sampleCount)
                for t in 0..<sampleCount {
                    var sum = 0.0
                    for c in 0..<channelCount { sum += topography[c] * residual[c][t] }
                    timeCourse[t] = sum
                }
                // Eigenvector sign is arbitrary; fix it so the largest excursion
                // is positive, which keeps the plotted waveform stable.
                if let peak = timeCourse.max(by: { abs($0) < abs($1) }), peak < 0 {
                    for t in timeCourse.indices { timeCourse[t] = -timeCourse[t] }
                    for c in topography.indices { topography[c] = -topography[c] }
                }
                components.append(ResidualComponent(
                    varianceFraction: value / originalTotal,
                    topography: topography, timeCourse: timeCourse))
            }
        }

        let residualFraction = min(max(residualTotal / originalTotal, 0), 1)
        return SourceDecomposition(
            sourceWaveforms: waveforms,
            residualComponents: components,
            explainedFraction: 1 - residualFraction,
            residualFraction: residualFraction)
    }

    // MARK: - Fast search objective (Stage 3c-perf)
    //
    // The position search evaluates thousands of candidates, and the naive
    // objective costs O(C²·p) per candidate because it forms C·L. Three changes
    // make it much cheaper without altering the reported result:
    //
    //  1. Flat, preallocated buffers instead of `[[Double]]`, which was
    //     allocating one small array per channel per candidate.
    //  2. A rank-reduced covariance C ≈ W·Wᵀ, so LᵀCL = (WᵀL)ᵀ(WᵀL) at O(r·C·p).
    //     A model with `p` free spatial dimensions cannot explain more than `p`
    //     components, so keeping `p` plus a margin loses nothing the search could
    //     have used — this is the usual signal-subspace argument.
    //  3. Parallel evaluation of candidate chunks.
    //
    // The *reported* goodness-of-fit and residual still come from `finalize`,
    // which uses the exact full covariance. Only candidate ranking is accelerated.

    /// A rank-reduced factor of a covariance: `C ≈ W·Wᵀ`.
    struct CovarianceFactor: Sendable {
        let channelCount: Int
        let rank: Int
        /// Row-major `channelCount × rank`.
        let w: [Double]
        /// Trace of the ORIGINAL (un-truncated) covariance.
        let total: Double
    }

    /// Eigendecomposes `covariance` and keeps the leading components. `modelColumns`
    /// is the number of free spatial dimensions the model has (3 per dipole).
    private static func factorize(
        covariance: [[Double]], total: Double, channelCount: Int, modelColumns: Int
    ) -> CovarianceFactor {
        let eigen = LinearAlgebra.symmetricEigenDecomposition(covariance)
        let order = eigen.values.indices.sorted { eigen.values[$0] > eigen.values[$1] }
        let cap = min(channelCount, max(modelColumns + 8, 12))
        var kept: [Int] = []
        for index in order.prefix(cap) {
            let value = eigen.values[index]
            if value <= 0 || value / max(total, 1e-300) < 1e-12 { break }
            kept.append(index)
        }
        if kept.isEmpty, let first = order.first { kept = [first] }
        let rank = kept.count
        var w = [Double](repeating: 0, count: channelCount * rank)
        for (slot, index) in kept.enumerated() {
            let scale = max(0, eigen.values[index]).squareRoot()
            for channel in 0..<channelCount {
                w[channel * rank + slot] = eigen.vectors[channel][index] * scale
            }
        }
        return CovarianceFactor(channelCount: channelCount, rank: rank, w: w, total: total)
    }

    /// Reusable buffers for the objective, so a candidate costs no allocations.
    private struct ObjectiveScratch {
        var gram: [Double]
        var a: [Double]
        var lcl: [Double]
        var augmented: [Double]
        init(columns p: Int, rank: Int) {
            gram = [Double](repeating: 0, count: p * p)
            a = [Double](repeating: 0, count: rank * p)
            lcl = [Double](repeating: 0, count: p * p)
            augmented = [Double](repeating: 0, count: p * 2 * p)
        }
    }

    /// `total − trace((LᵀL)⁻¹·LᵀCL)` for a design held flat (row-major, one row per
    /// channel). `columnOffset` selects this candidate's columns within the row.
    private static func factoredResidual(
        design: UnsafePointer<Double>, rowStride: Int, columnOffset: Int, columns p: Int,
        factor: CovarianceFactor, scratch: inout ObjectiveScratch
    ) -> Double {
        let channelCount = factor.channelCount
        let rank = factor.rank

        return scratch.gram.withUnsafeMutableBufferPointer { gramBuffer in
            scratch.a.withUnsafeMutableBufferPointer { aBuffer in
                scratch.lcl.withUnsafeMutableBufferPointer { lclBuffer in
                    scratch.augmented.withUnsafeMutableBufferPointer { augBuffer in
                        factor.w.withUnsafeBufferPointer { wBuffer in
                            let gram = gramBuffer.baseAddress!
                            let a = aBuffer.baseAddress!
                            let lcl = lclBuffer.baseAddress!
                            let w = wBuffer.baseAddress!

                            // gram = LᵀL (p × p, symmetric).
                            for i in 0..<p {
                                for j in i..<p {
                                    var sum = 0.0
                                    for ch in 0..<channelCount {
                                        let row = design + ch * rowStride + columnOffset
                                        sum += row[i] * row[j]
                                    }
                                    gram[i * p + j] = sum
                                    gram[j * p + i] = sum
                                }
                            }
                            // a = Wᵀ·L (rank × p) — this replaces forming C·L.
                            for t in 0..<rank {
                                for j in 0..<p {
                                    var sum = 0.0
                                    for ch in 0..<channelCount {
                                        sum += w[ch * rank + t] * (design + ch * rowStride + columnOffset)[j]
                                    }
                                    a[t * p + j] = sum
                                }
                            }
                            // lcl = aᵀ·a (p × p, symmetric) = LᵀCL.
                            for i in 0..<p {
                                for j in i..<p {
                                    var sum = 0.0
                                    for t in 0..<rank { sum += a[t * p + i] * a[t * p + j] }
                                    lcl[i * p + j] = sum
                                    lcl[j * p + i] = sum
                                }
                            }
                            // Same ridge the exact path uses.
                            var trace = 0.0
                            for i in 0..<p { trace += gram[i * p + i] }
                            let ridge = 1e-9 * trace / Double(p)
                            for i in 0..<p { gram[i * p + i] += ridge }

                            guard invert(gram, into: augBuffer.baseAddress!, size: p) else {
                                return factor.total
                            }
                            // explained = trace(gram⁻¹ · LᵀCL); both are symmetric.
                            var explained = 0.0
                            for i in 0..<p {
                                for j in 0..<p {
                                    explained += augBuffer.baseAddress![i * p + j] * lcl[i * p + j]
                                }
                            }
                            return max(0.0, factor.total - explained)
                        }
                    }
                }
            }
        }
    }

    /// Gauss-Jordan inverse of a small symmetric positive-definite `size × size`
    /// matrix. `scratch` needs `size * 2 * size` doubles; the inverse is written
    /// back into the first `size * size` of it.
    private static func invert(
        _ matrix: UnsafePointer<Double>, into scratch: UnsafeMutablePointer<Double>, size n: Int
    ) -> Bool {
        let width = 2 * n
        for i in 0..<n {
            for j in 0..<n { scratch[i * width + j] = matrix[i * n + j] }
            for j in 0..<n { scratch[i * width + n + j] = (i == j) ? 1 : 0 }
        }
        for column in 0..<n {
            var pivotRow = column
            var best = abs(scratch[column * width + column])
            for row in (column + 1)..<n {
                let value = abs(scratch[row * width + column])
                if value > best { best = value; pivotRow = row }
            }
            guard best > 1e-300 else { return false }
            if pivotRow != column {
                for j in 0..<width {
                    let tmp = scratch[column * width + j]
                    scratch[column * width + j] = scratch[pivotRow * width + j]
                    scratch[pivotRow * width + j] = tmp
                }
            }
            let pivot = scratch[column * width + column]
            let inversePivot = 1.0 / pivot
            for j in 0..<width { scratch[column * width + j] *= inversePivot }
            for row in 0..<n where row != column {
                let factor = scratch[row * width + column]
                if factor == 0 { continue }
                for j in 0..<width {
                    scratch[row * width + j] -= factor * scratch[column * width + j]
                }
            }
        }
        // Compact the inverse into the front of the scratch buffer.
        for i in 0..<n {
            for j in 0..<n { scratch[i * n + j] = scratch[i * width + n + j] }
        }
        return true
    }

    /// Invariants of the already-placed dipoles during a joint-refinement scan:
    /// their lead-field columns, their Gram block `Lfᵀ·Lf`, and their projection
    /// `Wᵀ·Lf`. Hoisting these out of the candidate loop is exact — it just stops
    /// the same sub-products being recomputed for every candidate.
    private struct FixedBlocks {
        let count: Int
        /// Row-major channels × count.
        let columns: [Double]
        /// Row-major count × count.
        let gram: [Double]
        /// Row-major rank × count.
        let a: [Double]

        init(columns: [Double], fixedColumnCount f: Int, factor: CovarianceFactor) {
            let channelCount = factor.channelCount
            let rank = factor.rank
            self.count = f
            self.columns = columns
            var gram = [Double](repeating: 0, count: f * f)
            for i in 0..<f {
                for j in i..<f {
                    var sum = 0.0
                    for ch in 0..<channelCount {
                        sum += columns[ch * f + i] * columns[ch * f + j]
                    }
                    gram[i * f + j] = sum
                    gram[j * f + i] = sum
                }
            }
            var a = [Double](repeating: 0, count: rank * f)
            for t in 0..<rank {
                for j in 0..<f {
                    var sum = 0.0
                    for ch in 0..<channelCount {
                        sum += factor.w[ch * rank + t] * columns[ch * f + j]
                    }
                    a[t * f + j] = sum
                }
            }
            self.gram = gram
            self.a = a
        }
    }

    /// Same objective as `factoredResidual`, but only the three candidate columns
    /// are folded in — the fixed dipoles' Gram and W-projection blocks come from
    /// `blocks`. `candidate` points at this candidate's first column.
    private static func blockedResidual(
        candidate: UnsafePointer<Double>, rowStride: Int,
        blocks: FixedBlocks, factor: CovarianceFactor, scratch: inout ObjectiveScratch
    ) -> Double {
        let channelCount = factor.channelCount
        let rank = factor.rank
        let f = blocks.count
        let p = f + 3

        return scratch.gram.withUnsafeMutableBufferPointer { gramBuffer in
            scratch.a.withUnsafeMutableBufferPointer { aBuffer in
                scratch.lcl.withUnsafeMutableBufferPointer { lclBuffer in
                    scratch.augmented.withUnsafeMutableBufferPointer { augBuffer in
                        factor.w.withUnsafeBufferPointer { wBuffer in
                            blocks.columns.withUnsafeBufferPointer { fixedBuffer in
                                blocks.gram.withUnsafeBufferPointer { fixedGram in
                                    blocks.a.withUnsafeBufferPointer { fixedA in
                                        let gram = gramBuffer.baseAddress!
                                        let a = aBuffer.baseAddress!
                                        let lcl = lclBuffer.baseAddress!
                                        let w = wBuffer.baseAddress!
                                        let fixed = fixedBuffer.baseAddress!

                                        // Fixed block of the Gram (pristine copy;
                                        // the ridge below would otherwise corrupt it).
                                        for i in 0..<f {
                                            for j in 0..<f {
                                                gram[i * p + j] = fixedGram[i * f + j]
                                            }
                                        }
                                        // Cross terms Lfᵀ·Lc and the 3×3 corner.
                                        for i in 0..<f {
                                            var s0 = 0.0, s1 = 0.0, s2 = 0.0
                                            for ch in 0..<channelCount {
                                                let fv = fixed[ch * f + i]
                                                let c = candidate + ch * rowStride
                                                s0 += fv * c[0]; s1 += fv * c[1]; s2 += fv * c[2]
                                            }
                                            gram[i * p + f] = s0; gram[f * p + i] = s0
                                            gram[i * p + f + 1] = s1; gram[(f + 1) * p + i] = s1
                                            gram[i * p + f + 2] = s2; gram[(f + 2) * p + i] = s2
                                        }
                                        for i in 0..<3 {
                                            for j in i..<3 {
                                                var sum = 0.0
                                                for ch in 0..<channelCount {
                                                    let c = candidate + ch * rowStride
                                                    sum += c[i] * c[j]
                                                }
                                                gram[(f + i) * p + f + j] = sum
                                                gram[(f + j) * p + f + i] = sum
                                            }
                                        }
                                        // a = [Wᵀ·Lf | Wᵀ·Lc]
                                        for t in 0..<rank {
                                            for j in 0..<f { a[t * p + j] = fixedA[t * f + j] }
                                            var s0 = 0.0, s1 = 0.0, s2 = 0.0
                                            for ch in 0..<channelCount {
                                                let wv = w[ch * rank + t]
                                                let c = candidate + ch * rowStride
                                                s0 += wv * c[0]; s1 += wv * c[1]; s2 += wv * c[2]
                                            }
                                            a[t * p + f] = s0
                                            a[t * p + f + 1] = s1
                                            a[t * p + f + 2] = s2
                                        }
                                        // lcl = aᵀ·a
                                        for i in 0..<p {
                                            for j in i..<p {
                                                var sum = 0.0
                                                for t in 0..<rank { sum += a[t * p + i] * a[t * p + j] }
                                                lcl[i * p + j] = sum
                                                lcl[j * p + i] = sum
                                            }
                                        }
                                        var trace = 0.0
                                        for i in 0..<p { trace += gram[i * p + i] }
                                        let ridge = 1e-9 * trace / Double(p)
                                        for i in 0..<p { gram[i * p + i] += ridge }

                                        guard invert(gram, into: augBuffer.baseAddress!, size: p) else {
                                            return factor.total
                                        }
                                        var explained = 0.0
                                        for i in 0..<p {
                                            for j in 0..<p {
                                                explained += augBuffer.baseAddress![i * p + j] * lcl[i * p + j]
                                            }
                                        }
                                        return max(0.0, factor.total - explained)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Precomputed lead-field grid (Stage 3c-perf step 4)

    /// A cached lattice of free-orientation lead fields over the source volume.
    /// A candidate position then costs a trilinear blend of 8 nodes instead of a
    /// fresh spherical-harmonic solve, which is what makes the small-batch joint
    /// refinement cheap. Built once per geometry and reused across fits, so the
    /// press-Fit / drag / re-fit loop pays for it only once.
    ///
    /// Values are stored as `Float` (halving a sizeable table) and interpolated in
    /// `Double`; the grid is only ever used to *rank* candidates, and `finalize`
    /// still evaluates the exact forward model at the chosen positions.
    final class LeadFieldGrid: @unchecked Sendable {
        let origin: Vector3D
        let spacing: Double
        let dim: Int
        let channelCount: Int
        private let values: [Float]
        private let valid: [Bool]

        init(origin: Vector3D, spacing: Double, dim: Int, channelCount: Int,
             values: [Float], valid: [Bool]) {
            self.origin = origin
            self.spacing = spacing
            self.dim = dim
            self.channelCount = channelCount
            self.values = values
            self.valid = valid
        }

        private func nodeIndex(_ ix: Int, _ iy: Int, _ iz: Int) -> Int {
            (iz * dim + iy) * dim + ix
        }

        /// Writes a `channelCount × 3` row-major block for `position`. Returns
        /// false when any of the 8 surrounding nodes is outside the solved
        /// volume, so the caller can fall back to an exact solve.
        func interpolate(at position: Vector3D, into out: UnsafeMutablePointer<Double>) -> Bool {
            let fx = (position.x - origin.x) / spacing
            let fy = (position.y - origin.y) / spacing
            let fz = (position.z - origin.z) / spacing
            let ix = Int(fx.rounded(.down)), iy = Int(fy.rounded(.down)), iz = Int(fz.rounded(.down))
            guard ix >= 0, iy >= 0, iz >= 0, ix + 1 < dim, iy + 1 < dim, iz + 1 < dim else { return false }
            let tx = fx - Double(ix), ty = fy - Double(iy), tz = fz - Double(iz)
            let stride = channelCount * 3

            var bases = [Int](repeating: 0, count: 8)
            var weights = [Double](repeating: 0, count: 8)
            var slot = 0
            for dz in 0...1 {
                for dy in 0...1 {
                    for dx in 0...1 {
                        let index = nodeIndex(ix + dx, iy + dy, iz + dz)
                        guard valid[index] else { return false }
                        bases[slot] = index * stride
                        weights[slot] = (dx == 1 ? tx : 1 - tx)
                            * (dy == 1 ? ty : 1 - ty)
                            * (dz == 1 ? tz : 1 - tz)
                        slot += 1
                    }
                }
            }
            return values.withUnsafeBufferPointer { buffer in
                let base = buffer.baseAddress!
                for i in 0..<stride { out[i] = 0 }
                for corner in 0..<8 {
                    let weight = weights[corner]
                    if weight == 0 { continue }
                    let source = base + bases[corner]
                    for i in 0..<stride { out[i] += weight * Double(source[i]) }
                }
                return true
            }
        }
    }

    private static let gridCacheLock = NSLock()
    nonisolated(unsafe) private static var gridCache: [String: LeadFieldGrid] = [:]
    /// Insertion order, for evicting the least recently built grid.
    nonisolated(unsafe) private static var gridOrder: [String] = []

    /// Returns the cached grid for this geometry, building it if needed.
    private static func leadFieldGrid(
        head: SphericalHeadModel, montage: Montage, reference: EEGReference,
        harmonicTerms: Int, maxRadius: Double, center: Vector3D,
        reporter: ProgressReporter? = nil
    ) -> LeadFieldGrid? {
        var key = "\(String(describing: head))|\(reference)|\(harmonicTerms)|"
        for electrode in montage.electrodes {
            key += "\(electrode.thetaDegrees),\(electrode.phiDegrees);"
        }

        gridCacheLock.lock()
        if let cached = gridCache[key] { gridCacheLock.unlock(); return cached }
        gridCacheLock.unlock()

        let channelCount = montage.electrodes.count
        let spacing = head.brainRadiusMeters / 12.0
        guard spacing > 0 else { return nil }
        // The cube spans a cell past the clamp radius so candidates there still
        // have surrounding indices, but only nodes strictly inside the innermost
        // shell can actually be solved — the forward model rejects a source at or
        // beyond the brain boundary. Nodes outside stay invalid, and the few
        // candidates whose corners include one fall back to an exact solve.
        let extent = maxRadius + 2 * spacing
        let solvableRadius = head.brainRadiusMeters * 0.985
        let dim = Int((2 * extent / spacing).rounded(.up)) + 1
        let origin = Vector3D(x: center.x - extent, y: center.y - extent, z: center.z - extent)

        var positions: [Vector3D] = []
        var nodeSlots: [Int] = []
        positions.reserveCapacity(dim * dim * dim / 2)
        for iz in 0..<dim {
            for iy in 0..<dim {
                for ix in 0..<dim {
                    let p = Vector3D(x: origin.x + Double(ix) * spacing,
                                     y: origin.y + Double(iy) * spacing,
                                     z: origin.z + Double(iz) * spacing)
                    if (p - center).norm <= solvableRadius {
                        positions.append(p)
                        nodeSlots.append((iz * dim + iy) * dim + ix)
                    }
                }
            }
        }
        guard !positions.isEmpty else { return nil }

        reporter?.phase("lead-field grid")
        reporter?.report(0, "Building lead-field grid: \(positions.count) nodes at \(String(format: "%.1f", spacing * 1000)) mm (cached for later fits)…")

        let stride = channelCount * 3
        var values = [Float](repeating: 0, count: dim * dim * dim * stride)
        var valid = [Bool](repeating: false, count: dim * dim * dim)

        // Solved in parallel: each worker owns a disjoint slice of nodes, so the
        // writes never overlap. (Doing this serially made the build cost more
        // than the fit it was meant to accelerate.)
        let workers = max(1, min(positions.count, ProcessInfo.processInfo.activeProcessorCount))
        let perWorker = (positions.count + workers - 1) / workers
        values.withUnsafeMutableBufferPointer { valueBuffer in
            valid.withUnsafeMutableBufferPointer { validBuffer in
                let valueBase = valueBuffer.baseAddress!
                let validBase = validBuffer.baseAddress!
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    let lower = worker * perWorker
                    let upper = min(lower + perWorker, positions.count)
                    guard lower < upper else { return }
                    let batch = 256
                    var solved = lower
                    while solved < upper {
                        let end = min(solved + batch, upper)
                        // A batch that fails leaves its nodes invalid rather than
                        // discarding the grid; those candidates fall back to exact.
                        guard let (flat, rowStride) = freeLeadFieldFlat(
                            candidates: Array(positions[solved..<end]), head: head, montage: montage,
                            reference: reference, harmonicTerms: harmonicTerms) else {
                            solved = end; continue
                        }
                        for local in 0..<(end - solved) {
                            let node = nodeSlots[solved + local]
                            let destination = node * stride
                            for ch in 0..<channelCount {
                                let source = ch * rowStride + 3 * local
                                valueBase[destination + ch * 3] = Float(flat[source])
                                valueBase[destination + ch * 3 + 1] = Float(flat[source + 1])
                                valueBase[destination + ch * 3 + 2] = Float(flat[source + 2])
                            }
                            validBase[node] = true
                        }
                        solved = end
                    }
                }
            }
        }
        if reporter?.isCancelled() == true { return nil }

        let grid = LeadFieldGrid(origin: origin, spacing: spacing, dim: dim,
                                 channelCount: channelCount, values: values, valid: valid)
        gridCacheLock.lock()
        // A grid runs tens of megabytes (≈19 MB at 64 channels, ≈75 MB at 256), so
        // keep only the few most recent geometries rather than every montage the
        // user has ever tried.
        if gridCache.count >= 3, let stale = gridOrder.first {
            gridCache.removeValue(forKey: stale)
            gridOrder.removeFirst()
        }
        gridCache[key] = grid
        gridOrder.append(key)
        gridCacheLock.unlock()
        return grid
    }

    /// Flat `channels × 3·positions.count` columns, taken from the grid when it
    /// covers every position so the fixed and candidate columns of a refinement
    /// design come from the same representation, and from an exact solve if not.
    private static func columnsFlat(
        for positions: [Vector3D], grid: LeadFieldGrid?,
        head: SphericalHeadModel, montage: Montage,
        reference: EEGReference, harmonicTerms: Int
    ) -> [Double]? {
        let channelCount = montage.electrodes.count
        let width = 3 * positions.count
        if let grid {
            var out = [Double](repeating: 0, count: channelCount * width)
            var block = [Double](repeating: 0, count: channelCount * 3)
            var covered = true
            block.withUnsafeMutableBufferPointer { buffer in
                let base = buffer.baseAddress!
                for (index, position) in positions.enumerated() {
                    guard grid.interpolate(at: position, into: base) else { covered = false; return }
                    for ch in 0..<channelCount {
                        let destination = ch * width + 3 * index
                        out[destination] = base[ch * 3]
                        out[destination + 1] = base[ch * 3 + 1]
                        out[destination + 2] = base[ch * 3 + 2]
                    }
                }
            }
            if covered { return out }
        }
        return freeLeadFieldFlat(
            candidates: positions, head: head, montage: montage,
            reference: reference, harmonicTerms: harmonicTerms)?.values
    }

    /// `freeLeadField` flattened to a row-major buffer plus its row stride.
    private static func freeLeadFieldFlat(
        candidates: [Vector3D], head: SphericalHeadModel, montage: Montage,
        reference: EEGReference, harmonicTerms: Int
    ) -> (values: [Double], rowStride: Int)? {
        guard let matrix = freeLeadField(
            candidates: candidates, head: head, montage: montage,
            reference: reference, harmonicTerms: harmonicTerms) else { return nil }
        let rows = matrix.count
        let columns = matrix.first?.count ?? 0
        guard rows > 0, columns > 0 else { return nil }
        var flat = [Double](repeating: 0, count: rows * columns)
        for row in 0..<rows {
            let source = matrix[row]
            let base = row * columns
            for column in 0..<columns { flat[base + column] = source[column] }
        }
        return (flat, columns)
    }

    /// Scores a batch of candidate positions in parallel and returns the best.
    /// `fixedColumns`, when present, are already-placed dipoles whose columns are
    /// prepended to every candidate's design (the joint-refinement case).
    /// Each worker solves the forward model for its *own* slice and scores it.
    /// Batching the whole chunk into one `freeLeadField` call first would leave
    /// the dominant cost — the spherical harmonic series, per electrode per
    /// candidate — running on a single thread.
    private static func bestCandidate(
        in candidates: [Vector3D],
        factor: CovarianceFactor,
        head: SphericalHeadModel, montage: Montage,
        reference: EEGReference, harmonicTerms: Int,
        fixedColumns: [Double]? = nil, fixedColumnCount: Int = 0,
        grid: LeadFieldGrid? = nil
    ) -> (position: Vector3D, residual: Double)? {
        guard !candidates.isEmpty else { return nil }

        let channelCount = factor.channelCount
        let p = fixedColumnCount + 3
        let rank = factor.rank
        let count = candidates.count
        // The already-placed dipoles' columns don't change while this candidate
        // batch is scanned, so their Gram block and their W-projection are built
        // once here rather than rebuilt for every candidate.
        let blocks = fixedColumns.map {
            FixedBlocks(columns: $0, fixedColumnCount: fixedColumnCount, factor: factor)
        }
        let workers = max(1, min(count, ProcessInfo.processInfo.activeProcessorCount))
        let perWorker = (count + workers - 1) / workers

        var results = [Double](repeating: .greatestFiniteMagnitude, count: workers)
        var winners = [Int](repeating: -1, count: workers)

        results.withUnsafeMutableBufferPointer { residualBuffer in
            winners.withUnsafeMutableBufferPointer { winnerBuffer in
                let residualOut = residualBuffer.baseAddress!
                let winnerOut = winnerBuffer.baseAddress!
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    let lower = worker * perWorker
                    let upper = min(lower + perWorker, count)
                    guard lower < upper else { return }
                    let slice = Array(candidates[lower..<upper])
                    var scratch = ObjectiveScratch(columns: p, rank: rank)
                    var bestResidual = Double.greatestFiniteMagnitude
                    var bestIndex = -1

                    // Preferred path: interpolate each candidate's columns out of
                    // the cached grid — no forward solve at all. Falls back to an
                    // exact batch solve for candidates the grid cannot cover.
                    if let grid {
                        var block = [Double](repeating: 0, count: channelCount * 3)
                        var missed: [Int] = []
                        block.withUnsafeMutableBufferPointer { blockBuffer in
                            let blockBase = blockBuffer.baseAddress!
                            for local in 0..<(upper - lower) {
                                guard grid.interpolate(at: slice[local], into: blockBase) else {
                                    missed.append(local); continue
                                }
                                let residual: Double
                                if let blocks {
                                    residual = blockedResidual(
                                        candidate: blockBase, rowStride: 3,
                                        blocks: blocks, factor: factor, scratch: &scratch)
                                } else {
                                    residual = factoredResidual(
                                        design: blockBase, rowStride: 3, columnOffset: 0,
                                        columns: p, factor: factor, scratch: &scratch)
                                }
                                if residual < bestResidual {
                                    bestResidual = residual
                                    bestIndex = lower + local
                                }
                            }
                        }
                        if !missed.isEmpty,
                           let (free, rowStride) = freeLeadFieldFlat(
                            candidates: missed.map { slice[$0] }, head: head, montage: montage,
                            reference: reference, harmonicTerms: harmonicTerms) {
                            free.withUnsafeBufferPointer { freeBuffer in
                                let freeBase = freeBuffer.baseAddress!
                                for (slot, local) in missed.enumerated() {
                                    let residual: Double
                                    if let blocks {
                                        residual = blockedResidual(
                                            candidate: freeBase + 3 * slot, rowStride: rowStride,
                                            blocks: blocks, factor: factor, scratch: &scratch)
                                    } else {
                                        residual = factoredResidual(
                                            design: freeBase, rowStride: rowStride,
                                            columnOffset: 3 * slot, columns: p,
                                            factor: factor, scratch: &scratch)
                                    }
                                    if residual < bestResidual {
                                        bestResidual = residual
                                        bestIndex = lower + local
                                    }
                                }
                            }
                        }
                    } else {
                        guard let (free, rowStride) = freeLeadFieldFlat(
                            candidates: slice, head: head, montage: montage,
                            reference: reference, harmonicTerms: harmonicTerms) else { return }
                        free.withUnsafeBufferPointer { freeBuffer in
                            let freeBase = freeBuffer.baseAddress!
                            for local in 0..<(upper - lower) {
                                let residual: Double
                                if let blocks {
                                    residual = blockedResidual(
                                        candidate: freeBase + 3 * local, rowStride: rowStride,
                                        blocks: blocks, factor: factor, scratch: &scratch)
                                } else {
                                    residual = factoredResidual(
                                        design: freeBase, rowStride: rowStride,
                                        columnOffset: 3 * local, columns: p,
                                        factor: factor, scratch: &scratch)
                                }
                                if residual < bestResidual {
                                    bestResidual = residual
                                    bestIndex = lower + local
                                }
                            }
                        }
                    }
                    (residualOut + worker).pointee = bestResidual
                    (winnerOut + worker).pointee = bestIndex
                }
            }
        }

        var bestResidual = Double.greatestFiniteMagnitude
        var bestIndex = -1
        for worker in 0..<workers where winners[worker] >= 0 {
            if results[worker] < bestResidual {
                bestResidual = results[worker]
                bestIndex = winners[worker]
            }
        }
        guard bestIndex >= 0 else { return nil }
        return (candidates[bestIndex], bestResidual)
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
    ///
    /// When `seeds` is supplied with exactly `count` positions, the deflation
    /// search is skipped and the seeds (clamped inside the brain) become the
    /// starting positions — the "drag a dipole, then refit from there" path. The
    /// same joint coordinate descent then refines them, so a single dragged dipole
    /// is refined too (the deflation path only refines when `count >= 2`).
    private static func fitPositionsFromCovariance(
        covariance: [[Double]], total: Double, count: Int, channelCount: Int,
        head: SphericalHeadModel, montage: Montage, reference: EEGReference, harmonicTerms: Int,
        seeds: [Vector3D]? = nil,
        reporter: ProgressReporter? = nil
    ) -> [Vector3D]? {
        let brainRadius = head.brainRadiusMeters
        guard brainRadius > 0 else { return nil }
        let maxRadius = brainRadius * 0.97
        let center = head.centerMeters
        // Stage 3c-perf step 7: the spherical-harmonic series converges quickly
        // for sources well inside the inner shell (they are clamped to 0.97 R),
        // so the *search* runs at reduced order. `finalize`, `deflateCovariance`
        // and `decompose` keep the caller's full term count, so every reported
        // number is computed at full accuracy.
        let searchTerms = min(harmonicTerms, 24)
        // Cached per geometry; the first fit pays for it and later fits (including
        // every drag-and-refit) reuse it.
        let grid = leadFieldGrid(
            head: head, montage: montage, reference: reference,
            harmonicTerms: searchTerms, maxRadius: maxRadius, center: center,
            reporter: reporter)

        var positions: [Vector3D] = []
        let seededStart = (seeds?.count == count)
        // Seeding skips the (expensive) deflation search entirely, so it gets a
        // small slice of the budget and refinement gets the rest.
        let searchUpper = seededStart ? 0.05 : 0.65
        if let seeds, seededStart {
            reporter?.report(0.02, "Seeding from \(count) dragged position\(count == 1 ? "" : "s") — skipping the coarse search")
            positions = seeds.map { clampToSphere($0, center: center, maxRadius: maxRadius) }
        } else {
            var residualCovariance = covariance
            var residualTotal = total
            for index in 0..<count {
                if reporter?.isCancelled() == true { return nil }
                let lower = searchUpper * Double(index) / Double(count)
                let upper = searchUpper * Double(index + 1) / Double(count)
                // Re-factor after each deflation: cheap next to the search it feeds.
                reporter?.phase("coarse search")
                let residualFactor = factorize(
                    covariance: residualCovariance, total: residualTotal,
                    channelCount: channelCount, modelColumns: 3)
                guard let position = covarianceSearch(
                    factor: residualFactor,
                    brainRadius: brainRadius, maxRadius: maxRadius, center: center,
                    head: head, montage: montage, reference: reference, harmonicTerms: searchTerms,
                    grid: grid,
                    reporter: reporter?.scoped(lower, upper),
                    label: "Dipole \(index + 1) of \(count)"
                ) else { break }
                positions.append(position)
                reporter?.phase("deflation")
                reporter?.report(upper, "Dipole \(index + 1) of \(count) — deflating covariance for the next search")
                deflateCovariance(
                    &residualCovariance, at: position, channelCount: channelCount,
                    head: head, montage: montage, reference: reference, harmonicTerms: harmonicTerms)
                residualTotal = 0.0
                for i in 0..<channelCount { residualTotal += residualCovariance[i][i] }
            }
        }
        guard !positions.isEmpty else { return nil }
        let k = positions.count

        if k >= 2 || (k == 1 && seededStart) {
            let sweeps = 4
            // The joint objective always sees the full covariance, so this factor
            // is built once and reused for every sweep.
            reporter?.phase("joint refinement")
            let jointFactor = factorize(
                covariance: covariance, total: total,
                channelCount: channelCount, modelColumns: 3 * k)
            // Stage 3c-perf step 5: the first sweep descends from a coarse step,
            // but later sweeps only ever nudge positions — restarting each one
            // from `brainRadius/4` re-walked ground that had not moved. Start
            // each later sweep from a step scaled to what actually shifted last
            // time (with generous headroom, since ±2 grid steps are searched),
            // and take only as many levels as are needed to reach the target
            // resolution from there.
            let targetResolution = 0.0008   // metres; the old 5-level descent's floor
            let coarseStep = brainRadius / 4.0
            var previousMaxShift = coarseStep
            for sweep in 0..<sweeps {
                if reporter?.isCancelled() == true { return nil }
                let startStep = sweep == 0
                    ? coarseStep
                    : min(coarseStep, max(previousMaxShift * 4, targetResolution * 2))
                let levels = max(2, Int(ceil(log(targetResolution / startStep) / log(0.45))) + 1)
                var maxShift = 0.0
                for i in 0..<k {
                    if reporter?.isCancelled() == true { return nil }
                    let done = (Double(sweep) + Double(i) / Double(k)) / Double(sweeps)
                    reporter?.report(searchUpper + (1 - searchUpper) * done,
                                     "Joint refinement — sweep \(sweep + 1) of \(sweeps), dipole \(i + 1) of \(k)")
                    let others = positions.enumerated().filter { $0.offset != i }.map(\.element)
                    // The other dipoles' columns are fixed for this whole
                    // sub-search, so solve and flatten them once.
                    var fixedColumns: [Double]?
                    let fixedColumnCount = 3 * others.count
                    if !others.isEmpty {
                        guard let flat = columnsFlat(
                            for: others, grid: grid, head: head, montage: montage,
                            reference: reference, harmonicTerms: searchTerms) else { continue }
                        fixedColumns = flat
                    }
                    var searchCenter = positions[i]
                    var step = startStep
                    var bestPosition = positions[i]
                    for _ in 0..<levels {
                        let candidates = localGrid(
                            around: searchCenter, step: step, halfWidthInSteps: 2,
                            center: center, maxRadius: maxRadius)
                        guard !candidates.isEmpty,
                              let winner = bestCandidate(
                                in: candidates, factor: jointFactor,
                                head: head, montage: montage,
                                reference: reference, harmonicTerms: searchTerms,
                                fixedColumns: fixedColumns, fixedColumnCount: fixedColumnCount,
                                grid: grid)
                        else { break }
                        bestPosition = winner.position
                        searchCenter = bestPosition
                        step *= 0.45
                    }
                    maxShift = max(maxShift, (bestPosition - positions[i]).norm)
                    positions[i] = bestPosition
                }
                previousMaxShift = maxShift
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
        factor: CovarianceFactor,
        brainRadius: Double, maxRadius: Double, center: Vector3D,
        head: SphericalHeadModel, montage: Montage, reference: EEGReference, harmonicTerms: Int,
        grid: LeadFieldGrid? = nil,
        reporter: ProgressReporter? = nil,
        label: String = "Dipole"
    ) -> Vector3D? {
        var best: (position: Vector3D, residual: Double)?
        var searchCenter = center
        var step = brainRadius / 5.0
        let levels = 6
        // Candidates are scored in chunks so a long level reports real progress
        // and can be cancelled part way; each chunk is scanned in parallel.
        let chunkSize = 512
        for level in 0..<levels {
            if reporter?.isCancelled() == true { return nil }
            let candidates = level == 0
                ? gridInsideSphere(center: center, maxRadius: maxRadius, step: step)
                : localGrid(around: searchCenter, step: step, halfWidthInSteps: 2,
                            center: center, maxRadius: maxRadius)
            guard !candidates.isEmpty else { break }

            let levelBase = Double(level) / Double(levels)
            let levelSpan = 1.0 / Double(levels)
            reporter?.report(levelBase, String(
                format: "%@ — %@ (level %d of %d): %d positions, %.1f mm step",
                label, level == 0 ? "coarse grid" : "refining", level + 1, levels,
                candidates.count, step * 1000))

            var solvedAny = false
            var offset = 0
            while offset < candidates.count {
                if reporter?.isCancelled() == true { return nil }
                let end = min(offset + chunkSize, candidates.count)
                let chunk = Array(candidates[offset..<end])
                guard let winner = bestCandidate(
                    in: chunk, factor: factor, head: head, montage: montage,
                    reference: reference, harmonicTerms: harmonicTerms,
                    grid: grid) else { break }
                solvedAny = true
                if best == nil || winner.residual < best!.residual { best = winner }
                offset = end
                reporter?.report(levelBase + levelSpan * Double(offset) / Double(candidates.count),
                                 String(format: "%@ — scoring position %d of %d (level %d of %d)",
                                        label, offset, candidates.count, level + 1, levels))
            }
            guard solvedAny else { if level == 0 { return nil } else { break } }
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

    /// Pulls a point inside the brain sphere (centre `center`, radius `maxRadius`),
    /// leaving interior points untouched. Used to keep a dragged seed solvable.
    private static func clampToSphere(_ p: Vector3D, center: Vector3D, maxRadius: Double) -> Vector3D {
        let d = p - center
        let r = d.norm
        guard r > maxRadius, r > 0 else { return p }
        return center + d * (maxRadius / r)
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
