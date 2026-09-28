//
//  ICARunGradeMeasurementTests.swift
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
//  `scripts/calibrate.sh ica`).
//
//  The campaign behind `ICARunGrade`'s data-sufficiency band. The one ICA
//  failure a truth-free number can predict before anyone looks at a component
//  is too little data for the number of components: the unmixing has n² free
//  parameters, and the usual rule of thumb (Onton & Makeig 2006) asks for
//  20–30 × n² samples. This measures where that bites in EVA's own Picard on
//  seeded dipole EEG while independently varying data volume, source
//  non-Gaussianity, and blink strength. The original campaign used only the
//  easiest corner (strongly bursty neural sources and a 100 µV blink), which
//  could not test the rule in the weak / near-Gaussian regime it is meant to
//  guard.
//
//  To keep the question about the *decomposition* and not about labelling, the
//  component removed is chosen by oracle — the one whose time course best
//  matches the true ocular signal. So the truth numbers are the best a user
//  could have done with that decomposition:
//
//    * blink removal — fraction of the ocular artifact removed (1 = all)
//    * brain lost    — var(removed − ocular) / var(clean): what went out that
//                      was not artifact
//
//  κ = analysis samples / components² is the truth-free number the grade uses.
//

import Foundation
import Testing
@testable import EVA

