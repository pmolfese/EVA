//
//  CIFTIQuickLookReaderTests.swift
//  EVATests
//

import CoreGraphics
import Foundation
import Testing
@testable import EVA

struct CIFTIQuickLookReaderTests {

    @Test func readsDenseScalarContainerXMLMappingsAndMatrix() throws {
        let xml = CIFTITestFixture.denseScalarXML(mapCount: 2, brainordinateCount: 5)
        let data = CIFTITestFixture.make(
            intent: 3006,
            dimensions: [2, 5],
            xml: xml,
            values: (0..<10).map(Double.init)
        )
        try withFixture(data, name: "task.dscalar.nii") { url in
            let model = try CIFTIQuickLookReader.read(from: url)
            #expect(model.header.version == .two)
            #expect(model.ciftiVersion == "2")
            #expect(model.fileKind == "Dense Scalar")
            #expect(model.matrixDimensions == [2, 5])
            #expect(model.sample.values == (0..<10).map(Double.init))
            #expect(model.mapping(for: 0)?.type == .scalars)
            #expect(model.mapping(for: 0)?.namedMaps.map(\.name) == ["Activation", "Myelin"])
            #expect(model.mapping(for: 1)?.type == .brainModels)
            #expect(model.structureNames == ["Cortex Left", "Thalamus Left"])
            #expect(model.metadata["Description"] == "Synthetic dense scalar")
        }
    }

    @Test func samplesLargeTimeSeriesMatrixWithoutRetainingItAll() throws {
        let columns = 600
        let rows = 300
        let xml = CIFTITestFixture.timeSeriesXML(seriesCount: columns, brainordinateCount: rows)
        let data = CIFTITestFixture.make(
            intent: 3002,
            dimensions: [columns, rows],
            xml: xml,
            values: (0..<(columns * rows)).map(Double.init)
        )
        try withFixture(data, name: "rest.dtseries.nii") { url in
            let model = try CIFTIQuickLookReader.read(from: url)
            #expect(model.fileKind == "Dense Data Series")
            #expect(model.sample.width == 512)
            #expect(model.sample.height == 192)
            #expect(model.sample.values.count == 512 * 192)
            #expect(model.mapping(for: 0)?.seriesStep == 0.72)
            #expect(model.mapping(for: 0)?.seriesUnit == "SECOND")
            #expect(model.sample.values.first == 0)
            #expect(model.sample.values.last == Double(columns * rows - 1))
        }
    }

    @Test func readsDenseLabelsAndUsesDeclaredColors() throws {
        let xml = CIFTITestFixture.denseLabelXML(brainordinateCount: 4)
        let data = CIFTITestFixture.make(
            intent: 3007,
            dimensions: [1, 4],
            xml: xml,
            values: [0, 1, 1, 2],
            dataType: .int16
        )
        try withFixture(data, name: "atlas.dlabel.nii") { url in
            let model = try CIFTIQuickLookReader.read(from: url)
            #expect(model.isLabelData)
            #expect(model.labelMaps.first?.name == "Atlas")
            #expect(model.labelMaps.first?.labels.map(\.name) == ["Unknown", "Visual", "Motor"])
            let image = try #require(CIFTIMatrixRenderer.image(for: model))
            #expect(image.width == 1)
            #expect(image.height == 4)
        }
    }

