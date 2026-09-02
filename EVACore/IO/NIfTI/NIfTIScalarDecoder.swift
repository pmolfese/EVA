//
//  NIfTIScalarDecoder.swift
//  EVAPreviewKit
//
//  Shared scalar decoding for NIfTI volumes and CIFTI matrices. Keeping this
//  at the container layer prevents each format interpretation from growing a
//  subtly different endian/scaling implementation.
//

import Foundation

nonisolated enum NIfTIScalarDecoder {
    static func value(
        from bytes: UnsafeRawBufferPointer,
        at offset: Int,
        type: NIfTIHeader.DataType,
        byteOrder: NIfTIHeader.ByteOrder
    ) -> Double {
        switch type {
        case .uint8: return Double(bytes[offset])
        case .int8: return Double(Int8(bitPattern: bytes[offset]))
        case .int16: return Double(Int16(bitPattern: uint16(bytes, offset, byteOrder)))
        case .uint16: return Double(uint16(bytes, offset, byteOrder))
        case .int32: return Double(Int32(bitPattern: uint32(bytes, offset, byteOrder)))
        case .uint32: return Double(uint32(bytes, offset, byteOrder))
        case .int64: return Double(Int64(bitPattern: uint64(bytes, offset, byteOrder)))
        case .uint64: return Double(uint64(bytes, offset, byteOrder))
        case .float32: return Double(Float(bitPattern: uint32(bytes, offset, byteOrder)))
        case .float64: return Double(bitPattern: uint64(bytes, offset, byteOrder))
        default: return .nan
        }
    }

    private static func uint16(
        _ bytes: UnsafeRawBufferPointer,
        _ offset: Int,
        _ order: NIfTIHeader.ByteOrder
    ) -> UInt16 {
        let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        return order == .littleEndian ? value : value.byteSwapped
    }

    private static func uint32(
        _ bytes: UnsafeRawBufferPointer,
        _ offset: Int,
        _ order: NIfTIHeader.ByteOrder
    ) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[offset + index]) << UInt32(index * 8) }
        return order == .littleEndian ? value : value.byteSwapped
    }

    private static func uint64(
        _ bytes: UnsafeRawBufferPointer,
        _ offset: Int,
        _ order: NIfTIHeader.ByteOrder
    ) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[offset + index]) << UInt64(index * 8) }
        return order == .littleEndian ? value : value.byteSwapped
    }
}
