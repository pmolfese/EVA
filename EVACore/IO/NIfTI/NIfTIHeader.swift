//
//  NIfTIHeader.swift
//  EVAPreviewKit
//
//  Bounds-checked, endian-aware decoding of the NIfTI-1 and NIfTI-2 headers.
//  The code deliberately reads documented byte offsets rather than binding
//  file data to a C-layout struct, keeping the Quick Look implementation pure
//  Swift and safe on unaligned input.
//

import Foundation

nonisolated struct NIfTIHeader: Sendable {

    enum Version: Int, Sendable {
        case one = 1
        case two = 2

        var displayName: String { "NIfTI-\(rawValue)" }
        var byteCount: Int { self == .one ? 348 : 540 }
    }

    enum ByteOrder: Sendable {
        case littleEndian
        case bigEndian

        var displayName: String {
            self == .littleEndian ? "Little-endian" : "Big-endian"
        }
    }

    enum DataType: Int, Sendable {
        case uint8 = 2
        case int16 = 4
        case int32 = 8
        case float32 = 16
        case complex64 = 32
        case float64 = 64
        case rgb24 = 128
        case int8 = 256
        case uint16 = 512
        case uint32 = 768
        case int64 = 1024
        case uint64 = 1280
        case float128 = 1536
        case complex128 = 1792
        case complex256 = 2048
        case rgba32 = 2304

        var displayName: String {
            switch self {
            case .uint8: return "UInt8"
            case .int8: return "Int8"
            case .int16: return "Int16"
            case .uint16: return "UInt16"
            case .int32: return "Int32"
            case .uint32: return "UInt32"
            case .int64: return "Int64"
            case .uint64: return "UInt64"
            case .float32: return "Float32"
            case .float64: return "Float64"
            case .complex64: return "Complex64"
            case .complex128: return "Complex128"
            case .complex256: return "Complex256"
            case .float128: return "Float128"
            case .rgb24: return "RGB24"
            case .rgba32: return "RGBA32"
            }
        }

        var supportedScalarBitCount: Int? {
            switch self {
            case .uint8, .int8: return 8
            case .int16, .uint16: return 16
            case .int32, .uint32, .float32: return 32
            case .int64, .uint64, .float64: return 64
            default: return nil
            }
        }
    }

    struct Affine: Sendable {
        struct AxisOrientation: Sendable, Equatable {
            let worldAxis: Int
            let isPositive: Bool

            var positiveLabel: String {
                switch (worldAxis, isPositive) {
                case (0, true): return "R"
                case (0, false): return "L"
                case (1, true): return "A"
                case (1, false): return "P"
                case (2, true): return "S"
                default: return "I"
                }
            }
        }

        /// Three rows by four columns, mapping voxel indices to NIfTI's RAS+
        /// world coordinate system.
        let rows: [[Double]]
        let source: String

        var axisOrientations: [AxisOrientation] {
            let permutations = [
                [0, 1, 2], [0, 2, 1], [1, 0, 2],
                [1, 2, 0], [2, 0, 1], [2, 1, 0]
            ]
            let best = permutations.max { lhs, rhs in
                orientationScore(lhs) < orientationScore(rhs)
            } ?? [0, 1, 2]
            return (0..<3).map { voxelAxis in
                let worldAxis = best[voxelAxis]
                let component = rows[safe: worldAxis]?[safe: voxelAxis] ?? 0
                return AxisOrientation(worldAxis: worldAxis, isPositive: component >= 0)
            }
        }

        func directionLabel(forVoxelAxis axis: Int) -> String? {
            guard axisOrientations.indices.contains(axis) else { return nil }
            return axisOrientations[axis].positiveLabel
        }

        private func orientationScore(_ permutation: [Int]) -> Double {
            (0..<3).reduce(0) { score, voxelAxis in
                let worldAxis = permutation[voxelAxis]
                return score + abs(rows[safe: worldAxis]?[safe: voxelAxis] ?? 0)
            }
        }
    }

    let version: Version
    let byteOrder: ByteOrder
    let dimensions: [Int64]
    let pixelDimensions: [Double]
    let dataType: DataType
    let bitpix: Int
    let voxelOffset: Int64
    let scaleSlope: Double
    let scaleIntercept: Double
    let calibrationMinimum: Double?
    let calibrationMaximum: Double?
    let spatialUnit: String?
    let temporalUnit: String?
    let qformCode: Int
    let sformCode: Int
    let intentCode: Int
    let intentName: String?
    let description: String?
    let affine: Affine?
    let magic: String

    var dimensionCount: Int { Int(dimensions.first ?? 0) }
    var width: Int { Int(dimensions[safe: 1] ?? 1) }
    var height: Int { Int(dimensions[safe: 2] ?? 1) }
    var depth: Int { Int(dimensions[safe: 3] ?? 1) }
    var volumeCount: Int { dimensionCount >= 4 ? Int(dimensions[safe: 4] ?? 1) : 1 }
    var bytesPerVoxel: Int { bitpix / 8 }

    var effectiveSlope: Double {
        scaleSlope.isFinite && scaleSlope != 0 ? scaleSlope : 1
    }

    var effectiveIntercept: Double {
        scaleIntercept.isFinite ? scaleIntercept : 0
    }

    var isSingleFile: Bool {
        magic.hasPrefix("n+1") || magic.hasPrefix("n+2")
    }

    static func versionAndByteOrder(from firstFourBytes: Data) throws -> (Version, ByteOrder) {
        guard firstFourBytes.count == 4 else { throw NIfTIReadError.truncatedHeader }
        let bytes = [UInt8](firstFourBytes)
        let little = Int(ByteDecoder.uint32(bytes, at: 0, order: .littleEndian))
        let big = Int(ByteDecoder.uint32(bytes, at: 0, order: .bigEndian))
        switch little {
        case 348: return (.one, .littleEndian)
        case 540: return (.two, .littleEndian)
        default: break
        }
        switch big {
        case 348: return (.one, .bigEndian)
        case 540: return (.two, .bigEndian)
        default: throw NIfTIReadError.invalidHeaderSize(little)
        }
    }

    static func decode(_ data: Data, version: Version, byteOrder: ByteOrder) throws -> NIfTIHeader {
        guard data.count >= version.byteCount else { throw NIfTIReadError.truncatedHeader }
        let bytes = [UInt8](data.prefix(version.byteCount))
        switch version {
        case .one: return try decodeV1(bytes, byteOrder: byteOrder)
        case .two: return try decodeV2(bytes, byteOrder: byteOrder)
        }
    }

    private static func decodeV1(_ bytes: [UInt8], byteOrder: ByteOrder) throws -> NIfTIHeader {
        let dimensions = stride(from: 40, to: 56, by: 2).map {
            Int64(ByteDecoder.int16(bytes, at: $0, order: byteOrder))
        }
        let pixdim = stride(from: 76, to: 108, by: 4).map {
            Double(ByteDecoder.float32(bytes, at: $0, order: byteOrder))
        }
        let datatypeCode = Int(ByteDecoder.int16(bytes, at: 70, order: byteOrder))
        guard let datatype = DataType(rawValue: datatypeCode) else {
            throw NIfTIReadError.unsupportedDataType(datatypeCode)
        }
        let bitpix = Int(ByteDecoder.int16(bytes, at: 72, order: byteOrder))
        let magic = ByteDecoder.string(bytes, at: 344, count: 4)
        let qformCode = Int(ByteDecoder.int16(bytes, at: 252, order: byteOrder))
        let sformCode = Int(ByteDecoder.int16(bytes, at: 254, order: byteOrder))
        let affine = makeAffine(
            qformCode: qformCode,
            sformCode: sformCode,
            quaternB: Double(ByteDecoder.float32(bytes, at: 256, order: byteOrder)),
            quaternC: Double(ByteDecoder.float32(bytes, at: 260, order: byteOrder)),
            quaternD: Double(ByteDecoder.float32(bytes, at: 264, order: byteOrder)),
            offsets: [268, 272, 276].map { Double(ByteDecoder.float32(bytes, at: $0, order: byteOrder)) },
            pixdim: pixdim,
            srows: [280, 296, 312].map { row in
                stride(from: row, to: row + 16, by: 4).map {
                    Double(ByteDecoder.float32(bytes, at: $0, order: byteOrder))
                }
            }
        )
        let units = decodeUnits(Int(bytes[123]))
        return NIfTIHeader(
            version: .one,
            byteOrder: byteOrder,
            dimensions: dimensions,
            pixelDimensions: pixdim,
            dataType: datatype,
            bitpix: bitpix,
            voxelOffset: Int64(Double(ByteDecoder.float32(bytes, at: 108, order: byteOrder)).rounded(.towardZero)),
            scaleSlope: Double(ByteDecoder.float32(bytes, at: 112, order: byteOrder)),
            scaleIntercept: Double(ByteDecoder.float32(bytes, at: 116, order: byteOrder)),
            calibrationMinimum: finiteOrNil(Double(ByteDecoder.float32(bytes, at: 128, order: byteOrder))),
            calibrationMaximum: finiteOrNil(Double(ByteDecoder.float32(bytes, at: 124, order: byteOrder))),
            spatialUnit: units.spatial,
            temporalUnit: units.temporal,
            qformCode: qformCode,
            sformCode: sformCode,
            intentCode: Int(ByteDecoder.int16(bytes, at: 68, order: byteOrder)),
            intentName: ByteDecoder.optionalString(bytes, at: 328, count: 16),
            description: ByteDecoder.optionalString(bytes, at: 148, count: 80),
            affine: affine,
            magic: magic
        )
    }

    private static func decodeV2(_ bytes: [UInt8], byteOrder: ByteOrder) throws -> NIfTIHeader {
        let dimensions = stride(from: 16, to: 80, by: 8).map {
            ByteDecoder.int64(bytes, at: $0, order: byteOrder)
        }
        let pixdim = stride(from: 104, to: 168, by: 8).map {
            ByteDecoder.float64(bytes, at: $0, order: byteOrder)
        }
        let datatypeCode = Int(ByteDecoder.int16(bytes, at: 12, order: byteOrder))
        guard let datatype = DataType(rawValue: datatypeCode) else {
            throw NIfTIReadError.unsupportedDataType(datatypeCode)
        }
        let bitpix = Int(ByteDecoder.int16(bytes, at: 14, order: byteOrder))
        let magic = ByteDecoder.string(bytes, at: 4, count: 8)
        let qformCode = Int(ByteDecoder.int32(bytes, at: 344, order: byteOrder))
        let sformCode = Int(ByteDecoder.int32(bytes, at: 348, order: byteOrder))
        let affine = makeAffine(
            qformCode: qformCode,
            sformCode: sformCode,
            quaternB: ByteDecoder.float64(bytes, at: 352, order: byteOrder),
            quaternC: ByteDecoder.float64(bytes, at: 360, order: byteOrder),
            quaternD: ByteDecoder.float64(bytes, at: 368, order: byteOrder),
            offsets: [376, 384, 392].map { ByteDecoder.float64(bytes, at: $0, order: byteOrder) },
            pixdim: pixdim,
            srows: [400, 432, 464].map { row in
                stride(from: row, to: row + 32, by: 8).map {
                    ByteDecoder.float64(bytes, at: $0, order: byteOrder)
                }
            }
        )
        let units = decodeUnits(Int(ByteDecoder.int32(bytes, at: 500, order: byteOrder)))
        return NIfTIHeader(
            version: .two,
            byteOrder: byteOrder,
            dimensions: dimensions,
            pixelDimensions: pixdim,
            dataType: datatype,
            bitpix: bitpix,
            voxelOffset: ByteDecoder.int64(bytes, at: 168, order: byteOrder),
            scaleSlope: ByteDecoder.float64(bytes, at: 176, order: byteOrder),
            scaleIntercept: ByteDecoder.float64(bytes, at: 184, order: byteOrder),
            calibrationMinimum: finiteOrNil(ByteDecoder.float64(bytes, at: 200, order: byteOrder)),
            calibrationMaximum: finiteOrNil(ByteDecoder.float64(bytes, at: 192, order: byteOrder)),
            spatialUnit: units.spatial,
            temporalUnit: units.temporal,
            qformCode: qformCode,
            sformCode: sformCode,
            intentCode: Int(ByteDecoder.int32(bytes, at: 504, order: byteOrder)),
            intentName: ByteDecoder.optionalString(bytes, at: 508, count: 16),
            description: ByteDecoder.optionalString(bytes, at: 240, count: 80),
            affine: affine,
            magic: magic
        )
    }

    private static func makeAffine(
        qformCode: Int,
        sformCode: Int,
        quaternB: Double,
        quaternC: Double,
        quaternD: Double,
        offsets: [Double],
        pixdim: [Double],
        srows: [[Double]]
    ) -> Affine? {
        if sformCode > 0,
           srows.count == 3,
           srows.flatMap({ $0 }).allSatisfy(\.isFinite),
           srows.flatMap({ Array($0.prefix(3)) }).contains(where: { abs($0) > 1e-12 }) {
            return Affine(rows: srows, source: "sform")
        }
        guard qformCode > 0,
              [quaternB, quaternC, quaternD].allSatisfy(\.isFinite),
              offsets.count == 3,
              pixdim.count >= 4 else { return nil }

        let b = quaternB, c = quaternC, d = quaternD
        let sum = b * b + c * c + d * d
        let a: Double
        if sum <= 1 { a = sqrt(max(0, 1 - sum)) }
        else {
            let scale = 1 / sqrt(sum)
            return quaternionAffine(
                a: 0, b: b * scale, c: c * scale, d: d * scale,
                offsets: offsets, pixdim: pixdim
            )
        }
        return quaternionAffine(a: a, b: b, c: c, d: d, offsets: offsets, pixdim: pixdim)
    }

    private static func quaternionAffine(
        a: Double, b: Double, c: Double, d: Double,
        offsets: [Double], pixdim: [Double]
    ) -> Affine {
        let dx = abs(pixdim[1]) > 0 ? abs(pixdim[1]) : 1
        let dy = abs(pixdim[2]) > 0 ? abs(pixdim[2]) : 1
        let dzBase = abs(pixdim[3]) > 0 ? abs(pixdim[3]) : 1
        let dz = (pixdim[0] < 0 ? -1.0 : 1.0) * dzBase
        let rotation = [
            [a*a+b*b-c*c-d*d, 2*b*c-2*a*d, 2*b*d+2*a*c],
            [2*b*c+2*a*d, a*a+c*c-b*b-d*d, 2*c*d-2*a*b],
            [2*b*d-2*a*c, 2*c*d+2*a*b, a*a+d*d-c*c-b*b]
        ]
        let scales = [dx, dy, dz]
        let rows = (0..<3).map { row in
            (0..<3).map { rotation[row][$0] * scales[$0] } + [offsets[row]]
        }
        return Affine(rows: rows, source: "qform")
    }

    private static func decodeUnits(_ raw: Int) -> (spatial: String?, temporal: String?) {
        let spatial: String?
        switch raw & 0x07 {
        case 1: spatial = "m"
        case 2: spatial = "mm"
        case 3: spatial = "µm"
        default: spatial = nil
        }
        let temporal: String?
        switch raw & 0x38 {
        case 8: temporal = "s"
        case 16: temporal = "ms"
        case 24: temporal = "µs"
        case 32: temporal = "Hz"
        case 40: temporal = "ppm"
        case 48: temporal = "rad/s"
        default: temporal = nil
        }
        return (spatial, temporal)
    }

    private static func finiteOrNil(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }
}

