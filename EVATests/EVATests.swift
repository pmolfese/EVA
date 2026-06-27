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

    private func makeMFFPackage() throws -> URL {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EVA-test-\(UUID().uuidString)")
            .appendingPathExtension("mff")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        try """
<?xml version="1.0" encoding="UTF-8"?>
<fileInfo>
  <recordTime>2026-06-25T12:00:00.000000-04:00</recordTime>
  <mffVersion>3</mffVersion>
</fileInfo>
""".write(to: packageURL.appendingPathComponent("info.xml"), atomically: true, encoding: .utf8)

        try """
<?xml version="1.0" encoding="UTF-8"?>
<dataInfo>
  <generalInformation>
    <fileDataType>
      <EEG/>
    </fileDataType>
  </generalInformation>
  <calibrations>
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
