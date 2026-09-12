//
//  RhythmicityMFFIntegrationTests.swift
//  EVATests
//
//  Local-only integration checks for the two large MFF recordings supplied for
//  Rhythmicity Explorer development. The recordings remain outside the repo.
//

import Foundation
import XCTest
@testable import EVA

final class RhythmicityMFFIntegrationTests: XCTestCase {
    private struct Expected {
        var bytes: Int64
        var samples: Int
        var duration: Double
    }

    func testSuppliedMFFRecordingsLoadThroughEVA() throws {
        guard let path = externalRootPath() else {
            throw XCTSkip(
                "Set EVA_RHYTHMICITY_MFF_ROOT, or put the path in "
                    + "/private/tmp/eva-rhythmicity-mff-root.txt"
            )
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let packages = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
            .filter { $0.pathExtension.lowercased() == "mff" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let expected = [
            Expected(bytes: 790_372_460, samples: 768_840, duration: 768.840),
            Expected(bytes: 783_569_148, samples: 762_222, duration: 762.222),
        ]
        XCTAssertEqual(packages.count, expected.count)
        for (package, expectation) in zip(packages, expected) {
            try check(package: package, expected: expectation)
        }
    }

    private func externalRootPath() -> String? {
        if let value = ProcessInfo.processInfo.environment["EVA_RHYTHMICITY_MFF_ROOT"],
           !value.isEmpty {
            return value
        }
        let marker = URL(fileURLWithPath: "/private/tmp/eva-rhythmicity-mff-root.txt")
        guard let value = try? String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func check(package: URL, expected: Expected) throws {
        let signalFile = package.appendingPathComponent("signal1.bin")
        let values = try signalFile.resourceValues(forKeys: [.fileSizeKey])
        XCTAssertEqual(Int64(values.fileSize ?? -1), expected.bytes)

        let signal = try MFFReader().loadSignal(from: package)
        XCTAssertEqual(signal.numberOfChannels, 257)
        XCTAssertEqual(signal.data.count, 257)
        XCTAssertEqual(signal.samplingRate, 1000, accuracy: 1e-12)
        XCTAssertEqual(signal.data.first?.count, expected.samples)
        XCTAssertEqual(signal.duration, expected.duration, accuracy: 1e-9)
        XCTAssertFalse(signal.isSegmented)
        XCTAssertTrue(signal.data.prefix(3).allSatisfy { channel in
            channel.prefix(2_000).allSatisfy(\.isFinite)
        })

        // Exercise the Milestone 1 numerical path without retaining or copying
        // a full-recording waveform fixture. The complete package load above is
        // the ingestion gate; this bounded window is the direct-CPU smoke gate.
        let analysisSampleCount = min(Int(signal.samplingRate * 12), expected.samples)
        let analysisSamples = signal.data[0].prefix(analysisSampleCount).map(Double.init)
        let input = RhythmicityInput.entireRecording(
            channels: [
                RhythmicityChannelInput(
                    channelIndex: 0,
                    channelName: signal.channelNames?.first ?? "E1",
                    samples: analysisSamples
                )
            ],
            samplingRate: signal.samplingRate,
            source: RhythmicitySourceDescriptor(
                recordingIdentity: "external-mff-smoke",
                displayName: "External MFF"
            ),
            processingProvenance: RhythmicityProcessingProvenance(
                sourceRevision: signal.dataRevision.uuidString
            )
        )
        var configuration = RhythmicityPreset.paperLAVI2026Exploratory
        configuration.backend = .directReferenceCPU
        configuration.frequenciesHz = [6, 10, 20, 40]
        let clock = ContinuousClock()
        let directStart = clock.now
        let result = try LAVIEngine.analyze(input: input, configuration: configuration)
        let directDuration = clock.now - directStart
        XCTAssertEqual(result.channels.count, 1)
        XCTAssertTrue(result.channels[0].values.allSatisfy(\.isFinite))
        XCTAssertTrue(result.channels[0].values.allSatisfy { (0...1).contains($0) })
        XCTAssertTrue(result.channels[0].validPairCounts.allSatisfy { $0 > 0 })
        XCTAssertNil(result.channels[0].lowerSignificance)
        XCTAssertNil(result.channels[0].upperSignificance)

        var productionConfiguration = configuration
        productionConfiguration.backend = .accelerateFFTCPU
        let productionStart = clock.now
        let productionResult = try LAVIEngine.analyze(
            input: input,
            configuration: productionConfiguration
        )
        let productionDuration = clock.now - productionStart
        XCTAssertEqual(
            productionResult.channels[0].validPairCounts,
            result.channels[0].validPairCounts
        )
        for index in configuration.frequenciesHz.indices {
            XCTAssertEqual(
                productionResult.channels[0].values[index],
                result.channels[0].values[index],
                accuracy: 1e-11
            )
        }
        XCTAssertLessThan(productionDuration, directDuration)
        print(
            "External MFF \(expected.samples) samples: direct \(directDuration), "
                + "production FFT \(productionDuration)"
        )

        // Milestone 6 real-signal smoke gate. The recordings are continuous,
        // so bounded, non-overlapping windows serve only as trial containers;
        // they do not claim experimental condition semantics. This validates
        // the direct and production WTPL reductions on observed MFF samples.
        try checkWTPL(signal: signal)

        // Milestone 7 real-signal smoke gate. Exercise the exact production
        // coefficient, single-trial WTPL, and map-domain detector chain on a
        // bounded observed interval without treating detections as artifacts.
        try checkBursts(signal: signal)

        // Exercise Milestone 2 against observed values from each supplied MFF.
        // The bounded window keeps the full 200-surrogate gate practical while
        // using the real production FFT coefficient provider.
        let inferenceSampleCount = min(2_048, expected.samples)
        let inferenceInput = RhythmicityInput.entireRecording(
            channels: [
                RhythmicityChannelInput(
                    channelIndex: 0,
                    channelName: signal.channelNames?.first ?? "E1",
                    samples: signal.data[0].prefix(inferenceSampleCount).map(Double.init)
                )
            ],
            samplingRate: signal.samplingRate,
            source: RhythmicitySourceDescriptor(
                recordingIdentity: "external-mff-significance-smoke",
                displayName: "External MFF"
            ),
            processingProvenance: RhythmicityProcessingProvenance(
                sourceRevision: signal.dataRevision.uuidString
            )
        )
        var inferenceConfiguration = RhythmicityPreset.paperLAVI2026(
            seed: UInt64(expected.samples)
        )
        inferenceConfiguration.frequenciesHz = [6, 10, 20, 40]
        guard case var .onDemand(significance) = inferenceConfiguration.significance else {
            XCTFail("Paper preset did not enable on-demand significance")
            return
        }
        significance.aperiodicFitRangeHz = 3...80
        inferenceConfiguration.significance = .onDemand(significance)
        let inferenceResult = try LAVIEngine.analyze(
            input: inferenceInput,
            configuration: inferenceConfiguration
        )
        let inferenceChannel = try XCTUnwrap(inferenceResult.channels.first)
        XCTAssertEqual(inferenceChannel.significanceRibbon?.surrogateCount, 200)
        XCTAssertEqual(inferenceChannel.surrogateSummary?.retainedCount, 200)
        XCTAssertEqual(inferenceChannel.surrogateSummary?.diagnostics.count, 200)
        XCTAssertEqual(inferenceChannel.aperiodicFit?.welchWindowCount, 1)
        XCTAssertTrue(inferenceChannel.lowerSignificance?.allSatisfy(\.isFinite) == true)
        XCTAssertTrue(inferenceChannel.upperSignificance?.allSatisfy(\.isFinite) == true)
        XCTAssertTrue(inferenceChannel.bands.allSatisfy { $0.isSignificant != nil })
    }

    private func checkWTPL(signal: MFFSignalData) throws {
        let trialLength = 2_000
        let trialCount = min(4, (signal.data.first?.count ?? 0) / trialLength)
        XCTAssertGreaterThanOrEqual(trialCount, 2)
        let trials = (0..<trialCount).map { trial in
            signal.data[0][(trial * trialLength)..<((trial + 1) * trialLength)].map(Double.init)
        }
        let plan = TFFrequencyPlan.explicit(frequenciesHz: [8, 10, 20], nCycles: 5)
        let baseline = WTPLBaselineSpec(startSample: 500, endSample: 750)
        let direct = try WTPLEngine.analyze(
            trials: trials,
            samplingRate: signal.samplingRate,
            plan: plan,
            lagCycles: [-1, 1],
            baseline: baseline,
            eventSampleIndex: 1_000,
            coefficientProvider: DirectComplexCoefficientProvider(),
            retainPerTrial: false
        )
        let production = try WTPLEngine.analyze(
            trials: trials,
            samplingRate: signal.samplingRate,
            plan: plan,
            lagCycles: [-1, 1],
            baseline: baseline,
            eventSampleIndex: 1_000,
            coefficientProvider: AccelerateFFTComplexCoefficientProvider(),
            retainPerTrial: false
        )

        XCTAssertEqual(production.validTrialCounts, direct.validTrialCounts)
        var sameMask = true
        var allFiniteValuesInRange = true
        var maximumError = 0.0
        for frequency in plan.frequenciesHz.indices {
            for time in 0..<trialLength {
                let reference = direct.meanWTPL[frequency][time]
                let actual = production.meanWTPL[frequency][time]
                if reference.isFinite, actual.isFinite {
                    maximumError = max(maximumError, abs(reference - actual))
                    allFiniteValuesInRange = allFiniteValuesInRange && (0...1).contains(actual)
                } else {
                    sameMask = sameMask && reference.isNaN && actual.isNaN
                }
            }
            let baselineValues = try XCTUnwrap(production.deltaWTPL)[frequency][500...750]
                .filter(\.isFinite)
            XCTAssertFalse(baselineValues.isEmpty)
            XCTAssertEqual(
                baselineValues.reduce(0, +) / Double(baselineValues.count),
                0,
                accuracy: 1e-12
            )
        }
        XCTAssertTrue(sameMask)
        XCTAssertTrue(allFiniteValuesInRange)
        XCTAssertLessThan(maximumError, 1e-10)
    }

    private func checkBursts(signal: MFFSignalData) throws {
        let count = min(12_000, signal.data[0].count)
        let samples = signal.data[0].prefix(count).map(Double.init)
        let frequencies = [8.0, 10.0, 20.0]
        let provider = AccelerateFFTComplexCoefficientProvider()
        var power = [[Double]](repeating: [Double](repeating: .nan, count: count), count: frequencies.count)
        var wtpl = power
        for frequencyIndex in frequencies.indices {
            let tile = try provider.coefficients(
                signal: samples, samplingRate: signal.samplingRate,
                frequencyHz: frequencies[frequencyIndex], widthCycles: 5,
                edgePolicy: .validOnly, cancellation: RhythmicityCancellation()
            )
            wtpl[frequencyIndex] = WTPLEngine.singleTrialValues(
                tile: tile, frequencyHz: frequencies[frequencyIndex],
                samplingRate: signal.samplingRate, lagCycles: [-1, 1]
            )
            for sample in tile.validSampleRange {
                power[frequencyIndex][sample] = tile.real[sample] * tile.real[sample]
                    + tile.imaginary[sample] * tile.imaginary[sample]
            }
        }
        let output = try RhythmicBurstDetector.detect(
            power: power, wtpl: wtpl, frequenciesHz: frequencies,
            samplingRate: signal.samplingRate, channelIndex: 0,
            channelName: signal.channelNames?.first ?? "E1", segmentIndex: 0
        )
        XCTAssertEqual(output.peakPowerThresholds.count, frequencies.count)
        XCTAssertTrue(output.peakPowerThresholds.allSatisfy(\.isFinite))
        XCTAssertTrue(output.bursts.allSatisfy {
            $0.onsetGlobalSample >= 0 && $0.offsetGlobalSample < count
                && $0.durationCycles >= 1 && $0.boundarySource == .powerPercentile
        })
    }
}
