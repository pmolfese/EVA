// Developed by P. Molfese, National Institutes of Health (NIH).
// United States Government work; see the repository license.

import Foundation

/// A signal-based repeat check, not an estimate of anatomical slice count.
nonisolated struct GradientTimingAssessment: Codable, Sendable, Equatable, Hashable {
    enum Agreement: String, Codable, Sendable { case compatible, mismatch, inconclusive }
    var agreement: Agreement
    var expectedMilliseconds: Double?
    var observedMilliseconds: Double?
    var observedCorrelation: Double?
    var expectedCorrelation: Double?
    var needsFractionalAlignment: Bool
    var detail: String
    var warrantsReview: Bool { agreement == .mismatch || needsFractionalAlignment }
    var summary: String {
        let interval = expectedMilliseconds.map { String(format: "%.2f ms", $0) } ?? "unknown"
        if agreement == .mismatch, let observedMilliseconds {
            return String(format: "Possible timing mismatch: configured %@, measured repeat %.2f ms. Check slices, multiband factor and timing.", interval, observedMilliseconds)
        }
        if needsFractionalAlignment {
            let timing: String
            if agreement == .compatible, let observedMilliseconds {
                timing = String(format: "Group timing agrees: configured %@, measured %.2f ms. ", interval, observedMilliseconds)
            } else {
                timing = "Group timing is not verified. "
            }
            return timing + "Fractional timing support is off. Integer-only alignment can leave residue even with synchronized clocks; enable interpolation or sub-sample alignment."
        }
        if agreement == .compatible, let observedMilliseconds {
            return String(format: "Group timing agrees: configured %@, measured repeat %.2f ms. Check correction quality after processing.", interval, observedMilliseconds)
        }
        return "No confident repeat comparison; acquisition timing is not verified."
    }
}

nonisolated struct GradientTimingProbe: Sendable {
    var samplingRate: Double
    var trSeconds: Double
    var correlations: [Double]
    var observedLag: Int?
    var comparisons: Int

    func assess(schedule: GradientAcquisitionSchedule?, fractionalTiming: Bool) -> GradientTimingAssessment {
        func result(_ agreement: GradientTimingAssessment.Agreement, expected: Double? = nil,
                    expectedCorrelation: Double? = nil, fractional: Bool = false, _ text: String) -> GradientTimingAssessment {
            GradientTimingAssessment(agreement: agreement, expectedMilliseconds: expected.map { 1000 * $0 },
                observedMilliseconds: observedLag.map { 1000 * Double($0) / samplingRate },
                observedCorrelation: observedLag.map { correlations[$0] }, expectedCorrelation: expectedCorrelation,
                needsFractionalAlignment: fractional, detail: text)
        }
        guard let schedule, schedule.groupsPerVolume > 1 else {
            return result(.inconclusive, "Whole-volume templates do not assume a within-volume group interval.")
        }
        let interval: Double
        switch schedule {
        case .uniform(let count): interval = trSeconds / Double(count)
        case .offsetsSeconds(let offsets), .offsetsFractionOfTR(let offsets):
            let scale: Double
            if case .offsetsFractionOfTR = schedule { scale = trSeconds } else { scale = 1 }
            let differences = zip(offsets.dropFirst(), offsets).map { ($0 - $1) * scale }
            guard let first = differences.first, first > 0,
                  differences.allSatisfy({ abs($0 - first) <= 0.000001 }) else {
                return result(.inconclusive, "This nonuniform schedule has no single group interval to compare with a repeating waveform.")
            }
            // The wrap to the next TR can contain deliberate dead time; do not
            // mistake that longer interval for an extra acquisition group.
            interval = first
        }
        let samples = interval * samplingRate
        let fractional = samples.isFinite && abs(samples - samples.rounded()) > 0.000001 && !fractionalTiming
        let hint = fractional ? " The group interval is fractional at the EEG sampling rate. This can occur with synchronized clocks; use sub-sample alignment or internal upsampling for slice templates." : ""
        guard samples.isFinite, samples >= 1, samples < Double(correlations.count - 1),
              let observedLag, comparisons >= 6 else {
            return result(.inconclusive, expected: interval, fractional: fractional,
                "No confident gradient repeat could be compared with these settings. This is not evidence that the timing is correct." + hint)
        }
        let candidates = [Int(floor(samples)), Int(ceil(samples))]
        let expectedCorrelation = candidates.map { correlations[$0] }.max() ?? 0
        // A sub-sample difference can accumulate into many samples by the last
        // group. Correlation at a rounded lag alone would call a 90 ms schedule
        // compatible with a uniform 90.91 ms grid despite ~19 ms of end drift.
        let ratio = samples / Double(observedLag)
        let nearbyPeriodDisagrees = (0.8...1.25).contains(ratio) && abs(ratio - 1) > 0.005
        let mismatch = expectedCorrelation < 0.5 || nearbyPeriodDisagrees
        let text = String(format: "Configured groups: %.2f ms apart. Strongest early repeat: %.2f ms (r = %.2f). ",
                          interval * 1000, Double(observedLag) / samplingRate * 1000, correlations[observedLag])
        return result(mismatch ? .mismatch : .compatible, expected: interval,
                      expectedCorrelation: expectedCorrelation, fractional: fractional,
                      text + (mismatch
                        ? "Configured timing disagrees with the measured repeat. Check total slices, multiband factor and acquisition timing; alternating waveforms can also cause this warning. The repeat does not establish anatomical slice count."
                        : "The repeat is consistent with the configured interval; correction quality must still be checked.") + hint)
    }
}

