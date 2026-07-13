//
//  BCGDetectionPreviewEstimator.swift
//  EVA
//
//  Runs every event-producing BCG detector without mutating the active
//  recording, for the comparison table in the BCG Detection sheet.
//

import Foundation

nonisolated struct BCGDetectionPreviewConfiguration: Sendable {
    let thresholdSD: Double
    let minHR: Double
    let maxHR: Double
    let powerMinHz: Double
    let powerMaxHz: Double
    let qrsLagSeconds: Double
    let pcaComponents: Int
    let spatialWhiten: Bool
    let slidingNormalize: Bool
    let respAdaptive: Bool
}

nonisolated enum BCGDetectionPreviewEstimator {
    /// `nil` means the method is not runnable as a beat detector (CWL, or QRS
    /// locking without detected QRS events). An empty array means it ran but
    /// found no beats.
    static func eventTimes(
        method: BCGDetectionMethod,
        channels: [[Float]],
        samplingRate: Double,
        duration: TimeInterval,
        exemplarRange: ClosedRange<Int>?,
        qrsTimes: [Double],
        configuration: BCGDetectionPreviewConfiguration
    ) async -> [Double]? {
        switch method {
        case .periodicity:
            return await BCGDetector.periodicityEvents(
                channels: channels,
                samplingRate: samplingRate,
                minHR: configuration.minHR,
                maxHR: configuration.maxHR,
                thresholdSD: configuration.thresholdSD
            )

        case .spatialPCA:
            return await BCGDetector.spatialPCAEvents(
                channels: channels,
                samplingRate: samplingRate,
                exemplarRange: exemplarRange,
                numComponents: configuration.pcaComponents,
                spatialWhiten: configuration.spatialWhiten,
                slidingNormalize: configuration.slidingNormalize,
                respAdaptive: configuration.respAdaptive,
                thresholdSD: configuration.thresholdSD
            )

        case .cardiacPowerMap:
            return await BCGDetector.cardiacPowerEvents(
                channels: channels,
                samplingRate: samplingRate,
                minHz: configuration.powerMinHz,
                maxHz: configuration.powerMaxHz,
                thresholdSD: configuration.thresholdSD
            )

        case .virtualECGPCA:
            guard let component = await BCGDetector.virtualECGComponent(
                channels: channels,
                samplingRate: samplingRate,
                minHR: configuration.minHR,
                maxHR: configuration.maxHR
            ) else { return [] }
            let source = ECGDetectionSource(
                id: "bcg-preview-virtual-ecg",
                label: "Virtual ECG",
                channelLabels: ["PC1"],
                channels: [component],
                samplingRate: samplingRate,
                duration: duration
            )
            return RWaveDetector.detect(
                sources: [source],
                configuration: qrsConfiguration(configuration)
            ).map(\.beginTimeSeconds)

        case .panTompkinsProxy:
            let source = ECGDetectionSource(
                id: "bcg-preview-pan-tompkins",
                label: "BCG Proxy",
                channelLabels: channels.indices.map { "Ch \($0 + 1)" },
                channels: channels,
                samplingRate: samplingRate,
                duration: duration
            )
            return RWaveDetector.detect(
                sources: [source],
                configuration: qrsConfiguration(configuration)
            ).map(\.beginTimeSeconds)

        case .qrsLocking:
            guard !qrsTimes.isEmpty else { return nil }
            return BCGDetector.qrsLockingEvents(
                qrsTimes: qrsTimes,
                lagSeconds: configuration.qrsLagSeconds,
                recordingDuration: duration
            )

        case .cwlRegression:
            return nil
        }
    }

    static func result(from times: [Double]) -> BCGAlgorithmResult {
        BCGAlgorithmResult(count: times.count, bpm: estimatedBPM(from: times))
    }

    static func estimatedBPM(from times: [Double]) -> Double? {
        guard times.count >= 2 else { return nil }
        let sorted = times.sorted()
        let intervals = zip(sorted.dropFirst(), sorted).map { $0 - $1 }.filter { $0 > 0 }
        guard !intervals.isEmpty else { return nil }
        let ordered = intervals.sorted()
        let middle = ordered.count / 2
        let median = ordered.count.isMultiple(of: 2)
            ? (ordered[middle - 1] + ordered[middle]) / 2
            : ordered[middle]
        return median > 0 ? 60 / median : nil
    }

    private static func qrsConfiguration(
        _ configuration: BCGDetectionPreviewConfiguration
    ) -> ECGDetectionConfiguration {
        ECGDetectionConfiguration(
            algorithm: .panTompkins,
            thresholdSD: configuration.thresholdSD,
            minimumRRSeconds: 60 / max(configuration.maxHR, 1) * 0.6,
            polarity: .either
        )
    }
}
