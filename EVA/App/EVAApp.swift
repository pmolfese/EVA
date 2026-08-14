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
        // `Window`, not `WindowGroup`, and that is the fix for double-opening.
        //
        // A `WindowGroup` can instantiate more than one window, and macOS uses
        // that: on a Finder open the group creates its launch window *and* then
        // spawns a second one to deliver the URL to, so you get two windows with
        // the file in the front one. Intermittent, because it depends on whether
        // the open-file Apple event lands before or after the launch window
        // exists.
        //
        // A `Window` scene is single-instance by construction, so the second
        // window cannot be created and `onOpenURL` is delivered to the one that
        // is already there.
        //
        // This is also the honest description of the app: `recording` is `@State`
        // on `EVAApp`, so every window of a group would render the *same*
        // recording. Two windows were never useful here — they were two views of
        // one document that could not diverge. "New Window" was already absent
        // too, since `CommandGroup(replacing: .newItem)` replaces New with
        // "Open Recording…".
        Window("EVA", id: "main") {
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

            CommandGroup(replacing: .help) {
                OpenReleaseNotesButton()
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

        Window("Release Notes", id: Self.releaseNotesWindowID) {
            ReleaseNotesView()
        }
        .defaultSize(width: 1000, height: 720)

        Settings {
            PreferencesView()
                .environment(goodnessSettings)
                .environment(segmentGoodnessSettings)
                .environment(processingDefaults)
        }
    }

    static let debugLogWindowID = "debug-log"
    static let channelSetsWindowID = "channel-sets"
    static let releaseNotesWindowID = "release-notes"

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

/// Help-menu item that opens the Release Notes window.
///
/// Replaces the default "EVA Help" item, which pointed at a help book EVA does
/// not ship.
private struct OpenReleaseNotesButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Release Notes") {
            openWindow(id: EVAApp.releaseNotesWindowID)
        }
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
