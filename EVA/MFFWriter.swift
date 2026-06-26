//
//  MFFWriter.swift
//  EVA
//
//  Native MFF export for EVA-processed signals.
//
//  Attribution: the signal block and epoch XML writer structure follows the
//  public mffpy writer implementation by the MFFPy contributors
//  (Apache-2.0), especially mffpy/bin_writer.py, mffpy/header_block/
//  header_block.py, and mffpy/epoch.py.
//

import Foundation

nonisolated enum MFFExportKind: Sendable {
    case continuous
    case epoched
    case averaged

    var statusName: String {
        switch self {
        case .continuous:
            return "continuous"
        case .epoched:
            return "segmented"
        case .averaged:
            return "averaged"
        }
    }
}

nonisolated enum MFFWriterError: LocalizedError {
    case emptySignal
    case invalidSamplingRate(Double)
    case inconsistentChannelLengths
    case invalidSegment(EpochSegment)
    case existingOutput(URL)

    var errorDescription: String? {
        switch self {
        case .emptySignal:
            return "There are no samples to export."
        case .invalidSamplingRate(let rate):
            return "MFF export requires a positive integer sampling rate, but found \(rate)."
        case .inconsistentChannelLengths:
            return "MFF export requires every channel to have the same number of samples."
        case .invalidSegment(let segment):
            return "Cannot export invalid segment \(segment.category)."
        case .existingOutput(let url):
            return "\(url.lastPathComponent) already exists and could not be replaced."
        }
    }
}

