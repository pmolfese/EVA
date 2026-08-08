//
//  ChannelsPanelViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
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

    /// Builds a `ChannelLabelRow` for `index`, resolving the channel's derived
    /// display state (name, hidden/bad/interpolated, color, health) here in the
    /// parent so the row itself is a plain value + closure view with no
    /// `WaveformView`/`ChannelModel` capture. See `ChannelLabelRow`.
    func channelLabel(index: Int, signal: MFFSignalData) -> some View {
        let label = signal.channelNames?.indices.contains(index) == true
            ? signal.channelNames?[index].nilIfEmpty ?? "Ch \(index + 1)"
            : "Ch \(index + 1)"
        return ChannelLabelRow(
            index: index,
            label: label,
            isHidden: channels.hidden.contains(index),
            isBad: channels.bad.contains(index),
            isInterpolated: channels.interpolated[index] != nil,
            color: channelColor(index),
            rowHeight: channelRowHeight,
            healthResult: channels.healthResults[index],
            isAnalyzingHealth: channels.isAnalyzingHealth,
            canInterpolate: electrodeGeometry?.positions[index] != nil,
            moveToPhysioTitle: "Move \(eegChannelDisplayName(index: index, signal: signal)) to Physio",
            onActivateHealth: {
                if let signal = continuousProcessedSignal {
                    runChannelHealthOnDemand(for: signal)
                }
            },
            onToggleHidden: { toggleHidden(index) },
            onMarkBad: { channels.bad.insert(index) },
            onUnmarkBad: { channels.bad.remove(index) },
            onInterpolate: { interpolate(index, in: signal) },
            onRemoveInterpolation: { channels.removeInterpolation(target: index) },
            onMoveToPhysio: { moveEEGChannelToPhysio(index: index, in: signal) },
            onExportJSON: { exportChannelAsJSON(index: index, signal: signal) },
            onExportJSONWithEvents: { exportChannelAsJSON(index: index, signal: signal, includeEvents: true) },
            onExport1D: { exportChannelAs1D(index: index, signal: signal) },
            onExport1DWithEvents: { exportChannelAs1D(index: index, signal: signal, includeEvents: true) }
        )
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
        channels.removeAllInterpolations()
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

    /// Builds a `WaveformChannelRow` for `index`, marked `.equatable()` so a row
    /// whose data + viewport didn't change skips its Canvas redraw. Derived state
    /// (hidden-adjusted samples, color, selection availability) is resolved here
    /// in the parent; the row captures no `self`. See `WaveformChannelRow`.
    func waveformRow(index: Int, channel: [Float], plotWidth: CGFloat, signal: MFFSignalData) -> some View {
        let isHidden = channels.hidden.contains(index)
        return WaveformChannelRow(
            index: index,
            // Hidden channels keep their row but draw no trace.
            samples: isHidden ? [] : channel,
            samplingRate: signal.samplingRate,
            dataRevision: signal.dataRevision,
            isHidden: isHidden,
            amplitudeScale: amplitudeScale,
            timeScale: timeScale,
            sampleStride: displaySampleStride(for: signal),
            visibleRange: visibleHorizontalRange,
            plotWidth: plotWidth,
            rowHeight: channelRowHeight,
            overflowHeight: channelOverflowHeight,
            color: channelColor(index),
            usesPixelAdaptiveRendering: usesPixelAdaptiveWaveformRendering,
            showsTimeMarkers: showsTimeMarkersAcrossTraces,
            timeMarkerStyle: waveformTimeMarkerStyle,
            canDefineArtifact: activeSelectionRange(in: signal) != nil,
            moveToPhysioTitle: "Move \(eegChannelDisplayName(index: index, signal: signal)) to Physio",
            onDefineArtifact: { openArtifactTemplateSheet(for: signal, clickedChannel: index) },
            onMoveToPhysio: { moveEEGChannelToPhysio(index: index, in: signal) }
        )
        .equatable()
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

    func updateWaveformHover(at location: CGPoint, in signal: MFFSignalData) {
        guard isCommandKeyPressed,
              let channelIndex = waveformHoverChannelIndex(atY: location.y, in: signal),
              signal.data.indices.contains(channelIndex),
              !channels.hidden.contains(channelIndex) else {
            waveformHoverInfo = nil
            return
        }

        let sample = sampleIndex(forContentX: location.x, in: signal)
        guard signal.data[channelIndex].indices.contains(sample) else {
            waveformHoverInfo = nil
            return
        }
        let segment = waveformHoverSegment(containing: sample)

        waveformHoverInfo = WaveformHoverInfo(
            channelLabel: waveformHoverChannelLabel(index: channelIndex, signal: signal),
            valueMicrovolts: waveformHoverValue(channel: channelIndex, sample: sample, segment: segment, in: signal),
            timeText: waveformHoverTimeText(sample: sample, segment: segment, in: signal),
            location: location
        )
    }

    @ViewBuilder
    func waveformHoverOverlay() -> some View {
        if isCommandKeyPressed, let waveformHoverInfo {
            ButterflyChannelBadge(
                name: waveformHoverInfo.channelLabel,
                valueMicrovolts: waveformHoverInfo.valueMicrovolts,
                detail: waveformHoverInfo.timeText
            )
            .offset(waveformHoverBadgeOffset(for: waveformHoverInfo))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func waveformHoverChannelIndex(atY y: CGFloat, in signal: MFFSignalData) -> Int? {
        guard y >= 0 else { return nil }
        let rowPitch = channelRowHeight + rowSpacing
        guard rowPitch > 0 else { return nil }

        let rowOffset = y.truncatingRemainder(dividingBy: rowPitch)
        guard rowOffset <= channelRowHeight else { return nil }

        let rowIndex = Int(y / rowPitch)
        let indices = channelIndices(in: signal)
        guard indices.indices.contains(rowIndex) else { return nil }
        return indices[rowIndex]
    }

    private func waveformHoverChannelLabel(index: Int, signal: MFFSignalData) -> String {
        let channelNumber = "Ch \(index + 1)"
        guard let names = signal.channelNames,
              names.indices.contains(index) else {
            return channelNumber
        }

        let name = names[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != channelNumber else { return channelNumber }
        return "\(channelNumber) · \(name)"
    }

    private func waveformHoverSegment(containing sample: Int) -> EpochSegment? {
        guard epoching.epochedSignal != nil else { return nil }
        return epoching.epochSegments.first { sample >= $0.startSample && sample <= $0.endSample }
    }

    private func waveformHoverValue(channel: Int, sample: Int, segment: EpochSegment?, in signal: MFFSignalData) -> Double {
        let value = Double(signal.data[channel][sample])
        guard let segment,
              segment.stimulusOffsetSamples > 0 else {
            return value
        }

        let preStart = segment.startSample
        let preEnd = preStart + segment.stimulusOffsetSamples
        guard preStart >= 0,
              preEnd <= signal.data[channel].count,
              segment.endSample < signal.data[channel].count else {
            return value
        }

        var baselineSum = 0.0
        var baselineCount = 0
        for baselineSample in preStart..<preEnd {
            let baselineValue = Double(signal.data[channel][baselineSample])
            guard baselineValue.isFinite else { continue }
            baselineSum += baselineValue
            baselineCount += 1
        }
        guard baselineCount > 0 else { return value }
        return value - baselineSum / Double(baselineCount)
    }

    private func waveformHoverTimeText(sample: Int, segment: EpochSegment?, in signal: MFFSignalData) -> String {
        guard signal.samplingRate > 0 else { return "Time --" }
        if let segment {
            let seconds = Double(sample - segment.startSample - segment.stimulusOffsetSamples) / signal.samplingRate
            let label = epoching.isAveraged || signal.isAveraged || segment.contributingEpochCount > 1
                ? "Average"
                : "Segment"
            return "\(label) \(formatWaveformHoverSeconds(seconds))"
        }
        return "Time \(formatWaveformHoverSeconds(Double(sample) / signal.samplingRate))"
    }

    private func formatWaveformHoverSeconds(_ seconds: Double) -> String {
        let magnitude = abs(seconds)
        if magnitude < 1 {
            return String(format: "%.1f ms", seconds * 1_000)
        }
        if magnitude < 60 {
            return String(format: "%.3f s", seconds)
        }
        let sign = seconds < 0 ? "-" : ""
        let positiveSeconds = magnitude
        let minutes = Int(positiveSeconds) / 60
        let remainingSeconds = positiveSeconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%@%d:%06.3f", sign, minutes, remainingSeconds)
    }

    private func waveformHoverBadgeOffset(for info: WaveformHoverInfo) -> CGSize {
        let estimatedWidth: CGFloat = 150
        let desiredX = info.location.x + 12
        let viewportLeading = max(horizontalOffset, 0)
        let viewportTrailing = viewportLeading + max(horizontalViewportWidth, estimatedWidth)
        let maxX = max(viewportTrailing - estimatedWidth, viewportLeading)
        let x = min(max(desiredX, viewportLeading), maxX)
        let y = max(info.location.y - 46, 0)
        return CGSize(width: x, height: y)
    }

    @ViewBuilder
    func segmentHealthOverlay(for signal: MFFSignalData) -> some View {
        if !epoching.isAveraged,
           !signal.isAveraged,
           segHealth.shows,
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
                        showsMouseOverHealth: segHealth.showsMouseOver,
                        qualityLabel: segHealth.qualityLabels[result.segmentID],
                        onLabel: { segHealth.setQualityLabel($0, for: result.segmentID) }
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
                updateLiveDragSelection(
                    start: sampleIndex(forContentX: contentX(fromGlobalX: value.startLocation.x), in: signal),
                    end: sampleIndex(forContentX: contentX(fromGlobalX: value.location.x), in: signal)
                )
            }
            .onEnded { value in
                if dragDistance(value) >= Self.dragSelectionThreshold {
                    // Treat as a selection drag.
                    let start = sampleIndex(forContentX: contentX(fromGlobalX: value.startLocation.x), in: signal)
                    let end = sampleIndex(forContentX: contentX(fromGlobalX: value.location.x), in: signal)
                    let lower = min(start, end)
                    let upper = max(start, end)
                    if upper > lower {
                        let selectedRange = lower...upper
                        if selectedSampleRange != selectedRange {
                            selectedSampleRange = selectedRange
                        }
                    }
                    clearLiveDragSelection()
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

    func updateLiveDragSelection(start: Int, end: Int) {
        if dragSelectionStartSample != start {
            dragSelectionStartSample = start
        }
        if dragSelectionEndSample != end {
            dragSelectionEndSample = end
        }
    }

    func clearLiveDragSelection() {
        if dragSelectionStartSample != nil {
            dragSelectionStartSample = nil
        }
        if dragSelectionEndSample != nil {
            dragSelectionEndSample = nil
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
