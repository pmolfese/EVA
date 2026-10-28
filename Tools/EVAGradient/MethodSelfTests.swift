import Foundation

func methodSelfTests(signal: MFFSignalData, triggers: [Int], directory: URL) throws {
    func check(_ value: Bool, _ message: String) throws { if !value { throw CLIError("Method self-test failed: \(message)") } }
    // Fractional group spacing must cover every scan sample, including longer
    // rounded intervals, and must not fill missing-volume gaps.
    let scanVolumes = [0, 2150, 4300]
    let fractional = try GradientEpochLayout.build(volumeTriggers: scanVolumes, sampleCount: 6450,
        acquisitionSchedule: .uniform(groupsPerVolume: 21), samplingRate: 1000, upsampleFactor: 1, relativeTriggerPosition: 0)
    let phase = try ArtifactPhaseDesign(layout: fractional, sampleCount: 6450, volumeTriggers: scanVolumes)
    try check(phase.phase.allSatisfy { $0 >= 0 }, "fractional group intervals have no one-sample holes")
    let gapVolumes = [0, 2150, 4300, 8600, 10750]
    let gapLayout = try GradientEpochLayout.build(volumeTriggers: gapVolumes, sampleCount: 12900,
        acquisitionSchedule: .uniform(groupsPerVolume: 21), samplingRate: 1000, upsampleFactor: 1, relativeTriggerPosition: 0)
    let gapPhase = try ArtifactPhaseDesign(layout: gapLayout, sampleCount: 12900, volumeTriggers: gapVolumes)
    try check(gapPhase.phase[6450..<8600].allSatisfy { $0 == -1 }, "missing volume stays uncovered")
    var options = try Options.parse(["compare", signal.signalURL.path, "--events", "a,b", "--fir-bin-ms", "20", "--ridge", "0.00000001"])
    let n = signal.data[0].count, rate = signal.samplingRate
    let layout = try GradientEpochLayout.build(volumeTriggers: triggers, sampleCount: n,
        acquisitionSchedule: .uniform(groupsPerVolume: 1), samplingRate: rate, upsampleFactor: 1, relativeTriggerPosition: 0)
    // Two conditions with overlapping response support, diverse scanner phases,
    // and exactly known FIR truth, independently of the correction implementation.
    let events = (0..<25).flatMap { index -> [MFFEvent] in
        let onset = 1.0 + Double(index) * 1.43
        return [("a", onset), ("b", onset + 0.37)].map { code, time in
            MFFEvent(id: "\(code)-\(index)", code: code, beginTimeSeconds: time, rawBeginTime: "", sourceFile: "test")
        }
    }
    let shell = signal.replacingEvents(signal.events.filter { $0.code == "TREV" } + events)
    let design = try ERPDesign(signal: shell, options: options)
    let beta = design.columns.indices.map { i -> Double in
        let lag = i % design.bins
        return (i < design.bins ? 4 : -2) * exp(-0.5 * pow((Double(lag) - 15) / 4, 2))
    }
    let truth = [design.predict(beta, count: n)]
    let artifact = (0..<n).map { Float(50 * sin(2 * Double.pi * Double($0 % 100) / 100)) }
    let raw = [zip(artifact, truth[0]).map(+)]
    let mixed = shell.replacingSamples(raw)
    let joint = try runMethod("joint", signal: mixed, triggers: triggers, layout: layout, options: options, protected: [])
    try check(rms(joint.channels, truth) < 0.0001, "joint recovery of overlapping condition FIRs: \(rms(joint.channels, truth))")
    options.iterations = 30; options.tolerance = 0.00001
    let baseline = try runMethod("baseline", signal: mixed, triggers: triggers, layout: layout, options: options, protected: [])
    let iterative = try runMethod("iterative", signal: mixed, triggers: triggers, layout: layout, options: options, protected: [])
    try check(rms(iterative.channels, truth) < rms(baseline.channels, truth) * 0.2, "iteration improves truth recovery")
    print("Truth RMSE: baseline=\(rms(baseline.channels, truth)), iterative=\(rms(iterative.channels, truth)), joint=\(rms(joint.channels, truth))")
    try check((iterative.details["iterations"] as? [[String: Any]])?.count ?? 0 > 1, "iteration history")

    // Independent local-gain truth: simultaneous fit must retain the entire ERP.
    options.jointBlockSeconds = 10
    let drifting = artifact.indices.map { artifact[$0] * Float(1 + 0.1 * Double($0) / Double(n)) }
    let localFit = try fitLocalArtifact([artifact], raw: [zip(drifting, truth[0]).map(+)], erp: design, rate: rate, options: options)
    try check(rms(localFit.channels, truth) < 0.0001, "local joint gain and ERP recovered together")
    var engineOptions = options; engineOptions.events = ["stim"]; engineOptions.iterations = 20
    let protection = [10.1..<10.9]
    for engine in ["allen", "farm"] {
        let excluded = try engineCorrection(engine, channels: signal.data, triggers: triggers, rate: rate,
                                            options: engineOptions, protected: protection)
        try check(excluded.diagnostics.epochs.allSatisfy { !$0.donorIndices.contains(10) }, "\(engine) excludes protected donors")
        try check(excluded.diagnostics.epochs.contains { $0.epoch == 10 && $0.corrected }, "\(engine) still corrects protected target")
        let none = try engineCorrection(engine, channels: signal.data, triggers: triggers, rate: rate,
                                       options: engineOptions, protected: [0..<50])
        try check(rms(none.channels, signal.data) == 0, "\(engine) no contaminated fallback")
        for suffix in ["", "-exclude", "-iterative", "-joint"] {
            let result = try runMethod(engine + suffix, signal: signal, triggers: triggers, layout: layout,
                                       options: engineOptions, protected: protection)
            try check(result.channels.count == 1 && result.channels[0].count == n && result.channels[0].allSatisfy(\.isFinite), "\(engine + suffix) valid output")
        }
    }
    // Exercise both real GUI scaling modes on changing-amplitude artifact truth.
    let changing = artifact.indices.map { artifact[$0] * Float(1 + 0.08 * sin(Double($0) / rate * 2 * .pi / 17)) }
    let scalingInput = signal.replacingSamples([changing])
    var scalingOptions = engineOptions
    let unscaled = try engineCorrection("farm", channels: scalingInput.data, triggers: triggers, rate: rate, options: scalingOptions, protected: [])
    scalingOptions.farmScaling = .leastSquares
    let scaled = try engineCorrection("farm", channels: scalingInput.data, triggers: triggers, rate: rate, options: scalingOptions, protected: [])
    let zeros = [[Float](repeating: 0, count: n)]
    try check(rms(scaled.channels, zeros) < rms(unscaled.channels, zeros), "FARM per-epoch scaling improves changing-amplitude artifact fixture")
    scalingOptions.farmScaling = .driftTracking
    let smoothed = try engineCorrection("farm", channels: scalingInput.data, triggers: triggers, rate: rate, options: scalingOptions, protected: [])
    try check(smoothed.channels[0].allSatisfy(\.isFinite), "GUI smoothed scaling produces finite output")
    let parsedScaling = try Options.parse(["compare", signal.signalURL.path, "--events", "stim", "--farm-scaling", "leastSquares"])
    try check(parsedScaling.farmScaling == .leastSquares, "CLI resolves GUI scaling option")
    var rejectedLegacy = false
    do { _ = try Options.parse(["compare", signal.signalURL.path, "--events", "stim", "--methods", "aas"]) }
    catch { rejectedLegacy = true }
    try check(rejectedLegacy, "legacy AAS cannot be selected")
    print("PASS: engine add-ons, protected donor veto and shortage behavior, independent local joint recovery, legacy disabled")

    options.events = ["stim"]; options.iterations = 5; options.firBinMS = 10
    let lockedEvents = triggers.enumerated().map { i, trigger in
        MFFEvent(id: "s-\(i)", code: "stim", beginTimeSeconds: Double(trigger) / rate + 0.1, rawBeginTime: "", sourceFile: "test")
    }
    let locked = signal.replacingEvents(signal.events.filter { $0.code == "TREV" } + lockedEvents)
    var rejected = false
    do { _ = try runMethod("joint", signal: locked, triggers: triggers, layout: layout, options: options, protected: []) }
    catch { rejected = error.localizedDescription.contains("Nonidentifiable") }
    try check(rejected, "exact phase locking must be flagged as nonidentifiable")
    options.allowConfounded = true
    let allowed = try runMethod("joint", signal: locked, triggers: triggers, layout: layout, options: options, protected: [])
    let solver = allowed.details["erpSolver"] as? [String: Any]
    try check(solver?["fullRank"] as? Bool == false, "ridge cannot hide confounding")
    options.allowConfounded = false
    options.jitterMS = 450; options.minimumISI = 0.1; options.seed = 71
    let jitterA = try jitterEvents(lockedEvents, options: options, duration: Double(n) / rate, rate: rate)
    let jitterB = try jitterEvents(lockedEvents, options: options, duration: Double(n) / rate, rate: rate)
    try check(jitterA.map(\.beginTimeSeconds) == jitterB.map(\.beginTimeSeconds), "seed determinism")
    try check(zip(jitterA, lockedEvents).allSatisfy { abs($0.beginTimeSeconds - $1.beginTimeSeconds) <= 0.455 }, "jitter bounds")
    try check(zip(jitterA, jitterA.dropFirst()).allSatisfy { $1.beginTimeSeconds - $0.beginTimeSeconds >= 0.1 }, "minimum ISI")
    let jittered = locked.replacingEvents(locked.events.filter { $0.code == "TREV" } + jitterA)
    let identifiable = try runMethod("joint", signal: jittered, triggers: triggers, layout: layout, options: options, protected: [])
    try check((identifiable.details["erpSolver"] as? [String: Any])?["fullRank"] as? Bool == true, "jitter restores rank for controlled fixture")

    let output = directory.appendingPathComponent("jitter-test")
    try runJitterExperiment(signal: locked, triggers: triggers, layout: layout, options: options, destination: output)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("jitter-report.json"))) as! [String: Any]
    let cases = json["cases"] as! [[String: Any]]
    func baselineError(_ caseIndex: Int) -> Double {
        let metrics = cases[caseIndex]["truthMetrics"] as! [[String: Any]]
        return metrics.first { $0["method"] as? String == "baseline" }!["truthRMSE"] as! Double
    }
    try check(baselineError(1) < baselineError(0), "jitter improves baseline recovery on locked fixture")
    let originalResults = cases[0]["comparisonResults"] as! [[String: Any]]
    try check(originalResults.first { $0["method"] as? String == "joint" }?["status"] as? String == "failed", "failed joint fit reported while other methods complete")
    // Selecting only joint must still reach the jittered case after original fails.
    options.methods = ["joint"]
    try runJitterExperiment(signal: locked, triggers: triggers, layout: layout, options: options,
        destination: directory.appendingPathComponent("joint-only-jitter"))
    print("PASS: joint overlapping-condition truth, iterative improvement, rank rejection/opt-in, seeded jitter bounds/ISI, paired jitter experiment and truth metrics")
}
