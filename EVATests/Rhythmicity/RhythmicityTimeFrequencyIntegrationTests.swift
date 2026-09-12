//
//  RhythmicityTimeFrequencyIntegrationTests.swift
//  EVATests
//

import Foundation
import Testing
@testable import EVA

@MainActor
struct RhythmicityTimeFrequencyIntegrationTests {
    @Test func explicitPublicationUsesDisplayedChannelAndDoesNotRewritePreferences() throws {
        let fixture = makeFixture()
        let vm = RhythmicityExplorerViewModel(store: RecordingStore())
        vm.laviResult = fixture.result
        vm.resultSelection = fixture.selection
        vm.selectedChannelIndex = fixture.channel.channelIndex
        vm.resultIsStale = false

        let savedPreferences = ProcessingDefaults.shared.timeFrequencyBands
        #expect(vm.publishSelectedChannelBandsToTimeFrequency())
        let published = try #require(vm.detectedBandSetForTimeFrequency)

        #expect(published.sourceChannelIndex == 6)
        #expect(published.sourceChannelName == "E7")
        #expect(published.frequencyBands == [EEGFrequencyBand(name: "Alpha", lowHz: 8, highHz: 12)])
        #expect(published.bands.first?.peakFrequencyHz == 10)
        #expect(published.bands.first?.direction == .sustained)
        #expect(ProcessingDefaults.shared.timeFrequencyBands == savedPreferences)
    }

    @Test func stalePublicationIsRejectedAndNeverFallsBackSilently() throws {
        let fixture = makeFixture()
        let existing = try #require(DetectedRhythmicityBandSet.make(
            result: fixture.result, selection: fixture.selection, channel: fixture.channel
        ))
        let vm = RhythmicityExplorerViewModel(store: RecordingStore())
        vm.laviResult = fixture.result
        vm.resultSelection = fixture.selection
        vm.selectedChannelIndex = fixture.channel.channelIndex
        vm.resultIsStale = true
        vm.detectedBandSetForTimeFrequency = existing

        #expect(!vm.publishSelectedChannelBandsToTimeFrequency())
        #expect(vm.detectedBandSetForTimeFrequency?.id == existing.id)

        let resolution = TimeFrequencyBandResolution.resolve(
            source: .rhythmicityExplorer,
            userPreferences: EEGFrequencyBand.restingDefaults,
            detectedBandSet: existing,
            detectedBandSetIsStale: true
        )
        #expect(resolution.bands.isEmpty)
        #expect(resolution.detectedBandSet == nil)
        #expect(resolution.warning?.contains("stale") == true)
    }

    @Test func explorerBandsDriveScalarROIsAndExportCompleteProvenance() throws {
        let fixture = makeFixture()
        let set = try #require(DetectedRhythmicityBandSet.make(
            result: fixture.result,
            selection: fixture.selection,
            channel: fixture.channel,
            createdAt: Date(timeIntervalSince1970: 0)
        ))
        let maps = TimeFrequencyExport.ConditionMaps(
            condition: "faces",
            channelIndices: [0],
            channelNames: ["Cz"],
            ersp: [[[1, 3], [2, 4], [100, 100]]],
            itpc: [[[0.2, 0.4], [0.4, 0.6], [1, 1]]],
            frequenciesHz: [8, 10, 20],
            timesMs: [100, 200]
        )
        let context = TimeFrequencyExport.Context(
            plan: .explicit(frequenciesHz: [8, 10, 20], nCycles: 5),
            method: .morlet,
            timeBandwidth: 4,
            baselineMethod: .decibel,
            bands: set.frequencyBands,
            windows: [.init(label: "100-200ms", startMs: 100, endMs: 200)],
            bandSource: .rhythmicityExplorer,
            detectedBandSet: set
        )

        let rows = TimeFrequencyExport.scalarCSVRows([maps], context: context)
        #expect(rows.contains { $0[0] == "summary" && $0[7] == "band_source" && $0[8] == "Rhythmicity Explorer" })
        #expect(rows.contains { $0[0] == "summary" && $0[7] == "band_source_channel" && $0[8] == "E7 [7]" })
        #expect(rows.contains { $0[0] == "summary" && $0[7] == "band_source_created_at" && $0[8] == "1970-01-01T00:00:00Z" })
        #expect(rows.contains { $0[0] == "summary" && $0[7] == "band_1_peak_hz" && $0[8] == "10" })
        let scalarBands = Set(rows.filter { $0[0] == "tf_scalar" }.map { $0[5] })
        #expect(scalarBands == ["Alpha"])
        let power = rows.first { $0[0] == "tf_scalar" && $0[7] == "ersp" }
        #expect(power?[8] == "2.5")

        let sidecar = TimeFrequencyExport.sidecarJSON(maps, measure: .power, context: context)
        let json = try #require(JSONSerialization.jsonObject(with: sidecar) as? [String: Any])
        let provenance = try #require(json["bandSource"] as? [String: Any])
        #expect(provenance["source"] as? String == "Rhythmicity Explorer")
        #expect(provenance["recordingDisplayName"] as? String == "Fixture.mff")
        #expect(provenance["sourceRevision"] as? String == "revision-1")
        #expect(provenance["sourceChannelName"] as? String == "E7")
        #expect(provenance["methodVersion"] as? String == RhythmicityExport.methodVersion)
    }

    private func makeFixture() -> (
        result: LAVIAnalysisResult,
        selection: RhythmicitySelectionDescriptor,
        channel: LAVIChannelResult
    ) {
        let band = ABBABand(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            beginIndex: 0,
            endIndex: 2,
            peakIndex: 1,
            beginFrequencyHz: 8,
            endFrequencyHz: 12,
            peakFrequencyHz: 10,
            peakLAVI: 0.8,
            deviationFromMedian: 0.2,
            direction: .sustained,
            relativeToAlpha: 0,
            canonicalName: "Alpha",
            isSignificant: true,
            significanceMargin: 0.1
        )
        let channel = LAVIChannelResult(
            channelIndex: 6,
            channelName: "E7",
            frequenciesHz: [8, 10, 12],
            values: [0.6, 0.8, 0.7],
            validPairCounts: [100, 100, 100],
            effectiveDurationsSeconds: [30, 30, 30],
            median: 0.7,
            bands: [band],
            warnings: []
        )
        let configuration = RhythmicityPreset.paperLAVI2026Exploratory
        let result = LAVIAnalysisResult(
            configuration: configuration,
            source: .init(recordingIdentity: "/fixture/Fixture.mff#revision-1", displayName: "Fixture.mff"),
            processingProvenance: .init(sourceRevision: "revision-1", processingSummary: ["Average reference"]),
            samplingRateHz: 1_000,
            channels: [channel],
            warnings: []
        )
        let selection = RhythmicitySelectionDescriptor(
            source: .processed,
            dataSelection: .entireProcessedRecording,
            segments: [.init(startSample: 0, endSample: 29_999, label: "Entire recording")],
            channelScope: .current,
            channelSetName: nil,
            includedChannelIndices: [6],
            excludedBadChannelIndices: [],
            interpolatedChannelIndices: [],
            includedMarkedArtifacts: false
        )
        return (result, selection, channel)
    }
}
