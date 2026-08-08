//
//  EVAApp.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import AppKit
import SwiftData
import SwiftUI

@main
struct EVAApp: App {
    @State private var recording: MFFRecording?
    @State private var openRecordingRequest = 0
    @State private var closeRecordingRequest = 0
    @State private var batchSetupRequest = 0
    @State private var goodnessSettings = ChannelGoodnessSettings()
    @State private var segmentGoodnessSettings = SegmentGoodnessSettings()
    @State private var processingDefaults = ProcessingDefaults.shared
    @State private var batch = BatchController()
    @State private var isCheckingForUpdates = false

    var body: some Scene {
        WindowGroup {
            ContentView(
                recording: $recording,
                openRecordingRequest: $openRecordingRequest,
                closeRecordingRequest: $closeRecordingRequest,
                batchSetupRequest: $batchSetupRequest
            )
            .environment(goodnessSettings)
            .environment(segmentGoodnessSettings)
            .environment(processingDefaults)
            .environment(batch)
        }
        .modelContainer(for: UserMarker.self)
        .defaultSize(Self.defaultWindowSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(isCheckingForUpdates ? "Checking for Updates..." : "Check for Updates...") {
                    checkForUpdates()
                }
                .disabled(isCheckingForUpdates)
            }

            CommandGroup(replacing: .newItem) {
                Button("Open Recording...") {
                    openRecordingRequest += 1
                }
                .keyboardShortcut("o", modifiers: .command)

                FileExportCommands()

                Button("Batch Process...") {
                    batchSetupRequest += 1
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Divider()

                Button("Close File") {
                    closeRecordingRequest += 1
                }
                .disabled(recording == nil)

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                ViewCommands()
            }

            CommandMenu("Channels") {
                ChannelsCommands()
            }

            CommandMenu("Artifacts") {
                ArtifactsCommands()
            }

            CommandGroup(after: .windowArrangement) {
                OpenDebugLogButton()
            }
        }

        Window("Debug Log", id: Self.debugLogWindowID) {
            DebugLogView()
        }
        .defaultSize(width: 640, height: 480)

        Window("Channel Sets", id: Self.channelSetsWindowID) {
            ChannelSetEditorView()
        }
        .defaultSize(width: 800, height: 580)

        Settings {
            PreferencesView()
                .environment(goodnessSettings)
                .environment(segmentGoodnessSettings)
                .environment(processingDefaults)
        }
    }

    static let debugLogWindowID = "debug-log"
    static let channelSetsWindowID = "channel-sets"

    private func checkForUpdates() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true

        Task { @MainActor in
            defer { isCheckingForUpdates = false }

            let currentVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "Unknown"

            do {
                let result = try await UpdateChecker().check(currentVersion: currentVersion)
                UpdateAlertPresenter.present(result)
            } catch {
                UpdateAlertPresenter.present(error: error)
            }
        }
    }

    private static var defaultWindowSize: CGSize {
        let frame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGSize(width: frame.width * 2 / 3, height: frame.height / 2)
    }
}

/// Window-menu item that opens the Debug Log window.
private struct OpenDebugLogButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Debug Log") {
            openWindow(id: EVAApp.debugLogWindowID)
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}
