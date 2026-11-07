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

import Foundation

/// Small, UI-independent selection rules shared by signal-processing callers.
/// Channel indices are zero-based; event starts and merge distances are in samples.
nonisolated enum SignalSelection {
    /// Returns sorted, unique indices whose channels match the first channel's length.
    /// Negative/out-of-bounds indices and differently sized channels are discarded.
    /// The first channel defines the expected length; this does not repair ragged data.
    static func validChannels(_ indices: [Int], in signal: MFFSignalData) -> [Int] {
        let sampleCount = signal.data.first?.count ?? 0
        return Array(Set(indices))
            .filter { $0 >= 0 && $0 < signal.data.count && signal.data[$0].count == sampleCount }
            .sorted()
    }

    /// Returns channel indices in their original order, keeping only the requested length.
    /// `data[channel][sample]` may be ragged; each row is checked independently.
    static func validChannels(in data: [[Float]], sampleCount: Int) -> [Int] {
        data.indices.filter { data[$0].count == sampleCount }
    }

    /// Greedily keeps the strongest hit within `mergeSamples` of the retained hit.
    /// Hits are sorted by start, with the strongest first at an identical start.
    /// A stronger hit replaces both the score and start; equal scores keep the earlier hit.
    ///
    /// The window follows the retained representative, rather than a fixed first hit:
    /// with distance 10, (100, 0.5), (105, 0.9), (114, 0.8) become (105, 0.9).
    /// The third hit is nine samples from the representative after replacement.
    /// Callers should supply finite scores and a nonnegative distance.
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
