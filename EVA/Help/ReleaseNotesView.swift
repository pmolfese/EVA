//
//  ReleaseNotesView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The Release Notes window (Help ▸ Release Notes): releases listed newest-first
//  in a narrow sidebar, the selected release's notes rendered on the right.
//
//  Content comes from `ReleaseNotesCatalog`; rendering from `MarkdownView`.
//

import SwiftUI

struct ReleaseNotesView: View {
    /// Sidebar takes a fifth of the window, the notes get the rest. Still
    /// user-draggable — this only sets where the divider starts.
    private static let sidebarFraction: CGFloat = 0.2
    private static let sidebarMinimumWidth: CGFloat = 150
    private static let sidebarMaximumWidth: CGFloat = 320

    @State private var notes: [ReleaseNote] = []
    @State private var selection: ReleaseNote.ID?

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(
                        min: Self.sidebarMinimumWidth,
                        ideal: min(
                            max(geometry.size.width * Self.sidebarFraction, Self.sidebarMinimumWidth),
                            Self.sidebarMaximumWidth
                        ),
                        max: Self.sidebarMaximumWidth
                    )
            } detail: {
                detail
            }
        }
        .task {
            guard notes.isEmpty else { return }
            notes = ReleaseNotesCatalog.load()
            // Newest release is what someone opening this window almost always
            // wants, and it saves a click.
            selection = notes.first?.id
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(notes, selection: $selection) { note in
            VStack(alignment: .leading, spacing: 2) {
                Text(note.displayVersion)
                    .font(.headline)
                if let title = note.title {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let date = note.formattedDate {
                    Text(date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 3)
            .tag(note.id)
        }
        .navigationTitle("Releases")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let note = notes.first(where: { $0.id == selection }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(for: note)
                    Divider()
                    MarkdownView(markdown: note.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            // Restarts the scroll position at the top when another release is
            // picked, instead of keeping the previous one's offset.
            .id(note.id)
            .navigationTitle(note.displayVersion)
        } else if notes.isEmpty {
            ContentUnavailableView(
                "No Release Notes",
                systemImage: "doc.text",
                description: Text("No release notes are bundled with this build of EVA.")
            )
        } else {
            ContentUnavailableView(
                "Select a Release",
                systemImage: "sidebar.left",
                description: Text("Choose a release from the list to see what changed.")
            )
        }
    }

    private func header(for note: ReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EVA \(note.displayVersion)")
                .font(.system(.largeTitle, weight: .bold))
            if let title = note.title {
                Text(title)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if let date = note.formattedDate {
                Text(date)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
