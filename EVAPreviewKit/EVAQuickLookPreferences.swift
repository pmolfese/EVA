//
//  EVAQuickLookPreferences.swift
//  EVAPreviewKit
//
//  Shared by the containing app and both Finder extension processes.
//

import Foundation

nonisolated enum EVAQuickLookPreferences {
    static let appGroupIdentifier = "group.gov.nih.nimh.cmn.eva"
    static let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard

    static func isEnabled(_ format: EVAPreviewFormat) -> Bool {
        guard defaults.object(forKey: format.preferenceKey) != nil else { return true }
        return defaults.bool(forKey: format.preferenceKey)
    }

    static func setEnabled(_ enabled: Bool, for format: EVAPreviewFormat) {
        defaults.set(enabled, forKey: format.preferenceKey)
    }
}