nonisolated enum NIfTIReadError: LocalizedError, Sendable {
    case unsupportedFile(URL)
    case cannotOpen(URL)
    case truncatedHeader
    case invalidHeaderSize(Int)
    case invalidMagic(String)
    case pairedFileUnsupported
    case invalidDimensions([Int64])
    case unsupportedDataType(Int)
    case unsupportedScalarType(String)
    case invalidBitpix(expected: Int, actual: Int)
    case invalidVoxelOffset(Int64)
    case previewTooLarge
    case truncatedVoxelData
    case invalidGzip(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url): return "\(url.lastPathComponent) is not a supported NIfTI file."
        case .cannotOpen(let url): return "Could not open \(url.lastPathComponent)."
        case .truncatedHeader: return "The NIfTI header is truncated."
        case .invalidHeaderSize(let size): return "Invalid NIfTI header size (\(size))."
        case .invalidMagic(let magic): return "Invalid NIfTI magic value (\(magic.debugDescription))."
        case .pairedFileUnsupported: return "Paired NIfTI .hdr/.img datasets are not yet supported."
        case .invalidDimensions: return "The NIfTI dimensions are invalid."
        case .unsupportedDataType(let code): return "Unsupported NIfTI datatype code \(code)."
        case .unsupportedScalarType(let name): return "\(name) voxel data is not yet supported."
        case .invalidBitpix(let expected, let actual): return "NIfTI bitpix is \(actual); datatype requires \(expected)."
        case .invalidVoxelOffset(let offset): return "Invalid NIfTI voxel offset \(offset)."
        case .previewTooLarge: return "The volume dimensions are too large to preview safely."
        case .truncatedVoxelData: return "The NIfTI voxel data is truncated."
        case .invalidGzip(let reason): return "Invalid gzip stream: \(reason)"
        }
    }
}

