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
//  Per-window channel state (hidden / bad / interpolated). Lifted out of the
//  view so the menu-bar "Channels" commands can read and mutate the active
//  window's channels via a focused value.
//

import Accelerate
import SwiftUI

nonisolated struct ChannelInterpolationRecipe: Sendable {
    let indices: [Int]
    let weights: [Float]
}

/// Immutable, Sendable interpolation state. The resolver can safely apply this
/// snapshot on a detached task without touching the observable ChannelModel.
nonisolated struct ChannelInterpolationSnapshot: Sendable {
    let revision: Int
    let cachedReplacements: [Int: [Float]]
    let recipes: [Int: ChannelInterpolationRecipe]

    var isEmpty: Bool { cachedReplacements.isEmpty }

    func applying(to signal: MFFSignalData) -> MFFSignalData {
        guard !isEmpty else { return signal }
        var data = signal.data
        let sampleCount = data.first?.count ?? 0

        for target in cachedReplacements.keys.sorted() where data.indices.contains(target) {
            if let recipe = recipes[target],
               recipe.indices.count == recipe.weights.count,
               !recipe.indices.isEmpty,
               recipe.indices.allSatisfy({ signal.data.indices.contains($0) && signal.data[$0].count == sampleCount }) {
                var replacement = [Float](repeating: 0, count: sampleCount)
                for (sourceIndex, weight) in zip(recipe.indices, recipe.weights) {
                    vDSP.add(
                        multiplication: (signal.data[sourceIndex], weight),
                        replacement,
                        result: &replacement
                    )
                }
                data[target] = replacement
            } else if let cached = cachedReplacements[target], cached.count == sampleCount {
                // Backward-compatible fallback for interpolation state created
                // before donor recipes were retained.
                data[target] = cached
            }
        }

        return signal.replacingData(data)
    }
}

nonisolated enum ToolbarButtonLabels {
    static let storageKey = "toolbarButtonLabelsVisible"
}

@Observable
final class ChannelModel {
    private struct InterpolationState {
        var replacements = [Int: [Float]]()
        var sources = [Int: (indices: [Int], weights: [Float])]()
        var revision = 0
    }

    private var interpolationState = InterpolationState()

    /// Memo for `interpolationSnapshot`, keyed by `interpolationState.revision`.
    ///
    /// `@ObservationIgnored` is required, not cosmetic: the snapshot is built
    /// lazily inside a getter that view bodies call, so a *tracked* cache would
    /// register a mutation during view update and re-invalidate the reader that
    /// just read it.
    @ObservationIgnored private var cachedInterpolationSnapshot: ChannelInterpolationSnapshot?

    /// Channels whose trace is not drawn (row stays in place).
    var hidden = Set<Int>()
    /// Channels marked bad (drawn gray).
    var bad = Set<Int>()
    /// channelIndex → spherical-spline-interpolated replacement series.
    var interpolated: [Int: [Float]] {
        get { interpolationState.replacements }
        set {
            var next = interpolationState
            next.replacements = newValue
            next.revision &+= 1
            interpolationState = next
        }
    }
    /// channelIndex → the channels (and spline weights) that produced its
    /// interpolation, so health can be estimated by averaging their scores
    /// instead of a full recompute.
    var interpolationSources: [Int: (indices: [Int], weights: [Float])] {
        get { interpolationState.sources }
        set {
            var next = interpolationState
            next.sources = newValue
            next.revision &+= 1
            interpolationState = next
        }
    }
    /// Changes only when interpolation output/recipes change. Viewport and
    /// unrelated UI state therefore cannot invalidate the resolved-signal cache.
    var interpolationRevision: Int { interpolationState.revision }
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

    /// Commits the replacement samples and their donor recipe as one observable
    /// state change. Keeping these paired prevents an intermediate waveform
    /// refresh with only half of the interpolation available.
    func setInterpolation(
        target: Int,
        replacement: [Float],
        sourceIndices: [Int],
        sourceWeights: [Float]
    ) {
        var next = interpolationState
        next.replacements[target] = replacement
        next.sources[target] = (sourceIndices, sourceWeights)
        next.revision &+= 1
        interpolationState = next
    }

    /// Replaces a collection of interpolations in a single observable update.
    func replaceInterpolations(
        _ replacements: [Int: [Float]],
        sources: [Int: (indices: [Int], weights: [Float])]
    ) {
        var next = interpolationState
        next.replacements = replacements
        next.sources = sources
        next.revision &+= 1
        interpolationState = next
    }

    func removeInterpolation(target: Int) {
        guard interpolationState.replacements[target] != nil
                || interpolationState.sources[target] != nil else { return }
        var next = interpolationState
        next.replacements[target] = nil
        next.sources[target] = nil
        next.revision &+= 1
        interpolationState = next
    }

    func removeAllInterpolations() {
        guard !interpolationState.replacements.isEmpty
                || !interpolationState.sources.isEmpty else { return }
        var next = interpolationState
        next.replacements.removeAll()
        next.sources.removeAll()
        next.revision &+= 1
        interpolationState = next
    }

