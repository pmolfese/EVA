//
//  TimeFrequencyEngineTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  PART TF-1 validation gate. Two independent checks on the complex Morlet ERSP
//  engine:
//
//  1. MNE cross-check — EVA's trial-averaged power must match
//     `mne.time_frequency.tfr_array_morlet(output='avg_power')` on the same
//     input, within floating-point tolerance. The reference is the committed
//     fixture `Fixtures/tf_morlet_reference.json`, generated offline by
//     `Fixtures/generate_tf_reference.py` (the XCTest sandbox cannot shell out).
//
//  2. Physics recovery — a known 6 Hz burst at a known latency must show up in
//     the baseline-normalized ERSP at the right frequency, the right time, and a
//     clearly elevated dB.
//
//  Per the harness note, differences are compared as ONE aggregate #expect, not
//  element-by-element (a per-cell loop over ~19k cells is macro-overhead death).
//

import Testing
import Foundation
@testable import EVA

struct TimeFrequencyEngineTests {

    // MARK: Fixture

    private struct TFReference: Decodable {
        var samplingRate: Double
        var nTimes: Int
        var nTrials: Int
        var burstFrequencyHz: Double
        var burstCenterSeconds: Double
        var freqsHz: [Double]
        var nCycles: Double
        var zeroMean: Bool
        var trials: [[Double]]     // (nTrials, nTimes)
        var avgPower: [[Double]]   // (nFreqs, nTimes)
        var itc: [[Double]]        // (nFreqs, nTimes)
        var timeBandwidth: Double
        var mtAvgPower: [[Double]] // (nFreqs, nTimes)
        var mtItc: [[Double]]      // (nFreqs, nTimes)
        var dpss: DPSSCase
    }

    private struct DPSSCase: Decodable {
        var length: Int
        var halfNBW: Double
        var kMax: Int
        var tapers: [[Double]]     // (kMax, length)
        var ratios: [Double]
    }

    private static let reference: TFReference = {
        let url = Fixtures.url("tf_morlet_reference.json")
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(TFReference.self, from: data)
    }()

    // MARK: 1. MNE cross-check

