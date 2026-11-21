// Experimental gradient/ERP comparison harness. Uses EVA's shared correction engine.
import Foundation

struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
let help = """
eva-gradient inspect|compare|jitter input.mff [options]
eva-gradient self-test
  --methods baseline,exclude,iterative,joint  Compare methods (default all).
  --methods allen,allen-exclude,allen-iterative,allen-joint,farm,farm-exclude,farm-iterative,farm-joint
  --joint-block-seconds 30  Linear gain knots for engine-based joint fits.
  --farm-scaling unscaled   GUI scaling: unscaled|driftTracking|leastSquares.
  --farm-scale-smoothing 15 Epochs for driftTracking median; gain bounds0.2–5.
  Legacy aas is disabled. Allen uses slice groups, ANC off; FARM uses whole TR.
  --iterations 5            Maximum iterative updates; --tolerance 0.001.
  --fir-bin-ms 10           ERP FIR bin width; support uses --protect-ms.
  --ridge 0.000001          Normalized ERP penalty (strictly positive).
  --allow-confounded false  Explicit opt-in to rank-deficient regularized fits.
  --jitter-ms 500           Jitter experiment: maximum absolute onset change.
  --seed 1                 Reproducible jitter seed (UInt64).
  --minimum-isi 0.1         Jitter experiment: minimum seconds between stimuli.
  --artifact-amplitude 1000 Synthetic gradient amplitude in native units.
  --tr-code TREV             Volume trigger code (case-insensitive).
  --slices N --multiband N    Anatomical slices and MB factor (defaults 1,1).
  --group-offsets 0,0.05,...  Explicit acquisition-group offsets in seconds.
  --events std,targ          Required event codes to protect and analyze.
  --protect-ms 0:800         Half-open event protection window.
  --donors 30                Requested donors; --min-donors 4.
  --max-donor-distance 60    Maximum distance in seconds.
  --inject-amplitude 5       Gaussian ERP amplitude in native signal units.
  --report timing.json      Inspect output (must not exist).
  --output-dir experiment   Compare output directory (must not exist).
AAS/iteration use local same-group templates. Joint fits a stationary artifact
model and condition FIRs. CPU, alignment/resampling/OBS/ANC off throughout.
Jitter creates paired synthetic schedules/recordings; real EEG is never retimed.
"""

struct Options {
    var methods = ["baseline", "exclude", "iterative", "joint"]
    var farmScaling = GradientTemplateScaling.unscaled
    var farmScaleSmoothing = 15
    var jointBlockSeconds = 30.0
    var iterations = 5
    var tolerance = 0.001
    var firBinMS = 10.0
    var ridge = 0.000001
    var allowConfounded = false
    var jitterMS = 500.0
    var seed: UInt64 = 1
    var minimumISI = 0.1
    var artifactAmplitude = 1000.0
    var command: String
    var input: URL
    var trCode = "TREV"
    var slices = 1
    var multiband = 1
    var offsets: [Double]?
    var events: [String] = []
    var protect = 0.0..<0.8
    var donors = 30
    var minimum = 4
    var distance = 60.0
    var amplitude = 5.0
    var report = "timing.json"
    var output = "gradient-experiment"

