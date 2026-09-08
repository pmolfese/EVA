//
//  GIFTIQuickLookReaderTests.swift
//  EVATests
//

import Compression
import CoreGraphics
import Foundation
import SceneKit
import Testing
@testable import EVA

struct GIFTIQuickLookReaderTests {

    @Test func readsASCIISurfaceMetadataOverlayAndTransform() throws {
        let xml = GIFTITestFixture.surfaceXML(
            pointEncoding: .ascii,
            triangleEncoding: .ascii,
            includeOverlay: true,
            includeTransform: true
        )
        try withFixture(xml) { url in
            let model = try GIFTIQuickLookReader.read(from: url)
            #expect(model.version == "1.0")
            #expect(model.fileKind == "Surface")
            #expect(model.vertexCount == 4)
            #expect(model.triangleCount == 4)
            #expect(model.vertices[0] == GIFTIPoint(x: 10, y: 0, z: 0))
            #expect(model.vertices[1] == GIFTIPoint(x: 11, y: 0, z: 0))
            #expect(model.coordinateSpace == "NIFTI_XFORM_MNI_152")
            #expect(model.anatomicalStructure == "CortexLeft")
            #expect(model.overlay?.values == [0, 1, 2, 3])
        }
    }

    @Test func readsBigEndianColumnMajorBase64Surface() throws {
        let xml = GIFTITestFixture.surfaceXML(
            pointEncoding: .base64(order: .bigEndian, indexing: .columnMajor),
            triangleEncoding: .base64(order: .bigEndian, indexing: .columnMajor)
        )
        try withFixture(xml) { url in
            let model = try GIFTIQuickLookReader.read(from: url)
            #expect(model.vertices == GIFTITestFixture.points)
            #expect(model.triangles == GIFTITestFixture.triangles)
        }
    }

    @Test func readsZlibBase64Surface() throws {
        let xml = GIFTITestFixture.surfaceXML(
            pointEncoding: .zlibBase64,
            triangleEncoding: .zlibBase64
        )
        try withFixture(xml) { url in
            let model = try GIFTIQuickLookReader.read(from: url)
            #expect(model.vertexCount == 4)
            #expect(model.triangleCount == 4)
        }
    }

    @Test func readsSameDirectoryExternalBinary() throws {
        try withTemporaryDirectory { directory in
            var binary = GIFTITestFixture.pointBytes(order: .littleEndian, indexing: .rowMajor)
            let triangleOffset = binary.count
            binary.append(GIFTITestFixture.triangleBytes(order: .littleEndian, indexing: .rowMajor))
            try binary.write(to: directory.appendingPathComponent("surface.bin"))
            let xml = GIFTITestFixture.externalSurfaceXML(triangleOffset: triangleOffset)
            let url = directory.appendingPathComponent("surface.gii")
            try Data(xml.utf8).write(to: url)

            let model = try GIFTIQuickLookReader.read(from: url)
            #expect(model.vertices == GIFTITestFixture.points)
            #expect(model.triangles == GIFTITestFixture.triangles)
        }
    }

    @Test func readsMetricOnlyFile() throws {
        let xml = GIFTITestFixture.metricXML(values: [-2, -1, 0, 1, 3])
        try withFixture(xml) { url in
            let model = try GIFTIQuickLookReader.read(from: url)
            #expect(!model.hasRenderableGeometry)
            #expect(model.fileKind == "Shape")
            #expect(model.overlay?.name == "Cortical thickness")
            #expect(model.overlay?.values == [-2, -1, 0, 1, 3])
        }
    }

    @Test func readsEveryFunctionalDataset() throws {
        let xml = GIFTITestFixture.functionalXML(datasets: [
            [0, 1, 2, 3],
            [4, 5, 6, 7],
            [8, 9, 10, 11]
        ])
        try withFixture(xml) { url in
            let model = try GIFTIQuickLookReader.read(from: url)
            #expect(model.fileKind == "Time Series")
            #expect(model.overlays.count == 3)
            #expect(model.overlays[1].values == [4, 5, 6, 7])
            #expect(model.sharedOverlayWindow != nil)
            #expect(model.displayOverlay(at: 0)?.window == model.displayOverlay(at: 2)?.window)
        }
    }

    @Test func splitsFunctionalMatrixIntoNodeOverlays() throws {
        let xml = GIFTITestFixture.functionalMatrixXML()
        try withFixture(xml) { url in
            let model = try GIFTIQuickLookReader.read(from: url)
            #expect(model.overlays.count == 2)
            #expect(model.overlays[0].values == [1, 2, 3, 4])
            #expect(model.overlays[1].values == [10, 20, 30, 40])
        }
    }

