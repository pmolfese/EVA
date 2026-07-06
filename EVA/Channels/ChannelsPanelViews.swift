//
//  ChannelsPanelViews.swift
//  EVA
//
//  Per-channel row UI: bad/hidden toggles, context menus, channel list rendering,
//  This is an extension of WaveformView (not a standalone type), following the
//  same pattern as the other L5 slices -- a file split, not a state extraction.
//

import SwiftUI

extension WaveformView {
    // MARK: - Channels

    func channelIndices(in signal: MFFSignalData) -> [Int] {
        Array(signal.data.indices)
    }

    /// Trace/label color: gray for bad, teal for interpolated, accent otherwise.
    func channelColor(_ index: Int) -> Color {
        if channels.bad.contains(index) { return .gray }
        if channels.interpolated[index] != nil { return .teal }
        return .accentColor
    }

    func channelLabel(index: Int, signal: MFFSignalData) -> some View {
        let isHidden = channels.hidden.contains(index)
        let label = signal.channelNames?.indices.contains(index) == true
            ? signal.channelNames?[index].nilIfEmpty ?? "Ch \(index + 1)"
            : "Ch \(index + 1)"
        return HStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isHidden {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                } else if channels.interpolated[index] != nil {
                    Image(systemName: "wand.and.stars")
                        .font(.caption2)
                } else if channels.bad.contains(index) {
                    Image(systemName: "xmark.circle")
                        .font(.caption2)
                }
            }
            .foregroundStyle(channelColor(index))
            .frame(maxWidth: .infinity, alignment: .leading)

