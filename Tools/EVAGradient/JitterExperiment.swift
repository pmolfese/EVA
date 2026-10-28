import Foundation

struct JitterRandom {
    var state: UInt64
    mutating func uniform() -> Double {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        z ^= z >> 31
        return Double(z >> 11) / 9007199254740992.0
    }
}

func jitterEvents(_ events: [MFFEvent], options: Options, duration: Double, rate: Double) throws -> [MFFEvent] {
    var rng = JitterRandom(state: options.seed)
    let ordered = events.sorted { $0.beginTimeSeconds == $1.beginTimeSeconds ? $0.id < $1.id : $0.beginTimeSeconds < $1.beginTimeSeconds }
    let earliest = max(0, -options.protect.lowerBound)
    let latest = duration - max(0.8, options.protect.upperBound)
    guard earliest < latest else { throw CLIError("Recording too short for proposed ERP windows") }
    // Retry complete schedules rather than clip offsets at edges (which piles up
    // phases). Sampling is conditional on bounds, trial order and minimum ISI.
    for _ in 0..<500 {
        var result: [MFFEvent] = []
        var failed = false
        for e in ordered {
            var accepted: Double?
            for _ in 0..<500 {
                let candidate = ((e.beginTimeSeconds + (2 * rng.uniform() - 1) * options.jitterMS / 1000) * rate).rounded() / rate
                guard candidate >= earliest, candidate <= latest,
                      abs(candidate - e.beginTimeSeconds) <= options.jitterMS / 1000 + 0.5 / rate else { continue }
                if let previous = result.last, candidate - previous.beginTimeSeconds < options.minimumISI { continue }
                accepted = candidate; break
            }
            guard let time = accepted else { failed = true; break }
            result.append(MFFEvent(id: e.id, code: e.code, label: e.label, eventDescription: e.eventDescription,
                cell: e.cell, beginTimeSeconds: time, rawBeginTime: "", sourceFile: "eva-gradient-jitter",
                durationSeconds: e.durationSeconds, timeAnchor: e.timeAnchor))
        }
        if !failed { return result }
    }
    throw CLIError("Cannot generate jitter schedule within bounds/minimum ISI; increase --jitter-ms or reduce --minimum-isi")
}

func phaseSummary(events: [MFFEvent], triggers: [Int], layout: GradientEpochLayout, rate: Double) -> [String: Any] {
    var result: [String: Any] = [:]
    let intervals = zip(triggers, triggers.dropFirst()).map { $1 - $0 }.sorted()
    let median = intervals[intervals.count / 2]
    for code in Set(events.map { $0.code.lowercased() }).sorted() {
        var volume = [Int](repeating: 0, count: 20), group = volume
        var omitted = 0
        for e in events where e.code.lowercased() == code {
            let sample = e.beginTimeSeconds * rate
            guard let v = triggers.lastIndex(where: { Double($0) <= sample }), v + 1 < triggers.count,
                  Double(triggers[v + 1] - triggers[v]) <= 1.5 * Double(median),
                  let g = layout.triggers.lastIndex(where: { Double($0) <= sample }) else { omitted += 1; continue }
            let vp = (sample - Double(triggers[v])) / Double(triggers[v + 1] - triggers[v])
            let groupEnd = g + 1 < layout.count ? layout.triggers[g + 1] : layout.triggers[g] + layout.period
            guard groupEnd > layout.triggers[g] else { omitted += 1; continue }
            let gp = (sample - Double(layout.triggers[g])) / Double(groupEnd - layout.triggers[g])
            volume[min(19, max(0, Int(vp * 20)))] += 1
            group[min(19, max(0, Int(gp * 20)))] += 1
        }
        result[code] = ["volumePhaseHistogram": volume, "groupPhaseHistogram": group,
                        "volumeOccupiedBins": volume.filter { $0 > 0 }.count,
                        "groupOccupiedBins": group.filter { $0 > 0 }.count, "omittedEvents": omitted]
    }
    return result
}

