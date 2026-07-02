//
//  ContentView.swift
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

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A set of dropped .mff URLs awaiting the combine sheet.
struct CombineRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ContentView: View {
    @Binding var recording: MFFRecording?
    @Binding var openRecordingRequest: Int

    @AppStorage(ToolbarButtonLabels.storageKey) private var showsToolbarButtonLabels = true

    @State private var showsFileImporter = false
    @State private var isDropTargeted = false
    @State private var openError: String?
    /// Multiple .mff files dropped at once → present the combine sheet.
    @State private var combineRequest: CombineRequest?

    var body: some View {
        Group {
            if let recording {
                WaveformView(recording: recording)
                    .id(recording.id)
            } else {
                launchScreen
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 4, dash: [10, 6]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            openDroppedURLs(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.mff, .data, .plainText],
            allowsMultipleSelection: true
        ) { result in
            handleImportResult(result)
        }
        .onChange(of: openRecordingRequest) { _, _ in
            showsFileImporter = true
        }
        .sheet(item: $combineRequest) { request in
            CombineRecordingsSheet(
                urls: request.urls,
                onComplete: { packageURL in
                    combineRequest = nil
                    open(packageURL)
                },
                onCancel: { combineRequest = nil }
            )
        }
        .background(WindowAccessor(autosaveName: "EVAMainWindow",
                                   hasRecording: recording != nil,
                                   onConfirmedClose: closeRecording))
    }

    /// Closes the current recording and returns the window to a fresh launch
    /// state. Because `WaveformView` is keyed by `recording.id`, dropping the
    /// recording discards all of its per-recording in-memory state; opening a
    /// new file builds a brand-new view.
    private func closeRecording() {
        recording = nil
        openError = nil
        isDropTargeted = false
        showsFileImporter = false
    }

    private var launchScreen: some View {
        VStack(spacing: 0) {
            launchControlBar

            Divider()

            startScreen
        }
    }

    private var launchControlBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Amplitude")
                        .font(.caption.weight(.semibold))
                        .frame(width: 72, alignment: .leading)
                    Slider(value: .constant(100.0), in: 10...1000, step: 10)
                        .frame(width: 170)
                        .disabled(true)
                    Text("100 µV")
                        .font(.caption.monospacedDigit())
                        .frame(width: 64, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    Text("Time Scale")
                        .font(.caption.weight(.semibold))
                        .frame(width: 72, alignment: .leading)
                    Slider(value: .constant(1.0), in: 0.2...8, step: 0.1)
                        .frame(width: 170)
                        .disabled(true)
                    Text("1.0x")
                        .font(.caption.monospacedDigit())
                        .frame(width: 64, alignment: .trailing)
                }
            }

            HStack(spacing: 6) {
                idleToolbarButton(name: "icon.mri", label: "MRI")
                idleToolbarButton(name: "icon.filter", label: "Filter")
                idleToolbarButton(name: "icon.artifacts", label: "Artifacts")
                idleToolbarButton(name: "icon.process", label: "Processing", buttonLabel: "PROCESS")
                idleToolbarButton(name: "icon.eeg-processing", label: "EEG Processing", buttonLabel: "EEG")
                idleToolbarButton(name: "icon.events", label: "Events")
            }

            Spacer(minLength: 12)

            idleStatusLog
                .frame(width: 240)

