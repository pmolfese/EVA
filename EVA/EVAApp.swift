//
//  EVAApp.swift
//  EVA
//
//  Created by Molfese, Peter  [E] on 6/25/26.
//

import AppKit
import SwiftData
import SwiftUI

@main
struct EVAApp: App {
    @State private var recording: MFFRecording?
    @State private var openRecordingRequest = 0

    var body: some Scene {
        WindowGroup {
            ContentView(
                recording: $recording,
                openRecordingRequest: $openRecordingRequest
            )
        }
        .modelContainer(for: UserMarker.self)
        .defaultSize(Self.defaultWindowSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open MFF...") {
                    openRecordingRequest += 1
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                ViewCommands()
            }

            CommandMenu("Channels") {
                ChannelsCommands()
            }
        }
    }

    private static var defaultWindowSize: CGSize {
        let frame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGSize(width: frame.width * 2 / 3, height: frame.height / 2)
    }
}
