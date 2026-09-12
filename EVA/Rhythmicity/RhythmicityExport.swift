//
//  RhythmicityExport.swift
//  EVA
//
//  Reproducible LAVI/ABBA package export.  The result intentionally contains
//  compact spectra and diagnostics, never source or surrogate waveforms.
//

import Foundation

nonisolated enum RhythmicityExport {
    static let schema = "org.nih.eva.rhythmicity"
    static let schemaVersion = 1
    static let methodVersion = "lavi-abba-2026-v1"
    static let referenceCommit = "78386879eeb8cf9be06a1edfa6917c91b2d0d2ba"

    struct BundleContents: Sendable {
        var files: [String: Data]
    }

    private struct Manifest: Codable {
        struct Software: Codable {
            var name: String
            var version: String
            var build: String
        }

        struct Morlet: Codable {
            var convention: String
            var widthCycles: Double
            var edgePolicy: String
        }

        struct LAVI: Codable {
            var lagCycles: Double
            var precision: String
            var backend: String
            var validPairCounts: [[Int]]
            var effectiveDurationsSeconds: [[Double]]
        }

        struct Significance: Codable {
            var available: Bool
            var source: String?
            var surrogateCount: Int?
            var alpha: Double?
            var tailRule: String?
            var seed: UInt64?
            var nonconvergedSurrogateCounts: [Int]
        }

        struct ABBA: Codable {
            var alphaAnchorLowerHz: Double
            var alphaAnchorUpperHz: Double
            var boundaryRepresentation: String
            var channelBandCounts: [Int]
        }

        struct ProcessingHistory: Codable {
            var sourceRevision: String
            var entries: [String]
        }

        var schema: String
        var schemaVersion: Int
        var methodVersion: String
        var referenceRepositoryCommit: String
        var exportedAt: Date
        var source: RhythmicitySourceDescriptor
        var selection: RhythmicitySelectionDescriptor
        var channels: [String]
        var channelIndices: [Int]
        var samplingRateHz: Double
        var frequenciesHz: [Double]
        var morlet: Morlet
        var lavi: LAVI
        var significance: Significance
        var abba: ABBA
        var processingHistory: ProcessingHistory
        var warnings: [String]
        var software: Software
    }

    static func bundle(
        result: LAVIAnalysisResult,
        selection: RhythmicitySelectionDescriptor,
        additionalWarnings: [String] = [],
        exportedAt: Date = Date(),
        bundle: Bundle = .main
    ) throws -> BundleContents {
        let warningText = unique(
            result.warnings.map(\.displayText)
                + result.channels.flatMap { $0.warnings.map(\.displayText) }
                + additionalWarnings
        )
        let ribbons = result.channels.compactMap(\.significanceRibbon)
        let firstRibbon = ribbons.first
        let significance = Manifest.Significance(
            available: ribbons.count == result.channels.count && !ribbons.isEmpty,
            source: firstRibbon?.source.rawValue,
            surrogateCount: firstRibbon?.surrogateCount,
            alpha: firstRibbon?.alpha,
            tailRule: firstRibbon?.tailRule.rawValue,
            seed: firstRibbon?.seed,
            nonconvergedSurrogateCounts: result.channels.map {
                $0.surrogateSummary?.nonconvergedCount ?? 0
            }
        )
        let manifest = Manifest(
            schema: schema,
            schemaVersion: schemaVersion,
            methodVersion: methodVersion,
            referenceRepositoryCommit: referenceCommit,
            exportedAt: exportedAt,
            source: result.source,
            selection: selection,
            channels: result.channels.map(\.channelName),
            channelIndices: result.channels.map(\.channelIndex),
            samplingRateHz: result.samplingRateHz,
            frequenciesHz: result.configuration.frequenciesHz,
            morlet: Manifest.Morlet(
                convention: "FieldTrip/LAVI 2026 complex Morlet",
                widthCycles: result.configuration.morletWidthCycles,
                edgePolicy: result.configuration.edgePolicy.rawValue
            ),
            lavi: Manifest.LAVI(
                lagCycles: result.configuration.laviLagCycles,
                precision: result.configuration.precision.rawValue,
                backend: result.configuration.backend.rawValue,
                validPairCounts: result.channels.map(\.validPairCounts),
                effectiveDurationsSeconds: result.channels.map(\.effectiveDurationsSeconds)
            ),
            significance: significance,
            abba: Manifest.ABBA(
                alphaAnchorLowerHz: result.configuration.alphaAnchorHz.lowerBound,
                alphaAnchorUpperHz: result.configuration.alphaAnchorHz.upperBound,
                boundaryRepresentation: "discrete frequency bins",
                channelBandCounts: result.channels.map { $0.bands.count }
            ),
            processingHistory: Manifest.ProcessingHistory(
                sourceRevision: result.processingProvenance.sourceRevision,
                entries: result.processingProvenance.processingSummary
            ),
            warnings: warningText,
            software: Manifest.Software(
                name: "EVA",
                version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        let values = result.channels.flatMap { $0.values.map(Float.init) }
        var ribbonValues: [Float] = []
        ribbonValues.reserveCapacity(result.channels.count * 2 * result.configuration.frequenciesHz.count)
        for channel in result.channels {
            ribbonValues.append(contentsOf: (channel.lowerSignificance
                ?? [Double](repeating: .nan, count: channel.frequenciesHz.count)).map(Float.init))
            ribbonValues.append(contentsOf: (channel.upperSignificance
                ?? [Double](repeating: .nan, count: channel.frequenciesHz.count)).map(Float.init))
        }

        return BundleContents(files: [
            "manifest.json": try encoder.encode(manifest),
            "lavi.csv": Data(csv(laviCSVRows(result: result)).utf8),
            "abba-bands.csv": Data(abbaCSV(result: result).utf8),
            "lavi.npy": TimeFrequencyExport.npyFloat32(
                shape: [result.channels.count, result.configuration.frequenciesHz.count],
                cOrderValues: values
            ),
            "lavi-ribbon.npy": TimeFrequencyExport.npyFloat32(
                shape: [result.channels.count, 2, result.configuration.frequenciesHz.count],
                cOrderValues: ribbonValues
            ),
            "warnings.txt": Data(((warningText.isEmpty ? "No validity warnings." : warningText.joined(separator: "\n")) + "\n").utf8),
        ])
    }

    static func write(_ contents: BundleContents, to destination: URL) throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".eva-rhythmicity-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        var committed = false
        defer {
            if !committed { try? manager.removeItem(at: temporary) }
        }
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

    static func laviCSVRows(result: LAVIAnalysisResult) -> [[String]] {
        var rows = [[
            "row_type", "condition_or_selection", "channel_index", "channel_name",
            "frequency_hz", "lavi", "median_lavi", "relative_lavi",
            "lower_significance", "upper_significance", "classification",
            "band_name", "significant", "valid_pair_count", "effective_duration_seconds",
        ]]
        for channel in result.channels {
            for index in channel.frequenciesHz.indices {
                let band = channel.bands.first { $0.beginIndex <= index && index <= $0.endIndex }
                rows.append([
                    "lavi", result.source.displayName, String(channel.channelIndex), channel.channelName,
                    number(channel.frequenciesHz[index]), number(channel.values[index]), number(channel.median),
                    number(channel.values[index] - channel.median),
                    optionalNumber(channel.lowerSignificance?[index]), optionalNumber(channel.upperSignificance?[index]),
                    band?.direction.rawValue ?? "", band?.canonicalName ?? unanchoredName(band),
                    band?.isSignificant.map(String.init) ?? "", String(channel.validPairCounts[index]),
                    number(channel.effectiveDurationsSeconds[index]),
                ])
            }
        }
        return rows
    }

    static func abbaCSV(result: LAVIAnalysisResult) -> String {
        var rows = [[
            "channel_index", "channel_name", "band_id", "band_name", "relative_to_alpha",
            "direction", "begin_index", "end_index", "peak_index", "begin_hz", "end_hz",
            "peak_hz", "peak_lavi", "peak_relative_lavi", "significant", "significance_margin",
        ]]
        for channel in result.channels {
            for band in channel.bands {
                rows.append([
                    String(channel.channelIndex), channel.channelName, band.id.uuidString,
                    band.canonicalName ?? "Unanchored", band.relativeToAlpha.map(String.init) ?? "",
                    band.direction.rawValue, String(band.beginIndex), String(band.endIndex), String(band.peakIndex),
                    number(band.beginFrequencyHz), number(band.endFrequencyHz), number(band.peakFrequencyHz),
                    number(band.peakLAVI), number(band.deviationFromMedian),
                    band.isSignificant.map(String.init) ?? "", optionalNumber(band.significanceMargin),
                ])
            }
        }
        return csv(rows)
    }

    private static func unanchoredName(_ band: ABBABand?) -> String {
        band == nil ? "" : "Unanchored"
    }

    private static func number(_ value: Double) -> String {
        value.isFinite ? String(format: "%.12g", value) : ""
    }

    private static func optionalNumber(_ value: Double?) -> String {
        guard let value else { return "" }
        return number(value)
    }

    private static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(csvEscape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    private static func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

nonisolated extension RhythmicityWarning {
    var displayText: String {
        switch self {
        case let .nonfiniteSamplesExcluded(channelIndex, count):
            return "Channel \(channelIndex + 1): excluded \(count) nonfinite samples and did not bridge those gaps."
        case let .insufficientValidDuration(channelIndex, frequencyHz):
            return "Channel \(channelIndex + 1): insufficient valid duration at \(String(format: "%.3g", frequencyHz)) Hz."
        case let .laviOutsideUnitInterval(channelIndex, frequencyHz, value):
            return "Channel \(channelIndex + 1): numerical LAVI \(value) was outside [0, 1] at \(frequencyHz) Hz."
        case let .iaaftSurrogatesDidNotConverge(channelIndex, count):
            return "Channel \(channelIndex + 1): \(count) matched surrogates reached a nonconverged stopping state and were retained."
        case .noAlphaAnchor:
            return "No sustained peak was found in the 6–14 Hz anchor range; bands remain unanchored."
        case .flatLAVIProfile:
            return "The finite LAVI profile is flat, so ABBA regions are unavailable."
        }
    }
}
