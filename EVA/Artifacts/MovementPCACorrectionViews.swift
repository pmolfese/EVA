//
//  MovementPCACorrectionViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import SwiftUI

struct MovementPCADetectionSheet: View {
    @Bindable var viewModel: MovementPCAViewModel
    let signal: MFFSignalData
    let onRestoreDefaults: () -> Void
    let onAnalyze: () -> Void
    let onAddMarkers: () -> Void
    let onClose: () -> Void

    private var configuration: MovementPCAConfiguration { viewModel.configuration }
    private var affectedEpochs: [MovementPCAEpochDiagnostic] {
        viewModel.result?.epochs.filter { $0.removedFactorCount > 0 } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Movement Artifact")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("MAAC-3")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("Find movement-contaminated epochs with temporal PCA + Promax, review the affected ranges, then add duration-bearing MOV markers for a separate Clean Artifacts step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settings
                    analysisProgress
                    results

                    if let status = viewModel.statusMessage {
                        Label(
                            status,
                            systemImage: viewModel.isAnalyzing
                                ? "gearshape.2"
                                : (viewModel.result == nil ? "exclamationmark.triangle" : "checkmark.circle")
                        )
                        .font(.caption)
                        .foregroundStyle(viewModel.isAnalyzing || viewModel.result != nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button("Restore Defaults", action: onRestoreDefaults)
                    .disabled(viewModel.isAnalyzing)

                Spacer()

                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)

                if viewModel.isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(viewModel.result == nil ? "Analyze Movement" : "Analyze Again", action: onAnalyze)
                    .disabled(viewModel.isAnalyzing)

                Button("Add \(affectedEpochs.count) Movement Marker\(affectedEpochs.count == 1 ? "" : "s")", action: onAddMarkers)
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.isAnalyzing || affectedEpochs.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 650, height: 720)
        .onChange(of: viewModel.configuration) { oldValue, newValue in
            guard oldValue != newValue, viewModel.result != nil else { return }
            viewModel.result = nil
            viewModel.analysisProgress = nil
            viewModel.analysisStartedAt = nil
            viewModel.statusMessage = "Settings changed. Analyze again before adding movement markers."
        }
    }

    private var settings: some View {
        GroupBox("Detection settings") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Analysis ranges", selection: $viewModel.configuration.rangeMode) {
                    ForEach(MovementPCARangeMode.allCases) { mode in
                        Text(mode.rawValue)
                            .tag(mode)
                            .disabled(mode == .epochSegments && signal.epochSegments.isEmpty)
                    }
                }

                Text(rangeModeExplanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Continuous window")
                        .font(.caption)
                        .frame(width: 125, alignment: .leading)
                    Slider(
                        value: $viewModel.configuration.continuousWindowSeconds,
                        in: 0.25...4,
                        step: 0.25
                    )
                    .disabled(configuration.rangeMode == .epochSegments)
                    Text(String(format: "%.2f s", configuration.continuousWindowSeconds))
                        .font(.caption.monospacedDigit())
                        .frame(width: 55, alignment: .trailing)
                }

