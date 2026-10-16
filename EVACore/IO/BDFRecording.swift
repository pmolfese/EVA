//
//  BDFRecording.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
// Native BDF/BDF+ parsing from the published specifications, without a Python
// runtime. Samples remain in each channel's physical unit; Status is an exact
// unsigned 24-bit word (all such integers are exactly representable in Float).
// https://www.biosemi.com/faq/file_format.htm
// https://www.biosemi.com/faq/trigger_signals.htm
// https://www.teuniz.net/edfbrowser/bdfplus%20format%20description.html

import Foundation

nonisolated enum BDFReadError: LocalizedError {
    case malformed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail), .unsupported(let detail): return detail
        }
    }
}

nonisolated struct BDFRecording: Sendable {
    struct Channel: Sendable {
        let label: String
        let unit: String
        let transducer: String
        let prefiltering: String
        let samplingRate: Double
        let isStatus: Bool
        var samples: [Float]
    }

    let channels: [Channel]
    let events: [MFFEvent]
    let startTime: Date?
    let duration: Double
    let isPlus: Bool

    /// Both +C and +D are accepted when their actual record clocks are
    /// contiguous. A real gap is refused: EVA's continuous processing model
    /// cannot yet filter around missing time without changing the data.
    static func read(
        from url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> BDFRecording {
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count >= 256,
              Array(bytes.prefix(8)) == [0xff, 0x42, 0x49, 0x4f, 0x53, 0x45, 0x4d, 0x49] else {
            throw BDFReadError.malformed("Missing BioSemi BDF signature or truncated fixed header.")
        }
        func text(_ offset: Int, _ length: Int) throws -> String {
            guard offset >= 0, length >= 0, offset <= bytes.count - length else {
                throw BDFReadError.malformed("Unexpected end of BDF header.")
            }
            // Latin-1 tolerates the micro sign found in real-world unit fields.
            return String(data: bytes[offset..<(offset + length)], encoding: .isoLatin1)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard let headerSize = Int(try text(184, 8)),
              let recordsField = Int(try text(236, 8)), recordsField >= -1,
              let recordDuration = Double(try text(244, 8)), recordDuration.isFinite, recordDuration > 0,
              let channelCount = Int(try text(252, 4)), channelCount > 0,
              headerSize >= 256 + channelCount * 256, headerSize <= bytes.count else {
            throw BDFReadError.malformed("Invalid BDF header size, channel count, record count, or record duration.")
        }
        let reserved = try text(192, 44)
        let isPlus = reserved.hasPrefix("BDF+C") || reserved.hasPrefix("BDF+D")
        var cursor = 256
        func fields(_ width: Int) throws -> [String] {
            try (0..<channelCount).map { _ in
                defer { cursor += width }
                return try text(cursor, width)
            }
        }
        func numbers(_ width: Int) throws -> [Double] {
            try fields(width).map {
                guard let value = Double($0), value.isFinite else {
                    throw BDFReadError.malformed("Invalid numeric channel field in BDF header.")
                }
                return value
            }
        }
        let labels = try fields(16)
        let transducers = try fields(80)
        let units = try fields(8)
        let physicalMin = try numbers(8)
        let physicalMax = try numbers(8)
        let digitalMin = try numbers(8)
        let digitalMax = try numbers(8)
        let prefilters = try fields(80)
        let counts = try fields(8).map { value -> Int in
            guard let count = Int(value), count > 0 else {
                throw BDFReadError.malformed("BDF samples per record must be positive integers.")
            }
            return count
        }
        _ = try fields(32)
        let annotations = Set(labels.indices.filter { labels[$0].lowercased() == "bdf annotations" })
        guard !isPlus || !annotations.isEmpty else {
            throw BDFReadError.malformed("BDF+ is missing its BDF Annotations channel.")
        }
        // Do not guess that an arbitrary final EEG channel is Status: some
        // third-party BDF writers omit Status entirely. ActiView labels it.
        let status = Set(labels.indices.filter {
            ["status", "trigger", "triggers"].contains(labels[$0].lowercased())
        })
        let ordinary = labels.indices.filter { !annotations.contains($0) }
        guard ordinary.contains(where: { !status.contains($0) }) else {
            throw BDFReadError.unsupported("The BDF contains no analog channels.")
        }
        // Bound arithmetic by the actual payload before any sample allocation.
        let payloadSize = bytes.count - headerSize
        var recordBytes = 0
        for count in counts {
            guard count <= payloadSize / 3, recordBytes <= payloadSize - count * 3 else {
                throw BDFReadError.malformed("BDF data payload is shorter than one declared record.")
            }
            recordBytes += count * 3
        }
        guard recordBytes > 0, payloadSize % recordBytes == 0 else {
            throw BDFReadError.malformed("BDF data payload ends with a partial record.")
        }
        let records = payloadSize / recordBytes
        guard records > 0, recordsField == -1 || recordsField == records else {
            throw BDFReadError.malformed("BDF record count does not match its data payload.")
        }
        let duration = Double(records) * recordDuration
        guard duration.isFinite else { throw BDFReadError.malformed("Invalid BDF recording duration.") }
        var channels = [Channel]()
        var outIndices = [Int: Int]()
        var slopes = [Double](repeating: 0, count: channelCount)
        for index in ordinary {
            let isStatus = status.contains(index)
            if !isStatus {
                guard digitalMin[index] >= -8_388_608, digitalMax[index] <= 8_388_607,
                      digitalMin[index].rounded() == digitalMin[index],
                      digitalMax[index].rounded() == digitalMax[index],
                      digitalMax[index] > digitalMin[index], physicalMax[index] != physicalMin[index] else {
                    throw BDFReadError.malformed("Invalid BDF calibration for channel \(index + 1) (\(labels[index])).")
                }
                slopes[index] = (physicalMax[index] - physicalMin[index]) / (digitalMax[index] - digitalMin[index])
                guard slopes[index].isFinite else {
                    throw BDFReadError.malformed("Non-finite BDF channel calibration.")
                }
            }
            let rate = Double(counts[index]) / recordDuration
            guard rate.isFinite, rate > 0 else { throw BDFReadError.malformed("Invalid BDF sampling rate.") }
            outIndices[index] = channels.count
            channels.append(Channel(
                label: labels[index].isEmpty ? "Ch\(index + 1)" : labels[index],
                unit: units[index], transducer: transducers[index], prefiltering: prefilters[index],
                samplingRate: rate, isStatus: isStatus,
                samples: [Float](repeating: 0, count: records * counts[index])
            ))
        }
        var events = [MFFEvent]()
        var previousCodes = [Int: Int]()
        var pendingTriggers = [Int: (sample: Int, code: Int)]()
        var origin: Double?
        // Record clocks are relative to the header's whole-second start time.
        // Normalize sample zero to the first record and shift dates/events by
        // the same fractional offset.
        try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = headerSize
            for record in 0..<records {
                try Task.checkCancellation()
                progress?(Double(record) / Double(records))
                for index in labels.indices {
                    let count = counts[index]
                    let end = offset + count * 3
                    if annotations.contains(index) {
                        let tals = try EDFAnnotationDecoder.decode(Array(raw[offset..<end]), includingTimekeeping: true)
                        if index == annotations.min(), isPlus {
                            guard let clock = tals.first, clock.texts.isEmpty,
                                  clock.onsetSeconds >= 0 else {
                                throw BDFReadError.malformed("BDF+ record is missing its leading timekeeping annotation.")
                            }
                            if origin == nil {
                                guard clock.onsetSeconds < 1 else {
                                    throw BDFReadError.malformed("BDF+ first record must start within the header's first second.")
                                }
                                origin = clock.onsetSeconds
                            }
                            let expected = (origin ?? 0) + Double(record) * recordDuration
                            guard abs(clock.onsetSeconds - expected) <= max(1e-7, abs(expected) * 1e-12) else {
                                throw BDFReadError.unsupported(
                                    "This BDF+ has gaps or overlapping records. EVA cannot yet process discontinuous BDF+ without changing event timing."
                                )
                            }
                        }
                        for (talIndex, tal) in tals.enumerated() {
                            for (textIndex, label) in tal.texts.enumerated() {
                                events.append(MFFEvent(
                                    id: "bdf-tal-\(record)-\(index)-\(talIndex)-\(textIndex)", code: label, label: label,
                                    eventDescription: "BDF+ annotation", beginTimeSeconds: tal.onsetSeconds,
                                    rawBeginTime: String(tal.onsetSeconds), sourceFile: url.lastPathComponent,
                                    durationSeconds: tal.durationSeconds
                                ))
                            }
                        }
                    } else if let outIndex = outIndices[index] {
                        for sample in 0..<count {
                            if sample & 0xffff == 0 { try Task.checkCancellation() }
                            let pos = offset + sample * 3
                            let word = UInt32(raw[pos]) | UInt32(raw[pos + 1]) << 8 | UInt32(raw[pos + 2]) << 16
                            let absolute = record * count + sample
                            if status.contains(index) {
                                channels[outIndex].samples[absolute] = Float(word)
                                let code = Int(word & 0xffff)
                                if code != (previousCodes[index] ?? 0) {
                                    if let pending = pendingTriggers.removeValue(forKey: index) {
                                        events.append(triggerEvent(
                                            channel: index, sample: pending.sample, end: absolute,
                                            code: pending.code, rate: channels[outIndex].samplingRate, url: url
                                        ))
                                    }
                                    if code != 0 { pendingTriggers[index] = (absolute, code) }
                                    previousCodes[index] = code
                                }
                            } else {
                                let signed = Int32(bitPattern: word << 8) >> 8
                                let value = (Double(signed) - digitalMin[index]) * slopes[index] + physicalMin[index]
                                let stored = Float(value)
                                guard stored.isFinite else {
                                    throw BDFReadError.malformed("BDF calibration overflows physical sample values.")
                                }
                                channels[outIndex].samples[absolute] = stored
                            }
                        }
                    }
                    offset = end
                }
            }
        }
        let firstOffset = origin ?? 0
        // Annotation onsets use the file clock. Trigger onsets already use
        // sample zero, so normalize annotations before adding the final pulses.
        events = events.map { event in
            guard event.eventDescription == "BDF+ annotation" else { return event }
            return MFFEvent(id: event.id, code: event.code, label: event.label,
                     eventDescription: event.eventDescription,
                     beginTimeSeconds: event.beginTimeSeconds - firstOffset,
                     rawBeginTime: event.rawBeginTime, sourceFile: event.sourceFile,
                     durationSeconds: event.durationSeconds)
        }
        for (index, pending) in pendingTriggers {
            guard let outIndex = outIndices[index] else { continue }
            events.append(triggerEvent(channel: index, sample: pending.sample, end: channels[outIndex].samples.count,
                                       code: pending.code, rate: channels[outIndex].samplingRate, url: url))
        }
        events.sort {
            $0.beginTimeSeconds == $1.beginTimeSeconds ? $0.id < $1.id : $0.beginTimeSeconds < $1.beginTimeSeconds
        }
        let start = try parseStartTime(date: text(168, 8), time: text(176, 8), recording: text(88, 80))
        progress?(1)
        return BDFRecording(channels: channels, events: events,
                            startTime: start?.addingTimeInterval(firstOffset), duration: duration, isPlus: isPlus)
    }

    private static func triggerEvent(channel: Int, sample: Int, end: Int, code: Int, rate: Double, url: URL) -> MFFEvent {
        MFFEvent(id: "bdf-status-\(channel)-\(sample)", code: String(code), label: String(code),
                 eventDescription: "BDF Status: lower 16 bits (mask=0xffff), each nonzero code transition",
                 beginTimeSeconds: Double(sample) / rate, rawBeginTime: String(Double(sample) / rate),
                 sourceFile: url.lastPathComponent, durationSeconds: Double(end - sample) / rate)
    }

    private static func parseStartTime(date: String, time: String, recording: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        // BDF has a local wall-clock date without a timezone. Follow the user's
        // local timezone rather than inventing an acquisition timezone.
        calendar.timeZone = .current
        let clock = time.split(separator: ".").compactMap { Int($0) }
        let day = date.split(separator: ".")
        guard clock.count == 3, day.count == 3 else { return nil }
        let shortYear = Int(day[2])
        var year: Int? = shortYear.flatMap { (0...99).contains($0) ? ($0 >= 85 ? 1900 + $0 : 2000 + $0) : nil }
        var month = Int(day[1]), dayNumber = Int(day[0])
        let parts = recording.split(separator: " ")
        if parts.first == "Startdate", parts.count > 1, parts[1] != "X" {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "dd-MMM-yyyy"
            formatter.isLenient = false
            if let fullDate = formatter.date(from: String(parts[1])) {
                let components = calendar.dateComponents([.year, .month, .day], from: fullDate)
                year = components.year; month = components.month; dayNumber = components.day
            }
        }
        guard let year, let month, let dayNumber else { return nil }
        let components = DateComponents(year: year, month: month, day: dayNumber,
                                        hour: clock[0], minute: clock[1], second: clock[2])
        guard let result = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: result) == components else { return nil }
        return result
    }
}