private nonisolated enum ByteDecoder {
    static func uint16(_ bytes: [UInt8], at offset: Int, order: NIfTIHeader.ByteOrder) -> UInt16 {
        let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        return order == .littleEndian ? value : value.byteSwapped
    }

    static func int16(_ bytes: [UInt8], at offset: Int, order: NIfTIHeader.ByteOrder) -> Int16 {
        Int16(bitPattern: uint16(bytes, at: offset, order: order))
    }

    static func uint32(_ bytes: [UInt8], at offset: Int, order: NIfTIHeader.ByteOrder) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[offset + index]) << UInt32(index * 8) }
        return order == .littleEndian ? value : value.byteSwapped
    }

    static func int32(_ bytes: [UInt8], at offset: Int, order: NIfTIHeader.ByteOrder) -> Int32 {
        Int32(bitPattern: uint32(bytes, at: offset, order: order))
    }

    static func uint64(_ bytes: [UInt8], at offset: Int, order: NIfTIHeader.ByteOrder) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[offset + index]) << UInt64(index * 8) }
        return order == .littleEndian ? value : value.byteSwapped
    }

    static func int64(_ bytes: [UInt8], at offset: Int, order: NIfTIHeader.ByteOrder) -> Int64 {
        Int64(bitPattern: uint64(bytes, at: offset, order: order))
    }

    static func float32(_ bytes: [UInt8], at offset: Int, order: NIfTIHeader.ByteOrder) -> Float {
        Float(bitPattern: uint32(bytes, at: offset, order: order))
    }

    static func float64(_ bytes: [UInt8], at offset: Int, order: NIfTIHeader.ByteOrder) -> Double {
        Double(bitPattern: uint64(bytes, at: offset, order: order))
    }

    static func string(_ bytes: [UInt8], at offset: Int, count: Int) -> String {
        let field = bytes[offset..<min(offset + count, bytes.count)]
        let prefix = field.prefix { $0 != 0 }
        return String(decoding: prefix, as: UTF8.self)
    }

    static func optionalString(_ bytes: [UInt8], at offset: Int, count: Int) -> String? {
        let value = string(bytes, at: offset, count: count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
