//
//  ChannelDecisionSteps.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The two per-recording channel decisions — which channels were marked bad, and
//  which were repaired by interpolation — as `eva.xml` steps.
//
//  ## Why this exists
//
//  `EVAProcessingStep.Operation` has declared `markBad` and `interpolateChannels`
//  since the enum was written, and **nothing ever emitted either one**. The
//  REWIND determinism audit found it: those decisions reached disk only as prose
//  in `log_eva_*.txt`, so a package could not tell you which channels its
//  operator had judged unusable without a human reading a log. It is the largest
//  remaining hole in `REWIND.md` work item 4, and it is why the history rail
//  cannot show the `mark bad · 4 ch` node that this design's own figure has in it.
//
//  ## Provenance only, deliberately
//
//  Both steps are emitted with `replayable: false`. Bad channels and
//  interpolation are judgements about *this* recording's electrodes; replaying
//  them onto another subject would interpolate channels that may be perfectly
//  good there. Making them replayable is a product decision, not a serialization
//  one, and it should be made on purpose rather than as a side effect of finally
//  writing them down.
//
//  One consequence worth knowing: because they do not replay, **their position in
//  the script is presentational today**. That matters when someone makes them
//  replayable, because the position below is not obviously right —
//  see `inserted(into:…)`.
//
//  ## Channel numbering
//
//  Steps carry **1-based** channel numbers, matching `log_eva_*.txt` and every
//  label in the UI, while `ChannelModel` stores 0-based indices. The conversion
//  happens here, once, in both directions.
//

import Foundation

nonisolated enum ChannelDecisionSteps {

    static let methodParameterValue = "sphericalSpline"

    /// The steps describing `badChannels` and `interpolatedChannels`. Either may
    /// be absent; an empty set produces no step rather than a step with an empty
    /// list, so a recording with no bad channels reads as having no such stage.
    ///
    /// The two sets are disjoint by construction: interpolating a channel removes
    /// it from `bad` (`WaveformView.interpolateChannel`). Together they are the
    /// full set of channels the operator judged unusable — `interpolateChannels`
    /// the ones that were repaired, `markBad` the ones that were not.
    static func steps(
        badChannels: Set<Int>,
        interpolatedChannels: Set<Int>
    ) -> [EVAProcessingStep] {
        var steps: [EVAProcessingStep] = []

        if !badChannels.isEmpty {
            steps.append(EVAProcessingStep(
                operation: .markBad,
                parameters: ["channels": channelList(badChannels)],
                replayable: false,
                note: "Bad-channel marks are judgements about this recording's electrodes."
            ))
        }

        if !interpolatedChannels.isEmpty {
            steps.append(EVAProcessingStep(
                operation: .interpolateChannels,
                parameters: [
                    "channels": channelList(interpolatedChannels),
                    "method": methodParameterValue
                ],
                replayable: false,
                note: "Interpolated channels are specific to this recording's electrodes."
            ))
        }

        return steps
    }

    /// Returns `script` with the channel-decision steps inserted **immediately
    /// before the first `segment` step**, or appended when the script has none.
    ///
    /// Both are true of that position:
    ///
    /// - It is right for `interpolateChannels`. `currentMFFExportSnapshot()`
    ///   applies interpolation to the continuous signal after every cleaning
    ///   stage and before epoching, which is exactly here.
    /// - It is **not obviously right for `markBad`**, and this is the thing to
    ///   revisit before making these replayable. Bad marks are ambient state, not
    ///   a positioned transform: wavelet reduction reads `channels.bad` as its
    ///   excluded set, and that runs *upstream* of this position. A truthful
    ///   linear script would need bad marks before the first stage that consults
    ///   them. Recording them here is honest as provenance — the export did have
    ///   these channels marked — but a replay engine that trusted the position
    ///   would exclude nothing from a wavelet pass it should have.
    ///
    /// Idempotent: a script that already carries these steps is returned with the
    /// old ones dropped first, so passing a script through twice does not
    /// duplicate them.
    static func inserted(
        into script: EVAProcessingScript,
        badChannels: Set<Int>,
        interpolatedChannels: Set<Int>
    ) -> EVAProcessingScript {
        var result = script
        result.steps.removeAll { $0.operation == .markBad || $0.operation == .interpolateChannels }

        let decisions = steps(badChannels: badChannels, interpolatedChannels: interpolatedChannels)
        guard !decisions.isEmpty else { return result }

        let position = result.steps.firstIndex { $0.operation == .segment } ?? result.steps.count
        result.steps.insert(contentsOf: decisions, at: position)
        return result
    }

    // MARK: - Encoding

    /// Sorted, 1-based, comma separated: `"8,21,64"`.
    static func channelList(_ indices: Set<Int>) -> String {
        indices.sorted().map { String($0 + 1) }.joined(separator: ",")
    }

    /// Inverse of `channelList` — back to 0-based indices.
    ///
    /// Ignores entries that are not positive integers rather than failing the
    /// whole list: a single malformed number in someone's hand-edited `eva.xml`
    /// should not silently discard every other channel in it.
    static func channelIndices(from list: String) -> Set<Int> {
        Set(list.split(separator: ",").compactMap { field in
            guard let number = Int(field.trimmingCharacters(in: .whitespaces)), number > 0 else { return nil }
            return number - 1
        })
    }
}
