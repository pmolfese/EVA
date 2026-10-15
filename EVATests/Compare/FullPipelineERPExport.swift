//
//  FullPipelineERPExport.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Not a regression test: a one-off export harness that runs EVA's actual,
//  unmodified production functions — filter, interpolate, average-reference,
//  epoch, baseline-correct, average — end to end on a real flanker-task MFF
//  recording, and writes the resulting ERPs to JSON so a Python script
//  (Tools/mne-compare/make_full_pipeline_reference.py) can run the equivalent
//  MNE pipeline on the same file and plot both. `@testable import EVA` is the
//  only practical way to call EVA's internal pipeline functions without a
//  dedicated CLI target, hence writing this as a Swift Testing test rather
//  than a real command-line tool.
//
//  Runs only when the real recording is present locally (git-ignored, like
//  every other real-file fixture here) — see Tools/mne-compare/README.md.
//

import Foundation
import Testing
import simd
@testable import EVA

@Suite("Full pipeline ERP export (real recording, not a regression gate)")
struct FullPipelineERPExport {

    static let mffPath = "/Users/molfesepj/Desktop/MFF_tests/24624/24624_flanker_run1_20240322_053029.mff"
    /// The app-sandboxed test host can't write into the repo tree directly
    /// (`com.apple.security.app-sandbox` only grants its own container and
    /// user-selected paths) — write to the container's own temporary
    /// directory instead, and copy it into
    /// `EVATests/Fixtures/Compare/local/` from outside the sandbox afterward.
    static let outputPath = {
        FileManager.default.temporaryDirectory.appendingPathComponent("eva_full_pipeline_erp.json")
    }()

    /// E82/E66 are the two channels with by far the highest raw variance in
    /// this recording (~5x the median; see Tools/mne-compare/README.md) — a
    /// simple, reproducible stand-in for "flag noisy channels," picked once
    /// from the raw data so both the EVA and MNE pipelines mark the same
    /// channels bad rather than each running their own detector.
    static let badChannelNames: Set<String> = ["E82", "E66"]
    static let congruentCodes: Set<String> = ["LC++", "RC++"]
    static let incongruentCodes: Set<String> = ["LI++", "RI++"]
    static let preStimulus = 0.2
    static let postStimulus = 0.8

