//
//  ProcessingAuditLog.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  One definition of the subject-specific provenance written to `log_eva_*.txt`.
//
//  These lines are deliberately *not* in `eva.xml`: that file is the portable
//  script that Copy Processing replays, whereas these are this recording's
//  resulting decisions — which channels were bad, which were escalated and
//  interpolated, how many trials survived per category, and what the gradient run
//  excluded. None of it is recoverable from the exported samples, so if it is not
//  recorded here it is gone.
//
//  Extracted from `WaveformView.currentProcessingAuditLogLines()` because the
//  headless path could not reach it: `HeadlessBatchProcessor` called
//  `MFFExportWriter.write` without an `auditLogLines` argument at all, so a
//  batch-produced package carried only the three step lines and silently omitted
//  every result line an interactively-produced package has. Same failure shape as
//  the invalidation cascade (`PipelineInvalidation`) — logic that lived on the
//  view, so the headless path quietly did less.
//

import Foundation

@MainActor
enum ProcessingAuditLog {

    /// Subject-specific export audit details for `log_eva_*.txt`.
    ///
    /// View models are passed explicitly rather than reached through a
    /// coordinator, matching `PipelineInvalidation`: it keeps every input visible
    /// in the signature, so adding a stage that produces provenance forces the
    /// compiler to name each call site that must supply it.
    static func lines(
        gradient: GradientViewModel,
        epoching: EpochingViewModel,
        channels: ChannelModel,
        cleaningVariance: CleaningVarianceLedger
    ) -> [String] {
        var lines: [String] = []

        // What the gradient run excluded and why.
        lines.append(contentsOf: gradient.auditLogLines)

        // What each cleaning stage removed, in the order the stages ran. One
        // ledger rather than a question per stage: see `CleaningVarianceLedger`.
        lines.append(contentsOf: cleaningVariance.auditLogLines)

        if !epoching.skippedLabeledBadSegmentsSummary.isEmpty {
            lines.append("segment result: skippedLabeledBadSegments=\(epoching.skippedLabeledBadSegmentsSummary.joined(separator: "; "))")
        }
        if !epoching.epochBadChannelSummary.isEmpty {
            lines.append("segment result: perEpochBadChannels=\(epoching.epochBadChannelSummary.joined(separator: "; "))")
        }
        if !epoching.epochBadChannelAllSegmentsSummary.isEmpty {
            lines.append("segment result: badChannelsInAllKeptSegments=\(epoching.epochBadChannelAllSegmentsSummary.joined(separator: ", "))")
        }

        if !channels.interpolated.isEmpty {
            var fields = [
                "channels=\(channels.interpolated.keys.sorted().map { String($0 + 1) }.joined(separator: ","))"
            ]
            if !epoching.escalatedChannelSummaries.isEmpty {
                fields.append("escalatedFromPerEpochDetection=\(epoching.escalatedChannelSummaries.joined(separator: "; "))")
            }
            lines.append("interpolateChannels result: \(fields.joined(separator: ", "))")
        }

        // A repair that was recorded but could not be re-solved on this file.
        // It reads as its own line rather than as an absence from the
        // `interpolateChannels` list, because "we did not repair this channel"
        // and "we tried to repair this channel and could not" are different
        // facts about the output, and only the second one needs looking into
        // (ROADMAP RW-1 item 3).
        if !channels.interpolationLost.isEmpty {
            let fields = channels.interpolationLost.keys.sorted().map { index in
                "\(index + 1): \(channels.interpolationLost[index] ?? "")"
            }
            lines.append("interpolateChannels lost: \(fields.joined(separator: "; "))")
        }

        if !channels.bad.isEmpty {
            lines.append("markBad result: channels=\(channels.bad.sorted().map { String($0 + 1) }.joined(separator: ","))")
        }

        let categories = epoching.averageSNRByCategory.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        for category in categories {
            let metrics = epoching.averageSNRByCategory[category] ?? SNRMetrics()
            lines.append(snrLine(category: category, metrics: metrics))
        }

        return lines
    }

    private static func snrLine(category: String, metrics: SNRMetrics) -> String {
        func f(_ value: Double?, _ digits: Int = 2) -> String {
            guard let value, value.isFinite else { return "n/a" }
            return String(format: "%.\(digits)f", value)
        }
        var parts: [String] = ["trials=\(metrics.trialCount)"]
        parts.append("plusMinusSNR=\(f(metrics.plusMinusSNR))")
        parts.append("baselineSNR=\(f(metrics.baselineSNR))")
        parts.append("gfpSNR=\(f(metrics.gfpSNR))")
        parts.append("sme=\(f(metrics.standardizedMeasurementError, 3))")
        parts.append("splitHalfReliability=\(f(metrics.splitHalfReliability))")
        return "average SNR [\(category)]: \(parts.joined(separator: ", "))"
    }
}
