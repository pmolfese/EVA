//
//  EllipticFilterTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct EllipticFilterTests {
    private let samplingRate = 250.0
    private let count = 4000

    private func rms(_ values: ArraySlice<Float>) -> Double {
        SignalStatistics.rootMeanSquare(values.map(Double.init))
    }

    @Test func ellipticBandPassPreservesPassbandAndRejectsStopbands() async throws {
        let inBand = SyntheticSignal.sine(frequency: 10, samplingRate: samplingRate, count: count)
        let drift = SyntheticSignal.sine(frequency: 0.1, samplingRate: samplingRate, count: count)
        let high = SyntheticSignal.sine(frequency: 90, samplingRate: samplingRate, count: count)

        let filtered = try await EEGSignalFilter.bandPass(
            channels: [inBand, drift, high],
            samplingRate: samplingRate,
            lowCutoff: 1,
            highCutoff: 40,
            highPassSlope: .dB24,
            lowPassSlope: .dB24,
            iirDesign: .elliptic,
            ellipticPassbandRippleDB: 0.1,
            ellipticStopbandAttenuationDB: 60,
            precision: .double
        )

        let interior = 1000..<(count - 1000)
        let inBandRatio = rms(filtered[0][interior]) / rms(inBand[interior])
        let driftRatio = rms(filtered[1][interior]) / rms(drift[interior])
        let highRatio = rms(filtered[2][interior]) / rms(high[interior])
        #expect(inBandRatio > 0.9)
        #expect(driftRatio < 0.05)
        #expect(highRatio < 0.05)
        #expect(filtered.flatMap { $0 }.allSatisfy(\.isFinite))
    }

    @Test func ellipticSectionsAreStableAndFinite() {
        for edge in [EllipticFilterDesign.Edge.lowPass, .highPass] {
            let sections = EllipticFilterDesign.sections(
                cutoff: edge == .lowPass ? 40 : 1,
                samplingRate: samplingRate,
                order: 8,
                edge: edge,
                passbandRippleDB: 0.1,
                stopbandAttenuationDB: 60
            )
            #expect(sections.count == 4)
            for section in sections {
                #expect([section.b0, section.b1, section.b2, section.a1, section.a2].allSatisfy(\.isFinite))
                // For a conjugate pole pair, a2 is the squared pole radius.
                #expect(section.a2 > 0 && section.a2 < 1)
            }
        }
    }
}
