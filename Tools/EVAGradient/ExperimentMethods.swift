import Foundation

struct ExperimentResult {
    let channels: [[Float]]
    let epochs: [GradientEpochDiagnostic]
    let details: [String: Any]
}

/// One native-sample artifact coefficient per acquisition group/lag. Each sample
/// belongs to at most one epoch; gaps and pre/post-scan samples are unmodeled.
struct ArtifactPhaseDesign {
    let phase: [Int]
    let counts: [Double]
    let width: Int
    init(layout: GradientEpochLayout, sampleCount: Int, volumeTriggers: [Int]) throws {
        let volumes = Array(Set(volumeTriggers)).sorted()
        guard volumes.count >= 2 else { throw CLIError("Artifact phase design needs two volumes") }
        let spacings = zip(volumes, volumes.dropFirst()).map { $1 - $0 }.sorted()
        let typical = spacings[spacings.count / 2]
        var ends = [Int](repeating: 0, count: layout.count)
        var previousInterval = typical
        var volumeEnds = [Int]()
        for v in volumes.indices {
            let observed = v + 1 < volumes.count ? volumes[v + 1] - volumes[v] : previousInterval
            let interval = Double(observed) > 1.5 * Double(typical) ? typical : observed
            volumeEnds.append(volumes[v] + interval)
            previousInterval = interval
        }
        for e in 0..<layout.count {
            let v = layout.volumeIndex[e]
            guard volumeEnds.indices.contains(v) else { throw CLIError("Volume geometry mismatch") }
            let next = e + 1 < layout.count && layout.volumeIndex[e + 1] == v
                ? layout.triggers[e + 1] : volumeEnds[v]
            ends[e] = min(sampleCount, next)
        }
        let width = zip(layout.triggers, ends).map { max(0, $1 - $0) }.max() ?? 0
        guard width > 0, layout.slicesPerVolume <= 2_000_000 / width else {
            throw CLIError("Artifact phase model exceeds two million coefficients")
        }
        var phase = [Int](repeating: -1, count: sampleCount)
        var counts = [Double](repeating: 0, count: width * layout.slicesPerVolume)
        for e in 0..<layout.count {
            let start = layout.triggers[e], end = ends[e]
            guard start >= 0, start < end else { continue }
            for i in start..<end {
                let p = layout.slicePosition[e] * width + i - start
                phase[i] = p; counts[p] += 1
            }
        }
        self.phase = phase; self.counts = counts; self.width = width
    }
    func means(_ y: [Float]) -> [Double] {
        var sums = [Double](repeating: 0, count: counts.count)
        for i in y.indices where phase[i] >= 0 { sums[phase[i]] += Double(y[i]) }
        for p in sums.indices where counts[p] > 0 { sums[p] /= counts[p] }
        return sums
    }
}

/// Sparse condition-specific, piecewise-constant FIR columns. Overlapping events
/// add; the normal system therefore accounts for overlap instead of averaging it.
struct ERPDesign {
    let columns: [[(sample: Int, value: Double)]]
    let gram: [[Double]]
    let binSamples: Int
    let startSample: Int
    let bins: Int
    init(signal: MFFSignalData, options: Options) throws {
        let rate = signal.samplingRate, n = signal.data[0].count
        binSamples = max(1, Int((options.firBinMS * rate / 1000).rounded()))
        startSample = Int((options.protect.lowerBound * rate).rounded())
        let end = Int((options.protect.upperBound * rate).rounded())
        guard end > startSample else { throw CLIError("ERP window is shorter than one sample") }
        bins = (end - startSample + binSamples - 1) / binSamples
        guard bins <= 512 / options.events.count else { throw CLIError("ERP model exceeds 512 columns; increase --fir-bin-ms or reduce conditions/window") }
        let q = bins * options.events.count
        var entries: [(sample: Int, col: Int)] = []
        for event in signal.events {
            guard let condition = options.events.firstIndex(of: event.code.lowercased()), event.beginTimeSeconds.isFinite else { continue }
            let onset = Int((event.beginTimeSeconds * rate).rounded())
            let lo = max(0, onset + startSample), hi = min(n, onset + end)
            guard lo < hi else { continue }
            guard entries.count + hi - lo <= 20_000_000 else { throw CLIError("ERP design exceeds 20 million entries; use a shorter recording") }
            for sample in lo..<hi {
                entries.append((sample, condition * bins + (sample - onset - startSample) / binSamples))
            }
        }
        entries.sort { $0.sample == $1.sample ? $0.col < $1.col : $0.sample < $1.sample }
        var columns = [[(sample: Int, value: Double)]](repeating: [], count: q)
        var gram = [[Double]](repeating: [Double](repeating: 0, count: q), count: q)
        var index = 0
        while index < entries.count {
            let sample = entries[index].sample
            var row: [(Int, Double)] = []
            while index < entries.count, entries[index].sample == sample {
                let col = entries[index].col
                var value = 0.0
                while index < entries.count, entries[index].sample == sample, entries[index].col == col {
                    value += 1; index += 1
                }
                row.append((col, value)); columns[col].append((sample, value))
            }
            for (a, va) in row { for (b, vb) in row { gram[a][b] += va * vb } }
        }
        self.columns = columns; self.gram = gram
    }
    func rhs(_ y: [Float]) -> [Double] {
        columns.map { column in column.reduce(0) { $0 + Double(y[$1.sample]) * $1.value } }
    }
    func predict(_ beta: [Double], count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        for c in columns.indices { for entry in columns[c] { result[entry.sample] += Float(entry.value * beta[c]) } }
        return result
    }
}

