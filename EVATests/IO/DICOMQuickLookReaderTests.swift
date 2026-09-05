//
//  DICOMQuickLookReaderTests.swift
//  EVATests
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EVA

struct DICOMQuickLookReaderTests {
    @Test func readsExplicitVRLittleEndianPart10Image() throws {
        let fixture = DICOMFixture.part10(
            syntaxUID: "1.2.840.10008.1.2.1",
            dataset: DICOMFixture.explicitDataset(order: .littleEndian)
        )
        try withFixture(fixture, extension: "dcm") { url in
            let model = try DICOMQuickLookReader.read(from: url)
            #expect(model.transferSyntax == .explicitVRLittleEndian)
            #expect(model.modality == "MR")
            #expect(model.patientName == "EVA TEST")
            #expect(model.dimensionsText == "4 × 3")
            #expect(model.pixelSpacing == [0.5, 0.75])
            guard case .grayscale(let width, let height, let values, let window, _) = model.image else {
                Issue.record("Expected a grayscale image")
                return
            }
            #expect(width == 4)
            #expect(height == 3)
            #expect(values == (0..<12).map { Double($0) * 2 - 10 })
            #expect(window.minimum == -50)
            #expect(window.maximum == 150)
            #expect(DICOMImageRenderer.image(for: model.image)?.width == 4)
        }
    }

    @Test func detectsExplicitVRDatasetWithoutPart10Preamble() throws {
        let fixture = DICOMFixture.explicitDataset(order: .littleEndian)
        try withFixture(fixture, extension: "ima") { url in
            let model = try DICOMQuickLookReader.read(from: url)
            #expect(model.transferSyntax == .explicitVRLittleEndian)
            #expect(model.image.height == 3)
        }
    }

    @Test func readsExplicitVRBigEndianSamples() throws {
        let fixture = DICOMFixture.part10(
            syntaxUID: "1.2.840.10008.1.2.2",
            dataset: DICOMFixture.explicitDataset(order: .bigEndian)
        )
        try withFixture(fixture, extension: "dcm") { url in
            let model = try DICOMQuickLookReader.read(from: url)
            #expect(model.transferSyntax == .explicitVRBigEndian)
            guard case .grayscale(_, _, let values, _, _) = model.image else {
                Issue.record("Expected a grayscale image")
                return
            }
            #expect(values.last == 12)
        }
    }

    @Test func readsImplicitVRLittleEndian() throws {
        let fixture = DICOMFixture.part10(
            syntaxUID: "1.2.840.10008.1.2",
            dataset: DICOMFixture.implicitDataset()
        )
        try withFixture(fixture, extension: "dcm") { url in
            let model = try DICOMQuickLookReader.read(from: url)
            #expect(model.transferSyntax == .implicitVRLittleEndian)
            #expect(model.modality == "CT")
            #expect(model.image.width == 2)
            #expect(model.image.height == 2)
        }
    }

    @Test func readsEncapsulatedJPEGBaseline() throws {
        let jpeg = try DICOMFixture.jpeg()
        let fixture = DICOMFixture.part10(
            syntaxUID: "1.2.840.10008.1.2.4.50",
            dataset: DICOMFixture.encapsulatedDataset(jpeg: jpeg)
        )
        try withFixture(fixture, extension: "dcm") { url in
            let model = try DICOMQuickLookReader.read(from: url)
            #expect(model.transferSyntax.isCompressed)
            #expect(DICOMImageRenderer.image(for: model.image)?.width == 2)
            #expect(DICOMImageRenderer.image(for: model.image)?.height == 2)
        }
    }

    @Test func routesDICOMExtensions() {
        #expect(EVAPreviewFormat.identify(URL(fileURLWithPath: "scan.dcm")) == .dicom)
        #expect(EVAPreviewFormat.identify(URL(fileURLWithPath: "SCAN.IMA")) == .dicom)
    }

