//
//  EDFCodec.swift
//  EVA BIDS
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
//  Self-contained EDF (European Data Format) reader/writer used as the
//  BIDS-legal signal container for `eva-bids to-bids` / `from-bids`. BIDS
//  event/channel metadata lives in the TSV/JSON sidecars, not EDF+
//  annotations, so this only needs plain EDF (no annotation channel).
//

import Foundation

enum EDFError: LocalizedError {
    case tooManyChannels(Int)
    case emptyChannel(String)
    case malformedHeader(String)
    case unexpectedEndOfFile

    var errorDescription: String? {
        switch self {
        case .tooManyChannels(let count):
            return "EDF supports at most 9999 signals; got \(count)."
        case .emptyChannel(let label):
            return "Channel \(label) has no samples."
        case .malformedHeader(let detail):
            return "Malformed EDF header: \(detail)."
        case .unexpectedEndOfFile:
            return "Unexpected end of file while reading EDF data."
        }
    }
}

enum EDFWriter {
    struct ChannelSpec {
        let label: String
        let physicalDimension: String
        let samplingRate: Double
        let data: [Float]
    }

    /// Writes plain (non-EDF+) EDF. Channels may have different sampling
    /// rates; each gets its own samples-per-record derived from a shared
    /// 1-second record duration.
    static func write(
        channels: [ChannelSpec],
        startDate: Date?,
        patientID: String,
        recordingID: String,
        to url: URL
    ) throws {
        guard channels.count <= 9999 else { throw EDFError.tooManyChannels(channels.count) }
        for channel in channels {
            guard !channel.data.isEmpty else { throw EDFError.emptyChannel(channel.label) }
        }

        let recordDurationSeconds = 1.0
        let samplesPerRecord = channels.map { max(Int((($0.samplingRate * recordDurationSeconds)).rounded()), 1) }
        let numRecords = zip(channels, samplesPerRecord).map { channel, perRecord in
            Int(ceil(Double(channel.data.count) / Double(perRecord)))
        }.max() ?? 0

        // The physical min/max actually used to scale samples must be the
        // *rounded* values that get written into the 8-char header fields —
        // not the exact computed range — or encode/decode disagree on scale
        // (worst for tiny-magnitude channels, where truncating an unrounded
        // "%g" string to 8 chars can silently mangle the exponent).
        var ranges: [(min: Double, max: Double)] = []
        for channel in channels {
            let values = channel.data.map(Double.init)
            var lo = values.min() ?? -1
            var hi = values.max() ?? 1
            if lo == hi {
                lo -= 1
                hi += 1
            }
            // Small headroom so exact extrema don't clip against the digital limits.
            let margin = (hi - lo) * 0.01
            let roundedLo = Double(edfNumericField(lo - margin, width: 8)) ?? (lo - margin)
            let roundedHi = Double(edfNumericField(hi + margin, width: 8)) ?? (hi + margin)
            ranges.append((roundedLo, roundedHi))
        }

        let headerRecordBytes = 256 * (channels.count + 1)
        var header = Data()
        header.append(edfField("0", 8))
        header.append(edfField(patientID, 80))
        header.append(edfField(recordingID, 80))
        header.append(edfField(edfDateString(startDate ?? Date()), 8))
        header.append(edfField(edfTimeString(startDate ?? Date()), 8))
        header.append(edfField(String(headerRecordBytes), 8))
        header.append(edfField("", 44))
        header.append(edfField(String(numRecords), 8))
        header.append(edfField(edfNumericField(recordDurationSeconds, width: 8), 8))
        header.append(edfField(String(channels.count), 4))

        for channel in channels { header.append(edfField(channel.label, 16)) }
        for _ in channels { header.append(edfField("", 80)) }
        for channel in channels { header.append(edfField(channel.physicalDimension, 8)) }
        for range in ranges { header.append(edfField(edfNumericField(range.min, width: 8), 8)) }
        for range in ranges { header.append(edfField(edfNumericField(range.max, width: 8), 8)) }
        for _ in channels { header.append(edfField("-32768", 8)) }
        for _ in channels { header.append(edfField("32767", 8)) }
        for _ in channels { header.append(edfField("", 80)) }
        for perRecord in samplesPerRecord { header.append(edfField(String(perRecord), 8)) }
        for _ in channels { header.append(edfField("", 32)) }

        guard header.count == headerRecordBytes else {
            throw EDFError.malformedHeader("built \(header.count) bytes, expected \(headerRecordBytes)")
        }

        var body = Data()
        for record in 0..<numRecords {
            for (index, channel) in channels.enumerated() {
                let perRecord = samplesPerRecord[index]
                let (lo, hi) = ranges[index]
                let scale = 65535.0 / (hi - lo)
                let start = record * perRecord
                for offset in 0..<perRecord {
                    let sampleIndex = start + offset
                    let physical = sampleIndex < channel.data.count ? Double(channel.data[sampleIndex]) : 0
                    let clamped = min(max(physical, lo), hi)
                    let digital = Int((clamped - lo) * scale - 32768)
                    appendInt16LE(digital, to: &body)
                }
            }
        }

        var output = header
        output.append(body)
        try output.write(to: url, options: .atomic)
    }

