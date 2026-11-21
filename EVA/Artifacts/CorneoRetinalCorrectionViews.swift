//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.

//
//  CorneoRetinalCorrectionViews.swift
//  EVA
//

import SwiftUI

/// Owns the corneo-retinal dipole (CRD) setup and review interface. CRD models
/// slow eye-position fields; blink spans are excluded while estimating those fields.
/// Analysis prepares a result for review; Use Result adds a cleaning definition.
extension WaveformView {
    /// Resets the previous analysis, suggests EOG channel roles from the sensor layout,
    /// and opens the sheet. Bad/interpolated channels are excluded from automatic
    /// selection. Selection failures appear as a status message in the open sheet.
    func openCorneoRetinalSheet(for signal: MFFSignalData) {
        corneoRetinal.result = nil
        corneoRetinal.analysisProgress = nil
        corneoRetinal.blinkReviewItems = []
        corneoRetinal.selectedBlinkReviewID = nil
        corneoRetinal.maskEstimateIsStale = false
        corneoRetinal.statusMessage = nil
        do {
            let selection = try CorneoRetinalChannelResolver.automatic(
                signal: signal,
                layout: recording.sensorLayout,
                excluding: channels.bad.union(channels.interpolated.keys)
            )
            corneoRetinal.leftHEOGChannels = corneoRetinalChannelList(selection.leftHEOGIndices)
            corneoRetinal.rightHEOGChannels = corneoRetinalChannelList(selection.rightHEOGIndices)
            corneoRetinal.upperVEOGChannels = corneoRetinalChannelList(selection.upperVEOGIndices)
            corneoRetinal.lowerVEOGChannels = corneoRetinalChannelList(selection.lowerVEOGIndices)
        } catch {
            corneoRetinal.statusMessage = error.localizedDescription
        }
        corneoRetinal.showsSheet = true
    }

    /// Builds channel selection, estimator settings, progress, blink review, and map
    /// quality controls. SwiftUI reevaluates this view when observed state changes;
    /// the expensive analysis starts only from an action, not from view construction.
    func corneoRetinalSheet(for signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Corneo-Retinal Dipole")
                        .font(.title3.weight(.semibold))
                    HelpButton(topic: CorneoRetinalHelpTopics.overview)
                    Spacer()
                    Text("MAAC-2")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("Estimate continuous horizontal and vertical eye-position fields from EOG-weighted scalp maps, then remove them with reverse-EMCP regression.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 9) {
                            corneoRetinalChannelRow("Left HEOG", text: $corneoRetinal.leftHEOGChannels, placeholder: "226")
                            corneoRetinalChannelRow("Right HEOG", text: $corneoRetinal.rightHEOGChannels, placeholder: "252")
                            corneoRetinalChannelRow("Upper VEOG", text: $corneoRetinal.upperVEOGChannels, placeholder: "18, 25")
                            corneoRetinalChannelRow("Lower VEOG", text: $corneoRetinal.lowerVEOGChannels, placeholder: "238, 241")
                            Text("Channels are one-based. All good EEG channels contribute to the scalp regression; marked-bad and interpolated channels are excluded automatically.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 4)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Channel roles")
                            HelpButton(topic: CorneoRetinalHelpTopics.channelRoles)
                        }
                    }
                    .disabled(corneoRetinal.isAnalyzing)

