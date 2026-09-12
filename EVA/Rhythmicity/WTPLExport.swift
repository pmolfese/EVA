//
//  WTPLExport.swift
//  EVA
//
//  Reproducible event-related WTPL package export. Invalid edge samples remain
//  NaN in NPY arrays and valid-trial counts are exported separately.
//

import Foundation

nonisolated enum WTPLExport {
    static let schema = "org.nih.eva.rhythmicity"
    static let schemaVersion = 1

    struct BundleContents: Sendable {
        var files: [String: Data]
    }

    static func bundle(
        result: WTPLAnalysisResult,
        bands: [EEGFrequencyBand],
        windows: [TimeFrequencyExport.Window],
        exportedAt: Date = Date()
    ) throws -> BundleContents {
        var files: [String: Data] = [:]
        for condition in result.conditions {
            let stem = safeName(condition.condition)
            let raw = condition.channels.map(\.meanWTPL)
            let delta = condition.channels.map { channel in
                channel.deltaWTPL ?? nanGrid(frequencies: result.frequenciesHz.count, times: result.timesMs.count)
            }
            let counts = condition.channels.map { channel in
                channel.validTrialCounts.map { $0.map(Double.init) }
            }
            files["wtpl-\(stem).npy"] = TimeFrequencyExport.npy(raw)
            files["delta-wtpl-\(stem).npy"] = TimeFrequencyExport.npy(delta)
            files["wtpl-valid-counts-\(stem).npy"] = TimeFrequencyExport.npy(counts)
        }
        files["wtpl-scalars.csv"] = TimeFrequencyExport.csvData(
            scalarCSVRows(result: result, bands: bands, windows: windows)
        )
        files["warnings.txt"] = Data(((result.warnings.isEmpty
            ? "No validity warnings."
            : result.warnings.map(\.displayText).joined(separator: "\n")) + "\n").utf8)
        files["manifest.json"] = try manifestJSON(
            result: result, bands: bands, windows: windows, exportedAt: exportedAt
        )
        return BundleContents(files: files)
    }

    static func write(_ contents: BundleContents, to destination: URL) throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".eva-wtpl-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? manager.removeItem(at: temporary) } }
        for name in contents.files.keys.sorted() {
            guard let data = contents.files[name] else { continue }
            try data.write(to: temporary.appendingPathComponent(name), options: .atomic)
        }
        guard !manager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        try manager.moveItem(at: temporary, to: destination)
        committed = true
    }

    static func scalarCSVRows(
        result: WTPLAnalysisResult,
        bands: [EEGFrequencyBand],
        windows: [TimeFrequencyExport.Window]
    ) -> [[String]] {
        var rows = [[
            "row_type", "condition", "channel_index", "channel_name", "band", "window",
            "measure", "value", "valid_trial_count_min",
        ]]
        func summary(_ key: String, _ value: String) {
            rows.append(["summary", "", "", "", "", "", key, value, ""])
        }
        summary("method_version", WTPLEngine.methodVersion)
        summary("source_revision", result.processingProvenance.sourceRevision)
        summary("lag_cycles", result.lagCycles.map(clean).joined(separator: ";"))
        summary("edge_policy", result.edgePolicy.rawValue)
        summary("baseline_ms", result.baselineWindowMs.map {
            "\(clean($0.lowerBound))...\(clean($0.upperBound))"
        } ?? "unavailable")

        for condition in result.conditions {
            for channel in condition.channels {
                for band in bands {
                    let frequencies = result.frequenciesHz.indices.filter {
                        result.frequenciesHz[$0] >= band.lowHz && result.frequenciesHz[$0] <= band.highHz
                    }
                    guard !frequencies.isEmpty else { continue }
                    for window in windows {
                        let times = result.timesMs.indices.filter {
                            result.timesMs[$0] >= window.startMs && result.timesMs[$0] <= window.endMs
                        }
                        guard !times.isEmpty else { continue }
                        let minimumCount = frequencies.flatMap { frequency in
                            times.map { channel.validTrialCounts[frequency][$0] }
                        }.min() ?? 0
                        rows.append(dataRow(
                            condition: condition.condition, channel: channel, band: band,
                            window: window, measure: "wtpl",
                            value: mean(channel.meanWTPL, frequencies: frequencies, times: times),
                            minimumCount: minimumCount
                        ))
                        if let delta = channel.deltaWTPL {
                            rows.append(dataRow(
                                condition: condition.condition, channel: channel, band: band,
                                window: window, measure: "delta_wtpl",
                                value: mean(delta, frequencies: frequencies, times: times),
                                minimumCount: minimumCount
                            ))
                        }
                    }
                }
            }
        }
        return rows
    }

    private static func manifestJSON(
        result: WTPLAnalysisResult,
        bands: [EEGFrequencyBand],
        windows: [TimeFrequencyExport.Window],
        exportedAt: Date
    ) throws -> Data {
        let baseline: Any = result.baselineWindowMs.map {
            ["startMs": $0.lowerBound, "endMs": $0.upperBound]
        } ?? NSNull()
        let object: [String: Any] = [
            "schema": schema,
            "schemaVersion": schemaVersion,
            "methodVersion": WTPLEngine.methodVersion,
            "reference": [
                "kind": "independent paper-equation Python oracle",
                "fixture": "EVATests/Fixtures/Rhythmicity/wtpl-python-oracle.json",
                "upstreamProvenanceCommit": "6da57b71f1084c62cfa1a4deaebee227d38f2584",
            ],
            "exportedAt": ISO8601DateFormatter().string(from: exportedAt),
            "source": [
                "recordingIdentity": result.source.recordingIdentity,
                "displayName": result.source.displayName,
                "sourceRevision": result.processingProvenance.sourceRevision,
            ],
            "frequenciesHz": result.frequenciesHz,
            "timesMs": result.timesMs,
            "nCycles": result.nCycles,
            "wtpl": [
                "definition": "within-trial phase persistence across signed cycle lags",
                "lagCycles": result.lagCycles,
                "edgePolicy": result.edgePolicy.rawValue,
                "baselineWindowMs": baseline,
                "invalidValue": "NaN",
                "dimensions": "channel × frequency × time",
                "validCounts": "separate float32 NPY; exact integer-valued counts",
            ],
            "conditions": result.conditions.map { condition in
                [
                    "name": condition.condition,
                    "channels": condition.channels.map { $0.channelName },
                    "channelIndices": condition.channels.map { $0.channelIndex },
                    "trialCounts": condition.channels.map { $0.trialCount },
                ] as [String: Any]
            },
            "bands": bands.map { ["name": $0.name, "lowHz": $0.lowHz, "highHz": $0.highHz] },
            "windows": windows.map { ["name": $0.label, "startMs": $0.startMs, "endMs": $0.endMs] },
            "processingHistory": result.processingProvenance.processingSummary,
            "warnings": result.warnings.map(\.displayText),
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func dataRow(
        condition: String,
        channel: WTPLChannelResult,
        band: EEGFrequencyBand,
        window: TimeFrequencyExport.Window,
        measure: String,
        value: Double,
        minimumCount: Int
    ) -> [String] {
        [
            "wtpl_scalar", condition, String(channel.channelIndex), channel.channelName,
            band.name, window.label, measure, clean(value), String(minimumCount),
        ]
    }

    private static func mean(_ grid: [[Double]], frequencies: [Int], times: [Int]) -> Double {
        var sum = 0.0
        var count = 0
        for frequency in frequencies where grid.indices.contains(frequency) {
            for time in times where grid[frequency].indices.contains(time) {
                let value = grid[frequency][time]
                if value.isFinite { sum += value; count += 1 }
            }
        }
        return count > 0 ? sum / Double(count) : .nan
    }

    private static func nanGrid(frequencies: Int, times: Int) -> [[Double]] {
        [[Double]](repeating: [Double](repeating: .nan, count: times), count: frequencies)
    }

    private static func safeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let result = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "condition" : result
    }

    private static func clean(_ value: Double) -> String {
        if !value.isFinite { return "NaN" }
        if value == value.rounded(), abs(value) < 1e15 { return String(format: "%.0f", value) }
        return String(format: "%.9g", value)
    }
}
