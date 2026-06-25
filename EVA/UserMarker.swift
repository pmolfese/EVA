//
//  UserMarker.swift
//  SummerEEGDemo
//
//  SwiftData sidecar model. MFF packages are read-only, so anything the user
//  *creates* — like a marked time point — lives here in the app's own store,
//  associated back to a recording by its package name.
//

import Foundation
import SwiftData

@Model
final class UserMarker {
    /// The `MFFRecording.packageName` this marker belongs to.
    var packageName: String
    /// Time of the marker, in seconds from the start of the recording.
    var timeSeconds: Double
    var note: String
    var createdAt: Date

    init(packageName: String, timeSeconds: Double, note: String = "", createdAt: Date = .now) {
        self.packageName = packageName
        self.timeSeconds = timeSeconds
        self.note = note
        self.createdAt = createdAt
    }
}
