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
import UniformTypeIdentifiers

@main
struct EVAApp: App {
    /// Quits when the last window closes. Paired with `ContentView`'s
    /// `WindowAccessor`, which refuses to close a window that still holds a
    /// recording — see `WindowCloseBehavior` for why that pairing is what makes
    /// this safe to turn on. With `WindowGroup` there can be several main
    /// windows; the flag still means exactly what it says — the *last* one
    /// closing quits, regardless of how many existed a moment before.
    @NSApplicationDelegateAdaptor(EVAAppDelegate.self) private var appDelegate

    @State private var goodnessSettings = ChannelGoodnessSettings()
    @State private var segmentGoodnessSettings = SegmentGoodnessSettings()
    @State private var processingDefaults = ProcessingDefaults.shared
    @State private var isCheckingForUpdates = false

    var body: some Scene {
        // `WindowGroup`, not `Window` — REWIND.md "EVA as a multi-window app"
        // (2026-08-15). `recording` is `ContentView`'s own `@State` now, not
        // shared from here, so each window instance genuinely owns its own
        // recording rather than every window rendering the same one. That is
        // what makes a second instance meaningful instead of a stray
        // duplicate — see `ContentView` for the corresponding half of this.
        //
        // The double-open bug `Window` fixed (0.1.7) was specifically that
        // `recording` used to be `@State` on *this* struct, so a second
        // window would have shown the same file rather than a different one.
        // That reason is gone now that the state moved down; the fix for the
        // Finder race itself lives in `ContentView`'s `.onOpenURL` instead
        // (load into an empty receiving window, otherwise open a sibling —
        // never blindly spawns a redundant second window the way the old bug
        // did).
        WindowGroup(id: "main") {
            ContentView()
                .environment(goodnessSettings)
                .environment(segmentGoodnessSettings)
                .environment(processingDefaults)
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
                NewWindowButton()
                    .keyboardShortcut("n", modifiers: .command)

                OpenRecordingButton()
                    .keyboardShortcut("o", modifiers: .command)

                FileExportCommands()

                Divider()

                CloseFileButton()
            }

            // Quit belongs to the **App** menu, not the File menu.
            //
            // It used to live in the `CommandGroup(replacing: .newItem)` block
            // above, which builds *File*-menu content. That content is scene
            // scoped: open Settings and the Settings scene becomes frontmost, so
            // SwiftUI tears down the main window scene's File items — and the
            // app's only ⌘Q went with them. Closing Settings did not reliably
            // bring them back, which is why the reported repro was "launch, do
            // not open a file, open Settings, close Settings, ⌘Q is gone."
            //
            // `.appTermination` is the App menu's own Quit slot. It is present
            // whatever is frontmost, which is exactly the property a quit
            // command needs and the reason macOS puts it there.
            CommandGroup(replacing: .appTermination) {
                Button("Quit EVA") {
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
                OpenFigureExportButton()
                // Alongside the other single-instance utility windows, not
                // in the File menu — moved here 2026-08-15 after manual
                // testing found it in the File menu but looked for under
                // Window, same place Debug Log/Channel Sets/Figure Export
                // already live. Batch behaves exactly like those now (its
                // own dedicated window), so this is where it belongs.
                OpenBatchWindowButton()
                    .keyboardShortcut("b", modifiers: [.command, .shift])
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

        Window("Figure Export", id: Self.figureExportWindowID) {
            FigureExportBasketView()
        }
        .defaultSize(width: 560, height: 520)

        // Batch's own window (REWIND.md "A significantly attractive option").
        // Single-instance, like the three utility windows above, and for the
        // same reason: there is only ever one batch run, so it does not need
        // `WindowGroup`'s "which instance" question at all. It hosts the same
        // `WaveformView` an ordinary recording window would — the
        // review/decision steps batch pauses for are that view's own sheets —
        // just driven by `BatchController.currentIndex` advancing through a
        // queue instead of a person picking files. See `BatchWindowView`.
        Window("Batch", id: Self.batchWindowID) {
            BatchWindowView()
                .environment(goodnessSettings)
                .environment(segmentGoodnessSettings)
                .environment(processingDefaults)
        }
        .modelContainer(for: UserMarker.self)
        .defaultSize(Self.defaultWindowSize)

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
    static let figureExportWindowID = "figure-export"
    static let batchWindowID = "batch"

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

/// Window-menu item that opens the Figure Export basket window.
private struct OpenFigureExportButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Figure Export") {
            openWindow(id: EVAApp.figureExportWindowID)
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
    }
}

/// File-menu item that opens (or fronts) the Batch window.
///
/// `openWindow(id:)` on a single-instance `Window` scene's id brings the
/// existing instance forward if one is already open rather than creating a
/// second — the same behavior `OpenDebugLogButton` already relies on. Batch
/// needs no per-invocation data the way opening a *recording* does, so unlike
/// `OpenRecordingButton` there is nothing else here: the window's own content
/// decides what to show (its setup sheet if idle, progress if not).
private struct OpenBatchWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Batch Process...") {
            openWindow(id: EVAApp.batchWindowID)
        }
    }
}

