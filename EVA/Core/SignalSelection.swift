//
//  SignalSelection.swift
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

nonisolated enum SignalSelection {
    static func validChannels(_ indices: [Int], in signal: MFFSignalData) -> [Int] {
        let sampleCount = signal.data.first?.count ?? 0
        return Array(Set(indices))
            .filter { $0 >= 0 && $0 < signal.data.count && signal.data[$0].count == sampleCount }
            .sorted()
    }

    static func validChannels(in data: [[Float]], sampleCount: Int) -> [Int] {
        data.indices.filter { data[$0].count == sampleCount }
    }

    static func mergeNearbyStarts(
        _ hits: [(start: Int, score: Float)],
        mergeSamples: Int
    ) -> [(start: Int, score: Float)] {
        let sorted = hits.sorted {
            $0.start == $1.start ? $0.score > $1.score : $0.start < $1.start
        }
        var merged: [(start: Int, score: Float)] = []

        for hit in sorted {
            guard let last = merged.last else {
                merged.append(hit)
                continue
            }

            if hit.start - last.start <= mergeSamples {
                if hit.score > last.score {
                    merged[merged.count - 1] = hit
                }
            } else {
                merged.append(hit)
            }
        }

        return merged
    }
}
