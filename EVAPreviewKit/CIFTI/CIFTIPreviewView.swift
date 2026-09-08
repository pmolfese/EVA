//
//  CIFTIPreviewView.swift
//  EVAPreviewKit
//

import SwiftUI

struct CIFTIPreviewView: View {
    let model: CIFTIPreviewModel

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 620 {
                HStack(spacing: 0) {
                    CIFTIMatrixPanel(model: model)
                        .frame(width: proxy.size.width * 0.7)
                    Divider()
                    ScrollView { CIFTIMetadataContent(model: model) }
                        .background(.background)
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        CIFTIMatrixPanel(model: model)
                            .frame(height: max(360, proxy.size.width * 0.72))
                        Divider()
                        CIFTIMetadataContent(model: model)
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}

private struct CIFTIMatrixPanel: View {
    let model: CIFTIPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.fileKind)
                    .font(.title2.weight(.semibold))
                Text(model.dimensionsText + " matrix")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.055))
                if let image = CIFTIMatrixRenderer.image(for: model) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .padding(2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("↓ " + model.verticalAxisTitle)
                    Text(model.horizontalAxisTitle + " →")
                }
                Spacer()
                Text(sampleDescription)
                    .multilineTextAlignment(.trailing)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            if model.isLabelData {
                CIFTILabelLegend(model: model)
            } else {
                CIFTIContinuousLegend(window: model.sample.window)
            }
        }
        .padding(28)
        .foregroundStyle(.white)
        .background(Color(red: 0.018, green: 0.028, blue: 0.025))
    }

    private var sampleDescription: String {
        let sample = model.sample
        let totalRows = model.matrixDimensions.dropFirst().reduce(1, *)
        if sample.width == model.matrixDimensions[0], sample.height == totalRows {
            return "Complete matrix"
        }
        return "Sampled \(sample.width) × \(sample.height)"
    }
}

private struct CIFTIContinuousLegend: View {
    let window: ClosedRange<Double>

    var body: some View {
        VStack(spacing: 5) {
            Canvas { context, size in
                let columns = max(Int(size.width), 2)
                for column in 0..<columns {
                    let t = Double(column) / Double(columns - 1)
                    let value = window.lowerBound + t * (window.upperBound - window.lowerBound)
                    let rgb = CIFTIMatrixRenderer.continuousColor(value: value, window: window)
                    let color = Color(
                        red: Double(rgb.0) / 255,
                        green: Double(rgb.1) / 255,
                        blue: Double(rgb.2) / 255
                    )
                    context.fill(
                        Path(CGRect(x: CGFloat(column), y: 0, width: 1.5, height: size.height)),
                        with: .color(color)
                    )
                }
            }
            .frame(height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            HStack {
                Text(short(window.lowerBound))
                Spacer()
                Text(short(window.upperBound))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func short(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(3...5)))
    }
}

private struct CIFTILabelLegend: View {
    let model: CIFTIPreviewModel

    var body: some View {
        let labels = model.labelMaps.first?.labels.prefix(8) ?? []
        if labels.isEmpty {
            Text("Categorical label keys")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.labelMaps.first?.name ?? "Labels")
                    .font(.caption.weight(.medium))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], spacing: 5) {
                    ForEach(Array(labels), id: \.key) { label in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(labelColor(label))
                                .frame(width: 8, height: 8)
                            Text(label.name).lineLimit(1)
                        }
                        .font(.caption2)
                    }
                }
            }
        }
    }

    private func labelColor(_ label: CIFTILabel) -> Color {
        guard let red = label.red, let green = label.green, let blue = label.blue else {
            return .secondary
        }
        return Color(red: red, green: green, blue: blue, opacity: label.alpha ?? 1)
    }
}

private struct CIFTIMetadataContent: View {
    let model: CIFTIPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.displayName)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    badge("CIFTI \(model.ciftiVersion)")
                    badge(model.fileKind)
                }
            }

            VStack(spacing: 8) {
                row("Matrix", model.dimensionsText)
                row("Datatype", model.header.dataType.displayName)
                row("Byte order", model.header.byteOrder.displayName)
                row("Storage", "NIfTI-2 rows")
                row("File size", ByteCountFormatter.string(fromByteCount: model.byteSize, countStyle: .file))
            }

            Divider()
            Text("Matrix Dimensions")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.mappings) { mapping in
                VStack(alignment: .leading, spacing: 3) {
                    Text(mappingTitle(mapping))
                        .font(.subheadline.weight(.medium))
                    Text(mapping.detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !model.structureNames.isEmpty {
                Divider()
                Text("Brain Structures")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.structureNames.joined(separator: "\n"))
                    .font(.subheadline)
            }

            let mapNames = model.mappings.flatMap(\.namedMaps).map(\.name)
            if !mapNames.isEmpty {
                Divider()
                Text("Maps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(mapNames.prefix(12).enumerated()), id: \.offset) { _, name in
                    Text(name).font(.subheadline).lineLimit(2)
                }
                if mapNames.count > 12 {
                    Text("+ \((mapNames.count - 12).formatted()) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let description = model.metadata["Description"], !description.isEmpty {
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

    private func mappingTitle(_ mapping: CIFTIMapping) -> String {
        let dimensions = mapping.dimensions.map { "\($0 + 1)" }.joined(separator: ", ")
        return "\(mapping.type.displayName) · dim \(dimensions)"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.13), in: Capsule())
    }
}
