//
//  MGHQuickLookReaderTests.swift
//  EVATests
//

import Compression
import Foundation
import Testing
@testable import EVA

struct MGHQuickLookReaderTests {
    @Test func readsBigEndianMGHAndScannerRASGeometry() throws {
        let fixture = MGHFixture.make(type: .int16, dimensions: [4, 3, 2, 1])
        try withFixture(fixture, extension: "mgh") { url in
            let model = try MGHQuickLookReader.read(from: url)
            #expect(model.header.version == 1)
            #expect(model.header.dataType == .int16)
            #expect(model.header.voxelSizes == [1, 2, 3])
            #expect(model.header.centerRAS == [10, 20, 30])
            #expect(model.header.affine?.rows[0][0] == 1)
            #expect(model.header.affine?.rows[1][1] == 2)
            #expect(model.header.affine?.rows[2][2] == 3)
            #expect(model.slices[0].values == (12..<24).map(Double.init))
            #expect(model.slices[1].topLabel == "S")
        }
    }

    @Test func readsMGZAndStopsAfterFirstFrame() throws {
        let plain = MGHFixture.make(type: .float32, dimensions: [3, 2, 2, 2])
        let compressed = try MGHFixture.gzip(plain)
        try withFixture(compressed, extension: "mgz") { url in
            let model = try MGHQuickLookReader.read(from: url)
            #expect(model.isCompressed)
            #expect(model.header.frameCount == 2)
            #expect(model.slices[0].values == (6..<12).map(Double.init))
        }
    }

    @Test func readsMghGzipSuffixAndRoutesAllNames() throws {
        let compressed = try MGHFixture.gzip(MGHFixture.make(type: .uint8, dimensions: [2, 2, 2, 1]))
        try withFixture(compressed, extension: "mgh.gz") { url in
            let model = try MGHQuickLookReader.read(from: url)
            #expect(model.slices.count == 3)
        }
        #expect(EVAPreviewFormat.identify(URL(fileURLWithPath: "brain.mgh")) == .mgh)
        #expect(EVAPreviewFormat.identify(URL(fileURLWithPath: "brain.mgz")) == .mgh)
        #expect(EVAPreviewFormat.identify(URL(fileURLWithPath: "brain.mgh.gz")) == .mgh)
    }

    @Test func rejectsUnsupportedDatatype() throws {
        var fixture = MGHFixture.make(type: .int16, dimensions: [2, 2, 2, 1])
        MGHFixture.writeInt32(99, into: &fixture, at: 20)
        try withFixture(fixture, extension: "mgh") { url in
            #expect(throws: MGHReadError.self) { try MGHQuickLookReader.read(from: url) }
        }
    }

    private func withFixture(_ data: Data, extension suffix: String, body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-mgh-\(UUID().uuidString).\(suffix)")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}

private enum MGHFixture {
    enum DataType: Int32 { case uint8 = 0, int32 = 1, float32 = 3, int16 = 4 }

    static func make(type: DataType, dimensions: [Int]) -> Data {
        precondition(dimensions.count == 4)
        var data = Data(repeating: 0, count: MGHHeader.byteCount)
        writeInt32(1, into: &data, at: 0)
        for (index, value) in dimensions.enumerated() { writeInt32(Int32(value), into: &data, at: 4 + index * 4) }
        writeInt32(type.rawValue, into: &data, at: 20)
        writeInt16(1, into: &data, at: 28)
        [Float(1), 2, 3].enumerated().forEach { writeFloat32($0.element, into: &data, at: 30 + $0.offset * 4) }
        let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        identity.enumerated().forEach { writeFloat32($0.element, into: &data, at: 42 + $0.offset * 4) }
        [Float(10), 20, 30].enumerated().forEach { writeFloat32($0.element, into: &data, at: 78 + $0.offset * 4) }
        for value in 0..<dimensions.reduce(1, *) {
            switch type {
            case .uint8: data.append(UInt8(truncatingIfNeeded: value))
            case .int16: appendUInt16(UInt16(bitPattern: Int16(truncatingIfNeeded: value)), to: &data)
            case .int32: appendUInt32(UInt32(bitPattern: Int32(value)), to: &data)
            case .float32: appendUInt32(Float(value).bitPattern, to: &data)
            }
        }
        return data
    }

    static func gzip(_ input: Data) throws -> Data {
        var payload = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { chunk in
            if let chunk { payload.append(chunk) }
        }
        try filter.write(input); try filter.finalize()
        var result = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255])
        result.append(payload); result.append(Data(repeating: 0, count: 8))
        return result
    }

    static func writeInt16(_ value: Int16, into data: inout Data, at offset: Int) {
        let bits = UInt16(bitPattern: value)
        data.replaceSubrange(offset..<(offset + 2), with: [UInt8(bits >> 8), UInt8(bits & 0xff)])
    }
    static func writeInt32(_ value: Int32, into data: inout Data, at offset: Int) {
        let bits = UInt32(bitPattern: value)
        data.replaceSubrange(offset..<(offset + 4), with: bytes(bits))
    }
    private static func writeFloat32(_ value: Float, into data: inout Data, at offset: Int) {
        data.replaceSubrange(offset..<(offset + 4), with: bytes(value.bitPattern))
    }
    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xff)])
    }
    private static func appendUInt32(_ value: UInt32, to data: inout Data) { data.append(contentsOf: bytes(value)) }
    private static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    }
}
