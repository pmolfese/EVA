//
//  EVATests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Testing
import Foundation
@testable import EVA

struct EVATests {

    // MARK: - Wavelet reducer: perfect reconstruction

    private func makeTestSignal(count: Int) -> [Double] {
        (0..<count).map { i in
            let t = Double(i)
            return sin(t * 0.07) + 0.4 * sin(t * 0.31) + 0.15 * cos(t * 0.9)
                + (i % 97 == 0 ? 8.0 : 0.0) // occasional spikes
        }
    }

    private func maxAbsDifference(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    @Test func dwtPerfectReconstruction() {
        let signal = makeTestSignal(count: 600)
        for family in WaveletReductionFamily.allCases {
            let bank = family.filterBank
            let transform = WaveletTransform(bank: bank)
            for levels in [1, 3, 5] {
                let decomposition = transform.forwardDWT(signal, levels: levels)
                let reconstructed = transform.inverseDWT(decomposition)
                let error = maxAbsDifference(signal, reconstructed)
                #expect(error < 1e-6, "DWT \(family.rawValue) L\(levels) error \(error)")
            }
        }
    }

    @Test func swtPerfectReconstruction() {
        let signal = makeTestSignal(count: 512)
        for family in WaveletReductionFamily.allCases {
            let bank = family.filterBank
            let transform = WaveletTransform(bank: bank)
            for levels in [1, 3, 4] {
                let decomposition = transform.forwardSWT(signal, levels: levels)
                let reconstructed = transform.inverseSWT(decomposition)
                let error = maxAbsDifference(signal, reconstructed)
                #expect(error < 1e-6, "SWT \(family.rawValue) L\(levels) error \(error)")
            }
        }
    }

    @Test func reductionRemovesSpikesAndPreservesBackground() {
        // A clean oscillation plus large isolated spikes; reduction should cut
        // the peak substantially while keeping most of the variance/structure.
        var signal = (0..<500).map { sin(Double($0) * 0.2) }
        for index in stride(from: 50, to: 500, by: 120) { signal[index] += 12 }

        let config = WaveletReductionConfiguration(
            kind: .dwt, family: .coif4, levelCount: 5,
            thresholdRule: .hard, thresholdModel: .bayesShrink, thresholdScale: 1
        )
        let (cleaned, artifact, _) = WaveletReducer.reduceChannel(signal, configuration: config)

        let originalPeak = signal.map(abs).max() ?? 0
        let cleanedPeak = cleaned.map(abs).max() ?? 0
        let artifactEnergy = artifact.reduce(0) { $0 + $1 * $1 }

        #expect(cleanedPeak < originalPeak)          // spikes reduced
        #expect(artifactEnergy > 0)                  // something was removed
        #expect(cleaned.count == signal.count)
    }

    @Test func reductionWithUniversalThresholdRetainsMostVariance() {
        // Expected wavelet-reduction behavior: on oscillation + sparse large
        // spikes, the universal-threshold defaults should remove the spikes
        // while keeping the bulk of the ongoing signal (variance retained well
        // above half).
        var signal = (0..<4000).map { sin(Double($0) * 0.2) + 0.3 * sin(Double($0) * 0.05) }
        for index in stride(from: 100, to: 4000, by: 500) { signal[index] += 25 }

        let config = WaveletReductionMode.continuousEEG.defaultConfiguration(samplingRate: 250)
        let (cleaned, _, _) = WaveletReducer.reduceChannel(signal, configuration: config, samplingRate: 250)

        func variance(_ v: [Double]) -> Double {
            let mean = v.reduce(0, +) / Double(v.count)
            return v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count)
        }
        // Compare against the spike-free background, which is what should survive.
        let background = (0..<4000).map { sin(Double($0) * 0.2) + 0.3 * sin(Double($0) * 0.05) }
        let retained = variance(cleaned) / variance(background)
        #expect(retained > 0.5 && retained < 1.5, "variance vs background \(retained)")

        let cleanedPeak = cleaned.map(abs).max() ?? 0
        #expect(cleanedPeak < 10, "spikes should be substantially reduced, peak \(cleanedPeak)")
    }

