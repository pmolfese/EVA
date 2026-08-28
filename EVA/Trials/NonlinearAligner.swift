//
//  NonlinearAligner.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Non-linear single-trial alignment engines used by the CWT-Ridge pipeline.
//  Unlike Woody (a single rigid shift), these can align multiple components with
//  different, time-varying latencies:
//
//   * DTW — Dynamic Time Warping against a template, with a Sakoe-Chiba band so
//     the warp stays monotonic and physiologically plausible. Produces a full
//     warping function, so early and late components can shift independently.
//
//   * Curve registration — landmark (peak) registration: each trial's detected
//     peaks are warped onto the template's peaks with a monotone piecewise
//     mapping (Ramsay & Silverman). Separates phase (latency) from amplitude
//     variability.
//
//   * Maximum likelihood — MAP single-trial latency estimation with a Gaussian
//     smoothness prior on the shift, robust for low-SNR trials where plain
//     cross-correlation diverges.
//
//  These are original Swift implementations of the published methods.
//
//  References:
//    * DTW / Sakoe-Chiba band: Sakoe, H., & Chiba, S. (1978). Dynamic
//      programming algorithm optimization for spoken word recognition. IEEE
//      Transactions on Acoustics, Speech, and Signal Processing, 26(1), 43-49.
//      https://doi.org/10.1109/TASSP.1978.1163055
//    * Curve / landmark registration: Ramsay, J. O., & Silverman, B. W. (2005).
//      Functional Data Analysis (2nd ed.), Chapters 7-8 (registration). Springer.
//

import Foundation