    private func withFixture(
        _ data: Data, extension suffix: String, body: (URL) throws -> Void
    ) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-dicom-\(UUID().uuidString).\(suffix)")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
}

private enum DICOMFixture {
    enum Order { case littleEndian, bigEndian }

    static func part10(syntaxUID: String, dataset: Data) -> Data {
        var data = Data(repeating: 0, count: 128)
        data.append(contentsOf: [0x44, 0x49, 0x43, 0x4d])
        appendExplicit(group: 0x0002, element: 0x0010, vr: "UI", value: text(syntaxUID, nullPad: true), to: &data, order: .littleEndian)
        data.append(dataset)
        return data
    }

    static func explicitDataset(order: Order) -> Data {
        var data = Data()
        appendExplicit(group: 0x0008, element: 0x0060, vr: "CS", value: text("MR"), to: &data, order: order)
        appendExplicit(group: 0x0010, element: 0x0010, vr: "PN", value: text("EVA^TEST"), to: &data, order: order)
        appendExplicit(group: 0x0028, element: 0x0002, vr: "US", value: uint16(1, order), to: &data, order: order)
        appendExplicit(group: 0x0028, element: 0x0004, vr: "CS", value: text("MONOCHROME2"), to: &data, order: order)
        appendExplicit(group: 0x0028, element: 0x0010, vr: "US", value: uint16(3, order), to: &data, order: order)
        appendExplicit(group: 0x0028, element: 0x0011, vr: "US", value: uint16(4, order), to: &data, order: order)
        appendExplicit(group: 0x0028, element: 0x0030, vr: "DS", value: text("0.5\\0.75"), to: &data, order: order)
        appendExplicit(group: 0x0028, element: 0x0100, vr: "US", value: uint16(16, order), to: &data, order: order)
        appendExplicit(group: 0x0028, element: 0x0101, vr: "US", value: uint16(12, order), to: &data, order: order)
        appendExplicit(group: 0x0028, element: 0x0102, vr: "US", value: uint16(11, order), to: &data, order: order)
        appendExplicit(group: 0x0028, element: 0x0103, vr: "US", value: uint16(0, order), to: &data, order: order)
        appendExplicit(group: 0x0028, element: 0x1050, vr: "DS", value: text("50"), to: &data, order: order)
        appendExplicit(group: 0x0028, element: 0x1051, vr: "DS", value: text("200"), to: &data, order: order)
        appendExplicit(group: 0x0028, element: 0x1052, vr: "DS", value: text("-10"), to: &data, order: order)
        appendExplicit(group: 0x0028, element: 0x1053, vr: "DS", value: text("2"), to: &data, order: order)
        var pixels = Data()
        for value in 0..<12 { pixels.append(uint16(UInt16(value), order)) }
        appendExplicit(group: 0x7fe0, element: 0x0010, vr: "OW", value: pixels, to: &data, order: order)
        return data
    }

    static func implicitDataset() -> Data {
        var data = Data()
        appendImplicit(group: 0x0008, element: 0x0060, value: text("CT"), to: &data)
        appendImplicit(group: 0x0028, element: 0x0002, value: uint16(1, .littleEndian), to: &data)
        appendImplicit(group: 0x0028, element: 0x0004, value: text("MONOCHROME2"), to: &data)
        appendImplicit(group: 0x0028, element: 0x0010, value: uint16(2, .littleEndian), to: &data)
        appendImplicit(group: 0x0028, element: 0x0011, value: uint16(2, .littleEndian), to: &data)
        appendImplicit(group: 0x0028, element: 0x0100, value: uint16(8, .littleEndian), to: &data)
        appendImplicit(group: 0x0028, element: 0x0101, value: uint16(8, .littleEndian), to: &data)
        appendImplicit(group: 0x0028, element: 0x0102, value: uint16(7, .littleEndian), to: &data)
        appendImplicit(group: 0x0028, element: 0x0103, value: uint16(0, .littleEndian), to: &data)
        appendImplicit(group: 0x7fe0, element: 0x0010, value: Data([0, 64, 128, 255]), to: &data)
        return data
    }

