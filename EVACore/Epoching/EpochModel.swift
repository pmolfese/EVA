//
//  EpochModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation

nonisolated struct EpochSegment: Identifiable, Sendable {
    let startSample: Int
    let endSample: Int
    let stimulusOffsetSamples: Int
    let category: String
    let sourceCode: String
    let sourceTimeSeconds: Double
    let colorIndex: Int
    let contributingEpochCount: Int
    /// Contributing subject/group id for grand-average segments (one seg per
    /// subject per category). `nil` for ordinary averages/epochs. `var` with a
    /// default so it joins the memberwise init while existing sites omit it.
    var subject: String? = nil

    var id: String {
        // `subject` disambiguates grand-average segments that share category +
        // sample range across subjects.
        "\(startSample)-\(endSample)-\(category)-\(sourceCode)-\(sourceTimeSeconds)-\(contributingEpochCount)-\(subject ?? "")"
    }
}