    @Test func attachesMatchingSiblingSurfaceToFunctionalData() throws {
        try withTemporaryDirectory { directory in
            let functionalURL = directory.appendingPathComponent("lh.task.func.gii")
            let surfaceURL = directory.appendingPathComponent("lh.cortex.gii")
            try Data(GIFTITestFixture.functionalXML(datasets: [[0, 1, 2, 3]]).utf8).write(to: functionalURL)
            try Data(GIFTITestFixture.surfaceXML(pointEncoding: .ascii, triangleEncoding: .ascii).utf8).write(to: surfaceURL)

            let model = try GIFTIQuickLookReader.read(from: functionalURL)
            #expect(model.hasRenderableGeometry)
            #expect(model.vertexCount == 4)
            #expect(model.triangleCount == 4)
            #expect(model.fileKind == "Functional Overlay")
            #expect(model.companionSurfaceName == "lh.cortex.gii")
            #expect(model.overlay?.values == [0, 1, 2, 3])
        }
    }

    @Test func rejectsTriangleOutsideVertexArray() throws {
        let xml = GIFTITestFixture.surfaceXML(
            pointEncoding: .ascii,
            triangleEncoding: .ascii,
            triangleOverride: [0, 1, 99]
        )
        try withFixture(xml) { url in
            #expect(throws: GIFTIReadError.self) {
                try GIFTIQuickLookReader.read(from: url)
            }
        }
    }

    @Test func rejectsExternalPathTraversal() throws {
        let xml = GIFTITestFixture.externalSurfaceXML(triangleOffset: 48)
            .replacingOccurrences(of: "surface.bin", with: "../surface.bin")
        try withFixture(xml) { url in
            #expect(throws: GIFTIReadError.self) {
                try GIFTIQuickLookReader.read(from: url)
            }
        }
    }

    @Test func thumbnailRendererDrawsIntoBitmapContext() throws {
        let xml = GIFTITestFixture.surfaceXML(pointEncoding: .ascii, triangleEncoding: .ascii)
        try withFixture(xml) { url in
            let model = try GIFTIQuickLookReader.read(from: url)
            let context = try #require(CGContext(
                data: nil,
                width: 160,
                height: 160,
                bitsPerComponent: 8,
                bytesPerRow: 160 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            GIFTIThumbnailRenderer(model: model).draw(
                in: context,
                size: CGSize(width: 160, height: 160)
            )
            #expect(context.makeImage() != nil)
        }
    }

    @Test func sceneUsesSmoothNormalsAndCanDisplayNormalGlyphs() throws {
        let xml = GIFTITestFixture.surfaceXML(pointEncoding: .ascii, triangleEncoding: .ascii)
        try withFixture(xml) { url in
            let model = try GIFTIQuickLookReader.read(from: url)
            let bundle = GIFTISceneFactory.make(model: model, showsNormals: true)
            let geometries = bundle.scene.rootNode.childNodes.compactMap(\.geometry)
            let surface = try #require(geometries.first {
                $0.elements.contains(where: { $0.primitiveType == .triangles })
            })
            #expect(surface.sources.contains(where: { $0.semantic == .normal }))
            #expect(geometries.contains {
                $0.elements.contains(where: { $0.primitiveType == .line })
            })
        }
    }

    @Test func formatRouterRecognizesIntentSpecificNames() {
        #expect(EVAPreviewFormat.identify(URL(fileURLWithPath: "lh.pial.surf.gii")) == .gifti)
        #expect(EVAPreviewFormat.identify(URL(fileURLWithPath: "metric.func.gii")) == .gifti)
    }

    private func withFixture(_ xml: String, body: (URL) throws -> Void) throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("fixture.gii")
            try Data(xml.utf8).write(to: url)
            try body(url)
        }
    }

    private func withTemporaryDirectory(body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-gifti-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private enum GIFTITestFixture {
    enum ByteOrder { case littleEndian, bigEndian }
    enum Indexing { case rowMajor, columnMajor }
    enum Encoding {
        case ascii
        case base64(order: ByteOrder, indexing: Indexing)
        case zlibBase64
    }

    static let points = [
        GIFTIPoint(x: 0, y: 0, z: 0),
        GIFTIPoint(x: 1, y: 0, z: 0),
        GIFTIPoint(x: 0, y: 2, z: 0),
        GIFTIPoint(x: 0, y: 0, z: 3)
    ]
    static let triangles = [
        GIFTITriangle(a: 0, b: 1, c: 2),
        GIFTITriangle(a: 0, b: 1, c: 3),
        GIFTITriangle(a: 0, b: 2, c: 3),
        GIFTITriangle(a: 1, b: 2, c: 3)
    ]

    static func surfaceXML(
        pointEncoding: Encoding,
        triangleEncoding: Encoding,
        includeOverlay: Bool = false,
        includeTransform: Bool = false,
        triangleOverride: [Int32]? = nil
    ) -> String {
        let pointPayload = payload(forPoints: pointEncoding)
        let trianglePayload = payload(forTriangles: triangleEncoding, override: triangleOverride)
        let arrayCount = includeOverlay ? 3 : 2
        let transform = includeTransform ? """
            <CoordinateSystemTransformMatrix>
              <DataSpace>NIFTI_XFORM_SCANNER_ANAT</DataSpace>
              <TransformedSpace>NIFTI_XFORM_MNI_152</TransformedSpace>
              <MatrixData>1 0 0 10  0 1 0 0  0 0 1 0  0 0 0 1</MatrixData>
            </CoordinateSystemTransformMatrix>
            """ : ""
        let overlay = includeOverlay ? """
          <DataArray Intent="NIFTI_INTENT_SHAPE" DataType="NIFTI_TYPE_FLOAT32"
                     ArrayIndexingOrder="RowMajorOrder" Dimensionality="1" Dim0="4"
                     Encoding="ASCII" Endian="LittleEndian" ExternalFileName="" ExternalFileOffset="">
            <MetaData><MD><Name>Name</Name><Value>Sulcal depth</Value></MD></MetaData>
            <Data>0 1 2 3</Data>
          </DataArray>
        """ : ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <GIFTI Version="1.0" NumberOfDataArrays="\(arrayCount)">
          <MetaData><MD><Name>Description</Name><Value>Tetrahedron fixture</Value></MD></MetaData>
          <LabelTable/>
          <DataArray Intent="NIFTI_INTENT_POINTSET" DataType="NIFTI_TYPE_FLOAT32"
                     ArrayIndexingOrder="\(pointPayload.indexing)" Dimensionality="2" Dim0="4" Dim1="3"
                     Encoding="\(pointPayload.encoding)" Endian="\(pointPayload.endian)" ExternalFileName="" ExternalFileOffset="">
            <MetaData><MD><Name>AnatomicalStructurePrimary</Name><Value>CortexLeft</Value></MD></MetaData>
            \(transform)
            <Data>\(pointPayload.data)</Data>
          </DataArray>
          <DataArray Intent="NIFTI_INTENT_TRIANGLE" DataType="NIFTI_TYPE_INT32"
                     ArrayIndexingOrder="\(trianglePayload.indexing)" Dimensionality="2" Dim0="\(triangleOverride == nil ? 4 : 1)" Dim1="3"
                     Encoding="\(trianglePayload.encoding)" Endian="\(trianglePayload.endian)" ExternalFileName="" ExternalFileOffset="">
            <Data>\(trianglePayload.data)</Data>
          </DataArray>
          \(overlay)
        </GIFTI>
        """
    }

    static func metricXML(values: [Float]) -> String {
        let text = values.map { String($0) }.joined(separator: " ")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <GIFTI Version="1.0" NumberOfDataArrays="1">
          <DataArray Intent="NIFTI_INTENT_SHAPE" DataType="NIFTI_TYPE_FLOAT32"
                     ArrayIndexingOrder="RowMajorOrder" Dimensionality="1" Dim0="\(values.count)"
                     Encoding="ASCII" Endian="LittleEndian" ExternalFileName="" ExternalFileOffset="">
            <MetaData><MD><Name>Name</Name><Value>Cortical thickness</Value></MD></MetaData>
            <Data>\(text)</Data>
          </DataArray>
        </GIFTI>
        """
    }

    static func functionalXML(datasets: [[Float]]) -> String {
        let arrays = datasets.enumerated().map { index, values in
            let text = values.map { String($0) }.joined(separator: " ")
            return """
              <DataArray Intent="NIFTI_INTENT_TIME_SERIES" DataType="NIFTI_TYPE_FLOAT32"
                         ArrayIndexingOrder="RowMajorOrder" Dimensionality="1" Dim0="\(values.count)"
                         Encoding="ASCII" Endian="LittleEndian" ExternalFileName="" ExternalFileOffset="">
                <MetaData><MD><Name>Name</Name><Value>Frame \(index + 1)</Value></MD></MetaData>
                <Data>\(text)</Data>
              </DataArray>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <GIFTI Version="1.0" NumberOfDataArrays="\(datasets.count)">
          \(arrays)
        </GIFTI>
        """
    }

    static func functionalMatrixXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <GIFTI Version="1.0" NumberOfDataArrays="1">
          <DataArray Intent="NIFTI_INTENT_TIME_SERIES" DataType="NIFTI_TYPE_FLOAT32"
                     ArrayIndexingOrder="RowMajorOrder" Dimensionality="2" Dim0="4" Dim1="2"
                     Encoding="ASCII" Endian="LittleEndian" ExternalFileName="" ExternalFileOffset="">
            <Data>1 10 2 20 3 30 4 40</Data>
          </DataArray>
        </GIFTI>
        """
    }

    static func externalSurfaceXML(triangleOffset: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <GIFTI Version="1.0" NumberOfDataArrays="2">
          <DataArray Intent="NIFTI_INTENT_POINTSET" DataType="NIFTI_TYPE_FLOAT32"
                     ArrayIndexingOrder="RowMajorOrder" Dimensionality="2" Dim0="4" Dim1="3"
                     Encoding="ExternalFileBinary" Endian="LittleEndian" ExternalFileName="surface.bin" ExternalFileOffset="0"><Data/></DataArray>
          <DataArray Intent="NIFTI_INTENT_TRIANGLE" DataType="NIFTI_TYPE_INT32"
                     ArrayIndexingOrder="RowMajorOrder" Dimensionality="2" Dim0="4" Dim1="3"
                     Encoding="ExternalFileBinary" Endian="LittleEndian" ExternalFileName="surface.bin" ExternalFileOffset="\(triangleOffset)"><Data/></DataArray>
        </GIFTI>
        """
    }

    static func pointBytes(order: ByteOrder, indexing: Indexing) -> Data {
        let rowMajor = points.flatMap { [$0.x, $0.y, $0.z] }
        let values = indexing == .rowMajor ? rowMajor : [0, 1, 0, 0, 0, 0, 2, 0, 0, 0, 0, 3]
        var data = Data()
        for value in values { append(value.bitPattern, to: &data, order: order) }
        return data
    }

    static func triangleBytes(order: ByteOrder, indexing: Indexing, override: [Int32]? = nil) -> Data {
        let rowMajor = override ?? triangles.flatMap { [Int32($0.a), Int32($0.b), Int32($0.c)] }
        let values: [Int32]
        if override != nil || indexing == .rowMajor {
            values = rowMajor
        } else {
            values = [0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3]
        }
        var data = Data()
        for value in values { append(UInt32(bitPattern: value), to: &data, order: order) }
        return data
    }

    private static func payload(forPoints encoding: Encoding) -> (data: String, encoding: String, endian: String, indexing: String) {
        switch encoding {
        case .ascii:
            let values: [Float] = points.flatMap { [$0.x, $0.y, $0.z] }
            let text = values.map { String($0) }.joined(separator: " ")
            return (text, "ASCII", "LittleEndian", "RowMajorOrder")
        case .base64(let order, let indexing):
            return (pointBytes(order: order, indexing: indexing).base64EncodedString(), "Base64Binary", endian(order), indexOrder(indexing))
        case .zlibBase64:
            let compressed = try! zlib(pointBytes(order: .littleEndian, indexing: .rowMajor))
            return (compressed.base64EncodedString(), "GZipBase64Binary", "LittleEndian", "RowMajorOrder")
        }
    }

    private static func payload(
        forTriangles encoding: Encoding,
        override: [Int32]?
    ) -> (data: String, encoding: String, endian: String, indexing: String) {
        switch encoding {
        case .ascii:
            let values = override ?? triangles.flatMap { [Int32($0.a), Int32($0.b), Int32($0.c)] }
            return (values.map { String($0) }.joined(separator: " "), "ASCII", "LittleEndian", "RowMajorOrder")
        case .base64(let order, let indexing):
            return (triangleBytes(order: order, indexing: indexing, override: override).base64EncodedString(), "Base64Binary", endian(order), indexOrder(indexing))
        case .zlibBase64:
            let compressed = try! zlib(triangleBytes(order: .littleEndian, indexing: .rowMajor, override: override))
            return (compressed.base64EncodedString(), "GZipBase64Binary", "LittleEndian", "RowMajorOrder")
        }
    }

    private static func zlib(_ input: Data) throws -> Data {
        var deflate = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { chunk in
            if let chunk { deflate.append(chunk) }
        }
        try filter.write(input)
        try filter.finalize()
        var output = Data([0x78, 0x9c])
        output.append(deflate)
        var checksum = adler32(input).bigEndian
        withUnsafeBytes(of: &checksum) { output.append(contentsOf: $0) }
        return output
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return b << 16 | a
    }

    private static func append(_ value: UInt32, to data: inout Data, order: ByteOrder) {
        let stored = order == .littleEndian ? value.littleEndian : value.bigEndian
        withUnsafeBytes(of: stored) { data.append(contentsOf: $0) }
    }

    private static func endian(_ order: ByteOrder) -> String {
        order == .littleEndian ? "LittleEndian" : "BigEndian"
    }

    private static func indexOrder(_ indexing: Indexing) -> String {
        indexing == .rowMajor ? "RowMajorOrder" : "ColumnMajorOrder"
    }
}
