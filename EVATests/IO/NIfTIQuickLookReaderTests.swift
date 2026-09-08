//
//  NIfTIQuickLookReaderTests.swift
//  EVATests
//
//  Tiny fixtures are assembled from the documented byte offsets so the tests
//  cover both header generations, both byte orders, gzip, scaling, center-plane
//  extraction, and malformed input without checking large binaries into git.
//

import Compression
import CoreGraphics
import Foundation
import Testing
@testable import EVA

struct NIfTIQuickLookReaderTests {

    @Test func readsNIfTI1Float32AndExtractsScaledCenterPlanes() throws {
        let fixture = NIfTITestFixture.make(
            version: .one,
            order: .littleEndian,
            type: .float32,
            dimensions: [4, 3, 2, 2],
            slope: 2,
            intercept: -1
        )
        try withFixture(fixture, extension: "nii") { url in
            let model = try NIfTIQuickLookReader.read(from: url)
            let expectedAxial: [Double] = (12..<24).map { Double($0 * 2 - 1) }
            let expectedCoronal: [Double] = [4, 5, 6, 7, 16, 17, 18, 19]
                .map { Double($0 * 2 - 1) }
            let expectedSagittal: [Double] = [2, 6, 10, 14, 18, 22]
                .map { Double($0 * 2 - 1) }
            #expect(model.header.version == .one)
            #expect(model.header.version.displayName == "NIfTI-1")
            #expect(model.header.volumeCount == 2)
            #expect(model.slices.count == 3)
            #expect(model.slices[0].values == expectedAxial)
            #expect(model.slices[1].values == expectedCoronal)
            #expect(model.slices[2].values == expectedSagittal)
            #expect(model.slices[0].leftLabel == "L")
            #expect(model.slices[0].rightLabel == "R")
        }
    }

    @Test func readsBigEndianInt16() throws {
        let fixture = NIfTITestFixture.make(
            version: .one,
            order: .bigEndian,
            type: .int16,
            dimensions: [3, 2, 2]
        )
        try withFixture(fixture, extension: "nii") { url in
            let model = try NIfTIQuickLookReader.read(from: url)
            #expect(model.header.byteOrder == .bigEndian)
            #expect(model.header.dataType == .int16)
            #expect(model.slices[0].values == (6..<12).map(Double.init))
        }
    }

    @Test func readsNIfTI2Float64() throws {
        let fixture = NIfTITestFixture.make(
            version: .two,
            order: .littleEndian,
            type: .float64,
            dimensions: [2, 3, 4]
        )
        try withFixture(fixture, extension: "nii") { url in
            let model = try NIfTIQuickLookReader.read(from: url)
            #expect(model.header.version == .two)
            #expect(model.header.dataType == .float64)
            #expect(model.header.width == 2)
            #expect(model.header.height == 3)
            #expect(model.header.depth == 4)
            #expect(model.header.affine?.source == "sform")
        }
    }

    @Test func readsGzipWithoutInflatingLaterVolumes() throws {
        let plain = NIfTITestFixture.make(
            version: .one,
            order: .littleEndian,
            type: .float32,
            dimensions: [4, 3, 2, 3]
        )
        let compressed = try NIfTITestFixture.gzip(plain)
        try withFixture(compressed, extension: "nii.gz") { url in
            let model = try NIfTIQuickLookReader.read(from: url)
            #expect(model.isCompressed)
            #expect(model.header.volumeCount == 3)
            #expect(model.slices[0].values == (12..<24).map(Double.init))
        }
    }

    @Test func keepsSuperiorAtTopWhenVoxelZRunsInferior() throws {
        let fixture = NIfTITestFixture.make(
            version: .one,
            order: .littleEndian,
            type: .float32,
            dimensions: [2, 2, 3],
            sform: [[1, 0, 0], [0, 2, 0], [0, 0, -3]]
        )
        try withFixture(fixture, extension: "nii") { url in
            let model = try NIfTIQuickLookReader.read(from: url)
            let coronal = model.slices[1]
            #expect(coronal.topLabel == "S")
            #expect(coronal.bottomLabel == "I")
            #expect(coronal.values == [10, 11, 6, 7, 2, 3])
        }
    }