    /// Formats a double to fit exactly within `width` ASCII characters without
    /// truncating a valid numeral into an invalid (or worse, silently
    /// misscaled) one. Blindly truncating e.g. "2.527e-24" to 8 chars yields
    /// "2.527e-2" — a different, wildly larger number — rather than an error.
    static func edfNumericField(_ value: Double, width: Int) -> String {
        guard value.isFinite else { return String(repeating: "0", count: min(1, width)) }
        for precision in stride(from: min(width - 1, 6), through: 0, by: -1) {
            let candidate = String(format: "%.\(precision)g", value)
            if candidate.count <= width { return candidate }
        }
        // Last resort: minimal-mantissa scientific notation always fits within
        // 8 characters for any representable Double (exponent is at most 3
        // digits), at the cost of only 1 significant figure.
        return String(format: "%.0e", value)
    }

    private static func edfField(_ value: String, _ width: Int) -> Data {
        var text = value
        if text.count > width {
            text = String(text.prefix(width))
        } else {
            text += String(repeating: " ", count: width - text.count)
        }
        return Data(text.utf8)
    }

    private static func appendInt16LE(_ value: Int, to data: inout Data) {
        let clamped = min(max(value, -32768), 32767)
        var little = Int16(clamped).littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func edfDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd.MM.yy"
        return formatter.string(from: date)
    }

    private static func edfTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH.mm.ss"
        return formatter.string(from: date)
    }
}

struct EDFChannel {
    let label: String
    let physicalDimension: String
    let samplingRate: Double
    let data: [Float]
}

struct EDFRecording {
    let patientID: String
    let recordingID: String
    let startDate: Date?
    let recordDurationSeconds: Double
    let channels: [EDFChannel]
}

