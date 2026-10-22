import Foundation
import Testing
@testable import EVA

struct GradientTimingCheckTests {
    private func recording(groups: Int, spacing: Double? = nil) -> ([[Float]], [Int]) {
        let triggers = (0..<40).map { 2000 + $0 * 2000 }
        var signal = [Float](repeating: 0, count: 84000)
        let interval = spacing ?? 2000 / Double(groups)
        for i in 2000..<82000 {
            let phase = Double((i - 2000) % 2000)
            let group = Int(phase / interval)
            if group >= groups { continue }
            let position = phase - Double(group) * interval
            signal[i] = Float(5000 * exp(-pow((position - 22) / 6, 2)) * sin(2 * .pi * 0.173 * position))
        }
        return ((0..<4).map { c in signal.map { $0 * Float(c + 1) / 2 } }, triggers)
    }

    @Test func catchesWrongMultibandGroupCountAndSeparatesFractionalTiming() throws {
        let (x, tr) = recording(groups: 23)
        let probe = try #require(GradientTimingCheck.measure(channels: x, triggers: tr, samplingRate: 1000))
        #expect(probe.observedLag == 87)
        #expect(probe.assess(schedule: .uniform(groupsPerVolume: 22), fractionalTiming: true).agreement == .mismatch)
        #expect(probe.assess(schedule: .uniform(groupsPerVolume: 11), fractionalTiming: true).agreement == .mismatch)
        let correct = probe.assess(schedule: .uniform(groupsPerVolume: 23), fractionalTiming: false)
        #expect(correct.agreement == .compatible)
        #expect(correct.needsFractionalAlignment)
        #expect(!probe.assess(schedule: .uniform(groupsPerVolume: 23), fractionalTiming: true).warrantsReview)
    }

    @Test func recognizesExactTimingAndDoesNotMistakeWrapDeadTimeForAnotherGroup() throws {
        let (x, tr) = recording(groups: 22, spacing: 90)
        let probe = try #require(GradientTimingCheck.measure(channels: x, triggers: tr, samplingRate: 1000))
        #expect(probe.observedLag == 90)
        let json = probe.assess(schedule: .offsetsSeconds((0..<22).map { Double($0) * 0.09 }), fractionalTiming: true)
        #expect(json.agreement == .compatible)
        // Correct count, wrong uniformly distributed onsets: 19 ms late at the end.
        #expect(probe.assess(schedule: .uniform(groupsPerVolume: 22), fractionalTiming: true).agreement == .mismatch)
    }

    @Test func abstainsOnWeakArtifactAndDoesNotPresentMissingEvidenceAsAgreement() throws {
        let (x, tr) = recording(groups: 23)
        let probe = try #require(GradientTimingCheck.measure(channels: x.map { $0.map { $0 * 0.00001 } },
                                                            triggers: tr, samplingRate: 1000))
        let assessment = probe.assess(schedule: .uniform(groupsPerVolume: 23), fractionalTiming: true)
        #expect(assessment.agreement == .inconclusive)
        #expect(assessment.observedMilliseconds == nil)
    }

    @Test func arbitrarySchedulesAndWholeVolumesDoNotProduceMismatchWarnings() throws {
        let (x, tr) = recording(groups: 23)
        let probe = try #require(GradientTimingCheck.measure(channels: x, triggers: tr, samplingRate: 1000))
        #expect(!probe.assess(schedule: .uniform(groupsPerVolume: 1), fractionalTiming: false).warrantsReview)
        #expect(probe.assess(schedule: .offsetsSeconds([0, 0.08, 0.2]), fractionalTiming: true).agreement == .inconclusive)
        #expect(GradientTimingCheck.measure(channels: x, triggers: [100, 200], samplingRate: 1000) == nil)
    }

    @Test func timingAssessmentPersistsWithoutBreakingOlderRunMetrics() throws {
        let old = GradientRunMetrics(residualFractionP90: 0, residualFractionMedian: 0,
            residualFractionMax: 0, worstChannel: nil, inBandResidualFractionP90: nil,
            inBandResidualFractionMedian: nil, removedVarianceFraction: 1,
            correctedEpochs: 20, totalEpochs: 20, gradedChannelCount: 4)
        let oldData = try JSONEncoder().encode(old)
        #expect(try JSONDecoder().decode(GradientRunMetrics.self, from: oldData).timingAssessment == nil)
        let (x, tr) = recording(groups: 23)
        let probe = try #require(GradientTimingCheck.measure(channels: x, triggers: tr, samplingRate: 1000))
        var current = old
        current.timingAssessment = probe.assess(schedule: .uniform(groupsPerVolume: 22), fractionalTiming: true)
        let restored = try JSONDecoder().decode(GradientRunMetrics.self, from: JSONEncoder().encode(current))
        #expect(restored == current)
        let quality = GradientRunGrade.grade(from: restored)
        #expect(quality.metrics.contains { $0.name == "Acquisition timing" && $0.grade == .watch })
    }
}