    @Test func reorientsPermutedVoxelAxesIntoAnatomicalPlanes() throws {
        let fixture = NIfTITestFixture.make(
            version: .one,
            order: .littleEndian,
            type: .float32,
            dimensions: [2, 3, 4],
            sform: [[1, 0, 0], [0, 0, 3], [0, 2, 0]]
        )
        try withFixture(fixture, extension: "nii") { url in
            let model = try NIfTIQuickLookReader.read(from: url)
            let axial = model.slices[0]
            let coronal = model.slices[1]
            #expect(axial.width == 2)
            #expect(axial.height == 4)
            #expect(axial.values == [2, 3, 8, 9, 14, 15, 20, 21])
            #expect(coronal.width == 2)
            #expect(coronal.height == 3)
            #expect(coronal.values == Array(12..<18).map(Double.init))
            #expect(coronal.topLabel == "S")
            #expect(coronal.bottomLabel == "I")
        }
    }

    @Test func rejectsMismatchedBitpix() throws {
        var fixture = NIfTITestFixture.make(
            version: .one,
            order: .littleEndian,
            type: .float32,
            dimensions: [2, 2, 2]
        )
        NIfTITestFixture.writeUInt16(16, into: &fixture, at: 72, order: .littleEndian)
        try withFixture(fixture, extension: "nii") { url in
            #expect(throws: NIfTIReadError.self) {
                try NIfTIQuickLookReader.read(from: url)
            }
        }
    }

    @Test func rejectsTruncatedVoxelData() throws {
        let fixture = NIfTITestFixture.make(
            version: .one,
            order: .littleEndian,
            type: .float32,
            dimensions: [4, 4, 4]
        )
        try withFixture(Data(fixture.prefix(360)), extension: "nii") { url in
            #expect(throws: NIfTIReadError.self) {
                try NIfTIQuickLookReader.read(from: url)
            }
        }
    }

    @Test func sliceRendererProducesExpectedRasterShape() throws {
        let fixture = NIfTITestFixture.make(
            version: .one,
            order: .littleEndian,
            type: .float32,
            dimensions: [4, 3, 2]
        )
        try withFixture(fixture, extension: "nii") { url in
            let model = try NIfTIQuickLookReader.read(from: url)
            let image = try #require(NIfTISliceRenderer.image(
                for: model.slices[0],
                window: model.intensityWindow
            ))
            #expect(image.width == 4)
            #expect(image.height == 3)
        }
    }

    private func withFixture(
        _ data: Data,
        extension pathExtension: String,
        body: (URL) throws -> Void
    ) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-nifti-\(UUID().uuidString).\(pathExtension)")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}

private enum NIfTITestFixture {
    enum FixtureType {
        case int16
        case float32
        case float64

        var code: UInt16 {
            switch self {
            case .int16: return 4
            case .float32: return 16
            case .float64: return 64
            }
        }

        var bitCount: UInt16 {
            switch self {
            case .int16: return 16
            case .float32: return 32
            case .float64: return 64
            }
        }

        func append(_ value: Int, to data: inout Data, order: NIfTIHeader.ByteOrder) {
            switch self {
            case .int16:
                appendUInt16(UInt16(bitPattern: Int16(value)), to: &data, order: order)
            case .float32:
                appendUInt32(Float(value).bitPattern, to: &data, order: order)
            case .float64:
                appendUInt64(Double(value).bitPattern, to: &data, order: order)
            }
        }
    }

