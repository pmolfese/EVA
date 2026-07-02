//
//  ChannelModel.swift
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
//  Per-window channel state (hidden / bad / interpolated). Lifted out of the
//  view so the menu-bar "Channels" commands can read and mutate the active
//  window's channels via a focused value.
//

import SwiftUI

nonisolated enum ToolbarButtonLabels {
    static let storageKey = "toolbarButtonLabelsVisible"
}

@Observable
final class ChannelModel {
    /// Channels whose trace is not drawn (row stays in place).
    var hidden = Set<Int>()
    /// Channels marked bad (drawn gray).
    var bad = Set<Int>()
    /// channelIndex → spherical-spline-interpolated replacement series.
    var interpolated = [Int: [Float]]()
    /// Whether the waveform should lazily compute and display channel quality.
    var showsHealth = false
    /// Latest channel-health scores, keyed by channel index.
    var healthResults = [Int: ChannelHealthResult]()
    /// True while a channel-health scan is running for the active waveform.
    var isAnalyzingHealth = false
    /// Progress for the current health scan.
    var healthProgress = 0.0
    /// Incremented by menu commands to force a new health scan.
    var healthRefreshToken = 0

    func clearHealthResults() {
        healthResults.removeAll()
        isAnalyzingHealth = false
        healthProgress = 0
    }
}

extension FocusedValues {
    var channelModel: ChannelModel? {
        get { self[ChannelModelKey.self] }
        set { self[ChannelModelKey.self] = newValue }
    }

    private struct ChannelModelKey: FocusedValueKey {
        typealias Value = ChannelModel
    }

    var channelLabelMetricsExportRequest: Binding<Int>? {
        get { self[ChannelLabelMetricsExportRequestKey.self] }
        set { self[ChannelLabelMetricsExportRequestKey.self] = newValue }
    }

    private struct ChannelLabelMetricsExportRequestKey: FocusedValueKey {
        typealias Value = Binding<Int>
    }

}

/// Menu-bar "Channels" commands, acting on the focused window's `ChannelModel`.
struct ChannelsCommands: View {
    @FocusedValue(\.channelModel) private var model
    @FocusedValue(\.channelLabelMetricsExportRequest) private var labelMetricsExportRequest
    @FocusedValue(\.channelHealthViewControls) private var healthControls
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Define Channel Sets…") {
            openWindow(id: EVAApp.channelSetsWindowID)
        }

        Divider()

        if let model {
            Toggle("Show Channel Health", isOn: Binding(
                get: { model.showsHealth },
                set: { model.showsHealth = $0 }
            ))

            Button("Channel Goodness Details...") {
                healthControls?.detailsRequest.wrappedValue += 1
            }
            .disabled(healthControls == nil)

            Button("Channel Goodness Settings...") {
                healthControls?.settingsRequest.wrappedValue += 1
            }
            .disabled(healthControls == nil)

            if model.showsHealth {
                Button("Refresh Channel Health") {
                    if let healthControls {
                        healthControls.refreshRequest.wrappedValue += 1
                    } else {
                        model.healthRefreshToken += 1
                    }
                }
                .disabled(model.isAnalyzingHealth)

                if model.isAnalyzingHealth {
                    Text("Analyzing \(Int((model.healthProgress * 100).rounded()))%")
                }
            }

            Divider()

            Button("Save Channel Labels + Metrics…") {
                labelMetricsExportRequest?.wrappedValue += 1
            }
            .disabled(model.bad.isEmpty || model.isAnalyzingHealth || labelMetricsExportRequest == nil)

            Divider()

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

    var segmentHealthViewControls: SegmentHealthViewControls? {
        get { self[SegmentHealthViewControlsKey.self] }
        set { self[SegmentHealthViewControlsKey.self] = newValue }
    }

    private struct SegmentHealthViewControlsKey: FocusedValueKey {
        typealias Value = SegmentHealthViewControls
    }

    var channelHealthViewControls: ChannelHealthViewControls? {
        get { self[ChannelHealthViewControlsKey.self] }
        set { self[ChannelHealthViewControlsKey.self] = newValue }
    }

    private struct ChannelHealthViewControlsKey: FocusedValueKey {
        typealias Value = ChannelHealthViewControls
    }

    var mffExportRequest: Binding<Int>? {
        get { self[MFFExportRequestKey.self] }
        set { self[MFFExportRequestKey.self] = newValue }
    }

    private struct MFFExportRequestKey: FocusedValueKey {
        typealias Value = Binding<Int>
    }

    var physioViewControls: PhysioViewControls? {
        get { self[PhysioViewControlsKey.self] }
        set { self[PhysioViewControlsKey.self] = newValue }
    }

    private struct PhysioViewControlsKey: FocusedValueKey {
        typealias Value = PhysioViewControls
    }
}

