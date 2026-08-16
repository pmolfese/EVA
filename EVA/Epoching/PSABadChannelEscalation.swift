//
//  PSABadChannelEscalation.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Promotes a channel that was bad in most epochs to *globally* bad, and
//  interpolates it across the whole recording.
//
//  Extracted from `WaveformView.escalateBadChannelsIfNeeded` because that lived
//  on the view, so the headless path could not run it. Measured consequence, from
//  the first same-file comparison (2026-08-13): an interactive run escalated and
//  interpolated Ch8/Ch21/Ch25 — bad in 85%, 64%, and 90% of 67 epochs — while the
//  batch run on the identical file left them raw and recorded no
//  `interpolateChannels result:` line at all. Same script, same input, different
//  averages and different provenance.
//
//  Same shape as `PipelineInvalidation` and `ProcessingAuditLog`: a free function
//  over explicitly-passed collaborators, so both the interactive and headless
//  callers share one implementation and the compiler names every call site when
//  the inputs change.
//

import SwiftUI

@MainActor
enum PSABadChannelEscalation {

    struct Outcome {
        /// Human-readable "Ch8: bad in 85% of epochs (57/67)" lines, for the
        /// audit log and the PSA summary. Populated even when interpolation is
        /// impossible, so the decision is always recorded.
        var summaries: [String] = []
        /// Per-channel success messages, for the interactive status line.
        var messages: [String] = []
        var errors: [String] = []
        /// The epoched signal with escalated channels patched in place, when that
        /// was possible. `nil` means the caller should leave its epochs alone.
        var patchedEpochedSignal: MFFSignalData?
        /// True when the epoched layout didn't match and the caller must
        /// invalidate its epochs instead of patching them.
        var requiresEpochInvalidation = false
        /// True when geometry was missing, so nothing could be interpolated.
        var lackedGeometry = false
    }

    /// Escalates every channel bad in at least `thresholdPercent`% of epochs.
    ///
    /// Escalated channels are removed from `channels.bad` and added to
    /// `channels.interpolated` (with their donor recipe), because after
    /// interpolation they carry reconstructed data rather than being excluded.
    static func escalate(
        counts: [Int: Int],
        totalEpochs: Int,
        isEnabled: Bool,
        thresholdPercent: Double,
        continuousSignal: MFFSignalData,
        epochedSignal: MFFSignalData?,
        positions: [Int: SIMD3<Double>],
        channels: ChannelModel
    ) async -> Outcome {
        var outcome = Outcome()

        guard isEnabled, totalEpochs > 0, !counts.isEmpty else { return outcome }

        let thresholdFraction = thresholdPercent / 100
        let toEscalate = counts
            .filter { Double($0.value) / Double(totalEpochs) >= thresholdFraction }
            .sorted { $0.key < $1.key }
        guard !toEscalate.isEmpty else { return outcome }

        outcome.summaries = toEscalate.map { channelIndex, count in
            let percent = Double(count) / Double(totalEpochs) * 100
            return "Ch\(channelIndex + 1): bad in \(String(format: "%.0f", percent))% of epochs (\(count)/\(totalEpochs))"
        }

        // Record the decision even when it can't be carried out — a headless run
        // with no geometry should still say which channels *would* have been
        // escalated rather than silently omitting them.
        guard !positions.isEmpty else {
            outcome.lackedGeometry = true
            return outcome
        }

        let targets = toEscalate.map(\.key)
        let excludedDonors = channels.bad.union(channels.interpolated.keys)

        let worker = Task.detached(priority: .userInitiated) {
            PSAGlobalBadChannelInterpolator.interpolate(
                targets: targets,
                continuousSignal: continuousSignal,
                epochedSignal: epochedSignal,
                excludedDonors: excludedDonors,
                positions: positions
            )
        }
        let results = await withTaskCancellationHandler(
            operation: { await worker.value },
            onCancel: { worker.cancel() }
        )

        guard !Task.isCancelled else { return outcome }

        let successful = results.filter(\.succeeded)
        outcome.errors = results.compactMap(\.errorMessage)

        var interpolated = channels.interpolated
        var interpolationSources = channels.interpolationSources
        var globalBadChannels = channels.bad

        for result in successful {
            guard let continuousSeries = result.continuousSeries else { continue }
            interpolated[result.target] = continuousSeries
            interpolationSources[result.target] = (result.indices, result.weights.map(Float.init))
            globalBadChannels.remove(result.target)
            outcome.messages.append(
                "Interpolated Ch \(result.target + 1) from \(result.indices.count) neighbors."
            )
        }

        guard !successful.isEmpty else { return outcome }

        channels.replaceInterpolations(interpolated, sources: interpolationSources)
        channels.bad = globalBadChannels

        // Averaging is linear, so applying the same interpolation weights to the
        // already-averaged epoched signal reproduces what re-running PSA after
        // interpolating would have produced — patch rather than discard.
        if let epochedSignal, successful.allSatisfy({ $0.epochedSeries != nil }) {
            var epochedData = epochedSignal.data
            for result in successful {
                if let series = result.epochedSeries, epochedData.indices.contains(result.target) {
                    epochedData[result.target] = series
                }
            }
            outcome.patchedEpochedSignal = epochedSignal.replacingSamples(epochedData)
        } else if epochedSignal != nil {
            // Stale or mismatched epoched layout — safer to invalidate.
            outcome.requiresEpochInvalidation = true
        }

        return outcome
    }
}