    @Test func rejectsMappingLengthMismatch() throws {
        let xml = CIFTITestFixture.denseScalarXML(mapCount: 2, brainordinateCount: 4)
        let data = CIFTITestFixture.make(
            intent: 3006,
            dimensions: [2, 5],
            xml: xml,
            values: (0..<10).map(Double.init)
        )
        try withFixture(data, name: "bad.dscalar.nii") { url in
            #expect(throws: CIFTIReadError.self) {
                try CIFTIQuickLookReader.read(from: url)
            }
        }
    }

    @Test func thumbnailRendererDrawsIntoBitmapContext() throws {
        let xml = CIFTITestFixture.denseScalarXML(mapCount: 2, brainordinateCount: 5)
        let data = CIFTITestFixture.make(
            intent: 3006,
            dimensions: [2, 5],
            xml: xml,
            values: (0..<10).map(Double.init)
        )
        try withFixture(data, name: "task.dscalar.nii") { url in
            let model = try CIFTIQuickLookReader.read(from: url)
            let context = try #require(CGContext(
                data: nil,
                width: 160,
                height: 160,
                bitsPerComponent: 8,
                bytesPerRow: 160 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            CIFTIThumbnailRenderer(model: model).draw(
                in: context, size: CGSize(width: 160, height: 160)
            )
            #expect(context.makeImage() != nil)
        }
    }

    @Test func routerChoosesCIFTIBeforeGenericNIfTI() {
        #expect(EVAPreviewFormat.identify(URL(fileURLWithPath: "task.dscalar.nii")) == .cifti)
        #expect(EVAPreviewFormat.identify(URL(fileURLWithPath: "rest.dtseries.nii")) == .cifti)
        #expect(EVAPreviewFormat.identify(URL(fileURLWithPath: "volume.nii")) == .nifti)
    }

    private func withFixture(_ data: Data, name: String, body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-cifti-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        try body(url)
    }
}

private enum CIFTITestFixture {
    enum DataType {
        case float32
        case int16

        var code: UInt16 { self == .float32 ? 16 : 4 }
        var bits: UInt16 { self == .float32 ? 32 : 16 }
    }

    static func denseScalarXML(mapCount: Int, brainordinateCount: Int) -> String {
        let firstCount = min(3, brainordinateCount)
        let secondCount = brainordinateCount - firstCount
        let secondModel = secondCount > 0 ? """
            <BrainModel IndexOffset="\(firstCount)" IndexCount="\(secondCount)" ModelType="CIFTI_MODEL_TYPE_VOXELS" BrainStructure="CIFTI_STRUCTURE_THALAMUS_LEFT">
              <VoxelIndicesIJK>0 0 0 1 0 0</VoxelIndicesIJK>
            </BrainModel>
            """ : ""
        let names = ["Activation", "Myelin"] + (2..<mapCount).map { "Map \($0 + 1)" }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <CIFTI Version="2"><Matrix>
          <MetaData><MD><Name>Description</Name><Value>Synthetic dense scalar</Value></MD></MetaData>
          <MatrixIndicesMap AppliesToMatrixDimension="0" IndicesMapToDataType="CIFTI_INDEX_TYPE_SCALARS">
            \(names.prefix(mapCount).map { "<NamedMap><MapName>\($0)</MapName></NamedMap>" }.joined())
          </MatrixIndicesMap>
          <MatrixIndicesMap AppliesToMatrixDimension="1" IndicesMapToDataType="CIFTI_INDEX_TYPE_BRAIN_MODELS">
            <BrainModel IndexOffset="0" IndexCount="\(firstCount)" ModelType="CIFTI_MODEL_TYPE_SURFACE" BrainStructure="CIFTI_STRUCTURE_CORTEX_LEFT" SurfaceNumberOfVertices="32492">
              <VertexIndices>0 1 2</VertexIndices>
            </BrainModel>
            \(secondModel)
          </MatrixIndicesMap>
        </Matrix></CIFTI>
        """
    }

    static func timeSeriesXML(seriesCount: Int, brainordinateCount: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <CIFTI Version="2"><Matrix>
          <MatrixIndicesMap AppliesToMatrixDimension="0" IndicesMapToDataType="CIFTI_INDEX_TYPE_SERIES" NumberOfSeriesPoints="\(seriesCount)" SeriesStart="0" SeriesStep="72" SeriesExponent="-2" SeriesUnit="SECOND"/>
          <MatrixIndicesMap AppliesToMatrixDimension="1" IndicesMapToDataType="CIFTI_INDEX_TYPE_BRAIN_MODELS">
            <BrainModel IndexOffset="0" IndexCount="\(brainordinateCount)" ModelType="CIFTI_MODEL_TYPE_SURFACE" BrainStructure="CIFTI_STRUCTURE_CORTEX_LEFT" SurfaceNumberOfVertices="\(brainordinateCount)"><VertexIndices>0</VertexIndices></BrainModel>
          </MatrixIndicesMap>
        </Matrix></CIFTI>
        """
    }

