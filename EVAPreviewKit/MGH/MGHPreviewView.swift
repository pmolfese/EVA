//
//  MGHPreviewView.swift
//  EVAPreviewKit
//

import SwiftUI

struct MGHPreviewView: View {
    let model: MGHPreviewModel

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 620 {
                HStack(spacing: 0) {
                    montage.frame(width: proxy.size.width * 0.7)
                    Divider()
                    ScrollView { metadata }
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        montage.frame(height: max(360, proxy.size.width * 0.72))
                        Divider()
                        metadata
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private var montage: some View {
        GeometryReader { proxy in
            let padding: CGFloat = 10, gap: CGFloat = 6
            let cellWidth = max(1, (proxy.size.width - padding * 2 - gap) / 2)
            let cellHeight = max(1, (proxy.size.height - padding * 2 - gap) / 2)
            VStack(spacing: gap) {
                HStack(spacing: gap) { panel(0); panel(1) }
                HStack(spacing: gap) { panel(2); summaryTile }
            }
            .frame(width: cellWidth * 2 + gap, height: cellHeight * 2 + gap)
            .padding(padding)
        }
        .background(Color.black)
    }

    @ViewBuilder private func panel(_ index: Int) -> some View {
        if model.slices.indices.contains(index) {
            NIfTISlicePanel(slice: model.slices[index], window: model.intensityWindow)
        } else { Color(white: 0.06) }
    }

    private var summaryTile: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("FreeSurfer MGH").font(.headline)
                Spacer()
                if model.header.frameCount > 1 {
                    Text("Frame 1 / \(model.header.frameCount)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(model.dimensionsText).font(.system(.title3, design: .rounded, weight: .semibold))
            Text("Display window").font(.caption).foregroundStyle(.secondary)
            LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                .frame(height: 10).clipShape(RoundedRectangle(cornerRadius: 2))
            HStack {
                Text(short(model.intensityWindow.minimum)); Spacer(); Text(short(model.intensityWindow.maximum))
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Text(model.header.affine?.source ?? "Native voxel orientation")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).foregroundStyle(.white).background(Color(white: 0.075))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.displayName).font(.headline).lineLimit(2).truncationMode(.middle)
                HStack(spacing: 6) {
                    badge("MGH v\(model.header.version)")
                    if model.isCompressed { badge("Gzip") }
                    if model.header.frameCount > 1 { badge("4D") }
                }
            }
            VStack(spacing: 8) {
                row("Dimensions", model.dimensionsText)
                row("Voxel size", model.voxelSizeText)
                row("Datatype", "\(model.header.dataType.displayName) (\(model.header.dataType.rawValue))")
                row("Frames", String(model.header.frameCount))
                row("Byte order", "Big-endian")
                row("File size", ByteCountFormatter.string(fromByteCount: model.byteSize, countStyle: .file))
            }
            Divider()
            VStack(spacing: 8) {
                row("RAS geometry", model.header.hasRASGeometry ? "Scanner RAS" : "Not present")
                if let center = model.header.centerRAS {
                    row("RAS center", center.map(short).joined(separator: ", ") + " mm")
                }
                if model.header.degreesOfFreedom != 0 {
                    row("Degrees of freedom", String(model.header.degreesOfFreedom))
                }
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
