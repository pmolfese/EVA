//
//  DICOMPreviewModel.swift
//  EVAPreviewKit
//

import Foundation

nonisolated enum DICOMTransferSyntax: Sendable, Equatable {
    case implicitVRLittleEndian
    case explicitVRLittleEndian
    case explicitVRBigEndian
    case encapsulated(uid: String, name: String)
    case unsupported(uid: String)

    init(uid: String?) {
        let value = uid?.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\0")))
            ?? "1.2.840.10008.1.2"
        switch value {
        case "1.2.840.10008.1.2": self = .implicitVRLittleEndian
        case "1.2.840.10008.1.2.1": self = .explicitVRLittleEndian
        case "1.2.840.10008.1.2.2": self = .explicitVRBigEndian
        case "1.2.840.10008.1.2.4.50": self = .encapsulated(uid: value, name: "JPEG Baseline")
        case "1.2.840.10008.1.2.4.51": self = .encapsulated(uid: value, name: "JPEG Extended")
        case "1.2.840.10008.1.2.4.57", "1.2.840.10008.1.2.4.70":
            self = .encapsulated(uid: value, name: "JPEG Lossless")
        case "1.2.840.10008.1.2.4.80", "1.2.840.10008.1.2.4.81":
            self = .encapsulated(uid: value, name: "JPEG-LS")
        case "1.2.840.10008.1.2.4.90", "1.2.840.10008.1.2.4.91":
            self = .encapsulated(uid: value, name: "JPEG 2000")
        default: self = .unsupported(uid: value)
        }
    }

    var displayName: String {
        switch self {
        case .implicitVRLittleEndian: "Implicit VR Little Endian"
        case .explicitVRLittleEndian: "Explicit VR Little Endian"
        case .explicitVRBigEndian: "Explicit VR Big Endian"
        case .encapsulated(_, let name): name
        case .unsupported(let uid): uid
        }
    }

    var isCompressed: Bool {
        if case .encapsulated = self { return true }
        return false
    }
}

nonisolated enum DICOMPixelImage: Sendable {
    case grayscale(width: Int, height: Int, values: [Double], window: NIfTIIntensityWindow, inverted: Bool)
    case rgb(width: Int, height: Int, bytes: Data)
    case encoded(width: Int, height: Int, data: Data)

    var width: Int {
        switch self {
        case .grayscale(let width, _, _, _, _), .rgb(let width, _, _), .encoded(let width, _, _): width
        }
    }

    var height: Int {
        switch self {
        case .grayscale(_, let height, _, _, _), .rgb(_, let height, _), .encoded(_, let height, _): height
        }
    }
}

nonisolated struct DICOMPreviewModel: Sendable {
    let url: URL
    let transferSyntax: DICOMTransferSyntax
    let image: DICOMPixelImage
    let modality: String?
    let patientName: String?
    let patientID: String?
    let studyDescription: String?
    let seriesDescription: String?
    let manufacturer: String?
    let sopClassUID: String?
    let photometricInterpretation: String
    let samplesPerPixel: Int
    let bitsAllocated: Int
    let bitsStored: Int
    let frameCount: Int
    let pixelSpacing: [Double]?
    let sliceThickness: Double?
    let windowCenter: Double?
    let windowWidth: Double?
    let byteSize: Int64

    var displayName: String { url.lastPathComponent }
    var dimensionsText: String {
        var value = "\(image.width) × \(image.height)"
        if frameCount > 1 { value += " × \(frameCount)" }
        return value
    }
    var pixelSpacingText: String? {
        guard let pixelSpacing, pixelSpacing.count >= 2 else { return nil }
        return pixelSpacing.prefix(2).map {
            $0.formatted(.number.precision(.fractionLength(0...4)))
        }.joined(separator: " × ") + " mm"
    }
    var physicalAspectRatio: Double {
        guard let pixelSpacing, pixelSpacing.count >= 2,
              pixelSpacing[0].isFinite, pixelSpacing[1].isFinite,
              pixelSpacing[0] > 0, pixelSpacing[1] > 0 else {
            return Double(image.width) / Double(max(image.height, 1))
        }
        // DICOM Pixel Spacing is row spacing first, then column spacing.
        return Double(image.width) * pixelSpacing[1] / (Double(image.height) * pixelSpacing[0])
    }
}

nonisolated enum DICOMReadError: LocalizedError, Sendable {
    case unsupportedFile(URL)
    case cannotOpen(URL)
    case malformed(String)
    case unsupportedTransferSyntax(String)
    case unsupportedPixels(String)
    case missingPixelData

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url): "\(url.lastPathComponent) is not a .dcm or .ima file."
        case .cannotOpen(let url): "Could not open \(url.lastPathComponent)."
        case .malformed(let reason): "Malformed DICOM file: \(reason)"
        case .unsupportedTransferSyntax(let syntax): "DICOM transfer syntax is not supported: \(syntax)"
        case .unsupportedPixels(let reason): "DICOM pixel data is not supported: \(reason)"
        case .missingPixelData: "The DICOM file does not contain previewable pixel data."
        }
    }
}