                HStack {
                    Text("Movement threshold")
                        .font(.caption)
                        .frame(width: 125, alignment: .leading)
                    Slider(
                        value: $viewModel.configuration.amplitudeThresholdMicrovolts,
                        in: 50...500,
                        step: 10
                    )
                    Text(String(format: "%.0f µV", configuration.amplitudeThresholdMicrovolts))
                        .font(.caption.monospacedDigit())
                        .frame(width: 55, alignment: .trailing)
                }
                Text("A range is marked when any rotated factor's channel back-projection exceeds this peak-to-peak threshold. The MAAC default is 200 µV.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Maximum factors")
                        .font(.caption)
                    Spacer()
                    Stepper(
                        "\(configuration.maximumFactorCount)",
                        value: $viewModel.configuration.maximumFactorCount,
                        in: 1...32
                    )
                    .fixedSize()
                }

                HStack {
                    Text("Promax power")
                        .font(.caption)
                    Spacer()
                    Stepper(
                        String(format: "%.0f", configuration.promaxPower),
                        value: $viewModel.configuration.promaxPower,
                        in: 2...6,
                        step: 1
                    )
                    .fixedSize()
                }

                Text("Marked-bad, already-interpolated, and non-finite channels are excluded. Seed 0 keeps the Varimax/Promax result deterministic.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        }
        .disabled(viewModel.isAnalyzing)
    }

    @ViewBuilder
    private var analysisProgress: some View {
        if viewModel.isAnalyzing, let progress = viewModel.analysisProgress {
            GroupBox("Analysis progress") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(progress.phase.rawValue)
                                .font(.callout.weight(.semibold))
                            Text(progressDetail(progress))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text("\(Int((progress.fraction * 100).rounded()))%")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: progress.fraction, total: 1)
                        .progressViewStyle(.linear)

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                            spacing: 8
                        ) {
                            progressMetric("Ranges", "\(progress.completedRangeCount)/\(progress.totalRangeCount)")
                            progressMetric("Flagged", "\(progress.affectedRangeCount)")
                            progressMetric("Factors", "\(progress.removedFactorCount)")
                            progressMetric("Skipped", "\(progress.skippedRangeCount)")
                            progressMetric("Workers", "\(progress.workerCount)")
                            progressMetric("Rate", rateText(progress.rangesPerSecond))
                            progressMetric("Elapsed", liveElapsedText(progress, now: context.date))
                            progressMetric("Remaining", remainingText(progress, now: context.date))
                        }
                    }

                    Text("Each worker independently centers one range, fits its thin temporal PCA, performs Varimax followed by Promax, and tests every factor's channel back-projection against the movement threshold. Completed ranges are then restored to recording order before markers are built.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if let result = viewModel.result {
            GroupBox("Detected movement ranges") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        metric("Analyzed", "\(result.analyzedEpochCount)")
                        metric("Marked", "\(result.affectedEpochCount)")
                        metric("Factors", "\(result.removedFactorCount)")
                    }

                    if affectedEpochs.isEmpty {
                        Text("No range exceeded the movement threshold. Nothing will be added to Clean Artifacts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(affectedEpochs.enumerated()), id: \.offset) { index, epoch in
                                HStack {
                                    Text("MOV \(index + 1)")
                                        .font(.caption.weight(.semibold))
                                        .frame(width: 54, alignment: .leading)
                                    Text(rangeText(epoch.sampleRange))
                                        .font(.caption.monospacedDigit())
                                    Spacer()
                                    Text("\(epoch.removedFactorCount) factor\(epoch.removedFactorCount == 1 ? "" : "s") · \(peakText(epoch))")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private func progressMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    private func progressDetail(_ progress: MovementPCAProgress) -> String {
        switch progress.phase {
        case .preparing:
            return "Partitioning the recording into \(progress.totalRangeCount) independent range(s) and starting \(progress.workerCount) bounded CPU worker(s)."
        case .decomposing:
            return "Processed \(formattedSampleCount(progress.completedSampleCount)) of \(formattedSampleCount(progress.totalSampleCount)) samples; \(progress.affectedRangeCount) range(s) currently exceed the threshold."
        case .assembling:
            return "All decompositions are finished. Merging corrected samples and diagnostics in original range order."
        case .complete:
            return "The ordered diagnostics and corrected range results are ready."
        }
    }

    private func liveElapsedText(_ progress: MovementPCAProgress, now: Date) -> String {
        durationText(currentElapsedSeconds(progress, now: now))
    }

    private func remainingText(_ progress: MovementPCAProgress, now: Date) -> String {
        guard let seconds = progress.estimatedSecondsRemaining else { return "—" }
        let sinceLatestUpdate = max(currentElapsedSeconds(progress, now: now) - progress.elapsedSeconds, 0)
        return durationText(max(seconds - sinceLatestUpdate, 0))
    }

    private func currentElapsedSeconds(_ progress: MovementPCAProgress, now: Date) -> Double {
        guard let startedAt = viewModel.analysisStartedAt else { return progress.elapsedSeconds }
        return max(now.timeIntervalSince(startedAt), progress.elapsedSeconds)
    }

    private func rateText(_ rangesPerSecond: Double) -> String {
        guard rangesPerSecond.isFinite, rangesPerSecond > 0 else { return "—" }
        return String(format: "%.1f/s", rangesPerSecond)
    }

    private func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let rounded = Int(seconds.rounded())
        return rounded < 60
            ? "\(rounded)s"
            : String(format: "%d:%02d", rounded / 60, rounded % 60)
    }

    private func formattedSampleCount(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName))
    }

    private var rangeModeExplanation: String {
        switch configuration.rangeMode {
        case .automatic:
            return signal.epochSegments.isEmpty
                ? "No stored epochs are present, so Automatic scans fixed one-second windows."
                : "Automatic scans the signal's \(signal.epochSegments.count) stored epoch boundaries."
        case .continuousWindows:
            return "Scans non-overlapping fixed windows across the complete recording."
        case .epochSegments:
            return signal.epochSegments.isEmpty
                ? "No recorded epoch boundaries are available for this signal."
                : "Scans each of the signal's \(signal.epochSegments.count) stored epochs independently."
        }
    }

    private func rangeText(_ range: Range<Int>) -> String {
        String(
            format: "%.3f–%.3f s",
            Double(range.lowerBound) / signal.samplingRate,
            Double(range.upperBound) / signal.samplingRate
        )
    }

    private func peakText(_ epoch: MovementPCAEpochDiagnostic) -> String {
        let peak = epoch.factors.filter(\.removed).map(\.peakToPeakMicrovolts).max() ?? 0
        return String(format: "%.1f µV", peak)
    }
}