                    GroupBox("Estimation") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                RowLabel(title: "Blink threshold", help: CorneoRetinalHelpTopics.preliminaryBlinkScan)
                                    .frame(width: 126, alignment: .leading)
                                Slider(value: $corneoRetinal.configuration.preliminaryBlink.amplitudeThresholdMicrovolts, in: 50...400, step: 5)
                                Text(String(format: "%.0f µV", corneoRetinal.configuration.preliminaryBlink.amplitudeThresholdMicrovolts))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 54, alignment: .trailing)
                            }
                            HStack {
                                RowLabel(title: "Rise/fall slope", help: CorneoRetinalHelpTopics.preliminaryBlinkScan)
                                    .frame(width: 126, alignment: .leading)
                                Slider(value: $corneoRetinal.configuration.preliminaryBlink.slopeThresholdMicrovoltsPerMillisecond, in: 0.1...5, step: 0.1)
                                Text(String(format: "%.1f", corneoRetinal.configuration.preliminaryBlink.slopeThresholdMicrovoltsPerMillisecond))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 54, alignment: .trailing)
                                    .help("Microvolts per millisecond")
                            }
                            HStack {
                                RowLabel(title: "Blink padding", help: CorneoRetinalHelpTopics.blinkMask)
                                    .frame(width: 126, alignment: .leading)
                                Slider(value: $corneoRetinal.configuration.blinkPaddingSeconds, in: 0...0.15, step: 0.005)
                                Text(String(format: "%.0f ms", corneoRetinal.configuration.blinkPaddingSeconds * 1_000))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 54, alignment: .trailing)
                            }
                            HStack {
                                RowLabel(title: "Horizontal center", help: CorneoRetinalHelpTopics.centralFraction)
                                    .frame(width: 126, alignment: .leading)
                                Slider(value: $corneoRetinal.configuration.verticalTemplateHorizontalFraction, in: 0.05...0.5, step: 0.025)
                                Text(String(format: "%.1f%%", corneoRetinal.configuration.verticalTemplateHorizontalFraction * 100))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 54, alignment: .trailing)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .disabled(corneoRetinal.isAnalyzing)

                    if let progress = corneoRetinal.analysisProgress {
                        GroupBox("Analysis progress") {
                            VStack(alignment: .leading, spacing: 9) {
                                ProgressView(value: progress.fraction, total: 1)
                                    .progressViewStyle(.linear)
                                HStack {
                                    Text(progress.stage)
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Text(String(format: "%.0f%%", progress.fraction * 100))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                if let detail = progress.detail {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 8) {
                                    if let candidates = progress.blinkCandidateCount {
                                        corneoRetinalMetric("Candidates", "\(candidates)")
                                    }
                                    if let accepted = progress.acceptedBlinkCount {
                                        corneoRetinalMetric("Accepted blinks", "\(accepted)")
                                    }
                                    if let masked = progress.blinkSampleCount,
                                       let total = progress.totalSampleCount, total > 0 {
                                        corneoRetinalMetric("Blink-masked", String(format: "%.1f%%", 100 * Double(masked) / Double(total)))
                                    }
                                    if let usable = progress.usableSampleCount,
                                       let total = progress.totalSampleCount, total > 0 {
                                        corneoRetinalMetric("Usable", String(format: "%.1f%%", 100 * Double(usable) / Double(total)))
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }

                    if corneoRetinal.result != nil {
                        corneoRetinalBlinkMaskReview(in: signal)
                    }

                    if let result = corneoRetinal.result {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 10) {
                                    corneoRetinalMetric("Blinks masked", "\(result.blinkEvents.count)")
                                    corneoRetinalMetric("Horizontal RMS", String(format: "%.2f µV", result.diagnostics.horizontalRMS))
                                    corneoRetinalMetric("Vertical RMS", String(format: "%.2f µV", result.diagnostics.verticalRMS))
                                }
                                Text("Vertical map used \(result.diagnostics.verticalTemplateSampleCount) of \(result.diagnostics.templateSampleCount) clean samples; \(result.diagnostics.blinkSampleCount) samples were blink-masked.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("The preliminary scan rejected \(result.blinkDetection.rejectedBySlopeCount) slow/non-biphasic and \(result.blinkDetection.rejectedBySymmetryCount) asymmetric threshold candidates.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let layout = recording.sensorLayout {
                                    HStack(spacing: 12) {
                                        corneoRetinalTopomap("Horizontal", values: result.diagnostics.horizontalTopography, layout: layout)
                                        corneoRetinalTopomap("Vertical", values: result.diagnostics.verticalTopography, layout: layout)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            HStack(spacing: 4) {
                                Text("Quality control")
                                HelpButton(topic: CorneoRetinalHelpTopics.qualityControl)
                            }
                        }
                    }

                    if let status = corneoRetinal.statusMessage {
                        Label(status, systemImage: corneoRetinal.result == nil ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(corneoRetinal.result == nil ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button("Restore Defaults") {
                    corneoRetinal.configuration = .default
                    openCorneoRetinalSheet(for: signal)
                }
                .disabled(corneoRetinal.isAnalyzing)

                Spacer()

                Button("Close") { corneoRetinal.showsSheet = false }
                    .keyboardShortcut(.cancelAction)

                Button(corneoRetinal.result == nil ? "Analyze" : "Analyze Again") {
                    analyzeCorneoRetinalCorrection(in: signal)
                }
                .disabled(corneoRetinal.isAnalyzing)

                Button("Use MAAC-2 Result") {
                    useCorneoRetinalResult()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(corneoRetinal.isAnalyzing || corneoRetinal.result == nil || corneoRetinal.maskEstimateIsStale)
            }
            .padding(20)
        }
        .frame(width: 680, height: 780)
        .onChange(of: corneoRetinal.configuration) { _, _ in invalidateCorneoRetinalAnalysis() }
        .onChange(of: corneoRetinal.leftHEOGChannels) { _, _ in invalidateCorneoRetinalAnalysis() }
        .onChange(of: corneoRetinal.rightHEOGChannels) { _, _ in invalidateCorneoRetinalAnalysis() }
        .onChange(of: corneoRetinal.upperVEOGChannels) { _, _ in invalidateCorneoRetinalAnalysis() }
        .onChange(of: corneoRetinal.lowerVEOGChannels) { _, _ in invalidateCorneoRetinalAnalysis() }
    }

    /// Builds a labeled text field whose Binding reads and writes its parent’s channel text.
    /// The ViewBuilder attribute lets SwiftUI assemble the returned view hierarchy.
    @ViewBuilder
    private func corneoRetinalChannelRow(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 104, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    /// Parses the user-facing channel lists into zero-based indices and validates
    /// the EOG role selection. Analysis channels are all channels except the excluded
    /// set; invalid role assignments throw so the caller can show an explanation.
    private func currentCorneoRetinalSelection(
        signal: MFFSignalData,
        excluding excluded: Set<Int>
    ) throws -> CorneoRetinalChannelSelection {
        let analysis = (0..<signal.numberOfChannels).filter { !excluded.contains($0) }
        return try CorneoRetinalChannelSelection(
            leftHEOGIndices: Self.parseChannelList(corneoRetinal.leftHEOGChannels, channelCount: signal.numberOfChannels),
            rightHEOGIndices: Self.parseChannelList(corneoRetinal.rightHEOGChannels, channelCount: signal.numberOfChannels),
            upperVEOGIndices: Self.parseChannelList(corneoRetinal.upperVEOGChannels, channelCount: signal.numberOfChannels),
            lowerVEOGIndices: Self.parseChannelList(corneoRetinal.lowerVEOGChannels, channelCount: signal.numberOfChannels),
            analysisIndices: analysis
        ).validated(channelCount: signal.numberOfChannels)
    }

    /// Formats zero-based indices as a comma-separated, one-based list for editing.
    private func corneoRetinalChannelList(_ indices: [Int]) -> String {
        indices.map { String($0 + 1) }.joined(separator: ", ")
    }

    /// Discards a completed estimate after settings change and requires reanalysis.
    /// Does nothing while analysis is active or when there is no completed result.
    private func invalidateCorneoRetinalAnalysis() {
        guard !corneoRetinal.isAnalyzing, corneoRetinal.result != nil else { return }
        corneoRetinal.result = nil
        corneoRetinal.analysisProgress = nil
        corneoRetinal.blinkReviewItems = []
        corneoRetinal.selectedBlinkReviewID = nil
        corneoRetinal.maskEstimateIsStale = false
        corneoRetinal.statusMessage = "Settings changed. Analyze again before using the correction."
    }

    /// Validates channel roles, then detects preliminary blinks and estimates the
    /// horizontal/vertical eye fields off the UI actor. Publishes diagnostics and
    /// editable blink spans when the original recording is still active. Errors
    /// become status text; this preview does not install a cleaning definition.
    private func analyzeCorneoRetinalCorrection(in signal: MFFSignalData) {
        let excluded = channels.bad.union(channels.interpolated.keys)
        let selection: CorneoRetinalChannelSelection
        do {
            selection = try currentCorneoRetinalSelection(signal: signal, excluding: excluded)
        } catch {
            corneoRetinal.result = nil
            corneoRetinal.statusMessage = error.localizedDescription
            return
        }

        // Capture the settings used by this run before starting asynchronous work.
        // The task reads this snapshot rather than changing UI controls mid-analysis.
        let configuration = corneoRetinal.configuration
        corneoRetinal.analysisTask?.cancel()
        corneoRetinal.isAnalyzing = true
        corneoRetinal.result = nil
        corneoRetinal.blinkReviewItems = []
        corneoRetinal.selectedBlinkReviewID = nil
        corneoRetinal.maskEstimateIsStale = false
        corneoRetinal.analysisProgress = CorneoRetinalAnalysisProgress(
            fraction: 0,
            stage: "Starting MAAC-2 analysis",
            detail: "Preparing the specialized blink mask"
        )
        corneoRetinal.statusMessage = "Detecting preliminary blink spans and estimating CRD maps…"
        let sessionID = recordingSessionID
        let (progressContinuation, progressTask) = ProgressBridge.make { (update: CorneoRetinalAnalysisProgress) in
            corneoRetinal.analysisProgress = update.preservingMetrics(from: corneoRetinal.analysisProgress)
        }
        // Task inherits the UI actor for state updates. Task.detached runs the heavy
        // calculation separately; Result packages either its value or its thrown error.
        // Cancelling the outer task prevents publishing a result, but does not by
        // itself stop the detached calculation.
        corneoRetinal.analysisTask = Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { () throws -> CorneoRetinalAnalysisResult in
                    let blinkDetection = try MAACPreliminaryBlinkDetector.detect(
                        channels: signal.data,
                        samplingRate: signal.samplingRate,
                        duration: signal.duration,
                        upperVEOGIndices: selection.upperVEOGIndices,
                        lowerVEOGIndices: selection.lowerVEOGIndices,
                        excluding: excluded,
                        configuration: configuration.preliminaryBlink
                    ) { update in
                        progressContinuation.yield(update)
                    }
                    let correction = try CorneoRetinalCorrector.correct(
                        data: signal.data,
                        samplingRate: signal.samplingRate,
                        selection: selection,
                        blinkEvents: blinkDetection.events,
                        configuration: configuration,
                        excluding: excluded
                    ) { update in
                        progressContinuation.yield(update)
                    }
                    return CorneoRetinalAnalysisResult(
                        diagnostics: correction.diagnostics,
                        blinkEvents: blinkDetection.events,
                        blinkDetection: blinkDetection,
                        selection: selection
                    )
                }
            }.value
            // Drain pending progress updates before publishing completion. The session
            // check prevents a result from an old recording appearing on a new one.
            await ProgressBridge.finishAndWait(progressContinuation, task: progressTask)
            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            switch outcome {
            case .success(let result):
                corneoRetinal.result = result
                corneoRetinal.blinkReviewItems = result.blinkEvents.map {
                    CorneoRetinalBlinkReviewItem(event: $0, isIncluded: true)
                }
                corneoRetinal.selectedBlinkReviewID = corneoRetinal.blinkReviewItems.first?.id
                corneoRetinal.maskEstimateIsStale = false
                corneoRetinal.analysisProgress = CorneoRetinalAnalysisProgress(
                    fraction: 1,
                    stage: "MAAC-2 analysis complete",
                    detail: "Blink masks and both CRD spatial regressions are ready for review.",
                    blinkCandidateCount: result.blinkDetection.candidateCount,
                    acceptedBlinkCount: result.blinkEvents.count,
                    blinkSampleCount: result.diagnostics.blinkSampleCount,
                    usableSampleCount: result.diagnostics.templateSampleCount,
                    totalSampleCount: signal.data.first?.count,
                    verticalTemplateSampleCount: result.diagnostics.verticalTemplateSampleCount,
                    horizontalRMS: result.diagnostics.horizontalRMS,
                    verticalRMS: result.diagnostics.verticalRMS
                )
                selectedEventCodes.insert(EyeArtifactKind.blink.eventCode)
                artifactVM.detectionRefreshToken += 1
                corneoRetinal.statusMessage = "Estimated horizontal and vertical CRD maps. Review their geometry before adding the correction."
            case .failure(let error):
                corneoRetinal.result = nil
                corneoRetinal.analysisProgress = nil
                corneoRetinal.statusMessage = error.localizedDescription
            }
            corneoRetinal.isAnalyzing = false
            corneoRetinal.analysisTask = nil
        }
    }

    /// Builds the editable blink-mask list and controls for the selected span.
    /// Inclusion and boundary edits update the overlay immediately, but a separate
    /// Update Estimate action recomputes the spatial regression before use.
    @ViewBuilder
    private func corneoRetinalBlinkMaskReview(in signal: MFFSignalData) -> some View {
        let items = corneoRetinal.blinkReviewItems
        let includedCount = items.count(where: \.isIncluded)
        let selectedIndex = corneoRetinal.selectedBlinkReviewID.flatMap { id in
            items.firstIndex(where: { $0.id == id })
        }

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if items.isEmpty {
                    Text("No preliminary blink masks were detected. The CRD estimate uses the full recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 8) {
                        Text("USE").frame(width: 34)
                        Text("#").frame(width: 24, alignment: .trailing)
                        Text("ONSET").frame(width: 72, alignment: .trailing)
                        Text("END").frame(width: 72, alignment: .trailing)
                        Text("DURATION").frame(width: 72, alignment: .trailing)
                        Spacer()
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                    ScrollView(.vertical) {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                                HStack(spacing: 8) {
                                    Toggle("Include blink \(offset + 1) in the MAAC mask", isOn: corneoRetinalBlinkInclusionBinding(id: item.id))
                                        .labelsHidden()
                                        .frame(width: 34)
                                    Button {
                                        corneoRetinal.selectedBlinkReviewID = item.id
                                    } label: {
                                        HStack(spacing: 8) {
                                            Text("\(offset + 1)").frame(width: 24, alignment: .trailing)
                                            Text(Self.crdReviewTime(item.onsetSeconds)).frame(width: 72, alignment: .trailing)
                                            Text(Self.crdReviewTime(item.endSeconds)).frame(width: 72, alignment: .trailing)
                                            Text(Self.crdReviewDuration(item.endSeconds - item.onsetSeconds)).frame(width: 72, alignment: .trailing)
                                        }
                                        .font(.caption.monospacedDigit())
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    Spacer()
                                    Button {
                                        corneoRetinal.selectedBlinkReviewID = item.id
                                        navigateToCorneoRetinalBlink(item.event, in: signal)
                                    } label: {
                                        Image(systemName: "scope")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Center and highlight this mask on the waveform.")
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(
                                    item.id == corneoRetinal.selectedBlinkReviewID
                                        ? Color.accentColor.opacity(0.12)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                            }
                        }
                    }
                    .frame(height: min(CGFloat(items.count) * 34, 170))

                    if let selectedIndex, items.indices.contains(selectedIndex) {
                        let selected = items[selectedIndex]
                        Divider()
                        HStack(spacing: 12) {
                            Stepper(
                                value: corneoRetinalBlinkOnsetBinding(id: selected.id, signal: signal),
                                step: 1 / signal.samplingRate
                            ) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Start").font(.caption2).foregroundStyle(.secondary)
                                    Text(Self.crdReviewTime(selected.onsetSeconds)).font(.caption.monospacedDigit())
                                }
                            }
                            Stepper(
                                value: corneoRetinalBlinkEndBinding(id: selected.id, signal: signal),
                                step: 1 / signal.samplingRate
                            ) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("End").font(.caption2).foregroundStyle(.secondary)
                                    Text(Self.crdReviewTime(selected.endSeconds)).font(.caption.monospacedDigit())
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            Button {
                                selectAdjacentCorneoRetinalBlink(from: selectedIndex, offset: -1, signal: signal)
                            } label: {
                                Label("Previous", systemImage: "chevron.left")
                            }
                            .disabled(selectedIndex == items.startIndex)

                            Button {
                                selectAdjacentCorneoRetinalBlink(from: selectedIndex, offset: 1, signal: signal)
                            } label: {
                                Label("Next", systemImage: "chevron.right")
                            }
                            .disabled(selectedIndex == items.index(before: items.endIndex))

                            Button("Show in Waveform") {
                                navigateToCorneoRetinalBlink(selected.event, in: signal)
                            }

                            Spacer()

                            if corneoRetinal.maskEstimateIsStale {
                                Button("Update Estimate") {
                                    updateCorneoRetinalEstimate(in: signal)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }

                    if corneoRetinal.maskEstimateIsStale {
                        Label("Mask edits are visible now. Update the estimate before using the result.", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else {
                        Text("\(includedCount) of \(items.count) detected blinks are included in the MAAC estimation mask.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
            .disabled(corneoRetinal.isAnalyzing)
        } label: {
            HStack(spacing: 4) {
                Text("Blink mask review")
                HelpButton(topic: CorneoRetinalHelpTopics.blinkMaskReview)
                Spacer()
                if !items.isEmpty {
                    Text("\(includedCount)/\(items.count) included")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Connects a toggle to one blink’s inclusion flag using its stable event ID.
    /// The setter commits the edited mask and marks the estimate stale; a missing
    /// item reads as false and ignores writes rather than using an outdated index.
    private func corneoRetinalBlinkInclusionBinding(id: MFFEvent.ID) -> Binding<Bool> {
        Binding(
            get: {
                corneoRetinal.blinkReviewItems.first(where: { $0.id == id })?.isIncluded ?? false
            },
            set: { included in
                guard let index = corneoRetinal.blinkReviewItems.firstIndex(where: { $0.id == id }) else { return }
                corneoRetinal.blinkReviewItems[index].isIncluded = included
                commitCorneoRetinalBlinkMaskEdits()
            }
        )
    }

    /// Connects the start-time stepper to a blink in seconds. The item’s setter
    /// clamps the span to the recording and preserves at least one sample of duration;
    /// committing the edit invalidates the existing map estimate.
    private func corneoRetinalBlinkOnsetBinding(id: MFFEvent.ID, signal: MFFSignalData) -> Binding<Double> {
        Binding(
            get: { corneoRetinal.blinkReviewItems.first(where: { $0.id == id })?.onsetSeconds ?? 0 },
            set: { onset in
                guard let index = corneoRetinal.blinkReviewItems.firstIndex(where: { $0.id == id }) else { return }
                corneoRetinal.blinkReviewItems[index].setOnset(
                    onset,
                    recordingDuration: signal.duration,
                    minimumDuration: 1 / signal.samplingRate
                )
                commitCorneoRetinalBlinkMaskEdits()
            }
        )
    }

    /// Connects the end-time stepper to a blink in seconds, with recording bounds
    /// and a one-sample minimum duration enforced by the review item. Missing IDs
    /// read as zero and ignore writes, which can happen as the list is replaced.
    private func corneoRetinalBlinkEndBinding(id: MFFEvent.ID, signal: MFFSignalData) -> Binding<Double> {
        Binding(
            get: { corneoRetinal.blinkReviewItems.first(where: { $0.id == id })?.endSeconds ?? 0 },
            set: { end in
                guard let index = corneoRetinal.blinkReviewItems.firstIndex(where: { $0.id == id }) else { return }
                corneoRetinal.blinkReviewItems[index].setEnd(
                    end,
                    recordingDuration: signal.duration,
                    minimumDuration: 1 / signal.samplingRate
                )
                commitCorneoRetinalBlinkMaskEdits()
            }
        )
    }

    /// Copies included review spans into the result in onset order and invalidates
    /// its map estimate. Clears the displayed-event cache, requests an overlay refresh,
    /// and updates the selected highlight so the waveform reflects edits immediately.
    private func commitCorneoRetinalBlinkMaskEdits() {
        guard var result = corneoRetinal.result else { return }
        // Key paths such as \.isIncluded and \.event select properties from each item.
        // Only checked spans become the estimation mask; unchecked items stay in
        // the review list so the user can include them again.
        result.blinkEvents = corneoRetinal.blinkReviewItems
            .filter(\.isIncluded)
            .map(\.event)
            .sorted { $0.onsetTimeSeconds < $1.onsetTimeSeconds }
        corneoRetinal.result = result
        corneoRetinal.maskEstimateIsStale = true
        corneoRetinal.statusMessage = "Blink mask edited. Update the CRD estimate before using the result."
        recordingStore.events.displayedEventsCache = .empty
        artifactVM.detectionRefreshToken += 1
        if let selectedID = corneoRetinal.selectedBlinkReviewID,
           let selected = corneoRetinal.blinkReviewItems.first(where: { $0.id == selectedID }) {
            highlightedArtifactEvent = selected.event
            highlightedArtifactColor = .orange
        }
    }

    /// Makes blink events visible, centers the waveform on this event, and highlights
    /// its span in orange. It changes navigation state without changing the event.
    private func navigateToCorneoRetinalBlink(_ event: MFFEvent, in signal: MFFSignalData) {
        selectedEventCodes.insert(EyeArtifactKind.blink.eventCode)
        jumpToEvent(event, in: signal)
        highlightedArtifactEvent = event
        highlightedArtifactColor = .orange
    }

    /// Moves selection by an offset in the review list and navigates to that blink.
    /// Out-of-range moves are ignored instead of wrapping around the list.
    private func selectAdjacentCorneoRetinalBlink(from index: Int, offset: Int, signal: MFFSignalData) {
        let target = index + offset
        guard corneoRetinal.blinkReviewItems.indices.contains(target) else { return }
        let item = corneoRetinal.blinkReviewItems[target]
        corneoRetinal.selectedBlinkReviewID = item.id
        navigateToCorneoRetinalBlink(item.event, in: signal)
    }

    /// Recomputes CRD diagnostics using the reviewed mask and existing channel roles.
    /// It reuses the blink detection result rather than detecting the blinks again.
    /// Only a successful result for the same recording clears the stale-mask flag.
    private func updateCorneoRetinalEstimate(in signal: MFFSignalData) {
        guard let current = corneoRetinal.result, corneoRetinal.maskEstimateIsStale else { return }
        let blinkEvents = current.blinkEvents
        let selection = current.selection
        let configuration = corneoRetinal.configuration
        let excluded = channels.bad.union(channels.interpolated.keys)
        corneoRetinal.analysisTask?.cancel()
        corneoRetinal.isAnalyzing = true
        corneoRetinal.statusMessage = "Re-estimating CRD maps from the reviewed blink mask…"
        corneoRetinal.analysisProgress = CorneoRetinalAnalysisProgress(
            fraction: 0.32,
            stage: "Applying reviewed blink mask",
            detail: "\(blinkEvents.count) blink spans included",
            blinkCandidateCount: current.blinkDetection.candidateCount,
            acceptedBlinkCount: blinkEvents.count,
            totalSampleCount: signal.data.first?.count
        )
        let sessionID = recordingSessionID
        let (progressContinuation, progressTask) = ProgressBridge.make { (update: CorneoRetinalAnalysisProgress) in
            corneoRetinal.analysisProgress = update.preservingMetrics(from: corneoRetinal.analysisProgress)
        }
        corneoRetinal.analysisTask = Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    try CorneoRetinalCorrector.correct(
                        data: signal.data,
                        samplingRate: signal.samplingRate,
                        selection: selection,
                        blinkEvents: blinkEvents,
                        configuration: configuration,
                        excluding: excluded
                    ) { update in
                        progressContinuation.yield(update)
                    }
                }
            }.value
            await ProgressBridge.finishAndWait(progressContinuation, task: progressTask)
            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            switch outcome {
            case .success(let correction):
                if var result = corneoRetinal.result {
                    result.diagnostics = correction.diagnostics
                    result.blinkEvents = blinkEvents
                    corneoRetinal.result = result
                    corneoRetinal.maskEstimateIsStale = false
                    corneoRetinal.analysisProgress = CorneoRetinalAnalysisProgress(
                        fraction: 1,
                        stage: "Reviewed CRD estimate complete",
                        detail: "The edited blink mask is reflected in both CRD maps.",
                        blinkCandidateCount: result.blinkDetection.candidateCount,
                        acceptedBlinkCount: blinkEvents.count,
                        blinkSampleCount: correction.diagnostics.blinkSampleCount,
                        usableSampleCount: correction.diagnostics.templateSampleCount,
                        totalSampleCount: signal.data.first?.count,
                        verticalTemplateSampleCount: correction.diagnostics.verticalTemplateSampleCount,
                        horizontalRMS: correction.diagnostics.horizontalRMS,
                        verticalRMS: correction.diagnostics.verticalRMS
                    )
                    corneoRetinal.statusMessage = "Updated the CRD maps from the reviewed blink mask."
                } else {
                    corneoRetinal.analysisProgress = nil
                    corneoRetinal.statusMessage = "The CRD result changed before the reviewed estimate finished. Analyze again."
                }
            case .failure(let error):
                corneoRetinal.analysisProgress = nil
                corneoRetinal.statusMessage = error.localizedDescription
            }
            corneoRetinal.isAnalyzing = false
            corneoRetinal.analysisTask = nil
        }
    }

    /// Formats an absolute recording time in seconds with millisecond precision.
    private static func crdReviewTime(_ seconds: Double) -> String {
        String(format: "%.3f s", seconds)
    }

    /// Formats short spans in milliseconds and spans of at least one second in seconds.
    private static func crdReviewDuration(_ seconds: Double) -> String {
        seconds < 1
            ? String(format: "%.0f ms", seconds * 1_000)
            : String(format: "%.3f s", seconds)
    }

    /// Adds or replaces the CRD cleaning definition from a current reviewed estimate,
    /// invalidates previously applied cleaning, and opens the cleaning sheet.
    /// The definition stores the mask and estimator settings for later application;
    /// this action does not directly replace the recording’s sample arrays.
    private func useCorneoRetinalResult() {
        guard let result = corneoRetinal.result, !corneoRetinal.maskEstimateIsStale else { return }
        let artifact = DefinedArtifact(
            // Reuse the existing definition ID when revising an earlier CRD setup.
            // A new UUID is needed only the first time this correction is added.
            id: corneoRetinal.definedArtifactID ?? UUID(),
            type: .corneoRetinal,
            name: "Corneo-Retinal Dipole",
            eventCode: "CRD",
            events: [],
            selectedChannelIndices: result.selection.analysisIndices,
            windowSizeSeconds: 0,
            average: nil,
            topography: nil,
            cleaningMethod: .corneoRetinalRegression,
            usesVariableEventDuration: false,
            corneoRetinalConfiguration: corneoRetinal.configuration,
            corneoRetinalChannelSelection: result.selection,
            corneoRetinalBlinkEvents: result.blinkEvents,
            appliedMethod: nil,
            cleanedAt: nil
        )
        if let index = template.definedArtifacts.firstIndex(where: { $0.id == artifact.id }) {
            template.definedArtifacts[index] = artifact
        } else {
            template.definedArtifacts.append(artifact)
        }
        corneoRetinal.definedArtifactID = artifact.id
        clearAppliedArtifactCleaning()
        artifactVM.cleaningStatusMessage = "Added MAAC-2 CRD correction with \(artifact.eventCount) blink-mask spans."
        corneoRetinal.showsSheet = false
        artifactVM.showsCleaningSheet = true
    }

    /// Builds a small label/value card for a progress or quality-control measurement.
    private func corneoRetinalMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    /// Draws one CRD regression-weight map using the recording’s sensor positions.
    /// Float weights are converted to Double for TopomapView; automatic scaling
    /// is local to this map, so its colors do not imply the other map’s numeric scale.
    private func corneoRetinalTopomap(_ title: String, values: [Float], layout: SensorLayout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TopomapView(
                layout: layout,
                values: values.map(Double.init),
                timeSeconds: 0,
                fixedScale: nil,
                unitLabel: "weight",
                showsHeader: false,
                colorBarPlacement: .bottom,
                minimumMapHeight: 150
            )
            .frame(height: 185)
        }
        .frame(maxWidth: .infinity)
    }
}
