//
//  GradientRunGradeMeasurementTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  CALIBRATION, not a regression test. Gated behind EVA_CALIBRATION=1 (run via
//  `scripts/calibrate.sh gradient`) so its minutes of compute stay out of the
//  default suite.
//
//  The `evaluate-gradient` campaign behind `GradientRunGrade`'s bands. It
//  simulates EEG + gradient artifact with known truth, runs EVA's real gradient
//  engines (FASTR, Allen IAR, local-template median), and for every channel
//  pairs the truth-free metric the app can compute — the TR-locked residual
//  share — with the truth it is supposed to stand for:
//
//      residual error = var(corrected − clean) / var(clean)   over the scan
//
//  One axis at a time is pushed from a baseline (the paper's rig: 152 µs/s clock
//  offset, 10 % slow modulation) through the conditions that break template
//  subtraction — clock drift, amplitude modulation, missing anti-aliasing,
//  jittered or missing TR markers, too few donors — so the table shows where
//  each engine stops working and whether the metric sees it.
//

import Foundation
import Testing
@testable import EVA

struct GradientRunGradeMeasurementTests {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["EVA_CALIBRATION"] == "1"
    }

    // MARK: Recording

    private struct Recording {
        var clean: [[Double]]
        var noisy: [[Float]]
        var triggers: [Int]
        var rate: Double
    }

    private struct Perturbation: Sendable {
        var triggerJitterSamples = 0
        var droppedTriggerFraction = 0.0
        /// Zero-pad the synthetic slice template before the simulator's
        /// anti-alias filter. That filter works on the template's own window, so
        /// unpadded it leaves the waveform starting and ending off zero — a step
        /// at every slice that aliases into the recording. Padded, the recorded
        /// artifact is band-limited and a sub-sample shift can represent it.
        var zeroPaddedTemplate = false
    }

    private func makeRecording(_ config: SimulationConfig, _ perturbation: Perturbation) throws -> Recording {
        let montage = Montage.standard(count: config.channelCount)
        let eeg = try DipoleEEGGenerator.generate(config: config, montage: montage)
        var noisy = eeg.channels
        var template: HighRateTemplate?
        if perturbation.zeroPaddedTemplate {
            let synthetic = GradientArtifactModel.syntheticTemplate(config: config)
            let padSeconds = 0.03
            let zeros = [Double](repeating: 0, count: Int(padSeconds * synthetic.rate))
            template = HighRateTemplate(samples: zeros + synthetic.samples + zeros, rate: synthetic.rate,
                                        leadInSeconds: synthetic.leadInSeconds + padSeconds)
        }
        let injection = GradientArtifactModel.inject(into: &noisy, config: config, montage: montage, template: template)
        var triggers = injection.quantizedVolumeOnsetsSeconds.map { Int(($0 * config.samplingRate).rounded()) }

        // Deterministic marker damage: an LCG seeded from the config seed.
        var state = config.seed &* 6_364_136_223_846_793_005 &+ 1
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        if perturbation.triggerJitterSamples > 0 {
            let j = perturbation.triggerJitterSamples
            triggers = triggers.map { $0 + Int((next() * Double(2 * j + 1)).rounded(.down)) - j }
        }
        if perturbation.droppedTriggerFraction > 0 {
            // Never drop the first two, so every run keeps a measurable epoch.
            triggers = triggers.enumerated().compactMap { i, t in
                i < 2 || next() >= perturbation.droppedTriggerFraction ? t : nil
            }
        }
        return Recording(clean: eeg.channels, noisy: noisy.map { $0.map(Float.init) },
                         triggers: triggers, rate: config.samplingRate)
    }

    // MARK: Engines

    private struct EngineRun {
        var output: [[Float]]
        var corrected: Int
        var total: Int
    }

    private typealias Engine = (name: String, run: @Sendable ([[Float]], [Int], Double) throws -> EngineRun)

    private static func fastr(_ name: String, donorsEachSide: Int = 4, align: Bool = true, radius: Int? = nil) -> Engine {
        (name, { channels, triggers, rate in
            var c = GradientCorrectionConfig()
            c.alignmentSearchRadius = radius
            c.averagingWindowBefore = donorsEachSide
            c.averagingWindowAfter = donorsEachSide
            c.alignmentEnabled = align
            c.subSampleAlignment = align
            let r = try GradientTemplateCorrector.correct(
                channels: channels, volumeTriggers: triggers, config: c, samplingRate: rate)
            return EngineRun(output: r.channels, corrected: r.diagnostics.correctedEpochCount,
                             total: r.diagnostics.epochs.count)
        })
    }

    private static let allen: Engine = ("Allen IAR", { channels, triggers, rate in
        let r = try GradientAAS.correct(
            channels: channels, volumeTriggers: triggers, config: .allenIARVolume, samplingRate: rate)
        return EngineRun(output: r.channels, corrected: r.diagnostics.correctedEpochCount,
                         total: r.diagnostics.epochs.count)
    })

    private static let localMedian: Engine = ("Local median", { channels, triggers, rate in
        var c = LocalTemplateConfiguration()
        c.donorsBefore = 4
        c.donorsAfter = 4
        let r = try LocalTemplateArtifactCorrector.correctGradient(
            channels: channels, trSamples: triggers, samplingRate: rate, configuration: c)
        let skipped = r.eventSummaries.filter { $0.skippedReason != nil }.count
        return EngineRun(output: r.cleanedChannels, corrected: r.eventSummaries.count - skipped,
                         total: r.eventSummaries.count)
    })

    // MARK: Measurement

    private struct Row: Sendable {
        var axis: String
        var value: String
        var engine: String
        var seed: Int
        var metrics: GradientRunMetrics
        /// Per channel: (metric, truth), broadband and in-band.
        var channels: [(Double, Double)]
        var inBandChannels: [(Double, Double)]
        var truthP90: Double
        var truthMedian: Double
        var inBandTruthP90: Double
    }

    private func measure(axis: String, value: String, recording: Recording, engine: Engine, seed: Int) throws -> Row? {
        let run = try engine.run(recording.noisy, recording.triggers, recording.rate)
        guard let metrics = GradientRunMetricsCalculator.measure(
            input: recording.noisy, output: run.output, triggers: recording.triggers,
            samplingRate: recording.rate, correctedEpochs: run.corrected, totalEpochs: run.total),
              let geometry = GradientRunMetricsCalculator.epochGeometry(
                triggers: recording.triggers, sampleCount: recording.noisy[0].count)
        else { return nil }
        let fractions = GradientRunMetricsCalculator.residualFractions(
            output: run.output, geometry: geometry, samplingRate: recording.rate)
        func errorRatio(_ y: [Double], _ clean: [Double]) -> Double {
            var mean = 0.0
            for t in geometry.scan { mean += clean[t] }
            mean /= Double(geometry.scan.count)
            var err = 0.0, brain = 0.0
            for t in geometry.scan {
                let d = y[t] - clean[t]
                err += d * d
                brain += (clean[t] - mean) * (clean[t] - mean)
            }
            return brain > 0 ? err / brain : 0
        }
        let cutoff = GradientRunMetricsCalculator.inBandCutoffHz
        var pairs: [(Double, Double)] = [], inBandPairs: [(Double, Double)] = []
        for f in fractions {
            let clean = recording.clean[f.channel]
            let y = run.output[f.channel].map(Double.init)
            pairs.append((f.broadband, errorRatio(y, clean)))
            if let inBand = f.inBand {
                inBandPairs.append((inBand, errorRatio(
                    GradientRunMetricsCalculator.lowPassed(y, cutoffHz: cutoff, samplingRate: recording.rate),
                    GradientRunMetricsCalculator.lowPassed(clean, cutoffHz: cutoff, samplingRate: recording.rate))))
            }
        }
        let truth = pairs.map(\.1).sorted()
        return Row(axis: axis, value: value, engine: engine.name, seed: seed, metrics: metrics,
                   channels: pairs, inBandChannels: inBandPairs,
                   truthP90: GradientRunMetricsCalculator.percentile(truth, 0.9),
                   truthMedian: GradientRunMetricsCalculator.percentile(truth, 0.5),
                   inBandTruthP90: GradientRunMetricsCalculator.percentile(inBandPairs.map(\.1).sorted(), 0.9))
    }

    private func spearman(_ pairs: [(Double, Double)]) -> Double {
        func ranks(_ v: [Double]) -> [Double] {
            let order = v.indices.sorted { v[$0] < v[$1] }
            var r = [Double](repeating: 0, count: v.count)
            for (rank, i) in order.enumerated() { r[i] = Double(rank) }
            return r
        }
        let a = ranks(pairs.map(\.0)), b = ranks(pairs.map(\.1))
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in a.indices {
            num += (a[i] - ma) * (b[i] - mb)
            da += (a[i] - ma) * (a[i] - ma)
            db += (b[i] - mb) * (b[i] - mb)
        }
        return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
    }

    @Test func gradientResidualMetricVersusTruth() async throws {
        guard Self.isEnabled else {
            print("GradientRunGradeMeasurementTests: set EVA_CALIBRATION=1 (scripts/calibrate.sh gradient) to run. Skipping.")
            return
        }

        var base = SimulationConfig.default
        base.eegGenerationModel = .dipole
        base.recordingReference = .average
        base.bcgEnabled = false
        base.channelCount = 20
        base.samplingRate = 500
        base.durationSeconds = 150   // 50 volumes at TR 3 s — two of Allen's 25-epoch sections

        let engines: [Engine] = [
            Self.fastr("FASTR"), Self.allen, Self.localMedian,
        ]
        let seeds = [1, 2]

        typealias Condition = (axis: String, value: String, config: @Sendable (inout SimulationConfig) -> Void,
                               perturbation: Perturbation, engines: [Engine])
        var conditions: [Condition] = [("baseline", "-", { _ in }, Perturbation(), engines)]
        for v in [0.0, 500, 1500, 5000] {
            conditions.append(("clock µs/s", String(format: "%.0f", v), { $0.clockOffsetMicrosecondsPerSecond = v }, Perturbation(), engines))
        }
        for v in [0.0, 0.3, 0.6] {
            conditions.append(("slow modulation", String(format: "%.1f", v), { $0.slowModulationFraction = v }, Perturbation(), engines))
        }
        conditions.append(("anti-alias", "off", { $0.artifactAntiAliasFraction = 0 }, Perturbation(), engines))
        for v in [250.0, 1000] {
            conditions.append(("rate Hz", String(format: "%.0f", v), { $0.samplingRate = v }, Perturbation(), engines))
        }
        for v in [1, 3, 10, 50] {
            var p = Perturbation(); p.triggerJitterSamples = v
            conditions.append(("marker jitter smp", "\(v)", { _ in }, p, engines))
        }
        for v in [0.05, 0.2] {
            var p = Perturbation(); p.droppedTriggerFraction = v
            conditions.append(("dropped markers", String(format: "%.2f", v), { _ in }, p, engines))
        }
        for v in [1, 2, 15] {
            conditions.append(("FASTR donors/side", "\(v)", { _ in }, Perturbation(), [Self.fastr("FASTR", donorsEachSide: v)]))
        }
        conditions.append(("synced", "clk0 mod0", { $0.clockOffsetMicrosecondsPerSecond = 0; $0.slowModulationFraction = 0 }, Perturbation(), engines))
        conditions.append(("synced 1 kHz", "clk0 mod0", { $0.clockOffsetMicrosecondsPerSecond = 0; $0.slowModulationFraction = 0; $0.samplingRate = 1000 }, Perturbation(), engines))
        conditions.append(("FASTR radius", "15", { _ in }, Perturbation(), [Self.fastr("FASTR r15", radius: 15)]))
        conditions.append(("FASTR radius", "15 clk0", { $0.clockOffsetMicrosecondsPerSecond = 0 }, Perturbation(), [Self.fastr("FASTR r15", radius: 15)]))
        conditions.append(("FASTR alignment", "off", { $0.clockOffsetMicrosecondsPerSecond = 1500 }, Perturbation(),
                           [Self.fastr("FASTR no-align", align: false)]))
        var padded = Perturbation(); padded.zeroPaddedTemplate = true
        conditions.append(("sim template", "padded", { _ in }, padded, engines))

        // Every (condition, seed) is independent, so the grid runs across
        // cores; a progress line per finished job lands in the temp dir so a
        // long run can be watched.
        let dir = FileManager.default.temporaryDirectory
        let progressURL = dir.appendingPathComponent("eva-gradient-run-grade.progress")
        try? "".write(to: progressURL, atomically: true, encoding: .utf8)
        let progressLock = NSLock()
        func note(_ line: String) {
            progressLock.lock(); defer { progressLock.unlock() }
            if let handle = try? FileHandle(forWritingTo: progressURL) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                try? handle.close()
            }
        }

        struct Job: Sendable { var condition: Int; var seed: Int }
        let jobs = conditions.indices.flatMap { c in seeds.map { Job(condition: c, seed: $0) } }
        var results: [Int: [Row]] = [:]
        var failures: [String] = []
        let limit = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        try await withThrowingTaskGroup(of: (Int, [Row], [String]).self) { group in
            var next = 0
            func submit() {
                guard next < jobs.count else { return }
                let job = jobs[next]; next += 1
                let condition = conditions[job.condition]
                group.addTask {
                    var config = base
                    config.seed = base.seed &+ UInt64(job.seed)
                    condition.config(&config)
                    let recording = try self.makeRecording(config, condition.perturbation)
                    var rows: [Row] = [], errors: [String] = []
                    for engine in condition.engines {
                        do {
                            if let row = try self.measure(axis: condition.axis, value: condition.value,
                                                          recording: recording, engine: engine, seed: job.seed) {
                                rows.append(row)
                            }
                        } catch {
                            errors.append("  \(condition.axis) \(condition.value) \(engine.name) seed \(job.seed): threw \(error)")
                        }
                    }
                    note("done \(condition.axis) \(condition.value) seed \(job.seed)")
                    return (job.condition, rows, errors)
                }
            }
            for _ in 0..<limit { submit() }
            while let (condition, rows, errors) = try await group.next() {
                results[condition, default: []].append(contentsOf: rows)
                failures.append(contentsOf: errors)
                submit()
            }
        }

        var rows: [Row] = []
        var lines = ["=== gradient run grade: TR-locked residual vs truth (20 ch, TR 3 s, 150 s, 500 Hz) ===",
                     "truth = var(corrected − clean)/var(clean) over the scan; metric = TR-locked residual share (p90 over channels)",
                     "",
                     "truth/metric are broadband unless marked ≤40 (after a 40 Hz low-pass); implied = m/(1−m), the metric's own estimate of the truth ratio",
                     "",
                     "axis               value  engine          truthP90 metP90 implied | ≤40 truthP90 metP90 implied | removed  coverage"]
        for (index, condition) in conditions.enumerated() {
            let conditionRows = (results[index] ?? []).sorted { $0.seed < $1.seed }
            rows.append(contentsOf: conditionRows)
            for engine in condition.engines {
                let rs = conditionRows.filter { $0.engine == engine.name }
                guard !rs.isEmpty else { continue }
                func avg(_ f: (Row) -> Double) -> Double { rs.map(f).reduce(0, +) / Double(rs.count) }
                let m = avg(\.metrics.residualFractionP90)
                let mb = avg { $0.metrics.inBandResidualFractionP90 ?? 0 }
                lines.append(String(
                    format: "%@ %@ %@ %9.3f %6.3f %7.3f | %9.3f %6.3f %7.3f | %6.4f  %6.3f",
                    condition.axis.padding(toLength: 18, withPad: " ", startingAt: 0),
                    condition.value.padding(toLength: 6, withPad: " ", startingAt: 0),
                    engine.name.padding(toLength: 15, withPad: " ", startingAt: 0),
                    avg(\.truthP90), m, m / max(1e-9, 1 - m),
                    avg(\.inBandTruthP90), mb, mb / max(1e-9, 1 - mb),
                    avg(\.metrics.removedVarianceFraction), avg(\.metrics.correctedEpochFraction)))
            }
        }
        lines.append(contentsOf: failures)

        // How well does the metric track truth?
        let channelPairs = rows.flatMap(\.channels)
        let inBandPairs = rows.flatMap(\.inBandChannels)
        let runPairs = rows.map { ($0.metrics.residualFractionP90, $0.truthP90) }
        let inBandRunPairs = rows.compactMap { r in r.metrics.inBandResidualFractionP90.map { ($0, r.inBandTruthP90) } }
        lines.append("")
        lines.append(String(format: "Spearman(metric, truth) broadband: per channel %.3f (n=%d), per run p90 %.3f (n=%d)",
                            spearman(channelPairs), channelPairs.count, spearman(runPairs), runPairs.count))
        lines.append(String(format: "Spearman(metric, truth) ≤40 Hz:    per channel %.3f (n=%d), per run p90 %.3f (n=%d)",
                            spearman(inBandPairs), inBandPairs.count, spearman(inBandRunPairs), inBandRunPairs.count))

        // Candidate thresholds against truth classes at the run level.
        func separation(_ title: String, _ pairs: [(Double, Double)]) {
            lines.append("")
            lines.append("\(title) — run level (truth p90: good < 0.1, watch 0.1–1, poor ≥ 1):")
            lines.append("  metric≥τ   flags truth-poor   flags truth-watch   flags truth-good")
            let poor = pairs.filter { $0.1 >= 1 }
            let watch = pairs.filter { $0.1 >= 0.1 && $0.1 < 1 }
            let good = pairs.filter { $0.1 < 0.1 }
            for tau in [0.02, 0.05, 0.08, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8] {
                func rate(_ set: [(Double, Double)]) -> String {
                    guard !set.isEmpty else { return "  n/a  " }
                    return String(format: "%3d/%-3d", set.filter { $0.0 >= tau }.count, set.count)
                }
                lines.append(String(format: "  %5.2f      %@            %@             %@", tau, rate(poor), rate(watch), rate(good)))
            }
        }
        separation("Broadband", runPairs)
        separation("≤40 Hz", inBandRunPairs)

        for line in lines { print(line) }
        try? (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("eva-gradient-run-grade.txt"), atomically: true, encoding: .utf8)
        var csv = ["axis,value,engine,seed,metric_p90,metric_median,truth_p90,truth_median,inband_metric_p90,inband_truth_p90,removed,coverage"]
        for r in rows {
            csv.append("\(r.axis),\(r.value),\(r.engine),\(r.seed),"
                + String(format: "%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.6f,%.4f",
                         r.metrics.residualFractionP90, r.metrics.residualFractionMedian,
                         r.truthP90, r.truthMedian, r.metrics.inBandResidualFractionP90 ?? -1, r.inBandTruthP90,
                         r.metrics.removedVarianceFraction,
                         r.metrics.correctedEpochFraction))
        }
        try? (csv.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("eva-gradient-run-grade.csv"), atomically: true, encoding: .utf8)
    }
}