nonisolated enum NonlinearAligner {
    enum Engine: String, CaseIterable, Identifiable, Sendable {
        case dtw = "DTW"
        case curveRegistration = "Curve Registration"
        case maxLikelihood = "Maximum Likelihood"

        var id: String { rawValue }
    }

    /// One trial's warped output plus the warping function that produced it.
    struct WarpedTrial: Identifiable, Sendable {
        var id: Int
        var trialIndex: Int
        /// For each output sample, the (possibly fractional) source-sample index
        /// it was drawn from. Length == output length.
        var warpFunction: [Double]
        var aligned: [Float]
        /// Correlation of the aligned trial with the template (fit quality).
        var correlation: Double
        /// Net latency of the trial's dominant deflection relative to the
        /// template, in samples (positive = trial later than template).
        var netShiftSamples: Double
    }

    struct Result: Sendable {
        var engine: Engine
        var template: [Float]
        var warped: [WarpedTrial]
        var alignedAverage: [Float]
        var unalignedAverage: [Float]
    }

    // MARK: - Entry point

    static func align(
        trials: [[Float]],
        template initialTemplate: [Float]? = nil,
        engine: Engine,
        sakoeChibaBand: Int = 20,
        maxShiftSamples: Int = 60,
        priorSigmaSamples: Double = 15,
        trialPeaks: [[CWTRidgeDetector.Peak]] = [],
        templatePeaks: [CWTRidgeDetector.Peak] = []
    ) -> Result? {
        guard let length = trials.first?.count, length > 0 else { return nil }
        let valid = trials.filter { $0.count == length }
        guard !valid.isEmpty else { return nil }

        let unaligned = average(valid, length: length)
        let template = initialTemplate?.count == length ? initialTemplate! : unaligned

        var warped: [WarpedTrial] = []
        for (index, trial) in valid.enumerated() {
            let peaks = index < trialPeaks.count ? trialPeaks[index] : []
            let w: WarpedTrial
            switch engine {
            case .dtw:
                w = dtwAlign(trial, to: template, index: index, band: sakoeChibaBand)
            case .curveRegistration:
                w = registerLandmarks(trial, to: template, trialPeaks: peaks, templatePeaks: templatePeaks, index: index)
            case .maxLikelihood:
                w = maxLikelihoodAlign(trial, to: template, index: index, maxShift: maxShiftSamples, priorSigma: priorSigmaSamples)
            }
            warped.append(w)
        }

        let aligned = average(warped.map(\.aligned), length: length)
        return Result(
            engine: engine,
            template: template,
            warped: warped,
            alignedAverage: aligned,
            unalignedAverage: unaligned
        )
    }

    // MARK: - DTW

    static func dtwAlign(_ trial: [Float], to template: [Float], index: Int, band: Int) -> WarpedTrial {
        let n = template.count
        let m = trial.count
        let t = template.map(Double.init)
        let x = trial.map(Double.init)
        let bandWidth = max(band, abs(n - m) + 1)

        // Cost matrix with Sakoe-Chiba band. cost[i][j] aligns template i, trial j.
        var cost = [[Double]](repeating: [Double](repeating: .infinity, count: m + 1), count: n + 1)
        cost[0][0] = 0
        for i in 1...n {
            let jLow = max(1, i - bandWidth)
            let jHigh = min(m, i + bandWidth)
            guard jLow <= jHigh else { continue }
            for j in jLow...jHigh {
                let d = abs(t[i - 1] - x[j - 1])
                let best = min(cost[i - 1][j], cost[i][j - 1], cost[i - 1][j - 1])
                cost[i][j] = d + (best.isFinite ? best : .infinity)
            }
        }

        // Backtrack to recover the warping path.
        var path: [(i: Int, j: Int)] = []
        var i = n
        var j = m
        while i > 0 && j > 0 {
            path.append((i, j))
            let diag = cost[i - 1][j - 1]
            let up = cost[i - 1][j]
            let left = cost[i][j - 1]
            let minValue = min(diag, up, left)
            if minValue == diag { i -= 1; j -= 1 }
            else if minValue == up { i -= 1 }
            else { j -= 1 }
        }
        path.reverse()

        // For each template sample, average the trial samples mapped to it.
        var warpFunction = [Double](repeating: 0, count: n)
        var aligned = [Float](repeating: 0, count: n)
        var counts = [Int](repeating: 0, count: n)
        var sums = [Double](repeating: 0, count: n)
        var jSums = [Double](repeating: 0, count: n)
        for (ti, tj) in path {
            let idx = ti - 1
            guard idx >= 0, idx < n else { continue }
            sums[idx] += x[tj - 1]
            jSums[idx] += Double(tj - 1)
            counts[idx] += 1
        }
        var lastValue = 0.0
        var lastSource = 0.0
        for k in 0..<n {
            if counts[k] > 0 {
                lastValue = sums[k] / Double(counts[k])
                lastSource = jSums[k] / Double(counts[k])
            }
            aligned[k] = Float(lastValue)
            warpFunction[k] = lastSource
        }

        let correlation = pearson(template, aligned)
        let netShift = meanWarpShift(warpFunction)
        return WarpedTrial(
            id: index,
            trialIndex: index,
            warpFunction: warpFunction,
            aligned: aligned,
            correlation: correlation,
            netShiftSamples: netShift
        )
    }

    // MARK: - Curve registration (landmark)

    static func registerLandmarks(
        _ trial: [Float],
        to template: [Float],
        trialPeaks: [CWTRidgeDetector.Peak],
        templatePeaks: [CWTRidgeDetector.Peak],
        index: Int
    ) -> WarpedTrial {
        let n = template.count

        // Match trial peaks to template peaks by polarity + proximity to build a
        // monotone set of (targetSample -> sourceSample) landmarks.
        var landmarks: [(target: Double, source: Double)] = [(0, 0)]
        let sortedTemplate = templatePeaks.sorted { $0.sampleIndex < $1.sampleIndex }
        var usedTrial = Set<Int>()
        for templatePeak in sortedTemplate {
            guard let match = nearestPeak(templatePeak, in: trialPeaks, excluding: usedTrial) else { continue }
            usedTrial.insert(match.id)
            landmarks.append((target: Double(templatePeak.sampleIndex), source: Double(match.sampleIndex)))
        }
        landmarks.append((target: Double(n - 1), source: Double(trial.count - 1)))
        // Enforce monotonic, de-duplicated landmarks.
        landmarks = sanitizeLandmarks(landmarks)

        // Piecewise-linear warp: for each output sample, interpolate the source index.
        var warpFunction = [Double](repeating: 0, count: n)
        var aligned = [Float](repeating: 0, count: n)
        for k in 0..<n {
            let source = interpolateSource(target: Double(k), landmarks: landmarks)
            warpFunction[k] = source
            aligned[k] = sampleLinear(trial, at: source)
        }

        let correlation = pearson(template, aligned)
        let netShift = landmarks.count > 2
            ? (landmarks.dropFirst().dropLast().map { $0.source - $0.target }.reduce(0, +) / Double(max(1, landmarks.count - 2)))
            : meanWarpShift(warpFunction)
        return WarpedTrial(
            id: index,
            trialIndex: index,
            warpFunction: warpFunction,
            aligned: aligned,
            correlation: correlation,
            netShiftSamples: netShift
        )
    }

    // MARK: - Maximum likelihood (MAP rigid shift with smoothness prior)

    static func maxLikelihoodAlign(
        _ trial: [Float],
        to template: [Float],
        index: Int,
        maxShift: Int,
        priorSigma: Double
    ) -> WarpedTrial {
        let n = template.count
        let t = template.map(Double.init)
        let x = trial.map(Double.init)
        let noiseVariance = max(residualVariance(t, x), 1e-9)
        let sigma2 = max(priorSigma * priorSigma, 1e-6)

        var bestShift = 0
        var bestPosterior = -Double.infinity
        // Require most of the template to actually overlap; otherwise a
        // boundary shift with only a handful of samples can win on a
        // spuriously small sum of squared errors.
        let minimumOverlap = max(n / 2, 1)
        for shift in (-maxShift)...maxShift {
            // Gaussian log-likelihood of the shifted trial under the template,
            // normalized to mean squared error so shifts are compared on a
            // per-sample basis rather than by raw summed error — a raw sum
            // shrinks (and so looks more likely) simply because a large
            // shift discards more edge samples.
            var sse = 0.0
            var count = 0
            for i in 0..<n {
                let j = i + shift
                guard j >= 0, j < x.count else { continue }
                let diff = t[i] - x[j]
                sse += diff * diff
                count += 1
            }
            guard count >= minimumOverlap else { continue }
            let meanSSE = sse / Double(count)
            let logLikelihood = -meanSSE / (2.0 * noiseVariance)
            let logPrior = -Double(shift * shift) / (2.0 * sigma2)
            let posterior = logLikelihood + logPrior
            if posterior > bestPosterior {
                bestPosterior = posterior
                bestShift = shift
            }
        }

        var aligned = [Float](repeating: 0, count: n)
        var warpFunction = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let j = i + bestShift
            warpFunction[i] = Double(j)
            if j >= 0 && j < x.count { aligned[i] = Float(x[j]) }
        }
        let correlation = pearson(template, aligned)
        return WarpedTrial(
            id: index,
            trialIndex: index,
            warpFunction: warpFunction,
            aligned: aligned,
            correlation: correlation,
            netShiftSamples: Double(bestShift)
        )
    }

    // MARK: - Functional PCA (on registered/aligned curves)

    struct FunctionalPCA: Sendable {
        var mean: [Float]
        /// Principal component curves (eigenvectors), most-variance first.
        var components: [[Float]]
        /// Fraction of total variance explained by each component.
        var explainedVariance: [Double]
        /// Per-trial scores on each retained component `[trial][component]`.
        var scores: [[Double]]
    }

    /// Functional PCA via the covariance of the (already registered) curves. Used
    /// to summarize the amplitude modes remaining after phase/latency is removed.
    static func functionalPCA(_ curves: [[Float]], componentCount: Int = 3) -> FunctionalPCA? {
        guard let length = curves.first?.count, length > 0 else { return nil }
        let data = curves.filter { $0.count == length }.map { $0.map(Double.init) }
        guard data.count >= 2 else { return nil }

        let mean = (0..<length).map { i in data.reduce(0.0) { $0 + $1[i] } / Double(data.count) }
        let centered = data.map { row in zip(row, mean).map(-) }

        // Covariance via the trial (Gram) matrix to avoid an LxL eigenproblem.
        // C = (1/(K-1)) Σ centered_k centered_kᵀ ; use the dual formulation.
        let k = centered.count
        var gram = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        for a in 0..<k {
            for b in a..<k {
                var dot = 0.0
                for i in 0..<length { dot += centered[a][i] * centered[b][i] }
                gram[a][b] = dot
                gram[b][a] = dot
            }
        }

        guard let (eigenvalues, eigenvectors) = jacobiEigen(gram) else { return nil }
        // Sort descending by eigenvalue.
        let order = eigenvalues.indices.sorted { eigenvalues[$0] > eigenvalues[$1] }
        let totalVariance = eigenvalues.reduce(0, +)
        guard totalVariance > 0 else { return nil }

        var components: [[Float]] = []
        var explained: [Double] = []
        let retained = min(componentCount, order.count)
        var basis: [[Double]] = []
        for c in 0..<retained {
            let idx = order[c]
            let eigenvalue = eigenvalues[idx]
            guard eigenvalue > 1e-12 else { continue }
            // Map dual eigenvector back to feature space: v = Σ_k u_k centered_k, normalized.
            var v = [Double](repeating: 0, count: length)
            for a in 0..<k {
                let weight = eigenvectors[a][idx]
                for i in 0..<length { v[i] += weight * centered[a][i] }
            }
            let norm = v.map { $0 * $0 }.reduce(0, +).squareRoot()
            guard norm > 1e-12 else { continue }
            let unit = v.map { $0 / norm }
            basis.append(unit)
            components.append(unit.map(Float.init))
            explained.append(eigenvalue / totalVariance)
        }

        // Project each centered curve onto the retained basis for scores.
        let scores = centered.map { row -> [Double] in
            basis.map { component in
                zip(row, component).reduce(0.0) { $0 + $1.0 * $1.1 }
            }
        }

        return FunctionalPCA(
            mean: mean.map(Float.init),
            components: components,
            explainedVariance: explained,
            scores: scores
        )
    }

    // MARK: - Helpers

    static func average(_ traces: [[Float]], length: Int) -> [Float] {
        guard !traces.isEmpty, length > 0 else { return [] }
        var sums = [Double](repeating: 0, count: length)
        var counts = [Int](repeating: 0, count: length)
        for trace in traces where trace.count == length {
            for i in 0..<length {
                let value = Double(trace[i])
                guard value.isFinite else { continue }
                sums[i] += value
                counts[i] += 1
            }
        }
        return (0..<length).map { counts[$0] > 0 ? Float(sums[$0] / Double(counts[$0])) : 0 }
    }

    private static func pearson(_ a: [Float], _ b: [Float]) -> Double {
        let n = min(a.count, b.count)
        guard n >= 3 else { return 0 }
        var meanA = 0.0, meanB = 0.0
        for i in 0..<n { meanA += Double(a[i]); meanB += Double(b[i]) }
        meanA /= Double(n); meanB /= Double(n)
        var num = 0.0, ssA = 0.0, ssB = 0.0
        for i in 0..<n {
            let da = Double(a[i]) - meanA
            let db = Double(b[i]) - meanB
            num += da * db; ssA += da * da; ssB += db * db
        }
        let denom = (ssA * ssB).squareRoot()
        return denom > 1e-12 ? num / denom : 0
    }

    private static func residualVariance(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 1 else { return 1 }
        var sse = 0.0
        for i in 0..<n { let d = a[i] - b[i]; sse += d * d }
        return sse / Double(n)
    }

    private static func meanWarpShift(_ warpFunction: [Double]) -> Double {
        guard !warpFunction.isEmpty else { return 0 }
        var acc = 0.0
        for (i, source) in warpFunction.enumerated() { acc += source - Double(i) }
        return acc / Double(warpFunction.count)
    }

    private static func nearestPeak(
        _ target: CWTRidgeDetector.Peak,
        in candidates: [CWTRidgeDetector.Peak],
        excluding used: Set<Int>
    ) -> CWTRidgeDetector.Peak? {
        var best: CWTRidgeDetector.Peak?
        var bestDistance = Int.max
        for candidate in candidates where !used.contains(candidate.id) {
            guard candidate.polaritySign == target.polaritySign else { continue }
            let distance = abs(candidate.sampleIndex - target.sampleIndex)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }

    private static func sanitizeLandmarks(_ landmarks: [(target: Double, source: Double)]) -> [(target: Double, source: Double)] {
        let sorted = landmarks.sorted { $0.target < $1.target }
        var result: [(target: Double, source: Double)] = []
        for point in sorted {
            if let last = result.last {
                guard point.target > last.target else { continue }
                // Keep source monotonically non-decreasing.
                let source = max(point.source, last.source)
                result.append((point.target, source))
            } else {
                result.append(point)
            }
        }
        return result
    }

    private static func interpolateSource(target: Double, landmarks: [(target: Double, source: Double)]) -> Double {
        guard let first = landmarks.first else { return target }
        if target <= first.target { return first.source }
        for i in 1..<landmarks.count {
            let lo = landmarks[i - 1]
            let hi = landmarks[i]
            if target <= hi.target {
                let span = hi.target - lo.target
                guard span > 0 else { return lo.source }
                let frac = (target - lo.target) / span
                return lo.source + frac * (hi.source - lo.source)
            }
        }
        return landmarks.last?.source ?? target
    }

    private static func sampleLinear(_ trace: [Float], at position: Double) -> Float {
        guard !trace.isEmpty else { return 0 }
        if position <= 0 { return trace[0] }
        if position >= Double(trace.count - 1) { return trace[trace.count - 1] }
        let lower = Int(position.rounded(.down))
        let frac = position - Double(lower)
        let a = Double(trace[lower])
        let b = Double(trace[min(lower + 1, trace.count - 1)])
        return Float(a + frac * (b - a))
    }

    // MARK: - Symmetric eigen-decomposition (Jacobi rotation)

    /// Classical Jacobi eigenvalue algorithm for a small symmetric matrix.
    /// Returns eigenvalues and eigenvectors as columns of the returned matrix
    /// (`vectors[row][column]`).
    private static func jacobiEigen(_ matrix: [[Double]], maxSweeps: Int = 100, tolerance: Double = 1e-10) -> (values: [Double], vectors: [[Double]])? {
        let n = matrix.count
        guard n > 0, matrix.allSatisfy({ $0.count == n }) else { return nil }
        var a = matrix
        var v = (0..<n).map { i in (0..<n).map { j in i == j ? 1.0 : 0.0 } }

        for _ in 0..<maxSweeps {
            // Largest off-diagonal magnitude.
            var p = 0, q = 1
            var maxOff = 0.0
            for i in 0..<n {
                for j in (i + 1)..<n {
                    if abs(a[i][j]) > maxOff { maxOff = abs(a[i][j]); p = i; q = j }
                }
            }
            if maxOff < tolerance { break }

            let app = a[p][p], aqq = a[q][q], apq = a[p][q]
            let phi = 0.5 * atan2(2.0 * apq, aqq - app)
            let c = cos(phi), s = sin(phi)

            for k in 0..<n {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<n {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
            for k in 0..<n {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }

        let values = (0..<n).map { a[$0][$0] }
        return (values, v)
    }
}
