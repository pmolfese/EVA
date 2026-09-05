//
//  DICOMQuickLookReader.swift
//  EVAPreviewKit
//
//  A deliberately self-contained DICOM Part 10 reader for Quick Look. It reads
//  common uncompressed monochrome/RGB images and lets ImageIO decode encapsulated
//  JPEG-family transfer syntaxes. It retains only the first frame.
//

import Foundation

nonisolated enum DICOMQuickLookReader {
    static func read(from url: URL) throws -> DICOMPreviewModel {
        let name = url.lastPathComponent.lowercased()
        guard name.hasSuffix(".dcm") || name.hasSuffix(".ima") else {
            throw DICOMReadError.unsupportedFile(url)
        }
        let data: Data
        do { data = try Data(contentsOf: url, options: [.mappedIfSafe]) }
        catch { throw DICOMReadError.cannotOpen(url) }

        let parsed = try data.withUnsafeBytes { rawBytes -> ParsedDICOM in
            var parser = DICOMParser(bytes: rawBytes)
            return try parser.parse()
        }
        let image = try makeImage(from: parsed)
        let byteSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value
            ?? Int64(data.count)
        return DICOMPreviewModel(
            url: url, transferSyntax: parsed.transferSyntax, image: image,
            modality: parsed.modality, patientName: parsed.patientName, patientID: parsed.patientID,
            studyDescription: parsed.studyDescription, seriesDescription: parsed.seriesDescription,
            manufacturer: parsed.manufacturer, sopClassUID: parsed.sopClassUID,
            photometricInterpretation: parsed.photometricInterpretation ?? "MONOCHROME2",
            samplesPerPixel: parsed.samplesPerPixel ?? 1,
            bitsAllocated: parsed.bitsAllocated ?? 0, bitsStored: parsed.bitsStored ?? parsed.bitsAllocated ?? 0,
            frameCount: max(parsed.frameCount ?? 1, 1), pixelSpacing: parsed.pixelSpacing,
            sliceThickness: parsed.sliceThickness, windowCenter: parsed.windowCenter,
            windowWidth: parsed.windowWidth, byteSize: byteSize
        )
    }

    private static func makeImage(from parsed: ParsedDICOM) throws -> DICOMPixelImage {
        guard let pixelData = parsed.pixelData else { throw DICOMReadError.missingPixelData }
        let width = parsed.columns ?? 0, height = parsed.rows ?? 0
        guard width > 0, height > 0 else { throw DICOMReadError.malformed("missing Rows or Columns") }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow, pixelCount <= 100_000_000 else {
            throw DICOMReadError.unsupportedPixels("image dimensions are too large")
        }

        if parsed.transferSyntax.isCompressed {
            guard !pixelData.isEmpty else { throw DICOMReadError.missingPixelData }
            return .encoded(width: width, height: height, data: pixelData)
        }
        if case .unsupported(let uid) = parsed.transferSyntax {
            throw DICOMReadError.unsupportedTransferSyntax(uid)
        }

        let samples = parsed.samplesPerPixel ?? 1
        let photometric = (parsed.photometricInterpretation ?? "MONOCHROME2").uppercased()
        if samples == 1, photometric.hasPrefix("MONOCHROME") {
            return try grayscaleImage(from: parsed, pixelData: pixelData, width: width, height: height)
        }
        if samples == 3, parsed.bitsAllocated == 8 {
            let bytes = try colorBytes(
                pixelData, width: width, height: height,
                photometric: photometric, planarConfiguration: parsed.planarConfiguration ?? 0
            )
            return .rgb(width: width, height: height, bytes: bytes)
        }
        throw DICOMReadError.unsupportedPixels(
            "\(photometric), \(samples) sample(s), \(parsed.bitsAllocated ?? 0) bits allocated"
        )
    }

    private static func grayscaleImage(
        from parsed: ParsedDICOM, pixelData: Data, width: Int, height: Int
    ) throws -> DICOMPixelImage {
        let bitsAllocated = parsed.bitsAllocated ?? 0
        guard bitsAllocated == 8 || bitsAllocated == 16 || bitsAllocated == 32 else {
            throw DICOMReadError.unsupportedPixels("\(bitsAllocated)-bit monochrome samples")
        }
        let bytesPerSample = bitsAllocated / 8
        let pixelCount = width * height
        guard pixelData.count >= pixelCount * bytesPerSample else {
            throw DICOMReadError.malformed("truncated pixel data")
        }
        let bitsStored = min(max(parsed.bitsStored ?? bitsAllocated, 1), bitsAllocated)
        let highBit = min(max(parsed.highBit ?? (bitsStored - 1), bitsStored - 1), bitsAllocated - 1)
        let lowBit = highBit - bitsStored + 1
        let isSigned = parsed.pixelRepresentation == 1
        let slope = parsed.rescaleSlope.flatMap { $0 == 0 ? nil : $0 } ?? 1
        let intercept = parsed.rescaleIntercept ?? 0
        var values = [Double](repeating: 0, count: pixelCount)

        pixelData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for index in 0..<pixelCount {
                let offset = index * bytesPerSample
                let raw: UInt32
                switch bytesPerSample {
                case 1: raw = UInt32(bytes[offset])
                case 2:
                    let a = UInt32(bytes[offset]), b = UInt32(bytes[offset + 1])
                    raw = parsed.byteOrder == .littleEndian ? a | (b << 8) : (a << 8) | b
                default:
                    let a = UInt32(bytes[offset]), b = UInt32(bytes[offset + 1])
                    let c = UInt32(bytes[offset + 2]), d = UInt32(bytes[offset + 3])
                    raw = parsed.byteOrder == .littleEndian
                        ? a | (b << 8) | (c << 16) | (d << 24)
                        : (a << 24) | (b << 16) | (c << 8) | d
                }
                let shifted = raw >> UInt32(lowBit)
                let mask: UInt32 = bitsStored == 32 ? .max : (UInt32(1) << UInt32(bitsStored)) - 1
                let stored = shifted & mask
                let numeric: Double
                if isSigned, bitsStored == 32 {
                    numeric = Double(Int32(bitPattern: stored))
                } else if isSigned, stored & (UInt32(1) << UInt32(bitsStored - 1)) != 0 {
                    numeric = Double(Int64(stored) - (Int64(1) << Int64(bitsStored)))
                } else {
                    numeric = Double(stored)
                }
                values[index] = numeric * slope + intercept
            }
        }

        let window: NIfTIIntensityWindow
        if let center = parsed.windowCenter, let width = parsed.windowWidth,
           center.isFinite, width.isFinite, width > 0 {
            window = NIfTIIntensityWindow(minimum: center - width / 2, maximum: center + width / 2)
        } else {
            let slice = NIfTISlice(
                plane: .axial, width: width, height: height,
                horizontalSpacing: 1, verticalSpacing: 1, values: values,
                leftLabel: "", rightLabel: "", topLabel: "", bottomLabel: ""
            )
            window = NIfTIIntensityWindow.make(slices: [slice])
        }
        return .grayscale(
            width: width, height: height, values: values, window: window,
            inverted: (parsed.photometricInterpretation ?? "").uppercased() == "MONOCHROME1"
        )
    }

    private static func colorBytes(
        _ pixelData: Data, width: Int, height: Int, photometric: String, planarConfiguration: Int
    ) throws -> Data {
        let count = width * height
        if photometric == "YBR_FULL_422" {
            guard pixelData.count >= count * 2 else { throw DICOMReadError.malformed("truncated YBR pixel data") }
            var rgb = Data(count: count * 3)
            rgb.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                pixelData.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                    var source = 0, destination = 0
                    while destination < count, source + 3 < input.count {
                        let y1 = Double(input[source]), y2 = Double(input[source + 1])
                        let cb = Double(input[source + 2]), cr = Double(input[source + 3])
                        writeYBR(y: y1, cb: cb, cr: cr, into: output, pixel: destination)
                        if destination + 1 < count { writeYBR(y: y2, cb: cb, cr: cr, into: output, pixel: destination + 1) }
                        source += 4; destination += 2
                    }
                }
            }
            return rgb
        }
        guard pixelData.count >= count * 3 else { throw DICOMReadError.malformed("truncated RGB pixel data") }
        if photometric == "RGB", planarConfiguration == 0 { return Data(pixelData.prefix(count * 3)) }
        var rgb = Data(count: count * 3)
        rgb.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            pixelData.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                for pixel in 0..<count {
                    let components: (UInt8, UInt8, UInt8)
                    if planarConfiguration == 1 {
                        components = (input[pixel], input[count + pixel], input[count * 2 + pixel])
                    } else {
                        components = (input[pixel * 3], input[pixel * 3 + 1], input[pixel * 3 + 2])
                    }
                    if photometric == "YBR_FULL" {
                        writeYBR(
                            y: Double(components.0), cb: Double(components.1), cr: Double(components.2),
                            into: output, pixel: pixel
                        )
                    } else {
                        output[pixel * 3] = components.0
                        output[pixel * 3 + 1] = components.1
                        output[pixel * 3 + 2] = components.2
                    }
                }
            }
        }
        return rgb
    }

    private static func writeYBR(
        y: Double, cb: Double, cr: Double, into output: UnsafeMutableRawBufferPointer, pixel: Int
    ) {
        func byte(_ value: Double) -> UInt8 { UInt8(min(max(value.rounded(), 0), 255)) }
        output[pixel * 3] = byte(y + 1.402 * (cr - 128))
        output[pixel * 3 + 1] = byte(y - 0.344_136 * (cb - 128) - 0.714_136 * (cr - 128))
        output[pixel * 3 + 2] = byte(y + 1.772 * (cb - 128))
    }
}

