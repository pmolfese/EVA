//
//  GradientRunGrade.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Turns an MRI gradient correction into a `StepQuality` grade — the second
//  producer after `PCASRunGrade` (ROADMAP § Processing run-grade).
//
//  ## What can be measured without truth
//
//  The gradient artifact is tens to hundreds of times the EEG, so a working
//  correction removes nearly all of the variance, and what separates a good
//  run from a poor one is what is *left* — which is locked to the scanner's
//  clock while the brain is not.
//
//  So the residual metric folds the corrected scan into TR epochs and, at every
//  phase of the TR cycle, takes the variance across epochs. Brain activity has
//  no reason to prefer one phase of the TR over another, so on a clean run that
//  profile is flat. Residual artifact — a spike that template subtraction missed
//  by a fraction of a sample, a slice left uncorrected at the edge of a volume,
//  a template scaled wrong — piles up at the phases where the artifact lives.
//  The metric is the share of corrected energy that sits *above* the flat floor,
//  the floor being a robust low quantile of the profile corrected for its own
//  sampling spread. It makes no assumption about the residual's shape, which
//  matters: at EEG sampling rates the dominant residue is sub-sample spike
//  jitter, which no first-order template model describes.
//
//  It is reported broadband and after a 40 Hz low-pass. Much gradient residue
//  is high-frequency and a later low-pass removes it; the in-band figure says
//  what an analysis in the usual EEG bands will actually see.
//
//  Bands come from `GradientRunGradeMeasurementTests` (EVA_CALIBRATION=1,
//  `scripts/calibrate.sh gradient`) and are recorded in
//  docs/provenance/run-grade-calibration.md § Gradient.
//
//  The residual metric can only fold on the markers the run was given, so
//  residue that is not locked to them reads low: grossly misplaced markers, or
//  artifact aliased by a missing anti-alias filter. Removed variance covers
//  exactly those cases — because the artifact dwarfs the brain, a correction
//  that works removes ≥ 0.99 of the scan's variance, and one that failed
//  removes visibly less (or, subtracting a template where there was no
//  artifact, more than was there). It is graded with two edges only; the
//  campaign gave no evidence for a Watch band in between.
//
//  What neither can see: a correction that removes brain along with the
//  artifact (an over-eager OBS stage, say) leaves nothing TR-locked behind and
//  removes ~1.0 of the variance either way, so it grades Good.
//

import Foundation

/// The truth-free numbers a gradient run is graded on. Computed off the main
/// actor, once, from the run's input and output.
nonisolated struct GradientRunMetrics: Codable, Sendable, Equatable, Hashable {
    /// Per-channel share of corrected in-scan energy that is TR-locked excess
    /// (broadband), at the 90th percentile across graded channels — residue on
    /// a few peripheral channels is exactly the failure worth flagging, and a
    /// median would average it away.
    var residualFractionP90: Double
    var residualFractionMedian: Double
    /// The worst channel's broadband share, and which channel (0-based).
    var residualFractionMax: Double
    var worstChannel: Int?
    /// The same share after a 40 Hz low-pass: what an analysis in the usual EEG
    /// bands will see. `nil` when the sampling rate is too low to split.
    var inBandResidualFractionP90: Double?
    var inBandResidualFractionMedian: Double?
    /// `var(input − output) / var(input)` over the scan, pooled over channels.
    /// Graded only at its extremes (see the file comment).
    var removedVarianceFraction: Double
    /// Epochs (or events) the engine actually corrected, of those it was given.
    var correctedEpochs: Int
    var totalEpochs: Int
    var gradedChannelCount: Int

    var correctedEpochFraction: Double {
        totalEpochs > 0 ? Double(correctedEpochs) / Double(totalEpochs) : 1
    }
}