    static func parse(_ args: [String]) throws -> Options {
        guard args.count >= 2, ["inspect", "compare", "jitter"].contains(args[0]) else { throw CLIError(help) }
        var o = Options(command: args[0], input: URL(fileURLWithPath: args[1]).standardizedFileURL)
        var i = 2
        func number(_ s: String) throws -> Double {
            guard let v = Double(s), v.isFinite else { throw CLIError("Invalid finite number: \(s)") }
            return v
        }
        func integer(_ s: String) throws -> Int {
            guard let v = Int(s), v > 0 else { throw CLIError("Expected positive integer: \(s)") }
            return v
        }
        while i < args.count {
            let flag = args[i]
            guard i + 1 < args.count else { throw CLIError("Missing value for \(flag)") }
            let value = args[i + 1]; i += 2
            switch flag {
            case "--methods": o.methods = value.split(separator: ",").map(String.init)
            case "--farm-scaling":
                guard let scaling = GradientTemplateScaling(rawValue: value) else { throw CLIError("Expected --farm-scaling unscaled|driftTracking|leastSquares") }
                o.farmScaling = scaling
            case "--farm-scale-smoothing": o.farmScaleSmoothing = try integer(value)
            case "--joint-block-seconds": o.jointBlockSeconds = try number(value)
            case "--iterations": o.iterations = try integer(value)
            case "--tolerance": o.tolerance = try number(value)
            case "--fir-bin-ms": o.firBinMS = try number(value)
            case "--ridge": o.ridge = try number(value)
            case "--allow-confounded":
                guard ["true", "false"].contains(value) else { throw CLIError("Expected true or false") }
                o.allowConfounded = value == "true"
            case "--jitter-ms": o.jitterMS = try number(value)
            case "--minimum-isi": o.minimumISI = try number(value)
            case "--artifact-amplitude": o.artifactAmplitude = try number(value)
            case "--seed":
                guard let seed = UInt64(value) else { throw CLIError("Seed must be an unsigned 64-bit integer") }
                o.seed = seed
            case "--tr-code": o.trCode = value
            case "--slices": o.slices = try integer(value)
            case "--multiband": o.multiband = try integer(value)
            case "--group-offsets": o.offsets = try value.split(separator: ",").map { try number(String($0)) }
            case "--events": o.events = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            case "--protect-ms":
                let parts = value.split(separator: ":")
                guard parts.count == 2 else { throw CLIError("Expected --protect-ms start:end") }
                let a = try number(String(parts[0])) / 1000, b = try number(String(parts[1])) / 1000
                guard a < b else { throw CLIError("Protection end must exceed start") }
                o.protect = a..<b
            case "--donors": o.donors = try integer(value)
            case "--min-donors": o.minimum = try integer(value)
            case "--max-donor-distance": o.distance = try number(value)
            case "--inject-amplitude": o.amplitude = try number(value)
            case "--report": o.report = value
            case "--output-dir": o.output = value
            default: throw CLIError("Unknown option: \(flag)")
            }
        }
        guard !o.methods.isEmpty, Set(o.methods).count == o.methods.count,
              o.methods.allSatisfy({ ["baseline", "exclude", "iterative", "joint", "allen", "allen-exclude", "allen-iterative", "allen-joint", "farm", "farm-exclude", "farm-iterative", "farm-joint"].contains($0) }) else {
            throw CLIError("Unknown/duplicate method. Legacy aas is disabled; use allen. See --help for engine add-ons.")
        }
        guard o.jointBlockSeconds >= 1, o.jointBlockSeconds <= 3600, o.iterations <= 100, o.tolerance > 0, o.firBinMS > 0, o.firBinMS <= 60000, o.ridge > 0,
              abs(o.protect.lowerBound) <= 3600, abs(o.protect.upperBound) <= 3600,
              o.jitterMS > 0, o.minimumISI >= 0, o.artifactAmplitude > 0 else { throw CLIError("Invalid estimation or jitter settings") }
        guard o.input.pathExtension.lowercased() == "mff" else { throw CLIError("Supports continuous MFF input") }
        guard !o.events.isEmpty, !o.events.contains(""), !o.events.contains(o.trCode.lowercased()) else { throw CLIError("Specify stimulus --events distinct from the TR code") }
        o.events = Array(Set(o.events)).sorted()
        guard o.slices % o.multiband == 0 else { throw CLIError("Slice count must be divisible by multiband factor") }
        guard o.distance > 0, o.minimum <= o.donors, o.amplitude > 0 else { throw CLIError("Require positive distance/amplitude and min-donors <= donors") }
        if let offsets = o.offsets {
            guard offsets.count == o.slices / o.multiband, offsets.first.map({ $0 >= 0 }) == true,
                  zip(offsets, offsets.dropFirst()).allSatisfy({ $0 < $1 }) else {
                throw CLIError("Offsets must be increasing, nonnegative, and match slices / multiband")
            }
        }
        return o
    }
    var schedule: GradientAcquisitionSchedule {
        offsets.map { .offsetsSeconds($0) } ?? .uniform(groupsPerVolume: slices / multiband)
    }
    func config(intervals: [Range<Double>]) -> GradientCorrectionConfig {
        var c = GradientCorrectionConfig()
        c.acquisitionSchedule = schedule
        c.alignmentEnabled = false
        c.templateScaling = .unscaled
        c.averagingWindowBefore = donors / 2
        c.averagingWindowAfter = donors - donors / 2
        c.donorPolicy = GradientDonorPolicy(protectedIntervals: intervals,
            maximumDistanceSeconds: distance, minimumDonors: minimum, matchAcquisitionGroup: true)
        return c
    }
}

