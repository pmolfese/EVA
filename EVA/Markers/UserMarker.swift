//
//  UserMarker.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
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
