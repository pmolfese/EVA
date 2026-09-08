//
//  DICOMPreviewView.swift
//  EVAPreviewKit
//

import SwiftUI

struct DICOMPreviewView: View {
    let model: DICOMPreviewModel

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 620 {
                HStack(spacing: 0) {
                    imagePanel.frame(width: proxy.size.width * 0.7)
                    Divider()
                    ScrollView { metadata }
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        imagePanel.frame(height: max(360, proxy.size.width * 0.75))
                        Divider()
                        metadata
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private var imagePanel: some View {
        GeometryReader { proxy in
            if let image = DICOMImageRenderer.image(for: model.image) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(model.physicalAspectRatio, contentMode: .fit)
                    .frame(maxWidth: proxy.size.width - 32, maxHeight: proxy.size.height - 54)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            } else {
                ContentUnavailableView("Image unavailable", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.white)
            }
            VStack {
                Spacer()
                HStack {
                    Text(model.modality ?? "DICOM")
                    Spacer()
                    if model.frameCount > 1 { Text("Frame 1 / \(model.frameCount)") }
                }
                .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.7)).padding(12)
            }
        }
        .background(Color.black)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.displayName).font(.headline).lineLimit(2).truncationMode(.middle)
                HStack(spacing: 6) {
                    badge("DICOM")
                    if let modality = model.modality { badge(modality) }
                    if model.transferSyntax.isCompressed { badge("Compressed") }
                    if model.frameCount > 1 { badge("Multiframe") }
                }
            }
            VStack(spacing: 8) {
                if let patientName = model.patientName { row("Patient", patientName) }
                if let patientID = model.patientID { row("Patient ID", patientID) }
                if let study = model.studyDescription { row("Study", study) }
                if let series = model.seriesDescription { row("Series", series) }
            }
            if model.patientName != nil || model.patientID != nil ||
                model.studyDescription != nil || model.seriesDescription != nil { Divider() }
            VStack(spacing: 8) {
                row("Dimensions", model.dimensionsText)
                if let spacing = model.pixelSpacingText { row("Pixel spacing", spacing) }
                if let thickness = model.sliceThickness {
                    row("Slice thickness", short(thickness) + " mm")
                }
                row("Photometric", model.photometricInterpretation)
                row("Samples", String(model.samplesPerPixel))
                row("Bit depth", model.bitsStored == model.bitsAllocated
                    ? "\(model.bitsAllocated)"
                    : "\(model.bitsStored) stored / \(model.bitsAllocated) allocated")
                if let center = model.windowCenter, let width = model.windowWidth {
                    row("Window", "C \(short(center)) · W \(short(width))")
                }
            }
            Divider()
            VStack(spacing: 8) {
                row("Transfer syntax", model.transferSyntax.displayName)
                if let manufacturer = model.manufacturer { row("Manufacturer", manufacturer) }
                row("File size", ByteCountFormatter.string(fromByteCount: model.byteSize, countStyle: .file))
            }
            Spacer(minLength: 0)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary); Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.subheadline)
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.13), in: Capsule())
    }

    private func short(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(3...5)))
    }
}