private nonisolated enum DICOMByteOrder { case littleEndian, bigEndian }

private nonisolated struct DICOMTag: Hashable {
    let group: UInt16
    let element: UInt16
}

private nonisolated struct ParsedDICOM {
    var transferSyntax = DICOMTransferSyntax.implicitVRLittleEndian
    var byteOrder = DICOMByteOrder.littleEndian
    var modality: String?
    var patientName: String?
    var patientID: String?
    var studyDescription: String?
    var seriesDescription: String?
    var manufacturer: String?
    var sopClassUID: String?
    var rows: Int?
    var columns: Int?
    var samplesPerPixel: Int?
    var photometricInterpretation: String?
    var planarConfiguration: Int?
    var frameCount: Int?
    var bitsAllocated: Int?
    var bitsStored: Int?
    var highBit: Int?
    var pixelRepresentation: Int?
    var pixelSpacing: [Double]?
    var sliceThickness: Double?
    var windowCenter: Double?
    var windowWidth: Double?
    var rescaleIntercept: Double?
    var rescaleSlope: Double?
    var pixelData: Data?
}

private nonisolated struct DICOMParser {
    private static let undefinedLength = UInt32.max
    let bytes: UnsafeRawBufferPointer
    var cursor = 0

    mutating func parse() throws -> ParsedDICOM {
        guard bytes.count >= 8 else { throw DICOMReadError.malformed("file is too short") }
        if bytes.count >= 132,
           bytes[128] == 0x44, bytes[129] == 0x49, bytes[130] == 0x43, bytes[131] == 0x4d {
            cursor = 132
        }
        var parsed = ParsedDICOM()
        var transferSyntaxUID: String?

        // File Meta Information is always Explicit VR Little Endian.
        while cursor + 8 <= bytes.count {
            let start = cursor
            let tag = try readTag(order: .littleEndian)
            cursor = start
            guard tag.group == 0x0002 else { break }
            let header = try readHeader(explicitVR: true, order: .littleEndian)
            guard header.length != Self.undefinedLength else {
                throw DICOMReadError.malformed("undefined File Meta Information length")
            }
            let value = try valueData(length: header.length)
            if header.tag == DICOMTag(group: 0x0002, element: 0x0010) { transferSyntaxUID = string(value) }
        }

        parsed.transferSyntax = DICOMTransferSyntax(uid: transferSyntaxUID)
        if transferSyntaxUID == nil, isLikelyExplicitVR(at: cursor) {
            // Older scanner exports (especially .ima files) sometimes omit the
            // Part 10 preamble and meta header while still encoding Explicit VR.
            parsed.transferSyntax = .explicitVRLittleEndian
        }
        let explicitVR: Bool
        switch parsed.transferSyntax {
        case .implicitVRLittleEndian:
            explicitVR = false; parsed.byteOrder = .littleEndian
        case .explicitVRLittleEndian, .encapsulated:
            explicitVR = true; parsed.byteOrder = .littleEndian
        case .explicitVRBigEndian:
            explicitVR = true; parsed.byteOrder = .bigEndian
        case .unsupported(let uid):
            throw DICOMReadError.unsupportedTransferSyntax(uid)
        }

        while cursor + 8 <= bytes.count {
            let header = try readHeader(explicitVR: explicitVR, order: parsed.byteOrder)
            if header.tag == DICOMTag(group: 0x7fe0, element: 0x0010) {
                parsed.pixelData = header.length == Self.undefinedLength
                    ? try readEncapsulatedPixelData()
                    : try valueData(length: header.length)
                break
            }
            if header.length == Self.undefinedLength {
                try skipUndefinedValue(explicitVR: explicitVR, order: parsed.byteOrder)
                continue
            }
            guard isPreviewMetadata(header.tag) else {
                try skipValue(length: header.length)
                continue
            }
            let value = try valueData(length: header.length)
            switch header.tag {
            case DICOMTag(group: 0x0008, element: 0x0016): parsed.sopClassUID = string(value)
            case DICOMTag(group: 0x0008, element: 0x0060): parsed.modality = string(value)
            case DICOMTag(group: 0x0008, element: 0x0070): parsed.manufacturer = string(value)
            case DICOMTag(group: 0x0008, element: 0x1030): parsed.studyDescription = string(value)
            case DICOMTag(group: 0x0008, element: 0x103e): parsed.seriesDescription = string(value)
            case DICOMTag(group: 0x0010, element: 0x0010):
                parsed.patientName = string(value)?.replacingOccurrences(of: "^", with: " ")
            case DICOMTag(group: 0x0010, element: 0x0020): parsed.patientID = string(value)
            case DICOMTag(group: 0x0018, element: 0x0050): parsed.sliceThickness = decimal(value)
            case DICOMTag(group: 0x0028, element: 0x0002): parsed.samplesPerPixel = unsignedShort(value, parsed.byteOrder)
            case DICOMTag(group: 0x0028, element: 0x0004): parsed.photometricInterpretation = string(value)
            case DICOMTag(group: 0x0028, element: 0x0006): parsed.planarConfiguration = unsignedShort(value, parsed.byteOrder)
            case DICOMTag(group: 0x0028, element: 0x0008): parsed.frameCount = integerString(value)
            case DICOMTag(group: 0x0028, element: 0x0010): parsed.rows = unsignedShort(value, parsed.byteOrder)
            case DICOMTag(group: 0x0028, element: 0x0011): parsed.columns = unsignedShort(value, parsed.byteOrder)
            case DICOMTag(group: 0x0028, element: 0x0030): parsed.pixelSpacing = decimalList(value)
            case DICOMTag(group: 0x0028, element: 0x0100): parsed.bitsAllocated = unsignedShort(value, parsed.byteOrder)
            case DICOMTag(group: 0x0028, element: 0x0101): parsed.bitsStored = unsignedShort(value, parsed.byteOrder)
            case DICOMTag(group: 0x0028, element: 0x0102): parsed.highBit = unsignedShort(value, parsed.byteOrder)
            case DICOMTag(group: 0x0028, element: 0x0103): parsed.pixelRepresentation = unsignedShort(value, parsed.byteOrder)
            case DICOMTag(group: 0x0028, element: 0x1050): parsed.windowCenter = decimal(value)
            case DICOMTag(group: 0x0028, element: 0x1051): parsed.windowWidth = decimal(value)
            case DICOMTag(group: 0x0028, element: 0x1052): parsed.rescaleIntercept = decimal(value)
            case DICOMTag(group: 0x0028, element: 0x1053): parsed.rescaleSlope = decimal(value)
            default: break
            }
        }
        return parsed
    }

    private mutating func readHeader(explicitVR: Bool, order: DICOMByteOrder) throws -> ElementHeader {
        let tag = try readTag(order: order)
        if tag.group == 0xfffe {
            return ElementHeader(tag: tag, length: try readUInt32(order: order))
        }
        if !explicitVR { return ElementHeader(tag: tag, length: try readUInt32(order: order)) }
        guard cursor + 2 <= bytes.count else { throw DICOMReadError.malformed("truncated VR") }
        let vr = String(bytes: [bytes[cursor], bytes[cursor + 1]], encoding: .ascii) ?? ""
        cursor += 2
        let longVRs: Set<String> = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "SV", "UC", "UR", "UT", "UN", "UV"]
        if longVRs.contains(vr) {
            guard cursor + 2 <= bytes.count else { throw DICOMReadError.malformed("truncated reserved VR bytes") }
            cursor += 2
            return ElementHeader(tag: tag, length: try readUInt32(order: order))
        }
        return ElementHeader(tag: tag, length: UInt32(try readUInt16(order: order)))
    }

    private func isLikelyExplicitVR(at offset: Int) -> Bool {
        guard offset >= 0, offset + 6 <= bytes.count else { return false }
        let first = bytes[offset + 4], second = bytes[offset + 5]
        guard first >= 0x41, first <= 0x5a, second >= 0x41, second <= 0x5a else { return false }
        let vr = String(bytes: [first, second], encoding: .ascii) ?? ""
        let known: Set<String> = [
            "AE", "AS", "AT", "CS", "DA", "DS", "DT", "FD", "FL", "IS", "LO", "LT",
            "OB", "OD", "OF", "OL", "OV", "OW", "PN", "SH", "SL", "SQ", "SS", "ST",
            "SV", "TM", "UC", "UI", "UL", "UN", "UR", "US", "UT", "UV"
        ]
        return known.contains(vr)
    }

    private mutating func readTag(order: DICOMByteOrder) throws -> DICOMTag {
        DICOMTag(group: try readUInt16(order: order), element: try readUInt16(order: order))
    }

    private mutating func readUInt16(order: DICOMByteOrder) throws -> UInt16 {
        guard cursor + 2 <= bytes.count else { throw DICOMReadError.malformed("truncated 16-bit value") }
        let a = UInt16(bytes[cursor]), b = UInt16(bytes[cursor + 1]); cursor += 2
        return order == .littleEndian ? a | (b << 8) : (a << 8) | b
    }

    private mutating func readUInt32(order: DICOMByteOrder) throws -> UInt32 {
        guard cursor + 4 <= bytes.count else { throw DICOMReadError.malformed("truncated 32-bit value") }
        let a = UInt32(bytes[cursor]), b = UInt32(bytes[cursor + 1])
        let c = UInt32(bytes[cursor + 2]), d = UInt32(bytes[cursor + 3]); cursor += 4
        return order == .littleEndian ? a | (b << 8) | (c << 16) | (d << 24) : (a << 24) | (b << 16) | (c << 8) | d
    }

    private mutating func valueData(length: UInt32) throws -> Data {
        guard let length = Int(exactly: length), length >= 0, cursor <= bytes.count - length else {
            throw DICOMReadError.malformed("element extends beyond end of file")
        }
        let result = Data(bytes: bytes.baseAddress!.advanced(by: cursor), count: length)
        cursor += length
        return result
    }

    private mutating func skipValue(length: UInt32) throws {
        guard let length = Int(exactly: length), length >= 0, cursor <= bytes.count - length else {
            throw DICOMReadError.malformed("element extends beyond end of file")
        }
        cursor += length
    }

    private func isPreviewMetadata(_ tag: DICOMTag) -> Bool {
        switch tag {
        case DICOMTag(group: 0x0008, element: 0x0016),
             DICOMTag(group: 0x0008, element: 0x0060),
             DICOMTag(group: 0x0008, element: 0x0070),
             DICOMTag(group: 0x0008, element: 0x1030),
             DICOMTag(group: 0x0008, element: 0x103e),
             DICOMTag(group: 0x0010, element: 0x0010),
             DICOMTag(group: 0x0010, element: 0x0020),
             DICOMTag(group: 0x0018, element: 0x0050),
             DICOMTag(group: 0x0028, element: 0x0002),
             DICOMTag(group: 0x0028, element: 0x0004),
             DICOMTag(group: 0x0028, element: 0x0006),
             DICOMTag(group: 0x0028, element: 0x0008),
             DICOMTag(group: 0x0028, element: 0x0010),
             DICOMTag(group: 0x0028, element: 0x0011),
             DICOMTag(group: 0x0028, element: 0x0030),
             DICOMTag(group: 0x0028, element: 0x0100),
             DICOMTag(group: 0x0028, element: 0x0101),
             DICOMTag(group: 0x0028, element: 0x0102),
             DICOMTag(group: 0x0028, element: 0x0103),
             DICOMTag(group: 0x0028, element: 0x1050),
             DICOMTag(group: 0x0028, element: 0x1051),
             DICOMTag(group: 0x0028, element: 0x1052),
             DICOMTag(group: 0x0028, element: 0x1053): true
        default: false
        }
    }

    private mutating func readEncapsulatedPixelData() throws -> Data {
        var fragments = Data()
        var isFirstItem = true
        while cursor + 8 <= bytes.count {
            let tag = try readTag(order: .littleEndian)
            let length = try readUInt32(order: .littleEndian)
            if tag == DICOMTag(group: 0xfffe, element: 0xe0dd) { return fragments }
            guard tag == DICOMTag(group: 0xfffe, element: 0xe000), length != Self.undefinedLength else {
                throw DICOMReadError.malformed("invalid encapsulated pixel fragment")
            }
            let fragment = try valueData(length: length)
            if isFirstItem { isFirstItem = false } else { fragments.append(fragment) }
        }
        throw DICOMReadError.malformed("unterminated encapsulated pixel data")
    }

    private mutating func skipUndefinedValue(explicitVR: Bool, order: DICOMByteOrder) throws {
        while cursor + 8 <= bytes.count {
            let header = try readHeader(explicitVR: explicitVR, order: order)
            if header.tag.group == 0xfffe,
               header.tag.element == 0xe0dd || header.tag.element == 0xe00d { return }
            if header.length == Self.undefinedLength { try skipUndefinedValue(explicitVR: explicitVR, order: order) }
            else { try skipValue(length: header.length) }
        }
        throw DICOMReadError.malformed("unterminated undefined-length value")
    }

    private func string(_ data: Data) -> String? {
        let value = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\0")))
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func decimal(_ data: Data) -> Double? { decimalList(data)?.first }
    private func decimalList(_ data: Data) -> [Double]? {
        guard let value = string(data) else { return nil }
        let values = value.split(separator: "\\").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return values.isEmpty ? nil : values
    }
    private func integerString(_ data: Data) -> Int? { string(data).flatMap(Int.init) }
    private func unsignedShort(_ data: Data, _ order: DICOMByteOrder) -> Int? {
        guard data.count >= 2 else { return nil }
        let a = UInt16(data[data.startIndex]), b = UInt16(data[data.startIndex + 1])
        return Int(order == .littleEndian ? a | (b << 8) : (a << 8) | b)
    }

    private struct ElementHeader {
        let tag: DICOMTag
        let length: UInt32
    }
}
