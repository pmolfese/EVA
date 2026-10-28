import Foundation

/// ERP protection is separate from the artifact engine. No legacy AAS path.
func engineCorrection(_ engine: String, channels: [[Float]], triggers: [Int], rate: Double,
                      options: Options, protected: [Range<Double>]) throws -> GradientCorrectionResult {
    if engine == "allen" {
        let gaps = zip(triggers, triggers.dropFirst()).map { $1 - $0 }.sorted()
        var config = GradientAAS.Config.allenIARSlice(slicesPerVolume: options.slices / options.multiband,
            samplingRate: rate, trSeconds: Double(gaps[gaps.count / 2]) / rate)
        config.acquisitionSchedule = options.schedule
        config.anc = false
        config.protectedIntervals = protected
        config.minimumProtectedDonors = protected.isEmpty ? 1 : options.minimum
        return try GradientAAS.correct(channels: channels, volumeTriggers: triggers, config: config, samplingRate: rate)
    }
    guard engine == "farm" else { throw CLIError("Unknown artifact engine") }
    var config = options.config(intervals: protected)
    config.acquisitionSchedule = .uniform(groupsPerVolume: 1)
    config.templateScaling = options.farmScaling
    config.templateScaleSmoothingEpochs = options.farmScaleSmoothing
    config.templateScaleRange = 0.2...5
    // Baseline/iterative preserve the app's FARM preset. Exclusion adds only an
    // overlap veto and minimum donor count, retaining the engine's candidate window.
    config.donorPolicy = protected.isEmpty ? nil : GradientDonorPolicy(protectedIntervals: protected,
        maximumDistanceSeconds: Double.greatestFiniteMagnitude, minimumDonors: options.minimum, matchAcquisitionGroup: false)
    config.averagingWindowBefore = 15; config.averagingWindowAfter = 15
    config.templateScheme = .correlationRanked
    config.correlationFeature = .firstDifference
    config.correlationThreshold = 0.9
    config.minimumCorrelatedDonors = 30
    config.correlationSearchWindow = 20
    return try GradientTemplateCorrector.correct(channels: channels, volumeTriggers: triggers, config: config, samplingRate: rate)
}

func runEngineAddon(_ method: String, signal: MFFSignalData, triggers: [Int], options: Options,
                    protected: [Range<Double>]) throws -> ExperimentResult {
    let parts = method.split(separator: "-").map(String.init)
    let engine = parts[0], addon = parts.count == 1 ? "none" : parts[1]
    guard parts.count <= 2, ["none", "exclude", "iterative", "joint"].contains(addon) else { throw CLIError("Unknown engine add-on") }
    let raw = signal.data, n = raw[0].count, rate = signal.samplingRate
    var details: [String: Any] = ["engine": engine, "addon": addon, "anc": false,
        "engineSettings": engine == "allen"
            ? "Allen IAR slice-group preset, explicit acquisition offsets, fixed sections ~7.5s (>=25 groups), gate .975, initial5, no detrending, sinc factor1, ANC off"
            : "FARM whole TR, 30 donors, +/-20 TR candidates, first-difference correlation >=.9, minimum30 then temporal fallback; scaling=\(options.farmScaling.rawValue), smoothing=\(options.farmScaleSmoothing) epochs, gain bounds0.2–5; no alignment/OBS/ANC"]
    if addon == "none" || addon == "exclude" {
        let result = try engineCorrection(engine, channels: raw, triggers: triggers, rate: rate, options: options,
                                          protected: addon == "exclude" ? protected : [])
        details["warnings"] = result.diagnostics.warnings.map { String(describing: $0) }
        return ExperimentResult(channels: result.channels, epochs: result.diagnostics.epochs, details: details)
    }
    let erp = try ERPDesign(signal: signal, options: options)
    if addon == "iterative" {
        let solver = try ERPSolver(gram: erp.gram, originalGram: erp.gram, ridge: options.ridge, allowConfounded: options.allowConfounded)
        let zero = raw.map { [Float](repeating: 0, count: $0.count) }
        var estimate = zero, previousArtifact = zero, corrected = raw
        var history: [[String: Any]] = [], epochs: [GradientEpochDiagnostic] = []
        var converged = false
        for iteration in 1...options.iterations {
            let training = zip(raw, estimate).map { zip($0, $1).map(-) }
            let gradient = try engineCorrection(engine, channels: training, triggers: triggers, rate: rate, options: options, protected: [])
            let artifact = zip(training, gradient.channels).map { zip($0, $1).map(-) }
            corrected = zip(raw, artifact).map { zip($0, $1).map(-) }
            let updated = corrected.map { erp.predict(solver.solve(erp.rhs($0)), count: n) }
            let erpChange = rms(updated, estimate) / max(rms(updated, zero), 1e-12)
            let artifactChange = rms(artifact, previousArtifact) / max(rms(artifact, zero), 1e-12)
            history.append(["iteration": iteration, "relativeERPChange": erpChange, "relativeArtifactChange": artifactChange])
            estimate = updated; previousArtifact = artifact; epochs = gradient.diagnostics.epochs
            if iteration > 1, max(erpChange, artifactChange) < options.tolerance { converged = true; break }
        }
        details["iterations"] = history; details["converged"] = converged; details["erpSolver"] = solver.report
        details["warning"] = "Convergence does not establish identifiability; residual event-locked artifact can enter ERP estimate"
        return ExperimentResult(channels: corrected, epochs: epochs, details: details)
    }
    // Build the basis from event-excluded donors. A contaminated template cannot
    // be repaired by a gain-only regression. Report this explicitly as a hybrid.
    let base = try engineCorrection(engine, channels: raw, triggers: triggers, rate: rate, options: options, protected: protected)
    let artifacts = zip(raw, base.channels).map { zip($0, $1).map(-) }
    let fit = try fitLocalArtifact(artifacts, raw: raw, erp: erp, rate: rate, options: options)
    details["basisTraining"] = "event-excluded engine templates; compare against engine-exclude"
    details["jointBlockSeconds"] = options.jointBlockSeconds
    details["channelFits"] = fit.reports
    details["warnings"] = base.diagnostics.warnings.map { String(describing: $0) }
    details["warning"] = "Conditional on learned templates; rank does not prove artifact/ERP separation. Gain fitting cannot correct missing artifact shapes. No independent training set."
    return ExperimentResult(channels: fit.channels, epochs: base.diagnostics.epochs, details: details)
}

