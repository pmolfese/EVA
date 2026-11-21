import SwiftUI

struct NIMLPreviewView: View {
    let model: NIMLPreviewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(model.fileName).font(.title2.bold()).textSelection(.enabled)
                Text(model.dataset?.attributes["dset_type"] ?? "AFNI NIML document")
                    .foregroundStyle(.secondary)
                if let data = model.data {
                    Text("\(data.rows) nodes · \(data.types.count) columns").font(.headline)
                    if let timestep = data.attributes["ni_timestep"] {
                        Text("Time step: \(timestep) seconds").font(.subheadline)
                    }
                }
                ForEach(Array(model.elements.enumerated()), id: \.offset) { _, element in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(element.attributes.keys.sorted(), id: \.self) { key in
                                Text("\(key): \(element.attributes[key] ?? "")")
                                    .font(.caption).textSelection(.enabled)
                            }
                            if !element.types.isEmpty && !element.sample.isEmpty {
                                Text("\(element.rows) rows × \(element.types.count) columns")
                                    .font(.subheadline.bold())
                                ScrollView(.horizontal) {
                                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                                        GridRow {
                                            Text("Row")
                                            ForEach(0..<min(16, element.types.count), id: \.self) { column in
                                                Text(columnName(column, element: element)).bold()
                                            }
                                        }
                                        GridRow {
                                            Text("Range").foregroundStyle(.secondary)
                                            ForEach(0..<min(16, element.ranges.count), id: \.self) { column in
                                                Text(rangeText(element.ranges[column])).foregroundStyle(.secondary)
                                            }
                                        }
                                        ForEach(Array(element.sample.enumerated()), id: \.offset) { row, cells in
                                            GridRow {
                                                Text(String(row))
                                                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in Text(cell) }
                                            }
                                        }
                                    }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                }
                                Text("Showing the first \(element.sample.count) rows and up to 16 columns. Ranges use all finite values.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !element.text.isEmpty {
                                Text(element.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                if element.text.count == 8192 { Text("Text truncated for preview.").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Text(element.attributes["atr_name"].map { "\(element.name): \($0)" } ?? element.name)
                    }.padding(.leading, CGFloat(element.depth) * 12)
                }
            }.padding(20)
        }.frame(minWidth: 500, minHeight: 350)
    }

    private func columnName(_ column: Int, element: NIMLPreviewModel.Element) -> String {
        let labels = model.columnLabels
        if element.name == "SPARSE_DATA", labels.indices.contains(column), !labels[column].isEmpty { return labels[column] }
        return "\(column + 1) (\(element.types[column]))"
    }
    private func rangeText(_ range: ClosedRange<Double>?) -> String {
        guard let range else { return "—" }
        return String(format: "%.5g … %.5g", range.lowerBound, range.upperBound)
    }
}
