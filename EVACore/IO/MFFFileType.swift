//
//  MFFFileType.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  How EVA classifies a loaded MFF: continuous, segmented, averaged, or grand
//  average. Surfaced (and, session-only, overridable) in the Dataset Info panel.
//

import Foundation

nonisolated enum MFFFileType: String, CaseIterable, Identifiable, Sendable, Codable {
    case continuous
    case segmented
    case averaged
    case grandAverage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .continuous: return "Continuous"
        case .segmented: return "Segmented"
        case .averaged: return "Averaged"
        case .grandAverage: return "Grand Average"
        }
    }
}

extension MFFSignalData {
    /// The type EVA detected on load, from the on-disk epoch/category structure.
    var detectedFileType: MFFFileType {
        if isGrandAverage { return .grandAverage }
        if isAveraged { return .averaged }
        if isSegmented { return .segmented }
        return .continuous
    }

    /// Distinct subject/group ids across the epoch segments (grand averages only).
    var subjects: [String] {
        var seen: [String] = []
        for segment in epochSegments {
            if let subject = segment.subject, !seen.contains(subject) { seen.append(subject) }
        }
        return seen
    }

    var hasMultipleSubjects: Bool { subjects.count > 1 }

    /// Distinct category names in first-appearance order.
    var categories: [String] {
        var seen: [String] = []
        for segment in epochSegments where !seen.contains(segment.category) {
            seen.append(segment.category)
        }
        return seen
    }
}
