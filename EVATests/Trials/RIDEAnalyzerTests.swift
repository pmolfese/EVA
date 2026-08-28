//
//  RIDEAnalyzerTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation
import Testing
@testable import EVA

struct RIDEAnalyzerTests {
    private let samplingRate = 1_000.0
    private let stimulusOffsetSamples = 120
    private let length = 420

    private func gaussian(center: Int, amplitude: Double = 1.0, width: Double = 8.0) -> [Float] {
        (0..<length).map { sample in
            let z = Double(sample - center) / width
            return Float(amplitude * exp(-0.5 * z * z))
        }
    }

    private func add(_ traces: [[Float]]) -> [Float] {
        guard let first = traces.first else { return [] }
        var out = [Float](repeating: 0, count: first.count)
        for trace in traces {
            for i in trace.indices {
                out[i] = Float(Double(out[i]) + Double(trace[i]))
            }
        }
        return out
    }

    private func trial(centralShift: Int, responseLatencyMs: Double? = nil, time: Double = 0) -> RIDEAnalyzer.TrialInput {
        let responseLatencySamples = Int(((responseLatencyMs ?? 0) / 1000.0 * samplingRate).rounded())
        var parts = [
            gaussian(center: stimulusOffsetSamples + 35, amplitude: 0.45, width: 7),
            gaussian(center: stimulusOffsetSamples + 130 + centralShift, amplitude: 1.2, width: 10)
        ]
        if responseLatencyMs != nil {
            parts.append(gaussian(center: stimulusOffsetSamples + responseLatencySamples + 30, amplitude: -0.8, width: 9))
        }
        return RIDEAnalyzer.TrialInput(
            sourceTimeSeconds: time,
            stimulusOffsetSamples: stimulusOffsetSamples,
            responseLatencyMs: responseLatencyMs,
            samples: add(parts)
        )
    }

