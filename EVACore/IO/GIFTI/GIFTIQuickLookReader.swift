//
//  GIFTIQuickLookReader.swift
//  EVAPreviewKit
//
//  Streaming XML parsing and bounds-checked decoding for the GIFTI 1.0 data
//  encodings. No GIFTI or NIfTI C library is linked.
//

import Compression
import Foundation

nonisolated enum GIFTIQuickLookReader {
    static func read(from url: URL) throws -> GIFTIPreviewModel {
        let model = try readDocument(from: url)
        return GIFTICompanionSurfaceResolver.attachIfAvailable(to: model)
    }

    static func readDocument(from url: URL) throws -> GIFTIPreviewModel {
        guard url.lastPathComponent.lowercased().hasSuffix(".gii") else {
            throw GIFTIReadError.unsupportedFile(url)
        }
        guard let parser = XMLParser(contentsOf: url) else {
            throw GIFTIReadError.cannotOpen(url)
        }
        let delegate = GIFTIXMLDelegate(url: url)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            if let error = delegate.failure { throw error }
            throw GIFTIReadError.invalidXML(parser.parserError?.localizedDescription ?? "unknown XML error")
        }
        return try delegate.makeModel()
    }
}

nonisolated enum GIFTIReadError: LocalizedError, Sendable {
    case unsupportedFile(URL)
    case cannotOpen(URL)
    case invalidXML(String)
    case invalidRoot
    case missingAttribute(String)
    case invalidAttribute(String, String)
    case unsupportedDataType(String)
    case unsupportedEncoding(String)
    case arrayTooLarge
    case invalidData(String)
    case externalFileNotLocal(String)
    case cannotReadExternalFile(String)
    case invalidSurface(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url): return "\(url.lastPathComponent) is not a GIFTI file."
        case .cannotOpen(let url): return "Could not open \(url.lastPathComponent)."
        case .invalidXML(let reason): return "Invalid GIFTI XML: \(reason)"
        case .invalidRoot: return "The XML document does not have a GIFTI root element."
        case .missingAttribute(let name): return "A GIFTI DataArray is missing \(name)."
        case .invalidAttribute(let name, let value): return "Invalid GIFTI \(name) value \(value.debugDescription)."
        case .unsupportedDataType(let type): return "Unsupported GIFTI datatype \(type)."
        case .unsupportedEncoding(let encoding): return "Unsupported GIFTI encoding \(encoding)."
        case .arrayTooLarge: return "A GIFTI data array is too large to preview safely."
        case .invalidData(let reason): return "Invalid GIFTI array data: \(reason)"
        case .externalFileNotLocal(let name): return "External GIFTI data must be in the same folder (\(name))."
        case .cannotReadExternalFile(let name): return "Could not read external GIFTI data file \(name)."
        case .invalidSurface(let reason): return "Invalid GIFTI surface: \(reason)"
        }
    }
}

private nonisolated struct GIFTIDecodedArray {
    let summary: GIFTIDataArraySummary
    let order: GIFTIArrayOrder
    let values: [Double]?
    let transforms: [GIFTICoordinateTransform]
}

private nonisolated struct GIFTICoordinateTransform {
    let dataSpace: String?
    let transformedSpace: String?
    let matrix: [Double]
}

private nonisolated enum GIFTIArrayOrder: String {
    case rowMajor = "RowMajorOrder"
    case columnMajor = "ColumnMajorOrder"
}

private nonisolated enum GIFTIEncoding: String {
    case ascii = "ASCII"
    case base64 = "Base64Binary"
    case zlibBase64 = "GZipBase64Binary"
    case external = "ExternalFileBinary"
}