enum EDFReader {
    static func load(from url: URL) throws -> EDFRecording {
        let bytes = try Data(contentsOf: url)
        guard bytes.count >= 256 else { throw EDFError.malformedHeader("file is too short") }

        let patientID = try field(bytes, offset: 8, length: 80)
        let recordingID = try field(bytes, offset: 88, length: 80)
        let startDateRaw = try field(bytes, offset: 168, length: 8)
        let startTimeRaw = try field(bytes, offset: 176, length: 8)
        let headerByteCount = Int(try field(bytes, offset: 184, length: 8)) ?? 0
        let recordCountField = Int(try field(bytes, offset: 236, length: 8)) ?? -1
        let recordDuration = Double(try field(bytes, offset: 244, length: 8)) ?? 1
        let signalCount = Int(try field(bytes, offset: 252, length: 4)) ?? 0
        guard headerByteCount >= 256, signalCount > 0, recordDuration > 0 else {
            throw EDFError.malformedHeader("invalid fixed header")
        }

        var cursor = 256
        let labels = try readStringArray(bytes, cursor: &cursor, count: signalCount, width: 16)
        _ = try readStringArray(bytes, cursor: &cursor, count: signalCount, width: 80)
        let physicalDimensions = try readStringArray(bytes, cursor: &cursor, count: signalCount, width: 8)
        let physicalMin = try readDoubleArray(bytes, cursor: &cursor, count: signalCount, width: 8)
        let physicalMax = try readDoubleArray(bytes, cursor: &cursor, count: signalCount, width: 8)
        let digitalMin = try readDoubleArray(bytes, cursor: &cursor, count: signalCount, width: 8)
        let digitalMax = try readDoubleArray(bytes, cursor: &cursor, count: signalCount, width: 8)
        _ = try readStringArray(bytes, cursor: &cursor, count: signalCount, width: 80)
        let samplesPerRecord = try readIntArray(bytes, cursor: &cursor, count: signalCount, width: 8)
        _ = try readStringArray(bytes, cursor: &cursor, count: signalCount, width: 32)

        let recordByteCount = samplesPerRecord.reduce(0, +) * 2
        let actualRecordCount = recordCountField >= 0
            ? recordCountField
            : max((bytes.count - headerByteCount) / max(recordByteCount, 1), 0)

        var channelData = samplesPerRecord.map { count in [Float](repeating: 0, count: count * actualRecordCount) }
        var offset = headerByteCount
        for record in 0..<actualRecordCount {
            for signalIndex in 0..<signalCount {
                let count = samplesPerRecord[signalIndex]
                let scale = (physicalMax[signalIndex] - physicalMin[signalIndex])
                    / max(digitalMax[signalIndex] - digitalMin[signalIndex], 1)
                for localSample in 0..<count {
                    guard offset + 2 <= bytes.count else { throw EDFError.unexpectedEndOfFile }
                    let raw = Int16(bitPattern: UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
                    offset += 2
                    let physical = (Double(raw) - digitalMin[signalIndex]) * scale + physicalMin[signalIndex]
                    channelData[signalIndex][record * count + localSample] = Float(physical)
                }
            }
        }

        let samplingRates = samplesPerRecord.map { Double($0) / recordDuration }
        let channels = (0..<signalCount).map { index in
            EDFChannel(
                label: labels[index],
                physicalDimension: physicalDimensions[index],
                samplingRate: samplingRates[index],
                data: channelData[index]
            )
        }

        return EDFRecording(
            patientID: patientID,
            recordingID: recordingID,
            startDate: parseEDFDate(dateString: startDateRaw, timeString: startTimeRaw),
            recordDurationSeconds: recordDuration,
            channels: channels
        )
    }

    private static func field(_ data: Data, offset: Int, length: Int) throws -> String {
        guard offset >= 0, offset + length <= data.count else {
            throw EDFError.malformedHeader("unexpected end of header")
        }
        return String(data: data[offset..<offset + length], encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func readStringArray(_ data: Data, cursor: inout Int, count: Int, width: Int) throws -> [String] {
        try (0..<count).map { _ in
            let value = try field(data, offset: cursor, length: width)
            cursor += width
            return value
        }
    }

    private static func readDoubleArray(_ data: Data, cursor: inout Int, count: Int, width: Int) throws -> [Double] {
        try readStringArray(data, cursor: &cursor, count: count, width: width).map { Double($0) ?? 0 }
    }

    private static func readIntArray(_ data: Data, cursor: inout Int, count: Int, width: Int) throws -> [Int] {
        try readStringArray(data, cursor: &cursor, count: count, width: width).map { Int($0) ?? 0 }
    }

    private static func parseEDFDate(dateString: String, timeString: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd.MM.yy HH.mm.ss"
        return formatter.date(from: "\(dateString) \(timeString)")
    }
}
