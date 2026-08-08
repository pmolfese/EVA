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
    /// Cached composition of the current processed signal with channel
    /// interpolation recipes. Kept per recording window.
    var interpolatedSignalResolver = InterpolatedSignalResolver()

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
