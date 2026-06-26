//
//  ChannelModel.swift
//  SummerEEGDemo
//
//  Per-window channel state (hidden / bad / interpolated). Lifted out of the
//  view so the menu-bar "Channels" commands can read and mutate the active
//  window's channels via a focused value.
//

import SwiftUI

@Observable
final class ChannelModel {
    /// Channels whose trace is not drawn (row stays in place).
    var hidden = Set<Int>()
    /// Channels marked bad (drawn gray).
    var bad = Set<Int>()
    /// channelIndex → spherical-spline-interpolated replacement series.
    var interpolated = [Int: [Float]]()
}

extension FocusedValues {
    var channelModel: ChannelModel? {
        get { self[ChannelModelKey.self] }
        set { self[ChannelModelKey.self] = newValue }
    }

    private struct ChannelModelKey: FocusedValueKey {
        typealias Value = ChannelModel
    }
}

/// Menu-bar "Channels" commands, acting on the focused window's `ChannelModel`.
struct ChannelsCommands: View {
    @FocusedValue(\.channelModel) private var model

    var body: some View {
        if let model {
            Button("Show All Traces") { model.hidden.removeAll() }
                .disabled(model.hidden.isEmpty)
            Button("Unmark All Bad") { model.bad.removeAll() }
                .disabled(model.bad.isEmpty)
            Button("Remove All Interpolations") { model.interpolated.removeAll() }
                .disabled(model.interpolated.isEmpty)

            Divider()

            Menu("Hidden Traces") {
                ForEach(model.hidden.sorted(), id: \.self) { index in
                    Button("Show Ch \(index + 1)") { model.hidden.remove(index) }
                }
            }
            .disabled(model.hidden.isEmpty)

            Menu("Bad Channels") {
                ForEach(model.bad.sorted(), id: \.self) { index in
                    Button("Unmark Ch \(index + 1)") { model.bad.remove(index) }
                }
            }
            .disabled(model.bad.isEmpty)

            Menu("Interpolated Channels") {
                ForEach(model.interpolated.keys.sorted(), id: \.self) { index in
                    Button("Restore Ch \(index + 1)") { model.interpolated[index] = nil }
                }
            }
            .disabled(model.interpolated.isEmpty)
        } else {
            Button("No Recording Open") {}
                .disabled(true)
        }
    }
}

struct ArtifactMenuControls {
    var artifacts: [DefinedArtifact]
    var deleteRequest: Binding<DefinedArtifact.ID?>
    var deleteAllRequest: Binding<Int>
}

extension FocusedValues {
    var artifactMenuControls: ArtifactMenuControls? {
        get { self[ArtifactMenuControlsKey.self] }
        set { self[ArtifactMenuControlsKey.self] = newValue }
    }

    private struct ArtifactMenuControlsKey: FocusedValueKey {
        typealias Value = ArtifactMenuControls
    }

    var icaDebugReportRequest: Binding<Int>? {
        get { self[ICADebugReportRequestKey.self] }
        set { self[ICADebugReportRequestKey.self] = newValue }
    }

    private struct ICADebugReportRequestKey: FocusedValueKey {
        typealias Value = Binding<Int>
    }

    var resetToOriginalRequest: Binding<Int>? {
        get { self[ResetToOriginalRequestKey.self] }
        set { self[ResetToOriginalRequestKey.self] = newValue }
    }

    private struct ResetToOriginalRequestKey: FocusedValueKey {
        typealias Value = Binding<Int>
    }

    var psaViewControls: PSAViewControls? {
        get { self[PSAViewControlsKey.self] }
        set { self[PSAViewControlsKey.self] = newValue }
    }

    private struct PSAViewControlsKey: FocusedValueKey {
        typealias Value = PSAViewControls
    }
}

/// Menu-bar "Artifacts" commands, acting on the focused waveform window.
struct ArtifactsCommands: View {
    @FocusedValue(\.artifactMenuControls) private var controls

    var body: some View {
        if let controls {
            Button("Delete All Defined Artifacts") {
                controls.deleteAllRequest.wrappedValue += 1
            }
            .disabled(controls.artifacts.isEmpty)

            Divider()

            Menu("Delete Defined Artifact") {
                ForEach(controls.artifacts) { artifact in
                    Button("\(artifact.name) (\(artifact.eventCount) events)") {
                        controls.deleteRequest.wrappedValue = artifact.id
                    }
                }
            }
            .disabled(controls.artifacts.isEmpty)
        } else {
            Button("No Recording Open") {}
                .disabled(true)
        }
    }
}

/// PSA-average view toggles exposed to the menu bar for the focused window.
struct PSAViewControls {
    var showButterfly: Binding<Bool>
    var showOverlaidCategories: Binding<Bool>
    var isAveraged: Bool
}

/// Menu-bar View commands for the focused waveform window.
struct ViewCommands: View {
    @FocusedValue(\.icaDebugReportRequest) private var reportRequest
    @FocusedValue(\.resetToOriginalRequest) private var resetRequest
    @FocusedValue(\.psaViewControls) private var psaControls

    var body: some View {
        Button((psaControls?.showButterfly.wrappedValue ?? false) ? "Hide Butterfly" : "Show Butterfly") {
            psaControls?.showButterfly.wrappedValue.toggle()
        }
        .disabled(psaControls?.isAveraged != true)
        .keyboardShortcut("b", modifiers: [.command, .shift])

        Button((psaControls?.showOverlaidCategories.wrappedValue ?? false) ? "Hide Overlaid Categories" : "Show Overlaid Categories") {
            psaControls?.showOverlaidCategories.wrappedValue.toggle()
        }
        .disabled(psaControls?.isAveraged != true)
        .keyboardShortcut("o", modifiers: [.command, .shift])

        Divider()

        Button("Reset to Original Data") {
            resetRequest?.wrappedValue += 1
        }
        .disabled(resetRequest == nil)
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Button("ICA Debug Report") {
            reportRequest?.wrappedValue += 1
        }
        .disabled(reportRequest == nil)
    }
}
