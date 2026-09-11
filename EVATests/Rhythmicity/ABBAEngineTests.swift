//
//  ABBAEngineTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct ABBAEngineTests {
    private struct InputFixture: Decodable {
        struct ABBA: Decodable {
            var alphaRangeHz: [Double]
            var frequenciesHz: [Double]
            var lavi: [Double]
            var lowerLimits: [Double]
            var upperLimits: [Double]
        }
        var abba: ABBA
    }

    private struct OutputFixture: Decodable {
        struct ABBA: Decodable {
            struct Envelope: Decodable { var borders: [[[Double]]] }
            var perFrequency: Envelope
            var globalEnvelope: Envelope
        }
        var abba: ABBA
    }

    private static let input: InputFixture = decode("Rhythmicity/reference-input.json")
    private static let output: OutputFixture = decode("Rhythmicity/python-reference.json")

    @Test func medianOnlyBandsMatchPinnedPythonBorders() throws {
        let input = Self.input.abba
        let result = try ABBAEngine.detectBands(
            lavi: input.lavi,
            frequenciesHz: input.frequenciesHz,
            alphaAnchorHz: input.alphaRangeHz[0]...input.alphaRangeHz[1]
        )
        let expected = Self.output.abba.perFrequency.borders[0]

        #expect(abs(result.median - 0.445) < 1e-15)
        #expect(result.bands.count == expected.count)
        for (band, row) in zip(result.bands, expected) {
            #expect(band.beginIndex == Int(row[0]) - 1)
            #expect(band.endIndex == Int(row[1]) - 1)
            #expect(band.peakIndex == Int(row[2]) - 1)
            #expect(band.beginFrequencyHz == row[3])
            #expect(band.endFrequencyHz == row[4])
            #expect(band.peakFrequencyHz == row[5])
            #expect(abs(band.peakLAVI - row[6]) < 1e-15)
            #expect(abs(band.deviationFromMedian - row[7]) < 1e-15)
            #expect(band.direction.referenceValue == Int(row[8]))
            #expect(band.relativeToAlpha == Int(row[9]))
            #expect(band.isSignificant == nil)
        }
        #expect(result.bands[3].canonicalName == "Alpha")
    }

    @Test func bandIdentifiersAreDeterministic() throws {
        let input = Self.input.abba
        let first = try ABBAEngine.detectBands(
            lavi: input.lavi,
            frequenciesHz: input.frequenciesHz,
            alphaAnchorHz: input.alphaRangeHz[0]...input.alphaRangeHz[1]
        )
        let second = try ABBAEngine.detectBands(
            lavi: input.lavi,
            frequenciesHz: input.frequenciesHz,
            alphaAnchorHz: input.alphaRangeHz[0]...input.alphaRangeHz[1]
        )
        #expect(first.bands.map(\.id) == second.bands.map(\.id))
    }

    @Test func perFrequencyRibbonMatchesPinnedSignificanceFlags() throws {
        let input = Self.input.abba
        let ribbon = LAVISignificanceRibbon(
            lower: input.lowerLimits,
            upper: input.upperLimits,
            frequenciesHz: input.frequenciesHz,
            source: .deterministicFixture,
            surrogateCount: 200,
            alpha: 0.05,
            tailRule: .fifthOrderStatisticPerFrequency
        )
        let result = try ABBAEngine.detectBands(
            lavi: input.lavi,
            frequenciesHz: input.frequenciesHz,
            alphaAnchorHz: input.alphaRangeHz[0]...input.alphaRangeHz[1],
            ribbon: ribbon
        )
        let expected = Self.output.abba.perFrequency.borders[0].map { $0[10] == 1 }
        #expect(result.bands.map(\.isSignificant) == expected.map(Optional.some))
    }

    @Test func globalCompatibilityEnvelopeMatchesPinnedFlags() throws {
        let input = Self.input.abba
        let lower = [Double](repeating: input.lowerLimits.min()!, count: input.lavi.count)
        let upper = [Double](repeating: input.upperLimits.max()!, count: input.lavi.count)
        let ribbon = LAVISignificanceRibbon(
            lower: lower,
            upper: upper,
            frequenciesHz: input.frequenciesHz,
            source: .deterministicFixture,
            surrogateCount: 20,
            alpha: .nan,
            tailRule: .toolboxGlobalExtrema
        )
        let result = try ABBAEngine.detectBands(
            lavi: input.lavi,
            frequenciesHz: input.frequenciesHz,
            alphaAnchorHz: input.alphaRangeHz[0]...input.alphaRangeHz[1],
            ribbon: ribbon
        )
        let expected = Self.output.abba.globalEnvelope.borders[0].map { $0[10] == 1 }
        #expect(result.bands.map(\.isSignificant) == expected.map(Optional.some))
    }

    @Test func exactMedianValuesInheritASignedNeighbor() {
        var values = [0.0, 0.0, 0.4, -0.2, 0.0]
        ABBAEngine.resolveExactMedianValues(&values, within: values.indices)
        #expect(abs(values[0] - 0.04) < 1e-15)
        #expect(abs(values[1] - 0.004) < 1e-15)
        #expect(abs(values[4] + 0.02) < 1e-15)
    }

    @Test func missingAlphaAnchorRetainsDiscreteBands() throws {
        let result = try ABBAEngine.detectBands(
            lavi: [0.1, 0.2, 0.1],
            frequenciesHz: [3, 4, 5],
            alphaAnchorHz: 6...14
        )
        #expect(!result.bands.isEmpty)
        #expect(result.bands.allSatisfy { $0.relativeToAlpha == nil && $0.canonicalName == nil })
        #expect(result.warnings.contains(.noAlphaAnchor))
        #expect(result.bands.allSatisfy { $0.peakFrequencyHz.isFinite })
    }

    @Test func nonfiniteBinsSplitRatherThanBridgeRegions() throws {
        let result = try ABBAEngine.detectBands(
            lavi: [0.1, .nan, 0.2, 0.3],
            frequenciesHz: [3, 4, 5, 6],
            alphaAnchorHz: 8...14
        )
        #expect(result.bands.count == 2)
        #expect(result.bands[0].beginIndex == 0 && result.bands[0].endIndex == 0)
        #expect(result.bands[1].beginIndex == 2 && result.bands[1].endIndex == 3)
    }

    @Test func invalidFrequencyOrderingIsRejected() {
        #expect(throws: ABBAError.frequenciesNotStrictlyAscending(index: 2)) {
            try ABBAEngine.detectBands(
                lavi: [0.1, 0.2, 0.3],
                frequenciesHz: [3, 5, 4],
                alphaAnchorHz: 6...14
            )
        }
    }

    private static func decode<T: Decodable>(_ name: String) -> T {
        let data = try! Data(contentsOf: Fixtures.url(name))
        return try! JSONDecoder().decode(T.self, from: data)
    }
}
