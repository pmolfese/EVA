//
//  FilterEdgeExport.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  One-off export harness, not a regression test (see FullPipelineERPExport
//  for the pattern): filters a real recording's FULL continuous signal —
//  not an epoch window — with both of EVA's band-pass architectures (default
//  IIR Butterworth, and the MNE-reproducing FIR config), then exports only
//  the first and last few seconds of a few channels, to check whether the
//  edges of a continuous zero-phase filter look different between EVA and
//  MNE, or between EVA's own IIR and FIR paths.
//

import Foundation
import Testing
@testable import EVA

@Suite("Filter edge behavior export (real recording, not a regression gate)")
struct FilterEdgeExport {

    static let mffPath = "/Users/molfesepj/Desktop/MFF_tests/24624/24624_flanker_run1_20240322_053029.mff"
    static let outputPath = {
        FileManager.default.temporaryDirectory.appendingPathComponent("eva_filter_edges.json")
    }()
    static let channelsToExport: Set<String> = ["E25", "E59", "E11"]
    static let edgeSeconds = 5

    @Test("export continuous-filter edges under EVA's default IIR and MNE-matching FIR")
    func exportFilterEdges() async throws {
        guard FileManager.default.fileExists(atPath: Self.mffPath) else {
            print("real recording not present at \(Self.mffPath) — skipping export")
            return
        }

        let signal = try MFFReader().loadSignal(from: URL(fileURLWithPath: Self.mffPath))
        let channelNames = try #require(signal.channelNames)
        var indices: [Int] = []
        var names: [String] = []
        for (index, name) in channelNames.enumerated() where Self.channelsToExport.contains(name) {
            indices.append(index)
            names.append(name)
        }
        #expect(names.count == Self.channelsToExport.count)
        let picked = indices.map { signal.data[$0] }

        // A) EVA's default continuous band-pass: no overrides — Butterworth
        // IIR, 24 dB/oct both edges. This is what an ordinary "filter 1-40 Hz"
        // in the app actually runs, unlike the MNE-reproducing FIR config
        // MNERealFileReferenceTests uses.
        let iirFiltered = try await EEGSignalFilter.bandPass(
            channels: picked, samplingRate: signal.samplingRate,
            lowCutoff: 1.0, highCutoff: 40.0
        )

        // B) The MNE-reproducing FIR config, for comparison.
        let firFiltered = try await EEGSignalFilter.bandPass(
            channels: picked, samplingRate: signal.samplingRate,
            lowCutoff: 1.0, highCutoff: 40.0,
            highPassFamily: .fir, lowPassFamily: .fir,
            firWindow: .hamming, firApplication: .delayCompensated, firDesignRule: .eeglabMNE
        )

        let edgeSamples = Int(Double(Self.edgeSeconds) * signal.samplingRate)
        func edges(_ channels: [[Float]]) -> [[String: [Double]]] {
            channels.map { channel in
                [
                    "start": channel.prefix(edgeSamples).map(Double.init),
                    "end": channel.suffix(edgeSamples).map(Double.init),
                ]
            }
        }

        struct Export: Encodable {
            let channelNames: [String]
            let samplingRate: Double
            let edgeSeconds: Int
            let totalSamples: Int
            let iir: [[String: [Double]]]
            let fir: [[String: [Double]]]
        }
        let export = Export(
            channelNames: names,
            samplingRate: signal.samplingRate,
            edgeSeconds: Self.edgeSeconds,
            totalSamples: picked.first?.count ?? 0,
            iir: edges(iirFiltered),
            fir: edges(firFiltered)
        )

        let jsonData = try JSONEncoder().encode(export)
        try jsonData.write(to: Self.outputPath)
        print("wrote \(Self.outputPath.path)")
    }
}
