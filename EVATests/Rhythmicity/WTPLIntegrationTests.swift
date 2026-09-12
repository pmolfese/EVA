//
//  WTPLIntegrationTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

struct WTPLIntegrationTests {
    @Test func eventExportContainsRawDeltaCountsScalarsAndProvenance() throws {
        let channel = WTPLChannelResult(
            channelIndex: 4,
            channelName: "E5",
            meanWTPL: [[.nan, 0.8, 0.9], [.nan, 0.6, 0.7]],
            deltaWTPL: [[.nan, -0.05, 0.05], [.nan, -0.1, 0.1]],
            validTrialCounts: [[0, 8, 8], [0, 7, 8]],
            varianceWTPL: [[.nan, 0.01, 0.02], [.nan, 0.03, 0.04]],
            trialCount: 8
        )
        let result = WTPLAnalysisResult(
            source: .init(recordingIdentity: "fixture#revision", displayName: "Fixture.mff"),
            processingProvenance: .init(sourceRevision: "revision", processingSummary: ["Average reference"]),
            frequenciesHz: [8, 10],
            timesMs: [-100, 0, 100],
            nCycles: [5, 5],
            lagCycles: [-1, 1],
            edgePolicy: .validOnly,
            baselineWindowMs: -100 ... 0,
            conditions: [.init(condition: "faces / target", channels: [channel])],
            warnings: [.wtplNoValidSamples(frequencyHz: 3.16)]
        )
        let contents = try WTPLExport.bundle(
            result: result,
            bands: [.init(name: "Alpha", lowHz: 8, highHz: 12)],
            windows: [.init(label: "-100–100 ms", startMs: -100, endMs: 100)],
            exportedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(Set(contents.files.keys) == [
            "wtpl-faces---target.npy", "delta-wtpl-faces---target.npy",
            "wtpl-valid-counts-faces---target.npy", "wtpl-scalars.csv",
            "manifest.json", "warnings.txt",
        ])
        for name in ["wtpl-faces---target.npy", "delta-wtpl-faces---target.npy", "wtpl-valid-counts-faces---target.npy"] {
            let data = try #require(contents.files[name])
            #expect(Array(data.prefix(6)) == [0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59])
            #expect(String(decoding: data.prefix(128), as: UTF8.self).contains("'shape': (1, 2, 3)"))
        }

        let csv = String(decoding: try #require(contents.files["wtpl-scalars.csv"]), as: UTF8.self)
        #expect(csv.contains("wtpl,0.75,0"))
        #expect(csv.contains("delta_wtpl,0,0"))
        let manifest = try #require(contents.files["manifest.json"])
        let json = try #require(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        #expect(json["methodVersion"] as? String == WTPLEngine.methodVersion)
        let reference = try #require(json["reference"] as? [String: Any])
        #expect(reference["kind"] as? String == "independent paper-equation Python oracle")
    }

    @Test func timeFrequencyShortcutDelegatesToSharedEngine() throws {
        let samplingRate = 200.0
        let trialLength = 400
        let trials = (0..<3).map { trial in
            (0..<trialLength).map { sample in
                sin(2 * Double.pi * 10 * Double(sample) / samplingRate + Double(trial) * 0.73)
            }
        }
        let signal = SyntheticSignal.make([trials.flatMap { $0 }.map(Float.init)], samplingRate: samplingRate)
        let segments = trials.indices.map { trial in
            EpochSegment(
                startSample: trial * trialLength,
                endSample: (trial + 1) * trialLength - 1,
                stimulusOffsetSamples: 200,
                category: "A",
                sourceCode: "A",
                sourceTimeSeconds: Double(trial * trialLength) / samplingRate,
                colorIndex: 0,
                contributingEpochCount: 1
            )
        }
        let plan = TFFrequencyPlan.explicit(frequenciesHz: [10], nCycles: 5)
        let context = TimeFrequencyExport.Context(
            plan: plan,
            method: .morlet,
            timeBandwidth: 4,
            baselineMethod: .decibel,
            bands: [.init(name: "Alpha", lowHz: 8, highHz: 12)],
            windows: [.init(label: "0–200 ms", startMs: 0, endMs: 200)],
            wtplShowsDelta: true,
            wtplBaselineStartMs: -500,
            wtplBaselineEndMs: -100,
            wtplLagCycles: [-1, 1]
        )
        let shortcut = try #require(TimeFrequencyExport.wtplConditionMaps(
            signal: signal,
            segments: segments,
            condition: "A",
            channelIndices: [0],
            channelNames: ["Cz"],
            context: context
        ))
        let stack = TimeFrequencyTrials.stack(
            signal: signal, segments: segments, category: "A", channelIndices: [0]
        )
        let direct = try WTPLEngine.analyze(
            trials: stack.trials,
            samplingRate: samplingRate,
            plan: plan,
            lagCycles: [-1, 1],
            baseline: .init(startSample: 100, endSample: 180),
            eventSampleIndex: 200,
            coefficientProvider: AccelerateFFTComplexCoefficientProvider(),
            retainPerTrial: false
        )

        let rawComparison = compare(try #require(shortcut.wtpl?.first), direct.meanWTPL)
        let deltaComparison = compare(
            try #require(shortcut.deltaWTPL?.first),
            try #require(direct.deltaWTPL)
        )
        #expect(rawComparison.sameNaNMask && rawComparison.maxError < 1e-12)
        #expect(deltaComparison.sameNaNMask && deltaComparison.maxError < 1e-12)
        #expect(shortcut.wtplValidTrialCounts == [direct.validTrialCounts])
        #expect(shortcut.timesMs == direct.timesMs)

        let scalarRows = TimeFrequencyExport.scalarCSVRows([shortcut], context: context)
        let measures = scalarRows.filter { $0.first == "tf_scalar" }.map { $0[7] }
        #expect(measures.contains("wtpl"))
        #expect(measures.contains("delta_wtpl"))
        #expect(!measures.contains("ersp"))
        #expect(!measures.contains("itpc"))
    }

    @Test func conditionDifferenceKeepsMinimumValidSupport() throws {
        func maps(_ condition: String, value: Double, count: Int) -> TimeFrequencyExport.ConditionMaps {
            .init(
                condition: condition,
                channelIndices: [2],
                channelNames: ["Cz"],
                ersp: [[[.nan]]],
                itpc: [[[.nan]]],
                wtpl: [[[value]]],
                deltaWTPL: [[[value - 0.5]]],
                wtplValidTrialCounts: [[[count]]],
                frequenciesHz: [10],
                timesMs: [0]
            )
        }
        let difference = try #require(TimeFrequencyExport.differenceMaps(
            maps("A", value: 0.9, count: 12),
            maps("B", value: 0.6, count: 8),
            label: "A − B"
        ))
        #expect(abs((difference.wtpl?[0][0][0] ?? .nan) - 0.3) < 1e-12)
        #expect(difference.wtplValidTrialCounts == [[[8]]])
    }

    private func compare(_ lhs: [[Double]], _ rhs: [[Double]]) -> (sameNaNMask: Bool, maxError: Double) {
        guard lhs.count == rhs.count else { return (false, .infinity) }
        var sameNaNMask = true
        var maxError = 0.0
        for frequency in lhs.indices {
            guard lhs[frequency].count == rhs[frequency].count else { return (false, .infinity) }
            for time in lhs[frequency].indices {
                let a = lhs[frequency][time]
                let b = rhs[frequency][time]
                if a.isNaN || b.isNaN {
                    sameNaNMask = sameNaNMask && a.isNaN && b.isNaN
                } else {
                    maxError = max(maxError, abs(a - b))
                }
            }
        }
        return (sameNaNMask, maxError)
    }
}