private nonisolated enum GIFTIDataType {
    case uint8, int8, uint16, int16, uint32, int32, uint64, int64, float32, float64

    init(name: String) throws {
        switch name.uppercased() {
        case "NIFTI_TYPE_UINT8", "2": self = .uint8
        case "NIFTI_TYPE_INT16", "4": self = .int16
        case "NIFTI_TYPE_INT32", "8": self = .int32
        case "NIFTI_TYPE_FLOAT32", "16": self = .float32
        case "NIFTI_TYPE_INT8", "256": self = .int8
        case "NIFTI_TYPE_UINT16", "512": self = .uint16
        case "NIFTI_TYPE_UINT32", "768": self = .uint32
        case "NIFTI_TYPE_INT64", "1024": self = .int64
        case "NIFTI_TYPE_UINT64", "1280": self = .uint64
        case "NIFTI_TYPE_FLOAT64", "64": self = .float64
        default: throw GIFTIReadError.unsupportedDataType(name)
        }
    }

    var byteCount: Int {
        switch self {
        case .uint8, .int8: return 1
        case .uint16, .int16: return 2
        case .uint32, .int32, .float32: return 4
        case .uint64, .int64, .float64: return 8
        }
    }
}

private nonisolated enum GIFTIByteOrder: String {
    case littleEndian = "LittleEndian"
    case bigEndian = "BigEndian"
}

private nonisolated struct GIFTIPendingArray {
    let intent: String
    let dataTypeName: String
    let dataType: GIFTIDataType
    let order: GIFTIArrayOrder
    let dimensions: [Int]
    let encodingName: String
    let encoding: GIFTIEncoding
    let byteOrder: GIFTIByteOrder
    let externalFileName: String
    let externalFileOffset: UInt64
    let captureData: Bool
    let expectedCount: Int
    var metadata: [String: String] = [:]
    var transforms: [GIFTICoordinateTransform] = []
    var dataText = ""
}