    @Test func detrendKeepsBaselineOffsetOutOfTheSeam() {
        // A large DC + drift offset between start and end used to wrap through
        // the circular transform boundary as a spurious edge artifact. With
        // detrending + reflection padding, the removed artifact near the edges
        // should stay comparable to the interior.
        let count = 2000
        let signal = (0..<count).map { 200.0 * Double($0) / Double(count) + sin(Double($0) * 0.3) }

        var config = WaveletReductionMode.continuousEEG.defaultConfiguration(samplingRate: 250)
        config.levelCount = 6
        let (cleaned, _, _) = WaveletReducer.reduceChannel(signal, configuration: config, samplingRate: 250)

        // The drift (trend) belongs to the artifact; what survives should be
        // the oscillation, without a blow-up at either edge.
        let interiorPeak = cleaned[200..<(count - 200)].map(abs).max() ?? 0
        let edgePeak = max(cleaned[..<200].map(abs).max() ?? 0, cleaned[(count - 200)...].map(abs).max() ?? 0)
        #expect(edgePeak < interiorPeak * 3 + 1e-9, "edge \(edgePeak) vs interior \(interiorPeak)")
    }

    @Test func windowedThresholdsMatchGlobalOnStationarySignals() {
        // On a stationary signal the local (windowed) thresholds should agree
        // closely with the global statistic, so both configurations remove
        // nearly the same artifact.
        var signal = (0..<6000).map { sin(Double($0) * 0.25) }
        for index in stride(from: 300, to: 6000, by: 700) { signal[index] += 15 }

        var globalConfig = WaveletReductionMode.continuousEEG.defaultConfiguration(samplingRate: 100)
        globalConfig.levelCount = 5
        var localConfig = globalConfig
        localConfig.thresholdWindowSeconds = 30

        let (globalCleaned, _, _) = WaveletReducer.reduceChannel(signal, configuration: globalConfig, samplingRate: 100)
        let (localCleaned, _, _) = WaveletReducer.reduceChannel(signal, configuration: localConfig, samplingRate: 100)

        let difference = zip(globalCleaned, localCleaned).map { abs($0 - $1) }.max() ?? 0
        let peak = globalCleaned.map(abs).max() ?? 1
        #expect(difference < peak, "global vs local divergence \(difference) (peak \(peak))")

        let globalPeak = globalCleaned.map(abs).max() ?? 0
        let localPeak = localCleaned.map(abs).max() ?? 0
        #expect(globalPeak < 10 && localPeak < 10, "both should remove the spikes")
    }

    // MARK: - Candidates, analysis range, stopband levels

    /// Builds an artifact-shaped signal: `channelCount` channels that all carry
    /// the same events at the same times (as a real blink or motion artifact
    /// does), plus one much larger event at the very end standing in for a
    /// filter transient.
    private func artifactSignal(
        samplingRate: Double = 250,
        count: Int = 10_000,
        channelCount: Int = 16,
        eventSamples: [Int] = [2_000, 4_000, 6_000],
        tailTransient: Bool = true
    ) -> MFFSignalData {
        let channels = (0..<channelCount).map { channel -> [Float] in
            var trace = [Float](repeating: 0, count: count)
            for (order, event) in eventSamples.enumerated() {
                // Amplitude varies by channel so one channel is unambiguously
                // strongest, and by event so the ranking is deterministic.
                let amplitude = Float(100 - order * 10) + Float(channel)
                for k in 0..<80 where event + k < count {
                    trace[event + k] = amplitude * Float(sin(Double(k) / 80.0 * .pi))
                }
            }
            if tailTransient {
                for k in 0..<200 where count - 200 + k < count {
                    trace[count - 200 + k] = 5_000 * Float(k) / 200
                }
            }
            return trace
        }
        return SyntheticSignal.make(channels, samplingRate: samplingRate)
    }