/// Normalize using the original ERP column norms, then inspect the *unregularized*
/// residual Gram spectrum. Ridge never hides a nonidentifiable design.
struct ERPSolver {
    let scales: [Double]
    let eigenvalues: [Double]
    let vectors: [[Double]]
    let ridge: Double
    let rank: Int
    let condition: Double?
    init(gram: [[Double]], originalGram: [[Double]], ridge: Double, allowConfounded: Bool) throws {
        let scales = originalGram.indices.map { sqrt(max(originalGram[$0][$0], 1e-30)) }
        self.scales = scales
        let matrix = gram.indices.map { i in gram.indices.map { j in gram[i][j] / (scales[i] * scales[j]) } }
        let decomposition = LinearAlgebra.symmetricEigenDecomposition(matrix)
        guard decomposition.values.count == gram.count, decomposition.values.allSatisfy(\.isFinite) else { throw CLIError("ERP eigensolver failed") }
        eigenvalues = decomposition.values; vectors = decomposition.vectors; self.ridge = ridge
        let maximum = max(eigenvalues.max() ?? 0, 0)
        let threshold = max(1e-10, maximum * 1e-8)
        rank = eigenvalues.filter { $0 > threshold }.count
        condition = rank == gram.count ? maximum / max(eigenvalues.min()!, threshold) : nil
        if rank < gram.count && !allowConfounded {
            throw CLIError("Nonidentifiable ERP design: rank \(rank)/\(gram.count). Timing cannot separate all terms. Use --allow-confounded true only for an explicitly regularized sensitivity experiment.")
        }
    }
    func solve(_ rhs: [Double]) -> [Double] {
        let q = rhs.count
        var normalized = [Double](repeating: 0, count: q)
        for k in 0..<q {
            let denom = max(0, eigenvalues[k]) + ridge
            guard denom > 1e-12 else { continue }
            var projection = 0.0
            for i in 0..<q { projection += vectors[i][k] * rhs[i] / scales[i] }
            for i in 0..<q { normalized[i] += vectors[i][k] * projection / denom }
        }
        return normalized.indices.map { normalized[$0] / scales[$0] }
    }
    var report: [String: Any] {
        ["rank": rank, "columns": scales.count, "fullRank": rank == scales.count,
         "normalizedGramCondition": condition as Any? ?? NSNull(), "ridge": ridge,
         "minimumEigenvalue": eigenvalues.min() ?? 0,
         "warning": rank < scales.count ? "Nonidentifiable: regularization determines allocation of shared variance" : "Full rank does not establish model adequacy"]
    }
}