/// File-menu "New Window" — a blank window, nothing else.
///
/// Genuinely this small on purpose. The discoverability gap it fixes: "I
/// want to combine two files on disk" had no clear starting point before
/// this, even though every piece downstream already existed — an empty
/// window already accepts a drop, dropping 2+ `.mff` files already shows the
/// combine sheet (`openSelectedURLs`'s `mffURLs.count > 1` branch), and that
/// sheet's `onComplete` already loads the combined result into the same
/// window that hosted it. What was missing was a way to *get* a blank
/// window on purpose rather than by accident (closing a recording, or a
/// lucky Finder-launch timing) — this is that, and nothing more. A dedicated
/// "Combine" window (`Window`, single-instance, batch's own window as the
/// precedent) was considered and set aside: batch's window is driven by a
/// queue advancing through files chosen in advance, but combine is "I just
/// decided, right now, to drag these two files together" — the per-window
/// sheet already fits that better than a persistent utility window would,
/// and it is what already delivers the result into place once you commit.
private struct NewWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Window") {
            openWindow(id: "main")
        }
    }
}

/// File-menu "Open Recording…" — always opens a brand-new window.
///
/// Deliberately not the same mechanism `ContentView`'s empty-state button or
/// `.onOpenURL` use. Both of those have an obvious window to act on (the one
/// they are already inside, or the one that received the event); this command
/// does not — it lives in the menu bar, not in any particular window, so
/// "load into the current window" has no unambiguous meaning for it. Always
/// making a new one is simpler than guessing, and was the explicit answer to
/// "should Open Recording ever reuse an existing window?" (2026-08-15).
///
/// Uses `NSOpenPanel` directly rather than SwiftUI's `.fileImporter`, which
/// has to be attached to a view that is actually on screen — there is no
/// window here to attach one to yet, since opening the window is the point.
/// `ContentView.requestBrainVisionFolderAccess` already does the same thing
/// for the same reason, elsewhere in the file this command used to live in.
private struct OpenRecordingButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Recording...") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.mff, .data, .plainText]
            panel.allowsMultipleSelection = true
            panel.message = "Choose a recording to open in a new window."
            guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
            PendingWindowOpens.shared.push(panel.urls)
            openWindow(id: "main")
        }
    }
}

/// File-menu "Close File" — acts on whichever recording window is currently
/// focused.
///
/// Reads `@FocusedValue(\.recordingWindowActions)` rather than a shared
/// `@State`, because with `WindowGroup` there is no longer one `recording` to
/// point at — see `ContentView` for what it publishes and why closing goes
/// through a closure rather than a raw binding.
private struct CloseFileButton: View {
    @FocusedValue(\.recordingWindowActions) private var actions

    var body: some View {
        Button("Close File") {
            actions?.close()
        }
        .disabled(actions?.hasRecording != true)
    }
}
