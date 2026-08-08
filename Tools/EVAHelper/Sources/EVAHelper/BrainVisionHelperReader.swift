//
//  BrainVisionHelperReader.swift
//  EVA Helper
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Minimal BrainVision reader for the command-line helper.
//

import Foundation

nonisolated enum BrainVisionHelperReader {
    enum Error: LocalizedError {
        case missingHeader(URL)
        case missingSidecar(URL, String)
        case malformedFile(URL, String)
        case unsupportedVariant(URL, String)
        case emptySignal(URL)

        var errorDescription: String? {
            switch self {
            case .missingHeader(let url):
                return "Unable to find BrainVision header for \(url.lastPathComponent)."
            case .missingSidecar(let url, let sidecar):
                return "\(url.lastPathComponent) requires \(sidecar), but that file was not found."
            case .malformedFile(let url, let details):
                return "Unable to parse \(url.lastPathComponent): \(details)"
            case .unsupportedVariant(let url, let details):
                return "Unsupported BrainVision variant in \(url.lastPathComponent): \(details)"
            case .emptySignal(let url):
                return "\(url.lastPathComponent) did not contain readable samples."
            }
        }
    }

    struct Result {
        var signal: MFFSignalData
        var referenceSignal: MFFSignalData?
        var headerURL: URL
    }

    static func load(from url: URL, progress: ((Double) -> Void)? = nil) throws -> Result {
        let headerURL = try resolvedHeaderURL(for: url)
        progress?(0.02)
        let text = try ImportText.read(headerURL)
        let ini = ImportINI.parse(text)
        let common = ini.section("common infos") ?? [:]

        guard let numberText = common["numberofchannels"], let numberOfChannels = Int(numberText) else {
            throw Error.malformedFile(headerURL, "missing NumberOfChannels")
        }
        guard let samplingIntervalText = common["samplinginterval"],
              let samplingInterval = Double(samplingIntervalText),
              samplingInterval > 0 else {
            throw Error.malformedFile(headerURL, "missing SamplingInterval")
        }

        let samplingRate = 1_000_000.0 / samplingInterval
        let dataFormat = (common["dataformat"] ?? "BINARY").uppercased()
        let orientation = (common["dataorientation"] ?? "MULTIPLEXED").uppercased()
        guard let dataFileName = common["datafile"], !dataFileName.isEmpty else {
            throw Error.malformedFile(headerURL, "missing DataFile")
        }

        let dataURL = headerURL.deletingLastPathComponent().appendingPathComponent(dataFileName)
        guard FileManager.default.fileExists(atPath: dataURL.path) else {
            throw Error.missingSidecar(headerURL, dataFileName)
        }

        let channels = parseChannelInfos(ini.section("channel infos") ?? [:], count: numberOfChannels)
        let channelNames = channels.map(\.name)
        progress?(0.08)

        let data: [[Float]]
        if dataFormat == "BINARY" {
            let binaryInfos = ini.section("binary infos") ?? [:]
            let binaryFormat = (binaryInfos["binaryformat"] ?? "INT_16").uppercased()
            data = try readBinaryData(
                dataURL,
                channelCount: numberOfChannels,
                format: binaryFormat,
                orientation: orientation,
                scales: channels.map(\.scaleToMicrovolts)
            ) { fraction in
                progress?(0.08 + 0.78 * fraction)
            }
        } else if dataFormat == "ASCII" {
            data = try readASCIIData(
                dataURL,
                channelCount: numberOfChannels,
                orientation: orientation,
                scales: channels.map(\.scaleToMicrovolts)
            ) { fraction in
                progress?(0.08 + 0.78 * fraction)
            }
        } else {
            throw Error.unsupportedVariant(headerURL, "DataFormat \(dataFormat)")
        }

        guard let sampleCount = data.first?.count, sampleCount > 0 else {
            throw Error.emptySignal(dataURL)
        }

        let markerURL = common["markerfile"].map {
            headerURL.deletingLastPathComponent().appendingPathComponent($0)
        }
        let events = markerURL.flatMap { try? parseMarkers($0, samplingRate: samplingRate) } ?? []
        progress?(0.92)

        let pnsIndices = (0..<numberOfChannels).filter {
            isBrainVisionPNSChannelName(channelNames[$0])
        }
        let eegIndices = (0..<numberOfChannels).filter { !pnsIndices.contains($0) }
        let selectedEEGIndices = eegIndices.isEmpty ? Array(0..<numberOfChannels) : eegIndices
        let eegData = selectedEEGIndices.map { data[$0] }
        let eegNames = selectedEEGIndices.map { channelNames[$0] }

        let signal = MFFSignalData(
            signalURL: headerURL,
            signalType: "BrainVision",
            numberOfChannels: eegData.count,
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            recordingStartTime: nil,
            events: events,
            data: eegData,
            channelNames: eegNames
        )

        let references: MFFSignalData? = pnsIndices.isEmpty ? nil : MFFSignalData(
            signalURL: headerURL,
            signalType: "BrainVision PNS",
            numberOfChannels: pnsIndices.count,
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            recordingStartTime: nil,
            events: [],
            data: pnsIndices.map { data[$0] },
            channelNames: pnsIndices.map { channelNames[$0] }
        )

        progress?(1)
        return Result(signal: signal, referenceSignal: references, headerURL: headerURL)
    }

    private struct ChannelInfo {
        var name: String
        var scaleToMicrovolts: Double
    }

    private static func isBrainVisionPNSChannelName(_ name: String) -> Bool {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
        return normalized.hasPrefix("CWL")
            || normalized.hasPrefix("ECG")
            || normalized.hasPrefix("EKG")
    }

    private static func resolvedHeaderURL(for url: URL) throws -> URL {
        switch url.pathExtension.lowercased() {
        case "vhdr":
            return url
        case "vmrk", "eeg":
            let sibling = url.deletingPathExtension().appendingPathExtension("vhdr")
            guard FileManager.default.fileExists(atPath: sibling.path) else {
                throw Error.missingHeader(url)
            }
            return sibling
        default:
            throw Error.unsupportedVariant(url, "expected .vhdr, .eeg, or .vmrk")
        }
    }

    private static func parseChannelInfos(_ infos: [String: String], count: Int) -> [ChannelInfo] {
        (0..<count).map { index in
            let key = "ch\(index + 1)"
            let parts = (infos[key] ?? "Ch\(index + 1),,1,uV")
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            let name = parts.first.map(decodeEscapedComma)?.nonEmpty
                ?? "Ch\(index + 1)"
            let resolution = parts.count > 2 ? Double(parts[2]) ?? 1 : 1
            let unit = parts.count > 3 ? parts[3].nonEmpty ?? "uV" : "uV"
            return ChannelInfo(name: name, scaleToMicrovolts: microvoltsPerUnit(unit) * resolution)
        }
    }

    private static func readBinaryData(
        _ url: URL,
        channelCount: Int,
        format: String,
        orientation: String,
        scales: [Double],
        progress: ((Double) -> Void)? = nil
    ) throws -> [[Float]] {
        let bytes = try Data(contentsOf: url)
        let valueByteCount: Int
        let valueAt: (Data, Int) throws -> Double
        switch format {
        case "INT_16":
            valueByteCount = 2
            valueAt = { Double(try BinaryImport.int16LE($0, at: $1)) }
        case "INT_32":
            valueByteCount = 4
            valueAt = { Double(try BinaryImport.int32LE($0, at: $1)) }
        case "IEEE_FLOAT_32":
            valueByteCount = 4
            valueAt = { Double(try BinaryImport.float32LE($0, at: $1)) }
        default:
            throw Error.unsupportedVariant(url, "BinaryFormat \(format)")
        }

        let sampleCount = bytes.count / max(valueByteCount * channelCount, 1)
        guard sampleCount > 0, bytes.count >= sampleCount * channelCount * valueByteCount else {
            throw Error.emptySignal(url)
        }

        var data = Array(repeating: [Float](repeating: 0, count: sampleCount), count: channelCount)
        var offset = 0
        let reportEvery = max(1, sampleCount / 100)
        switch orientation {
        case "MULTIPLEXED":
            for sample in 0..<sampleCount {
                for channel in 0..<channelCount {
                    data[channel][sample] = Float(try valueAt(bytes, offset) * scales[channel])
                    offset += valueByteCount
                }
                if sample % reportEvery == 0 || sample == sampleCount - 1 {
                    progress?(Double(sample + 1) / Double(sampleCount))
                }
            }
        case "VECTORIZED":
            for channel in 0..<channelCount {
                for sample in 0..<sampleCount {
                    data[channel][sample] = Float(try valueAt(bytes, offset) * scales[channel])
                    offset += valueByteCount
                }
                progress?(Double(channel + 1) / Double(channelCount))
            }
        default:
            throw Error.unsupportedVariant(url, "DataOrientation \(orientation)")
        }
        return data
    }

    private static func readASCIIData(
        _ url: URL,
        channelCount: Int,
        orientation: String,
        scales: [Double],
        progress: ((Double) -> Void)? = nil
    ) throws -> [[Float]] {
        guard orientation == "MULTIPLEXED" else {
            throw Error.unsupportedVariant(url, "ASCII vectorized data")
        }
        let values = ImportText.numericTokens(try ImportText.read(url))
        guard values.count >= channelCount else {
            throw Error.emptySignal(url)
        }
        let sampleCount = values.count / channelCount
        var data = Array(repeating: [Float](repeating: 0, count: sampleCount), count: channelCount)
        let reportEvery = max(1, sampleCount / 100)
        for sample in 0..<sampleCount {
            for channel in 0..<channelCount {
                data[channel][sample] = Float(values[sample * channelCount + channel] * scales[channel])
            }
            if sample % reportEvery == 0 || sample == sampleCount - 1 {
                progress?(Double(sample + 1) / Double(sampleCount))
            }
        }
        return data
    }

    private static func parseMarkers(_ url: URL, samplingRate: Double) throws -> [MFFEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let ini = ImportINI.parse(try ImportText.read(url))
        let markers = ini.section("marker infos") ?? [:]
        return markers.keys.sorted(by: ImportText.naturalKeySort).compactMap { key in
            guard key.lowercased().hasPrefix("mk") else { return nil }
            let parts = (markers[key] ?? "")
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count >= 3,
                  !parts[0].localizedCaseInsensitiveContains("new segment"),
                  let sample = Int(parts[2]) else {
                return nil
            }
            let type = decodeEscapedComma(parts[0]).nonEmpty ?? "Marker"
            let description = parts.count > 1 ? decodeEscapedComma(parts[1]).nonEmpty : nil
            let code = description.map { "\(type)/\($0)" } ?? type
            let sizeInSamples = parts.count > 3 ? Int(parts[3]) : nil
            let duration = sizeInSamples.flatMap { $0 > 1 ? Double($0) / samplingRate : nil }
            let onset = Double(max(sample - 1, 0)) / samplingRate
            return MFFEvent(
                id: "\(url.lastPathComponent)-\(key)",
                code: code,
                label: type,
                eventDescription: description,
                beginTimeSeconds: onset,
                rawBeginTime: "\(sample)",
                sourceFile: url.lastPathComponent,
                durationSeconds: duration
            )
        }
    }

    private static func decodeEscapedComma(_ value: String) -> String {
        value.replacingOccurrences(of: "\\1", with: ",")
    }

    private static func microvoltsPerUnit(_ unit: String) -> Double {
        switch unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "v":
            return 1_000_000
        case "mv":
            return 1_000
        case "uv", "":
            return 1
        case "nv":
            return 0.001
        default:
            return 1
        }
    }
}

