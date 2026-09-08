//
//  NIfTIPreviewView.swift
//  EVAPreviewKit
//
//  A SwiftUI interpretation of NIfTIViewQL's useful 70/30 split: a dark 2×2
//  orthogonal montage beside compact metadata. The fourth tile explains the
//  display window and 4D selection instead of remaining empty.
//

import SwiftUI

struct NIfTIPreviewView: View {
    let model: NIfTIPreviewModel

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 620 {
                HStack(spacing: 0) {
                    NIfTIMontageView(model: model)
                        .frame(width: proxy.size.width * 0.7)
                    Divider()
                    NIfTIMetadataView(model: model)
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        NIfTIMontageView(model: model)
                            .frame(height: max(360, proxy.size.width * 0.72))
                        Divider()
                        NIfTIMetadataContent(model: model)
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}

private struct NIfTIMontageView: View {
    let model: NIfTIPreviewModel

    var body: some View {
        GeometryReader { proxy in
            let padding: CGFloat = 10
            let gap: CGFloat = 6
            let cellWidth = max(1, (proxy.size.width - padding * 2 - gap) / 2)
            let cellHeight = max(1, (proxy.size.height - padding * 2 - gap) / 2)
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    slicePanel(at: 0)
                    slicePanel(at: 1)
                }
                HStack(spacing: gap) {
                    slicePanel(at: 2)
                    summaryTile
                }
            }
            .frame(width: cellWidth * 2 + gap, height: cellHeight * 2 + gap)
            .padding(padding)
        }
        .background(Color.black)
    }

    @ViewBuilder
    private func slicePanel(at index: Int) -> some View {
        if model.slices.indices.contains(index) {
            NIfTISlicePanel(slice: model.slices[index], window: model.intensityWindow)
        } else {
            Color(white: 0.06)
        }
    }

    private var summaryTile: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(model.header.version.displayName)
                    .font(.headline)
                Spacer()
                if model.header.volumeCount > 1 {
                    Text("Volume 1 / \(model.header.volumeCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(model.dimensionsText)
                .font(.system(.title3, design: .rounded, weight: .semibold))
            Text("Display window")
                .font(.caption)
                .foregroundStyle(.secondary)
            LinearGradient(
                colors: [.black, .white],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            HStack {
                Text(formatted(model.intensityWindow.minimum))
                Spacer()
                Text(formatted(model.intensityWindow.maximum))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            Spacer()
            Text(model.header.affine.map { "Orientation from \($0.source)" } ?? "Native voxel orientation")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .foregroundStyle(.white)
        .background(Color(white: 0.075))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(3...5)))
    }
}

struct NIfTISlicePanel: View {
    let slice: NIfTISlice
    let window: NIfTIIntensityWindow

    var body: some View {
        ZStack {
            Color(white: 0.025)
            if let image = NIfTISliceRenderer.image(for: slice, window: window) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(slice.physicalAspectRatio, contentMode: .fit)
                    .padding(18)
            }
            orientationLabels
        }
        .overlay(alignment: .topLeading) {
            Text(slice.plane.rawValue)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(7)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var orientationLabels: some View {
        ZStack {
            Text(slice.leftLabel).frame(maxWidth: .infinity, alignment: .leading)
            Text(slice.rightLabel).frame(maxWidth: .infinity, alignment: .trailing)
            Text(slice.topLabel).frame(maxHeight: .infinity, alignment: .top)
            Text(slice.bottomLabel).frame(maxHeight: .infinity, alignment: .bottom)
        }
        .font(.caption2.monospaced().weight(.semibold))
        .foregroundStyle(.white.opacity(0.7))
        .padding(6)
    }
}

private struct NIfTIMetadataView: View {
    let model: NIfTIPreviewModel

    var body: some View {
        ScrollView {
            NIfTIMetadataContent(model: model)
        }
        .background(.background)
    }
}

private struct NIfTIMetadataContent: View {
    let model: NIfTIPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.displayName)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    NIfTIBadge(text: model.header.version.displayName)
                    if model.isCompressed { NIfTIBadge(text: "Gzip") }
                    if model.header.volumeCount > 1 { NIfTIBadge(text: "4D") }
                }
            }

            VStack(spacing: 8) {
                row("Dimensions", model.dimensionsText)
                row("Voxel size", model.voxelSizeText)
                row("Datatype", model.header.dataType.displayName)
                if let time = model.timeResolutionText { row("Time step", time) }
                row("Byte order", model.header.byteOrder.displayName)
                row("File size", ByteCountFormatter.string(fromByteCount: model.byteSize, countStyle: .file))
            }

            Divider()

            VStack(spacing: 8) {
                row("qform", formDescription(model.header.qformCode))
                row("sform", formDescription(model.header.sformCode))
                if model.header.intentCode != 0 {
                    row("Intent", intentText)
                }
                if model.header.effectiveSlope != 1 || model.header.effectiveIntercept != 0 {
                    row("Scaling", "×\(short(model.header.effectiveSlope)) + \(short(model.header.effectiveIntercept))")
                }
            }

            if let description = model.header.description {
                Divider()
                Text("Description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(description)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private var intentText: String {
        if let name = model.header.intentName { return "\(name) (\(model.header.intentCode))" }
        return String(model.header.intentCode)
    }

    private func formDescription(_ code: Int) -> String {
        switch code {
        case 0: return "Not set"
        case 1: return "Scanner anatomical"
        case 2: return "Aligned anatomical"
        case 3: return "Talairach"
        case 4: return "MNI 152"
        case 5: return "Template"
        default: return "Code \(code)"
        }
    }

    private func short(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(3...5)))
    }
}

private struct NIfTIBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.13), in: Capsule())
    }
}
