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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
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

    var id: String {
        "\(startSample)-\(endSample)-\(category)-\(sourceCode)-\(sourceTimeSeconds)-\(contributingEpochCount)"
    }
}
