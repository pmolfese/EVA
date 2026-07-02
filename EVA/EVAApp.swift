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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import SwiftData
import SwiftUI

@main
struct EVAApp: App {
    @State private var recording: MFFRecording?
    @State private var openRecordingRequest = 0
    @State private var goodnessSettings = ChannelGoodnessSettings()
    @State private var processingDefaults = ProcessingDefaults.shared

    var body: some Scene {
        WindowGroup {
            ContentView(
                recording: $recording,
                openRecordingRequest: $openRecordingRequest
            )
            .environment(goodnessSettings)
            .environment(processingDefaults)
        }
        .modelContainer(for: UserMarker.self)
        .defaultSize(Self.defaultWindowSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Recording...") {
                    openRecordingRequest += 1
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                FileExportCommands()
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
                .environment(processingDefaults)
        }
    }

    static let debugLogWindowID = "debug-log"
    static let channelSetsWindowID = "channel-sets"

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
