//
//  GradientCoverage.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  What a gradient run actually covered, per epoch and per volume (ROADMAP
//  MRI-1). The engines already record *that* an epoch went uncorrected; this
//  says *why*, and separates the two answers that used to share one counter:
//
//  - **Normal edges.** An epoch whose window runs past the recording, and the
//    volumes the operator trimmed with skip-start/skip-end, are uncorrected by
//    construction. Nothing failed; they are reported, never flagged.
//  - **Failures and fallbacks.** An epoch left uncorrected because no donor
//    qualified or the template carried no energy, or one corrected from donors
//    taken across a motion barrier, is a stretch of data whose correction
//    cannot be trusted. Those merge into duration-bearing
//    `MRI_GRAD_UNRELIABLE` events, which PSA can reject on.
//
//  Between the two sits `watch`: the engine took a documented, benign fallback
//  (a rejected template scale replaced from neighbours, correlation ranking
//  falling back to temporal neighbours). Reported and graded Watch, never turned
//  into an event — the correction is still a correction (owner, 2026-09-26).
//
//  Built from the diagnostics the engines already return, so no engine changes
//  and no CPU/GPU parity question: both backends report identical decisions.
//

import Foundation

nonisolated enum GradientCoverageStatus: Int, Sendable, Comparable, CaseIterable {
    case corrected
    /// Past the recording's edge — normal, not a failure.
    case edge
    /// Corrected through a benign documented fallback.
    case watch
    /// Corrected, but from donors the method should not have used.
    case unreliable
    /// Left uncorrected for a reason other than the recording's edge.
    case failed

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Whether this stretch of data is marked unreliable for PSA.
    var isUnreliable: Bool { self == .unreliable || self == .failed }

    var name: String {
        switch self {
        case .corrected: return "corrected"
        case .edge: return "edge"
        case .watch: return "watch"
        case .unreliable: return "unreliable"
        case .failed: return "failed"
        }
    }
}

/// One artifact epoch, on the recording's own sample axis.
nonisolated struct GradientEpochCoverage: Sendable, Equatable {
    var epoch: Int
    var volume: Int
    /// First sample of the epoch window, clamped to the recording.
    var startSample: Int
    /// One past the last sample, clamped to the recording.
    var endSample: Int
    var status: GradientCoverageStatus
    /// Short machine-readable reasons (`noEligibleDonors`, …); empty when
    /// `status == .corrected`.
    var reasons: [String]
}

/// A merged run of unreliable epochs.
nonisolated struct GradientUnreliableSpan: Sendable, Equatable {
    var startSample: Int
    var endSample: Int
    var epochCount: Int
    /// Reason → epochs in this span carrying it.
    var reasons: [String: Int]
}