func merged(_ ranges: [Range<Double>]) -> [Range<Double>] {
    var result: [Range<Double>] = []
    for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
        if let last = result.last, r.lowerBound <= last.upperBound {
            result[result.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
        } else { result.append(r) }
    }
    return result
}
func writeJSON(_ object: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .withoutOverwriting)
}
func csv(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
func rms(_ a: [[Float]], _ b: [[Float]]) -> Double {
    var sum = 0.0, n = 0.0
    for c in a.indices { for i in a[c].indices { let d = Double(a[c][i] - b[c][i]); sum += d * d; n += 1 } }
    return sqrt(sum / max(n, 1))
}
func erpCSV(signal: MFFSignalData, output: [[Float]], codes: [String]) -> String {
    let rate = signal.samplingRate, count = signal.data[0].count
    let before = Int((0.2 * rate).rounded()), after = Int((0.8 * rate).rounded())
    var rows = ["event,channel,lag_seconds,n,raw,corrected,removed"]
    for code in codes {
        let onsets = signal.events.filter { $0.code.lowercased() == code }.map { Int(($0.beginTimeSeconds * rate).rounded()) }
            .filter { $0 - before >= 0 && $0 + after < count }
        guard !onsets.isEmpty else { continue }
        for c in output.indices {
            let name = signal.channelNames.flatMap { $0.indices.contains(c) ? $0[c] : nil } ?? "channel-\(c + 1)"
            for lag in -before...after {
                var raw = 0.0, clean = 0.0
                for t in onsets { raw += Double(signal.data[c][t + lag]); clean += Double(output[c][t + lag]) }
                raw /= Double(onsets.count); clean /= Double(onsets.count)
                rows.append("\(csv(code)),\(csv(name)),\(Double(lag) / rate),\(onsets.count),\(raw),\(clean),\(raw - clean)")
            }
        }
    }
    return rows.joined(separator: "\n") + "\n"
}
func injection(signal: MFFSignalData, codes: [String], amplitude: Double) -> [[Float]] {
    let rate = signal.samplingRate, count = signal.data[0].count
    var wave = [Float](repeating: 0, count: count)
    for e in signal.events where codes.contains(e.code.lowercased()) {
        let start = max(0, Int(ceil(e.beginTimeSeconds * rate)))
        let end = min(count, Int(ceil((e.beginTimeSeconds + 0.8) * rate)))
        guard start < end else { continue }
        for i in start..<end {
            let t = Double(i) / rate - e.beginTimeSeconds
            wave[i] += Float(amplitude * exp(-0.5 * pow((t - 0.3) / 0.06, 2)))
        }
    }
    return signal.data.indices.map { c in wave.map { $0 * Float(1 + Double(c) / Double(max(1, signal.numberOfChannels - 1))) } }
}

func run(_ o: Options) throws {
    let destination = URL(fileURLWithPath: o.command == "inspect" ? o.report : o.output).standardizedFileURL
    guard !FileManager.default.fileExists(atPath: destination.path) else { throw CLIError("Output already exists: \(destination.path)") }
    let reader = MFFReader(), signal = try reader.loadSignal(from: o.input)
    guard !signal.isSegmented, !signal.isAveraged, !signal.data.isEmpty, !signal.data[0].isEmpty,
          signal.samplingRate.isFinite, signal.samplingRate > 0 else { throw CLIError("Expected nonempty continuous signal") }
    let rate = signal.samplingRate, count = signal.data[0].count
    let counts = Dictionary(grouping: signal.events, by: { $0.code.lowercased() }).mapValues { $0.count }
    for code in o.events where counts[code] == nil { throw CLIError("Event code not found: \(code). Available: \(counts.keys.sorted())") }
    let tr = Array(Set(signal.events.filter { $0.code.lowercased() == o.trCode.lowercased() }
        .map { Int(($0.beginTimeSeconds * rate).rounded()) }.filter { $0 >= 0 && $0 < count })).sorted()
    guard tr.count >= 2 else { throw CLIError("Need at least two usable \(o.trCode) markers") }
    let intervals = zip(tr, tr.dropFirst()).map { Double($1 - $0) / rate }
    let medianTR = intervals.sorted()[intervals.count / 2]
    if let offsets = o.offsets, let last = offsets.last, last >= intervals.min()! { throw CLIError("Group offsets must fit inside every observed TR") }
    let events = signal.events.filter { o.events.contains($0.code.lowercased()) && $0.beginTimeSeconds >= 0 && $0.beginTimeSeconds < Double(count) / rate }
    for code in o.events where !events.contains(where: { $0.code.lowercased() == code }) { throw CLIError("No in-recording events for \(code)") }
    let protected = merged(events.map { ($0.beginTimeSeconds + o.protect.lowerBound)..<($0.beginTimeSeconds + o.protect.upperBound) })
    var layout = try GradientEpochLayout.build(volumeTriggers: tr, sampleCount: count, acquisitionSchedule: o.schedule, samplingRate: rate, upsampleFactor: 1, relativeTriggerPosition: 0)
    if layout.lacksOnlyClosingSample { layout = layout.extended(bySamples: 1, upsampleFactor: 1) }
    if o.command == "jitter" {
        try runJitterExperiment(signal: signal, triggers: tr, layout: layout, options: o, destination: destination)
        return
    }
    let policy = o.config(intervals: protected).donorPolicy!
    let eligible = (0..<layout.count).map { e -> Bool in
        guard let start = layout.windowStart(of: e) else { return false }
        return policy.permitsWindow(start: Double(start) / rate, end: Double(start + layout.length) / rate)
    }
    var coverage: [[String: Any]] = []
    for target in 0..<layout.count {
        let candidates = GradientDonorSelection.nearestTemporalDonors(target: target, epochCount: layout.count,
            desired: o.donors, allowsSelfDonation: false, isEligible: { c in
                eligible[c] && layout.slicePosition[c] == layout.slicePosition[target]
                && Double(abs(layout.triggers[c] - layout.triggers[target])) / rate <= o.distance
            })
        coverage.append(["epoch": target, "group": layout.slicePosition[target], "donorEligible": eligible[target],
            "selectedCleanDonors": candidates.count, "targetInBounds": layout.windowStart(of: target) != nil,
            "supported": candidates.count >= o.minimum && layout.windowStart(of: target) != nil])
    }
    var phases: [[String: Any]] = []
    for event in events {
        let t = event.beginTimeSeconds * rate
        guard let volume = tr.lastIndex(where: { Double($0) <= t }), volume + 1 < tr.count,
              Double(tr[volume + 1] - tr[volume]) / rate <= 1.5 * medianTR else { continue }
        let groupEpochs = layout.triggers.indices.filter { layout.volumeIndex[$0] == volume }
        guard let group = groupEpochs.last(where: { Double(layout.triggers[$0]) <= t }) else { continue }
        phases.append(["event": event.code, "onsetSeconds": event.beginTimeSeconds,
            "volumePhase": (t - Double(tr[volume])) / Double(tr[volume + 1] - tr[volume]),
            "group": layout.slicePosition[group], "secondsSinceGroup": (t - Double(layout.triggers[group])) / rate])
    }
    var report: [String: Any] = ["input": o.input.path, "sampleRate": rate, "samples": count,
        "eventCounts": counts, "trCode": o.trCode, "trCount": tr.count,
        "trSeconds": ["min": intervals.min()!, "median": medianTR, "max": intervals.max()!],
        "longTriggerGaps": intervals.filter { $0 > 1.5 * medianTR }.count,
        "slices": o.slices, "multiband": o.multiband, "groups": o.slices / o.multiband,
        "groupOffsetsSeconds": o.offsets as Any? ?? NSNull(), "events": o.events,
        "protectionSeconds": [o.protect.lowerBound, o.protect.upperBound],
        "methods": o.methods, "iterations": o.iterations, "tolerance": o.tolerance,
        "firBinMS": o.firBinMS, "ridge": o.ridge, "allowConfounded": o.allowConfounded,
        "requestedDonors": o.donors, "minimumDonors": o.minimum, "maximumDonorDistanceSeconds": o.distance,
        "settings": ["scaling": "unscaled", "alignment": "off", "upsampleFactor": "1", "obs": "off", "anc": "off", "backend": "cpu", "groupMatching": "same-group"],
        "excludedOrUnavailableDonorEpochs": eligible.filter { !$0 }.count,
        "coverage": coverage, "eventPhases": phases,
        "phaseEventsOmittedOutsideCompleteTR": events.count - phases.count,
        "limitations": ["Uniform timing unless explicit group offsets supplied", "No alignment or resampling", "ERP CSV is unfiltered and not baseline-corrected", "PNS preserved without correction", "Injection uses native signal units and a synthetic channel gain ramp; it is not a native ERP truth estimate"]]
    if o.command == "inspect" { try writeJSON(report, to: destination); print("Wrote \(destination.path)"); return }
    let pns = try reader.loadPNSSignal(from: o.input)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let injected = injection(signal: signal, codes: o.events, amplitude: o.amplitude)
    let augmented = zip(signal.data, injected).map { a, b in zip(a, b).map(+) }
    var results: [[String: Any]] = []
    for method in o.methods {
        print("Running \(method)...")
        let start = Date()
        do {
            let result = try runMethod(method, signal: signal, triggers: tr, layout: layout, options: o, protected: protected)
            let injectedResult = try runMethod(method, signal: signal.replacingSamples(augmented), triggers: tr, layout: layout, options: o, protected: protected)
            try MFFWriter.write(signal: signal.replacingSamples(result.channels, signalTypeSuffix: "gradient-\(method)"), pnsSignal: pns, segments: [], kind: .continuous, to: destination.appendingPathComponent("\(method).mff"))
            let recovered = zip(injectedResult.channels, result.channels).map { a, b in zip(a, b).map(-) }
            var dot = 0.0, energy = 0.0
            for c in injected.indices { for i in injected[c].indices { dot += Double(recovered[c][i]) * Double(injected[c][i]); energy += Double(injected[c][i]) * Double(injected[c][i]) } }
            let rows = result.epochs.sorted { $0.epoch < $1.epoch }
            var donorCSV = "epoch,volume,group,corrected,donor_count,max_distance_seconds,donor_indices\n"
            let triggerByEpoch = Dictionary(uniqueKeysWithValues: rows.map { ($0.epoch, $0.trigger) })
            for e in rows {
                let distance = e.donorIndices.compactMap { triggerByEpoch[$0] }.map { Double(abs($0 - e.trigger)) / rate }.max() ?? 0
                donorCSV += "\(e.epoch),\(e.volume),\(e.slicePosition),\(e.corrected),\(e.donorIndices.count),\(distance),\(csv(e.donorIndices.map(String.init).joined(separator: ";")))\n"
            }
            try donorCSV.write(to: destination.appendingPathComponent("\(method)-donors.csv"), atomically: true, encoding: .utf8)
            try erpCSV(signal: signal, output: result.channels, codes: o.events).write(to: destination.appendingPathComponent("\(method)-erp.csv"), atomically: true, encoding: .utf8)
            results.append(["method": method, "status": "ok", "details": result.details, "injectionDetails": injectedResult.details, "secondsIncludingInjectionAndExport": Date().timeIntervalSince(start),
                "correctedEpochs": rows.isEmpty ? NSNull() : rows.filter { $0.corrected }.count as Any, "diagnosticEpochs": rows.count,
                "removedRMS": rms(signal.data, result.channels), "injectedERPRMSE": rms(recovered, injected),
                "injectedERPAmplitudeRatio": energy > 0 ? dot / energy : 0,
                "epochCoverageApplicable": !rows.isEmpty])
        } catch {
            let message = error.localizedDescription
            results.append(["method": method, "status": "failed", "error": message])
            print("\(method) failed: \(message)")
        }
    }
    report["results"] = results
    report["injection"] = ["amplitudeNativeUnits": o.amplitude, "peakSeconds": 0.3, "sigmaSeconds": 0.06, "supportSeconds": [0, 0.8], "channelGains": "linear 1 to 2 (single channel: 1)", "metricSupport": "whole recording, including leakage outside injected windows"] as [String: Any]
    try writeJSON(report, to: destination.appendingPathComponent("report.json"))
    print("Wrote \(destination.path)")
    if !results.contains(where: { $0["status"] as? String == "ok" }) {
        throw CLIError("All requested methods failed; see report.json")
    }
}

func selfTest() throws {
    func check(_ ok: @autoclosure () -> Bool, _ message: String) throws {
        guard ok() else { throw CLIError("Self-test failed: \(message)") }
    }
    let p = GradientDonorPolicy(protectedIntervals: [1..<2])
    try check(p.permitsWindow(start: 0, end: 1), "touching left boundary")
    try check(p.permitsWindow(start: 2, end: 3), "touching right boundary")
    try check(!p.permitsWindow(start: 0.9, end: 1.1), "overlap")
    try check(merged([1..<2, 1.5..<3, 4..<5]) == [1..<3, 4..<5], "merged intervals")
    let rate = 100.0, n = 4001, tr = Array(stride(from: 0, to: 4000, by: 100))
    let artifact = (0..<n).map { Float(50 * sin(2 * Double.pi * Double($0 % 100) / 100)) }
    var truth = [Float](repeating: 0, count: n)
    for i in 1010..<1080 { truth[i] = Float(5 * exp(-0.5 * pow((Double(i) - 1040) / 10, 2))) }
    let raw = [zip(artifact, truth).map(+)]
    var c = GradientCorrectionConfig()
    c.alignmentEnabled = false; c.templateScaling = .unscaled
    let original = try GradientTemplateCorrector.correct(channels: raw, volumeTriggers: tr, config: c, samplingRate: rate)
    c.donorPolicy = GradientDonorPolicy(protectedIntervals: [], maximumDistanceSeconds: 1000, minimumDonors: 1, matchAcquisitionGroup: false)
    let equivalent = try GradientTemplateCorrector.correct(channels: raw, volumeTriggers: tr, config: c, samplingRate: rate)
    try check(rms(original.channels, equivalent.channels) == 0, "unrestricted policy preserves behavior")
    c.donorPolicy = GradientDonorPolicy(protectedIntervals: [10.1..<10.8], maximumDistanceSeconds: 20, minimumDonors: 4)
    let result = try GradientTemplateCorrector.correct(channels: raw, volumeTriggers: tr, config: c, samplingRate: rate)
    try check(result.diagnostics.epochs.contains { $0.epoch == 10 && $0.corrected }, "protected target corrected")
    try check(result.diagnostics.epochs.allSatisfy { !$0.donorIndices.contains(10) }, "protected epoch never donates")
    try check(rms(result.channels, [truth]) < 0.001, "known ERP preserved and artifact removed")
    try check(rms(result.channels, [truth]) < rms(original.channels, [truth]), "exclusion improves ERP recovery over baseline")
    for scheme in [GradientTemplateScheme.correlationRanked, .squaredCorrelationRanked, .motionInformed] {
        var alternate = c
        alternate.templateScheme = scheme
        alternate.minimumCorrelatedDonors = 1000 // exercise temporal fallback
        let fallback = try GradientTemplateCorrector.correct(channels: raw, volumeTriggers: tr, config: alternate, samplingRate: rate)
        try check(fallback.diagnostics.epochs.allSatisfy { !$0.donorIndices.contains(10) }, "fallback respects protection")
        try check(fallback.diagnostics.epochs.allSatisfy { e in e.donorIndices.allSatisfy { abs(tr[$0] - tr[e.epoch]) <= 2000 } }, "fallback respects distance")
    }
    for e in result.diagnostics.epochs {
        try check(e.donorIndices.allSatisfy { abs(tr[$0] - tr[e.epoch]) <= 2000 }, "distance bound")
    }
    c.donorPolicy?.protectedIntervals = [0..<50]
    let shortage = try GradientTemplateCorrector.correct(channels: raw, volumeTriggers: tr, config: c, samplingRate: rate)
    try check(shortage.diagnostics.epochs.allSatisfy { !$0.corrected }, "shortage never falls back to contaminated donors")
    try check(rms(shortage.channels, raw) == 0, "shortage leaves targets unchanged")
    c.acquisitionSchedule = .uniform(groupsPerVolume: 2)
    c.donorPolicy?.protectedIntervals = []
    let grouped = try GradientTemplateCorrector.correct(channels: raw, volumeTriggers: tr, config: c, samplingRate: rate)
    for e in grouped.diagnostics.epochs {
        try check(e.donorIndices.allSatisfy { $0 % 2 == e.slicePosition }, "same acquisition group")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eva-gradient-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("fixture.mff")
    let events = tr.enumerated().map { MFFEvent(id: "tr-\($0.offset)", code: "TREV", beginTimeSeconds: Double($0.element) / rate, rawBeginTime: "", sourceFile: "test") }
        + [MFFEvent(id: "stim", code: "stim", beginTimeSeconds: 10.1, rawBeginTime: "", sourceFile: "test")]
    let signal = MFFSignalData(signalURL: url, signalType: "EEG", numberOfChannels: 1, samplingRate: rate,
        duration: Double(n) / rate, recordingStartTime: Date(timeIntervalSince1970: 1700000000), events: events, data: raw, channelNames: ["Cz"])
    try MFFWriter.write(signal: signal, pnsSignal: nil, segments: [], kind: .continuous, to: url)
    var options = try Options.parse(["inspect", url.path, "--events", "stim", "--report", directory.appendingPathComponent("inspect.json").path])
    try run(options)
    options.command = "compare"; options.output = directory.appendingPathComponent("comparison").path
    try run(options)
    let loaded = try MFFReader().loadSignal(from: directory.appendingPathComponent("comparison/exclude.mff"))
    try check(loaded.data[0].count == n, "output sample count")
    try check(loaded.events.count == events.count, "output events preserved")
    try check(rms(loaded.data, [truth]) < 0.001, "MFF end-to-end ERP recovery")
    try methodSelfTests(signal: signal, triggers: tr, directory: directory)
    print("PASS: interval boundaries, exclusions, protected targets, shortages, distance/group restrictions, compatibility, synthetic ERP recovery, inspect/compare and MFF round trip")
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["self-test"] { try selfTest() }
    else if args.isEmpty || args.contains("--help") { print(help) }
    else { try run(Options.parse(args)) }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    Foundation.exit(1)
}
