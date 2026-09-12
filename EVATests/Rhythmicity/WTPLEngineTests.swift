//
//  WTPLEngineTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct WTPLEngineTests {
    private struct Oracle: Decodable {
        struct Input: Decodable {
            var samplingRateHz: Double
            var eventSampleIndex: Int
            var frequenciesHz: [Double]
            var nCycles: [Double]
            var lagCycles: [Double]
            var baselineSamplesInclusive: [Int]
            var trials: [[Double]]
        }
        struct Expected: Decodable {
            var meanWTPL: [[Double?]]
            var deltaWTPL: [[Double?]]
            var validTrialCounts: [[Int]]
            var varianceWTPL: [[Double?]]
        }
        var input: Input
        var expected: Expected
    }

    @Test func matchesIndependentPythonPaperEquationOracle() throws {
        let data = try Data(contentsOf: Fixtures.url("Rhythmicity/wtpl-python-oracle.json"))
        let fixture = try JSONDecoder().decode(Oracle.self, from: data)
        let input = fixture.input
        let result = try WTPLEngine.analyze(
            trials: input.trials,
            samplingRate: input.samplingRateHz,
            plan: TFFrequencyPlan(frequenciesHz: input.frequenciesHz, nCycles: input.nCycles),
            lagCycles: input.lagCycles,
            baseline: WTPLBaselineSpec(
                startSample: input.baselineSamplesInclusive[0],
                endSample: input.baselineSamplesInclusive[1]
            ),
            eventSampleIndex: input.eventSampleIndex,
            coefficientProvider: DirectComplexCoefficientProvider(),
            edgePolicy: .validOnly,
            retainPerTrial: true
        )

        try compare(result.meanWTPL, fixture.expected.meanWTPL, tolerance: 2e-12)
        try compare(try #require(result.deltaWTPL), fixture.expected.deltaWTPL, tolerance: 2e-12)
        try compare(result.varianceWTPL, fixture.expected.varianceWTPL, tolerance: 2e-12)
        #expect(result.validTrialCounts == fixture.expected.validTrialCounts)
        #expect(result.perTrialWTPL?.count == input.trials.count)
        #expect(result.baselineWindowMs == -625 ... -500)
    }

    @Test func sustainedOscillationIsNearOneAndAmplitudeInvariant() throws {
        let rate = 100.0
        let base = (0..<500).map { sin(2 * .pi * 10 * Double($0) / rate) }
        let scaled = base.map { -7.25 * $0 }
        let a = try analyze([base], samplingRate: rate)
        let b = try analyze([scaled], samplingRate: rate)
        let center = 100..<400
        #expect(center.compactMap { finite(a.meanWTPL[0][$0]) }.allSatisfy { $0 > 0.999 })
        #expect(center.allSatisfy { index in
            guard a.meanWTPL[0][index].isFinite, b.meanWTPL[0][index].isFinite else { return true }
            return abs(a.meanWTPL[0][index] - b.meanWTPL[0][index]) < 1e-12
        })
    }

    @Test func phaseResetProducesLocalDecrease() throws {
        let rate = 100.0
        let phases = (0..<500).map { index in
            2 * Double.pi * 10 * Double(index) / rate + (index >= 250 ? 1.4 : 0)
        }
        let result = try WTPLEngine.analyze(
            trials: [phases], samplingRate: rate,
            plan: .explicit(frequenciesHz: [10], nCycles: 5),
            lagCycles: [-1, 1], baseline: nil, eventSampleIndex: 250,
            coefficientProvider: PhaseCoefficientProvider(),
            edgePolicy: .referenceSamePadding, retainPerTrial: false
        )
        #expect(result.meanWTPL[0][250] < 0.8)
        #expect(result.meanWTPL[0][150] > 0.999999)
    }

    @Test func fractionalLagsInterpolateComplexCoefficients() throws {
        let phases = (0..<40).map { Double($0) * 0.31 + 0.004 * Double($0 * $0) }
        let result = try WTPLEngine.analyze(
            trials: [phases], samplingRate: 20,
            plan: .explicit(frequenciesHz: [8], nCycles: 5),
            lagCycles: [-1, 1], baseline: nil, eventSampleIndex: 20,
            coefficientProvider: PhaseCoefficientProvider(),
            edgePolicy: .referenceSamePadding, retainPerTrial: false
        )
        #expect(result.meanWTPL[0][20].isFinite)
        #expect(result.meanWTPL[0][20] < 1)
        #expect(result.validTrialCounts[0][1] == 0)
        #expect(result.validTrialCounts[0][38] == 0)
    }

    @Test func onlineMeanMatchesRetainedTrialsAndBaselineCentersEachFrequency() throws {
        let rate = 100.0
        let trials = (0..<5).map { trial in
            (0..<500).map { index in
                sin(2 * .pi * 10 * Double(index) / rate + Double(trial) * 0.73)
            }
        }
        let result = try WTPLEngine.analyze(
            trials: trials, samplingRate: rate,
            plan: .explicit(frequenciesHz: [10], nCycles: 5),
            lagCycles: [-1, 1], baseline: .init(startSample: 100, endSample: 199),
            eventSampleIndex: 250,
            coefficientProvider: DirectComplexCoefficientProvider(),
            retainPerTrial: true
        )
        let retained = try #require(result.perTrialWTPL)
        for time in result.meanWTPL[0].indices where result.meanWTPL[0][time].isFinite {
            let values = retained.compactMap { finite($0[0][time]) }
            #expect(abs(result.meanWTPL[0][time] - values.reduce(0, +) / Double(values.count)) < 1e-13)
        }
        let baseline = try #require(result.deltaWTPL)[0][100...199].filter(\.isFinite)
        #expect(abs(baseline.reduce(0, +) / Double(baseline.count)) < 1e-13)
    }

    @Test func separateTrialsCannotShareLagSamples() throws {
        let phases = (0..<20).map { Double($0) * 0.4 }
        let result = try WTPLEngine.analyze(
            trials: [phases, phases], samplingRate: 20,
            plan: .explicit(frequenciesHz: [5], nCycles: 5),
            lagCycles: [-1, 1], baseline: nil, eventSampleIndex: 10,
            coefficientProvider: PhaseCoefficientProvider(),
            edgePolicy: .referenceSamePadding, retainPerTrial: true
        )
        #expect(result.validTrialCounts[0][0] == 0)
        #expect(result.validTrialCounts[0][4] == 2)
        #expect(result.validTrialCounts[0][19] == 0)
    }

    @Test func wtplAndITPCHaveDifferentInterpretations() throws {
        let offsets = [0.0, .pi / 2, .pi, 3 * .pi / 2]
        let trials = offsets.map { offset in
            (0..<100).map { 2 * .pi * 5 * Double($0) / 100 + offset }
        }
        let result = try WTPLEngine.analyze(
            trials: trials, samplingRate: 100,
            plan: .explicit(frequenciesHz: [5], nCycles: 5),
            lagCycles: [-1, 1], baseline: nil, eventSampleIndex: 50,
            coefficientProvider: PhaseCoefficientProvider(),
            edgePolicy: .referenceSamePadding, retainPerTrial: false
        )
        let wtpl = result.meanWTPL[0][50]
        let phasesAtTime = trials.map { $0[50] }
        let itpcReal = phasesAtTime.map(cos).reduce(0, +) / Double(phasesAtTime.count)
        let itpcImaginary = phasesAtTime.map(sin).reduce(0, +) / Double(phasesAtTime.count)
        let itpc = hypot(itpcReal, itpcImaginary)
        #expect(wtpl > 0.999999)
        #expect(itpc < 1e-12)
    }

    @Test func invalidBaselineIsRejectedInsteadOfSilentlyShrunk() {
        #expect(throws: WTPLAnalysisError.invalidBaseline(start: -1, end: 20, sampleCount: 20)) {
            try WTPLEngine.analyze(
                trials: [[Double](repeating: 1, count: 20)], samplingRate: 20,
                plan: .explicit(frequenciesHz: [5], nCycles: 5), lagCycles: [-1, 1],
                baseline: .init(startSample: -1, endSample: 20), eventSampleIndex: 10,
                coefficientProvider: PhaseCoefficientProvider(), retainPerTrial: false
            )
        }
    }

    private func analyze(_ trials: [[Double]], samplingRate: Double) throws -> WTPLResult {
        try WTPLEngine.analyze(
            trials: trials, samplingRate: samplingRate,
            plan: .explicit(frequenciesHz: [10], nCycles: 5),
            lagCycles: [-1, 1], baseline: nil, eventSampleIndex: trials[0].count / 2,
            coefficientProvider: DirectComplexCoefficientProvider(), retainPerTrial: false
        )
    }

    private func compare(_ actual: [[Double]], _ expected: [[Double?]], tolerance: Double) throws {
        #expect(actual.count == expected.count)
        for frequency in expected.indices {
            #expect(actual[frequency].count == expected[frequency].count)
            for time in expected[frequency].indices {
                if let expectedValue = expected[frequency][time] {
                    #expect(abs(actual[frequency][time] - expectedValue) < tolerance)
                } else {
                    #expect(actual[frequency][time].isNaN)
                }
            }
        }
    }

    private func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }
}

private nonisolated struct PhaseCoefficientProvider: ComplexCoefficientProvider {
    func coefficients(
        signal: [Double], samplingRate: Double, frequencyHz: Double,
        widthCycles: Double, edgePolicy: RhythmicityEdgePolicy,
        cancellation: RhythmicityCancellation
    ) throws -> ComplexCoefficientTile {
        try cancellation.check()
        return ComplexCoefficientTile(
            frequencyHz: frequencyHz,
            real: signal.map(cos), imaginary: signal.map(sin), validSampleRange: signal.indices
        )
    }
}