nonisolated struct GradientCoverage: Sendable, Equatable {

    /// The event code `MRI_GRAD_UNRELIABLE` spans are written with.
    static let unreliableEventCode = "MRI_GRAD_UNRELIABLE"
    static let unreliableEventLabel = "MRI correction unreliable"
    /// `sourceFile` of the emitted events, so they are recognisable as EVA's own.
    static let eventSourceFile = "EVA Gradient Coverage"

    var epochs: [GradientEpochCoverage]
    /// Volumes the engine was handed.
    var volumeCount: Int
    /// Volumes dropped before correction by skip-start / skip-end.
    var trimmedLeadingVolumes: Int = 0
    var trimmedTrailingVolumes: Int = 0
    /// Run-level conditions worth a Watch grade that belong to no one epoch.
    var runNotes: [String] = []

    /// Worst status of any epoch in each volume, indexed by volume.
    var volumeStatuses: [GradientCoverageStatus] {
        var statuses = [GradientCoverageStatus](repeating: .corrected, count: volumeCount)
        for epoch in epochs where statuses.indices.contains(epoch.volume) {
            statuses[epoch.volume] = max(statuses[epoch.volume], epoch.status)
        }
        return statuses
    }

    func epochCount(_ status: GradientCoverageStatus) -> Int {
        epochs.filter { $0.status == status }.count
    }

    /// Epochs a correction could have been expected to reach: everything but
    /// the edges.
    var gradableEpochCount: Int { epochs.count - epochCount(.edge) }

    /// Consecutive unreliable epochs merged into spans. Epochs merge when their
    /// windows touch or overlap, so the slice epochs of one volume become one
    /// span and a gap of good data splits two.
    var unreliableSpans: [GradientUnreliableSpan] {
        var spans: [GradientUnreliableSpan] = []
        for epoch in epochs.sorted(by: { $0.startSample < $1.startSample })
        where epoch.status.isUnreliable && epoch.endSample > epoch.startSample {
            if var last = spans.last, epoch.startSample <= last.endSample {
                last.endSample = max(last.endSample, epoch.endSample)
                last.epochCount += 1
                for reason in epoch.reasons { last.reasons[reason, default: 0] += 1 }
                spans[spans.count - 1] = last
            } else {
                var reasons: [String: Int] = [:]
                for reason in epoch.reasons { reasons[reason, default: 0] += 1 }
                spans.append(GradientUnreliableSpan(
                    startSample: epoch.startSample, endSample: epoch.endSample,
                    epochCount: 1, reasons: reasons))
            }
        }
        return spans
    }

    /// The spans as onset-anchored, duration-bearing events.
    func unreliableEvents(samplingRate: Double) -> [MFFEvent] {
        guard samplingRate > 0 else { return [] }
        return unreliableSpans.map { span in
            let onset = Double(span.startSample) / samplingRate
            let duration = Double(span.endSample - span.startSample) / samplingRate
            let detail = span.reasons.keys.sorted()
                .map { "\(Self.reasonDescription($0)) (\(span.reasons[$0] ?? 0))" }
                .joined(separator: "; ")
            return MFFEvent(
                id: "mri-grad-unreliable-\(span.startSample)-\(span.endSample)",
                code: Self.unreliableEventCode,
                label: Self.unreliableEventLabel,
                eventDescription: "\(span.epochCount) epoch\(span.epochCount == 1 ? "" : "s"): \(detail)",
                beginTimeSeconds: onset,
                rawBeginTime: String(format: "%.6f", onset),
                sourceFile: Self.eventSourceFile,
                durationSeconds: duration,
                timeAnchor: .onset
            )
        }
    }

    /// `signal`'s events with any previous run's unreliable spans replaced by
    /// `newEvents`. A re-run describes the data it produced, not the union with
    /// a run that no longer exists.
    static func replacingUnreliableEvents(
        in events: [MFFEvent], with newEvents: [MFFEvent]
    ) -> [MFFEvent] {
        (events.filter { $0.code != unreliableEventCode } + newEvents)
            .sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
    }

    /// Audit-log lines, in the export writer's `"<operation> <kind>: …"` style.
    func auditLogLines(operation: String, samplingRate: Double) -> [String] {
        let statuses = volumeStatuses
        func volumes(_ s: GradientCoverageStatus) -> Int { statuses.filter { $0 == s }.count }
        var lines = [
            "\(operation) coverage: volumes=\(volumeCount), corrected=\(volumes(.corrected)), "
            + "edge=\(volumes(.edge)), watch=\(volumes(.watch)), unreliable=\(volumes(.unreliable)), "
            + "failed=\(volumes(.failed)), trimmedLeading=\(trimmedLeadingVolumes), "
            + "trimmedTrailing=\(trimmedTrailingVolumes)"
        ]
        let spans = unreliableSpans
        if !spans.isEmpty, samplingRate > 0 {
            let seconds = spans.reduce(0.0) { $0 + Double($1.endSample - $1.startSample) } / samplingRate
            let shown = spans.prefix(10).map {
                String(format: "%.3f–%.3f s", Double($0.startSample) / samplingRate, Double($0.endSample) / samplingRate)
            }.joined(separator: ", ")
            lines.append(
                "\(operation) unreliable: spans=\(spans.count), seconds="
                + String(format: "%.3f", seconds) + " (\(shown)\(spans.count > 10 ? ", …" : ""))"
            )
        }
        for note in runNotes {
            lines.append("\(operation) watch: \(note)")
        }
        return lines
    }

    static func reasonDescription(_ reason: String) -> String {
        switch reason {
        case "noEligibleDonors": return "no eligible donors"
        case "degenerateTemplate": return "template carried no energy"
        case "donorsCrossedMotionBarrier": return "donors taken across a motion event"
        case "templateScaleRejected": return "template scale replaced from neighbours"
        case "correlationDonorsFellBack": return "correlation ranking fell back to neighbours"
        case "insufficientDonors": return "too few donors"
        case "noTemplateSamples": return "no template samples"
        case "noCorrelatedDonors": return "no donor met the correlation floor"
        case "outsideRecording", "epochOutOfBounds": return "past the recording edge"
        case "uncorrected": return "left uncorrected"
        case "missingTrigger": return "TR marker missing; left uncorrected"
        default: return reason
        }
    }

    // MARK: - Missing markers

    /// Stretches where one or more TR markers are missing: a trigger interval
    /// longer than `GradientEpochLayout.missingTriggerGapFactor` × the median.
    ///
    /// Every engine corrects the TR that follows each marker it has, so the
    /// TRs whose markers are missing are corrected by nobody — their artifact is
    /// still in the data at full amplitude — and until 2026-09-26 no report said
    /// so, because there was no epoch to report on (ROADMAP MRI-1). The gap runs
    /// from one median TR after the marker before it to the marker after it.
    ///
    /// - Parameter triggers: TR samples on the recording's own axis.
    static func missingTriggerGaps(triggers: [Int]) -> [(start: Int, end: Int, missing: Int)] {
        let sorted = Array(Set(triggers)).sorted()
        guard sorted.count >= 3 else { return [] }
        let intervals = zip(sorted, sorted.dropFirst()).map { $1 - $0 }
        let typical = intervals.sorted()[intervals.count / 2]
        guard typical > 0 else { return [] }
        var gaps: [(start: Int, end: Int, missing: Int)] = []
        for (index, interval) in intervals.enumerated()
        where Double(interval) > GradientEpochLayout.missingTriggerGapFactor * Double(typical) {
            let missing = max(1, Int((Double(interval) / Double(typical)).rounded()) - 1)
            gaps.append((sorted[index] + typical, sorted[index + 1], missing))
        }
        return gaps
    }

    /// Adds `missingTriggerGaps` as failed stretches and a run-level note, so
    /// they become `MRI_GRAD_UNRELIABLE` spans and a Watch in the run grade.
    mutating func addMissingTriggerGaps(triggers: [Int], sampleCount: Int) {
        let gaps = Self.missingTriggerGaps(triggers: triggers)
        guard !gaps.isEmpty else { return }
        for gap in gaps {
            let start = min(max(gap.start, 0), sampleCount)
            let end = min(max(gap.end, 0), sampleCount)
            guard end > start else { continue }
            // No epoch or volume index: nothing was built here. `volume: -1`
            // keeps these out of the per-volume roll-up.
            epochs.append(GradientEpochCoverage(
                epoch: -1, volume: -1, startSample: start, endSample: end,
                status: .failed, reasons: ["missingTrigger"]))
        }
        let missing = gaps.reduce(0) { $0 + $1.missing }
        runNotes.append(
            "\(missing) TR marker\(missing == 1 ? "" : "s") appear\(missing == 1 ? "s" : "") to be missing "
            + "(\(gaps.count) gap\(gaps.count == 1 ? "" : "s") longer than "
            + String(format: "%.1f", GradientEpochLayout.missingTriggerGapFactor)
            + "× the median TR); those TRs were left uncorrected and are marked \(Self.unreliableEventCode)")
    }

    // MARK: - Builders

    /// Coverage for the two engines that return `GradientCorrectionDiagnostics`.
    ///
    /// - Parameters:
    ///   - sampleCount: samples in the recording, on its own (not upsampled) axis.
    static func from(
        diagnostics: GradientCorrectionDiagnostics,
        sampleCount: Int,
        usesMotionInformedDonors: Bool = false
    ) -> GradientCoverage {
        let factor = max(1, diagnostics.upsampleFactor)
        var reasonsByEpoch: [Int: [String]] = [:]
        var runNotes: [String] = []
        for warning in diagnostics.warnings {
            switch warning {
            case .epochOutOfBounds(let epoch): reasonsByEpoch[epoch, default: []].append("epochOutOfBounds")
            case .noEligibleDonors(let epoch): reasonsByEpoch[epoch, default: []].append("noEligibleDonors")
            case .degenerateTemplate(let epoch): reasonsByEpoch[epoch, default: []].append("degenerateTemplate")
            case .templateScaleRejected(let epoch): reasonsByEpoch[epoch, default: []].append("templateScaleRejected")
            case .donorsCrossedMotionBarrier(let epoch):
                reasonsByEpoch[epoch, default: []].append("donorsCrossedMotionBarrier")
            case .correlationDonorsFellBack(let epoch):
                reasonsByEpoch[epoch, default: []].append("correlationDonorsFellBack")
            case .motionRowsFrontPadded(let count):
                runNotes.append("motion file was \(count) row\(count == 1 ? "" : "s") short and was front-padded with zero motion; check it belongs to this run")
            case .motionRowsTruncated(let count):
                runNotes.append("motion file had \(count) extra row\(count == 1 ? "" : "s"), ignored; check it belongs to this run")
            case .noSupraThresholdMotion where usesMotionInformedDonors:
                runNotes.append("no volume exceeded the motion threshold, so Moosmann ran as plain nearest-neighbour averaging")
            default:
                break
            }
        }

        let epochs = diagnostics.epochs.map { record -> GradientEpochCoverage in
            let reasons = reasonsByEpoch[record.epoch] ?? []
            let status: GradientCoverageStatus
            if !record.corrected {
                status = reasons.contains("epochOutOfBounds") ? .edge : .failed
            } else if reasons.contains("donorsCrossedMotionBarrier") {
                status = .unreliable
            } else if !reasons.isEmpty {
                status = .watch
            } else {
                status = .corrected
            }
            let first = record.trigger - diagnostics.samplesBefore
            let last = record.trigger + diagnostics.samplesAfter
            let start = min(max(Int((Double(first) / Double(factor)).rounded(.down)), 0), sampleCount)
            let end = min(max(Int((Double(last + 1) / Double(factor)).rounded(.up)), 0), sampleCount)
            return GradientEpochCoverage(
                epoch: record.epoch,
                volume: record.volume,
                startSample: start,
                endSample: max(start, end),
                status: status,
                reasons: record.corrected || !reasons.isEmpty ? reasons : ["uncorrected"]
            )
        }
        let volumeCount = (diagnostics.epochs.map(\.volume).max() ?? -1) + 1
        return GradientCoverage(epochs: epochs, volumeCount: volumeCount, runNotes: runNotes)
    }

    /// Coverage for the local-template engine, whose diagnostics are per event.
    ///
    /// - Parameters:
    ///   - triggers: the TR samples the engine was handed. It de-duplicates and
    ///     sorts them itself, and indexes its events into that list, so the
    ///     same is done here.
    static func from(
        localSummaries: [LocalTemplateEventSummary],
        triggers: [Int],
        sampleCount: Int
    ) -> GradientCoverage {
        let sorted = Array(Set(triggers.filter { $0 >= 0 && $0 < sampleCount })).sorted()
        let intervals = zip(sorted, sorted.dropFirst()).map { $1 - $0 }.sorted()
        let length = intervals.isEmpty ? 0 : intervals[intervals.count / 2]
        let epochs = localSummaries.map { summary -> GradientEpochCoverage in
            let trigger = sorted.indices.contains(summary.eventIndex) ? sorted[summary.eventIndex] : 0
            let status: GradientCoverageStatus
            var reasons: [String] = []
            switch summary.skippedReason {
            case nil: status = .corrected
            case .outsideRecording?: status = .edge; reasons = ["outsideRecording"]
            case let reason?: status = .failed; reasons = [reason.rawValue]
            }
            let start = min(max(trigger, 0), sampleCount)
            let end = min(max(trigger + length, 0), sampleCount)
            return GradientEpochCoverage(
                epoch: summary.eventIndex, volume: summary.eventIndex,
                startSample: start, endSample: max(start, end),
                status: status, reasons: reasons)
        }
        return GradientCoverage(epochs: epochs, volumeCount: localSummaries.count)
    }
}