/// Physio (PNS) channel display controls exposed to the View menu.
struct PhysioViewControls {
    var showsPhysio: Binding<Bool>
    /// Whether the focused recording actually contains physio channels.
    var hasPhysio: Bool
    var channelCount: Int
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

/// Segment-health display controls exposed to the View menu.
struct SegmentHealthViewControls {
    var showsHealth: Binding<Bool>
    var showsMouseOverHealth: Binding<Bool>
    var detailsRequest: Binding<Int>
    var refreshRequest: Binding<Int>
    var isAnalyzing: Bool
    var progress: Double
}

/// Channel-health display controls exposed to menu commands.
struct ChannelHealthViewControls {
    var showsHealth: Binding<Bool>
    var detailsRequest: Binding<Int>
    var refreshRequest: Binding<Int>
    var settingsRequest: Binding<Int>
    var isAnalyzing: Bool
    var progress: Double
}

/// File-menu export commands for the focused waveform window.
struct FileExportCommands: View {
    @FocusedValue(\.mffExportRequest) private var mffExportRequest

    var body: some View {
        Button("Export to MFF...") {
            mffExportRequest?.wrappedValue += 1
        }
        .disabled(mffExportRequest == nil)
    }
}

/// Menu-bar View commands for the focused waveform window.
struct ViewCommands: View {
    @AppStorage(ToolbarButtonLabels.storageKey) private var showsToolbarButtonLabels = true

    @FocusedValue(\.icaDebugReportRequest) private var reportRequest
    @FocusedValue(\.resetToOriginalRequest) private var resetRequest
    @FocusedValue(\.psaViewControls) private var psaControls
    @FocusedValue(\.segmentHealthViewControls) private var segmentHealthControls
    @FocusedValue(\.physioViewControls) private var physioControls

    var body: some View {
        Button(showsToolbarButtonLabels ? "Hide Button Labels" : "Show Button Labels") {
            showsToolbarButtonLabels.toggle()
        }

        Divider()

        if let physioControls, physioControls.hasPhysio {
            Button(physioControls.showsPhysio.wrappedValue
                   ? "Hide Physio Channels"
                   : "Show Physio Channels (\(physioControls.channelCount))") {
                physioControls.showsPhysio.wrappedValue.toggle()
            }

            Divider()
        }

        Toggle("Show Segment Health", isOn: Binding(
            get: { segmentHealthControls?.showsHealth.wrappedValue ?? false },
            set: { segmentHealthControls?.showsHealth.wrappedValue = $0 }
        ))
        .disabled(segmentHealthControls == nil)

        Button("Segment Health Details...") {
            segmentHealthControls?.detailsRequest.wrappedValue += 1
        }
        .disabled(segmentHealthControls == nil)

        if let segmentHealthControls, segmentHealthControls.showsHealth.wrappedValue {
            Toggle("Show Mouse Over Health", isOn: segmentHealthControls.showsMouseOverHealth)

            Button("Refresh Segment Health") {
                segmentHealthControls.refreshRequest.wrappedValue += 1
            }
            .disabled(segmentHealthControls.isAnalyzing)

            if segmentHealthControls.isAnalyzing {
                Text("Analyzing \(Int((segmentHealthControls.progress * 100).rounded()))%")
            }
        }

        Divider()

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
