//
//  FigureExportBasketView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The "Figure Export" window (Window menu): the reorderable list of figures
//  added via "Add to Export" and the contact-sheet export controls. See
//  `FigureExportBasket` for the capture/layout logic this is a thin view over.
//

import SwiftUI

struct FigureExportBasketView: View {
    @State private var basket = FigureExportBasket.shared

    var body: some View {
        VStack(spacing: 0) {
            if basket.items.isEmpty {
                ContentUnavailableView(
                    "No Figures Yet",
                    systemImage: "tray",
                    description: Text("Right-click any plot in EVA and choose “Add to Export” to collect it here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(basket.items) { item in
                        HStack(spacing: 12) {
                            if let thumbnail = item.thumbnailImage {
                                Image(nsImage: thumbnail)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 64, height: 64)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.body.weight(.medium))
                                if !item.legend.isEmpty {
                                    Text(item.legend.map(\.0).joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Button {
                                basket.remove(item.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .onMove { basket.move(fromOffsets: $0, toOffset: $1) }
                }
            }

            Divider()

            HStack {
                Text("\(basket.items.count) figure\(basket.items.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Picker("Page", selection: $basket.pageSize) {
                    ForEach(FigureBasketPageSize.allCases) { size in
                        Text(size.rawValue).tag(size)
                    }
                }
                .frame(width: 220)

                Button("Clear") {
                    basket.clear()
                }
                .disabled(basket.items.isEmpty)

                Button("Export Contact Sheet…") {
                    basket.exportContactSheet()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(basket.items.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 400)
    }
}