private nonisolated final class GIFTIXMLDelegate: NSObject, XMLParserDelegate {
    private static let maximumGeometryValues = 4_500_000
    private static let maximumPreviewValues = 2_000_000
    private static let maximumTextCharacters = 128 * 1024 * 1024
    private static let maximumMetadataCharacters = 4 * 1024 * 1024

    private let url: URL
    private(set) var failure: GIFTIReadError?
    private var sawRoot = false
    private var version = ""
    private var declaredArrayCount: Int?
    private var fileMetadata: [String: String] = [:]
    private var arrays: [GIFTIDecodedArray] = []
    private var labels: [Int: GIFTILabel] = [:]
    private var pendingArray: GIFTIPendingArray?
    private var capturedPreviewValueCount = 0
    private var elementStack: [String] = []
    private var text = ""
    private var metadataName: String?
    private var metadataValue: String?
    private var pendingLabel: (key: Int, red: Float?, green: Float?, blue: Float?, alpha: Float?)?
    private var transformDataSpace: String?
    private var transformTargetSpace: String?
    private var transformMatrixText: String?

    init(url: URL) { self.url = url }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        elementStack.append(elementName)
        text = ""
        do {
            switch elementName {
            case "GIFTI":
                sawRoot = true
                version = attributeDict["Version"] ?? "Unknown"
                if let raw = attributeDict["NumberOfDataArrays"] {
                    guard let count = Int(raw), count >= 0 else {
                        throw GIFTIReadError.invalidAttribute("NumberOfDataArrays", raw)
                    }
                    declaredArrayCount = count
                }
            case "DataArray":
                pendingArray = try makePendingArray(attributes: attributeDict)
            case "Label":
                guard let rawKey = attributeDict["Key"] ?? attributeDict["Index"],
                      let key = Int(rawKey), key >= 0 else {
                    throw GIFTIReadError.missingAttribute("Label Key")
                }
                pendingLabel = (
                    key, float(attributeDict["Red"]), float(attributeDict["Green"]),
                    float(attributeDict["Blue"]), float(attributeDict["Alpha"])
                )
            case "CoordinateSystemTransformMatrix":
                transformDataSpace = nil
                transformTargetSpace = nil
                transformMatrixText = nil
            default: break
            }
        } catch let error as GIFTIReadError {
            fail(error, parser: parser)
        } catch {
            fail(.invalidXML(error.localizedDescription), parser: parser)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard failure == nil, let element = elementStack.last else { return }
        if element == "Data" {
            guard pendingArray?.captureData == true else { return }
            if (pendingArray?.dataText.count ?? 0) + string.count > Self.maximumTextCharacters {
                fail(.arrayTooLarge, parser: parser)
            } else {
                pendingArray?.dataText.append(string)
            }
        } else {
            if text.count + string.count > Self.maximumMetadataCharacters {
                fail(.invalidXML("metadata is too large"), parser: parser)
            } else {
                text.append(string)
            }
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard failure == nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch elementName {
            case "Name": metadataName = value
            case "Value": metadataValue = value
            case "MD":
                if let name = metadataName, let value = metadataValue {
                    if pendingArray != nil { pendingArray?.metadata[name] = value }
                    else { fileMetadata[name] = value }
                }
                metadataName = nil
                metadataValue = nil
            case "Label":
                if let label = pendingLabel {
                    labels[label.key] = GIFTILabel(
                        key: label.key, name: value,
                        red: label.red, green: label.green, blue: label.blue, alpha: label.alpha
                    )
                }
                pendingLabel = nil
            case "DataSpace": transformDataSpace = value.isEmpty ? nil : value
            case "TransformedSpace": transformTargetSpace = value.isEmpty ? nil : value
            case "MatrixData": transformMatrixText = value
            case "CoordinateSystemTransformMatrix":
                let matrix = try parseNumbers(transformMatrixText ?? "", expectedCount: 16)
                pendingArray?.transforms.append(GIFTICoordinateTransform(
                    dataSpace: transformDataSpace,
                    transformedSpace: transformTargetSpace,
                    matrix: matrix
                ))
            case "DataArray":
                guard let pending = pendingArray else {
                    throw GIFTIReadError.invalidXML("DataArray state was lost")
                }
                let summary = GIFTIDataArraySummary(
                    intent: pending.intent,
                    dataType: pending.dataTypeName,
                    dimensions: pending.dimensions,
                    encoding: pending.encodingName,
                    metadata: pending.metadata
                )
                let values = pending.captureData ? try decode(pending) : nil
                arrays.append(GIFTIDecodedArray(
                    summary: summary, order: pending.order,
                    values: values, transforms: pending.transforms
                ))
                pendingArray = nil
            default: break
            }
        } catch let error as GIFTIReadError {
            fail(error, parser: parser)
        } catch {
            fail(.invalidData(error.localizedDescription), parser: parser)
        }
        if !elementStack.isEmpty { elementStack.removeLast() }
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if failure == nil { failure = .invalidXML(parseError.localizedDescription) }
    }

    func makeModel() throws -> GIFTIPreviewModel {
        guard sawRoot else { throw GIFTIReadError.invalidRoot }
        if let declaredArrayCount, declaredArrayCount != arrays.count {
            throw GIFTIReadError.invalidData(
                "NumberOfDataArrays is \(declaredArrayCount), but \(arrays.count) were found"
            )
        }

        let pointArray = arrays.first { $0.summary.intent == "NIFTI_INTENT_POINTSET" }
        let triangleArray = arrays.first { $0.summary.intent == "NIFTI_INTENT_TRIANGLE" }
        var vertices = try pointArray.map(points(from:)) ?? []
        if let transform = pointArray?.transforms.first {
            vertices = try apply(transform: transform, to: vertices)
        }
        let surfaceTriangles = try triangleArray.map {
            try triangles(from: $0, vertexCount: vertices.count)
        } ?? []

        let scalarOverlays = arrays.flatMap { makeOverlays(from: $0, vertexCount: vertices.count) }
        let byteSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return GIFTIPreviewModel(
            url: url,
            version: version,
            metadata: fileMetadata,
            arrays: arrays.map(\.summary),
            labels: labels,
            vertices: vertices,
            triangles: surfaceTriangles,
            overlays: scalarOverlays,
            sharedOverlayWindow: GIFTIScalarOverlay.sharedWindow(for: scalarOverlays),
            coordinateSpace: pointArray?.transforms.first?.transformedSpace,
            byteSize: byteSize,
            companionSurfaceName: nil
        )
    }

    private func makePendingArray(attributes: [String: String]) throws -> GIFTIPendingArray {
        func required(_ name: String) throws -> String {
            guard let value = attributes[name], !value.isEmpty else {
                throw GIFTIReadError.missingAttribute(name)
            }
            return value
        }
        let intent = try required("Intent")
        let dataTypeName = try required("DataType")
        let dataType = try GIFTIDataType(name: dataTypeName)
        let orderName = try required("ArrayIndexingOrder")
        guard let order = GIFTIArrayOrder(rawValue: orderName) else {
            throw GIFTIReadError.invalidAttribute("ArrayIndexingOrder", orderName)
        }
        let encodingName = try required("Encoding")
        guard let encoding = GIFTIEncoding(rawValue: encodingName) else {
            throw GIFTIReadError.unsupportedEncoding(encodingName)
        }
        let endianName = try required("Endian")
        guard let byteOrder = GIFTIByteOrder(rawValue: endianName) else {
            throw GIFTIReadError.invalidAttribute("Endian", endianName)
        }
        let dimensionalityRaw = try required("Dimensionality")
        guard let dimensionality = Int(dimensionalityRaw), (1...6).contains(dimensionality) else {
            throw GIFTIReadError.invalidAttribute("Dimensionality", dimensionalityRaw)
        }
        var dimensions: [Int] = []
        var expectedCount = 1
        for index in 0..<dimensionality {
            let name = "Dim\(index)"
            let raw = try required(name)
            guard let value = Int(raw), value > 0 else {
                throw GIFTIReadError.invalidAttribute(name, raw)
            }
            let (product, overflow) = expectedCount.multipliedReportingOverflow(by: value)
            guard !overflow else { throw GIFTIReadError.arrayTooLarge }
            expectedCount = product
            dimensions.append(value)
        }
        let isGeometry = intent == "NIFTI_INTENT_POINTSET" || intent == "NIFTI_INTENT_TRIANGLE"
        if isGeometry && expectedCount > Self.maximumGeometryValues { throw GIFTIReadError.arrayTooLarge }
        let excludedOverlayIntents: Set<String> = [
            "NIFTI_INTENT_POINTSET", "NIFTI_INTENT_TRIANGLE", "NIFTI_INTENT_NODE_INDEX",
            "NIFTI_INTENT_VECTOR", "NIFTI_INTENT_DISPVECT", "NIFTI_INTENT_RGB_VECTOR",
            "NIFTI_INTENT_RGBA_VECTOR", "NIFTI_INTENT_GENMATRIX", "NIFTI_INTENT_SYMMATRIX"
        ]
        let isOverlayCandidate = !excludedOverlayIntents.contains(intent)
        let remainingPreviewCapacity = Self.maximumPreviewValues - capturedPreviewValueCount
        let captureOverlay = isOverlayCandidate && expectedCount <= remainingPreviewCapacity
        if captureOverlay { capturedPreviewValueCount += expectedCount }
        let externalFileName = attributes["ExternalFileName"] ?? ""
        let externalFileOffset: UInt64
        if encoding == .external {
            guard !externalFileName.isEmpty else { throw GIFTIReadError.missingAttribute("ExternalFileName") }
            let rawOffset = try required("ExternalFileOffset")
            guard let offset = UInt64(rawOffset) else {
                throw GIFTIReadError.invalidAttribute("ExternalFileOffset", rawOffset)
            }
            externalFileOffset = offset
        } else {
            externalFileOffset = 0
        }
        return GIFTIPendingArray(
            intent: intent,
            dataTypeName: dataTypeName,
            dataType: dataType,
            order: order,
            dimensions: dimensions,
            encodingName: encodingName,
            encoding: encoding,
            byteOrder: byteOrder,
            externalFileName: externalFileName,
            externalFileOffset: externalFileOffset,
            captureData: isGeometry || captureOverlay,
            expectedCount: expectedCount
        )
    }

    private func makeOverlays(from array: GIFTIDecodedArray, vertexCount: Int) -> [GIFTIScalarOverlay] {
        guard let values = array.values else { return [] }
        let intent = array.summary.intent
        let excluded: Set<String> = [
            "NIFTI_INTENT_POINTSET", "NIFTI_INTENT_TRIANGLE", "NIFTI_INTENT_NODE_INDEX",
            "NIFTI_INTENT_VECTOR", "NIFTI_INTENT_DISPVECT", "NIFTI_INTENT_RGB_VECTOR",
            "NIFTI_INTENT_RGBA_VECTOR", "NIFTI_INTENT_GENMATRIX", "NIFTI_INTENT_SYMMATRIX"
        ]
        guard !excluded.contains(intent) else { return [] }

        let baseName = array.summary.metadata["Name"] ?? array.summary.intentDisplayName
        guard array.summary.dimensions.count == 2 else {
            guard vertexCount == 0 || values.count == vertexCount else { return [] }
            return [.make(name: baseName, intent: intent, values: values)]
        }

        let rows = array.summary.dimensions[0]
        let columns = array.summary.dimensions[1]
        let nodeAxis: Int
        if vertexCount > 0 {
            if rows == vertexCount { nodeAxis = 0 }
            else if columns == vertexCount { nodeAxis = 1 }
            else { return [] }
        } else {
            // GIFTI convention places nodes in Dim0 for an N-by-T functional array.
            nodeAxis = 0
        }
        let frameCount = nodeAxis == 0 ? columns : rows
        let nodeCount = nodeAxis == 0 ? rows : columns
        guard nodeCount > 0, frameCount > 0 else { return [] }

        return (0..<frameCount).map { frame in
            let frameValues = (0..<nodeCount).map { node -> Double in
                let row = nodeAxis == 0 ? node : frame
                let column = nodeAxis == 0 ? frame : node
                let index = array.order == .rowMajor
                    ? row * columns + column
                    : column * rows + row
                return values[index]
            }
            let name = frameCount == 1 ? baseName : "\(baseName) · \(frame + 1)"
            return .make(name: name, intent: intent, values: frameValues)
        }
    }

    private func decode(_ array: GIFTIPendingArray) throws -> [Double] {
        switch array.encoding {
        case .ascii:
            return try parseNumbers(array.dataText, expectedCount: array.expectedCount)
        case .base64, .zlibBase64:
            guard let encoded = Data(base64Encoded: array.dataText, options: .ignoreUnknownCharacters) else {
                throw GIFTIReadError.invalidData("invalid base64")
            }
            let expectedBytes = try checkedByteCount(array)
            let bytes = array.encoding == .zlibBase64
                ? try inflate(encoded, expectedByteCount: expectedBytes)
                : encoded
            guard bytes.count == expectedBytes else {
                throw GIFTIReadError.invalidData("expected \(expectedBytes) bytes, found \(bytes.count)")
            }
            return decodeBinary(bytes, type: array.dataType, order: array.byteOrder)
        case .external:
            let bytes = try readExternalData(array)
            return decodeBinary(bytes, type: array.dataType, order: array.byteOrder)
        }
    }

    private func checkedByteCount(_ array: GIFTIPendingArray) throws -> Int {
        let (count, overflow) = array.expectedCount.multipliedReportingOverflow(by: array.dataType.byteCount)
        guard !overflow else { throw GIFTIReadError.arrayTooLarge }
        return count
    }

    private func readExternalData(_ array: GIFTIPendingArray) throws -> Data {
        let name = array.externalFileName
        guard !name.isEmpty,
              !name.hasPrefix("/"),
              URL(fileURLWithPath: name).lastPathComponent == name else {
            throw GIFTIReadError.externalFileNotLocal(name)
        }
        let externalURL = url.deletingLastPathComponent().appendingPathComponent(name)
        let count = try checkedByteCount(array)
        do {
            let handle = try FileHandle(forReadingFrom: externalURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: array.externalFileOffset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else {
                throw GIFTIReadError.invalidData("external data is truncated")
            }
            return data
        } catch let error as GIFTIReadError {
            throw error
        } catch {
            throw GIFTIReadError.cannotReadExternalFile(name)
        }
    }

    private func inflate(_ data: Data, expectedByteCount: Int) throws -> Data {
        let payload = try rawDeflatePayload(from: data)
        var offset = 0
        do {
            let filter = try InputFilter<Data>(.decompress, using: .zlib, bufferCapacity: 64 * 1024) { count in
                guard offset < payload.count else { return nil }
                let end = min(offset + count, payload.count)
                defer { offset = end }
                return payload.subdata(in: offset..<end)
            }
            let result = try filter.readData(ofLength: expectedByteCount) ?? Data()
            let extra = try filter.readData(ofLength: 1) ?? Data()
            guard result.count == expectedByteCount, extra.isEmpty else {
                throw GIFTIReadError.invalidData("zlib output size does not match the declared dimensions")
            }
            return result
        } catch let error as GIFTIReadError {
            throw error
        } catch {
            throw GIFTIReadError.invalidData("zlib decompression failed: \(error.localizedDescription)")
        }
    }

    /// Apple's Compression `.zlib` filter consumes raw DEFLATE bytes. GIFTI
    /// writers commonly emit a full RFC 1950 zlib stream, and some early tools
    /// emitted an RFC 1952 gzip stream despite the specification saying ZLIB.
    private func rawDeflatePayload(from data: Data) throws -> Data {
        let bytes = [UInt8](data)
        if bytes.count >= 6 {
            let header = Int(bytes[0]) << 8 | Int(bytes[1])
            let isZlib = bytes[0] & 0x0f == 8 && header % 31 == 0
            if isZlib {
                guard bytes[1] & 0x20 == 0 else {
                    throw GIFTIReadError.invalidData("preset zlib dictionaries are unsupported")
                }
                return data.subdata(in: 2..<(data.count - 4))
            }
        }
        if bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b {
            guard bytes[2] == 8 else {
                throw GIFTIReadError.invalidData("unsupported gzip compression method")
            }
            let flags = bytes[3]
            guard flags & 0xe0 == 0 else {
                throw GIFTIReadError.invalidData("reserved gzip flags are set")
            }
            var index = 10
            if flags & 0x04 != 0 {
                guard index + 2 <= bytes.count - 8 else { throw GIFTIReadError.invalidData("truncated gzip header") }
                let length = Int(bytes[index]) | Int(bytes[index + 1]) << 8
                index += 2 + length
            }
            if flags & 0x08 != 0 { while index < bytes.count - 8, bytes[index] != 0 { index += 1 }; index += 1 }
            if flags & 0x10 != 0 { while index < bytes.count - 8, bytes[index] != 0 { index += 1 }; index += 1 }
            if flags & 0x02 != 0 { index += 2 }
            guard index <= bytes.count - 8 else { throw GIFTIReadError.invalidData("truncated gzip header") }
            return data.subdata(in: index..<(data.count - 8))
        }
        return data
    }

    private func parseNumbers(_ source: String, expectedCount: Int) throws -> [Double] {
        let tokens = source.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count == expectedCount else {
            throw GIFTIReadError.invalidData("expected \(expectedCount) values, found \(tokens.count)")
        }
        var values: [Double] = []
        values.reserveCapacity(expectedCount)
        for token in tokens {
            guard let value = Double(token) else {
                throw GIFTIReadError.invalidData("non-numeric value \(String(token).debugDescription)")
            }
            values.append(value)
        }
        return values
    }

    private func decodeBinary(_ data: Data, type: GIFTIDataType, order: GIFTIByteOrder) -> [Double] {
        let stride = type.byteCount
        return data.withUnsafeBytes { bytes in
            (0..<(data.count / stride)).map { index in
                let offset = index * stride
                switch type {
                case .uint8: return Double(bytes[offset])
                case .int8: return Double(Int8(bitPattern: bytes[offset]))
                case .uint16: return Double(uint16(bytes, offset, order))
                case .int16: return Double(Int16(bitPattern: uint16(bytes, offset, order)))
                case .uint32: return Double(uint32(bytes, offset, order))
                case .int32: return Double(Int32(bitPattern: uint32(bytes, offset, order)))
                case .uint64: return Double(uint64(bytes, offset, order))
                case .int64: return Double(Int64(bitPattern: uint64(bytes, offset, order)))
                case .float32: return Double(Float(bitPattern: uint32(bytes, offset, order)))
                case .float64: return Double(bitPattern: uint64(bytes, offset, order))
                }
            }
        }
    }

    private func uint16(_ bytes: UnsafeRawBufferPointer, _ offset: Int, _ order: GIFTIByteOrder) -> UInt16 {
        let value = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        return order == .littleEndian ? value : value.byteSwapped
    }

    private func uint32(_ bytes: UnsafeRawBufferPointer, _ offset: Int, _ order: GIFTIByteOrder) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[offset + index]) << UInt32(index * 8) }
        return order == .littleEndian ? value : value.byteSwapped
    }

    private func uint64(_ bytes: UnsafeRawBufferPointer, _ offset: Int, _ order: GIFTIByteOrder) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[offset + index]) << UInt64(index * 8) }
        return order == .littleEndian ? value : value.byteSwapped
    }

    private func points(from array: GIFTIDecodedArray) throws -> [GIFTIPoint] {
        guard array.summary.dimensions.count == 2, array.summary.dimensions[1] == 3,
              let values = array.values else {
            throw GIFTIReadError.invalidSurface("POINTSET must have dimensions N × 3")
        }
        let count = array.summary.dimensions[0]
        return (0..<count).map { index in
            let components = triplet(values, index: index, count: count, order: array.order)
            return GIFTIPoint(x: Float(components.0), y: Float(components.1), z: Float(components.2))
        }
    }

    private func triangles(from array: GIFTIDecodedArray, vertexCount: Int) throws -> [GIFTITriangle] {
        guard array.summary.dimensions.count == 2, array.summary.dimensions[1] == 3,
              let values = array.values else {
            throw GIFTIReadError.invalidSurface("TRIANGLE must have dimensions N × 3")
        }
        let count = array.summary.dimensions[0]
        var result: [GIFTITriangle] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let components = triplet(values, index: index, count: count, order: array.order)
            let indices = [components.0, components.1, components.2]
            guard indices.allSatisfy({ $0.isFinite && $0.rounded() == $0 && $0 >= 0 && $0 <= Double(UInt32.max) }) else {
                throw GIFTIReadError.invalidSurface("triangle \(index) contains a non-integer index")
            }
            let converted = indices.map { UInt32($0) }
            if vertexCount > 0, converted.contains(where: { Int($0) >= vertexCount }) {
                throw GIFTIReadError.invalidSurface("triangle \(index) refers to a missing vertex")
            }
            result.append(GIFTITriangle(a: converted[0], b: converted[1], c: converted[2]))
        }
        return result
    }

    private func triplet(
        _ values: [Double], index: Int, count: Int, order: GIFTIArrayOrder
    ) -> (Double, Double, Double) {
        switch order {
        case .rowMajor:
            return (values[index * 3], values[index * 3 + 1], values[index * 3 + 2])
        case .columnMajor:
            return (values[index], values[count + index], values[count * 2 + index])
        }
    }

    private func apply(transform: GIFTICoordinateTransform, to points: [GIFTIPoint]) throws -> [GIFTIPoint] {
        guard transform.matrix.count == 16 else {
            throw GIFTIReadError.invalidSurface("coordinate transform is not 4 × 4")
        }
        let m = transform.matrix
        return try points.map { point in
            let x = Double(point.x), y = Double(point.y), z = Double(point.z)
            let denominator = m[12] * x + m[13] * y + m[14] * z + m[15]
            let w = denominator == 0 ? 1 : denominator
            let transformed = (
                (m[0] * x + m[1] * y + m[2] * z + m[3]) / w,
                (m[4] * x + m[5] * y + m[6] * z + m[7]) / w,
                (m[8] * x + m[9] * y + m[10] * z + m[11]) / w
            )
            guard transformed.0.isFinite, transformed.1.isFinite, transformed.2.isFinite else {
                throw GIFTIReadError.invalidSurface("coordinate transform produced a non-finite point")
            }
            return GIFTIPoint(x: Float(transformed.0), y: Float(transformed.1), z: Float(transformed.2))
        }
    }

    private func float(_ raw: String?) -> Float? {
        guard let raw, let value = Float(raw), value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    private func fail(_ error: GIFTIReadError, parser: XMLParser) {
        failure = error
        parser.abortParsing()
    }
}
