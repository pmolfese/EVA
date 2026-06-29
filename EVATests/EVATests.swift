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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
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
            let bank = WaveletFilterBank.orthonormal(family.scalingFilter)
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
            let bank = WaveletFilterBank.orthonormal(family.scalingFilter)
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

    @Test func mffReaderAppliesGCALCalibration() throws {
        let packageURL = try makeMFFPackage()
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let signal = try MFFReader().loadSignal(from: packageURL)

        #expect(signal.data[0] == [2, 4, 6])
        #expect(signal.data[1] == [5, 10, 15])
    }

    @Test func mffExportStripsSourceCalibrationsAfterCalibratedRead() throws {
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
        #expect(!exportedInfo.contains("ICAL"))
        #expect(!exportedInfo.contains("calibrations"))

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