extension WaveformView {
    func openMovementPCASheet(for signal: MFFSignalData) {
        movementPCA.analysisTask?.cancel()
        movementPCA.analysisTask = nil
        movementPCA.isAnalyzing = false
        movementPCA.result = nil
        movementPCA.analysisProgress = nil
        movementPCA.analysisStartedAt = nil
        movementPCA.statusMessage = "Review the settings, then analyze the signal to create movement markers."
        if let existing = template.definedArtifacts.first(where: \.isMovementPCADefinition) {
            movementPCA.definedArtifactID = existing.id
            movementPCA.configuration = existing.movementPCAConfiguration ?? .default
        } else {
            movementPCA.definedArtifactID = nil
            movementPCA.configuration = .default
        }
        movementPCA.showsSheet = true
    }

    func movementPCASheet(for signal: MFFSignalData) -> some View {
        MovementPCADetectionSheet(
            viewModel: movementPCA,
            signal: signal,
            onRestoreDefaults: {
                movementPCA.configuration = .default
                movementPCA.result = nil
                movementPCA.analysisProgress = nil
                movementPCA.analysisStartedAt = nil
                movementPCA.statusMessage = "Defaults restored. Analyze the signal to update movement markers."
            },
            onAnalyze: { analyzeMovementPCA(in: signal) },
            onAddMarkers: { addMovementPCAMarkers(from: signal) },
            onClose: {
                movementPCA.analysisTask?.cancel()
                movementPCA.analysisTask = nil
                movementPCA.isAnalyzing = false
                movementPCA.analysisProgress = nil
                movementPCA.analysisStartedAt = nil
                movementPCA.showsSheet = false
            }
        )
    }

