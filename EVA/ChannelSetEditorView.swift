//
//  ChannelSetEditorView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Full editor for creating, viewing, and managing channel sets.
//  Shows a NavigationSplitView: built-in and user-defined sets in the sidebar,
//  an interactive scalp map + name field in the detail pane.
//
//  When no SensorLayout is available, the map is replaced with a plain
//  channel-index list editor.
//

import SwiftUI
import UniformTypeIdentifiers

struct ChannelSetEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private var layout: SensorLayout? { ChannelSetStore.shared.activeSensorLayout }

    @State private var sidebarSelection: ChannelSet.ID? = nil
    @State private var editingSet: ChannelSet? = nil
    @State private var editingName: String = ""
    @State private var selectedIndices: Set<Int> = []
    /// True while editing a brand-new, not-yet-saved set (the detail pane is
    /// active even though nothing is selected in the sidebar).
    @State private var isCreatingNew = false
    /// When on, toggling an electrode also toggles its mirror-image partner in
    /// the opposite hemisphere so the set stays left/right symmetric.
    @State private var forceSymmetry = false

    @State private var showsDeleteConfirmation = false
    @State private var showsSaveAsAlert = false
    @State private var saveAsName = ""
    @State private var showsExportPanel = false
    @State private var exportDocument: ChannelSetDocument? = nil
    @State private var showsImportPanel = false
    @State private var errorMessage: String? = nil

    private var store: ChannelSetStore { .shared }

    var body: some View {
        NavigationSplitView {
            sidebarList
        } detail: {
            detailPane
        }
        .navigationTitle("Channel Sets")
        .frame(minWidth: 760, minHeight: 540)
        .toolbar { toolbarContent }
        .fileExporter(
            isPresented: $showsExportPanel,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportDocument.map { _ in
                editingSet.map { $0.name } ?? "ChannelSets"
            } ?? "ChannelSets"
        ) { _ in exportDocument = nil }
        .fileImporter(
            isPresented: $showsImportPanel,
            allowedContentTypes: [.json]
        ) { handleImport($0) }
        .confirmationDialog(
            "Delete \"\(editingName)\"?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { commitDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This channel set will be permanently removed.")
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .alert("Save as New Channel Set", isPresented: $showsSaveAsAlert) {
            TextField("Name", text: $saveAsName)
            Button("Save") { commitSave(asNew: true, name: saveAsName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Import…") { showsImportPanel = true }
            Button("Export All…") { prepareExport(sets: store.allSets) }
            Button {
                beginNewSet()
            } label: {
                Label("New Channel Set", systemImage: "plus")
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarList: some View {
        List(selection: $sidebarSelection) {
            Section("Built-In") {
                ForEach(ChannelSetStore.builtInSets) { set in
                    channelSetRow(set)
                        .tag(set.id)
                }
            }
            if !store.userSets.isEmpty {
                Section("User-Defined") {
                    ForEach(store.userSets) { set in
                        channelSetRow(set)
                            .tag(set.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: sidebarSelection) { _, id in
            if let id, let set = store.allSets.first(where: { $0.id == id }) {
                loadSet(set)
            }
        }
    }

    @ViewBuilder
    private func channelSetRow(_ set: ChannelSet) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(set.name)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text("\(set.channelIndices.count) ch")
                if let net = set.netType {
                    Text("·")
                    Text(net)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if sidebarSelection == nil && editingSet == nil && !isCreatingNew {
            ContentUnavailableView(
                "No Channel Set Selected",
                systemImage: "antenna.radiowaves.left.and.right",
                description: Text("Choose a set from the sidebar, or tap \(Image(systemName: "plus")) to create one.")
            )
        } else {
            VStack(spacing: 0) {
                // Name row
                HStack(spacing: 8) {
                    TextField("Channel Set Name", text: $editingName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isViewingBuiltIn)
                    if let netType = editingSet?.netType {
                        Text(netType)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                Divider()

                // Map or fallback
                if let layout {
                    ChannelSetMapView(
                        layout: layout,
                        selectedIndices: $selectedIndices,
                        interactive: !isViewingBuiltIn,
                        onToggle: forceSymmetry && !isViewingBuiltIn
                            ? { channel, nowSelected in
                                applySymmetry(to: channel, nowSelected: nowSelected, layout: layout)
                              }
                            : nil
                    )
                    .padding(12)
                } else {
                    noLayoutFallback
                        .padding(12)
                }

                Divider()

                // Status + action bar
                HStack {
                    Text("\(selectedIndices.count) channel\(selectedIndices.count == 1 ? "" : "s") selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !isViewingBuiltIn, layout != nil {
                        Toggle("Force symmetry", isOn: $forceSymmetry)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .help("Toggling an electrode also toggles its mirror-image partner in the opposite hemisphere. Turning this on mirrors the current selection.")
                            .onChange(of: forceSymmetry) { _, on in
                                if on, let layout { mirrorEntireSelection(layout: layout) }
                            }
                    }

                    Spacer()

                    if !isViewingBuiltIn {
                        Button("Reset") { resetEdits() }

                        Button("Delete", role: .destructive) {
                            showsDeleteConfirmation = true
                        }
                        .disabled(editingSet == nil)

                        Button("Export…") { exportCurrentSet() }

                        Button("Save as New…") {
                            saveAsName = editingName + " Copy"
                            showsSaveAsAlert = true
                        }

                        Button("Save") { commitSave(asNew: false) }
                            .disabled(editingName.trimmingCharacters(in: .whitespaces).isEmpty)
                            .keyboardShortcut("s", modifiers: .command)
                    } else {
                        Button("Export…") { exportCurrentSet() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private var noLayoutFallback: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No sensor layout available for this recording.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !isViewingBuiltIn {
                Text("Enter channel numbers (1-based, comma-separated):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let binding = Binding<String>(
                    get: { selectedIndices.sorted().map { String($0 + 1) }.joined(separator: ", ") },
                    set: { text in
                        let parsed = text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)).map { $0 - 1 } }
                        selectedIndices = Set(parsed.filter { $0 >= 0 })
                    }
                )
                TextField("1, 52, 54, 226-252", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
            } else {
                Text(selectedIndices.sorted().map { String($0 + 1) }.joined(separator: ", "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var isViewingBuiltIn: Bool {
        editingSet.map { store.isBuiltIn($0) } ?? false
    }

    private func loadSet(_ set: ChannelSet) {
        editingSet = set
        editingName = set.name
        selectedIndices = Set(set.channelIndices)
        isCreatingNew = false
    }

    private func beginNewSet() {
        sidebarSelection = nil
        editingSet = nil
        editingName = ""
        selectedIndices = []
        forceSymmetry = false
        isCreatingNew = true
    }

    private func resetEdits() {
        if let set = editingSet {
            loadSet(set)
        } else {
            editingName = ""
            selectedIndices = []
        }
    }

    private func commitSave(asNew: Bool, name: String? = nil) {
        let finalName = (name ?? editingName).trimmingCharacters(in: .whitespaces)
        guard !finalName.isEmpty else { return }
        let newSet = ChannelSet(
            id: asNew ? UUID() : (editingSet?.id ?? UUID()),
            name: finalName,
            channelIndices: selectedIndices.sorted(),
            netType: editingSet?.netType
        )
        store.save(newSet)
        editingSet = newSet
        editingName = finalName
        sidebarSelection = newSet.id
        isCreatingNew = false
        saveAsName = ""
    }

    private func commitDelete() {
        guard let set = editingSet else { return }
        store.delete(set)
        sidebarSelection = nil
        editingSet = nil
        editingName = ""
        selectedIndices = []
        isCreatingNew = false
    }

    // MARK: - Symmetry

    /// Adds/removes the mirror partner of `channel` to match the just-changed
    /// state, so the selection stays left/right symmetric.
    private func applySymmetry(to channel: Int, nowSelected: Bool, layout: SensorLayout) {
        guard let partner = mirrorPartner(of: channel, layout: layout), partner != channel else { return }
        if nowSelected {
            selectedIndices.insert(partner)
        } else {
            selectedIndices.remove(partner)
        }
    }

    /// Adds the mirror partner of every currently-selected channel.
    private func mirrorEntireSelection(layout: SensorLayout) {
        var additions = Set<Int>()
        for channel in selectedIndices {
            if let partner = mirrorPartner(of: channel, layout: layout) {
                additions.insert(partner)
            }
        }
        selectedIndices.formUnion(additions)
    }

    /// The electrode whose position most closely mirrors `channel` across the
    /// midline (x → −x, same y). Returns `nil` if no good partner exists.
    private func mirrorPartner(of channel: Int, layout: SensorLayout) -> Int? {
        guard let source = layout.positions.first(where: { $0.channelIndex == channel }) else { return nil }
        let targetX = -source.x
        let targetY = source.y
        var best: (index: Int, distance: Double)? = nil
        for candidate in layout.positions where candidate.channelIndex != channel {
            let d = hypot(candidate.x - targetX, candidate.y - targetY)
            if best == nil || d < best!.distance {
                best = (candidate.channelIndex, d)
            }
        }
        // Reject if the nearest mirror is implausibly far (e.g. a midline
        // electrode whose true partner is itself).
        guard let best, best.distance < 0.18 else { return nil }
        return best.index
    }

    private func prepareExport(sets: [ChannelSet]) {
        guard let data = try? store.exportData(sets: sets) else { return }
        exportDocument = ChannelSetDocument(data: data)
        showsExportPanel = true
    }

    private func exportCurrentSet() {
        guard let set = editingSet else { return }
        prepareExport(sets: [set])
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Access denied to the selected file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else {
                errorMessage = "Could not read the selected file."
                return
            }
            do {
                try store.importSets(from: data)
            } catch {
                errorMessage = "Import failed: \(error.localizedDescription)"
            }
        case .failure(let error):
            errorMessage = "Could not open file: \(error.localizedDescription)"
        }
    }
}

// MARK: - FileDocument for export

struct ChannelSetDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = d
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