    static func denseLabelXML(brainordinateCount: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <CIFTI Version="2"><Matrix>
          <MatrixIndicesMap AppliesToMatrixDimension="0" IndicesMapToDataType="CIFTI_INDEX_TYPE_LABELS">
            <NamedMap><MapName>Atlas</MapName><LabelTable>
              <Label Key="0" Red="0.1" Green="0.1" Blue="0.1" Alpha="1">Unknown</Label>
              <Label Key="1" Red="0.1" Green="0.5" Blue="0.9" Alpha="1">Visual</Label>
              <Label Key="2" Red="0.9" Green="0.3" Blue="0.1" Alpha="1">Motor</Label>
            </LabelTable></NamedMap>
          </MatrixIndicesMap>
          <MatrixIndicesMap AppliesToMatrixDimension="1" IndicesMapToDataType="CIFTI_INDEX_TYPE_BRAIN_MODELS">
            <BrainModel IndexOffset="0" IndexCount="\(brainordinateCount)" ModelType="CIFTI_MODEL_TYPE_SURFACE" BrainStructure="CIFTI_STRUCTURE_CORTEX_LEFT" SurfaceNumberOfVertices="\(brainordinateCount)"><VertexIndices>0 1 2 3</VertexIndices></BrainModel>
          </MatrixIndicesMap>
        </Matrix></CIFTI>
        """
    }

    static func make(
        intent: Int,
        dimensions: [Int],
        xml: String,
        values: [Double],
        dataType: DataType = .float32
    ) -> Data {
        precondition((2...3).contains(dimensions.count))
        precondition(dimensions.reduce(1, *) == values.count)
        let xmlBytes = Data(xml.utf8)
        let extensionSize = ((8 + xmlBytes.count + 15) / 16) * 16
        let voxelOffset = 544 + extensionSize
        var result = Data(repeating: 0, count: voxelOffset)

        writeUInt32(540, into: &result, at: 0)
        result.replaceSubrange(4..<12, with: Data([0x6e, 0x2b, 0x32, 0, 13, 10, 26, 10]))
        writeUInt16(dataType.code, into: &result, at: 12)
        writeUInt16(dataType.bits, into: &result, at: 14)
        writeUInt64(UInt64(4 + dimensions.count), into: &result, at: 16)
        for index in 1...4 { writeUInt64(1, into: &result, at: 16 + index * 8) }
        for (index, dimension) in dimensions.enumerated() {
            writeUInt64(UInt64(dimension), into: &result, at: 16 + (index + 5) * 8)
        }
        writeUInt64(UInt64(voxelOffset), into: &result, at: 168)
        writeUInt64(1.0.bitPattern, into: &result, at: 176)
        writeUInt32(UInt32(intent), into: &result, at: 504)
        result[540] = 1
        writeUInt32(UInt32(extensionSize), into: &result, at: 544)
        writeUInt32(32, into: &result, at: 548)
        result.replaceSubrange(552..<(552 + xmlBytes.count), with: xmlBytes)

        for value in values {
            switch dataType {
            case .float32: appendUInt32(Float(value).bitPattern, to: &result)
            case .int16: appendUInt16(UInt16(bitPattern: Int16(value)), to: &result)
            }
        }
        return result
    }

    private static func writeUInt16(_ value: UInt16, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    private static func writeUInt32(_ value: UInt32, into data: inout Data, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8((value >> UInt32(index * 8)) & 0xff) }
    }

    private static func writeUInt64(_ value: UInt64, into data: inout Data, at offset: Int) {
        for index in 0..<8 { data[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xff) }
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        for index in 0..<4 { data.append(UInt8((value >> UInt32(index * 8)) & 0xff)) }
    }
}