struct ICARunGradeMeasurementTests {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["EVA_CALIBRATION"] == "1"
    }

    private struct Row: Sendable {
        var channels: Int
        var components: Int
        var seconds: Double
        var seed: Int
        var nominalKappa: Double
        var kappa: Double
        var sourceBurstiness: Double
        var meanSourceExcessKurtosis: Double
        var blinkAmplitudeMicrovolts: Double
        var iterations: Int
        var finalChange: Double
        var bestCorrelation: Double
        var blinkRemoval: Double
        var brainLost: Double
        var removedVariance: Double
        var ocularShare: Double
    }

    private static func layout(for montage: Montage) -> SensorLayout {
        let radius = montage.positions.map { hypot($0.x, $0.y) }.max() ?? 1
        let scale = radius > 0 ? radius : 1
        return SensorLayout(
            name: montage.name,
            positions: montage.positions.enumerated().map { index, position in
                SensorPosition(channelIndex: index, x: position.x / scale, y: position.y / scale)
            }
        )
    }

    private func run(
        channels: Int,
        seconds: Double,
        seed: Int,
        nominalKappa: Double,
        sourceBurstiness: Double,
        blinkAmplitudeMicrovolts: Double
    ) throws -> Row {
        let rate = 250.0
        var config = SimulationConfig.default
        config.seed = config.seed &+ UInt64(seed)
        config.eegGenerationModel = .dipole
        config.nonGaussianSources = NonGaussianSourceModel(
            burstiness: sourceBurstiness,
            burstSeconds: 0.5
        )
        config.recordingReference = .average
        config.gradientEnabled = false
        config.bcgEnabled = false
        config.channelCount = channels
        config.samplingRate = rate
        config.durationSeconds = seconds
        config.blinksPerMinute = 16
        config.blinkAmplitudeMicrovolts = blinkAmplitudeMicrovolts
        // Fill the rank: average reference leaves n − 1 dimensions, and the
        // blink takes one of them. With fewer sources than that, PCA trims the
        // decomposition to the true rank and every run is data-rich by default.
        // The eye model spans more than one dimension, so leave it room.
        config.dipoleSourceCount = channels - 4

        let montage = Montage.standard(count: channels)
        let eeg = try DipoleEEGGenerator.generate(config: config, montage: montage)
        let sourceKurtoses = eeg.sourceSpace?.timecoursesNanoampereMeters.map {
            NonGaussianSourceModel.excessKurtosis($0)
        } ?? []
        let meanSourceExcessKurtosis = sourceKurtoses.isEmpty ? 0
            : sourceKurtoses.reduce(0, +) / Double(sourceKurtoses.count)
        let clean = eeg.channels
        var noisy = clean
        var ocularSource = GaussianSource(seed: SimulationSeedStreams.ocular(base: config.seed))
        let ocular = OcularArtifactModel.inject(into: &noisy, config: config, montage: montage, source: &ocularSource)
        let artifact = zip(noisy, clean).map { n, c in zip(n, c).map { $0 - $1 } }
        let blinkChannel = ocular.blinkTopography.enumerated().max { abs($0.element) < abs($1.element) }?.offset ?? 0

        let signal = SyntheticSignal.make(noisy.map { $0.map(Float.init) }, samplingRate: rate)
        let maxIterations = 200
        let decomposition = try ICAArtifactDetector.fit(
            signal: signal,
            configuration: ICAConfiguration(
                method: .picard, componentCount: channels - 1, varianceThreshold: 0.99999,
                averageReference: true, downsampleRate: 125, maxIterations: maxIterations,
                learningRate: nil, fitFilter: nil, convergenceTolerance: 1e-7, minimumIterations: 10))

        // Oracle: the component whose time course best matches the ocular signal
        // on its strongest channel, decimated the way the fit was.
        let step = max(1, decomposition.decimation)
        let reference = stride(from: 0, to: artifact[blinkChannel].count, by: step).map { artifact[blinkChannel][$0] }
        func correlation(_ a: [Double], _ b: [Double]) -> Double {
            let n = min(a.count, b.count)
            guard n > 2 else { return 0 }
            let ma = a.prefix(n).reduce(0, +) / Double(n), mb = b.prefix(n).reduce(0, +) / Double(n)
            var num = 0.0, da = 0.0, db = 0.0
            for i in 0..<n {
                num += (a[i] - ma) * (b[i] - mb)
                da += (a[i] - ma) * (a[i] - ma)
                db += (b[i] - mb) * (b[i] - mb)
            }
            return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
        }
        let scored = decomposition.componentSources.enumerated().map { ($0.offset, abs(correlation($0.element, reference))) }
        let best = scored.max { $0.1 < $1.1 } ?? (0, 0)

        let cleaned = ICAArtifactDetector.cleanedSignal(from: signal, decomposition: decomposition, excluding: [best.0]).data

        // Truth.
        var ocularEnergy = 0.0, ocularResidual = 0.0
        var cleanEnergy = 0.0, lostEnergy = 0.0, inputEnergy = 0.0, removedEnergy = 0.0
        for c in 0..<channels {
            let meanClean = clean[c].reduce(0, +) / Double(clean[c].count)
            for t in clean[c].indices {
                let removed = noisy[c][t] - Double(cleaned[c][t])
                let a = artifact[c][t]
                ocularEnergy += a * a
                let residual = Double(cleaned[c][t]) - clean[c][t]
                ocularResidual += residual * residual
                cleanEnergy += (clean[c][t] - meanClean) * (clean[c][t] - meanClean)
                lostEnergy += (removed - a) * (removed - a)
                inputEnergy += noisy[c][t] * noisy[c][t]
                removedEnergy += removed * removed
            }
        }
        let kappa = Double(decomposition.componentSources.first?.count ?? 0)
            / Double(decomposition.componentCount * decomposition.componentCount)
        return Row(
            channels: channels, components: decomposition.componentCount, seconds: seconds, seed: seed,
            nominalKappa: nominalKappa, kappa: kappa,
            sourceBurstiness: sourceBurstiness,
            meanSourceExcessKurtosis: meanSourceExcessKurtosis,
            blinkAmplitudeMicrovolts: blinkAmplitudeMicrovolts,
            iterations: decomposition.iterations, finalChange: decomposition.finalChange,
            bestCorrelation: best.1,
            blinkRemoval: ocularEnergy > 0 ? 1 - ocularResidual / ocularEnergy : 0,
            brainLost: cleanEnergy > 0 ? lostEnergy / cleanEnergy : 0,
            removedVariance: inputEnergy > 0 ? removedEnergy / inputEnergy : 0,
            ocularShare: inputEnergy > 0 ? ocularEnergy / inputEnergy : 0)
    }

    @Test func dataSufficiencyVersusDecompositionQuality() async throws {
        guard Self.isEnabled else {
            print("ICARunGradeMeasurementTests: set EVA_CALIBRATION=1 (scripts/calibrate.sh ica) to run. Skipping.")
            return
        }
        // Hold channel geometry fixed and cross the current κ boundary with the
        // two factors the first campaign omitted. `burstiness = 0` is the
        // Gaussian non-identifiability control; 0.02 is the near-Gaussian regime;
        // 0.7 reproduces the old clearly separable background. Blink amplitudes
        // span weak through the old 100 µV case. Two seeds keep this on-demand
        // campaign tractable; five seeds expose the instability this campaign
        // is looking for, and every raw row is retained for judging it.
        let channels = 20
        var jobs: [(Double, Double, Double, Int, Double)] = []
        for nominalKappa in [5.0, 10, 20, 40] {
            let seconds = (nominalKappa * Double((channels - 1) * (channels - 1)) / 125).rounded(.up)
            for burstiness in [0.0, 0.02, 0.7] {
                for blinkAmplitude in [10.0, 30, 100] {
                    for seed in [1, 2, 3, 4, 5] {
                        jobs.append((nominalKappa, burstiness, blinkAmplitude, seed, seconds))
                    }
                }
            }
        }

        let dir = FileManager.default.temporaryDirectory
        let progressURL = dir.appendingPathComponent("eva-ica-run-grade.progress")
        try? "".write(to: progressURL, atomically: true, encoding: .utf8)
        let lock = NSLock()
        func note(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            if let h = try? FileHandle(forWritingTo: progressURL) {
                h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close()
            }
        }

        var rows: [Row] = []
        var failures: [String] = []
        let limit = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        try await withThrowingTaskGroup(of: Result<Row, Error>.self) { group in
            var next = 0
            func submit() {
                guard next < jobs.count else { return }
                let (nominalKappa, burstiness, blinkAmplitude, seed, seconds) = jobs[next]
                next += 1
                group.addTask {
                    do {
                        let row = try self.run(
                            channels: channels,
                            seconds: seconds,
                            seed: seed,
                            nominalKappa: nominalKappa,
                            sourceBurstiness: burstiness,
                            blinkAmplitudeMicrovolts: blinkAmplitude
                        )
                        note(String(
                            format: "done κnom=%.0f burst=%.1f blink=%.0f seed=%d κ=%.1f",
                            nominalKappa, burstiness, blinkAmplitude, seed, row.kappa
                        ))
                        return .success(row)
                    } catch {
                        return .failure(error)
                    }
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

        rows.sort {
            ($0.sourceBurstiness, $0.blinkAmplitudeMicrovolts, $0.nominalKappa, $0.seed)
                < ($1.sourceBurstiness, $1.blinkAmplitudeMicrovolts, $1.nominalKappa, $1.seed)
        }
        var lines = ["=== ICA run grade: κ × source Gaussianity × blink strength (Picard, 125 Hz analysis) ===",
                     "blink removal = 1 − residual ocular / ocular (1 = all); brain lost = var(removed − ocular)/var(clean)",
                     "",
                     " burst blink  κnom  κreal kurtosis seed comps T(s) iters conv |r|best blinkRemoval brainLost ocularShare"]
        for r in rows {
            lines.append(String(
                format: "  %.2f %5.0f  %4.0f  %5.1f  %7.2f   %d   %3d  %4.0f  %4d  %@   %.3f      %.3f       %.3f     %.4f",
                r.sourceBurstiness, r.blinkAmplitudeMicrovolts, r.nominalKappa, r.kappa,
                r.meanSourceExcessKurtosis, r.seed, r.components, r.seconds, r.iterations,
                r.iterations < 200 ? "yes" : " no", r.bestCorrelation, r.blinkRemoval,
                r.brainLost, r.ocularShare
            ))
        }
        lines.append("")
        lines.append("Means by source regime, blink strength, and requested κ:")
        for burstiness in [0.0, 0.02, 0.7] {
            for blinkAmplitude in [10.0, 30, 100] {
                for nominalKappa in [5.0, 10, 20, 40] {
                    let group = rows.filter {
                        $0.sourceBurstiness == burstiness
                            && $0.blinkAmplitudeMicrovolts == blinkAmplitude
                            && $0.nominalKappa == nominalKappa
                    }
                    guard !group.isEmpty else { continue }
                    func avg(_ f: (Row) -> Double) -> Double {
                        group.map(f).reduce(0, +) / Double(group.count)
                    }
                    lines.append(String(
                        format: "  burst %.2f blink %3.0f κnom %2.0f (κ %.1f): removal %.3f brainLost %.3f |r| %.3f ocularShare %.4f",
                        burstiness, blinkAmplitude, nominalKappa, avg(\.kappa),
                        avg(\.blinkRemoval), avg(\.brainLost), avg(\.bestCorrelation),
                        avg(\.ocularShare)
                    ))
                }
            }
        }
        // Does hitting the iteration cap predict a worse removal? Compare
        // converged and capped runs of the same condition.
        lines.append("")
        lines.append("Converged vs capped, same (n, T):")
        for key in Set(rows.map { "\($0.channels)/\(Int($0.seconds))" }).sorted() {
            let group = rows.filter { "\($0.channels)/\(Int($0.seconds))" == key }
            let converged = group.filter { $0.iterations < 200 }, capped = group.filter { $0.iterations >= 200 }
            guard !converged.isEmpty, !capped.isEmpty else { continue }
            func avg(_ g: [Row], _ f: (Row) -> Double) -> Double { g.map(f).reduce(0, +) / Double(g.count) }
            lines.append(String(format: "  %@  converged %d: brainLost %.3f blink %.3f | capped %d: brainLost %.3f blink %.3f",
                key, converged.count, avg(converged, \.brainLost), avg(converged, \.blinkRemoval),
                capped.count, avg(capped, \.brainLost), avg(capped, \.blinkRemoval)))
        }
        lines.append(contentsOf: failures)
        for line in lines { print(line) }
        try? (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("eva-ica-run-grade.txt"), atomically: true, encoding: .utf8)
        var csv = ["source_burstiness,blink_amplitude_uv,nominal_kappa,realized_kappa,mean_source_excess_kurtosis,seed,components,seconds,iterations,converged,best_abs_correlation,blink_removal,brain_lost,removed_variance,ocular_share"]
        csv.append(contentsOf: rows.map { r in
            [
                String(r.sourceBurstiness), String(r.blinkAmplitudeMicrovolts), String(r.nominalKappa),
                String(r.kappa), String(r.meanSourceExcessKurtosis), String(r.seed), String(r.components),
                String(r.seconds), String(r.iterations), r.iterations < 200 ? "true" : "false",
                String(r.bestCorrelation), String(r.blinkRemoval), String(r.brainLost),
                String(r.removedVariance), String(r.ocularShare)
            ].joined(separator: ",")
        })
        try? (csv.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("eva-ica-run-grade.csv"), atomically: true, encoding: .utf8)
    }
}
