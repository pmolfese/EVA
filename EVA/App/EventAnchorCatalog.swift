//
//  EventAnchorCatalog.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Which `EventTimeAnchor` each of EVA's built-in event producers stamps.
//
//  This exists to be *shown*: without it, Preferences ▸ Events lists only the
//  user's own rules, and an empty list reads as "nothing in EVA is centered" —
//  which is untrue the moment any detector runs. It is a readout, never an
//  input. Detectors measure where their events sit, so there is nothing here
//  for a user to correct; the editable rules alongside it exist because file
//  formats *cannot* record an anchor, which is a genuinely different problem.
//
//  A hand-maintained table like this rots silently, and a UI that confidently
//  states the wrong thing is worse than one that says nothing. `EventAnchorCatalogTests`
//  therefore drives each producer and asserts its real output matches the entry
//  below. Change a detector's anchor without updating its entry and that test
//  fails — which is the only reason this table is safe to display.
//

import Foundation

nonisolated struct EventAnchorCatalogEntry: Identifiable, Sendable, Hashable {
    /// Display name of the producer, as the user meets it in EVA's UI.
    let name: String
    let anchor: EventTimeAnchor
    /// What the marked sample actually is, in the producer's own terms.
    let detail: String
    /// `MFFEvent.sourceFile` (or its prefix) this producer stamps, when it has a
    /// single stable one. Used by the anti-drift test to tie an entry to real
    /// output; `nil` where the source string is composed per scan.
    let sourceFilePrefix: String?

    var id: String { name }
}

nonisolated enum EventAnchorCatalog {
    /// Ordered for reading, not alphabetically: measured extrema first (the
    /// surprising ones), then centered matches, then the onset cases that
    /// behave the way an event marker is usually assumed to.
    static let entries: [EventAnchorCatalogEntry] = [
        EventAnchorCatalogEntry(
            name: "Eye-artifact threshold",
            anchor: .peak,
            detail: "Marks the blink apex; the duration is the window around it.",
            sourceFilePrefix: EyeArtifactThresholdDetector.sourceFile
        ),
        EventAnchorCatalogEntry(
            name: "ECG (R wave)",
            anchor: .peak,
            detail: "Marks the R peak; the duration is the deflection's width.",
            sourceFilePrefix: RWaveDetector.sourceFile
        ),
        EventAnchorCatalogEntry(
            name: "BCG",
            anchor: .peak,
            detail: "Marks the pulse artifact peak, centered in its window.",
            sourceFilePrefix: BCGDetector.sourceFile
        ),
        EventAnchorCatalogEntry(
            name: "Waveform template match",
            anchor: .center,
            detail: "Marks the middle of the matched template window.",
            sourceFilePrefix: "Template"
        ),
        EventAnchorCatalogEntry(
            name: "Trajectory scan",
            anchor: .center,
            detail: "Marks the middle of the matched map sequence.",
            sourceFilePrefix: "Trajectory"
        ),
        EventAnchorCatalogEntry(
            name: "Topography scan",
            anchor: .onset,
            detail: "Marks where the match begins, with a fixed forward duration.",
            sourceFilePrefix: "Topography"
        ),
        EventAnchorCatalogEntry(
            name: "Continuous scan",
            anchor: .onset,
            detail: "Marks where the run begins; each event's duration is its own.",
            sourceFilePrefix: "Continuous"
        ),
        EventAnchorCatalogEntry(
            name: "Wavelet Explorer",
            anchor: .onset,
            detail: "Marks the candidate's start, spanning its full detected burst.",
            sourceFilePrefix: WaveletArtifactExplorerViewModel.candidateSourceFile
        ),
        EventAnchorCatalogEntry(
            name: "Imported events",
            anchor: .onset,
            detail: "MFF, EDF, BrainVision and the rest all record onsets.",
            sourceFilePrefix: nil
        ),
    ]

    /// Entries grouped by anchor, in the display order above.
    static func entries(for anchor: EventTimeAnchor) -> [EventAnchorCatalogEntry] {
        entries.filter { $0.anchor == anchor }
    }
}