    static func make(
        version: NIfTIHeader.Version,
        order: NIfTIHeader.ByteOrder,
        type: FixtureType,
        dimensions: [Int],
        slope: Double = 1,
        intercept: Double = 0,
        sform: [[Double]]? = nil
    ) -> Data {
        precondition((3...4).contains(dimensions.count))
        let affine = sform ?? [[1, 0, 0], [0, 2, 0], [0, 0, 3]]
        precondition(affine.count == 3 && affine.allSatisfy { $0.count == 3 })
        var data = Data(repeating: 0, count: version.byteCount)
        switch version {
        case .one:
            writeUInt32(348, into: &data, at: 0, order: order)
            writeUInt16(UInt16(dimensions.count), into: &data, at: 40, order: order)
            for (index, value) in dimensions.enumerated() {
                writeUInt16(UInt16(value), into: &data, at: 42 + index * 2, order: order)
            }
            writeUInt16(type.code, into: &data, at: 70, order: order)
            writeUInt16(type.bitCount, into: &data, at: 72, order: order)
            for index in 0..<8 { writeFloat32(index == 0 ? 1 : Float(index), into: &data, at: 76 + index * 4, order: order) }
            writeFloat32(352, into: &data, at: 108, order: order)
            writeFloat32(Float(slope), into: &data, at: 112, order: order)
            writeFloat32(Float(intercept), into: &data, at: 116, order: order)
            data.replaceSubrange(148..<163, with: Data("EVA test volume".utf8))
            writeUInt16(1, into: &data, at: 254, order: order)
            for row in 0..<3 {
                for column in 0..<3 {
                    writeFloat32(Float(affine[row][column]), into: &data, at: 280 + row * 16 + column * 4, order: order)
                }
            }
            data.replaceSubrange(344..<348, with: [0x6e, 0x2b, 0x31, 0]) // n+1\0
            data.append(contentsOf: [0, 0, 0, 0])
        case .two:
            writeUInt32(540, into: &data, at: 0, order: order)
            data.replaceSubrange(4..<12, with: [0x6e, 0x2b, 0x32, 0, 0x0d, 0x0a, 0x1a, 0x0a])
            writeUInt16(type.code, into: &data, at: 12, order: order)
            writeUInt16(type.bitCount, into: &data, at: 14, order: order)
            writeUInt64(UInt64(dimensions.count), into: &data, at: 16, order: order)
            for (index, value) in dimensions.enumerated() {
                writeUInt64(UInt64(value), into: &data, at: 24 + index * 8, order: order)
            }
            for index in 0..<8 { writeFloat64(index == 0 ? 1 : Double(index), into: &data, at: 104 + index * 8, order: order) }
            writeUInt64(544, into: &data, at: 168, order: order)
            writeFloat64(slope, into: &data, at: 176, order: order)
            writeFloat64(intercept, into: &data, at: 184, order: order)
            data.replaceSubrange(240..<255, with: Data("EVA test volume".utf8))
            writeUInt32(1, into: &data, at: 348, order: order)
            for row in 0..<3 {
                for column in 0..<3 {
                    writeFloat64(affine[row][column], into: &data, at: 400 + row * 32 + column * 8, order: order)
                }
            }
            data.append(contentsOf: [0, 0, 0, 0])
        }

        let voxelCount = dimensions.reduce(1, *)
        for value in 0..<voxelCount { type.append(value, to: &data, order: order) }
        return data
    }

    static func gzip(_ input: Data) throws -> Data {
        var payload = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { chunk in
            if let chunk { payload.append(chunk) }
        }
        try filter.write(input)
        try filter.finalize()
        var result = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255])
        result.append(payload)
        result.append(Data(repeating: 0, count: 8)) // Reader stops at raw-DEFLATE end.
        return result
    }

    static func writeUInt16(
        _ value: UInt16,
        into data: inout Data,
        at offset: Int,
        order: NIfTIHeader.ByteOrder
    ) {
        let stored = order == .littleEndian ? value : value.byteSwapped
        data.replaceSubrange(offset..<(offset + 2), with: [UInt8(stored & 0xff), UInt8(stored >> 8)])
    }

    static func writeUInt32(
        _ value: UInt32,
        into data: inout Data,
        at offset: Int,
        order: NIfTIHeader.ByteOrder
    ) {
        let stored = order == .littleEndian ? value : value.byteSwapped
        data.replaceSubrange(offset..<(offset + 4), with: (0..<4).map { UInt8((stored >> UInt32($0 * 8)) & 0xff) })
    }

    static func writeUInt64(
        _ value: UInt64,
        into data: inout Data,
        at offset: Int,
        order: NIfTIHeader.ByteOrder
    ) {
        let stored = order == .littleEndian ? value : value.byteSwapped
        data.replaceSubrange(offset..<(offset + 8), with: (0..<8).map { UInt8((stored >> UInt64($0 * 8)) & 0xff) })
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data, order: NIfTIHeader.ByteOrder) {
        let stored = order == .littleEndian ? value : value.byteSwapped
        data.append(contentsOf: [UInt8(stored & 0xff), UInt8(stored >> 8)])
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data, order: NIfTIHeader.ByteOrder) {
        let stored = order == .littleEndian ? value : value.byteSwapped
        data.append(contentsOf: (0..<4).map { UInt8((stored >> UInt32($0 * 8)) & 0xff) })
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data, order: NIfTIHeader.ByteOrder) {
        let stored = order == .littleEndian ? value : value.byteSwapped
        data.append(contentsOf: (0..<8).map { UInt8((stored >> UInt64($0 * 8)) & 0xff) })
    }

    private static func writeFloat32(_ value: Float, into data: inout Data, at offset: Int, order: NIfTIHeader.ByteOrder) {
        writeUInt32(value.bitPattern, into: &data, at: offset, order: order)
    }

    private static func writeFloat64(_ value: Double, into data: inout Data, at offset: Int, order: NIfTIHeader.ByteOrder) {
        writeUInt64(value.bitPattern, into: &data, at: offset, order: order)
    }
}
