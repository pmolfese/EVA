//
//  Rereferencing.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Re-referencing as one operation with one recorded step, instead of a `Bool`
//  hiding inside two other stages.
//
//  ## Why this stopped being a filter option
//
//  Average reference used to be `filter.averageReference` and
//  `epoching.averageReference` — two toggles, each serialized as a parameter of
//  the stage that happened to host it. Three things were wrong with that:
//
//  1. **It is the comparison people actually want to run.** Referenced versus not
//     is the classic A/B, and as a filter parameter, flipping it forks the history
//     at `filter` and recomputes a band-pass that did not change. As its own step
//     it forks *after* the filter, and both branches share one filter output
//     through copy-on-write.
//  2. **It reads the bad-channel set, and nothing said so.** The reference is the
//     mean of the good channels, so marking a channel bad changes the output of
//     every channel — while the `filter` step's parameters, and therefore its
//     node hash, recorded nothing. That is `REWIND.md`'s "channel decisions are
//     ambient" problem in its worst form, and the fix is to make the excluded set
//     an explicit parameter of an explicit step.
//  3. **Two toggles, one concept.** Ticking both referenced twice, silently.
//     Two steps in the rail is a thing you can see.
//
//  `EVAProcessingStep.Operation.reference` already existed and was never emitted;
//  this fills it in.
//
//  ## Why the domain is part of the step rather than two operations
//
//  Continuous and epoch re-referencing are genuinely different operations that
//  share an implementation. The continuous one is a free-standing transform on
//  the working signal. The epoch one happens *inside* the PSA fold, before
//  baseline correction and after trial rejection — so it sees a different channel
//  mean than a continuous pass would, because the trials that got dropped are not
//  in it. Collapsing them into one slot would change results.
//
//  That asymmetry shows up in where the step is emitted, and it is deliberate:
//
//  - `.continuous` is emitted **after** `filter`, the stage whose output it acts
//    on.
//  - `.epoch` is emitted **before** `segment`, because epoch referencing cannot
//    be performed from outside the fold that builds the average — it is a
//    setting the segmentation consumes rather than a pass of its own.
//
//  ## No interactive/headless split, by construction
//
//  Both directions apply the arithmetic in the same two places: continuous
//  inside `FilterViewModel`'s tail, on the band-passed buffer it already owns,
//  and epoch inside the PSA fold. What replay does is derive the *flags* from the
//  step list before anything runs (`ReplaySettingsRestore`) — so the step is a
//  record of a decision, not a second implementation of it.
//
//  That is deliberate. The first version applied a separate headless pass over
//  `filter.output`, which was correct only if you accepted an argument about
//  ordering, and was one line away from referencing twice. Every divergence this
//  project has found was hiding in exactly that kind of argument, so there is now
//  nothing to diverge.
//
//  What still wants a paired run is the *format* change: `averageReference` has
//  moved out of the `filter` and `segment` parameters into its own step, so
//  eva.xml differs from every file written before this. `signal1.bin` must not.
//
import Foundation

/// How the reference is computed. One case today; the point of the enum is that
/// adding linked-mastoid or single-channel references becomes a case and a
/// switch arm rather than another `Bool` on another view model.
nonisolated enum ReferenceScheme: String, Codable, Sendable, CaseIterable {
    case average

    var displayName: String {
        switch self {
        case .average: return "Average"
        }
    }
}

/// Where in the chain a reference step sits. See the file header for why this is
/// a parameter rather than two operations.
nonisolated enum ReferenceDomain: String, Codable, Sendable, CaseIterable {
    case continuous
    case epoch
}

nonisolated enum Rereferencing {

    // MARK: - Applying

    /// Re-references `channels` in place.
    ///
    /// `excluded` channels do not contribute to the reference but are still
    /// corrected by it — a bad channel must not pull the mean around, and it
    /// must still end up in the same space as everything else.
    static func applyInPlace(
        _ channels: inout [[Float]],
        scheme: ReferenceScheme = .average,
        excluding excluded: Set<Int> = []
    ) {
        switch scheme {
        case .average:
            EEGSignalFilter.averageReferenceInPlace(&channels, excluding: excluded)
        }
    }

    static func applied(
        _ channels: [[Float]],
        scheme: ReferenceScheme = .average,
        excluding excluded: Set<Int> = []
    ) -> [[Float]] {
        var copy = channels
        applyInPlace(&copy, scheme: scheme, excluding: excluded)
        return copy
    }

    /// Re-references a whole signal, preserving every field but the samples.
    static func applied(
        _ signal: MFFSignalData,
        scheme: ReferenceScheme = .average,
        excluding excluded: Set<Int> = []
    ) -> MFFSignalData {
        MFFSignalData(
            signalURL: signal.signalURL,
            signalType: signal.signalType,
            numberOfChannels: signal.numberOfChannels,
            samplingRate: signal.samplingRate,
            duration: signal.duration,
            recordingStartTime: signal.recordingStartTime,
            events: signal.events,
            data: applied(signal.data, scheme: scheme, excluding: excluded),
            channelNames: signal.channelNames
        )
    }

    // MARK: - Step parameters

    /// Portable parameters for the eva.xml `reference` step.
    ///
    /// `excluded` is written out in full rather than summarised. It is the whole
    /// reason this step exists as a step: without the list, the same parameters
    /// describe two different outputs depending on ambient channel state, and the
    /// node hash would claim they were the same.
    static func parameters(
        scheme: ReferenceScheme,
        domain: ReferenceDomain,
        excluding excluded: Set<Int>
    ) -> [String: String] {
        var p: [String: String] = [
            "scheme": scheme.rawValue,
            "domain": domain.rawValue,
            "excludedCount": "\(excluded.count)"
        ]
        if !excluded.isEmpty {
            p["excluded"] = excluded.sorted().map(String.init).joined(separator: ",")
        }
        return p
    }

    static func scheme(from p: [String: String]) -> ReferenceScheme {
        p["scheme"].flatMap(ReferenceScheme.init(rawValue:)) ?? .average
    }

    /// Defaults to `.continuous` so a step written before the domain existed —
    /// or by hand — replays as the free-standing transform rather than silently
    /// becoming a segmentation setting that never fires.
    static func domain(from p: [String: String]) -> ReferenceDomain {
        p["domain"].flatMap(ReferenceDomain.init(rawValue:)) ?? .continuous
    }

    /// The recorded exclusion set.
    ///
    /// Advisory on replay: the *live* bad set is what actually gets excluded, so
    /// re-referencing a different subject with different bad channels does the
    /// right thing rather than reproducing this subject's channel numbers. This
    /// is here so a reader — and a future comparison — can see what the recorded
    /// run excluded.
    static func recordedExclusions(from p: [String: String]) -> Set<Int> {
        guard let raw = p["excluded"], !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").compactMap { Int($0) })
    }
}