nonisolated enum MFFWriter {
    static func write(
        signal: MFFSignalData,
        segments: [EpochSegment],
        kind: MFFExportKind,
        to outputURL: URL
    ) throws {
        let sampleRate = try integerSamplingRate(signal.samplingRate)
        let sampleCount = try validate(signal: signal)
        let blocks = try exportBlocks(for: signal, sampleCount: sampleCount, segments: segments, kind: kind)

        let packageURL = normalizedMFFURL(outputURL)
        if FileManager.default.fileExists(atPath: packageURL.path) {
            do {
                try FileManager.default.removeItem(at: packageURL)
            } catch {
                throw MFFWriterError.existingOutput(packageURL)
            }
        }
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        do {
            try writeInfoXML(signal: signal, kind: kind, to: packageURL)
            try writeSignalInfoXML(to: packageURL)
            try writeSignalBinary(
                blocks: blocks.map { $0.withSignalData(signal.data) },
                channelCount: signal.numberOfChannels,
                sampleRate: sampleRate,
                to: packageURL
            )
            try writeEpochsXML(blocks: blocks, sampleRate: sampleRate, to: packageURL)
            try writeEventsXML(signal: signal, blocks: blocks, sampleRate: sampleRate, kind: kind, to: packageURL)
            try writeChannelNamesXML(signal: signal, to: packageURL)
        } catch {
            try? FileManager.default.removeItem(at: packageURL)
            throw error
        }
    }

    private static func normalizedMFFURL(_ url: URL) -> URL {
        url.pathExtension.lowercased() == "mff" ? url : url.appendingPathExtension("mff")
    }

    private static func integerSamplingRate(_ rate: Double) throws -> Int {
        guard rate.isFinite, rate > 0 else {
            throw MFFWriterError.invalidSamplingRate(rate)
        }
        let rounded = rate.rounded()
        guard abs(rounded - rate) < 0.0001, rounded < Double(1 << 24) else {
            throw MFFWriterError.invalidSamplingRate(rate)
        }
        return Int(rounded)
    }

    private static func validate(signal: MFFSignalData) throws -> Int {
        guard signal.numberOfChannels > 0,
              signal.data.count == signal.numberOfChannels,
              let first = signal.data.first,
              !first.isEmpty else {
            throw MFFWriterError.emptySignal
        }
        let count = first.count
        guard signal.data.allSatisfy({ $0.count == count }) else {
            throw MFFWriterError.inconsistentChannelLengths
        }
        return count
    }

    private static func exportBlocks(
        for signal: MFFSignalData,
        sampleCount: Int,
        segments: [EpochSegment],
        kind: MFFExportKind
    ) throws -> [ExportBlock] {
        guard kind != .continuous, !segments.isEmpty else {
            return [
                ExportBlock(
                    startSample: 0,
                    endSample: sampleCount - 1,
                    stimulusOffsetSamples: nil,
                    category: "Continuous",
                    sourceCode: "Continuous",
                    sourceTimeSeconds: 0,
                    contributingEpochCount: 1
                )
            ]
        }

        return try segments.sorted { $0.startSample < $1.startSample }.map { segment in
            guard segment.startSample >= 0,
                  segment.endSample >= segment.startSample,
                  segment.endSample < sampleCount else {
                throw MFFWriterError.invalidSegment(segment)
            }
            return ExportBlock(
                startSample: segment.startSample,
                endSample: segment.endSample,
                stimulusOffsetSamples: segment.stimulusOffsetSamples,
                category: segment.category,
                sourceCode: segment.sourceCode,
                sourceTimeSeconds: segment.sourceTimeSeconds,
                contributingEpochCount: segment.contributingEpochCount
            )
        }
    }

    private static func writeInfoXML(signal: MFFSignalData, kind: MFFExportKind, to packageURL: URL) throws {
        let recordTime = mffDateString(signal.recordingStartTime ?? Date())
        let xml = """
<?xml version="1.0" encoding="UTF-8"?>
<fileInfo>
  <recordTime>\(xmlEscape(recordTime))</recordTime>
  <mffVersion>3</mffVersion>
  <acquisitionVersion>EVA MFF export</acquisitionVersion>
  <appName>EVA</appName>
  <exportKind>\(xmlEscape(kind.statusName))</exportKind>
</fileInfo>
"""
        try xml.write(to: packageURL.appendingPathComponent("info.xml"), atomically: true, encoding: .utf8)
    }

    private static func writeSignalInfoXML(to packageURL: URL) throws {
        let xml = """
<?xml version="1.0" encoding="UTF-8"?>
<dataInfo>
  <generalInformation>
    <fileDataType>
      <EEG/>
    </fileDataType>
  </generalInformation>
</dataInfo>
"""
        try xml.write(to: packageURL.appendingPathComponent("info1.xml"), atomically: true, encoding: .utf8)
    }

    private static func writeSignalBinary(
        blocks: [ExportBlock],
        channelCount: Int,
        sampleRate: Int,
        to packageURL: URL
    ) throws {
        var data = Data()
        for block in blocks {
            let sampleCount = block.sampleCount
            let blockSize = channelCount * sampleCount * MemoryLayout<Float>.size
            let headerSize = 20 + channelCount * 8
            appendInt32(1, to: &data)
            appendInt32(headerSize, to: &data)
            appendInt32(blockSize, to: &data)
            appendInt32(channelCount, to: &data)

            for channel in 0..<channelCount {
                appendInt32(channel * sampleCount * MemoryLayout<Float>.size, to: &data)
            }

            let rateDepth = (sampleRate << 8) + 32
            for _ in 0..<channelCount {
                appendInt32(rateDepth, to: &data)
            }

            appendInt32(0, to: &data)

            for channel in 0..<channelCount {
                for sample in block.startSample...block.endSample {
                    appendFloat32(block.signalData[channel][sample], to: &data)
                }
            }
        }

        try data.write(to: packageURL.appendingPathComponent("signal1.bin"), options: .atomic)
    }

    private static func writeEpochsXML(blocks: [ExportBlock], sampleRate: Int, to packageURL: URL) throws {
        var body = ""
        var cursorMicroseconds = 0
        for (index, block) in blocks.enumerated() {
            let duration = Int((Double(block.sampleCount) / Double(sampleRate) * 1_000_000).rounded())
            let begin = cursorMicroseconds
            let end = begin + duration
            body += """
  <epoch>
    <beginTime>\(begin)</beginTime>
    <endTime>\(end)</endTime>
    <firstBlock>\(index + 1)</firstBlock>
    <lastBlock>\(index + 1)</lastBlock>
  </epoch>
"""
            cursorMicroseconds = end
        }
        let xml = """
<?xml version="1.0" encoding="UTF-8"?>
<epochs>
\(body)</epochs>
"""
        try xml.write(to: packageURL.appendingPathComponent("epochs.xml"), atomically: true, encoding: .utf8)
    }

    private static func writeEventsXML(
        signal: MFFSignalData,
        blocks: [ExportBlock],
        sampleRate: Int,
        kind: MFFExportKind,
        to packageURL: URL
    ) throws {
        let events = exportEvents(signal: signal, blocks: blocks, sampleRate: sampleRate, kind: kind)
        var body = ""
        for event in events {
            body += """
  <event>
    <code>\(xmlEscape(event.code))</code>
    <beginTime>\(String(format: "%.6f", event.beginTimeSeconds))</beginTime>
    <duration>0</duration>
    <description>\(xmlEscape(event.description))</description>
  </event>
"""
        }
        let xml = """
<?xml version="1.0" encoding="UTF-8"?>
<eventTrack>
  <name>EVA Export</name>
\(body)</eventTrack>
"""
        try xml.write(to: packageURL.appendingPathComponent("Events_EVA.xml"), atomically: true, encoding: .utf8)
    }

    private static func writeChannelNamesXML(signal: MFFSignalData, to packageURL: URL) throws {
        guard let names = signal.channelNames, names.count == signal.numberOfChannels else { return }
        var body = ""
        for (index, name) in names.enumerated() {
            body += """
  <sensor>
    <number>\(index + 1)</number>
    <name>\(xmlEscape(name))</name>
    <type>0</type>
  </sensor>
"""
        }
        let xml = """
<?xml version="1.0" encoding="UTF-8"?>
<sensorLayout>
  <name>EVA Channel Names</name>
\(body)</sensorLayout>
"""
        try xml.write(to: packageURL.appendingPathComponent("sensorLayout.xml"), atomically: true, encoding: .utf8)
    }

    private static func exportEvents(
        signal: MFFSignalData,
        blocks: [ExportBlock],
        sampleRate: Int,
        kind: MFFExportKind
    ) -> [ExportEvent] {
        if kind == .continuous {
            return signal.events.map {
                ExportEvent(code: $0.code, beginTimeSeconds: $0.beginTimeSeconds, description: $0.sourceFile)
            }
        }

        var cursor = 0
        var output: [ExportEvent] = []
        for block in blocks {
            let eventSample = cursor + (block.stimulusOffsetSamples ?? 0)
            let eventTime = Double(eventSample) / Double(sampleRate)
            let description: String
            if kind == .averaged {
                description = "\(block.contributingEpochCount) contributing epochs"
            } else {
                description = "Source \(block.sourceCode) at \(String(format: "%.6f", block.sourceTimeSeconds)) s"
            }
            output.append(ExportEvent(code: block.category, beginTimeSeconds: eventTime, description: description))
            cursor += block.sampleCount
        }
        return output
    }

    private static func appendInt32(_ value: Int, to data: inout Data) {
        var little = Int32(value).littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func appendFloat32(_ value: Float, to data: inout Data) {
        var little = value.bitPattern.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func mffDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private nonisolated struct ExportBlock: Sendable {
    let startSample: Int
    let endSample: Int
    let stimulusOffsetSamples: Int?
    let category: String
    let sourceCode: String
    let sourceTimeSeconds: Double
    let contributingEpochCount: Int
    var signalData: [[Float]] = []

    var sampleCount: Int {
        endSample - startSample + 1
    }

    func withSignalData(_ data: [[Float]]) -> ExportBlock {
        var copy = self
        copy.signalData = data
        return copy
    }
}

private nonisolated struct ExportEvent: Sendable {
    let code: String
    let beginTimeSeconds: Double
    let description: String
}
