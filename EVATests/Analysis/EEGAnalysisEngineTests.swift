//
//  EEGAnalysisEngineTests.swift
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

import Foundation
import Testing
@testable import EVA

struct EEGAnalysisEngineTests {
    @Test func analyzeProducesSpectralAndConnectivityResults() async {
        let samplingRate = 128.0
        let sampleCount = 512
        let data = (0..<4).map { channel in
            (0..<sampleCount).map { sample -> Float in
                let t = Double(sample) / samplingRate
                let phase = Double(channel) * 0.2
                return Float(20 * sin(2 * .pi * 10 * t + phase) + 4 * sin(2 * .pi * 3 * t))
            }
        }
        let signal = MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/eeg-analysis-test.mff/signal1.bin"),
            signalType: "EEG",
            numberOfChannels: data.count,
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            recordingStartTime: nil,
            events: [],
            data: data,
            channelNames: (0..<data.count).map { "E\($0 + 1)" }
        )
        let channelSets = await MainActor.run {
            [
                ChannelSet(name: "Anterior", channelIndices: [0, 1]),
                ChannelSet(name: "Posterior", channelIndices: [2, 3])
            ]
        }
        let request = EEGAnalysisRequest(
            packageName: "synthetic.mff",
            signal: signal,
            processing: EEGAnalysisProcessingSnapshot(
                signalDescription: "Synthetic",
                gradientCorrected: false,
                icaCleaned: false,
                filtered: false,
                filterLowCutoffHz: nil,
                filterHighCutoffHz: nil,
                notch60HzEnabled: nil,
                averageReferenced: nil,
                artifactCleaned: false,
                artifactCleaningVisible: false,
                waveletReduced: false,
                waveletReductionVisible: false,
                interpolatedChannelIndices: [],
                markedBadChannelIndices: []
            ),
            segmentLengthSeconds: 2,
            keptGrades: [.good, .watch, .poor],
            artifactRejectionThreshold: 1,
            artifactSources: [],
            selectedArtifactSourceIDs: [],
            excludedChannelIndices: [],
            frequencyBands: EEGFrequencyBand.restingDefaults,
            connectivityBand: EEGFrequencyBand(name: "Alpha", lowHz: 8, highHz: 13),
            connectivityMetrics: [.coherence, .phaseLockingValue],
            channelSets: channelSets,
            includesChannelConnectivity: true,
            includesRegionConnectivity: true
        )

        let result = await EEGAnalysisEngine.analyze(request: request)

        #expect(result.segments.includedSegmentCount > 0)
        #expect(result.spectral?.channels.count == data.count)
        #expect(result.connectivity?.channelPairs.isEmpty == false)
        #expect(result.connectivity?.regionPairs.isEmpty == false)
    }
}
