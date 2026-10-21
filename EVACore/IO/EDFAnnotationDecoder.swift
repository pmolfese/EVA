//
//  EDFAnnotationDecoder.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
// Shared EDF+/BDF+ time-stamped annotation lists, including record clocks.
// Extracted from SignalImportReader's EDF+ support, originally implemented with
// reference to MNE-Python (BSD-3-Clause). See THIRD_PARTY_NOTICES.md.

import Foundation

nonisolated enum EDFAnnotationDecoder {
    struct TAL {
        let onsetSeconds: Double
        let durationSeconds: Double?
        let texts: [String]
    }

    static func decode(_ bytes: [UInt8], includingTimekeeping: Bool = false) throws -> [TAL] {
        guard bytes.last == 0 else {
            throw EDFAnnotationError.invalid("annotation record is not NUL-terminated")
        }
        var output: [TAL] = []
        var start = 0
        for end in 0...bytes.count where end == bytes.count || bytes[end] == 0 {
            guard end > start else {
                start = end + 1
                continue
            }
            let chunk = Array(bytes[start..<end])
            start = end + 1
            guard let firstSeparator = chunk.firstIndex(of: 0x14), chunk.last == 0x14 else {
                throw EDFAnnotationError.invalid("annotation TAL is missing its text separator")
            }
            let timing = Array(chunk[..<firstSeparator])
            let timingParts = split(timing, separator: 0x15)
            guard let onsetText = ascii(timingParts.first ?? []),
                  (onsetText.hasPrefix("+") || onsetText.hasPrefix("-")),
                  let onset = Double(onsetText), onset.isFinite else {
                throw EDFAnnotationError.invalid("annotation TAL has an invalid onset")
            }
            var duration: Double?
            if timingParts.count > 1 {
                guard timingParts.count == 2,
                      let durationText = ascii(timingParts[1]),
                      let parsed = Double(durationText), parsed.isFinite, parsed >= 0 else {
                    throw EDFAnnotationError.invalid("annotation TAL has an invalid duration")
                }
                duration = parsed > 0 ? parsed : nil
            }
            let textBytes = Array(chunk[chunk.index(after: firstSeparator)...])
            let texts = try split(textBytes, separator: 0x14).compactMap { field -> String? in
                guard !field.isEmpty else { return nil }
                guard let value = String(bytes: field, encoding: .utf8) else {
                    throw EDFAnnotationError.invalid("annotation text is not valid UTF-8")
                }
                return value
            }
            // Empty-text TALs are EDF+ record-timekeeping annotations.
            if includingTimekeeping || !texts.isEmpty { output.append(TAL(onsetSeconds: onset, durationSeconds: duration, texts: texts)) }
        }
        return output
    }

    private static func split(_ bytes: [UInt8], separator: UInt8) -> [[UInt8]] {
        var fields: [[UInt8]] = [[]]
        for byte in bytes {
            if byte == separator { fields.append([]) } else { fields[fields.count - 1].append(byte) }
        }
        return fields
    }

    private static func ascii(_ bytes: [UInt8]) -> String? {
        String(bytes: bytes, encoding: .ascii)
    }
}

nonisolated enum EDFAnnotationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}