/// Linear interpolation of artifact gains gives continuous local modulation.
/// Solve [G E] on raw - A, with ridge centered on unit artifact gain and zero ERP.
/// Only A + G*delta is removed; the fitted ERP is never subtracted.
func fitLocalArtifact(_ artifacts: [[Float]], raw: [[Float]], erp: ERPDesign, rate: Double,
                      options: Options) throws -> (channels: [[Float]], reports: [[String: Any]]) {
    let step = max(1, Int((options.jointBlockSeconds * rate).rounded()))
    var output: [[Float]] = [], reports: [[String: Any]] = []
    for channel in raw.indices {
        let a = artifacts[channel]
        guard let first = a.firstIndex(where: { abs($0) > 1e-12 }), let last = a.lastIndex(where: { abs($0) > 1e-12 }), last > first else {
            throw CLIError("Joint channel \(channel + 1) has no artifact basis; check donor coverage")
        }
        let intervals = max(1, Int(ceil(Double(last - first) / Double(step))))
        let width = Double(last - first) / Double(intervals), p = intervals + 1, q = erp.columns.count, size = p + q
        guard size <= 1024 else { throw CLIError("Too many joint coefficients; increase --joint-block-seconds") }
        func weights(_ i: Int) -> (Int, Double, Double) {
            let x = min(Double(intervals), max(0, Double(i - first) / width))
            let k = min(intervals - 1, Int(x)), fraction = x - Double(k)
            return (k, 1 - fraction, fraction)
        }
        var gram = [[Double]](repeating: [Double](repeating: 0, count: size), count: size)
        var rhs = [Double](repeating: 0, count: size)
        let residual = zip(raw[channel], a).map(-)
        for i in first...last {
            let (k, w0, w1) = weights(i), g0 = Double(a[i]) * w0, g1 = Double(a[i]) * w1
            gram[k][k] += g0 * g0; gram[k+1][k+1] += g1 * g1
            gram[k][k+1] += g0 * g1; gram[k+1][k] += g0 * g1
            rhs[k] += g0 * Double(residual[i]); rhs[k+1] += g1 * Double(residual[i])
        }
        let erpRHS = erp.rhs(residual)
        for c in 0..<q {
            rhs[p+c] = erpRHS[c]
            for d in 0..<q { gram[p+c][p+d] = erp.gram[c][d] }
            for entry in erp.columns[c] where entry.sample >= first && entry.sample <= last {
                let (k, w0, w1) = weights(entry.sample), v = Double(a[entry.sample]) * entry.value
                gram[k][p+c] += v * w0; gram[p+c][k] += v * w0
                gram[k+1][p+c] += v * w1; gram[p+c][k+1] += v * w1
            }
        }
        let solver = try ERPSolver(gram: gram, originalGram: gram, ridge: options.ridge, allowConfounded: options.allowConfounded)
        let beta = solver.solve(rhs)
        var corrected = raw[channel]
        for i in first...last {
            let (k, w0, w1) = weights(i)
            corrected[i] -= Float(Double(a[i]) * (1 + w0 * beta[k] + w1 * beta[k+1]))
        }
        guard corrected.allSatisfy(\.isFinite) else { throw CLIError("Nonfinite joint fit") }
        let gains = beta.prefix(p).map { 1 + $0 }
        reports.append(["channel": channel+1, "solver": solver.report, "gainKnots": gains,
                        "minimumGain": gains.min()!, "maximumGain": gains.max()!, "artifactColumns": p])
        output.append(corrected)
    }
    return (output, reports)
}
