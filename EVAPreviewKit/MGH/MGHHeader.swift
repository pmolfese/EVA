//
//  MGHHeader.swift
//  EVAPreviewKit
//
//  Pure-Swift decoding of FreeSurfer's fixed-size, big-endian MGH header.
//

import Foundation

nonisolated struct MGHHeader: Sendable {
    static let byteCount = 284

    enum DataType: Int32, Sendable {
        case uint8 = 0
        case int32 = 1
        case float32 = 3
        case int16 = 4

        var displayName: String {
            switch self {
            case .uint8: return "UInt8"
            case .int16: return "Int16"
            case .int32: return "Int32"
            case .float32: return "Float32"
            }
        }

        var niftiType: NIfTIHeader.DataType {
            switch self {
            case .uint8: return .uint8
            case .int16: return .int16
            case .int32: return .int32
            case .float32: return .float32
            }
        }

        var bytesPerVoxel: Int { niftiType.supportedScalarBitCount! / 8 }
    }

    let version: Int32
    let width: Int
    let height: Int
    let depth: Int
    let frameCount: Int
    let dataType: DataType
    let degreesOfFreedom: Int32
    let hasRASGeometry: Bool
    let voxelSizes: [Double]
    let centerRAS: [Double]?
    let affine: NIfTIHeader.Affine?

    static func decode(_ data: Data) throws -> MGHHeader {
        guard data.count >= byteCount else { throw MGHReadError.truncatedHeader }
        let bytes = [UInt8](data.prefix(byteCount))
        let version = int32(bytes, at: 0)
        guard version == 1 else { throw MGHReadError.unsupportedVersion(version) }

        let rawDimensions = [4, 8, 12, 16].map { Int(int32(bytes, at: $0)) }
        guard rawDimensions.allSatisfy({ $0 > 0 }) else {
            throw MGHReadError.invalidDimensions(rawDimensions)
        }
        guard let dataType = DataType(rawValue: int32(bytes, at: 20)) else {
            throw MGHReadError.unsupportedDataType(int32(bytes, at: 20))
        }

        let goodRAS = int16(bytes, at: 28) != 0
        let voxelSizes: [Double]
        let center: [Double]?
        let affine: NIfTIHeader.Affine?
        if goodRAS {
            voxelSizes = [30, 34, 38].map { Double(float32(bytes, at: $0)) }
            let directionCosines = stride(from: 42, to: 78, by: 4).map {
                Double(float32(bytes, at: $0))
            }
            let decodedCenter = [78, 82, 86].map { Double(float32(bytes, at: $0)) }
            guard voxelSizes.allSatisfy({ $0.isFinite && $0 > 0 }),
                  directionCosines.allSatisfy(\.isFinite),
                  decodedCenter.allSatisfy(\.isFinite) else {
                throw MGHReadError.invalidRASGeometry
            }

            // Mdc is stored as x_R,x_A,x_S,y_R,...: three voxel-axis columns.
            var rows = Array(repeating: Array(repeating: 0.0, count: 4), count: 3)
            let halfDimensions = rawDimensions.prefix(3).map { Double($0) / 2 }
            for worldAxis in 0..<3 {
                for voxelAxis in 0..<3 {
                    rows[worldAxis][voxelAxis] = directionCosines[voxelAxis * 3 + worldAxis]
                        * voxelSizes[voxelAxis]
                }
                rows[worldAxis][3] = decodedCenter[worldAxis]
                    - (0..<3).reduce(0) { $0 + rows[worldAxis][$1] * halfDimensions[$1] }
            }
            center = decodedCenter
            affine = NIfTIHeader.Affine(rows: rows, source: "FreeSurfer scanner RAS")
        } else {
            voxelSizes = [1, 1, 1]
            center = nil
            affine = nil
        }

        return MGHHeader(
            version: version,
            width: rawDimensions[0], height: rawDimensions[1], depth: rawDimensions[2],
            frameCount: rawDimensions[3], dataType: dataType,
            degreesOfFreedom: int32(bytes, at: 24), hasRASGeometry: goodRAS,
            voxelSizes: voxelSizes, centerRAS: center, affine: affine
        )
    }

    private static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func int16(_ bytes: [UInt8], at offset: Int) -> Int16 {
        Int16(bitPattern: uint16(bytes, at: offset))
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func int32(_ bytes: [UInt8], at offset: Int) -> Int32 {
        Int32(bitPattern: uint32(bytes, at: offset))
    }

    private static func float32(_ bytes: [UInt8], at offset: Int) -> Float {
        Float(bitPattern: uint32(bytes, at: offset))
    }
}

nonisolated enum MGHReadError: LocalizedError, Sendable {
    case unsupportedFile(URL)
    case cannotOpen(URL)
    case invalidGzip(String)
    case truncatedHeader
    case unsupportedVersion(Int32)
    case invalidDimensions([Int])
    case unsupportedDataType(Int32)
    case invalidRASGeometry
    case previewTooLarge
    case truncatedVoxelData

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url): return "\(url.lastPathComponent) is not an MGH or MGZ file."
        case .cannotOpen(let url): return "Could not open \(url.lastPathComponent)."
        case .invalidGzip(let reason): return "Invalid MGZ gzip stream: \(reason)"
        case .truncatedHeader: return "The MGH header is truncated."
        case .unsupportedVersion(let version): return "Unsupported MGH version \(version)."
        case .invalidDimensions: return "The MGH dimensions are invalid."
        case .unsupportedDataType(let code): return "Unsupported MGH datatype code \(code)."
        case .invalidRASGeometry: return "The MGH scanner-RAS geometry is invalid."
        case .previewTooLarge: return "The MGH volume is too large to preview safely."
        case .truncatedVoxelData: return "The MGH voxel data is truncated."
        }
    }
}