nonisolated enum GradientRunMetricsCalculator {

    /// Low-pass edge for the in-band figure.
    static let inBandCutoffHz = 40.0

    /// Measures a run.
    ///
    /// - Parameters:
    ///   - input: the channels handed to the correction.
    ///   - output: what it returned (same shape).
    ///   - triggers: the volume triggers, in samples, the run used.
    ///   - excludedChannels: channels deliberately passed through uncorrected;
    ///     they are not graded (an untouched channel is "all residual" by
    ///     construction, and that is the user's choice, not a failure).
    /// - Returns: `nil` when there are fewer than two usable TR epochs.
    static func measure(
        input: [[Float]],
        output: [[Float]],
        triggers: [Int],
        samplingRate: Double,
        correctedEpochs: Int,
        totalEpochs: Int,
        excludedChannels: Set<Int> = []
    ) -> GradientRunMetrics? {
        guard let geometry = epochGeometry(triggers: triggers, sampleCount: input.first?.count ?? 0),
              output.count == input.count
        else { return nil }
        let fractions = residualFractions(
            output: output, geometry: geometry, samplingRate: samplingRate,
            excludedChannels: excludedChannels)
        guard !fractions.isEmpty else { return nil }

        // Removed variance over the scan, pooled over the graded channels.
        // Both sides demeaned: the artifact carries an offset, and counting it
        // on one side only reads as "removed more than was there".
        var removedNumerator = 0.0
        var removedDenominator = 0.0
        for fraction in fractions {
            let x = input[fraction.channel], y = output[fraction.channel]
            var meanX = 0.0, meanD = 0.0
            for t in geometry.scan {
                meanX += Double(x[t])
                meanD += Double(x[t]) - Double(y[t])
            }
            meanX /= Double(geometry.scan.count)
            meanD /= Double(geometry.scan.count)
            for t in geometry.scan {
                let d = Double(x[t]) - Double(y[t]) - meanD
                let c = Double(x[t]) - meanX
                removedNumerator += d * d
                removedDenominator += c * c
            }
        }

        let broadband = fractions.map(\.broadband).sorted()
        let inBand = fractions.compactMap(\.inBand).sorted()
        let worst = fractions.max { $0.broadband < $1.broadband }
        return GradientRunMetrics(
            residualFractionP90: percentile(broadband, 0.9),
            residualFractionMedian: percentile(broadband, 0.5),
            residualFractionMax: broadband.last ?? 0,
            worstChannel: worst?.channel,
            inBandResidualFractionP90: inBand.isEmpty ? nil : percentile(inBand, 0.9),
            inBandResidualFractionMedian: inBand.isEmpty ? nil : percentile(inBand, 0.5),
            removedVarianceFraction: removedDenominator > 0 ? removedNumerator / removedDenominator : 0,
            correctedEpochs: correctedEpochs,
            totalEpochs: totalEpochs,
            gradedChannelCount: fractions.count
        )
    }

    /// The TR epochs a run is measured over: non-overlapping windows of the
    /// shortest trigger spacing, starting at each trigger that fits.
    struct EpochGeometry: Sendable {
        let starts: [Int]
        let length: Int
        var scan: Range<Int> { starts.first!..<(starts.last! + length) }
    }

    static func epochGeometry(triggers: [Int], sampleCount n: Int) -> EpochGeometry? {
        guard n > 0 else { return nil }
        let sorted = Array(Set(triggers.filter { $0 >= 0 && $0 < n })).sorted()
        guard sorted.count >= 3 else { return nil }
        var length = Int.max
        for i in 1..<sorted.count { length = min(length, sorted[i] - sorted[i - 1]) }
        guard length >= 8 else { return nil }
        let starts = sorted.filter { $0 + length <= n }
        guard starts.count >= 3 else { return nil }
        return EpochGeometry(starts: starts, length: length)
    }

    /// Per-channel TR-locked excess share (0-based channel index), broadband
    /// and in-band. Flat channels, and channels in `excludedChannels`, are
    /// omitted.
    static func residualFractions(
        output: [[Float]],
        geometry: EpochGeometry,
        samplingRate: Double,
        excludedChannels: Set<Int> = []
    ) -> [(channel: Int, broadband: Double, inBand: Double?)] {
        let canSplit = samplingRate > 2.5 * inBandCutoffHz
        var fractions: [(channel: Int, broadband: Double, inBand: Double?)] = []
        for channel in output.indices where !excludedChannels.contains(channel) {
            let y = output[channel].map(Double.init)
            guard let broadband = lockedExcess(y, geometry) else { continue }
            let inBand = canSplit
                ? lockedExcess(lowPassed(y, cutoffHz: inBandCutoffHz, samplingRate: samplingRate), geometry)
                : nil
            fractions.append((channel, broadband, inBand))
        }
        return fractions
    }

    /// Share of a signal's in-scan energy that sits above the flat floor of its
    /// TR-phase variance profile.
    ///
    /// Only the scan's overall mean is removed. Centring each epoch, or
    /// high-passing first, both look like they would help with slow brain
    /// activity and both hurt: centring makes a slow signal swing widest at the
    /// epoch edges (a false TR-locked shape), and a high-pass smears a
    /// one-sample residue across neighbouring phases. Slow activity that is left
    /// alone is not TR-locked, so it only raises the flat floor.
    static func lockedExcess(_ y: [Double], _ geometry: EpochGeometry) -> Double? {
        let length = geometry.length
        let starts = geometry.starts
        var mean = 0.0
        for t in geometry.scan { mean += y[t] }
        mean /= Double(geometry.scan.count)
        var profile = [Double](repeating: 0, count: length)
        for start in starts {
            for k in 0..<length {
                let v = y[start + k] - mean
                profile[k] += v * v
            }
        }
        let count = Double(starts.count)
        for k in 0..<length { profile[k] /= count }
        let total = profile.reduce(0, +) / Double(length)
        guard total > 0 else { return nil }
        // Under a flat profile each phase's variance is σ²·χ²_N/N, so its
        // quartile sits below σ² by a known amount. Wilson–Hilferty gives that
        // quartile; dividing it out makes the floor an unbiased σ².
        let n = count
        let wh = 1 - 2 / (9 * n) - 0.6745 * (2 / (9 * n)).squareRoot()
        let expectedQuartile = max(0.05, wh * wh * wh)
        let floor = percentile(profile.sorted(), 0.25) / expectedQuartile
        return max(0, 1 - floor / total)
    }

    static func lowPassed(_ x: [Double], cutoffHz: Double, samplingRate: Double) -> [Double] {
        zeroPhaseButterworth(x, cutoffHz: cutoffHz, samplingRate: samplingRate, highPass: false)
    }

    /// Zero-phase 4th-order Butterworth (a 2nd-order section run forward and
    /// backward), with odd-reflection padding for the transients.
    static func zeroPhaseButterworth(
        _ x: [Double], cutoffHz: Double, samplingRate: Double, highPass: Bool
    ) -> [Double] {
        guard x.count > 8, cutoffHz > 0, cutoffHz < samplingRate / 2 else { return x }
        let warped = tan(Double.pi * cutoffHz / samplingRate)
        let root2 = 2.0.squareRoot()
        let norm = 1 / (1 + root2 * warped + warped * warped)
        let b0 = highPass ? norm : warped * warped * norm
        let b1 = highPass ? -2 * b0 : 2 * b0
        let b2 = b0
        let a1 = 2 * (warped * warped - 1) * norm
        let a2 = (1 - root2 * warped + warped * warped) * norm
        let pad = min(x.count - 1, Int((3 * samplingRate / cutoffHz).rounded(.up)))
        var extended = [Double]()
        extended.reserveCapacity(x.count + 2 * pad)
        for i in stride(from: pad, through: 1, by: -1) { extended.append(2 * x[0] - x[i]) }
        extended.append(contentsOf: x)
        let last = x.count - 1
        for i in 1...pad { extended.append(2 * x[last] - x[last - i]) }
        func run(_ s: inout [Double]) {
            var x1 = s[0], x2 = s[0], y1 = s[0], y2 = s[0]
            for i in s.indices {
                let x0 = s[i]
                let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                s[i] = y0
                x2 = x1; x1 = x0; y2 = y1; y1 = y0
            }
        }
        run(&extended)
        extended.reverse()
        run(&extended)
        extended.reverse()
        return Array(extended[pad..<(pad + x.count)])
    }

    /// Linear-interpolated percentile of an ascending array.
    static func percentile(_ ascending: [Double], _ q: Double) -> Double {
        guard !ascending.isEmpty else { return 0 }
        let position = q * Double(ascending.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(ascending.count - 1, lower + 1)
        let w = position - Double(lower)
        return ascending[lower] * (1 - w) + ascending[upper] * w
    }
}

nonisolated enum GradientRunGrade {

    // MARK: Bands (GradientRunGradeMeasurementTests; see the provenance doc)

    /// TR-locked residual share (broadband, p90 across channels) below which
    /// the correction left no residue worth mentioning. Every simulated run
    /// whose true residual stayed below the brain's own variance read ≤ 0.07;
    /// at 0.10 the metric flagged 121 of 122 runs whose residual exceeded it.
    static let residualGoodCeiling = 0.10
    /// At or above this, residue dominates what is left (116 of 122 truth-poor
    /// runs, none of the good ones).
    static let residualPoorFloor = 0.30
    /// Removed-variance fraction below which the artifact was largely left in
    /// place: every simulated run that corrected well removed ≥ 0.999, every
    /// failure the residual metric could not see removed ≤ 0.64.
    static let removedVariancePoorCeiling = 0.90
    /// At or above this the run removed more than the recording carried — a
    /// template subtracted where there was no artifact (Allen IAR with dropped
    /// markers reached 2–4).
    static let removedVariancePoorFloor = 1.05
    /// Corrected-epoch fraction at or above which coverage is complete enough.
    static let coverageGoodFloor = 0.98
    /// Below this, a visible stretch of the scan was left uncorrected.
    static let coveragePoorCeiling = 0.90

    static func grade(from metrics: GradientRunMetrics) -> StepQuality {
        let graded = [residualMetric(metrics), removedMetric(metrics), coverageMetric(metrics)]
        let overall = graded.map(\.grade).max() ?? .good
        return StepQuality(grade: overall, summary: summary(overall, graded), metrics: graded)
    }

    private static func removedMetric(_ m: GradientRunMetrics) -> QualityMetric {
        let value = m.removedVarianceFraction
        let text = String(format: "%.3f of the scan's variance", value)
        if value < removedVariancePoorCeiling {
            return QualityMetric(name: "Removed variance", grade: .poor,
                                 detail: text + " — the artifact was largely left in place; check the TR markers and the amplifier's anti-alias filter.")
        }
        if value >= removedVariancePoorFloor {
            return QualityMetric(name: "Removed variance", grade: .poor,
                                 detail: text + " — more than the recording carried; a template was subtracted where there was no artifact.")
        }
        return QualityMetric(name: "Removed variance", grade: .good, detail: text + ".")
    }

    private static func residualMetric(_ m: GradientRunMetrics) -> QualityMetric {
        let value = m.residualFractionP90
        let grade: RunGrade
        if value >= residualPoorFloor { grade = .poor }
        else if value >= residualGoodCeiling { grade = .watch }
        else { grade = .good }
        let worst = m.worstChannel.map { String(format: "; worst channel %d at %.0f%%", $0 + 1, 100 * m.residualFractionMax) } ?? ""
        let inBand = m.inBandResidualFractionP90.map { String(format: "; %.0f%% below 40 Hz", 100 * $0) } ?? ""
        let tail: String
        switch grade {
        case .good: tail = "."
        case .watch: tail = " — some gradient residue remains."
        case .poor: tail = " — much of what is left is still gradient artifact."
        }
        return QualityMetric(
            name: "Residual artifact", grade: grade,
            detail: String(format: "%.0f%% of the corrected scan is locked to the TR (90th pct. of %d channels)",
                           100 * value, m.gradedChannelCount) + worst + inBand + tail)
    }

    private static func coverageMetric(_ m: GradientRunMetrics) -> QualityMetric {
        let fraction = m.correctedEpochFraction
        let grade: RunGrade
        if fraction < coveragePoorCeiling { grade = .poor }
        else if fraction < coverageGoodFloor { grade = .watch }
        else { grade = .good }
        let left = m.totalEpochs - m.correctedEpochs
        let tail = left > 0 ? " — \(left) left uncorrected (see the run details)." : "."
        return QualityMetric(
            name: "Epoch coverage", grade: grade,
            detail: "\(m.correctedEpochs) of \(m.totalEpochs) epochs corrected\(tail)")
    }

    private static func summary(_ overall: RunGrade, _ metrics: [QualityMetric]) -> String {
        switch overall {
        case .good:
            return "Clean gradient correction."
        case .watch:
            let reasons = metrics.filter { $0.grade == .watch }.map(\.name.localizedLowercase)
            return "Corrected, but worth a look (" + reasons.joined(separator: ", ") + ")."
        case .poor:
            return "Gradient artifact remains. Check the TR marker and slice count; without clock sync, sub-sample jitter leaves residue at any setting."
        }
    }
}
