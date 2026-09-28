//
//  ArtifactCleanRunGradeMeasurementTests.swift
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
//  `scripts/calibrate.sh artifact`).
//
//  End-to-end follow-up to the oracle-event campaign behind
//  `ArtifactCleanRunGrade`. Simulated blink times are used only as truth for
//  scoring: the events passed to ArtifactCleaner come from EVA's production
//  EyeArtifactThresholdDetector. The campaign crosses blink density, detector
//  threshold / signal amplitude, and cleaning method, and reports detector
//  precision/recall/timing plus touched fraction, residual error and brain loss.
//

import Foundation
import Testing
@testable import EVA

struct ArtifactCleanRunGradeMeasurementTests {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["EVA_CALIBRATION"] == "1"
    }

    private struct Scenario: Sendable {
        var name: String
        var blinkAmplitudeMicrovolts: Double
        var detectorThresholdMicrovolts: Float
    }

    private struct Row: Sendable {
        var scenario: String
        var blinkAmplitudeMicrovolts: Double
        var detectorThresholdMicrovolts: Float
        var method: String
        var blinksPerMinute: Double
        var seed: Int
        var trueEvents: Int
        var detectedEvents: Int
        var truePositiveEvents: Int
        var falsePositiveEvents: Int
        var falseNegativeEvents: Int
        var precision: Double
        var recall: Double
        var f1: Double
        var peakMAESeconds: Double?
        var touched: Double
        var errBefore: Double
        var errAfter: Double
        var brainLost: Double
        var removedVariance: Double
    }

    private struct MatchScore: Sendable {
        var truePositives: Int
        var falsePositives: Int
        var falseNegatives: Int
        var precision: Double
        var recall: Double
        var f1: Double
        var meanAbsoluteErrorSeconds: Double?
    }

    /// The simulator's blink template peaks at ~120 ms. Detector events are
    /// peak-anchored, while `blinkSeconds` contains template onsets.
    private static let simulatedBlinkPeakDelaySeconds = 0.12
    /// Blinks have a 1 s refractory floor, so this admits template / sampling
    /// jitter without allowing adjacent truth events to compete for a match.
    private static let matchToleranceSeconds = 0.25

    private func scoreDetection(truthOnsets: [Double], detected: [MFFEvent]) -> MatchScore {
        let truthPeaks = truthOnsets.map { $0 + Self.simulatedBlinkPeakDelaySeconds }
        let detections = detected.map(\.beginTimeSeconds).sorted()
        var unmatchedTruth = Set(truthPeaks.indices)
        var errors: [Double] = []

        for detection in detections {
            let best = unmatchedTruth
                .map { ($0, abs(truthPeaks[$0] - detection)) }
                .filter { $0.1 <= Self.matchToleranceSeconds }
                .min { $0.1 < $1.1 }
            if let best {
                unmatchedTruth.remove(best.0)
                errors.append(best.1)
            }
        }

        let tp = errors.count
        let fp = detections.count - tp
        let fn = truthPeaks.count - tp
        let precision = detections.isEmpty ? (truthPeaks.isEmpty ? 1 : 0) : Double(tp) / Double(detections.count)
        let recall = truthPeaks.isEmpty ? 1 : Double(tp) / Double(truthPeaks.count)
        let f1 = precision + recall > 0 ? 2 * precision * recall / (precision + recall) : 0
        return MatchScore(
            truePositives: tp, falsePositives: fp, falseNegatives: fn,
            precision: precision, recall: recall, f1: f1,
            meanAbsoluteErrorSeconds: errors.isEmpty ? nil : errors.reduce(0, +) / Double(errors.count)
        )
    }

    private func runCondition(
        scenario: Scenario,
        methods: [ArtifactCleaningMethod],
        blinksPerMinute: Double,
        seed: Int
    ) throws -> [Row] {
        let rate = 250.0
        var config = SimulationConfig.default
        config.seed = config.seed &+ UInt64(seed)
        config.eegGenerationModel = .dipole
        config.recordingReference = .average
        config.gradientEnabled = false
        config.bcgEnabled = false
        config.channelCount = 20
        config.samplingRate = rate
        config.durationSeconds = 60
        config.blinksPerMinute = blinksPerMinute
        config.blinkAmplitudeMicrovolts = scenario.blinkAmplitudeMicrovolts

        // Montage.standard(20) is a true 10-20 ordering. The production detector
        // does not mistake it for an EGI net and therefore exercises its shipped
        // fallback: the first four frontal channels (Fp1/Fp2/F7/F3).
        let montage = Montage.standard(count: config.channelCount)
        let eeg = try DipoleEEGGenerator.generate(config: config, montage: montage)
        let clean = eeg.channels
        var noisy = clean
        var ocularSource = GaussianSource(seed: SimulationSeedStreams.ocular(base: config.seed))
        let ocular = OcularArtifactModel.inject(
            into: &noisy, config: config, montage: montage, source: &ocularSource)

        var detectorConfig = EyeArtifactThresholdConfiguration.defaults(for: .blink)
        detectorConfig.amplitudeMinMicrovolts = scenario.detectorThresholdMicrovolts
        let floatNoisy = noisy.map { $0.map(Float.init) }
        let events = EyeArtifactThresholdDetector.detect(
            kind: .blink,
            channels: floatNoisy,
            samplingRate: rate,
            duration: config.durationSeconds,
            sensorLayoutName: montage.name,
            configuration: detectorConfig
        )
        let detection = scoreDetection(truthOnsets: ocular.blinkSeconds, detected: events)

        let signal = SyntheticSignal.make(floatNoisy, samplingRate: rate)
        let n = clean[0].count
        var rows: [Row] = []
        for method in methods {
            let artifact = DefinedArtifact(
                type: .ocular, name: "Detected blink", eventCode: EyeArtifactKind.blink.eventCode,
                events: events, selectedChannelIndices: Array(0..<config.channelCount),
                windowSizeSeconds: config.blinkDurationSeconds + 0.2,
                average: nil, topography: nil, cleaningMethod: method)
            let cleaned = ArtifactCleaner.cleanedSignal(
                from: signal, artifacts: [artifact], excluding: []).signal.data

            var touchedMask = [Bool](repeating: false, count: n)
            for c in 0..<config.channelCount {
                for t in 0..<n where abs(Double(cleaned[c][t]) - noisy[c][t]) > 1e-4 {
                    touchedMask[t] = true
                }
            }
            var brainEnergy = 0.0, before = 0.0, after = 0.0, lost = 0.0, input = 0.0, removed = 0.0
            for c in 0..<config.channelCount {
                let mean = clean[c].reduce(0, +) / Double(n)
                let meanX = noisy[c].reduce(0, +) / Double(n)
                for t in 0..<n {
                    let b = clean[c][t] - mean
                    brainEnergy += b * b
                    let artifactPart = noisy[c][t] - clean[c][t]
                    before += artifactPart * artifactPart
                    let e = Double(cleaned[c][t]) - clean[c][t]
                    after += e * e
                    let change = noisy[c][t] - Double(cleaned[c][t])
                    removed += change * change
                    input += (noisy[c][t] - meanX) * (noisy[c][t] - meanX)
                    if touchedMask[t] {
                        let notArtifact = change - artifactPart
                        lost += notArtifact * notArtifact
                    }
                }
            }
            rows.append(Row(
                scenario: scenario.name,
                blinkAmplitudeMicrovolts: scenario.blinkAmplitudeMicrovolts,
                detectorThresholdMicrovolts: scenario.detectorThresholdMicrovolts,
                method: method.rawValue,
                blinksPerMinute: blinksPerMinute,
                seed: seed,
                trueEvents: ocular.blinkSeconds.count,
                detectedEvents: events.count,
                truePositiveEvents: detection.truePositives,
                falsePositiveEvents: detection.falsePositives,
                falseNegativeEvents: detection.falseNegatives,
                precision: detection.precision,
                recall: detection.recall,
                f1: detection.f1,
                peakMAESeconds: detection.meanAbsoluteErrorSeconds,
                touched: Double(touchedMask.filter { $0 }.count) / Double(n),
                errBefore: brainEnergy > 0 ? before / brainEnergy : 0,
                errAfter: brainEnergy > 0 ? after / brainEnergy : 0,
                brainLost: brainEnergy > 0 ? lost / brainEnergy : 0,
                removedVariance: input > 0 ? removed / input : 0
            ))
        }
        return rows
    }

    @Test func realDetectionVersusHarm() async throws {
        guard Self.isEnabled else {
            print("ArtifactCleanRunGradeMeasurementTests: set EVA_CALIBRATION=1 (scripts/calibrate.sh artifact) to run. Skipping.")
            return
        }
        let scenarios = [
            Scenario(name: "sensitive-100", blinkAmplitudeMicrovolts: 100, detectorThresholdMicrovolts: 50),
            Scenario(name: "default-100", blinkAmplitudeMicrovolts: 100, detectorThresholdMicrovolts: 150),
            Scenario(name: "default-200", blinkAmplitudeMicrovolts: 200, detectorThresholdMicrovolts: 150)
        ]
        let methods: [ArtifactCleaningMethod] = [.obs, .sspPCA, .mas, .wavelet]
        // At 60 s, the 20/min condition directly exercises the 20-event pooled-
        // basis boundary while retaining the original 0–100/min density span.
        let rates = [0.0, 3, 10, 20, 50, 100]
        var jobs: [(Scenario, Double, Int)] = []
        for scenario in scenarios {
            for rate in rates {
                for seed in [1, 2] { jobs.append((scenario, rate, seed)) }
            }
        }

        var rows: [Row] = []
        var failures: [String] = []
        // PCA-backed cleaners have large transient allocations. Run conditions
        // serially and drain autoreleased storage between them so the calibration
        // remains reliable in the sandboxed app test host.
        for (index, job) in jobs.enumerated() {
            let (scenario, rate, seed) = job
            do {
                let conditionRows = try autoreleasepool {
                    try self.runCondition(
                        scenario: scenario, methods: methods,
                        blinksPerMinute: rate, seed: seed)
                }
                rows.append(contentsOf: conditionRows)
                print("artifact calibration \(index + 1)/\(jobs.count): \(scenario.name), \(rate)/min, seed \(seed)")
            } catch {
                failures.append("\(scenario.name) \(rate)/min seed \(seed) threw \(error)")
            }
        }
        rows.sort {
            ($0.scenario, $0.method, $0.blinksPerMinute, $0.seed)
                < ($1.scenario, $1.method, $1.blinksPerMinute, $1.seed)
        }

        func average(_ group: [Row], _ keyPath: KeyPath<Row, Double>) -> Double {
            group.map { $0[keyPath: keyPath] }.reduce(0, +) / Double(group.count)
        }
        func averageInt(_ group: [Row], _ keyPath: KeyPath<Row, Int>) -> Double {
            group.map { Double($0[keyPath: keyPath]) }.reduce(0, +) / Double(group.count)
        }
        func averageOptional(_ group: [Row], _ keyPath: KeyPath<Row, Double?>) -> Double? {
            let values = group.compactMap { $0[keyPath: keyPath] }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }

        var lines = [
            "=== artifact clean run grade: real blink detection vs harm (20 ch 10-20, 250 Hz, 60 s, 2 seeds) ===",
            "Detection uses EVA EyeArtifactThresholdDetector on noisy data; simulator onsets are scoring truth only.",
            "Peak match = onset + 0.12 s within ±0.25 s. Default detector settings retained except the named amplitude threshold.",
            "err = var(· − clean)/var(clean); gain = errBefore/errAfter; brainLost = non-artifact change inside touched samples / var(clean)",
            "",
            "scenario       method        rate true det  prec   rec    f1  peakMAE touched errBefore errAfter  gain brainLost removedVar"
        ]
        for scenario in scenarios {
            for method in methods {
                for rate in rates {
                    let group = rows.filter {
                        $0.scenario == scenario.name
                            && $0.method == method.rawValue
                            && $0.blinksPerMinute == rate
                    }
                    guard !group.isEmpty else { continue }
                    let before = average(group, \.errBefore)
                    let after = average(group, \.errAfter)
                    let peak = averageOptional(group, \.peakMAESeconds)
                    lines.append(String(
                        format: "%-14@ %-12@ %4.0f %4.1f %4.1f %5.3f %5.3f %5.3f %7@ %7.3f %9.3f %8.3f %5.2f %9.3f %10.3f",
                        scenario.name as NSString,
                        method.rawValue as NSString,
                        rate,
                        averageInt(group, \.trueEvents),
                        averageInt(group, \.detectedEvents),
                        average(group, \.precision),
                        average(group, \.recall),
                        average(group, \.f1),
                        peak.map { String(format: "%.3f", $0) } ?? "--",
                        average(group, \.touched), before, after,
                        before / max(1e-9, after),
                        average(group, \.brainLost),
                        average(group, \.removedVariance)
                    ))
                }
                lines.append("")
            }
        }
        lines.append(contentsOf: failures)

        var csv = [
            "scenario,blink_amplitude_uv,detector_threshold_uv,method,blinks_per_minute,seed,true_events,detected_events,true_positives,false_positives,false_negatives,precision,recall,f1,peak_mae_seconds,touched_fraction,error_before,error_after,gain,brain_lost,removed_variance"
        ]
        for row in rows {
            csv.append([
                row.scenario,
                String(format: "%.0f", row.blinkAmplitudeMicrovolts),
                String(format: "%.0f", row.detectorThresholdMicrovolts),
                row.method,
                String(format: "%.0f", row.blinksPerMinute),
                String(row.seed),
                String(row.trueEvents),
                String(row.detectedEvents),
                String(row.truePositiveEvents),
                String(row.falsePositiveEvents),
                String(row.falseNegativeEvents),
                String(format: "%.6f", row.precision),
                String(format: "%.6f", row.recall),
                String(format: "%.6f", row.f1),
                row.peakMAESeconds.map { String(format: "%.6f", $0) } ?? "",
                String(format: "%.6f", row.touched),
                String(format: "%.6f", row.errBefore),
                String(format: "%.6f", row.errAfter),
                String(format: "%.6f", row.errBefore / max(1e-9, row.errAfter)),
                String(format: "%.6f", row.brainLost),
                String(format: "%.6f", row.removedVariance)
            ].joined(separator: ","))
        }

        for line in lines { print(line) }
        let directory = FileManager.default.temporaryDirectory
        try? (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("eva-artifact-clean-run-grade.txt"),
            atomically: true, encoding: .utf8)
        try? (csv.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("eva-artifact-clean-run-grade.csv"),
            atomically: true, encoding: .utf8)
    }
}
