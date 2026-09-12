//
//  RhythmicBurstExport.swift
//  EVA
//
//  Reproducible neural-rhythmicity burst exports. These files describe analysis
//  annotations only and are never interpreted as artifact-cleaning instructions.
//

import Foundation

nonisolated enum RhythmicBurstExport {
    static let schema = "org.nih.eva.rhythmicity-bursts"
    static let schemaVersion = 1

    struct BundleContents: Sendable {
        var files: [String: Data]
    }

    static func bundle(
        result: RhythmicBurstAnalysisResult,
        exportedAt: Date = Date()
    ) throws -> BundleContents {
        var files: [String: Data] = [
            "bursts.csv": TimeFrequencyExport.csvData(burstRows(result.bursts)),
            "burst-band-summary.csv": TimeFrequencyExport.csvData(summaryRows(result.summaries)),
            "warnings.txt": Data(((result.warnings.isEmpty
                ? "No validity warnings."
                : result.warnings.joined(separator: "\n")) + "\n").utf8),
        ]
        for map in result.maps {
            let stem = "c\(map.channelIndex)-s\(map.segmentIndex)"
            files["burst-power-\(stem).npy"] = TimeFrequencyExport.npy([map.normalizedPower])
            files["burst-wtpl-\(stem).npy"] = TimeFrequencyExport.npy([map.wtpl])
            files["burst-axes-\(stem).json"] = try JSONSerialization.data(
                withJSONObject: [
                    "channelIndex": map.channelIndex,
                    "channelName": map.channelName,
                    "segmentIndex": map.segmentIndex,
                    "segmentID": map.segmentID ?? NSNull(),
                    "segmentLabel": map.segmentLabel ?? NSNull(),
                    "segmentStartSample": map.segmentStartSample,
                    "segmentEndSample": map.segmentEndSample,
                    "sampleStride": map.sampleStride,
                    "frequenciesHz": map.frequenciesHz,
                    "timesSeconds": map.timesSeconds,
                    "powerScale": "power divided by the per-frequency P90 threshold",
                    "wtplScale": "unitless 0...1; NaN at invalid edges",
                ],
                options: [.prettyPrinted, .sortedKeys]
            )
        }
        files["manifest.json"] = try manifest(result: result, exportedAt: exportedAt)
        return BundleContents(files: files)
    }

    static func write(_ contents: BundleContents, to destination: URL) throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".eva-bursts-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? manager.removeItem(at: temporary) } }
        for name in contents.files.keys.sorted() {
            try contents.files[name]?.write(to: temporary.appendingPathComponent(name), options: .atomic)
        }
        guard !manager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        try manager.moveItem(at: temporary, to: destination)
        committed = true
    }

    static func burstRows(_ bursts: [RhythmicBurst]) -> [[String]] {
        var rows = [[
            "burst_id", "channel_index", "channel_name", "segment_index", "segment_id", "segment_label",
            "peak_frequency_hz", "peak_global_sample", "onset_global_sample", "offset_global_sample",
            "initial_onset_global_sample", "initial_offset_global_sample", "duration_ms", "duration_cycles",
            "peak_power", "peak_p90_power", "relative_peak_power_db", "estimated_energy",
            "lower_peak_frequency_hz", "upper_peak_frequency_hz", "peak_wtpl", "mean_wtpl",
            "band_id", "band_name", "band_direction", "band_consistency_percent", "boundary_source",
        ]]
        rows += bursts.map { burst in
            [
                burst.id, String(burst.channelIndex), burst.channelName, String(burst.segmentIndex),
                burst.segmentID ?? "", burst.segmentLabel ?? "", number(burst.peakFrequencyHz),
                String(burst.peakGlobalSample), String(burst.onsetGlobalSample), String(burst.offsetGlobalSample),
                String(burst.initialOnsetGlobalSample), String(burst.initialOffsetGlobalSample),
                number(burst.durationMilliseconds), number(burst.durationCycles), number(burst.peakPower),
                number(burst.peakThresholdPower), number(burst.relativePeakPowerDB), number(burst.estimatedEnergy),
                number(burst.lowerPeakFrequencyHz), number(burst.upperPeakFrequencyHz), optional(burst.peakWTPL),
                optional(burst.meanWTPL), burst.bandID ?? "", burst.bandName ?? "",
                burst.bandDirection?.rawValue ?? "", optional(burst.bandConsistencyPercent), burst.boundarySource.rawValue,
            ]
        }
        return rows
    }

    static func summaryRows(_ summaries: [RhythmicBurstBandSummary]) -> [[String]] {
        var rows = [[
            "channel_index", "channel_name", "band_id", "band_name", "band_direction", "band_width_hz",
            "burst_count", "analyzed_duration_seconds", "rate_per_minute_per_hz", "occupancy_percent",
            "mean_duration_ms", "mean_duration_cycles", "mean_relative_peak_power_db", "mean_wtpl",
        ]]
        rows += summaries.map { value in
            [
                String(value.channelIndex), value.channelName, value.bandID ?? "", value.bandName,
                value.bandDirection?.rawValue ?? "", number(value.bandWidthHz), String(value.burstCount),
                number(value.analyzedDurationSeconds), number(value.ratePerMinutePerHz), number(value.occupancyPercent),
                number(value.meanDurationMilliseconds), number(value.meanDurationCycles),
                number(value.meanRelativePeakPowerDB), optional(value.meanWTPL),
            ]
        }
        return rows
    }

    private static func manifest(result: RhythmicBurstAnalysisResult, exportedAt: Date) throws -> Data {
        let config = result.configuration
        let object: [String: Any] = [
            "schema": schema,
            "schemaVersion": schemaVersion,
            "methodVersion": RhythmicBurstDetector.methodVersion,
            "exportedAt": ISO8601DateFormatter().string(from: exportedAt),
            "analysisDomain": "neural rhythmicity annotation; not artifact detection, rejection, or cleaning",
            "reference": [
                "repository": "https://github.com/laaanchic/WTPL",
                "commit": RhythmicBurstDetector.referenceCommit,
                "file": "Bursts_detection_WTPL_v1_0_0.m",
                "fileSHA256": RhythmicBurstDetector.referenceFileSHA256,
                "version": "1.0.0",
                "validation": "independent Python map oracle; upstream helper functions are not distributed",
            ],
            "source": [
                "recordingIdentity": result.source.recordingIdentity,
                "displayName": result.source.displayName,
                "sourceRevision": result.processingProvenance.sourceRevision,
            ],
            "selection": try jsonObject(result.selection),
            "parameters": [
                "peakPercentile": config.peakPercentile,
                "boundaryPercentile": config.boundaryPercentile,
                "minimumDurationCycles": config.minimumDurationCycles,
                "minimumMergeGapHz": config.minimumMergeGapHz,
                "relativeMergeGap": config.relativeMergeGap,
                "wtplThreshold": config.wtplThreshold,
                "boundarySource": config.boundarySource.rawValue,
                "maximumTimePointsPerSegment": config.maximumTimePointsPerSegment,
                "maximumDisplayTimePoints": config.maximumDisplayTimePoints,
                "morletWidthCycles": result.morletWidthCycles,
                "wtplLagCycles": result.wtplLagCycles,
            ] as [String: Any],
            "samplingRateHz": result.samplingRateHz,
            "frequenciesHz": result.frequenciesHz,
            "bandSource": result.bandSourceDescription,
            "bands": result.bandDefinitions.map {
                ["id": $0.id, "name": $0.name, "lowHz": $0.lowHz, "highHz": $0.highHz,
                 "direction": $0.direction?.rawValue ?? NSNull(), "source": $0.source] as [String: Any]
            },
            "maps": result.maps.map {
                ["id": $0.id, "channelIndex": $0.channelIndex, "segmentIndex": $0.segmentIndex,
                 "frequencyCount": $0.frequenciesHz.count, "timeCount": $0.timesSeconds.count,
                 "sampleStride": $0.sampleStride] as [String: Any]
            },
            "burstCount": result.bursts.count,
            "processingHistory": result.processingProvenance.processingSummary,
            "warnings": result.warnings,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private static func optional(_ value: Double?) -> String { value.map(number) ?? "" }
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "NaN" }
        return String(format: "%.9g", value)
    }
}