            Text("No recording open")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func idleToolbarButton(
        name: String,
        label: String,
        buttonLabel: String? = nil,
        inactiveForeground: Color = .primary
    ) -> some View {
        Button {} label: {
            ToolbarIcon(
                name: name,
                label: showsToolbarButtonLabels ? (buttonLabel ?? label) : nil,
                inactiveForeground: inactiveForeground
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .disabled(true)
        .help("Open an MFF recording to use \(label).")
    }

    private var idleStatusLog: some View {
        Text("Ready")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .accessibilityLabel("Status log")
    }

    private var startScreen: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("EVA")
                    .font(.largeTitle.weight(.semibold))
                Text("Electrophysiology Viewer and Analysis")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            Button("Open Recording...") {
                showsFileImporter = true
            }
            .keyboardShortcut("o", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Drop .mff, BrainVision, EDF, Persyst, or BESA .avr/.mul recordings here")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let openError {
                Text(openError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            openSelectedURLs(urls)
        case .failure(let error):
            openError = error.localizedDescription
        }
    }

    private func openDroppedURLs(_ urls: [URL]) -> Bool {
        openSelectedURLs(urls)
    }

    @discardableResult
    private func openSelectedURLs(_ urls: [URL]) -> Bool {
        let supportedURLs = urls.filter(isSupportedRecordingURL)
        let mffURLs = supportedURLs.filter { $0.pathExtension.lowercased() == "mff" }
        if mffURLs.count > 1 {
            combineRequest = CombineRequest(urls: mffURLs)
            return true
        }

        let brainVisionURLs = supportedURLs.filter(isBrainVisionURL)
        if !brainVisionURLs.isEmpty {
            return openBrainVisionSelection(brainVisionURLs)
        }

        guard let url = supportedURLs.first else {
            openError = "EVA can open .mff, BrainVision, EDF, Persyst, and BESA .avr/.mul recordings."
            return false
        }
        return open(url, securityScopedURLs: supportedURLs)
    }

    @discardableResult
    private func open(_ url: URL, securityScopedURLs: [URL] = []) -> Bool {
        guard isSupportedRecordingURL(url) else {
            openError = "EVA can open .mff, BrainVision, EDF, Persyst, and BESA .avr/.mul recordings."
            return false
        }

        openError = nil
        recording = MFFRecording(packageURL: url, securityScopedURLs: securityScopedURLs)
        return true
    }

    private func isSupportedRecordingURL(_ url: URL) -> Bool {
        SignalImportReader.isSupportedRecordingURL(url)
    }

    private func isBrainVisionURL(_ url: URL) -> Bool {
        ["vhdr", "vmrk", "eeg"].contains(url.pathExtension.lowercased())
    }

    private func openBrainVisionSelection(_ urls: [URL]) -> Bool {
        guard let headerURL = brainVisionHeaderURL(from: urls) else {
            openError = "BrainVision recordings need a .vhdr header file."
            return false
        }

        var scopedURLs = urls
        if !selectionIncludesBrainVisionSet(urls) {
            guard let folderURL = requestBrainVisionFolderAccess(containing: headerURL) else {
                openError = "BrainVision recordings use .vhdr, .vmrk, and .eeg sidecar files. Select the containing folder or choose all three files together."
                return false
            }
            scopedURLs.append(folderURL)
        }

        return open(headerURL, securityScopedURLs: scopedURLs)
    }

    private func brainVisionHeaderURL(from urls: [URL]) -> URL? {
        if let header = urls.first(where: { $0.pathExtension.lowercased() == "vhdr" }) {
            return header
        }
        guard let sidecar = urls.first(where: isBrainVisionURL) else { return nil }
        return sidecar.deletingPathExtension().appendingPathExtension("vhdr")
    }

    private func selectionIncludesBrainVisionSet(_ urls: [URL]) -> Bool {
        let extensions = Set(urls.map { $0.pathExtension.lowercased() })
        return extensions.isSuperset(of: ["vhdr", "vmrk", "eeg"])
    }

    private func requestBrainVisionFolderAccess(containing headerURL: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = headerURL.deletingLastPathComponent()
        panel.prompt = "Grant Access"
        panel.message = "BrainVision recordings use multiple files. Select the folder that contains the .vhdr, .vmrk, and .eeg files."
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Sets an AppKit frame-autosave name on the hosting window and intercepts
/// the close button to show a discard-confirmation sheet when a recording is open.
private struct WindowAccessor: NSViewRepresentable {
    let autosaveName: String
    var hasRecording: Bool = false
    var onConfirmedClose: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hasRecording = hasRecording
        context.coordinator.onConfirmedClose = onConfirmedClose
        let autosaveName = autosaveName
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.frameAutosaveName != autosaveName {
                window.setFrameAutosaveName(autosaveName)
            }
            context.coordinator.attach(to: window)
        }
    }

    /// Intercepts `windowShouldClose` to show a discard-confirmation alert sheet
    /// when a recording is open; forwards all other delegate messages to SwiftUI's
    /// original delegate so lifecycle and state restoration keep working.
    final class Coordinator: NSObject, NSWindowDelegate {
        var hasRecording = false
        var onConfirmedClose: (() -> Void)?
        private weak var originalDelegate: NSWindowDelegate?

        func attach(to window: NSWindow) {
            guard window.delegate !== self else { return }
            originalDelegate = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if hasRecording {
                showDiscardSheet(for: sender)
                return false
            }
            if let originalDelegate,
               originalDelegate.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
                return originalDelegate.windowShouldClose?(sender) ?? true
            }
            return true
        }

        private func showDiscardSheet(for window: NSWindow) {
            let alert = NSAlert()
            alert.messageText = "Discard unsaved work?"
            alert.informativeText = "Closing this recording will discard any processing that has not been exported. This cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.onConfirmedClose?()
                }
            }
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if originalDelegate?.responds(to: aSelector) == true { return originalDelegate }
            return super.forwardingTarget(for: aSelector)
        }
    }
}

#Preview {
    ContentView(recording: .constant(nil), openRecordingRequest: .constant(0))
}
