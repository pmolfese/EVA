//
//  ABBAEngine.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Automatic band-border assignment for a frequency-resolved LAVI profile.
//

import Foundation

nonisolated enum ABBAEngine {
    static func detectBands(
        lavi: [Double],
        frequenciesHz: [Double],
        alphaAnchorHz: ClosedRange<Double>,
        ribbon: LAVISignificanceRibbon? = nil
    ) throws -> ABBAResult {
        try validate(
            lavi: lavi,
            frequenciesHz: frequenciesHz,
            alphaAnchorHz: alphaAnchorHz,
            ribbon: ribbon
        )

        let finiteValues = lavi.filter(\.isFinite).sorted()
        guard !finiteValues.isEmpty else {
            return ABBAResult(
                median: .nan,
                deviationsFromMedian: [Double](repeating: .nan, count: lavi.count),
                bands: [],
                warnings: [.flatLAVIProfile]
            )
        }
        let median = medianOfSorted(finiteValues)
        let deviations = lavi.map { $0.isFinite ? $0 - median : .nan }
        var adjusted = deviations
        var bands: [ABBABand] = []

        for finiteRange in contiguousFiniteRanges(in: deviations) {
            resolveExactMedianValues(&adjusted, within: finiteRange)
            let signedIndices = finiteRange.filter { adjusted[$0] != 0 && adjusted[$0].isFinite }
            guard !signedIndices.isEmpty else { continue }

            var regionStart = signedIndices[0]
            var previousIndex = signedIndices[0]
            var previousSign = adjusted[previousIndex] > 0 ? 1 : -1

            func appendRegion(start: Int, end: Int, sign: Int) {
                guard start <= end else { return }
                var peak = start
                var peakMagnitude = -Double.infinity
                for index in start...end where adjusted[index].isFinite {
                    let magnitude = abs(adjusted[index])
                    if magnitude > peakMagnitude {
                        peakMagnitude = magnitude
                        peak = index
                    }
                }
                guard peakMagnitude.isFinite else { return }

                let direction: ABBADirection = sign > 0 ? .sustained : .transient
                let significance = significanceForBand(
                    direction: direction,
                    peakIndex: peak,
                    peakLAVI: lavi[peak],
                    ribbon: ribbon
                )
                bands.append(
                    ABBABand(
                        id: stableID(begin: start, end: end, peak: peak),
                        beginIndex: start,
                        endIndex: end,
                        peakIndex: peak,
                        beginFrequencyHz: roundedTenth(frequenciesHz[start]),
                        endFrequencyHz: roundedTenth(frequenciesHz[end]),
                        peakFrequencyHz: roundedTenth(frequenciesHz[peak]),
                        peakLAVI: lavi[peak],
                        deviationFromMedian: adjusted[peak],
                        direction: direction,
                        relativeToAlpha: nil,
                        canonicalName: nil,
                        isSignificant: significance?.significant,
                        significanceMargin: significance?.margin
                    )
                )
            }

            for index in signedIndices.dropFirst() {
                let sign = adjusted[index] > 0 ? 1 : -1
                // Nonfinite gaps are handled as separate finite ranges. Exact
                // median bins inherit a sign, so only a true sign change ends
                // the current region.
                if sign != previousSign {
                    appendRegion(start: regionStart, end: previousIndex, sign: previousSign)
                    regionStart = index
                }
                previousIndex = index
                previousSign = sign
            }
            appendRegion(start: regionStart, end: previousIndex, sign: previousSign)
        }

        if bands.isEmpty {
            return ABBAResult(
                median: median,
                deviationsFromMedian: adjusted,
                bands: [],
                warnings: [.flatLAVIProfile]
            )
        }

        let alphaCandidates = bands.indices.filter { index in
            let band = bands[index]
            return band.direction == .sustained && alphaAnchorHz.contains(band.peakFrequencyHz)
        }
        var warnings: [RhythmicityWarning] = []
        if let firstCandidate = alphaCandidates.first {
            var anchorIndex = firstCandidate
            for candidate in alphaCandidates.dropFirst()
            where bands[candidate].peakLAVI > bands[anchorIndex].peakLAVI {
                anchorIndex = candidate
            }
            for index in bands.indices {
                let relative = index - anchorIndex
                bands[index].relativeToAlpha = relative
                bands[index].canonicalName = canonicalName(relativeToAlpha: relative)
            }
        } else {
            warnings.append(.noAlphaAnchor)
        }

        return ABBAResult(
            median: median,
            deviationsFromMedian: adjusted,
            bands: bands,
            warnings: warnings
        )
    }

    /// Isolated because exact-median handling is an externally pinned rule.
    /// A leading zero takes one tenth of the next available signed deviation;
    /// later zeros inherit one tenth of the already-adjusted preceding value.
    static func resolveExactMedianValues(_ values: inout [Double], within range: Range<Int>) {
        guard !range.isEmpty else { return }
        for index in range where values[index] == 0 {
            if index == range.lowerBound {
                let following = values[range].dropFirst().first { $0.isFinite && $0 != 0 }
                values[index] = following.map { $0 / 10.0 } ?? 0
            } else {
                values[index] = values[index - 1] / 10.0
            }
        }
    }

    private static func validate(
        lavi: [Double],
        frequenciesHz: [Double],
        alphaAnchorHz: ClosedRange<Double>,
        ribbon: LAVISignificanceRibbon?
    ) throws {
        guard !lavi.isEmpty else { throw ABBAError.emptyProfile }
        guard lavi.count == frequenciesHz.count else {
            throw ABBAError.countMismatch(lavi: lavi.count, frequencies: frequenciesHz.count)
        }
        guard alphaAnchorHz.lowerBound.isFinite,
              alphaAnchorHz.upperBound.isFinite,
              alphaAnchorHz.lowerBound > 0,
              alphaAnchorHz.lowerBound <= alphaAnchorHz.upperBound else {
            throw ABBAError.invalidAlphaAnchor(
                lower: alphaAnchorHz.lowerBound,
                upper: alphaAnchorHz.upperBound
            )
        }
        for index in frequenciesHz.indices {
            let frequency = frequenciesHz[index]
            guard frequency.isFinite, frequency > 0 else {
                throw ABBAError.invalidFrequency(index: index, value: frequency)
            }
            if index > 0, frequency <= frequenciesHz[index - 1] {
                throw ABBAError.frequenciesNotStrictlyAscending(index: index)
            }
        }
        guard let ribbon else { return }
        guard ribbon.lower.count == lavi.count,
              ribbon.upper.count == lavi.count,
              ribbon.frequenciesHz.count == lavi.count else {
            throw ABBAError.ribbonCountMismatch
        }
        for index in lavi.indices {
            let tolerance = 1e-12 * max(1, abs(frequenciesHz[index]))
            guard abs(ribbon.frequenciesHz[index] - frequenciesHz[index]) <= tolerance else {
                throw ABBAError.ribbonFrequencyMismatch(index: index)
            }
            guard ribbon.lower[index].isFinite,
                  ribbon.upper[index].isFinite,
                  ribbon.lower[index] <= ribbon.upper[index] else {
                throw ABBAError.invalidRibbon(index: index)
            }
        }
    }

    private static func contiguousFiniteRanges(in values: [Double]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?
        for index in values.indices {
            if values[index].isFinite {
                if start == nil { start = index }
            } else if let runStart = start {
                ranges.append(runStart..<index)
                start = nil
            }
        }
        if let runStart = start { ranges.append(runStart..<values.count) }
        return ranges
    }

    private static func medianOfSorted(_ values: [Double]) -> Double {
        let middle = values.count / 2
        return values.count.isMultiple(of: 2)
            ? (values[middle - 1] + values[middle]) / 2.0
            : values[middle]
    }

    private static func roundedTenth(_ value: Double) -> Double {
        (value * 10.0).rounded(.toNearestOrEven) / 10.0
    }

    private static func canonicalName(relativeToAlpha: Int) -> String {
        if relativeToAlpha == 0 { return "Alpha" }
        return relativeToAlpha < 0
            ? "Alpha − \(-relativeToAlpha)"
            : "Alpha + \(relativeToAlpha)"
    }

    private static func significanceForBand(
        direction: ABBADirection,
        peakIndex: Int,
        peakLAVI: Double,
        ribbon: LAVISignificanceRibbon?
    ) -> (significant: Bool, margin: Double)? {
        guard let ribbon else { return nil }
        switch direction {
        case .sustained:
            let margin = peakLAVI - ribbon.upper[peakIndex]
            return (margin > 0, margin)
        case .transient:
            let margin = ribbon.lower[peakIndex] - peakLAVI
            return (margin > 0, margin)
        }
    }

    private static func stableID(begin: Int, end: Int, peak: Int) -> UUID {
        var bytes: [UInt8] = [0x4c, 0x41, 0x56, 0x49] // "LAVI"
        for value in [begin, end, peak] {
            let encoded = UInt32(truncatingIfNeeded: value).bigEndian
            withUnsafeBytes(of: encoded) { bytes.append(contentsOf: $0) }
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