func runMethod(_ method: String, signal: MFFSignalData, triggers: [Int], layout: GradientEpochLayout,
               options: Options, protected: [Range<Double>]) throws -> ExperimentResult {
    let raw = signal.data, rate = signal.samplingRate, n = raw[0].count
    let config = options.config(intervals: method == "exclude" ? protected : [])
    if method == "baseline" || method == "exclude" {
        let result = try GradientTemplateCorrector.correct(channels: raw, volumeTriggers: triggers, config: config, samplingRate: rate)
        return ExperimentResult(channels: result.channels, epochs: result.diagnostics.epochs,
            details: ["warnings": result.diagnostics.warnings.map { String(describing: $0) }, "model": "local same-group AAS"])
    }
    if method == "aas" { throw CLIError("Legacy AAS is disabled; use allen") }
    if method.hasPrefix("allen") || method.hasPrefix("farm") {
        return try runEngineAddon(method, signal: signal, triggers: triggers, options: options, protected: protected)
    }
    let erp = try ERPDesign(signal: signal, options: options)
    if method == "iterative" {
        let solver = try ERPSolver(gram: erp.gram, originalGram: erp.gram, ridge: options.ridge, allowConfounded: options.allowConfounded)
        var estimate = raw.map { [Float](repeating: 0, count: $0.count) }
        var previousArtifact = estimate
        var corrected = raw
        var history: [[String: Any]] = [], epochs: [GradientEpochDiagnostic] = []
        var converged = false
        for iteration in 1...options.iterations {
            let training = zip(raw, estimate).map { a, b in zip(a, b).map(-) }
            let gradient = try GradientTemplateCorrector.correct(channels: training, volumeTriggers: triggers, config: config, samplingRate: rate)
            let artifact = zip(training, gradient.channels).map { a, b in zip(a, b).map(-) }
            corrected = zip(raw, artifact).map { a, b in zip(a, b).map(-) }
            let updated = corrected.map { erp.predict(solver.solve(erp.rhs($0)), count: n) }
            let zeros = [Float](repeating: 0, count: n)
            let erpChange = rms(updated, estimate) / max(rms(updated, updated.map { _ in zeros }), 1e-12)
            let artifactChange = rms(artifact, previousArtifact) / max(rms(artifact, artifact.map { _ in zeros }), 1e-12)
            history.append(["iteration": iteration, "relativeERPChange": erpChange, "relativeArtifactChange": artifactChange])
            estimate = updated; previousArtifact = artifact; epochs = gradient.diagnostics.epochs
            if iteration > 1, max(erpChange, artifactChange) < options.tolerance { converged = true; break }
        }
        return ExperimentResult(channels: corrected, epochs: epochs,
            details: ["model": "alternating local AAS and overlap-aware condition FIR", "iterations": history,
                      "converged": converged, "erpSolver": solver.report,
                      "firBinSamples": erp.binSamples, "firStartSample": erp.startSample, "firBinsPerCondition": erp.bins,
                      "warning": "Convergence is not identifiability or preservation; compare against truth/injection"])
    }
    guard method == "joint" else { throw CLIError("Unknown method \(method)") }
    let artifact = try ArtifactPhaseDesign(layout: layout, sampleCount: n, volumeTriggers: triggers)
    let q = erp.columns.count, p = artifact.counts.count
    guard p <= 16_000_000 / max(q, 1) else { throw CLIError("Joint model exceeds 16 million cross-products; increase --fir-bin-ms or shorten TR geometry") }
    // Schur complement eliminates disjoint artifact indicator columns exactly:
    // E' (I - P_G) E beta = E' (I - P_G) y.
    var cross = [[Double]](repeating: [Double](repeating: 0, count: p), count: q)
    for c in 0..<q { for entry in erp.columns[c] {
        let phase = artifact.phase[entry.sample]
        if phase >= 0 { cross[c][phase] += entry.value }
    } }
    var gram = erp.gram
    for a in 0..<q { for b in 0...a {
        var projection = 0.0
        for k in 0..<p where artifact.counts[k] > 0 { projection += cross[a][k] * cross[b][k] / artifact.counts[k] }
        gram[a][b] -= projection; gram[b][a] = gram[a][b]
    } }
    let solver = try ERPSolver(gram: gram, originalGram: erp.gram, ridge: options.ridge, allowConfounded: options.allowConfounded)
    var output: [[Float]] = []
    for y in raw {
        let mean = artifact.means(y)
        var rhs = erp.rhs(y)
        for c in 0..<q { for k in 0..<p { rhs[c] -= cross[c][k] * mean[k] } }
        let prediction = erp.predict(solver.solve(rhs), count: n)
        let template = artifact.means(zip(y, prediction).map(-))
        output.append(y.indices.map { i in artifact.phase[i] < 0 ? y[i] : y[i] - Float(template[artifact.phase[i]]) })
    }
    return ExperimentResult(channels: output, epochs: [], details: ["model": "global group/native-lag artifact template plus condition FIR",
        "erpSolver": solver.report, "firBinSamples": erp.binSamples, "firStartSample": erp.startSample, "firBinsPerCondition": erp.bins, "artifactCoefficients": artifact.counts.filter { $0 > 0 }.count,
        "modeledArtifactSamples": artifact.phase.filter { $0 >= 0 }.count,
        "warning": "Stationary artifact model over the run; local donor settings do not apply to joint regression"])
}