    static func encapsulatedDataset(jpeg: Data) -> Data {
        var data = Data()
        appendExplicit(group: 0x0008, element: 0x0060, vr: "CS", value: text("OT"), to: &data, order: .littleEndian)
        appendExplicit(group: 0x0028, element: 0x0002, vr: "US", value: uint16(1, .littleEndian), to: &data, order: .littleEndian)
        appendExplicit(group: 0x0028, element: 0x0004, vr: "CS", value: text("MONOCHROME2"), to: &data, order: .littleEndian)
        appendExplicit(group: 0x0028, element: 0x0010, vr: "US", value: uint16(2, .littleEndian), to: &data, order: .littleEndian)
        appendExplicit(group: 0x0028, element: 0x0011, vr: "US", value: uint16(2, .littleEndian), to: &data, order: .littleEndian)
        appendExplicit(group: 0x0028, element: 0x0100, vr: "US", value: uint16(8, .littleEndian), to: &data, order: .littleEndian)
        data.append(uint16(0x7fe0, .littleEndian)); data.append(uint16(0x0010, .littleEndian))
        data.append("OB".data(using: .ascii)!); data.append(contentsOf: [0, 0]); data.append(uint32(.max, .littleEndian))
        data.append(uint16(0xfffe, .littleEndian)); data.append(uint16(0xe000, .littleEndian)); data.append(uint32(0, .littleEndian))
        var fragment = jpeg
        if !fragment.count.isMultiple(of: 2) { fragment.append(0) }
        data.append(uint16(0xfffe, .littleEndian)); data.append(uint16(0xe000, .littleEndian))
        data.append(uint32(UInt32(fragment.count), .littleEndian)); data.append(fragment)
        data.append(uint16(0xfffe, .littleEndian)); data.append(uint16(0xe0dd, .littleEndian)); data.append(uint32(0, .littleEndian))
        return data
    }

    static func jpeg() throws -> Data {
        let pixels = Data([0, 80, 160, 255])
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 2,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { throw FixtureError.cannotCreateJPEG }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw FixtureError.cannotCreateJPEG }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.cannotCreateJPEG }
        return output as Data
    }

    private enum FixtureError: Error { case cannotCreateJPEG }

    private static func appendExplicit(
        group: UInt16, element: UInt16, vr: String, value: Data, to data: inout Data, order: Order
    ) {
        data.append(uint16(group, order)); data.append(uint16(element, order))
        data.append(vr.data(using: .ascii)!)
        if ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UR", "UT", "UN"].contains(vr) {
            data.append(contentsOf: [0, 0]); data.append(uint32(UInt32(value.count), order))
        } else {
            data.append(uint16(UInt16(value.count), order))
        }
        data.append(value)
    }

    private static func appendImplicit(group: UInt16, element: UInt16, value: Data, to data: inout Data) {
        data.append(uint16(group, .littleEndian)); data.append(uint16(element, .littleEndian))
        data.append(uint32(UInt32(value.count), .littleEndian)); data.append(value)
    }

    private static func text(_ string: String, nullPad: Bool = false) -> Data {
        var data = string.data(using: .ascii)!
        if !data.count.isMultiple(of: 2) { data.append(nullPad ? 0 : 0x20) }
        return data
    }
    private static func uint16(_ value: UInt16, _ order: Order) -> Data {
        switch order {
        case .littleEndian: Data([UInt8(value & 0xff), UInt8(value >> 8)])
        case .bigEndian: Data([UInt8(value >> 8), UInt8(value & 0xff)])
        }
    }
    private static func uint32(_ value: UInt32, _ order: Order) -> Data {
        let bytes = [
            UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)
        ]
        return order == .littleEndian ? Data(bytes) : Data(bytes.reversed())
    }
}