    @Test func decomposesStimulusAndCentralComponents() throws {
        let shifts = [-18, -5, 12, 24]
        let result = try #require(RIDEAnalyzer.decompose(
            trials: shifts.enumerated().map { index, shift in trial(centralShift: shift, time: Double(index)) },
            samplingRate: samplingRate,
            configuration: RIDEAnalyzer.Configuration(
                includesStimulusComponent: true,
                includesCentralComponent: true,
                includesResponseComponent: false,
                centralWindow: RIDEAnalyzer.ComponentWindow(startMs: 80, endMs: 190),
                centralMaxLagMs: 40,
                maxIterations: 8,
                convergenceToleranceSamples: 0
            )
        ))

        #expect(result.component(.stimulus) != nil)
        #expect(result.component(.central) != nil)
        #expect(result.component(.response) == nil)
        #expect(result.trialLatencies.count == shifts.count)
        let estimated = result.trialLatencies.compactMap(\.centralLatencyShiftSamples)
        let estimatedAnchor = estimated.sorted()[estimated.count / 2]
        let expectedAnchor = shifts.sorted()[shifts.count / 2]
        for (latency, expected) in zip(result.trialLatencies, shifts) {
            let centeredEstimate = try #require(latency.centralLatencyShiftSamples) - estimatedAnchor
            let centeredExpected = expected - expectedAnchor
            #expect(abs(centeredEstimate - centeredExpected) <= 2)
        }
    }

    @Test func responseComponentIsOptional() throws {
        let result = try #require(RIDEAnalyzer.decompose(
            trials: [trial(centralShift: 0), trial(centralShift: 10)],
            samplingRate: samplingRate,
            configuration: RIDEAnalyzer.Configuration(
                includesStimulusComponent: true,
                includesCentralComponent: true,
                includesResponseComponent: false,
                centralWindow: RIDEAnalyzer.ComponentWindow(startMs: 80, endMs: 190)
            )
        ))

        #expect(result.components.map(\.component) == [.stimulus, .central])
        #expect(result.trialLatencies.allSatisfy { $0.responseLatencyMs == nil })
    }

    @Test func includesResponseComponentWhenRequested() throws {
        let result = try #require(RIDEAnalyzer.decompose(
            trials: [
                trial(centralShift: -8, responseLatencyMs: 140, time: 1),
                trial(centralShift: 5, responseLatencyMs: 200, time: 2),
                trial(centralShift: 16, responseLatencyMs: 250, time: 3)
            ],
            samplingRate: samplingRate,
            configuration: RIDEAnalyzer.Configuration(
                includesStimulusComponent: true,
                includesCentralComponent: true,
                includesResponseComponent: true,
                centralWindow: RIDEAnalyzer.ComponentWindow(startMs: 80, endMs: 190),
                responseLatencySource: .estimated,
                centralMaxLagMs: 35,
                defaultResponseLatencyMs: 400,
                maxIterations: 6,
                convergenceToleranceSamples: 0
            )
        ))

        #expect(result.component(.response) != nil)
        #expect((result.component(.response)?.rms ?? 0) > 0.01)
        #expect(result.trialLatencies.compactMap(\.responseLatencyMs).map { Int($0.rounded()) } == [140, 200, 250])
        #expect(result.centralAlignedAverage != nil)
        #expect(result.responseAlignedAverage != nil)
    }

    @Test func supportsCentralOnlyMode() throws {
        let result = try #require(RIDEAnalyzer.decompose(
            trials: [trial(centralShift: -12), trial(centralShift: 12)],
            samplingRate: samplingRate,
            configuration: RIDEAnalyzer.Configuration(
                includesStimulusComponent: false,
                includesCentralComponent: true,
                includesResponseComponent: false,
                centralWindow: RIDEAnalyzer.ComponentWindow(startMs: 80, endMs: 190)
            )
        ))

        #expect(result.components.map(\.component) == [.central])
        #expect(result.centralAlignedAverage != nil)
        #expect(result.responseAlignedAverage == nil)
    }

    @Test func returnsNilForInvalidInputs() {
        let result = RIDEAnalyzer.decompose(
            trials: [],
            samplingRate: samplingRate,
            configuration: RIDEAnalyzer.Configuration(
                centralWindow: RIDEAnalyzer.ComponentWindow(startMs: 80, endMs: 190)
            )
        )
        #expect(result == nil)
    }

    @Test func responseMarkersAreRequiredForPerTrialLocking() {
        let missingMarker = RIDEAnalyzer.TrialInput(
            sourceTimeSeconds: 0,
            stimulusOffsetSamples: stimulusOffsetSamples,
            responseLatencyMs: nil,
            samples: trial(centralShift: 0).samples
        )
        let result = RIDEAnalyzer.decompose(
            trials: [missingMarker],
            samplingRate: samplingRate,
            configuration: RIDEAnalyzer.Configuration(
                includesStimulusComponent: false,
                includesCentralComponent: false,
                includesResponseComponent: true,
                centralWindow: RIDEAnalyzer.ComponentWindow(startMs: 80, endMs: 190),
                responseLatencySource: .estimated
            )
        )
        #expect(result == nil)
    }

    @Test func fixedResponseMarkerIsExplicitlyDiagnosed() throws {
        let result = try #require(RIDEAnalyzer.decompose(
            trials: [trial(centralShift: 0), trial(centralShift: 8)],
            samplingRate: samplingRate,
            configuration: RIDEAnalyzer.Configuration(
                includesStimulusComponent: true,
                includesCentralComponent: true,
                includesResponseComponent: true,
                centralWindow: RIDEAnalyzer.ComponentWindow(startMs: 80, endMs: 190),
                responseLatencySource: .fixed,
                defaultResponseLatencyMs: 400
            )
        ))
        #expect(result.trialLatencies.compactMap(\.responseLatencyMs) == [400, 400])
        #expect(result.warnings.contains { $0.contains("one fixed marker") })
    }

    @Test func componentEstimationUsesRobustPointwiseMedian() throws {
        let normal = trial(centralShift: 0).samples
        var outlier = normal
        for index in outlier.indices { outlier[index] *= 100 }
        let inputs = [normal, normal, outlier].enumerated().map { index, samples in
            RIDEAnalyzer.TrialInput(
                sourceTimeSeconds: Double(index),
                stimulusOffsetSamples: stimulusOffsetSamples,
                responseLatencyMs: nil,
                samples: samples
            )
        }
        let result = try #require(RIDEAnalyzer.decompose(
            trials: inputs,
            samplingRate: samplingRate,
            configuration: RIDEAnalyzer.Configuration(
                includesStimulusComponent: false,
                includesCentralComponent: true,
                includesResponseComponent: false,
                centralWindow: RIDEAnalyzer.ComponentWindow(startMs: 80, endMs: 190),
                centralLatencySource: .stimulusLocked,
                maxIterations: 2
            )
        ))
        let peak = result.component(.central)?.lockedTemplate.map { abs(Double($0)) }.max() ?? 0
        let normalPeak = normal.map { abs(Double($0)) }.max() ?? 0
        #expect(abs(peak - normalPeak) < 0.01)
    }
}
