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
//  The campaign behind `ArtifactCleanRunGrade`'s touched-fraction band. The
//  event-windowed cleaners (OBS, MAS, per-event wavelet) rewrite the data inside
//  each event's window and leave the rest alone, so the truth-free number a run
//  can report is how much of the recording it rewrote. The question this
//  answers is whether that number predicts harm: as blinks get denser and the
//  touched fraction climbs, does cleaning stop paying for itself?
//
//  Events are the true blink onsets (oracle detection), so the measurement is
//  about the cleaner, not the detector. For each run it reports:
//
//    * touched     — fraction of samples any channel changed (truth-free)
//    * errBefore   — var(noisy − clean) / var(clean)
//    * errAfter    — var(cleaned − clean) / var(clean)
//    * gain        — errBefore / errAfter (> 1 = cleaning helped)
//    * brainLost   — var(changed − ocular) / var(clean) inside touched samples:
//                    what the cleaner took that was not the artifact
//

import Foundation
import Testing
@testable import EVA

struct ArtifactCleanRunGradeMeasurementTests {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["EVA_CALIBRATION"] == "1"
    }

    private struct Row: Sendable {
        var method: String
        var blinksPerMinute: Double
        var seed: Int
        var touched: Double
        var errBefore: Double
        var errAfter: Double
        var brainLost: Double
        var removedVariance: Double
    }

    private func run(method: ArtifactCleaningMethod, blinksPerMinute: Double, seed: Int) throws -> Row {
        let rate = 250.0
        var config = SimulationConfig.default
        config.seed = config.seed &+ UInt64(seed)
        config.eegGenerationModel = .dipole
        config.recordingReference = .average
        config.gradientEnabled = false
        config.bcgEnabled = false
        config.channelCount = 20
        config.samplingRate = rate
        config.durationSeconds = 120
        config.blinksPerMinute = blinksPerMinute

        let montage = Montage.standard(count: config.channelCount)
        let eeg = try DipoleEEGGenerator.generate(config: config, montage: montage)
        let clean = eeg.channels
        var noisy = clean
        var ocularSource = GaussianSource(seed: SimulationSeedStreams.ocular(base: config.seed))
        let ocular = OcularArtifactModel.inject(into: &noisy, config: config, montage: montage, source: &ocularSource)

        let events = ocular.blinkSeconds.enumerated().map { index, onset in
            MFFEvent(id: "blink-\(index)", code: "BLNK", beginTimeSeconds: onset,
                     rawBeginTime: "", sourceFile: "sim", durationSeconds: config.blinkDurationSeconds)
        }
        let artifact = DefinedArtifact(
            type: .ocular, name: "Blink", eventCode: "BLNK", events: events,
            selectedChannelIndices: Array(0..<config.channelCount),
            windowSizeSeconds: config.blinkDurationSeconds + 0.2,
            average: nil, topography: nil, cleaningMethod: method)
        let signal = SyntheticSignal.make(noisy.map { $0.map(Float.init) }, samplingRate: rate)
        let cleaned = ArtifactCleaner.cleanedSignal(from: signal, artifacts: [artifact], excluding: []).signal.data

        let n = clean[0].count
        var touchedMask = [Bool](repeating: false, count: n)
        for c in 0..<config.channelCount {
            for t in 0..<n where abs(Double(cleaned[c][t]) - noisy[c][t]) > 1e-4 { touchedMask[t] = true }
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
        _ = ocular
        return Row(
            method: method.rawValue, blinksPerMinute: blinksPerMinute, seed: seed,
            touched: Double(touchedMask.filter { $0 }.count) / Double(n),
            errBefore: brainEnergy > 0 ? before / brainEnergy : 0,
            errAfter: brainEnergy > 0 ? after / brainEnergy : 0,
            brainLost: brainEnergy > 0 ? lost / brainEnergy : 0,
            removedVariance: input > 0 ? removed / input : 0)
    }

    @Test func touchedFractionVersusHarm() async throws {
        guard Self.isEnabled else {
            print("ArtifactCleanRunGradeMeasurementTests: set EVA_CALIBRATION=1 (scripts/calibrate.sh artifact) to run. Skipping.")
            return
        }
        let methods: [ArtifactCleaningMethod] = [.obs, .mas, .wavelet]
        let rates = [3.0, 10, 20, 35, 50, 70, 100]
        var jobs: [(ArtifactCleaningMethod, Double, Int)] = []
        for m in methods { for r in rates { for s in [1, 2] { jobs.append((m, r, s)) } } }

        var rows: [Row] = []
        var failures: [String] = []
        let limit = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        try await withThrowingTaskGroup(of: Result<Row, Error>.self) { group in
            var next = 0
            func submit() {
                guard next < jobs.count else { return }
                let (m, r, s) = jobs[next]; next += 1
                group.addTask {
                    do { return .success(try self.run(method: m, blinksPerMinute: r, seed: s)) }
                    catch { return .failure(error) }
                }
            }
            for _ in 0..<limit { submit() }
            while let result = try await group.next() {
                switch result {
                case .success(let row): rows.append(row)
                case .failure(let error): failures.append("threw \(error)")
                }
                submit()
            }
        }

        var lines = ["=== artifact clean run grade: touched fraction vs harm (oracle blink events, 20 ch, 250 Hz, 120 s) ===",
                     "err = var(· − clean)/var(clean); gain = errBefore/errAfter; brainLost = non-artifact change inside touched samples / var(clean)",
                     "",
                     "method        blinks/min  touched  errBefore  errAfter   gain    brainLost  removedVar"]
        for m in methods {
            for r in rates {
                let group = rows.filter { $0.method == m.rawValue && $0.blinksPerMinute == r }
                guard !group.isEmpty else { continue }
                func avg(_ f: (Row) -> Double) -> Double { group.map(f).reduce(0, +) / Double(group.count) }
                lines.append(String(format: "%@  %6.0f      %5.3f   %8.3f   %8.3f  %6.2f   %8.3f   %6.3f",
                    m.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0), r,
                    avg(\.touched), avg(\.errBefore), avg(\.errAfter),
                    avg(\.errBefore) / max(1e-9, avg(\.errAfter)), avg(\.brainLost), avg(\.removedVariance)))
            }
            lines.append("")
        }
        lines.append(contentsOf: failures)
        for line in lines { print(line) }
        try? (lines.joined(separator: "\n") + "\n").write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("eva-artifact-clean-run-grade.txt"),
            atomically: true, encoding: .utf8)
    }
}
