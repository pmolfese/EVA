//
//  SourceFitImporterTests.swift
//  EVA Resolve
//
//  Round-trips the EVA → Resolve handoff: an averaged MFF written the way EVA's
//  "Fit Source Model" writes it (MFFWriter + layout files + sidecar) must come
//  back as a FitDataset with one condition per category, average-referenced,
//  and pre-highlighted around the sidecar sample.
//

import Foundation
import Testing
@testable import EVAResolve

@Suite("Source fit importer")
struct SourceFitImporterTests {

    private func writeAveragedPackage(centerSample: Int?) throws -> URL {
        let montage = Montage.standard(count: 32)
        let rate = 250.0
        let perCondition = 100
        let categories = ["Target", "Standard"]
        var data = [[Float]](repeating: [], count: montage.electrodes.count)
        var segments: [EpochSegment] = []
        for (c, name) in categories.enumerated() {
            for channel in 0..<montage.electrodes.count {
                data[channel] += (0..<perCondition).map { s in
                    Float(channel + 1) * sin(Double(s) / 7.0 + Double(c)).asFloat
                }
            }
            segments.append(EpochSegment(
                startSample: c * perCondition, endSample: (c + 1) * perCondition - 1,
                stimulusOffsetSamples: 25, category: name, sourceCode: name,
                sourceTimeSeconds: Double(c), colorIndex: c, contributingEpochCount: 10))
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceFitImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("averaged.mff")
        let signal = MFFSignalData(
            signalURL: url.appendingPathComponent("signal1.bin"),
            signalType: "EEG", numberOfChannels: montage.electrodes.count,
            samplingRate: rate, duration: Double(perCondition * categories.count) / rate,
            recordingStartTime: Date(), events: [], data: data,
            channelNames: montage.channelNames)
        try MFFWriter.write(signal: signal, segments: segments, kind: .averaged, to: url, preserveSourceFileInfo: false)
        try MontageWriter.writeLayoutFiles(montage: montage, to: url)
        let sidecar = try JSONEncoder().encode(SourceFitImporter.Sidecar(centerSample: centerSample))
        try sidecar.write(to: url.appendingPathComponent(SourceFitImporter.sidecarName))
        return url
    }

    @Test("averaged package round-trips into a FitDataset with a pre-highlight")
    func roundTrip() throws {
        let url = try writeAveragedPackage(centerSample: 40)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (dataset, selection) = try SourceFitImporter.load(url)
        #expect(dataset.conditions.map(\.name) == ["Target", "Standard"])
        #expect(dataset.channelCount == 32)
        #expect(dataset.sampleCount == 100)
        #expect(dataset.sampleRate == 250)
        #expect(dataset.truth == nil)
        // ±30 ms at 250 Hz is ±8 samples around 40.
        #expect(selection == 32...48)
        // Average-referenced: each sample's channel mean is ~0.
        let column = dataset.conditions[0].data.map { $0[10] }
        let mean = column.reduce(0, +) / Double(column.count)
        let peak = column.map(abs).max() ?? 1
        #expect(abs(mean) < peak * 1e-5)
    }

    @Test("no sidecar means no pre-highlight")
    func noSidecar() throws {
        let url = try writeAveragedPackage(centerSample: nil)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (_, selection) = try SourceFitImporter.load(url)
        #expect(selection == nil)
    }
}

private extension Double {
    var asFloat: Float { Float(self) }
}
