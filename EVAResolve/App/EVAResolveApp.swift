//
//  EVAResolveApp.swift
//  EVA Resolve
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  EVA Resolve is EVA's sibling app for source analysis: the Source Simulator,
//  dipole fitting, and (to come) head models and distributed inverse imaging. It
//  shares IO and math with EVA through the `EVACore/` folder; everything here is
//  Resolve's own UI and app state.
//
//  Handoff from EVA: "Fit Source Model" in EVA writes an averaged `.mff` and asks
//  Launch Services to open it in Resolve (which grants this sandboxed app access
//  to that package). Any averaged MFF opened here — from EVA, Finder, or File ▸
//  Open — lands in the Source window's Fit mode via `SourceFitImporter`.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct EVAResolveApp: App {
    @NSApplicationDelegateAdaptor(EVAResolveAppDelegate.self) private var appDelegate
    @State private var sourceSimulatorController = SourceSimulatorController()
    @State private var headModelController = HeadModelController()

    var body: some Scene {
        Window("Source Simulator", id: Self.sourceSimulatorWindowID) {
            SourceSimulatorWindowView()
                .environment(sourceSimulatorController)
        }
        .defaultSize(width: 940, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenHeadModelWindowButton()
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                OpenAveragedRecordingButton()
                    .keyboardShortcut("o", modifiers: .command)
            }
        }

        // Head Model (R2.4): MRI, fiducials, electrodes, coregistration.
        Window("Head Model", id: Self.headModelWindowID) {
            HeadModelWindowView()
                .environment(headModelController)
        }
        .defaultSize(width: 1180, height: 760)

        Settings {
            EVAResolvePreferencesView()
        }
    }

    static let sourceSimulatorWindowID = "source-simulator"
    static let headModelWindowID = "head-model"
}

/// Quits when the last window closes, and routes documents opened through
/// Launch Services (Finder, `open`, or EVA's handoff) into the Fit importer.
final class EVAResolveAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            SourceFitImporter.importAndQueue(url)
        }
    }
}

/// File ▸ New Head Model — opens (or fronts) the single-instance Head Model window.
private struct OpenHeadModelWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("New Head Model…") { openWindow(id: EVAResolveApp.headModelWindowID) }
    }
}

/// File ▸ Open — pick an averaged MFF and fit it.
private struct OpenAveragedRecordingButton: View {
    var body: some View {
        Button("Open Averaged Recording...") {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [UTType(importedAs: "com.egi.mff")]
            panel.message = "Choose an averaged .mff recording to fit."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            SourceFitImporter.importAndQueue(url)
        }
    }
}
