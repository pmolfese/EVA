//
//  ContentView.swift
//  EVA
//
//  Copyright (C) 2026 Peter Molfese
//  SPDX-License-Identifier: GPL-3.0-only
//

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

#Preview {
    ContentView(recording: .constant(nil), openRecordingRequest: .constant(0))
}
