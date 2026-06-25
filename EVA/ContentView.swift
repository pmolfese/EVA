//
//  ContentView.swift
//  EVA
//
//  Created by Molfese, Peter  [E] on 6/25/26.
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
                startScreen
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
            allowedContentTypes: [.mff],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .onChange(of: openRecordingRequest) { _, _ in
            showsFileImporter = true
        }
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

            Button("Open MFF...") {
                showsFileImporter = true
            }
            .keyboardShortcut("o", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Drop an .mff package anywhere in this window")
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
            openError = "EVA can open EGI .mff packages right now."
            return false
        }

        openError = nil
        recording = MFFRecording(packageURL: url)
        return true
    }

    private func isSupportedRecordingURL(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("mff") == .orderedSame
    }
}

#Preview {
    ContentView(recording: .constant(nil), openRecordingRequest: .constant(0))
}