nonisolated enum GradientTimingCheck {
    /// Bounded sampling across channels and the marked scan. FFT correlation
    /// avoids scanning the entire recording whenever a parameter is edited.
    static func measure(channels: [[Float]], triggers: [Int], samplingRate fs: Double) -> GradientTimingProbe? {
        guard fs.isFinite, fs >= 100, let n = channels.first?.count, n > 0 else { return nil }
        let tr = Array(Set(triggers.filter { $0 >= 0 && $0 < n })).sorted()
        guard tr.count >= 4 else { return nil }
        let gaps = zip(tr.dropFirst(), tr).map { $0 - $1 }.sorted()
        let period = gaps[gaps.count / 2]
        let maxLag = min(Int(fs * 0.25), period / 2, 2048)
        let minLag = max(2, Int(ceil(fs / 250)))
        guard maxLag > minLag + 2 else { return nil }
        let length = min(8 * period, Int(16 * fs))
        guard length > 4 * maxLag, n > length + 1 else { return nil }
        let channelIndices = Array(Set((0..<min(4, channels.count)).map {
            $0 * max(0, channels.count - 1) / max(1, min(4, channels.count) - 1)
        })).sorted()
        let starts = Array(Set([tr[tr.count / 4], tr[tr.count / 2], tr[3 * tr.count / 4]]))
        var measurements: [[Double]] = []
        for c in channelIndices {
            for start in starts {
                if Task.isCancelled { return nil }
                guard start + length < n, start + length <= tr.last! + period,
                      channels[c].count == n else { continue }
                let values = (0..<length).map { Double(channels[c][start + $0 + 1] - channels[c][start + $0]) }
                guard values.allSatisfy(\.isFinite) else { continue }
                let mean = values.reduce(0, +) / Double(length)
                let x = values.map { $0 - mean }
                let energy = x.reduce(0) { $0 + $1 * $1 }
                // Abstain on ordinary EEG/weak artifact rather than reporting a
                // physiological rhythm as a confident scanner repeat (µV input).
                guard energy / Double(length) >= 25 * 25 else { continue }
                var count = 1
                while count < 2 * length { count *= 2 }
                var re = x + [Double](repeating: 0, count: count - length)
                var im = [Double](repeating: 0, count: count)
                DSP.fft(re: &re, im: &im, inverse: false)
                for i in re.indices { re[i] = re[i] * re[i] + im[i] * im[i]; im[i] = 0 }
                DSP.fft(re: &re, im: &im, inverse: true)
                var sums = [Double](repeating: 0, count: length + 1)
                var squares = sums
                for i in x.indices { sums[i + 1] = sums[i] + x[i]; squares[i + 1] = squares[i] + x[i] * x[i] }
                var scores = [Double](repeating: 0, count: maxLag + 1)
                for lag in minLag...maxLag {
                    let size = Double(length - lag)
                    let a = sums[length - lag], b = sums[length] - sums[lag]
                    let va = squares[length - lag] - a * a / size
                    let vb = squares[length] - squares[lag] - b * b / size
                    if va > 0, vb > 0 {
                        // DSP.fft deliberately leaves the inverse unnormalized.
                        let cross = re[lag] / Double(count)
                        scores[lag] = max(-1, min(1, (cross - a * b / size) / sqrt(va * vb)))
                    }
                }
                measurements.append(scores)
            }
        }
        var scores = [Double](repeating: 0, count: maxLag + 1)
        for lag in minLag...maxLag {
            let sorted = measurements.map { $0[lag] }.sorted()
            if !sorted.isEmpty { scores[lag] = sorted[sorted.count / 2] }
        }
        // Earliest strong local maximum, not the largest harmonic. Require
        // corroboration in multiple windows/channels, not a single lucky match.
        let repeatLag = (minLag..<(maxLag - 1)).first { lag in
            measurements.count >= 6 && scores[lag] >= 0.9
                && scores[lag] > scores[lag - 1] && scores[lag] >= scores[lag + 1]
                && measurements.filter { $0[lag] >= 0.85 }.count * 4 >= measurements.count * 3
        }
        return GradientTimingProbe(samplingRate: fs, trSeconds: Double(period) / fs,
            correlations: scores, observedLag: repeatLag, comparisons: measurements.count)
    }
}
