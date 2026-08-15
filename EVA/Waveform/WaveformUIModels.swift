//
//  WaveformUIModels.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Per-recording UI state, lifted out of `WaveformView`'s ~104 `@State`
//  properties and grouped by lifetime/domain (ROADMAP Priority 1, B4).
//
//  Why these are `@Observable` classes on `RecordingStore` rather than `@State`
//  on the view:
//
//  1. **Diffing granularity.** `@State` on `WaveformView` is a stored property of
//     the view struct, so every AttributeGraph node that captures `self` copies
//     all of it — the `initializeWithCopy for WaveformView` frame that is still
//     1.48% of the main thread in `trace2.trace` and spikes during selection
//     drags. State that lives behind a reference is not copied with the struct,
//     and Observation tracks reads per property.
//  2. **Reach.** `RecordingStore` is where menu-bar commands already find
//     `channels`; hanging UI models off it gives commands, and later the REWIND
//     history tree, a way to read and drive this state without a live view.
//
//  These are deliberately *display* state, not domain state — nothing here
//  belongs in `eva.xml` or affects processing output. The domain view models
//  (`FilterViewModel`, `ICAViewModel`, …) stay where they are.
//
//  Migration note: `WaveformView` keeps forwarding computed properties for every
//  property moved here, exactly as it already did for the viewport values, so the
//  ~20 `extension WaveformView` files did not have to change. Those forwarders
//  are scaffolding — they come out as children start reading the store directly
//  (B2). Sites that need a `Binding` use a local `@Bindable` instead, since a
//  computed property has no `$` projection.
//

import SwiftUI

/// Time selection, drag tracking, hover, and the transient highlights that ride
/// along with them.
///
/// Grouped by lifetime: every property here changes at pointer frequency during
/// an interaction and is meaningless once it ends.
@Observable
final class WaveformSelectionModel {
    /// Sample the topomap is showing (set by double-click).
    var topomapSample: Int?
    /// Committed time selection.
    var selectedSampleRange: ClosedRange<Int>?
    /// Live drag endpoints. Non-nil only while a selection drag is in flight;
    /// these are the properties that tick on every mouse-moved event.
    var dragSelectionStartSample: Int?
    var dragSelectionEndSample: Int?
    /// Sample under the event-track right-click, for its context menu.
    var eventTrackContextSample: Int?
    var waveformHoverInfo: WaveformHoverInfo?
    /// Timestamp of the last stationary click, used to detect a double-click
    /// manually inside the single waveform interaction gesture.
    var lastWaveformClick: (time: Date, x: CGFloat)?
    /// Live global x of the scrolling waveform content's leading edge. Used to
    /// convert a gesture's global x into a scroll-independent content x.
    var waveformContentMinX: CGFloat = 0
    /// Artifact event whose window is highlighted in the waveform (tap its flag).
    var highlightedArtifactEvent: MFFEvent?
    var highlightedArtifactColor: Color = .orange
    /// Set to scroll the channel list to that row (e.g. from a topomap/butterfly
    /// click); `.scrollPosition(id:)` on the vertical channel ScrollView consumes it.
    var scrollToChannelRequest: Int?
}

/// Events panel, event-track caches, and the category-group popover.
@Observable
final class WaveformEventDisplayModel {
    var showsEventsPanel = false
    var selectedEventID: MFFEvent.ID?
    var selectedEventCodes = Set<String>()
    /// Derived-list caches. Kept beside the panel state they serve so a cache
    /// refresh invalidates only readers of the cache.
    var displayedEventsCache = WaveformDisplayedEventsCache.empty
    var eventTrackSourceSummary = EventTrackSourceSummary.empty

    // Category-group popover.
    var showsCategoryGroupPopover = false
    var categoryGroupMode: CategoryGroupMode = .codes
    var categoryGroupName = ""
    var categoryGroupSelectedCodes = Set<String>()
    var categoryRegexSourceCode = ""
    var categoryRegexPattern = ""
    var categoryRegexMatchField: CategoryRegexMatchField = .description
}

/// Physio (PNS) pane display state: visibility, per-channel scaling, polarity,
/// renames, and ICA-derived synthetic channels.
@Observable
final class PhysioDisplayModel {
    /// Shown by default when present; pinned below the EEG channels and synced
    /// to the EEG time axis.
    var showsPhysioChannels = true
    var ranges: [ClosedRange<Float>] = []
    var scaleFactors: [Int: Double] = [:]
    var maxScaledChannels = Set<Int>()
    var flippedPolarity = Set<Int>()
    /// User-assigned renames for physio channels (keyed by merged channel index).
    var channelRenames: [Int: String] = [:]
    /// Index of the channel currently being renamed (nil when no rename in progress).
    var renameTarget: Int?
    var renameText: String = ""
    /// Synthetic PNS channels created from ICA components.
    var syntheticPNSChannels: [SyntheticPNSChannel] = []
}

/// A timestamped entry kept in the scrollable status history.
///
/// Lifted out of `WaveformView` (where it was a nested type) so it can live
/// beside the model that owns the history.
struct StatusHistoryEntry: Identifiable, Hashable {
    let id = UUID()
    let source: String
    let text: String
    let isError: Bool
    let date: Date
}

extension WaveformView {
    /// Two-way binding into one of the `@Observable` UI models above.
    ///
    /// The forwarding computed properties on `WaveformView` cover reads and
    /// writes, but a computed property has no `$` projection — so the handful of
    /// sites that need a real `Binding` (`TextField`, `Picker`, `popover`,
    /// `DisclosureGroup`, `scrollPosition`) go through this instead.
    ///
    /// Call as `binding(recordingStore.events, \.categoryGroupName)`.
    func binding<Model: AnyObject, Value>(
        _ model: Model,
        _ keyPath: ReferenceWritableKeyPath<Model, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0 }
        )
    }
}

/// Toolbar status line, its scrollable history, and channel-status messaging.
@Observable
final class RecordingStatusModel {
    var channelStatusMessage: String?
    var channelStatusIsError = false
    /// Newest first; shown when the status area is clicked.
    var statusHistory: [StatusHistoryEntry] = []
    /// Dedupes repeated identical messages from the same feature.
    var lastRecordedStatusBySource: [String: String] = [:]
    var showsStatusHistory = false
    /// Which tab the status popover opens on. Set from the status area on each
    /// activation, so the popover leads with whichever half is relevant — see
    /// `ProcessingStatusPopover.swift`.
    var statusPopoverTab: ProcessingStatusTab = .queue
    var showsRecentProcessingHistory = false
}