    @Test func candidatesReportDistinctEventsNotOnePerChannel() {
        let artifact = artifactSignal(tailTransient: false)
        let candidates = WaveletReducer.findCandidates(
            artifact: artifact,
            channelIndices: Array(artifact.data.indices),
            maxCount: 40
        )

        // Three events exist, on 16 channels each. The old one-peak-per-channel
        // behaviour returned 16 rows all describing the single largest event;
        // the list should now be the three distinct events instead.
        #expect(candidates.count == 3, "expected 3 distinct events, got \(candidates.count)")

        let peakTimes = candidates.map { $0.peakTimeSeconds }.sorted()
        for (index, expected) in [8.0, 16.0, 24.0].enumerated() {
            #expect(abs(peakTimes[index] - expected) < 0.5, "event \(index) at \(peakTimes[index])s, expected ~\(expected)s")
        }
    }

    @Test func candidateEdgeMarginSuppressesTailTransient() {
        let artifact = artifactSignal()   // includes the 5000 µV tail transient
        let indices = Array(artifact.data.indices)
        let sampleCount = artifact.data[0].count

        let unguarded = WaveletReducer.findCandidates(
            artifact: artifact, channelIndices: indices, maxCount: 40)
        // Without a margin the transient is the top-ranked event, as in the
        // report that motivated this.
        #expect(abs((unguarded.first?.peakTimeSeconds ?? 0) - 39.5) < 1.0)

        let margin = WaveletReducer.candidateEdgeMargin(
            family: .coif4, levelCount: 9, sampleCount: sampleCount)
        #expect(margin > 0)
        let guarded = WaveletReducer.findCandidates(
            artifact: artifact, channelIndices: indices, maxCount: 40,
            edgeMarginSamples: margin)

        let tailSeconds = Double(sampleCount - margin) / artifact.samplingRate
        #expect(!guarded.contains { $0.peakTimeSeconds >= tailSeconds },
                "a candidate was still reported inside the suppressed margin")
        #expect(guarded.count == 3, "the three real events should remain, got \(guarded.count)")
    }

    /// At 1000 Hz with a 30 Hz low-pass, levels 1–4 span 31–500 Hz and hold
    /// nothing; level 5 (15.6–31.25 Hz) straddles the cutoff and must survive.
    @Test func stopbandLevelCountMatchesTheFilterBand() {
        #expect(WaveletReductionConfiguration.stopbandLevelCount(samplingRate: 1000, highCutoff: 30) == 4)
        #expect(WaveletReductionConfiguration.stopbandLevelCount(samplingRate: 250, highCutoff: 100) == 0)
        #expect(WaveletReductionConfiguration.stopbandLevelCount(samplingRate: 500, highCutoff: 30) == 3)
        // Degenerate inputs must not produce a negative or nonsensical count.
        #expect(WaveletReductionConfiguration.stopbandLevelCount(samplingRate: 0, highCutoff: 30) == 0)
        #expect(WaveletReductionConfiguration.stopbandLevelCount(samplingRate: 1000, highCutoff: 600) == 0)
    }

    @Test func skippingFineLevelsLeavesHighFrequencyContentAlone() {
        // Slow content plus sparse spikes. The spikes are broadband, so they
        // put removable energy into the finest levels — which a band-limited
        // recording's stopband levels would not legitimately contain. A pure
        // sinusoid would not work here: it sets its own band's noise floor, so
        // the universal threshold leaves it alone with or without skipping.
        let count = 8_000
        var signal = (0..<count).map { sin(Double($0) * 0.05) * 20 }
        for spike in stride(from: 500, to: count, by: 900) { signal[spike] += 120 }
        var config = WaveletReductionMode.continuousEEG.defaultConfiguration(samplingRate: 250)
        config.levelCount = 6
        config.useGPU = false

        let (keptAll, _, _) = WaveletReducer.reduceChannel(signal, configuration: config, samplingRate: 250)
        config.skippedFineLevels = 2
        let (keptSkipped, artifactSkipped, energies) = WaveletReducer.reduceChannel(
            signal, configuration: config, samplingRate: 250)

        // Skipped levels must report no removed energy at all.
        #expect(energies[0] == 0 && energies[1] == 0, "skipped levels still reported removed energy")
        // And the cleaned trace must retain strictly more of the original.
        func distance(_ v: [Double]) -> Double {
            zip(v, signal).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
        }
        #expect(distance(keptSkipped) < distance(keptAll), "skipping levels should remove less, not more")
        #expect(artifactSkipped.count == signal.count)
    }

    @Test func analysisRangeLeavesExcludedSamplesUntouched() {
        let signal = artifactSignal(samplingRate: 250, count: 10_000, channelCount: 4)
        var config = WaveletReductionMode.continuousEEG.defaultConfiguration(samplingRate: 250)
        config.levelCount = 6
        config.useGPU = false
        // Analyse everything except the final 5 s, where the transient lives.
        config.analysisEndSeconds = 35.0

        let result = WaveletReducer.reduce(
            signal: signal, channelIndices: Array(signal.data.indices), configuration: config)

        let cutoffSample = Int(35.0 * 250)
        for channel in signal.data.indices {
            // Outside the span, cleaned == original and artifact == 0.
            for index in cutoffSample..<signal.data[channel].count {
                #expect(result.cleaned.data[channel][index] == signal.data[channel][index],
                        "ch \(channel) sample \(index) was modified outside the analysis range")
                #expect(result.artifact.data[channel][index] == 0)
            }
            // Inside it, something was actually removed.
            #expect(result.artifact.data[channel][0..<cutoffSample].contains { $0 != 0 },
                    "ch \(channel) had nothing removed inside the analysis range")
        }
    }

    @Test func mffReaderAppliesGCALCalibration() throws {
        let packageURL = try makeMFFPackage()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let signal = try MFFReader().loadSignal(from: packageURL)

        #expect(signal.data[0] == [2, 4, 6])
        #expect(signal.data[1] == [5, 10, 15])
    }

    @Test func mffExportStripsGCALButKeepsICAL() throws {
        // EVA stores calibrated physical samples, so the gain calibration (GCAL)
        // must be stripped to avoid double-scaling on re-import. Electrode
        // impedance (ICAL) is metadata, not a scale factor, and is preserved.
        let packageURL = try makeMFFPackage()
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EVA-export-\(UUID().uuidString)")
            .appendingPathExtension("mff")
        defer {
            try? FileManager.default.removeItem(at: packageURL)
            try? FileManager.default.removeItem(at: exportURL)
        }

        let signal = try MFFReader().loadSignal(from: packageURL)
        try MFFWriter.write(signal: signal, segments: [], kind: .continuous, to: exportURL)

        let exportedInfo = try String(
            contentsOf: exportURL.appendingPathComponent("info1.xml"),
            encoding: .utf8
        )
        #expect(!exportedInfo.contains("GCAL"))
        #expect(exportedInfo.contains("ICAL"))

        let exportedSignal = try MFFReader().loadSignal(from: exportURL)
        #expect(exportedSignal.data == signal.data)
    }

    @Test func mffReaderDetectsAntiAliasTimingCorrectionFromFixtureMetadata() throws {
        let correction = try MFFReader().antiAliasTimingCorrection(in: Fixtures.url("example_2.mff"))
        let status = try #require(correction)

        #expect(status.shiftMicroseconds == 36_000)
        #expect(status.acquisitionVersion == "5.4.1.2 (r28337)")
        #expect(status.evidence.contains(.hardwareFilterAdjusted))
        #expect(status.evidence.contains(.acquisitionVersion))
    }

    @Test func mffReaderFallsBackToAcquisitionVersionForAntiAliasTimingCorrection() throws {
        let packageURL = try makeMFFPackage(acquisitionVersion: "5.2.0")
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let correction = try MFFReader().antiAliasTimingCorrection(in: packageURL)
        let status = try #require(correction)

        #expect(status.shiftMicroseconds == nil)
        #expect(status.evidence == [.acquisitionVersion])
    }

    @Test func signalImportExposesAntiAliasTimingCorrectionMetadata() throws {
        let imported = try SignalImportReader.load(from: Fixtures.url("example_2.mff"))
        let status = try #require(imported.antiAliasTimingCorrection)

        #expect(status.loadingMessage == "Corrected for anti-alias timing bug at recording")
    }

    // MARK: - MFF reader: real fixture recordings (BEL-Public/mffpy)

    @Test func mffReaderSelectsEEGSignalFromMultiSignalPackage() throws {
        // example_3 contains both an EEG signal (signal1.bin) and a PNS signal
        // (signal2.bin). loadSignal must pick the EEG descriptor, not the PNS one.
        let url = Fixtures.url("example_3.mff")

        let binFiles = try MFFReader().binFiles(in: url)
        #expect(binFiles.count == 2) // EEG + PNS present

        let signal = try MFFReader().loadSignal(from: url)
        #expect(signal.signalType.caseInsensitiveCompare("EEG") == .orderedSame)
        #expect(signal.signalURL.lastPathComponent == "signal1.bin")
        #expect(signal.numberOfChannels > 0)
        #expect(signal.samplingRate > 0)
        #expect(signal.data.count == signal.numberOfChannels)
        #expect((signal.data.first?.count ?? 0) > 0)
    }

    @Test func mffReaderLoadsPackageWithEmptyCalibrations() throws {
        // example_4 declares <calibrations /> (empty). Reading must succeed and
        // return data unchanged by any calibration step.
        let url = Fixtures.url("example_4.mff")

        let signal = try MFFReader().loadSignal(from: url)
        #expect(signal.signalType.caseInsensitiveCompare("EEG") == .orderedSame)
        #expect(signal.numberOfChannels > 0)
        #expect(signal.samplingRate > 0)
        #expect(signal.data.count == signal.numberOfChannels)
        #expect(signal.data.allSatisfy { $0.count == (signal.data.first?.count ?? -1) })
    }

    private func makeMFFPackage(
        acquisitionVersion: String? = nil,
        hardwareFilterAdjusted: Bool? = nil,
        shiftMicroseconds: Int? = nil
    ) throws -> URL {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EVA-test-\(UUID().uuidString)")
            .appendingPathExtension("mff")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        let acquisitionVersionXML = acquisitionVersion.map {
            "  <acquisitionVersion>\($0)</acquisitionVersion>\n"
        } ?? ""
        try """
<?xml version="1.0" encoding="UTF-8"?>
<fileInfo>
  <recordTime>2026-06-25T12:00:00.000000-04:00</recordTime>
\(acquisitionVersionXML)  <mffVersion>3</mffVersion>
</fileInfo>
""".write(to: packageURL.appendingPathComponent("info.xml"), atomically: true, encoding: .utf8)

        let hardwareFilterAdjustedXML: String
        if let hardwareFilterAdjusted {
            let shiftAttribute = shiftMicroseconds.map { " shiftMicroseconds=\"\($0)\"" } ?? ""
            hardwareFilterAdjustedXML = """
  <hardwareFilterAdjusted\(shiftAttribute)>\(hardwareFilterAdjusted ? "true" : "false")</hardwareFilterAdjusted>
"""
        } else {
            hardwareFilterAdjustedXML = ""
        }
        try """
<?xml version="1.0" encoding="UTF-8"?>
<dataInfo>
  <generalInformation>
    <fileDataType>
      <EEG/>
    </fileDataType>
  </generalInformation>
\(hardwareFilterAdjustedXML.isEmpty ? "" : "\(hardwareFilterAdjustedXML)\n")  <calibrations>
    <calibration>
      <beginTime>0</beginTime>
      <type>GCAL</type>
      <channels>
        <ch n="1">2.0</ch>
        <ch n="2">0.5</ch>
      </channels>
    </calibration>
    <calibration>
      <beginTime>0</beginTime>
      <type>ICAL</type>
      <channels>
        <ch n="1">10.0</ch>
        <ch n="2">10.0</ch>
      </channels>
    </calibration>
  </calibrations>
</dataInfo>
""".write(to: packageURL.appendingPathComponent("info1.xml"), atomically: true, encoding: .utf8)

        try writeSignalBinary(
            to: packageURL.appendingPathComponent("signal1.bin"),
            samplesByChannel: [
                [1, 2, 3],
                [10, 20, 30]
            ],
            sampleRate: 1_000
        )

        return packageURL
    }

    // MARK: - On-disk segmented / averaged detection

    @Test func mffReaderDetectsAveragedEpochsFromCategories() throws {
        let packageURL = try makeAveragedMFFPackage()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let signal = try MFFReader().loadSignal(from: packageURL)

        #expect(signal.isSegmented)
        #expect(signal.isAveraged)
        #expect(signal.epochSegments.count == 2)

        let a = try #require(signal.epochSegments.first(where: { $0.category == "A" }))
        #expect(a.startSample == 0)
        #expect(a.endSample == 3)
        #expect(a.stimulusOffsetSamples == 1)
        #expect(a.contributingEpochCount == 10)

        let b = try #require(signal.epochSegments.first(where: { $0.category == "B" }))
        #expect(b.startSample == 4)
        #expect(b.endSample == 7)
        #expect(b.stimulusOffsetSamples == 1)
        #expect(b.contributingEpochCount == 7)

        // Events come from the epochs, not the original recording's event tracks.
        #expect(signal.events.count == 2)
        #expect(Set(signal.events.map(\.code)) == ["A", "B"])
        let aEvent = try #require(signal.events.first(where: { $0.code == "A" }))
        #expect(abs(aEvent.beginTimeSeconds - 0.001) < 1e-9)
    }

    @Test func mffReaderSynthesizesEGIChannelNamesWhenLayoutLabelsAreBlank() throws {
        // HydroCel layouts number every electrode but leave <name> blank, except
        // the reference (type 1). Without synthesized E{n} labels the channel
        // identity is unknown and combining two runs of the same net fails.
        let signal = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        let names = try #require(signal.channelNames)
        #expect(names.count == signal.numberOfChannels)
        #expect(names.first == "E1")
        #expect(names.last == "VREF")
        #expect(Set(names).count == names.count)
    }

    @Test func mffReaderTreatsSingleFullSpanCategoryAsContinuous() throws {
        // One category whose single segment spans the whole recording (no
        // averaging) must not be flagged as segmented.
        let signal = try MFFReader().loadSignal(from: Fixtures.url("example_2.mff"))
        #expect(!signal.isSegmented)
        #expect(signal.epochSegments.isEmpty)
    }

    /// Builds a 2-block, 2-category averaged package (each block one epoch).
    private func makeAveragedMFFPackage() throws -> URL {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EVA-avg-\(UUID().uuidString)")
            .appendingPathExtension("mff")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        try """
<?xml version="1.0" encoding="UTF-8"?>
<fileInfo><recordTime>2026-06-25T12:00:00.000000-04:00</recordTime><mffVersion>3</mffVersion></fileInfo>
""".write(to: packageURL.appendingPathComponent("info.xml"), atomically: true, encoding: .utf8)

        try """
<?xml version="1.0" encoding="UTF-8"?>
<dataInfo><generalInformation><fileDataType><EEG/></fileDataType></generalInformation></dataInfo>
""".write(to: packageURL.appendingPathComponent("info1.xml"), atomically: true, encoding: .utf8)

        try """
<?xml version="1.0" encoding="UTF-8"?>
<epochs>
  <epoch><beginTime>0</beginTime><endTime>4000</endTime><firstBlock>1</firstBlock><lastBlock>1</lastBlock></epoch>
  <epoch><beginTime>4000</beginTime><endTime>8000</endTime><firstBlock>2</firstBlock><lastBlock>2</lastBlock></epoch>
</epochs>
""".write(to: packageURL.appendingPathComponent("epochs.xml"), atomically: true, encoding: .utf8)

        try """
<?xml version="1.0" encoding="UTF-8"?>
<categories>
  <cat><name>A</name><segments><seg><beginTime>0</beginTime><endTime>4000</endTime><evtBegin>1000</evtBegin>
    <keys><key><keyCode>#seg</keyCode><data dataType="long">10</data></key></keys></seg></segments></cat>
  <cat><name>B</name><segments><seg><beginTime>4000</beginTime><endTime>8000</endTime><evtBegin>5000</evtBegin>
    <keys><key><keyCode>#seg</keyCode><data dataType="long">7</data></key></keys></seg></segments></cat>
</categories>
""".write(to: packageURL.appendingPathComponent("categories.xml"), atomically: true, encoding: .utf8)

        // Two blocks of four samples each, 1000 Hz, two channels.
        var data = Data()
        appendSignalBlock(to: &data, samplesByChannel: [[1, 2, 3, 4], [5, 6, 7, 8]], sampleRate: 1_000)
        appendSignalBlock(to: &data, samplesByChannel: [[9, 10, 11, 12], [13, 14, 15, 16]], sampleRate: 1_000)
        try data.write(to: packageURL.appendingPathComponent("signal1.bin"), options: .atomic)

        return packageURL
    }

    private func appendSignalBlock(to data: inout Data, samplesByChannel: [[Float]], sampleRate: Int32) {
        let channelCount = Int32(samplesByChannel.count)
        let sampleCount = Int32(samplesByChannel.first?.count ?? 0)
        let headerSize = Int32(16 + Int(channelCount) * 8)
        let blockSize = Int32(Int(channelCount) * Int(sampleCount) * MemoryLayout<Float>.size)
        let rateDepth = (sampleRate << 8) | 32

        appendInt32(1, to: &data)
        appendInt32(headerSize, to: &data)
        appendInt32(blockSize, to: &data)
        appendInt32(channelCount, to: &data)
        for _ in 0..<channelCount { appendInt32(0, to: &data) }
        for _ in 0..<channelCount { appendInt32(rateDepth, to: &data) }
        for channel in samplesByChannel {
            for sample in channel { appendFloat32(sample, to: &data) }
        }
    }

    private func writeSignalBinary(to url: URL, samplesByChannel: [[Float]], sampleRate: Int32) throws {
        let channelCount = Int32(samplesByChannel.count)
        let sampleCount = Int32(samplesByChannel.first?.count ?? 0)
        let headerSize = Int32(16 + Int(channelCount) * 8)
        let blockSize = Int32(Int(channelCount) * Int(sampleCount) * MemoryLayout<Float>.size)
        let rateDepth = (sampleRate << 8) | 32

        var data = Data()
        appendInt32(1, to: &data)
        appendInt32(headerSize, to: &data)
        appendInt32(blockSize, to: &data)
        appendInt32(channelCount, to: &data)
        for _ in 0..<channelCount {
            appendInt32(0, to: &data)
        }
        for _ in 0..<channelCount {
            appendInt32(rateDepth, to: &data)
        }
        for channel in samplesByChannel {
            for sample in channel {
                appendFloat32(sample, to: &data)
            }
        }

        try data.write(to: url, options: .atomic)
    }

    private func appendInt32(_ value: Int32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private func appendFloat32(_ value: Float, to data: inout Data) {
        var littleEndian = value.bitPattern.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