func runJitterExperiment(signal: MFFSignalData, triggers: [Int], layout: GradientEpochLayout, options: Options, destination: URL) throws {
    let rate = signal.samplingRate, n = signal.data[0].count
    let selected = signal.events.filter { options.events.contains($0.code.lowercased()) }
    guard selected.allSatisfy({ $0.beginTimeSeconds >= max(0, -options.protect.lowerBound) && $0.beginTimeSeconds + max(0.8, options.protect.upperBound) <= Double(n) / rate }) else {
        throw CLIError("Jitter experiment requires complete ERP windows for all selected original events")
    }
    let proposed = try jitterEvents(selected, options: options, duration: Double(n) / rate, rate: rate)
    let scanner = signal.events.filter { $0.code.lowercased() == options.trCode.lowercased() }
    let design = try ArtifactPhaseDesign(layout: layout, sampleCount: n, volumeTriggers: triggers)
    let artifact = signal.data.indices.map { channel -> [Float] in
        design.phase.map { phase in
            guard phase >= 0 else { return 0 }
            let lag = Double(phase % design.width) / Double(design.width)
            let group = phase / design.width
            let shape = sin(2 * Double.pi * lag) + 0.35 * sin(14 * Double.pi * lag + Double(group) * 0.3)
            return Float(options.artifactAmplitude * (1 + Double(channel) / Double(max(1, signal.numberOfChannels))) * shape)
        }
    }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    var rows = "id,event,original_seconds,jittered_seconds,offset_seconds\n"
    // Event identity need not be unique in imported recordings; stable sorted order
    // is the same one used by the scheduler.
    let sortedOriginal = selected.sorted { $0.beginTimeSeconds == $1.beginTimeSeconds ? $0.id < $1.id : $0.beginTimeSeconds < $1.beginTimeSeconds }
    for (a, b) in zip(sortedOriginal, proposed) {
        rows += "\(csv(a.id)),\(csv(a.code)),\(a.beginTimeSeconds),\(b.beginTimeSeconds),\(b.beginTimeSeconds - a.beginTimeSeconds)\n"
    }
    try rows.write(to: destination.appendingPathComponent("proposed-events.csv"), atomically: true, encoding: .utf8)
    var cases: [[String: Any]] = []
    for (name, events) in [("original", selected), ("jittered", proposed)] {
        let shell = signal.replacingEvents((scanner + events).sorted { $0.beginTimeSeconds < $1.beginTimeSeconds })
        let truth = injection(signal: shell, codes: options.events, amplitude: options.amplitude)
        let raw = zip(artifact, truth).map { a, b in zip(a, b).map(+) }
        let inputURL = destination.appendingPathComponent("\(name)-synthetic.mff")
        try MFFWriter.write(signal: shell.replacingSamples(raw, signalTypeSuffix: "SYNTHETIC \(name)"), pnsSignal: nil, segments: [], kind: .continuous, to: inputURL)
        try MFFWriter.write(signal: shell.replacingSamples(truth, signalTypeSuffix: "SYNTHETIC ERP TRUTH"), pnsSignal: nil, segments: [], kind: .continuous, to: destination.appendingPathComponent("\(name)-truth.mff"))
        var comparison = options
        comparison.command = "compare"; comparison.input = inputURL
        comparison.output = destination.appendingPathComponent("\(name)-comparison").path
        let resultURL = URL(fileURLWithPath: comparison.output).appendingPathComponent("report.json")
        do { try run(comparison) }
        catch {
            // A nonidentifiable original design must not prevent evaluating the
            // jittered design, even when joint is the sole requested method.
            guard FileManager.default.fileExists(atPath: resultURL.path) else { throw error }
        }
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as! [String: Any]
        var metrics: [[String: Any]] = []
        let successful = (saved["results"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "ok" }
        for method in options.methods where successful.contains(where: { $0["method"] as? String == method }) {
            let correctedURL = URL(fileURLWithPath: comparison.output).appendingPathComponent("\(method).mff")
            guard FileManager.default.fileExists(atPath: correctedURL.path) else { continue }
            let corrected = try MFFReader().loadSignal(from: correctedURL)
            metrics.append(["method": method, "truthRMSE": rms(corrected.data, truth), "uncorrectedTruthRMSE": rms(raw, truth)])
        }
        cases.append(["schedule": name, "phases": phaseSummary(events: events, triggers: triggers, layout: layout, rate: rate),
                      "truthMetrics": metrics, "comparisonResults": saved["results"] ?? []])
    }
    try writeJSON(["experiment": "synthetic paired timing-jitter experiment; no real samples retimed",
        "inputTimingSource": options.input.path, "seed": String(options.seed), "maximumJitterMS": options.jitterMS,
        "minimumISISeconds": options.minimumISI, "artifactAmplitudeNativeUnits": options.artifactAmplitude,
        "erpAmplitudeNativeUnits": options.amplitude, "cases": cases,
        "limitations": ["Stationary synthetic gradient and Gaussian ERP only; no ongoing EEG, motion or physiological artifacts", "Same gradient samples in both schedules; event codes/counts preserved", "PNS and unrelated real event markers omitted", "Jitter is a proposal, not a guarantee of phase balance or acquisition feasibility", "Joint regression uses a model deliberately matched to this synthetic artifact; validate with measured artifacts too"]] as [String: Any],
        to: destination.appendingPathComponent("jitter-report.json"))
    print("Wrote jitter experiment \(destination.path)")
    guard cases.contains(where: { !(($0["truthMetrics"] as? [[String: Any]]) ?? []).isEmpty }) else {
        throw CLIError("All methods failed on both schedules; see jitter-report.json")
    }
}