            ChannelHealthBadge(
                result: channels.healthResults[index],
                isAnalyzing: channels.isAnalyzingHealth,
                onActivate: {
                    if let signal = continuousProcessedSignal {
                        runChannelHealthOnDemand(for: signal)
                    }
                }
            )
        }
        .opacity(isHidden ? 0.4 : 1)
        .frame(maxWidth: .infinity, minHeight: channelRowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { toggleHidden(index) }
        .help("Click to show/hide the trace. Right-click for Mark Bad / Interpolate.")
        .contextMenu {
            if channels.bad.contains(index) {
                Button("Unmark Bad") { channels.bad.remove(index) }
            } else {
                Button("Mark Bad") { channels.bad.insert(index) }
            }

            if channels.interpolated[index] != nil {
                Button("Remove Interpolation") { channels.interpolated[index] = nil }
            } else {
                Button("Interpolate") { interpolate(index, in: signal) }
                    .disabled(electrodeGeometry?.positions[index] == nil)
            }

            Divider()
            Button(isHidden ? "Show Trace" : "Hide Trace") { toggleHidden(index) }

            Divider()
            Button("Move \(eegChannelDisplayName(index: index, signal: signal)) to Physio") {
                moveEEGChannelToPhysio(index: index, in: signal)
            }

            Divider()
            Menu("Export Channel") {
                Button("Export as JSON…") {
                    exportChannelAsJSON(index: index, signal: signal)
                }
                Button("Export as 1D…") {
                    exportChannelAs1D(index: index, signal: signal)
                }
            }
        }
    }

    func toggleHidden(_ index: Int) {
        if channels.hidden.contains(index) {
            channels.hidden.remove(index)
        } else {
            channels.hidden.insert(index)
        }
    }

    func moveEEGChannelToPhysio(index: Int, in signal: MFFSignalData) {
        let name = eegChannelDisplayName(index: index, signal: signal)
        guard confirmChannelRoleEditReset(action: "Move \(name) to Physio") else { return }

        let insertIndex = recording.pnsSignal?.numberOfChannels ?? 0
        do {
            let movedName = try recording.moveEEGChannelToPhysio(index: index)
            insertPhysioDisplayState(at: insertIndex)
            showsPhysioChannels = true
            finishChannelRoleEdit(message: "Moved \(movedName) to Physio. Export to save the channel role change.")
        } catch {
            channelStatusMessage = error.localizedDescription
            channelStatusIsError = true
        }
    }

    func movePhysioChannelToEEG(index: Int, name: String) {
        guard confirmChannelRoleEditReset(action: "Move \(name) to EEG") else { return }

        do {
            let movedName = try recording.movePhysioChannelToEEG(index: index)
            removePhysioDisplayState(at: index)
            finishChannelRoleEdit(message: "Moved \(movedName) to EEG. Export to save the channel role change.")
        } catch {
            channelStatusMessage = error.localizedDescription
            channelStatusIsError = true
        }
    }

    func finishChannelRoleEdit(message: String) {
        resetToOriginalData()
        channels.hidden.removeAll()
        channels.bad.removeAll()
        channels.interpolated.removeAll()
        channels.interpolationSources.removeAll()
        channels.clearHealthResults()
        electrodeGeometry = recording.electrodeGeometry
        ChannelSetStore.shared.activeSensorLayout = recording.sensorLayout
        ChannelSetStore.shared.activeChannelNames = recording.signal?.channelNames
        physioRanges = Self.computePhysioRanges(displayedPhysioSignal())
        channelStatusMessage = message
        channelStatusIsError = false
    }

    func confirmChannelRoleEditReset(action: String) -> Bool {
        guard hasDerivedChannelRoleState else { return true }

        let alert = NSAlert()
        alert.messageText = "\(action)?"
        alert.informativeText = "This in-memory channel role edit will clear current filters, MRI/ICA/artifact results, epochs, interpolations, channel marks, and health results. The source file on disk will not change until the next export."
        alert.addButton(withTitle: "Move Channel")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    var hasDerivedChannelRoleState: Bool {
        filter.output != nil
            || filter.pnsOutput != nil
            || gradient.correctedSignal != nil
            || gradient.correctedPNSSignal != nil
            || ica.cleanedSignal != nil
            || ica.decomposition != nil
            || artifactVM.cleanedSignal != nil
            || !artifactVM.events.isEmpty
            || !template.definedArtifacts.isEmpty
            || wavelet.reducedSignal != nil
            || epoching.epochedSignal != nil
            || eegAnalysis.result != nil
            || eegAnalysis.isRunning
            || !channels.hidden.isEmpty
            || !channels.bad.isEmpty
            || !channels.interpolated.isEmpty
            || !channels.healthResults.isEmpty
    }

    func insertPhysioDisplayState(at index: Int) {
        physioChannelRenames = shiftPhysioDictionaryKeys(physioChannelRenames, insertingAt: index)
        physioScaleFactors = shiftPhysioDictionaryKeys(physioScaleFactors, insertingAt: index)
        physioMaxScaledChannels = shiftPhysioSet(physioMaxScaledChannels, insertingAt: index)
        physioFlippedPolarity = shiftPhysioSet(physioFlippedPolarity, insertingAt: index)
    }

    func removePhysioDisplayState(at index: Int) {
        physioChannelRenames = shiftPhysioDictionaryKeys(physioChannelRenames, removingAt: index)
        physioScaleFactors = shiftPhysioDictionaryKeys(physioScaleFactors, removingAt: index)
        physioMaxScaledChannels = shiftPhysioSet(physioMaxScaledChannels, removingAt: index)
        physioFlippedPolarity = shiftPhysioSet(physioFlippedPolarity, removingAt: index)
    }

    func shiftPhysioDictionaryKeys<Value>(_ values: [Int: Value], insertingAt index: Int) -> [Int: Value] {
        Dictionary(uniqueKeysWithValues: values.map { key, value in
            (key >= index ? key + 1 : key, value)
        })
    }

    func shiftPhysioDictionaryKeys<Value>(_ values: [Int: Value], removingAt index: Int) -> [Int: Value] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            guard key != index else { return nil }
            return (key > index ? key - 1 : key, value)
        })
    }

    func shiftPhysioSet(_ values: Set<Int>, insertingAt index: Int) -> Set<Int> {
        Set(values.map { $0 >= index ? $0 + 1 : $0 })
    }

    func shiftPhysioSet(_ values: Set<Int>, removingAt index: Int) -> Set<Int> {
        Set(values.compactMap { value in
            guard value != index else { return nil }
            return value > index ? value - 1 : value
        })
    }

    @ViewBuilder
    func waveformRow(index: Int, channel: [Float], plotWidth: CGFloat, signal: MFFSignalData) -> some View {
        WaveformPlot(
            // Hidden channels keep their row but draw no trace.
            samples: channels.hidden.contains(index) ? [] : channel,
            amplitudeScale: amplitudeScale,
            timeScale: timeScale,
            sampleStride: displaySampleStride(for: signal),
            visibleRange: visibleHorizontalRange,
            nominalHeight: channelRowHeight,
            color: channelColor(index)
        )
        .frame(width: plotWidth, height: channelRowHeight + (channelOverflowHeight * 2))
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: plotWidth, height: channelRowHeight)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                .frame(width: plotWidth, height: channelRowHeight)
        }
        .frame(width: plotWidth, height: channelRowHeight)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Define Artifact…") {
                openArtifactTemplateSheet(for: signal, clickedChannel: index)
            }
            .disabled(activeSelectionRange(in: signal) == nil)

            Divider()
            Button("Move \(eegChannelDisplayName(index: index, signal: signal)) to Physio") {
                moveEEGChannelToPhysio(index: index, in: signal)
            }
        }
        .accessibilityLabel("Channel \(index + 1)")
        .zIndex(1)
    }

    @ViewBuilder
    func splitFileContextMenu(for signal: MFFSignalData) -> some View {
        if let sample = splitSampleForContextMenu(in: signal) {
            Menu("Split File") {
                Button("Save Left Segment…") {
                    splitCurrentFile(.left, atSample: sample)
                }
                .disabled(isExportingMFF)

                Button("Save Right Segment…") {
                    splitCurrentFile(.right, atSample: sample)
                }
                .disabled(isExportingMFF)

                Button("Save Both Segments…") {
                    splitCurrentFile(.both, atSample: sample)
                }
                .disabled(isExportingMFF)
            }
        } else {
            Menu("Split File") {
                Button("No Split Point") {}
                    .disabled(true)
            }
            .disabled(true)
        }
    }

    func splitSampleForContextMenu(in signal: MFFSignalData) -> Int? {
        guard let sampleCount = signal.data.first?.count, sampleCount > 1 else { return nil }
        let fallbackX = horizontalOffset + max(horizontalViewportWidth / 2, 0)
        let fallback = sampleIndex(forContentX: fallbackX, in: signal)
        return min(max(eventTrackContextSample ?? fallback, 1), sampleCount - 1)
    }

    /// Vertical cursor at the topomap sample, drawn once across the channel
    /// stack. Vivid orange so it is unmistakably distinct from the blue
    /// selection band.
    @ViewBuilder
    func cursorOverlay(for signal: MFFSignalData) -> some View {
        if let topomapSample {
            Rectangle()
                .fill(Color.orange)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .offset(x: contentX(forSample: topomapSample, in: signal) - 1)
                .allowsHitTesting(false)
        }
    }

    /// Highlighted time selection across the full channel stack. Uses a fixed
    /// blue (not the system accent) so it can never be confused with the yellow
    /// topomap cursor, regardless of the user's macOS accent colour.
    @ViewBuilder
    func selectionOverlay(for signal: MFFSignalData) -> some View {
        if let range = activeSelectionRange(in: signal) {
            let lowerX = contentX(forSample: range.lowerBound, in: signal)
            let upperX = contentX(forSample: range.upperBound, in: signal)
            let selectionColor = Color(nsColor: .systemBlue)
            Rectangle()
                .fill(selectionColor.opacity(0.16))
                .frame(width: max(upperX - lowerX, 2))
                .frame(maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(selectionColor.opacity(0.8))
                        .frame(width: 1)
                }
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(selectionColor.opacity(0.8))
                        .frame(width: 1)
                }
                .offset(x: lowerX)
                .allowsHitTesting(false)
        }
    }

    /// Translucent band spanning the window of the tapped artifact event, drawn
    /// in the event's flag color. The flag sits at the peak (event onset), so the
    /// window is centered on it using the event's recorded duration.
    @ViewBuilder
    func artifactHighlightOverlay(for signal: MFFSignalData) -> some View {
        if let event = highlightedArtifactEvent,
           let duration = event.durationSeconds, duration > 0,
           signal.samplingRate > 0,
           let sampleCount = signal.data.first?.count, sampleCount > 0 {
            // `centerTimeSeconds` (not `beginTimeSeconds`) — Topography/Continuous
            // events stamp their true onset, not their center, so centering the
            // band on `beginTimeSeconds` directly would draw it half a duration
            // too early for those sources.
            let halfWindow = duration / 2
            let startSample = Int(((event.centerTimeSeconds - halfWindow) * signal.samplingRate).rounded())
            let endSample = Int(((event.centerTimeSeconds + halfWindow) * signal.samplingRate).rounded())
            let lower = min(max(startSample, 0), sampleCount - 1)
            let upper = min(max(endSample, lower + 1), sampleCount)
            let lowerX = contentX(forSample: lower, in: signal)
            let upperX = contentX(forSample: upper, in: signal)
            Rectangle()
                .fill(highlightedArtifactColor.opacity(0.18))
                .frame(width: max(upperX - lowerX, 2))
                .frame(maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    Rectangle().fill(highlightedArtifactColor.opacity(0.7)).frame(width: 1)
                }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(highlightedArtifactColor.opacity(0.7)).frame(width: 1)
                }
                .offset(x: lowerX)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    func segmentHealthOverlay(for signal: MFFSignalData) -> some View {
        if segHealth.shows,
           let results = segHealth.analysis?.results,
           let sampleCount = signal.data.first?.count,
           sampleCount > 0 {
            ZStack(alignment: .topLeading) {
                ForEach(results) { result in
                    let start = min(max(result.startSample, 0), sampleCount - 1)
                    let end = min(max(result.endSample + 1, start + 1), sampleCount)
                    let startX = contentX(forSample: start, in: signal)
                    let endX = contentX(forSample: end, in: signal)
                    SegmentHealthBand(
                        result: result,
                        showsMouseOverHealth: segHealth.showsMouseOver
                    )
                        .frame(width: max(endX - startX, 2))
                        .frame(maxHeight: .infinity)
                        .offset(x: startX)
                }
            }
        }
    }

    /// Distance (pt) a press must travel before it counts as a selection drag
    /// rather than a click.
    private static let dragSelectionThreshold: CGFloat = 4
    /// Max seconds between two clicks to count as a double-click.
    private static let doubleClickInterval: TimeInterval = 0.5

    /// A single gesture that handles BOTH the selection drag and the
    /// double-click topomap cursor. Doing it in one gesture avoids SwiftUI's
    /// gesture arbitration entirely: a press that moves past the threshold is a
    /// selection; a stationary press is a click, and two clicks in quick
    /// succession place the topomap cursor. Neither can trigger the other.
    func waveformInteractionGesture(in signal: MFFSignalData) -> some Gesture {
        // Global coordinate space, converted to content x by subtracting the
        // content's live leading edge (waveformContentMinX). This stays correct
        // even if the horizontal ScrollView scrolls during the drag.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard dragDistance(value) >= Self.dragSelectionThreshold else { return }
                dragSelectionStartSample = sampleIndex(forContentX: contentX(fromGlobalX: value.startLocation.x), in: signal)
                dragSelectionEndSample = sampleIndex(forContentX: contentX(fromGlobalX: value.location.x), in: signal)
            }
            .onEnded { value in
                if dragDistance(value) >= Self.dragSelectionThreshold {
                    // Treat as a selection drag.
                    let start = sampleIndex(forContentX: contentX(fromGlobalX: value.startLocation.x), in: signal)
                    let end = sampleIndex(forContentX: contentX(fromGlobalX: value.location.x), in: signal)
                    let lower = min(start, end)
                    let upper = max(start, end)
                    if upper > lower {
                        selectedSampleRange = lower...upper
                    }
                    dragSelectionStartSample = nil
                    dragSelectionEndSample = nil
                    lastWaveformClick = nil
                    highlightedArtifactEvent = nil
                    return
                }

                // Otherwise it's a stationary click: detect a double-click by hand.
                let clickX = contentX(fromGlobalX: value.location.x)
                let now = Date()
                if let last = lastWaveformClick,
                   now.timeIntervalSince(last.time) < Self.doubleClickInterval,
                   abs(clickX - last.x) < 6 {
                    topomapSample = sampleIndex(forContentX: clickX, in: signal)
                    epoching.butterflyTopomapRelativeSample = nil
                    lastWaveformClick = nil
                } else {
                    lastWaveformClick = (now, clickX)
                }
            }
    }

    func dragDistance(_ value: DragGesture.Value) -> CGFloat {
        hypot(value.translation.width, value.translation.height)
    }

    /// Converts a global-space x into content-space x (0 == first sample),
    /// independent of the horizontal scroll position.
    func contentX(fromGlobalX globalX: CGFloat) -> CGFloat {
        globalX - waveformContentMinX
    }

    func activeSelectionRange(in signal: MFFSignalData) -> ClosedRange<Int>? {
        if let dragSelectionStartSample, let dragSelectionEndSample {
            let lower = min(dragSelectionStartSample, dragSelectionEndSample)
            let upper = max(dragSelectionStartSample, dragSelectionEndSample)
            return clampedSampleRange(lower...upper, in: signal)
        }

        if let selectedSampleRange {
            return clampedSampleRange(selectedSampleRange, in: signal)
        }

        return nil
    }

    func clampedSampleRange(_ range: ClosedRange<Int>, in signal: MFFSignalData) -> ClosedRange<Int>? {
        guard let sampleCount = signal.data.first?.count, sampleCount > 0 else { return nil }
        let lower = min(max(range.lowerBound, 0), sampleCount - 1)
        let upper = min(max(range.upperBound, lower), sampleCount - 1)
        return lower...upper
    }

    func selectionDescription(_ range: ClosedRange<Int>, in signal: MFFSignalData) -> String {
        guard signal.samplingRate > 0 else { return "Selection" }
        let lowerSeconds = Double(range.lowerBound) / signal.samplingRate
        let upperSeconds = Double(range.upperBound) / signal.samplingRate
        let duration = max(upperSeconds - lowerSeconds, 0)
        return String(format: "Selection %.3f–%.3fs (%.3fs)", lowerSeconds, upperSeconds, duration)
    }

    func clearSelection() {
        selectedSampleRange = nil
        dragSelectionStartSample = nil
        dragSelectionEndSample = nil
    }

    /// Green dividers between concatenated epochs.
    @ViewBuilder
    func epochBoundaryOverlay(for signal: MFFSignalData) -> some View {
        if epoching.epochedSignal != nil {
            ForEach(epoching.epochSegments.dropFirst()) { segment in
                Rectangle()
                    .fill(Color.green)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .offset(x: contentX(forSample: segment.startSample, in: signal) - 1)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    func epochLegend() -> some View {
        if !epoching.epochSegments.isEmpty {
            let summaries = epochCategorySummaries()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(summaries) { summary in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(summary.color)
                                .frame(width: 12, height: 12)
                            Text("\(summary.category) · \(summary.count)")
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }

                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(Color.green)
                            .frame(width: 12, height: 2)
                        Text("epoch boundary")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 4)
            }
            .frame(maxWidth: 320)
        }
    }

}