    private func analyzeMovementPCA(in signal: MFFSignalData) {
        let configuration = movementPCA.configuration
        let excluded = channels.bad.union(channels.interpolated.keys)
        movementPCA.analysisTask?.cancel()
        movementPCA.isAnalyzing = true
        movementPCA.result = nil
        movementPCA.analysisStartedAt = Date()
        if let sampleCount = signal.data.first?.count,
           let plan = try? MovementPCACorrector.analysisRanges(
               sampleCount: sampleCount,
               samplingRate: signal.samplingRate,
               epochSegments: signal.epochSegments,
               configuration: configuration
           ) {
            movementPCA.analysisProgress = MovementPCAProgress(
                phase: .preparing,
                completedRangeCount: 0,
                totalRangeCount: plan.ranges.count,
                completedSampleCount: 0,
                totalSampleCount: plan.ranges.reduce(0) { $0 + $1.count },
                affectedRangeCount: 0,
                skippedRangeCount: 0,
                removedFactorCount: 0,
                workerCount: MovementPCACorrector.workerCount(for: plan.ranges.count),
                elapsedSeconds: 0
            )
        } else {
            movementPCA.analysisProgress = nil
        }
        movementPCA.statusMessage = "Running bounded parallel temporal PCA + Promax across the analysis ranges…"
        let sessionID = recordingSessionID
        let (progressContinuation, progressTask) = ProgressBridge.make { (update: MovementPCAProgress) in
            movementPCA.analysisProgress = update
        }
        movementPCA.analysisTask = Task {
            let worker = Task.detached(priority: .userInitiated) {
                Result {
                    try MovementPCACorrector.correct(
                        data: signal.data,
                        samplingRate: signal.samplingRate,
                        epochSegments: signal.epochSegments,
                        configuration: configuration,
                        excluding: excluded
                    ) { update in
                        progressContinuation.yield(update)
                    }.diagnostics
                }
            }
            let outcome = await withTaskCancellationHandler(
                operation: { await worker.value },
                onCancel: {
                    worker.cancel()
                    progressContinuation.finish()
                }
            )
            await ProgressBridge.finishAndWait(progressContinuation, task: progressTask)
            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            guard configuration == movementPCA.configuration else {
                movementPCA.isAnalyzing = false
                movementPCA.analysisTask = nil
                movementPCA.analysisStartedAt = nil
                movementPCA.statusMessage = "Settings changed. Analyze again before adding movement markers."
                return
            }
            switch outcome {
            case .success(let diagnostics):
                movementPCA.result = diagnostics
                movementPCA.statusMessage = diagnostics.affectedEpochCount == 0
                    ? "Analyzed \(diagnostics.analyzedEpochCount) ranges; none exceeded the movement threshold."
                    : "Found \(diagnostics.affectedEpochCount) movement-contaminated range(s). Review them, then add their markers."
            case .failure(let error):
                movementPCA.result = nil
                movementPCA.statusMessage = error.localizedDescription
            }
            movementPCA.isAnalyzing = false
            movementPCA.analysisTask = nil
            movementPCA.analysisStartedAt = nil
        }
    }

    private func addMovementPCAMarkers(from signal: MFFSignalData) {
        guard let diagnostics = movementPCA.result else { return }
        let events = MovementPCAArtifactMarkerBuilder.events(
            from: diagnostics,
            samplingRate: signal.samplingRate
        )
        guard !events.isEmpty else { return }
        let artifact = DefinedArtifact(
            id: movementPCA.definedArtifactID ?? UUID(),
            type: .movement,
            name: "MAAC Movement",
            eventCode: MovementPCAArtifactMarkerBuilder.eventCode,
            events: events,
            selectedChannelIndices: Array(signal.data.indices),
            windowSizeSeconds: movementPCA.configuration.continuousWindowSeconds,
            average: nil,
            topography: nil,
            cleaningMethod: .movementPCA,
            usesVariableEventDuration: false,
            movementPCAConfiguration: movementPCA.configuration,
            appliedMethod: nil,
            cleanedAt: nil
        )

        if let index = template.definedArtifacts.firstIndex(where: { $0.id == artifact.id }) {
            template.definedArtifacts[index] = artifact
        } else {
            template.definedArtifacts.append(artifact)
        }
        registerPSADefinedArtifactForRejection(artifact.id)
        movementPCA.definedArtifactID = artifact.id
        artifactVM.events = definedArtifactEventList()
        selectedEventCodes = [artifact.eventCode]
        invalidateOBSVarianceCache(for: artifact.id)
        clearAppliedArtifactCleaning()
        artifactVM.cleaningStatusMessage = "Added \(artifact.eventCount) MAAC movement marker(s). Choose Clean Artifacts when you are ready to apply MAAC-3."
        movementPCA.showsSheet = false
    }

    func movementPCARangeSummary(_ artifact: DefinedArtifact, signal: MFFSignalData) -> String {
        let configuration = artifact.movementPCAConfiguration ?? .default
        let usesEpochs = configuration.rangeMode == .epochSegments
            || (configuration.rangeMode == .automatic && !signal.epochSegments.isEmpty)
        let rangeDescription = usesEpochs
            ? "recorded epochs"
            : String(format: "%.2f s windows", configuration.continuousWindowSeconds)
        return "\(artifact.eventCount) marked range\(artifact.eventCount == 1 ? "" : "s") · \(rangeDescription) · Promax"
    }
}
