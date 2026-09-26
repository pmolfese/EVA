//
//  ArtifactCleanRunGrade.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Turns a drawn-artifact cleaning into a `StepQuality` grade (ROADMAP §
//  Processing run-grade).
//
//  The event-windowed cleaners — regression, OBS, SSP/PCA, the local-template
//  family, per-event wavelet — rewrite the data inside each event's window and
//  leave the rest untouched, so the truth-free number a run can report is how
//  much of the recording it rewrote. `ArtifactCleanRunGradeMeasurementTests`
//  (docs/provenance/run-grade-calibration.md § Artifact clean) found:
//
//    * cleaning beats leaving the artifact at every density tested — 4–8× less
//      error even with 90 % of the recording touched — so there is no point at
//      which a run becomes Poor;
//    * but inside the windows it rewrites, 30–50 % of the brain's variance is
//      distorted, so the error it leaves grows with the touched fraction and
//      crosses a tenth of the brain's variance at 20–35 % touched. Watch from
//      20 %;
//    * pooled-basis methods (OBS, SSP/PCA) need events to estimate the basis:
//      6 events barely helped (1.1× less error), 20 did (4×). Watch below 20.
//
//  The continuous MAAC corrections (corneo-retinal regression, movement PCA,
//  BSS-CCA) touch every sample by design, so for a run that includes one the
//  touched fraction says nothing and is not graded. MAAC grading is deferred
//  with the rest of MAAC (ROADMAP § Processing run-grade).
//

import Foundation

nonisolated struct ArtifactCleanRunMetrics: Codable, Sendable, Equatable, Hashable {
    /// Fraction of time points at which any graded channel changed.
    var touchedFraction: Double
    /// `var(input − output) / var(input)`, pooled over graded channels.
    var removedVarianceFraction: Double
    var eventCount: Int
    /// Methods that actually ran, by display name.
    var methods: [String]
    /// A continuous (whole-recording) correction ran, so `touchedFraction` is
    /// ~1 by construction.
    var includesContinuousCorrection: Bool
    /// Fewest events behind any pooled-basis (OBS, SSP/PCA) artifact that ran;
    /// `nil` when none did.
    var minimumPooledBasisEventCount: Int?

    static func usesPooledBasis(_ method: ArtifactCleaningMethod) -> Bool {
        method == .obs || method == .sspPCA
    }

    /// Methods that correct the whole recording rather than event windows.
    static func isContinuous(_ method: ArtifactCleaningMethod) -> Bool {
        method == .corneoRetinalRegression || method == .movementPCA || method == .bssCCA
    }

    static func measure(
        original: [[Float]],
        cleaned: [[Float]],
        artifacts: [DefinedArtifact],
        summaries: [ArtifactCleaningSummary],
        excludedChannels: Set<Int>
    ) -> ArtifactCleanRunMetrics? {
        let n = original.first?.count ?? 0
        guard n > 0, cleaned.count == original.count else { return nil }
        var touched = [Bool](repeating: false, count: n)
        var numerator = 0.0, denominator = 0.0
        for channel in original.indices where !excludedChannels.contains(channel) {
            let x = original[channel], y = cleaned[channel]
            guard x.count == n, y.count == n else { continue }
            var meanX = 0.0, meanD = 0.0
            for t in 0..<n {
                meanX += Double(x[t])
                meanD += Double(x[t]) - Double(y[t])
            }
            meanX /= Double(n)
            meanD /= Double(n)
            for t in 0..<n {
                let change = Double(x[t]) - Double(y[t])
                if abs(change) > touchTolerance { touched[t] = true }
                let d = change - meanD
                let c = Double(x[t]) - meanX
                numerator += d * d
                denominator += c * c
            }
        }
        let ran = Set(summaries.map(\.artifactID))
        let used = artifacts.filter { ran.contains($0.id) }
        return ArtifactCleanRunMetrics(
            touchedFraction: Double(touched.lazy.filter { $0 }.count) / Double(n),
            removedVarianceFraction: denominator > 0 ? numerator / denominator : 0,
            eventCount: used.reduce(0) { $0 + $1.eventCount },
            methods: used.map(\.cleaningMethod.rawValue),
            includesContinuousCorrection: used.contains { isContinuous($0.cleaningMethod) },
            minimumPooledBasisEventCount: used.filter { usesPooledBasis($0.cleaningMethod) }.map(\.eventCount).min()
        )
    }

    /// Changes smaller than this (µV) are float round-off, not a rewrite.
    static let touchTolerance = 1e-4
}

nonisolated enum ArtifactCleanRunGrade {

    // MARK: Bands (ArtifactCleanRunGradeMeasurementTests)

    /// Touched fraction at or above which the grade reads Watch.
    static let touchedWatchFloor = 0.20
    /// Events below which a pooled-basis method's basis is poorly estimated.
    static let pooledBasisEventWatchFloor = 20

    static func grade(from m: ArtifactCleanRunMetrics) -> StepQuality {
        var metrics = [touchedMetric(m)]
        if let events = m.minimumPooledBasisEventCount {
            let grade: RunGrade = events < pooledBasisEventWatchFloor ? .watch : .good
            metrics.append(QualityMetric(
                name: "Events for OBS/SSP", grade: grade,
                detail: "\(events) event\(events == 1 ? "" : "s") behind the shared basis"
                    + (grade == .good ? "." : " — below \(pooledBasisEventWatchFloor), the basis is poorly estimated and cleaning helps little.")))
        }
        let overall = metrics.filter(\.reached).map(\.grade).max() ?? .good
        metrics.append(QualityMetric(
            name: "Removed variance", grade: .good,
            detail: String(format: "%.0f%% of the variance — reported, not graded.", 100 * m.removedVarianceFraction)))
        let summary = overall == .good
            ? "Local artifact repair."
            : "Cleaned, but worth a look (" + metrics.filter { $0.reached && $0.grade == .watch }
                .map(\.name.localizedLowercase).joined(separator: ", ") + ")."
        return StepQuality(grade: overall, summary: summary, metrics: metrics)
    }

    private static func touchedMetric(_ m: ArtifactCleanRunMetrics) -> QualityMetric {
        let name = "Recording touched"
        if m.includesContinuousCorrection {
            return QualityMetric(
                name: name, grade: .good,
                detail: String(format: "%.0f%% — a continuous correction ran, which touches every sample by design; not graded.",
                               100 * m.touchedFraction),
                reached: false)
        }
        let f = m.touchedFraction
        let grade: RunGrade = f >= touchedWatchFloor ? .watch : .good
        let tail = grade == .good
            ? "."
            : " — cleaning still beats leaving the artifact, but it distorts some of the brain signal wherever it rewrites, and that now adds up."
        return QualityMetric(
            name: name, grade: grade,
            detail: String(format: "%.0f%% of the recording (%d events)", 100 * f, m.eventCount) + tail)
    }
}
