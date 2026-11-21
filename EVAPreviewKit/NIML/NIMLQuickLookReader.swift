import Foundation

nonisolated struct NIMLPreviewModel: Sendable {
    struct Element: Sendable {
        let name: String
        let depth: Int
        let attributes: [String: String]
        var rows = 0
        var types: [String] = []
        var sample: [[String]] = []
        var ranges: [ClosedRange<Double>?] = []
        var text = ""
    }

    let fileName: String
    let elements: [Element]
    var dataset: Element? { elements.first { $0.name == "AFNI_dataset" } }
    var data: Element? { elements.first { $0.name == "SPARSE_DATA" } }
    var columnLabels: [String] {
        guard let datasetIndex = elements.firstIndex(where: { $0.name == "AFNI_dataset" }) else { return [] }
        let depth = elements[datasetIndex].depth
        let children = elements.dropFirst(datasetIndex + 1).prefix { $0.depth > depth }
        let labels = children.first { $0.depth == depth + 1 && $0.attributes["atr_name"] == "COLMS_LABS" }?.text ?? ""
        return labels.components(separatedBy: ";")
    }
}

nonisolated enum NIMLReadError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): "Cannot preview NIML: \(message)" }
    }
}

/// Byte-oriented NIML reader following afni-io's niml/parse.rs and dset.rs.
/// Binary bodies start immediately after `>` and are row-interleaved. A bare
/// binary/base64 form is big-endian; only an `lsb` form is little-endian.
/// Keep bounded samples instead of retaining a potentially enormous matrix.
nonisolated enum NIMLQuickLookReader {
    static let maximumFileBytes = 128 * 1024 * 1024

    static func read(from url: URL) throws -> NIMLPreviewModel {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        return try read(data: data, fileName: url.lastPathComponent)
    }

    static func read(data: Data, fileName: String = "NIML") throws -> NIMLPreviewModel {
        guard data.count <= maximumFileBytes else { throw NIMLReadError.invalid("file exceeds the 128 MB preview limit.") }
        var parser = Parser(bytes: Array(data))
        try parser.elements(depth: 0, closing: nil)
        guard !parser.output.isEmpty else { throw NIMLReadError.invalid("no elements found.") }
        return NIMLPreviewModel(fileName: fileName, elements: parser.output)
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0
        var output: [NIMLPreviewModel.Element] = []

        func matches(_ string: String) -> Bool { bytes[position...].starts(with: string.utf8) }
        mutating func blanks() {
            while position < bytes.count && Self.isBlank(bytes[position]) { position += 1 }
        }
        static func isBlank(_ byte: UInt8) -> Bool { [9, 10, 11, 12, 13, 32].contains(byte) }
        mutating func expect(_ string: String) throws {
            guard matches(string) else { throw NIMLReadError.invalid("expected \(string) at byte \(position).") }
            position += string.utf8.count
        }
        func string(_ range: Range<Int>) throws -> String {
            guard let value = String(bytes: bytes[range], encoding: .utf8) else { throw NIMLReadError.invalid("invalid UTF-8 text.") }
            return value
        }
        mutating func through(_ delimiter: String) throws -> Range<Int> {
            let start = position
            while position < bytes.count && !matches(delimiter) { position += 1 }
            guard position < bytes.count else { throw NIMLReadError.invalid("missing \(delimiter).") }
            let end = position
            position += delimiter.utf8.count
            return start..<end
        }
        mutating func word() throws -> String {
            let start = position
            while position < bytes.count && !Self.isBlank(bytes[position]) && ![60, 62, 47, 61].contains(bytes[position]) { position += 1 }
            guard position > start else { throw NIMLReadError.invalid("missing name at byte \(position).") }
            return try string(start..<position)
        }
        mutating func value() throws -> String {
            guard position < bytes.count else { throw NIMLReadError.invalid("missing attribute value.") }
            if bytes[position] == 34 || bytes[position] == 39 {
                let quote = bytes[position]
                position += 1
                let start = position
                while position < bytes.count && bytes[position] != quote { position += 1 }
                guard position < bytes.count else { throw NIMLReadError.invalid("unterminated quoted value.") }
                let result = try string(start..<position)
                position += 1
                return decodeEntities(result)
            }
            return decodeEntities(try word())
        }
        mutating func elements(depth: Int, closing: String?) throws {
            guard depth <= 32 else { throw NIMLReadError.invalid("nesting exceeds the preview limit.") }
            while true {
                blanks()
                if let closing, matches("</") {
                    try expect("</\(closing)")
                    blanks()
                    try expect(">")
                    return
                }
                if position == bytes.count {
                    guard closing == nil else { throw NIMLReadError.invalid("unterminated group \(closing!).") }
                    return
                }
                if matches("<?") { _ = try through(">"); continue }
                if matches("<!--") { _ = try through("-->"); continue }
                guard output.count < 4096 else { throw NIMLReadError.invalid("too many elements for a preview.") }
                try expect("<")
                let name = try word()
                var attrs: [String: String] = [:]
                blanks()
                while !matches(">") && !matches("/>") {
                    let key = try word()
                    blanks()
                    if matches("=") {
                        position += 1
                        blanks()
                        attrs[key] = try value()
                    } else { attrs[key] = "" }
                    blanks()
                }
                let index = output.count
                output.append(.init(name: name, depth: depth, attributes: attrs))
                if matches("/>") { position += 2; continue }
                try expect(">")
                let form = (attrs["ni_form"] ?? "").lowercased()
                if form == "ni_group" {
                    try elements(depth: depth + 1, closing: name)
                    continue
                }
                let types = try expandTypes(attrs["ni_type"] ?? "")
                let rows: Int?
                if let dimen = attrs["ni_dimen"] {
                    guard let count = Int(dimen), (0...100_000_000).contains(count) else { throw NIMLReadError.invalid("invalid ni_dimen.") }
                    rows = count
                } else { rows = nil }
                let body: [UInt8]
                if form.contains("binary") {
                    let count = try binarySize(types: types, rows: rows)
                    guard count <= bytes.count - position else { throw NIMLReadError.invalid("truncated binary body.") }
                    body = Array(bytes[position..<position + count])
                    position += count
                    blanks()
                    try expect("</\(name)>")
                } else {
                    let range = try through("</\(name)>")
                    if form.contains("base64") {
                        let encoded = bytes[range].filter { !Self.isBlank($0) }
                        guard let decoded = Data(base64Encoded: Data(encoded)) else { throw NIMLReadError.invalid("invalid base64 body.") }
                        body = Array(decoded)
                    } else { body = Array(bytes[range]) }
                }
                var element = output[index]
                element.types = types
                if form.contains("binary") || form.contains("base64") {
                    let count = try binarySize(types: types, rows: rows)
                    guard body.count == count else { throw NIMLReadError.invalid("binary body size disagrees with ni_dimen.") }
                    element.rows = rows ?? 0
                    element.ranges = Array(repeating: nil, count: types.count)
                    var offset = 0
                    for row in 0..<element.rows {
                        var sample: [String] = []
                        for (column, type) in types.enumerated() {
                            let width = width(type)!
                            var bits: UInt64 = 0
                            for byte in 0..<width {
                                let shift = form.contains("lsb") ? byte * 8 : (width - byte - 1) * 8
                                bits |= UInt64(body[offset + byte]) << shift
                            }
                            offset += width
                            let value: Double
                            switch type {
                            case "byte": value = Double(bits)
                            case "short": value = Double(Int16(bitPattern: UInt16(bits)))
                            case "int": value = Double(Int32(bitPattern: UInt32(bits)))
                            case "float": value = Double(Float(bitPattern: UInt32(bits)))
                            default: value = Double(bitPattern: bits)
                            }
                            updateRange(value, column: column, element: &element)
                            if row < 20 && column < 16 { sample.append(String(value)) }
                        }
                        if row < 20 { element.sample.append(sample) }
                    }
                } else {
                    guard let text = String(bytes: body, encoding: .utf8) else { throw NIMLReadError.invalid("invalid text body.") }
                    try readText(text, types: types, rows: rows, element: &element)
                }
                output[index] = element
            }
        }
    }

    private static func width(_ type: String) -> Int? {
        switch type { case "byte": 1; case "short": 2; case "int", "float": 4; case "double": 8; default: nil }
    }
    private static func binarySize(types: [String], rows: Int?) throws -> Int {
        guard let rows, !types.isEmpty, types.allSatisfy({ width($0) != nil }) else {
            throw NIMLReadError.invalid("binary data requires ni_dimen and fixed-width numeric columns; string and custom record types are unsupported.")
        }
        let (size, overflow) = types.reduce(0) { $0 + width($1)! }.multipliedReportingOverflow(by: rows)
        guard !overflow, size <= maximumFileBytes else { throw NIMLReadError.invalid("binary payload exceeds the preview limit.") }
        return size
    }
    private static func expandTypes(_ text: String) throws -> [String] {
        if text.isEmpty { return [] }
        var result: [String] = []
        let aliases = ["uint8": "byte", "int16": "short", "int32": "int", "float32": "float", "float64": "double"]
        for entry in text.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = entry.split(separator: "*", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw NIMLReadError.invalid("invalid ni_type.") }
            let count = parts.count == 2 ? Int(parts[0].trimmingCharacters(in: .whitespaces)) : 1
            let raw = parts.last!.trimmingCharacters(in: .whitespaces).lowercased()
            guard let count, count > 0, count <= 4096 - result.count, !raw.isEmpty else { throw NIMLReadError.invalid("invalid or excessive column count.") }
            result.append(contentsOf: repeatElement(aliases[raw] ?? raw, count: count))
        }
        return result
    }
    private static func updateRange(_ value: Double, column: Int, element: inout NIMLPreviewModel.Element) {
        guard value.isFinite else { return }
        if let old = element.ranges[column] { element.ranges[column] = min(old.lowerBound, value)...max(old.upperBound, value) }
        else { element.ranges[column] = value...value }
    }
    private static func readText(_ text: String, types: [String], rows: Int?, element: inout NIMLPreviewModel.Element) throws {
        if types.isEmpty || types == ["string"] || types == ["cstring"] || types.contains(where: { width($0) == nil && $0 != "string" && $0 != "cstring" }) {
            // Preserve generic text and ASCII custom records for inspection.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if types == ["string"] || types == ["cstring"] {
                // AFNI may split long attributes into multiple quoted strings.
                // Reassemble these before interpreting semicolon-separated labels.
                var cursor = trimmed.startIndex
                var pieces = ""
                if trimmed.first == "\"" || trimmed.first == "'" {
                    while cursor < trimmed.endIndex {
                        while cursor < trimmed.endIndex && trimmed[cursor].isWhitespace { trimmed.formIndex(after: &cursor) }
                        if cursor == trimmed.endIndex { break }
                        let quote = trimmed[cursor]
                        guard quote == "\"" || quote == "'" else { throw NIMLReadError.invalid("expected a quoted string.") }
                        trimmed.formIndex(after: &cursor)
                        let start = cursor
                        while cursor < trimmed.endIndex && trimmed[cursor] != quote { trimmed.formIndex(after: &cursor) }
                        guard cursor < trimmed.endIndex else { throw NIMLReadError.invalid("unterminated string body.") }
                        if pieces.count < 8192 { pieces += decodeEntities(String(trimmed[start..<cursor].prefix(8192 - pieces.count))) }
                        trimmed.formIndex(after: &cursor)
                    }
                    element.text = pieces
                } else { element.text = decodeEntities(String(trimmed.prefix(8192))) }
            } else { element.text = decodeEntities(String(trimmed.prefix(8192))) }
            element.rows = rows ?? 0
            return
        }
        var cursor = text.startIndex
        var cells = 0
        var sample: [String] = []
        element.ranges = Array(repeating: nil, count: types.count)
        while cursor < text.endIndex {
            while cursor < text.endIndex && (text[cursor].isWhitespace || text[cursor] == ";") { text.formIndex(after: &cursor) }
            if cursor == text.endIndex { break }
            let token: String
            if text[cursor] == "\"" || text[cursor] == "'" {
                let quote = text[cursor]
                text.formIndex(after: &cursor)
                let start = cursor
                while cursor < text.endIndex && text[cursor] != quote { text.formIndex(after: &cursor) }
                guard cursor < text.endIndex else { throw NIMLReadError.invalid("unterminated string cell.") }
                token = decodeEntities(String(text[start..<cursor]))
                text.formIndex(after: &cursor)
            } else {
                let start = cursor
                while cursor < text.endIndex && !text[cursor].isWhitespace && text[cursor] != ";" { text.formIndex(after: &cursor) }
                token = decodeEntities(String(text[start..<cursor]))
            }
            let column = cells % types.count
            if width(types[column]) != nil {
                guard let number = Double(token) else { throw NIMLReadError.invalid("invalid numeric cell \(token.prefix(40)).") }
                updateRange(number, column: column, element: &element)
            }
            if cells / types.count < 20 && column < 16 { sample.append(String(token.prefix(256))) }
            cells += 1
            if cells % types.count == 0 && cells / types.count <= 20 { element.sample.append(sample); sample = [] }
        }
        guard cells % types.count == 0, rows == nil || rows == cells / types.count else { throw NIMLReadError.invalid("cell count disagrees with ni_type/ni_dimen.") }
        element.rows = cells / types.count
    }

    /// Decode once, so `&amp;lt;` remains `&lt;`, as in AFNI.
    private static func decodeEntities(_ text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        let named: [String: String] = ["lt": "<", "gt": ">", "amp": "&", "quot": "\"", "apos": "'"]
        while cursor < text.endIndex {
            if text[cursor] == "&", let end = text[cursor...].prefix(16).firstIndex(of: ";") {
                let entity = String(text[text.index(after: cursor)..<end])
                var replacement = named[entity]
                if entity.hasPrefix("#") {
                    let hex = entity.hasPrefix("#x") || entity.hasPrefix("#X")
                    if let code = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(code) { replacement = String(scalar) }
                }
                if let replacement { result += replacement; cursor = text.index(after: end); continue }
            }
            result.append(text[cursor]); text.formIndex(after: &cursor)
        }
        return result
    }
}
