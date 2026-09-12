//
//  CorneoRetinalCorrectionViews.swift
//  EVA
//

import SwiftUI

extension WaveformView {
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

    @ViewBuilder
    private func corneoRetinalChannelRow(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 104, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

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

    private func corneoRetinalChannelList(_ indices: [Int]) -> String {
        indices.map { String($0 + 1) }.joined(separator: ", ")
    }

    private func invalidateCorneoRetinalAnalysis() {
        guard !corneoRetinal.isAnalyzing, corneoRetinal.result != nil else { return }
        corneoRetinal.result = nil
        corneoRetinal.analysisProgress = nil
        corneoRetinal.blinkReviewItems = []
        corneoRetinal.selectedBlinkReviewID = nil
        corneoRetinal.maskEstimateIsStale = false
        corneoRetinal.statusMessage = "Settings changed. Analyze again before using the correction."
    }

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

    private func commitCorneoRetinalBlinkMaskEdits() {
        guard var result = corneoRetinal.result else { return }
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

    private func navigateToCorneoRetinalBlink(_ event: MFFEvent, in signal: MFFSignalData) {
        selectedEventCodes.insert(EyeArtifactKind.blink.eventCode)
        jumpToEvent(event, in: signal)
        highlightedArtifactEvent = event
        highlightedArtifactColor = .orange
    }

    private func selectAdjacentCorneoRetinalBlink(from index: Int, offset: Int, signal: MFFSignalData) {
        let target = index + offset
        guard corneoRetinal.blinkReviewItems.indices.contains(target) else { return }
        let item = corneoRetinal.blinkReviewItems[target]
        corneoRetinal.selectedBlinkReviewID = item.id
        navigateToCorneoRetinalBlink(item.event, in: signal)
    }

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

    private static func crdReviewTime(_ seconds: Double) -> String {
        String(format: "%.3f s", seconds)
    }

    private static func crdReviewDuration(_ seconds: Double) -> String {
        seconds < 1
            ? String(format: "%.0f ms", seconds * 1_000)
            : String(format: "%.3f s", seconds)
    }

    private func useCorneoRetinalResult() {
        guard let result = corneoRetinal.result, !corneoRetinal.maskEstimateIsStale else { return }
        let artifact = DefinedArtifact(
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

    private func corneoRetinalMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

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
