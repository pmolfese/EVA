//
//  RecordingStore.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Shared source of truth for the currently loaded recording's channel state
//  and viewport, per the L4 plan in REFACTOR.md §5/§6. Introduced once the
//  L5 view-decomposition split WaveformView's domain logic across ~20 files
//  that all read/wrote WaveformView's own @State directly -- this collects
//  that state into one @Observable object so future consumers (a
//  RecordingExporter, a headless batch path) can hold a RecordingStore
//  without needing a live WaveformView.
//
//  WaveformView still exposes `channels`, `amplitudeScale`, `timeScale`,
//  `horizontalOffset`, `horizontalViewportWidth`, and `horizontalScrollPosition`
//  as computed properties that forward to this store, so none of the
//  extension files that read/write those names needed to change.
//

import SwiftUI

@Observable
final class RecordingStore {
    /// Per-window channel state (hidden / bad / interpolated).
    var channels = ChannelModel()

    // MARK: Waveform UI state (B4)
    // Lifted out of `WaveformView`'s `@State` and grouped by lifetime/domain, so
    // it is no longer copied with the view struct and menu-bar commands can reach
    // it the same way they reach `channels`. See `WaveformUIModels.swift`.

    /// Time selection, drag tracking, hover, transient highlights.
    var selection = WaveformSelectionModel()
    /// Events panel, event-track caches, category-group popover.
    var events = WaveformEventDisplayModel()
    /// Physio (PNS) pane display state.
    var physio = PhysioDisplayModel()
    /// Toolbar status line and its history.
    var status = RecordingStatusModel()
    /// The processing history tree and the History rail's display state. Derived
    /// from the processing script for now — see `RecordingHistoryModel`.
    var processingHistory = RecordingHistoryModel()
    /// What each cleaning stage removed, in the order the stages ran. See
    /// `CleaningVarianceLedger`.
    var cleaningVariance = CleaningVarianceLedger()
    /// Single owner of in-flight operation progress, replacing the per-view-model
    /// `operationProgress` properties. See `OperationProgressCenter`.
    var operationProgress = OperationProgressCenter()
    /// Owns the in-flight MFF export. Needed because both export paths set
    /// `isExportingMFF = true` *before* cancelling the previous task, so a
    /// superseded export resuming later would otherwise clear the flag the newer
    /// one just set. See `LatestOnlyRunner`.
    @ObservationIgnored let exportRunner = LatestOnlyRunner()
    /// Owns the in-flight history re-derivation. Rapid clicks down the rail
    /// start one rebuild each, and without this the *first* one to finish moves
    /// the window — so the state on screen is whichever rebuild happened to be
    /// shortest, not the node last clicked. Only the newest may commit
    /// (ROADMAP RW-1 item 2). See `LatestOnlyRunner`.
    @ObservationIgnored let historyReDeriveRunner = LatestOnlyRunner()
    /// User's session-only correction of the detected file type (File ▸ Dataset
    /// Info). Not written to disk and not part of `eva.xml`'s authoritative
    /// `fileType` — this is the escape hatch for a package EVA reads wrongly, so
    /// a bad detection never blocks the work.
    var fileTypeOverride: MFFFileType?
    /// Cached composition of the current processed signal with channel
    /// interpolation recipes. Kept per recording window.
    var interpolatedSignalResolver = InterpolatedSignalResolver()
    /// Latest continuous signal at the end of this window's processing
    /// pipeline. The Channels utility reads this when focus moves between
    /// recording windows, so becoming main does not republish raw data.
    @ObservationIgnored var channelsWindowSignal: MFFSignalData?

    // MARK: Viewport
    var amplitudeScale: Double = 100
    var timeScale: Double = 1
    var horizontalOffset: CGFloat = 0
    var horizontalViewportWidth: CGFloat = 1
    var horizontalScrollPosition = ScrollPosition(idType: Int.self, x: 0)

    /// Serializes major processing operations (filter, gradient, ICA, wavelet
    /// reduction, artifact cleaning, channel/segment health, PSA, BCG, EEG
    /// analysis) so at most one runs at a time. Lives here (not on
    /// WaveformView) so standalone VMs that only hold `store` — not a
    /// WaveformView reference — can reach it too.
    let processingQueue = ProcessingQueue()
}