    @Test("run EVA's full pipeline and export the ERP")
    func exportFullPipelineERP() async throws {
        guard FileManager.default.fileExists(atPath: Self.mffPath) else {
            print("real recording not present at \(Self.mffPath) — skipping export")
            return
        }

        let packageURL = URL(fileURLWithPath: Self.mffPath)
        let signal = try MFFReader().loadSignal(from: packageURL)
        let geometry = try #require(ElectrodeGeometry.load(fromPackageContaining: signal.signalURL))

        // Restrict to the 129 named "E<n>" EEG channels, in that order —
        // drops VREF (the physical reference, zero variance/uninformative)
        // and any other non-EEG channel the package happens to carry.
        let channelNames = try #require(signal.channelNames)
        var eegIndices: [Int] = []
        var eegNames: [String] = []
        for (index, name) in channelNames.enumerated() where name.hasPrefix("E") && Int(name.dropFirst()) != nil {
            eegIndices.append(index)
            eegNames.append(name)
        }
        #expect(eegIndices.count > 100, "expected roughly a full net of E<n> channels, got \(eegIndices.count)")

        let eegData = eegIndices.map { signal.data[$0] }
        let eegPositions: [Int: SIMD3<Double>] = Dictionary(
            uniqueKeysWithValues: eegIndices.enumerated().compactMap { newIndex, oldIndex in
                geometry.positions[oldIndex].map { (newIndex, $0) }
            }
        )

        // 1. Filter — EVA's MNE-reproducing FIR design (see MNERealFileReferenceTests).
        let filtered = try await EEGSignalFilter.bandPass(
            channels: eegData,
            samplingRate: signal.samplingRate,
            lowCutoff: 1.0,
            highCutoff: 40.0,
            highPassFamily: .fir,
            lowPassFamily: .fir,
            firWindow: .hamming,
            firApplication: .delayCompensated,
            firDesignRule: .eeglabMNE
        )
        let filteredSignal = SyntheticSignal.make(filtered, samplingRate: signal.samplingRate)

        // 2. Interpolate the flagged bad channels from the filtered signal.
        let badIndices = Set(eegNames.enumerated().filter { Self.badChannelNames.contains($0.element) }.map(\.offset))
        #expect(badIndices.count == Self.badChannelNames.count)
        var repaired = filtered
        for target in badIndices {
            let solved = ChannelInterpolationSolver.solve(
                target: target, in: filteredSignal, bad: badIndices,
                alreadyInterpolated: [], positions: eegPositions
            )
            if case .success(let solution) = solved {
                repaired[target] = solution.replacement
            }
        }

        // 3. Average reference (all 129 channels now that the bad ones are repaired).
        Rereferencing.applyInPlace(&repaired, excluding: [])
        let referencedSignal = SyntheticSignal.make(repaired, samplingRate: signal.samplingRate)

        // 4. Epoch: congruent vs incongruent flanker trials.
        let preSamples = Int((Self.preStimulus * signal.samplingRate).rounded())
        let epochLength = Int(((Self.preStimulus + Self.postStimulus) * signal.samplingRate).rounded())
        let sampleCount = repaired.first?.count ?? 0

        func segments(for codes: Set<String>, category: String) -> [EpochSegment] {
            signal.events
                .filter { codes.contains($0.code) }
                .sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
                .compactMap { event -> EpochSegment? in
                    let eventSample = Int((event.beginTimeSeconds * signal.samplingRate).rounded())
                    let start = eventSample - preSamples
                    let end = start + epochLength - 1
                    guard start >= 0, end < sampleCount else { return nil }
                    return EpochSegment(
                        startSample: start,
                        endSample: end,
                        stimulusOffsetSamples: preSamples,
                        category: category,
                        sourceCode: event.code,
                        sourceTimeSeconds: event.beginTimeSeconds,
                        colorIndex: category == "congruent" ? 0 : 1,
                        contributingEpochCount: 1
                    )
                }
        }

        let congruentSegments = segments(for: Self.congruentCodes, category: "congruent")
        let incongruentSegments = segments(for: Self.incongruentCodes, category: "incongruent")
        let allSegments = congruentSegments + incongruentSegments
        #expect(!congruentSegments.isEmpty && !incongruentSegments.isEmpty)

        let built = PSABuildResult(signal: referencedSignal, segments: allSegments, message: "")
        let averaged = try #require(built.average(colorIndices: ["congruent": 0, "incongruent": 1]))
        let final = averaged.postProcessed(averageReference: false, baselineCorrect: true, badChannels: [])

        // Locate each category's block in the concatenated averaged output.
        struct ExportedCondition: Encodable {
            let category: String
            let trialCount: Int
            let startSample: Int
            let endSample: Int
        }
        let conditions = ["congruent": congruentSegments.count, "incongruent": incongruentSegments.count]
            .compactMap { name, count -> ExportedCondition? in
                guard let seg = final.segments.first(where: { $0.category == name }) else { return nil }
                return ExportedCondition(category: name, trialCount: count, startSample: seg.startSample, endSample: seg.endSample)
            }

        struct Export: Encodable {
            let channelNames: [String]
            let samplingRate: Double
            let preSamples: Int
            let epochLength: Int
            let badChannels: [String]
            let conditions: [ExportedCondition]
            let data: [[Double]]
        }
        let export = Export(
            channelNames: eegNames,
            samplingRate: signal.samplingRate,
            preSamples: preSamples,
            epochLength: epochLength,
            badChannels: Array(Self.badChannelNames).sorted(),
            conditions: conditions,
            data: final.signal.data.map { $0.map(Double.init) }
        )

        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(export)
        try FileManager.default.createDirectory(
            at: Self.outputPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try jsonData.write(to: Self.outputPath)
        print("wrote \(Self.outputPath.path): \(conditions.map { "\($0.category)=\($0.trialCount)" }.joined(separator: ", "))")
    }
}