    /// Applies each saved spherical-spline recipe to the signal currently at
    /// the end of the processing pipeline. The donor weights are persistent;
    /// the replacement samples are re-derived so filtering, OBS, wavelets, and
    /// other upstream transforms cannot reveal the original target channel.
    /// Cached on `revision` (ROADMAP C4). Rebuilding this `mapValues`-ed a fresh
    /// recipe dictionary on every access, and it is read on every `WaveformView`
    /// body pass — twice on the interpolating path. Every mutation of
    /// `interpolationState` bumps `revision`, and the state is never reset to a
    /// fresh value, so the revision is a monotonic key that cannot go stale.
    ///
    /// Reading `interpolationState` here still registers the observation
    /// dependency, so views refresh exactly as before when interpolation changes.
    var interpolationSnapshot: ChannelInterpolationSnapshot {
        let state = interpolationState
        if let cachedInterpolationSnapshot,
           cachedInterpolationSnapshot.revision == state.revision {
            return cachedInterpolationSnapshot
        }

        let snapshot = ChannelInterpolationSnapshot(
            revision: state.revision,
            cachedReplacements: state.replacements,
            recipes: state.sources.mapValues {
                ChannelInterpolationRecipe(indices: $0.indices, weights: $0.weights)
            }
        )
        cachedInterpolationSnapshot = snapshot
        return snapshot
    }

    func applyingInterpolations(to signal: MFFSignalData) -> MFFSignalData {
        interpolationSnapshot.applying(to: signal)
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
            Button(model.healthResults.isEmpty ? "Run Channel Health" : "Refresh Channel Health") {
                if let healthControls {
                    healthControls.refreshRequest.wrappedValue += 1
                } else {
                    model.healthRefreshToken += 1
                }
            }
            .disabled(model.isAnalyzingHealth)

            Button("Channel Goodness Details...") {
                healthControls?.detailsRequest.wrappedValue += 1
            }
            .disabled(healthControls == nil)

            Button("Channel Goodness Settings...") {
                healthControls?.settingsRequest.wrappedValue += 1
            }
            .disabled(healthControls == nil)

            if model.isAnalyzingHealth {
                Text("Analyzing \(Int((model.healthProgress * 100).rounded()))%")
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
            Button("Remove All Interpolations") {
                model.removeAllInterpolations()
            }
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
                    Button("Restore Ch \(index + 1)") { model.removeInterpolation(target: index) }
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
    var showsAppliedCorrection: Binding<Bool>
    var appliedCorrectionAvailable: Bool
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

    var copyProcessingRequest: Binding<Int>? {
        get { self[CopyProcessingRequestKey.self] }
        set { self[CopyProcessingRequestKey.self] = newValue }
    }

    private struct CopyProcessingRequestKey: FocusedValueKey {
        typealias Value = Binding<Int>
    }

    var datasetInfoRequest: Binding<Int>? {
        get { self[DatasetInfoRequestKey.self] }
        set { self[DatasetInfoRequestKey.self] = newValue }
    }

    private struct DatasetInfoRequestKey: FocusedValueKey {
        typealias Value = Binding<Int>
    }

    var importPhysioRequest: Binding<Int>? {
        get { self[ImportPhysioRequestKey.self] }
        set { self[ImportPhysioRequestKey.self] = newValue }
    }

    private struct ImportPhysioRequestKey: FocusedValueKey {
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
            Toggle("Show Applied Correction", isOn: controls.showsAppliedCorrection)
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!controls.appliedCorrectionAvailable)

            Divider()

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
    var averagedDisplayMode: Binding<EpochingViewModel.AveragedDisplayMode>
    var isAveraged: Bool
}

/// Segment-health display controls exposed to the View menu.
struct SegmentHealthViewControls {
    var showsHealth: Binding<Bool>
    var showsMouseOverHealth: Binding<Bool>
    var detailsRequest: Binding<Int>
    var refreshRequest: Binding<Int>
    var isAvailable: Bool
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
    @FocusedValue(\.copyProcessingRequest) private var copyProcessingRequest
    @FocusedValue(\.datasetInfoRequest) private var datasetInfoRequest
    @FocusedValue(\.importPhysioRequest) private var importPhysioRequest

    var body: some View {
        Button("Import Physio...") {
            importPhysioRequest?.wrappedValue += 1
        }
        .disabled(importPhysioRequest == nil)

        Divider()

        Button("Dataset Info...") {
            datasetInfoRequest?.wrappedValue += 1
        }
        .keyboardShortcut("i", modifiers: .command)
        .disabled(datasetInfoRequest == nil)

        Divider()

        Button("Export to MFF...") {
            mffExportRequest?.wrappedValue += 1
        }
        .disabled(mffExportRequest == nil)

        Divider()

        Button("Copy Processing From...") {
            copyProcessingRequest?.wrappedValue += 1
        }
        .disabled(copyProcessingRequest == nil)
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
            set: { if segmentHealthControls?.isAvailable == true { segmentHealthControls?.showsHealth.wrappedValue = $0 } }
        ))
        .disabled(segmentHealthControls?.isAvailable != true)
        .help(segmentHealthControls?.isAvailable == false ? "Segment Health is unavailable for averaged categories." : "Show quality scores for individual segments.")

        Button("Segment Health Details...") {
            segmentHealthControls?.detailsRequest.wrappedValue += 1
        }
        .disabled(segmentHealthControls?.isAvailable != true)

        if let segmentHealthControls, segmentHealthControls.isAvailable, segmentHealthControls.showsHealth.wrappedValue {
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

        Button("Show Waveform View") {
            psaControls?.averagedDisplayMode.wrappedValue = .waveform
        }
        .disabled(psaControls?.isAveraged != true)
        .keyboardShortcut("2", modifiers: .command)

        Button("Show Averages View") {
            psaControls?.averagedDisplayMode.wrappedValue = .averages
        }
        .disabled(psaControls?.isAveraged != true)
        .keyboardShortcut("3", modifiers: .command)

        Button("Show Trials View") {
            psaControls?.averagedDisplayMode.wrappedValue = .trials
        }
        .disabled(psaControls?.isAveraged != true)
        .keyboardShortcut("4", modifiers: .command)

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
