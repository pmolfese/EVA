//
//  OpenRecordingRegistry.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  A weak roster of the recordings currently open in EVA's windows.
//
//  Preferences is its own scene: it has no recording in scope and no window's
//  view hierarchy to inherit one from. The Events tab needs both — the event
//  codes actually present in the user's data (so a rule can be added by picking
//  a code rather than by typing one blind) and a way to reapply edited rules to
//  what is already open. This is the smallest thing that provides them.
//
//  References are weak, so a registered recording that its window releases is
//  dropped here too and nothing is kept alive by being listed.
//

import Foundation
import Observation

@MainActor
@Observable
final class OpenRecordingRegistry {
    static let shared = OpenRecordingRegistry()

    private struct WeakRecording {
        weak var recording: MFFRecording?
    }

    /// Keyed by `MFFRecording.id` so re-registering the same recording (a
    /// reload, say) replaces its entry rather than duplicating it.
    private var entries: [UUID: WeakRecording] = [:]

    /// Every still-live registered recording, in no guaranteed order.
    ///
    /// Reading also compacts the roster, which is the only reaping this needs:
    /// entries are few, and a stale one costs nothing until someone looks.
    var recordings: [MFFRecording] {
        let live = entries.compactMapValues { $0.recording == nil ? nil : $0 }
        if live.count != entries.count {
            entries = live
        }
        return live.values.compactMap(\.recording)
    }

    /// Distinct event codes across every open recording, sorted for display.
    var eventCodes: [String] {
        let codes = recordings.flatMap { $0.signal?.events.map(\.code) ?? [] }
        return Array(Set(codes)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func register(_ recording: MFFRecording) {
        entries[recording.id] = WeakRecording(recording: recording)
    }

    func unregister(_ recording: MFFRecording) {
        entries[recording.id] = nil
    }
}