private nonisolated enum ImportText {
    static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        throw BrainVisionHelperReader.Error.malformedFile(url, "unsupported text encoding")
    }

    static func tokens(_ line: String) -> [String] {
        line.replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    static func numericTokens(_ text: String) -> [Double] {
        tokens(text).compactMap(Double.init)
    }

    static func naturalKeySort(_ left: String, _ right: String) -> Bool {
        left.localizedStandardCompare(right) == .orderedAscending
    }
}

private nonisolated struct ImportINI {
    var sections: [String: [String: String]]

    func section(_ name: String) -> [String: String]? {
        sections[name.lowercased()]
    }

    static func parse(_ text: String) -> ImportINI {
        var sections: [String: [String: String]] = [:]
        var current = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix(";") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).lowercased()
                sections[current, default: [:]] = [:]
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            sections[current, default: [:]][key] = value
        }
        return ImportINI(sections: sections)
    }
}

private nonisolated enum BinaryImport {
    static func int16LE(_ data: Data, at offset: Int) throws -> Int16 {
        try require(data, offset, 2)
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1])
        return Int16(bitPattern: b1 << 8 | b0)
    }

    static func int32LE(_ data: Data, at offset: Int) throws -> Int32 {
        try require(data, offset, 4)
        let value = UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
        return Int32(bitPattern: value)
    }

    static func float32LE(_ data: Data, at offset: Int) throws -> Float {
        try require(data, offset, 4)
        return Float(bitPattern: UInt32(bitPattern: try int32LE(data, at: offset)))
    }

    private static func require(_ data: Data, _ offset: Int, _ count: Int) throws {
        guard offset >= 0, offset + count <= data.count else {
            throw BrainVisionHelperReader.Error.malformedFile(URL(fileURLWithPath: "<binary>"), "unexpected end of binary data")
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