    @Test func meanPowerMatchesMNEReference() {
        let ref = Self.reference
        let plan = TFFrequencyPlan.explicit(frequenciesHz: ref.freqsHz, nCycles: ref.nCycles)

        let power = TimeFrequencyEngine.meanPower(
            trials: ref.trials,
            samplingRate: ref.samplingRate,
            plan: plan
        )

        #expect(power.count == ref.avgPower.count)
        #expect(power.first?.count == ref.avgPower.first?.count)

        // Aggregate error, scaled by the reference's global peak so near-zero
        // cells don't blow up a relative metric. Both sides compute a
        // zero-padded linear convolution, so agreement should be ~machine eps.
        var maxAbsError = 0.0
        var refPeak = 0.0
        for fi in ref.avgPower.indices {
            for ti in ref.avgPower[fi].indices {
                refPeak = max(refPeak, abs(ref.avgPower[fi][ti]))
                maxAbsError = max(maxAbsError, abs(power[fi][ti] - ref.avgPower[fi][ti]))
            }
        }
        let relativeError = refPeak > 0 ? maxAbsError / refPeak : maxAbsError
        #expect(relativeError < 1e-6,
                "EVA ERSP power deviates from MNE by \(relativeError) (rel to peak \(refPeak))")
    }

    @Test func itpcMatchesMNEReference() {
        let ref = Self.reference
        let plan = TFFrequencyPlan.explicit(frequenciesHz: ref.freqsHz, nCycles: ref.nCycles)

        let (_, itpc) = TimeFrequencyEngine.decompose(
            trials: ref.trials,
            samplingRate: ref.samplingRate,
            plan: plan
        )

        #expect(itpc.count == ref.itc.count)
        #expect(itpc.first?.count == ref.itc.first?.count)

        // ITPC is already in [0, 1]; compare directly (no peak scaling needed).
        var maxAbsError = 0.0
        for fi in ref.itc.indices {
            for ti in ref.itc[fi].indices {
                maxAbsError = max(maxAbsError, abs(itpc[fi][ti] - ref.itc[fi][ti]))
            }
        }
        #expect(maxAbsError < 1e-6, "EVA ITPC deviates from MNE by \(maxAbsError)")
    }

    @Test func itpcIsHighAtPhaseLockedBurst() {
        let ref = Self.reference
        let plan = TFFrequencyPlan.explicit(frequenciesHz: ref.freqsHz, nCycles: ref.nCycles)
        let (_, itpc) = TimeFrequencyEngine.decompose(
            trials: ref.trials,
            samplingRate: ref.samplingRate,
            plan: plan
        )

        let burstFi = ref.freqsHz.indices.min {
            abs(ref.freqsHz[$0] - ref.burstFrequencyHz) < abs(ref.freqsHz[$1] - ref.burstFrequencyHz)
        }!
        let burstTi = Int(ref.burstCenterSeconds * ref.samplingRate)

        // The burst is identical (phase-locked) across trials → ITPC ≈ 1 there.
        #expect(itpc[burstFi][burstTi] > 0.9,
                "phase-locked burst ITPC \(itpc[burstFi][burstTi]) not near 1")

        // Pre-stimulus baseline is noise-only → low phase coherence with 40 trials.
        let baselineEnd = Int(0.5 * ref.samplingRate) - 1
        var baselineMean = 0.0
        for t in 0...baselineEnd { baselineMean += itpc[burstFi][t] }
        baselineMean /= Double(baselineEnd + 1)
        #expect(baselineMean < 0.4, "baseline ITPC \(baselineMean) unexpectedly high")
    }

    // MARK: DPSS tapers (multitaper)

    @Test func dpssMatchesScipy() {
        let ref = Self.reference.dpss
        let (tapers, ratios) = DPSS.tapers(length: ref.length, halfNBW: ref.halfNBW, kMax: ref.kMax)

        #expect(tapers.count == ref.tapers.count)
        #expect(tapers.first?.count == ref.length)

        // Ratios (concentration eigenvalues) must match closely.
        var maxRatioError = 0.0
        for k in ratios.indices { maxRatioError = max(maxRatioError, abs(ratios[k] - ref.ratios[k])) }
        #expect(maxRatioError < 1e-9, "DPSS ratio error \(maxRatioError)")

        // Tapers match up to a per-taper sign (irrelevant for power).
        var maxTaperError = 0.0
        for k in tapers.indices {
            let a = tapers[k], b = ref.tapers[k]
            var same = 0.0, flipped = 0.0
            for i in 0..<min(a.count, b.count) {
                same = max(same, abs(a[i] - b[i]))
                flipped = max(flipped, abs(a[i] + b[i]))
            }
            maxTaperError = max(maxTaperError, min(same, flipped))
        }
        #expect(maxTaperError < 1e-9, "DPSS taper error \(maxTaperError)")
    }

    @Test func multitaperPowerMatchesMNEReference() {
        let ref = Self.reference
        let plan = TFFrequencyPlan.explicit(frequenciesHz: ref.freqsHz, nCycles: ref.nCycles)
        let (power, _) = TimeFrequencyEngine.decompose(
            trials: ref.trials, samplingRate: ref.samplingRate, plan: plan,
            method: .multitaper, timeBandwidth: ref.timeBandwidth
        )

        #expect(power.count == ref.mtAvgPower.count)
        var maxAbsError = 0.0, refPeak = 0.0
        for fi in ref.mtAvgPower.indices {
            for ti in ref.mtAvgPower[fi].indices {
                refPeak = max(refPeak, abs(ref.mtAvgPower[fi][ti]))
                maxAbsError = max(maxAbsError, abs(power[fi][ti] - ref.mtAvgPower[fi][ti]))
            }
        }
        let relativeError = refPeak > 0 ? maxAbsError / refPeak : maxAbsError
        #expect(relativeError < 1e-6, "multitaper power deviates from MNE by \(relativeError)")
    }

    @Test func multitaperITCMatchesMNEReference() {
        let ref = Self.reference
        let plan = TFFrequencyPlan.explicit(frequenciesHz: ref.freqsHz, nCycles: ref.nCycles)
        let (_, itpc) = TimeFrequencyEngine.decompose(
            trials: ref.trials, samplingRate: ref.samplingRate, plan: plan,
            method: .multitaper, timeBandwidth: ref.timeBandwidth
        )

        var maxAbsError = 0.0
        for fi in ref.mtItc.indices {
            for ti in ref.mtItc[fi].indices {
                maxAbsError = max(maxAbsError, abs(itpc[fi][ti] - ref.mtItc[fi][ti]))
            }
        }
        #expect(maxAbsError < 1e-6, "multitaper ITC deviates from MNE by \(maxAbsError)")
    }

    // MARK: 2. Physics recovery

    @Test func erspRecoversBurstFrequencyLatencyAndPower() {
        let ref = Self.reference
        let plan = TFFrequencyPlan.explicit(frequenciesHz: ref.freqsHz, nCycles: ref.nCycles)

        // Baseline: first 0.5 s, well before the mid-epoch burst.
        let baselineEnd = Int(0.5 * ref.samplingRate) - 1
        let baseline = TFBaselineSpec(startSample: 0, endSample: baselineEnd, method: .decibel)

        let result = try! #require(TimeFrequencyEngine.ersp(
            trials: ref.trials,
            samplingRate: ref.samplingRate,
            plan: plan,
            baseline: baseline
        ))

        // Locate the global ERSP maximum.
        var peakFreqIndex = 0
        var peakTimeIndex = 0
        var peakValue = -Double.greatestFiniteMagnitude
        for fi in result.ersp.indices {
            for ti in result.ersp[fi].indices where result.ersp[fi][ti] > peakValue {
                peakValue = result.ersp[fi][ti]
                peakFreqIndex = fi
                peakTimeIndex = ti
            }
        }

        // Frequency: nearest analysis bin to the injected 6 Hz.
        let expectedFreqIndex = ref.freqsHz.indices.min {
            abs(ref.freqsHz[$0] - ref.burstFrequencyHz) < abs(ref.freqsHz[$1] - ref.burstFrequencyHz)
        }!
        #expect(abs(peakFreqIndex - expectedFreqIndex) <= 1,
                "ERSP peak at \(result.frequenciesHz[peakFreqIndex]) Hz, expected ~\(ref.burstFrequencyHz) Hz")

        // Latency: within ±150 ms of the burst center.
        let peakTimeSeconds = Double(peakTimeIndex) / ref.samplingRate
        #expect(abs(peakTimeSeconds - ref.burstCenterSeconds) < 0.15,
                "ERSP peak at \(peakTimeSeconds) s, expected ~\(ref.burstCenterSeconds) s")

        // Magnitude: the burst should be clearly elevated over baseline, and the
        // baseline period itself should sit near 0 dB.
        #expect(peakValue > 6.0, "burst dB \(peakValue) not clearly elevated")

        let burstRow = result.ersp[expectedFreqIndex]
        var baselineMean = 0.0
        for t in 0...baselineEnd { baselineMean += burstRow[t] }
        baselineMean /= Double(baselineEnd + 1)
        #expect(abs(baselineMean) < 1.0, "baseline dB \(baselineMean) not near zero")
    }

    // MARK: 3. Determinism

    @Test func meanPowerIsDeterministic() {
        let ref = Self.reference
        let plan = TFFrequencyPlan.explicit(frequenciesHz: ref.freqsHz, nCycles: ref.nCycles)
        let a = TimeFrequencyEngine.meanPower(trials: ref.trials, samplingRate: ref.samplingRate, plan: plan)
        let b = TimeFrequencyEngine.meanPower(trials: ref.trials, samplingRate: ref.samplingRate, plan: plan)

        var maxDiff = 0.0
        for fi in a.indices {
            for ti in a[fi].indices { maxDiff = max(maxDiff, abs(a[fi][ti] - b[fi][ti])) }
        }
        #expect(maxDiff == 0.0)
    }

    // MARK: Trial-stack data prep (feeds the TF view)

    @Test func trialStackResolvesChannelsAndTrimsToCommonLength() {
        // Two channels, three "A" epochs and two "B" epochs at known ranges.
        let sr = 250.0
        let n = 400
        let chan0 = SyntheticSignal.sine(frequency: 6, samplingRate: sr, count: n, amplitude: 10)
        let chan1 = SyntheticSignal.sine(frequency: 6, samplingRate: sr, count: n, amplitude: 30)
        let signal = SyntheticSignal.make([chan0, chan1], samplingRate: sr)

        func seg(_ start: Int, _ end: Int, _ cat: String) -> EpochSegment {
            EpochSegment(startSample: start, endSample: end, stimulusOffsetSamples: 25,
                         category: cat, sourceCode: "x", sourceTimeSeconds: 0, colorIndex: 0,
                         contributingEpochCount: 1)
        }
        let segments = [
            seg(0, 99, "A"), seg(100, 199, "A"), seg(200, 289, "A"),  // last is shorter (90)
            seg(0, 99, "B"), seg(100, 199, "B"),
        ]

        let stack = TimeFrequencyTrials.stack(signal: signal, segments: segments, category: "A", channelIndices: [0, 1])
        #expect(stack.trials.count == 3)
        // Trimmed to the shortest A epoch (90 samples).
        #expect(stack.timeCount == 90)
        #expect(stack.trials.allSatisfy { $0.count == 90 })
        #expect(stack.stimulusOffsetSamples == 25)

        // Channel resolution = mean of the two channels → amplitude ~20 sine.
        let peak = stack.trials[0].map(abs).max() ?? 0
        #expect(peak > 15 && peak < 25, "channel-averaged amplitude \(peak) not ~20")

        // A different category yields its own count.
        let stackB = TimeFrequencyTrials.stack(signal: signal, segments: segments, category: "B", channelIndices: [0])
        #expect(stackB.trials.count == 2)
        #expect(stackB.timeCount == 100)
    }

    // MARK: TF-3 export

    @Test func npyMatchesNumpyReference() {
        // Same array numpy wrote to the fixture: arange(24)*0.5 − 3, shape (2,3,4).
        var map = [[[Double]]](repeating: [[Double]](repeating: [Double](repeating: 0, count: 4), count: 3), count: 2)
        var v = 0.0
        for c in 0..<2 { for f in 0..<3 { for t in 0..<4 { map[c][f][t] = v * 0.5 - 3.0; v += 1 } } }

        let produced = TimeFrequencyExport.npy(map)
        let reference = try! Data(contentsOf: Fixtures.url("npy_reference_2x3x4.npy"))
        #expect(produced == reference, "EVA NPY is not byte-identical to numpy (\(produced.count) vs \(reference.count) bytes)")
    }

    @Test func scalarCSVReducesBandWindowMeans() {
        // One channel, freqs 5/6/7 Hz (all in Theta 4–8), times 100–400 ms.
        let maps = TimeFrequencyExport.ConditionMaps(
            condition: "A",
            channelNames: ["Cz"],
            ersp: [[[1, 2, 3, 4], [1, 2, 3, 4], [1, 2, 3, 4]]],   // freq × time
            itpc: [[[0, 0.5, 0.5, 1], [0, 0.5, 0.5, 1], [0, 0.5, 0.5, 1]]],
            frequenciesHz: [5, 6, 7],
            timesMs: [100, 200, 300, 400]
        )
        let context = TimeFrequencyExport.Context(
            plan: .explicit(frequenciesHz: [5, 6, 7], nCycles: 7),
            method: .morlet, timeBandwidth: 4,
            baselineMethod: .decibel,
            bands: EEGFrequencyBand.restingDefaults,
            windows: [TimeFrequencyExport.Window(label: "200-500ms", startMs: 200, endMs: 500)]
        )
        let rows = TimeFrequencyExport.scalarCSVRows([maps], context: context)

        // The 200–500 ms window selects times 200/300/400 → ersp mean (2+3+4)/3 = 3.
        let erspRow = rows.first { $0.count == 9 && $0[0] == "tf_scalar" && $0[5] == "Theta" && $0[6] == "200-500ms" && $0[7] == "ersp" }
        #expect(erspRow?[8] == "3")
        // ITPC mean over the same window = (0.5+0.5+1)/3 ≈ 0.6667.
        let itpcRow = rows.first { $0.count == 9 && $0[0] == "tf_scalar" && $0[5] == "Theta" && $0[6] == "200-500ms" && $0[7] == "itpc" }
        #expect((itpcRow?[8]).map { Double($0) ?? -1 }.map { abs($0 - 0.6667) < 1e-3 } == true)
        // Header + a summary parameter row are present.
        #expect(rows.first == ["row_type", "scope", "condition", "channel_index", "channel_name", "band", "window", "measure", "value"])
        #expect(rows.contains { $0[0] == "summary" && $0[7] == "baseline_method" && $0[8] == "dB" })
    }

    // MARK: Kernel unit checks

    @Test func kernelMatchesMNENormalization() {
        // MNE normalizes so the real part has L2 norm 1 and the full complex
        // wavelet has L2 norm √2.
        let k = ComplexMorlet.kernel(frequencyHz: 6.0, nCycles: 7.0, samplingRate: 250.0)
        var realNormSq = 0.0
        var fullNormSq = 0.0
        for i in 0..<k.count {
            realNormSq += k.re[i] * k.re[i]
            fullNormSq += k.re[i] * k.re[i] + k.im[i] * k.im[i]
        }
        #expect(abs(realNormSq.squareRoot() - 1.0) < 1e-6)
        #expect(abs(fullNormSq.squareRoot() - 2.0.squareRoot()) < 1e-6)
    }
}
