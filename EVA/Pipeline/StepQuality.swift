//
//  StepQuality.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  A run-quality grade for a processing step — the process-side counterpart to
//  `ChannelHealthResult`, and deliberately the same shape: one headline grade, a
//  one-line summary, and the weighted metrics that produced it. The history rail
//  shows the grade as a pill beside a node; the status popover expands it into
//  the metric breakdown, exactly as channel health does per channel.
//
//  Generic on purpose (SI-4 Track 3): producers are `PCASRunGrade`,
//  `GradientRunGrade`, `ICARunGrade`, and `ArtifactCleanRunGrade`, and
//  `RecordingHistoryModel.quality(for:in:)` picks one by the node's own step,
//  so the type carries no method-specific vocabulary.
//

import Foundation

/// Three-level run grade, matching `ChannelHealthGrade`'s Good/Watch/Poor so the
/// whole app reads one scale. `Comparable` by severity, so an overall grade is
/// just the worst of a step's metrics.
nonisolated enum RunGrade: String, Codable, Sendable, Equatable, Comparable, CaseIterable {
    case good
    case watch
    case poor

    var severity: Int {
        switch self {
        case .good: return 0
        case .watch: return 1
        case .poor: return 2
        }
    }

    static func < (lhs: RunGrade, rhs: RunGrade) -> Bool { lhs.severity < rhs.severity }

    var displayName: String {
        switch self {
        case .good: return "Good"
        case .watch: return "Watch"
        case .poor: return "Poor"
        }
    }
}

/// One graded facet of a run, e.g. "Accepted beats". The counterpart to
/// `ChannelHealthMetric`; `detail` is the human sentence shown under the bar.
nonisolated struct QualityMetric: Codable, Sendable, Equatable, Hashable, Identifiable {
    var name: String
    var grade: RunGrade
    var detail: String
    /// `nil` when the metric was never reached — e.g. a refusal that stopped at
    /// an earlier gate. Rendered as "n/a" rather than as a graded bar.
    var reached: Bool

    var id: String { name }

    init(name: String, grade: RunGrade, detail: String, reached: Bool = true) {
        self.name = name
        self.grade = grade
        self.detail = detail
        self.reached = reached
    }
}

/// A processing step's run quality: the pill on the rail and its breakdown.
nonisolated struct StepQuality: Codable, Sendable, Equatable, Hashable {
    var grade: RunGrade
    var summary: String
    var metrics: [QualityMetric]

    init(grade: RunGrade, summary: String, metrics: [QualityMetric]) {
        self.grade = grade
        self.summary = summary
        self.metrics = metrics
    }

    /// Overall grade as the worst of the reached metrics. Used when a producer
    /// builds metrics first and wants the headline to follow from them.
    init(summary: String, metrics: [QualityMetric]) {
        self.grade = metrics.filter(\.reached).map(\.grade).max() ?? .good
        self.summary = summary
        self.metrics = metrics
    }
}
