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

struct ContentView: View {
    @Binding var recording: MFFRecording?
    @Binding var openRecordingRequest: Int

    @State private var showsFileImporter = false
    @State private var isDropTargeted = false
    @State private var openError: String?

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
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .onChange(of: openRecordingRequest) { _, _ in
            showsFileImporter = true
        }
        .background(WindowAccessor(autosaveName: "EVAMainWindow", onCloseRequest: {
            // Closing a window that has a recording open doesn't close the
            // window — it closes the file and resets to the launch screen so the
            // user can drop a new EEG file. With no recording open, close as
            // usual.
            if recording != nil {
                closeRecording()
                return false
            }
            return true
        }))
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
                idleToolbarButton(name: "icon.process", label: "Processing")
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

    private func idleToolbarButton(name: String, label: String) -> some View {
        Button {} label: {
            ToolbarIcon(name: name)
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
            guard let url = urls.first else { return }
            open(url)
        case .failure(let error):
            openError = error.localizedDescription
        }
    }

    private func openDroppedURLs(_ urls: [URL]) -> Bool {
        guard let url = urls.first else { return false }
        return open(url)
    }

    @discardableResult
    private func open(_ url: URL) -> Bool {
        guard isSupportedRecordingURL(url) else {
            openError = "EVA can open .mff, BrainVision, EDF, Persyst, and BESA .avr/.mul recordings."
            return false
        }

        openError = nil
        recording = MFFRecording(packageURL: url)
        return true
    }

    private func isSupportedRecordingURL(_ url: URL) -> Bool {
        SignalImportReader.isSupportedRecordingURL(url)
    }
}

/// Sets an AppKit frame-autosave name on the hosting window so its size and
/// position are remembered, and intercepts the window close so the app can
/// decide whether to actually close or just reset to the launch screen.
private struct WindowAccessor: NSViewRepresentable {
    let autosaveName: String
    /// Invoked when the window is asked to close. Return `true` to allow the
    /// close, `false` to keep the window open.
    let onCloseRequest: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCloseRequest = onCloseRequest
        let autosaveName = autosaveName
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            if window.frameAutosaveName != autosaveName {
                window.setFrameAutosaveName(autosaveName)
            }
            context.coordinator.attach(to: window)
        }
    }

    /// Window delegate that intercepts `windowShouldClose` and otherwise forwards
    /// every message to SwiftUI's original delegate (so window lifecycle and
    /// state restoration keep working).
    final class Coordinator: NSObject, NSWindowDelegate {
        var onCloseRequest: (() -> Bool)?
        private weak var originalDelegate: NSWindowDelegate?

        func attach(to window: NSWindow) {
            // Already installed (and SwiftUI hasn't replaced us): nothing to do.
            guard window.delegate !== self else { return }
            originalDelegate = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if onCloseRequest?() == false { return false }
            if let originalDelegate,
               originalDelegate.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
                return originalDelegate.windowShouldClose?(sender) ?? true
            }
            return true
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
