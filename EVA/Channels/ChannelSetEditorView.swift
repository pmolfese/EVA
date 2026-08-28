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

    /// The standalone editor historically owned its Done button. The unified
    /// Channels window owns that button at the window level, so its embedded
    /// Channel Sets tab turns this one off while previews/legacy callers keep
    /// the old behavior by default.
    var showsDismissButton = true

    private var layout: SensorLayout? { ChannelSetStore.shared.activeSensorLayout }
    private var channelNames: [String]? { ChannelSetStore.shared.activeChannelNames }

    @State private var sidebarSelection: ChannelSet.ID? = nil
    @State private var editingSet: ChannelSet? = nil
    @State private var editingName: String = ""
    /// `nil` means "any net" (`ChannelSet.netType == nil`). Editable for both
    /// new and existing sets — see `netTypeControl`.
    @State private var editingNetType: String? = nil
    /// Backs the "Other…" free-text entry in `netTypeControl`.
    @State private var netTypeTextEntry: String = ""
    @State private var showsNetTypeTextField = false
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
    /// Which net's "save this geometry?" banner was last dismissed with
    /// "Not Now" — so switching away and back to the *same* still-unsaved
    /// net doesn't keep re-asking, while a genuinely different novel net
    /// still prompts. Session-only, not persisted; reset when the window
    /// reopens.
    @State private var dismissedNetPrompt: String? = nil
    @State private var saveNetNameEntry: String = ""
    @State private var showsManageNets = false
    /// `nil` = show every set. Sets tagged "Any Net" (`netType == nil`) stay
    /// visible under every filter, including a specific one — they are
    /// explicitly meant to apply regardless of net, so a filter hiding them
    /// would hide sets that are perfectly valid for whatever's selected.
    @State private var netFilter: String? = nil

    private var store: ChannelSetStore { .shared }

    private func matchesFilter(_ set: ChannelSet) -> Bool {
        netFilter == nil || set.netType == nil || set.netType == netFilter
    }

    var body: some View {
        HSplitView {
            sidebarList
                .frame(minWidth: 210, idealWidth: 230, maxWidth: 280)

            centerPane
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

            inspectorPane
                .frame(minWidth: 240, idealWidth: 270, maxWidth: 320, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) { unsavedNetBanner }
        .navigationTitle("Channel Sets")
        .frame(minWidth: 900, minHeight: 560)
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
        .sheet(isPresented: $showsManageNets) {
            ManageNetGeometriesSheet()
        }
    }

    /// Offers to save the *focused recording's own* geometry into the
    /// catalog, the first time this editor sees a net it doesn't already
    /// know about — see `ChannelSetStore`'s file header: this is the whole
    /// mechanism by which the catalog grows, deliberately in place of
    /// bundling guessed positions.
    @ViewBuilder
    private var unsavedNetBanner: some View {
        if let layout, store.geometry(named: layout.name) == nil, dismissedNetPrompt != layout.name {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This recording's net (\"\(layout.name)\") hasn't been saved yet.")
                        .font(.callout)
                    Text("Save it so sets can be created for it without this file open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                TextField("Name", text: $saveNetNameEntry)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button("Save") {
                    store.saveGeometry(name: saveNetNameEntry, positions: layout.positions)
                    dismissedNetPrompt = layout.name
                }
                .disabled(saveNetNameEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Not Now") { dismissedNetPrompt = layout.name }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
            .onAppear {
                saveNetNameEntry = layout.name
                maybeAutoSaveNet(layout)
            }
            .onChange(of: layout.name) { _, new in
                saveNetNameEntry = new
                maybeAutoSaveNet(layout)
            }
        }
    }

    /// `Preferences ▸ Channel Sets ▸ "Auto-save nets I haven't seen before"`
    /// (2026-08-16) — saves under the recording's own reported name instead
    /// of waiting on the banner's "Save" click. Gated to MFF-sourced
    /// recordings unless the second preference is also on; see
    /// `ChannelSetStore.activeIsMFFSource`'s doc comment for why. Setting
    /// `dismissedNetPrompt` here (not just saving) is what keeps the banner
    /// itself from ever actually appearing — its guard already checks
    /// `store.geometry(named:) == nil`, which becomes false the instant this
    /// saves.
    private func maybeAutoSaveNet(_ layout: SensorLayout) {
        let defaults = ProcessingDefaults.shared
        guard defaults.autoSaveNewNetGeometries else { return }
        guard store.activeIsMFFSource || defaults.autoSaveNewNetGeometriesFromNonMFF else { return }
        guard store.geometry(named: layout.name) == nil else { return }
        store.saveGeometry(name: layout.name, positions: layout.positions)
        dismissedNetPrompt = layout.name
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if showsDismissButton {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarList: some View {
        VStack(spacing: 0) {
            netFilterControl
            Divider()
            List(selection: $sidebarSelection) {
                let builtIn = ChannelSetStore.builtInSets.filter(matchesFilter)
                let userDefined = store.userSets.filter(matchesFilter)

                if !builtIn.isEmpty {
                    Section("Built-In") {
                        ForEach(builtIn) { set in
                            channelSetRow(set)
                                .tag(set.id)
                        }
                    }
                }
                if !userDefined.isEmpty {
                    Section("My Sets") {
                        ForEach(userDefined) { set in
                            channelSetRow(set)
                                .tag(set.id)
                        }
                    }
                }
                if builtIn.isEmpty && userDefined.isEmpty {
                    Text("No sets for this net.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)

            Divider()
            sidebarFooter
        }
        .onChange(of: sidebarSelection) { _, id in
            if let id, let set = store.allSets.first(where: { $0.id == id }) {
                loadSet(set)
            }
        }
    }

    /// "All Nets" plus every name `store.knownNetNames` offers. Filtering
    /// out to a specific net still shows "Any Net"-tagged sets — see
    /// `matchesFilter`.
    private var netFilterControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Show sets for")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker("Net", selection: $netFilter) {
                Text("All Nets").tag(String?.none)
                if !store.knownNetNames.isEmpty {
                    Divider()
                    ForEach(store.knownNetNames, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 0) {
            Button {
                beginNewSet()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Channel Set")

            Divider()
                .frame(height: 30)

            Menu {
                Button("Import Channel Sets…") { showsImportPanel = true }
                Button("Export All Channel Sets…") { prepareExport(sets: store.allSets) }
                Divider()
                Button("Manage Saved Nets…") { showsManageNets = true }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 38, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Channel Set Actions")

            Spacer()
        }
        .frame(height: 31)
    }

    @ViewBuilder
    private func channelSetRow(_ set: ChannelSet) -> some View {
        HStack(spacing: 8) {
            Image(systemName: store.isBuiltIn(set) ? "circle.grid.3x3.fill" : "circle.grid.3x3")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(set.name)
                    .lineLimit(1)
                if let net = set.netType {
                    Text(net)
                        .lineLimit(1)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)
            Text("\(set.channelIndices.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Center pane

    @ViewBuilder
    private var centerPane: some View {
        if sidebarSelection == nil && editingSet == nil && !isCreatingNew {
            ContentUnavailableView(
                "No Channel Set Selected",
                systemImage: "antenna.radiowaves.left.and.right",
                description: Text("Choose a set from the sidebar, or click \(Image(systemName: "plus")) to create one.")
            )
        } else {
            VStack(spacing: 0) {
                mapToolbar

                if let layout {
                    VStack(spacing: 10) {
                        ChannelSetMapView(
                            layout: layout,
                            selectedIndices: $selectedIndices,
                            interactive: !isViewingBuiltIn,
                            channelLabel: channelDisplayLabel,
                            onToggle: forceSymmetry && !isViewingBuiltIn
                                ? { channel, nowSelected in
                                    applySymmetry(to: channel, nowSelected: nowSelected, layout: layout)
                                  }
                                : nil
                        )
                        if !unpositionedChannelIndices(in: layout).isEmpty {
                            unpositionedChannelsView(unpositionedChannelIndices(in: layout))
                        }
                    }
                    .padding(16)
                } else {
                    noLayoutFallback
                        .padding(16)
                }

                Divider()
                mapFooter
            }
        }
    }

    private var mapToolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(editingName.isEmpty ? "New Channel Set" : editingName)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(selectedIndices.count) channel\(selectedIndices.count == 1 ? "" : "s") · \(editingNetType ?? "Any Net")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Select All") {
                selectedIndices = allAvailableChannelIndices
                if forceSymmetry, let layout { mirrorEntireSelection(layout: layout) }
            }
            .disabled(isViewingBuiltIn || allAvailableChannelIndices.isEmpty)

            Button("Clear") { selectedIndices.removeAll() }
                .disabled(isViewingBuiltIn || selectedIndices.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var mapFooter: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.blue.opacity(0.28))
                .frame(width: 11, height: 11)
                .overlay(Circle().stroke(.blue, lineWidth: 1))
            Text("Included in set")
            Text(isViewingBuiltIn ? "Built-in sets are read-only" : "Click electrodes to add or remove them")
                .foregroundStyle(.secondary)
            Spacer()
            if !selectedChannelSummary.isEmpty {
                Text(selectedChannelSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 250, alignment: .trailing)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(.bar)
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspectorPane: some View {
        if sidebarSelection == nil && editingSet == nil && !isCreatingNew {
            VStack(spacing: 0) {
                inspectorTitle
                Spacer()
            }
            .background(.bar)
        } else {
            VStack(spacing: 0) {
                inspectorTitle
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        inspectorIdentity
                        Divider()
                        inspectorSelection
                        Divider()
                        inspectorActions
                    }
                    .padding(14)
                }

                if !isViewingBuiltIn {
                    Divider()
                    inspectorSaveBar
                }
            }
            .background(.bar)
        }
    }

    private var inspectorTitle: some View {
        HStack {
            Text("Channel Set")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var inspectorIdentity: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isViewingBuiltIn {
                    Text(editingName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Channel Set Name", text: $editingName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Applies to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isViewingBuiltIn {
                    Text(editingNetType ?? "Any Net")
                } else {
                    netTypeControl
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var inspectorSelection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Channels")
                Spacer()
                Text("\(selectedIndices.count)")
                    .font(.title2.monospacedDigit())
            }

            if !isViewingBuiltIn, layout != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Keep selection symmetric", isOn: $forceSymmetry)
                        .toggleStyle(.checkbox)
                        .onChange(of: forceSymmetry) { _, on in
                            if on, let layout { mirrorEntireSelection(layout: layout) }
                        }
                    Text("Selecting a channel also selects its partner in the opposite hemisphere.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }
        }
    }

    private var inspectorActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                saveAsName = editingName + " Copy"
                showsSaveAsAlert = true
            } label: {
                Label("Duplicate Set…", systemImage: "plus.square.on.square")
            }
            .buttonStyle(.plain)
            .disabled(editingSet == nil)

            Button(action: exportCurrentSet) {
                Label("Export Set…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(editingSet == nil)

            if !isViewingBuiltIn {
                Button(role: .destructive) {
                    showsDeleteConfirmation = true
                } label: {
                    Label("Delete Set…", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .disabled(editingSet == nil)
            }
        }
        .foregroundStyle(Color.accentColor)
    }

    private var inspectorSaveBar: some View {
        HStack(spacing: 8) {
            Text(hasUnsavedChanges ? "Unsaved changes" : "Saved")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Revert") { resetEdits() }
                .disabled(!hasUnsavedChanges)
            Button("Save") { commitSave(asNew: false) }
                .buttonStyle(.borderedProminent)
                .disabled(editingName.trimmingCharacters(in: .whitespaces).isEmpty || !hasUnsavedChanges)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(10)
    }

    /// Which net this set applies to — editable for new and existing sets
    /// alike, backed by `editingNetType`. Options come from
    /// `store.knownNetNames` (saved geometries plus any net name already
    /// used by another set), with "Other…" for typing one that isn't there
    /// yet. Typing a brand-new name here does not by itself save a
    /// geometry — a set can be tagged for a net EVA has never seen positions
    /// for; `unsavedNetPrompt` is the separate, geometry-specific offer.
    @ViewBuilder
    private var netTypeControl: some View {
        if showsNetTypeTextField {
            HStack(spacing: 4) {
                TextField("Net name", text: $netTypeTextEntry)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit { commitNetTypeTextEntry() }
                Button("Set") { commitNetTypeTextEntry() }
                Button("Cancel") {
                    showsNetTypeTextField = false
                    netTypeTextEntry = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        } else {
            Menu {
                Button("Any Net") { editingNetType = nil }
                if !store.knownNetNames.isEmpty {
                    Divider()
                    ForEach(store.knownNetNames, id: \.self) { name in
                        Button(name) { editingNetType = name }
                    }
                }
                Divider()
                Button("Other…") {
                    netTypeTextEntry = editingNetType ?? ""
                    showsNetTypeTextField = true
                }
            } label: {
                Text(editingNetType ?? "Any Net")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Which net this set applies to. \"Any Net\" means it's offered regardless of which recording is open.")
        }
    }

    private func commitNetTypeTextEntry() {
        let trimmed = netTypeTextEntry.trimmingCharacters(in: .whitespaces)
        editingNetType = trimmed.isEmpty ? nil : trimmed
        showsNetTypeTextField = false
        netTypeTextEntry = ""
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
                Text(selectedChannelSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unpositionedChannelsView(_ indices: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No plotted location")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(indices, id: \.self) { index in
                        unpositionedChannelButton(index)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func unpositionedChannelButton(_ index: Int) -> some View {
        let label = channelDisplayLabel(index)
        let selected = selectedIndices.contains(index)
        let foreground = selected ? Color.blue : Color.primary.opacity(0.75)
        let fill = selected ? Color.blue.opacity(0.18) : Color.primary.opacity(0.08)
        let stroke = selected ? Color.blue.opacity(0.65) : Color.primary.opacity(0.16)

        return Button {
            guard !isViewingBuiltIn else { return }
            if selected {
                selectedIndices.remove(index)
            } else {
                selectedIndices.insert(index)
            }
        } label: {
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(foreground)
                .background(Capsule().fill(fill))
                .overlay(Capsule().stroke(stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isViewingBuiltIn)
        .help(label)
    }

    // MARK: - Helpers

    private var isViewingBuiltIn: Bool {
        editingSet.map { store.isBuiltIn($0) } ?? false
    }

    private var allAvailableChannelIndices: Set<Int> {
        if let channelNames, !channelNames.isEmpty {
            return Set(channelNames.indices)
        }
        if let layout {
            return Set(layout.positions.map(\.channelIndex))
        }
        return []
    }

    private var hasUnsavedChanges: Bool {
        guard let set = editingSet else { return isCreatingNew }
        return editingName != set.name
            || editingNetType != set.netType
            || selectedIndices != Set(set.channelIndices)
    }

    private var selectedChannelSummary: String {
        let labels = selectedIndices.sorted().map(channelDisplayLabel)
        guard !labels.isEmpty else { return "" }
        let visible = labels.prefix(24).joined(separator: ", ")
        let remaining = labels.count - 24
        return remaining > 0 ? "\(visible), +\(remaining) more" : visible
    }

    private func unpositionedChannelIndices(in layout: SensorLayout) -> [Int] {
        guard let channelNames, !channelNames.isEmpty else { return [] }
        let positioned = Set(layout.positions.map(\.channelIndex))
        return channelNames.indices.filter { !positioned.contains($0) }
    }

    private func channelDisplayLabel(_ index: Int) -> String {
        if let channelNames,
           channelNames.indices.contains(index) {
            let trimmed = channelNames[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "\(index + 1)"
    }

    private func loadSet(_ set: ChannelSet) {
        editingSet = set
        editingName = set.name
        editingNetType = set.netType
        showsNetTypeTextField = false
        selectedIndices = Set(set.channelIndices)
        isCreatingNew = false
    }

    private func beginNewSet() {
        sidebarSelection = nil
        editingSet = nil
        editingName = ""
        // Defaults to whichever net is actually focused, when there is one —
        // the common case is "I have this file open, I want a set for it,"
        // and defaulting to "Any net" would make that the extra step instead
        // of the free action.
        editingNetType = layout?.name
        showsNetTypeTextField = false
        selectedIndices = []
        forceSymmetry = false
        isCreatingNew = true
    }

    private func resetEdits() {
        if let set = editingSet {
            loadSet(set)
        } else {
            editingName = ""
            editingNetType = layout?.name
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
            netType: editingNetType
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

// MARK: - Manage Nets

/// Rename (with merge-on-collision, via `ChannelSetStore.renameGeometry`) and
/// delete for the saved net-geometry catalog. The scenario this exists for:
/// "typed '64 channel' two ways and now has two entries that mean the same
/// net" — renaming one onto the other's name consolidates them.
private struct ManageNetGeometriesSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var store: ChannelSetStore { .shared }

    @State private var renamingID: KnownNetGeometry.ID?
    @State private var renameText = ""

    private var sortedGeometries: [KnownNetGeometry] {
        store.knownGeometries.sorted { $0.name < $1.name }
    }

    /// Net names that are still "known" (still offered by the filter and the
    /// "+" picker, via `ChannelSetStore.knownNetNames`) purely because a
    /// channel set is still tagged with them — not because there's a saved
    /// geometry to manage here. `deleteGeometry` deliberately leaves those
    /// tags alone (see its doc comment), which used to mean a name someone
    /// just deleted looked like it had simply vanished from this sheet while
    /// still showing up in the filter, with no way back in from here
    /// (2026-08-16, manual test finding: "I can't re-add it since the list
    /// is empty"). Listed separately, read-only, so it's clear these aren't
    /// missing rows — there's nothing to rename or delete, only a real
    /// recording's own geometry to save under the same name again.
    private var tagOnlyNetNames: [String] {
        let geometryNames = Set(store.knownGeometries.map(\.name))
        return store.knownNetNames.filter { !geometryNames.contains($0) }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Saved Net Geometries")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(14)

            Divider()

            if sortedGeometries.isEmpty, tagOnlyNetNames.isEmpty {
                ContentUnavailableView(
                    "No Saved Nets",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Save a recording's net from the Channel Sets editor's banner to see it here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !sortedGeometries.isEmpty {
                        Section {
                            ForEach(sortedGeometries) { geometry in
                                row(for: geometry)
                            }
                        }
                    }
                    if !tagOnlyNetNames.isEmpty {
                        Section {
                            ForEach(tagOnlyNetNames, id: \.self) { name in
                                HStack {
                                    Text(name)
                                    Spacer()
                                    Text("No saved geometry")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        } header: {
                            Text("Used by channel sets, no geometry saved")
                        } footer: {
                            Text("Open a recording with this net and type this exact name into the Channel Sets editor's banner to attach geometry again.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(width: 440, height: 380)
    }

    @ViewBuilder
    private func row(for geometry: KnownNetGeometry) -> some View {
        HStack(spacing: 10) {
            if renamingID == geometry.id {
                TextField("Net name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(geometry) }
            } else {
                Text(geometry.name)
                Spacer()
                Text("\(geometry.positions.count) ch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                if renamingID == geometry.id {
                    commitRename(geometry)
                } else {
                    renameText = geometry.name
                    renamingID = geometry.id
                }
            } label: {
                Image(systemName: renamingID == geometry.id ? "checkmark" : "pencil")
            }
            .buttonStyle(.plain)
            .help(renamingID == geometry.id ? "Save name" : "Rename")

            Button(role: .destructive) {
                if renamingID == geometry.id { renamingID = nil }
                store.deleteGeometry(geometry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
        .padding(.vertical, 2)
    }

    private func commitRename(_ geometry: KnownNetGeometry) {
        store.renameGeometry(geometry, to: renameText)
        renamingID = nil
        renameText = ""
    }
}
