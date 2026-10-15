//
//  MAACPreliminaryBlinkDetectorTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct MAACPreliminaryBlinkDetectorTests {
    private let samplingRate = 250.0
    private let sampleCount = 750

    @Test func detectsFastUpperMinusLowerBlinkWithUnequalGroups() throws {
        var channels = Array(repeating: [Float](repeating: 0, count: sampleCount), count: 4)
        addTriangle(to: &channels[0], center: 250, halfWidth: 25, peak: 105)
        addTriangle(to: &channels[1], center: 250, halfWidth: 25, peak: 100)
        addTriangle(to: &channels[2], center: 250, halfWidth: 25, peak: -105)
        // Channel 3 is deliberately unrelated and excluded from the explicit
        // two-upper/one-lower role assignment.
        channels[3][250] = 2_000

        let result = try MAACPreliminaryBlinkDetector.detect(
            channels: channels,
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            upperVEOGIndices: [0, 1],
            lowerVEOGIndices: [2]
        )

        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(result.candidateCount == 1)
        #expect(event.code == "Eye Blink")
        #expect(event.sourceFile == MAACPreliminaryBlinkDetector.sourceFile)
        #expect(event.timeAnchor == .onset)
        #expect((event.durationSeconds ?? 0) >= 0.020)
        #expect(event.eventDescription?.contains("rise") == true)
        #expect(event.spanSeconds?.contains(1.0) == true)
    }

    @Test func rejectsSlowVerticalDriftThatCrossesAmplitudeThreshold() throws {
        var upper = [Float](repeating: 0, count: sampleCount)
        var lower = [Float](repeating: 0, count: sampleCount)
        for sample in 100...600 {
            let distance = sample <= 350 ? sample - 100 : 600 - sample
            let value = Float(max(distance, 0)) * 0.42
            upper[sample] = value
            lower[sample] = -value
        }
        let result = try MAACPreliminaryBlinkDetector.detect(
            channels: [upper, lower],
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            upperVEOGIndices: [0],
            lowerVEOGIndices: [1]
        )
        #expect(result.candidateCount == 1)
        #expect(result.events.isEmpty)
        #expect(result.rejectedBySlopeCount == 1)
    }

    @Test func excludedRoleIsNotSilentlyReassigned() {
        #expect(throws: MAACPreliminaryBlinkError.missingLowerVEOG) {
            try MAACPreliminaryBlinkDetector.detect(
                channels: Array(repeating: [Float](repeating: 0, count: sampleCount), count: 3),
                samplingRate: samplingRate,
                duration: Double(sampleCount) / samplingRate,
                upperVEOGIndices: [0, 1],
                lowerVEOGIndices: [2],
                excluding: [2]
            )
        }
    }

    private func addTriangle(to values: inout [Float], center: Int, halfWidth: Int, peak: Float) {
        for offset in -halfWidth...halfWidth {
            let fraction = 1 - Float(abs(offset)) / Float(halfWidth)
            values[center + offset] += peak * fraction
        }
    }
}
