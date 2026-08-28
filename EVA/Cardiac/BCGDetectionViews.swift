//
//  BCGDetectionViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  BCG (ballistocardiogram) detection sheet and its supporting helpers,
//  extracted from WaveformView.swift during the L5 view-decomposition refactor.
//  This is an extension of WaveformView (not a standalone type), following the
//  same pattern as ECGDetectionViews.swift — the cluster reads/writes
//  WaveformView's own @State and stores (bcg, artifactVM, template), so this is
//  a file split, not a state extraction.
//

import SwiftUI

private struct BCGParameterLabel: View {
    let title: String
    let explanation: String
    var width: CGFloat? = 100

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
            BCGHelpButton(title: title, explanation: explanation)
        }
        .frame(width: width, alignment: .leading)
    }
}

private struct BCGHelpButton: View {
    let title: String
    let explanation: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Explain \(title)")
        .accessibilityLabel("Explain \(title)")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(explanation)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 320)
        }
    }
}

/// All BCG identification methods at a glance, with their sources — the tab
/// strip only ever shows one method's description at a time, so this is the
/// one place to compare them side by side before picking.
private struct BCGMethodOverviewHelpButton: View {
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Compare all BCG detection methods")
        .accessibilityLabel("Compare all BCG detection methods")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("BCG Detection Methods")
                        .font(.headline)

                    Text("The ballistocardiogram is the heartbeat-driven pulse wave contaminating EEG, most severely inside the scanner. Each method below finds it by a different signature; all but CWL produce beat events you then correct with a cleaning method.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(BCGDetectionMethod.allCases) { method in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(method.tabLabel)
                                    .font(.caption.weight(.semibold))
                                if method.isDirectCorrection {
                                    Text("corrects directly — no detection step")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(method.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let reference = method.reference {
                                Text(reference)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("Heuristic — no specific source paper.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    Divider()

                    Text("Background")
                        .font(.caption.weight(.semibold))
                    Text(BCGDetectionMethod.backgroundReference)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Detectors are original Swift implementations. Citations name the source of the technique applied; several methods adapt or combine a published approach rather than reproduce it exactly.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(width: 360, alignment: .leading)
            }
            .frame(maxHeight: 460)
        }
    }
}

extension WaveformView {
    // MARK: - BCG Detection sheet

    @ViewBuilder
    func bcgDetectionSheet(for signal: MFFSignalData, selection: ClosedRange<Int>?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("BCG Detection")
                        .font(.headline)
                    BCGMethodOverviewHelpButton()
                }
                Text("Ballistocardiogram artifacts are caused by the heartbeat-driven pulse wave. Choose a method below — each exploits a different signature of BCG.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Divider()

            // Method tab strip
            Picker("Method", selection: $bcg.method) {
                ForEach(BCGDetectionMethod.allCases) { method in
                    Text(method.tabLabel).tag(method)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            // Method description, plus the source of the technique it applies.
            VStack(alignment: .leading, spacing: 4) {
                Text(bcg.method.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let source = bcg.method.referenceShort {
                    Text("Source: \(source)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            // Per-method options
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    bcgAlgorithmComparisonView()

                    Divider()

                    bcgMethodOptions(for: signal, selection: selection)

                    // Channel restriction — applies to the GFP-based methods. Hemispheric
                    // topography has its own Right/Left pickers in bcgMethodOptions instead.
                    if bcg.method != .qrsLocking && bcg.method != .cwlRegression
                        && bcg.method != .hemisphericTopography {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Text("BCG Channels")
                                    .font(.caption.weight(.semibold))
                                BCGHelpButton(
                                    title: "BCG Channels",
                                    explanation: "Restricts detection to a saved channel set. A focused set containing channels where BCG is prominent can improve sensitivity and reduce unrelated EEG, muscle, and bad-channel activity. Leave this unset to use every EEG channel."
                                )
                            }
                            ChannelSetPickerView(
                                label: "Channel Set",
                                selectedSetID: $bcg.channelSetID,
                                channelCount: signal.numberOfChannels
                            )
                            Text(bcg.channelSetID == nil
                                 ? "Using all EEG channels."
                                 : "Restricting detection to the selected set.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // CWL reference channels — external PNS leads, not detected from the EEG.
                    if bcg.method == .cwlRegression {
                        cwlChannelPicker()
                    }

                    // Shared options — not applicable to direct-correction methods (no events produced).
                    if !bcg.method.isDirectCorrection {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Output")
                                .font(.caption.weight(.semibold))

                            HStack {
                                BCGParameterLabel(
                                    title: "Event code",
                                    explanation: "The label written onto every detected BCG event and shown in the event track. Changing it only changes the event label; it does not change detection."
                                )
                                TextField("BCG", text: $bcg.eventCode)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                                BCGParameterLabel(
                                    title: "Window",
                                    explanation: "The total artifact interval centered on each detected BCG peak. It becomes the event duration, controls the highlighted range when an event is clicked, and defines the default interval used for BCG averaging and cleaning.",
                                    width: nil
                                )
                                    .padding(.leading, 8)
                                TextField("s", value: $bcg.windowSeconds, format: .number.precision(.fractionLength(3)))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                                Text("s")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack {
                                BCGParameterLabel(
                                    title: "Threshold",
                                    explanation: "How far the detection score must rise above its robust baseline, measured in standard deviations. Lower values find more candidate beats but increase false positives; higher values are more selective and may miss weak BCG events."
                                )
                                TextField("SD", value: $bcg.thresholdSD, format: .number.precision(.fractionLength(1)))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                                Text("robust SD above mean")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Slider(value: $bcg.thresholdSD, in: 1...6, step: 0.25)
                            }
                            .opacity(bcg.method == .qrsLocking ? 0.35 : 1)
                            .disabled(bcg.method == .qrsLocking)
                        }
                    }

                    if let status = bcg.status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(status.hasPrefix("✓") ? Color.green : .secondary)
                    }

                    if bcg.isRunning, let progress = bcg.progress {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(bcg.method == .cwlRegression ? "CWL correction" : "Processing")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: min(max(progress, 0), 1), total: 1)
                                .progressViewStyle(.linear)
                        }
                    }

                    // Iterative refinement panel — spatial PCA only, shown after detection
                    if bcg.method == .spatialPCA && bcg.detectsArtifacts {
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Iterative Exemplar Refinement")
                                .font(.caption.weight(.semibold))
                            Text("Re-epochs detected beats, scores each by PC1 projection, rejects the weakest fraction, re-averages, and re-detects using the cleaner template.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                BCGParameterLabel(
                                    title: "Reject fraction",
                                    explanation: "During refinement, removes this fraction of the weakest or least template-like detected beats before rebuilding the spatial BCG exemplar. Larger values can clean a contaminated template but may discard genuine variable beats."
                                )
                                TextField("%", value: Binding(
                                    get: { bcg.rejectFraction * 100 },
                                    set: { bcg.rejectFraction = $0 / 100 }
                                ), format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                                Text("% of beats removed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Slider(value: $bcg.rejectFraction, in: 0.05...0.50, step: 0.05)
                            }

                            if let refined = bcg.refinedTemplate, refined.count == signal.numberOfChannels,
                               let sensorLayout = recording.sensorLayout {
                                HStack(spacing: 12) {
                                    TopomapView(
                                        layout: sensorLayout,
                                        values: refined.map { Double($0) },
                                        timeSeconds: 0,
                                        fixedScale: nil,
                                        showsHeader: false,
                                        colorBarPlacement: .none,
                                        minimumMapHeight: 90,
                                        contentPadding: 0
                                    )
                                    .frame(width: 90, height: 90)
                                    .clipShape(Circle())

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Refined template")
                                            .font(.caption.weight(.semibold))
                                        if let kept = bcg.refinedKeptCount {
                                            let total = artifactVM.events.filter { $0.sourceFile == BCGDetector.sourceFile }.count
                                            Text("Averaged from \(kept) / \(total + (total - kept)) beats")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // Action row
            HStack {
                if bcg.method == .cwlRegression {
                    if bcg.correctedSignal != nil {
                        Button("Remove CWL Correction", role: .destructive) {
                            disableCWLCorrection()
                            bcg.showsSheet = false
                        }
                    }
                } else if bcg.method == .surrogatePCAS {
                    if bcg.correctedSignal != nil, bcg.appliedCorrection == .surrogatePCAS {
                        Button("Remove PCA-S Correction", role: .destructive) {
                            disableSurrogateCorrection()
                            bcg.showsSheet = false
                        }
                    }
                } else if bcg.detectsArtifacts {
                    Button("Disable BCG Detection", role: .destructive) {
                        disableBCGDetection()
                        bcg.showsSheet = false
                    }
                }
                Spacer()
                if bcg.isRunning || bcg.isRefining {
                    if bcg.progress == nil {
                        ProgressView().controlSize(.small)
                    }
                }
                Button("Cancel") {
                    bcg.showsSheet = false
                }
                if bcg.method == .spatialPCA && bcg.detectsArtifacts {
                    Button("Refine") {
                        bcgRefinementTask?.cancel()
                        let sessionID = recordingSessionID
                        bcgRefinementTask = Task {
                            await runBCGRefinement(signal: signal)
                            if !Task.isCancelled, sessionID == recordingSessionID {
                                bcgRefinementTask = nil
                            }
                        }
                    }
                    .disabled(bcg.isRefining || bcg.isRunning)
                }
                if bcg.method == .surrogatePCAS {
                    let beats = surrogateBeatTimes()
                    let missingGeometry = !surrogateMissingGeometryChannels(for: signal).isEmpty
                        || electrodeGeometry == nil
                    Button("Correct PCA-S") {
                        bcgTask?.cancel()
                        let sessionID = recordingSessionID
                        bcgTask = Task {
                            await runSurrogateCorrection(signal: signal)
                            if !Task.isCancelled, sessionID == recordingSessionID {
                                bcgTask = nil
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    // Disabled rather than failing on click: both refusals are
                    // stated in the panel above, so the button being off is the
                    // same message rather than a second one.
                    .disabled(bcg.isRunning || beats.isEmpty || missingGeometry)
                    .help(missingGeometry
                          ? "PCA-S needs 3D coordinates for every corrected channel."
                          : beats.isEmpty
                            ? "PCA-S needs detected beats. Run BCG or ECG detection first."
                            : "Fit the surrogate model and remove the BCG.")
                } else if bcg.method == .cwlRegression {
                    Button("Correct CWL") {
                        bcgTask?.cancel()
                        let sessionID = recordingSessionID
                        bcgTask = Task {
                            await runCWLCorrection(signal: signal)
                            if !Task.isCancelled, sessionID == recordingSessionID {
                                bcgTask = nil
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(bcg.isRunning || bcg.selectedCWLChannels.isEmpty)
                } else {
                    Button("Detect BCG") {
                        bcgTask?.cancel()
                        let sessionID = recordingSessionID
                        bcgTask = Task {
                            await runBCGDetection(signal: signal, selection: selection)
                            if !Task.isCancelled, sessionID == recordingSessionID {
                                bcgTask = nil
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(bcg.isRunning || (bcg.method == .qrsLocking && !ecg.isEnabled))
                }
            }
            .padding(20)
        }
        .frame(width: 720)
        .disabled(bcg.isRunning || bcg.isRefining)
        .task(id: bcgDetectionPreviewRequestID(for: signal, selection: selection)) {
            await refreshBCGDetectionEstimate(for: signal, selection: selection)
        }
    }

    @ViewBuilder
    func bcgAlgorithmComparisonView() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Algorithm Comparison")
                    .font(.caption.weight(.semibold))
                Spacer()
                if bcg.isEstimating {
                    ProgressView().controlSize(.mini)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Algorithm")
                    Text("Events")
                    Text("BPM")
                    Text("")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                    .gridCellColumns(4)

                ForEach(BCGDetectionMethod.allCases) { method in
                    GridRow {
                        Text(method.tabLabel).font(.caption2)
                        if let result = bcg.algorithmResults[method] {
                            Text("\(result.count)").font(.caption2.monospacedDigit())
                            if let bpm = result.bpm, bpm.isFinite {
                                Text(String(format: "%.0f", bpm)).font(.caption2.monospacedDigit())
                            } else {
                                Text("—").font(.caption2).foregroundStyle(.secondary)
                            }
                        } else if bcg.isEstimating, !method.isDirectCorrection {
                            Text("…").font(.caption2).foregroundStyle(.secondary)
                            Text("…").font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text("—").font(.caption2).foregroundStyle(.secondary)
                            Text(bcgComparisonUnavailableLabel(for: method))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            bcg.method = method
                        } label: {
                            Image(systemName: bcg.method == method ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(bcg.method == method ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Use \(method.tabLabel)")
                    }
                }
            }

            Text("BPM uses the median interval between detected events. Previewing does not apply or replace BCG events.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func bcgComparisonUnavailableLabel(for method: BCGDetectionMethod) -> String {
        switch method {
        case .cwlRegression: return "N/A"
        case .qrsLocking: return "ECG needed"
        case .hemisphericTopography: return "L/R sets needed"
        default: return "—"
        }
    }

    func bcgDetectionPreviewRequestID(
        for signal: MFFSignalData,
        selection: ClosedRange<Int>?
    ) -> String {
        let qrsSignature = artifactVM.events
            .filter { $0.code == RWaveDetector.eventCode }
            .map { String(format: "%.4f", $0.beginTimeSeconds) }
            .joined(separator: ",")
        return [
            signal.signalURL.path,
            "\(signal.numberOfChannels)",
            "\(signal.data.first?.count ?? 0)",
            "\(signal.samplingRate)",
            bcg.channelSetID?.uuidString ?? "all",
            bcg.rightChannelSetID?.uuidString ?? "no-right",
            bcg.leftChannelSetID?.uuidString ?? "no-left",
            selection.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "no-selection",
            String(format: "%.4f", bcg.thresholdSD),
            String(format: "%.4f", bcg.minHR),
            String(format: "%.4f", bcg.maxHR),
            String(format: "%.4f", bcg.powerMinHz),
            String(format: "%.4f", bcg.powerMaxHz),
            String(format: "%.4f", bcg.qrsLagMs),
            "\(bcg.pcaComponents)",
            "\(bcg.spatialWhiten)",
            "\(bcg.slidingNormalize)",
            "\(bcg.respAdaptive)",
            qrsSignature
        ].joined(separator: "|")
    }

    @MainActor
    func refreshBCGDetectionEstimate(
        for signal: MFFSignalData,
        selection: ClosedRange<Int>?
    ) async {
        let requestID = bcgDetectionPreviewRequestID(for: signal, selection: selection)
        let restrictedIndices = bcg.channelSetID.flatMap { id in
            ChannelSetStore.shared.allSets.first(where: { $0.id == id })?
                .channelIndices.filter { signal.data.indices.contains($0) }
        }
        let previewChannels: [[Float]]
        if let restrictedIndices, !restrictedIndices.isEmpty {
            previewChannels = restrictedIndices.map { signal.data[$0] }
        } else {
            previewChannels = signal.data
        }
        guard !previewChannels.isEmpty else {
            bcg.isEstimating = false
            bcg.algorithmResults = [:]
            return
        }

        let configuration = BCGDetectionPreviewConfiguration(
            thresholdSD: bcg.thresholdSD,
            minHR: bcg.minHR,
            maxHR: bcg.maxHR,
            powerMinHz: bcg.powerMinHz,
            powerMaxHz: bcg.powerMaxHz,
            qrsLagSeconds: bcg.qrsLagMs / 1000,
            pcaComponents: bcg.pcaComponents,
            spatialWhiten: bcg.spatialWhiten,
            slidingNormalize: bcg.slidingNormalize,
            respAdaptive: bcg.respAdaptive
        )
        let qrsTimes = artifactVM.events
            .filter { $0.code == RWaveDetector.eventCode }
            .map(\.beginTimeSeconds)
        let samplingRate = signal.samplingRate
        let duration = signal.duration
        let hemisphericChannels = hemisphericPreviewChannels(for: signal)

        bcg.isEstimating = true
        bcg.algorithmResults = [:]
        let results = await withTaskGroup(
            of: (BCGDetectionMethod, BCGAlgorithmResult?).self,
            returning: [BCGDetectionMethod: BCGAlgorithmResult].self
        ) { group in
            for method in BCGDetectionMethod.allCases where !method.isDirectCorrection {
                group.addTask(priority: .utility) {
                    guard let times = await BCGDetectionPreviewEstimator.eventTimes(
                        method: method,
                        channels: previewChannels,
                        samplingRate: samplingRate,
                        duration: duration,
                        exemplarRange: selection,
                        qrsTimes: qrsTimes,
                        configuration: configuration,
                        hemisphericChannels: hemisphericChannels
                    ) else { return (method, nil) }
                    return (method, BCGDetectionPreviewEstimator.result(from: times))
                }
            }
            var output: [BCGDetectionMethod: BCGAlgorithmResult] = [:]
            for await (method, result) in group {
                if let result { output[method] = result }
            }
            return output
        }

        guard !Task.isCancelled,
              requestID == bcgDetectionPreviewRequestID(for: signal, selection: selection) else { return }
        bcg.isEstimating = false
        bcg.algorithmResults = results
    }

    /// Resolves the right/left channel-set selections against the current recording,
    /// for the hemispheric-topography method (see `BCGDetector.hemisphericTopographyEvents`).
    /// `nil` when either side is unset or has no channels in range.
    func hemisphericPreviewChannels(for signal: MFFSignalData) -> (right: [[Float]], left: [[Float]])? {
        func channels(for id: ChannelSet.ID?) -> [[Float]]? {
            guard let id,
                  let set = ChannelSetStore.shared.allSets.first(where: { $0.id == id })
            else { return nil }
            let indices = set.channelIndices.filter { signal.data.indices.contains($0) }
            guard !indices.isEmpty else { return nil }
            return indices.map { signal.data[$0] }
        }
        guard let right = channels(for: bcg.rightChannelSetID),
              let left = channels(for: bcg.leftChannelSetID)
        else { return nil }
        return (right, left)
    }

    @ViewBuilder
    func bcgMethodOptions(for signal: MFFSignalData, selection: ClosedRange<Int>?) -> some View {
        switch bcg.method {
        case .periodicity:
            VStack(alignment: .leading, spacing: 10) {
                Text("Heart rate range")
                    .font(.caption.weight(.semibold))
                HStack {
                    BCGParameterLabel(
                        title: "Min HR",
                        explanation: "The slowest plausible heart rate. It sets the lower edge of the cardiac band used by periodicity detection. Raise it when slow drift is being mistaken for BCG; lower it when genuine slow beats are missed."
                    )
                    TextField("BPM", value: $bcg.minHR, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("BPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $bcg.minHR, in: 30...80, step: 1)
                }
                HStack {
                    BCGParameterLabel(
                        title: "Max HR",
                        explanation: "The fastest plausible heart rate. It sets the upper cardiac-band edge and helps determine minimum spacing between detections. Lower it to reject implausibly close duplicate peaks."
                    )
                    TextField("BPM", value: $bcg.maxHR, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("BPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $bcg.maxHR, in: 60...180, step: 1)
                }
                if selection != nil {
                    Label("Uses all EEG channels; selection ignored for this method.", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

        case .spatialPCA:
            VStack(alignment: .leading, spacing: 10) {
                Text("Spatial PC extraction")
                    .font(.caption.weight(.semibold))
                if selection != nil {
                    Label("Will derive the BCG spatial map from your highlighted selection.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("No selection — will use the first 30 s of the recording. Highlight a clear BCG exemplar for better results.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                HStack(spacing: 10) {
                    BCGParameterLabel(
                        title: "Components",
                        explanation: "The number of leading spatial principal components treated as the BCG subspace. One is simplest; two or three can capture BCG that spans multiple spatial patterns, but too many components may admit unrelated activity."
                    )
                    Stepper("\(bcg.pcaComponents)", value: $bcg.pcaComponents, in: 1...4)
                        .labelsHidden()
                    Text("\(bcg.pcaComponents) PC\(bcg.pcaComponents == 1 ? "" : "s") combined via RSS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help("Project onto the top N spatial components and combine scores via root-sum-of-squares. 2–3 components captures BCG sources that span more than one dipole.")

                HStack(alignment: .top, spacing: 6) {
                    Toggle(isOn: $bcg.spatialWhiten) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Spatial whitening")
                                .font(.caption)
                            Text("Suppresses alpha / muscle before PCA so BCG stands out")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    BCGHelpButton(
                        title: "Spatial whitening",
                        explanation: "Equalizes spatial directions using the background covariance before computing the BCG components. This reduces domination by large non-BCG sources such as alpha or muscle, although it can make a very noisy covariance estimate less stable."
                    )
                }

                HStack(alignment: .top, spacing: 6) {
                    Toggle(isOn: $bcg.respAdaptive) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Respiratory envelope normalization")
                                .font(.caption)
                            Text("6 s sliding RMS — tracks ~0.2 Hz BCG amplitude modulation")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    BCGHelpButton(
                        title: "Respiratory envelope normalization",
                        explanation: "Divides the detection signal by a short sliding RMS envelope. Because BCG amplitude changes across the breathing cycle, this keeps the threshold similarly sensitive at respiratory peaks and troughs."
                    )
                }

                HStack(alignment: .top, spacing: 6) {
                    Toggle(isOn: $bcg.slidingNormalize) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Sliding z-score normalization")
                                .font(.caption)
                            Text("30 s window — adapts to slow amplitude drift across the run")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    BCGHelpButton(
                        title: "Sliding z-score normalization",
                        explanation: "Recomputes the detection baseline in a rolling 30-second window so one fixed SD threshold can follow gradual changes in BCG amplitude. Disable it when you need one global threshold across the entire recording."
                    )
                }
            }

        case .cardiacPowerMap:
            VStack(alignment: .leading, spacing: 10) {
                Text("Cardiac frequency band")
                    .font(.caption.weight(.semibold))
                HStack {
                    BCGParameterLabel(
                        title: "Low cutoff",
                        explanation: "The lowest frequency included when estimating each channel's cardiac-band power. Raise it to suppress slow drift and respiration; lower it to retain unusually slow cardiac activity. Keep it below the high cutoff."
                    )
                    TextField("Hz", value: $bcg.powerMinHz, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("Hz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $bcg.powerMinHz, in: 0.3...1.5, step: 0.05)
                }
                HStack {
                    BCGParameterLabel(
                        title: "High cutoff",
                        explanation: "The highest frequency included in the cardiac power map. Raise it to include faster BCG structure; lower it to exclude higher-frequency muscle or scanner noise. Keep it above the low cutoff."
                    )
                    TextField("Hz", value: $bcg.powerMaxHz, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("Hz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $bcg.powerMaxHz, in: 0.8...3.0, step: 0.05)
                }
            }

        case .hemisphericTopography:
            VStack(alignment: .leading, spacing: 10) {
                Text("Right / left channel groups")
                    .font(.caption.weight(.semibold))
                if bcg.rightChannelSetID != nil, bcg.leftChannelSetID != nil {
                    Label("BCG estimated as the difference of the right- and left-set averages.", systemImage: "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Pick both a Right and a Left channel set — anterior-temporal/facial electrodes with the clearest inter-hemispheric contrast work best.", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 4) {
                    Text("Right set")
                        .font(.caption)
                        .frame(width: 100, alignment: .leading)
                    BCGHelpButton(
                        title: "Right set",
                        explanation: "Channel set averaged to estimate the right-hemisphere side of the pulse-artifact topography (μR). Pick anterior-temporal/facial electrodes on the right."
                    )
                    ChannelSetPickerView(
                        label: "Right Channel Set",
                        selectedSetID: $bcg.rightChannelSetID,
                        channelCount: signal.numberOfChannels
                    )
                }
                HStack(spacing: 4) {
                    Text("Left set")
                        .font(.caption)
                        .frame(width: 100, alignment: .leading)
                    BCGHelpButton(
                        title: "Left set",
                        explanation: "Channel set averaged to estimate the left-hemisphere side of the pulse-artifact topography (μL). Pick anterior-temporal/facial electrodes on the left."
                    )
                    ChannelSetPickerView(
                        label: "Left Channel Set",
                        selectedSetID: $bcg.leftChannelSetID,
                        channelCount: signal.numberOfChannels
                    )
                }

                Divider()

                Text("Expected heart rate")
                    .font(.caption.weight(.semibold))
                HStack {
                    BCGParameterLabel(
                        title: "Max HR",
                        explanation: "The fastest plausible heart rate. It sets the minimum spacing between detections, rejecting implausibly close duplicate peaks."
                    )
                    TextField("BPM", value: $bcg.maxHR, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("BPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $bcg.maxHR, in: 60...180, step: 1)
                }
            }

        case .virtualECGPCA, .panTompkinsProxy:
            VStack(alignment: .leading, spacing: 10) {
                Text("Expected heart rate")
                    .font(.caption.weight(.semibold))
                if bcg.channelSetID == nil {
                    Label("Pick a BCG channel set below for best results — these methods are designed for a focused proxy group.", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(bcg.method == .virtualECGPCA
                          ? "First principal component of the selected channel set drives Pan-Tompkins QRS detection."
                          : "Pan-Tompkins runs across the selected channel set and aggregates beats.",
                          systemImage: "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    BCGParameterLabel(
                        title: "Min HR",
                        explanation: "The slowest expected heart rate. For Virtual ECG, this helps define the band passed into PCA; for the proxy detector, it describes the intended physiological range. Lower it only when slow beats are expected."
                    )
                    TextField("BPM", value: $bcg.minHR, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Slider(value: $bcg.minHR, in: 30...80, step: 1)
                }
                HStack {
                    BCGParameterLabel(
                        title: "Max HR",
                        explanation: "The fastest expected heart rate. This sets the refractory period that prevents detections from occurring implausibly close together; for Virtual ECG it also bounds the preprocessing band."
                    )
                    TextField("BPM", value: $bcg.maxHR, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Slider(value: $bcg.maxHR, in: 60...180, step: 1)
                }
                Text("Max HR sets the refractory period (caps the beat rate); for Virtual ECG it also bounds the band-pass before PCA.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .qrsLocking:
            VStack(alignment: .leading, spacing: 10) {
                Text("QRS → BCG lag")
                    .font(.caption.weight(.semibold))
                if ecg.isEnabled {
                    Label("ECG detection is active — QRS times will be used.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("ECG / QRS detection must be enabled first (Artifacts → ECG / QRS Detection).", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    BCGParameterLabel(
                        title: "Lag",
                        explanation: "The mechanical delay from each detected ECG R-wave to the expected BCG artifact peak. Typical values are about 200–400 ms. Adjust it until event flags align with the BCG peak in the EEG."
                    )
                    TextField("ms", value: $bcg.qrsLagMs, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $bcg.qrsLagMs, in: 100...700, step: 10)
                }
            }

        case .cwlRegression:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("")
                        .frame(width: 100, alignment: .leading)
                    Toggle("EVA Fast CWR", isOn: $bcg.cwlUseEVAFastCWR)
                        .toggleStyle(.checkbox)
                    BCGHelpButton(
                        title: "EVA Fast CWR",
                        explanation: "Switches between two CWL regression implementations. Enabled uses EVA's faster regularized lag-range solver. Disabled uses a denser delay embedding with Hann-tapered overlap designed to match CWRegrTool behavior more closely."
                    )
                    Text(bcg.cwlUseEVAFastCWR ? "regularized sliding solver" : "CWRegrTool-compatible")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if bcg.cwlUseEVAFastCWR {
                    Text("Lag range")
                        .font(.caption.weight(.semibold))
                    Text("Each CWL channel is regressed at every lag in this range; the fit is subtracted using a sliding window so the coupling can drift across the recording.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        BCGParameterLabel(
                            title: "Min lag",
                            explanation: "The earliest temporal offset tested between each CWL reference and EEG channel. Negative values allow the reference to lead the EEG. Widening the range increases flexibility and computation."
                        )
                        TextField("ms", value: $bcg.cwlLagRangeMinMs, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        BCGParameterLabel(
                            title: "Max lag",
                            explanation: "The latest temporal offset tested between the CWL reference and EEG. Positive values allow the reference-related artifact to appear later in the EEG. It must be greater than the minimum lag.",
                            width: nil
                        )
                            .padding(.leading, 8)
                        TextField("ms", value: $bcg.cwlLagRangeMaxMs, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Text("ms")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        BCGParameterLabel(
                            title: "Lag step",
                            explanation: "Spacing between candidate delays in the lag range. Smaller steps model timing more precisely but add regressors and computation; larger steps are faster but may miss the best alignment."
                        )
                        TextField("ms", value: $bcg.cwlLagStepMs, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        BCGParameterLabel(
                            title: "Window",
                            explanation: "Length of each sliding regression fit. Short windows track changing wire coupling more quickly but have fewer samples and can overfit; longer windows are more stable but adapt slowly.",
                            width: nil
                        )
                            .padding(.leading, 8)
                        TextField("s", value: $bcg.cwlWindowSeconds, format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Text("s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("CWRegrTool")
                        .font(.caption.weight(.semibold))
                    Text("Uses dense ±delay sample embedding with a Hann-tapered overlap, matching the original CWRegrTool default as closely as practical inside EVA.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        BCGParameterLabel(
                            title: "Delay",
                            explanation: "Half-width of the dense CWRegrTool-style delay embedding around each CWL reference sample. The 21 ms default follows CWRegrTool; increasing it captures broader timing offsets but creates a larger regression."
                        )
                        TextField("ms", value: $bcg.cwlDelayMs, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        BCGParameterLabel(
                            title: "Window",
                            explanation: "Length of each Hann-tapered CWL regression segment. The 4-second default balances stable estimation with the ability to follow changes in coupling across the run.",
                            width: nil
                        )
                            .padding(.leading, 8)
                        TextField("s", value: $bcg.cwlWindowSeconds, format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Text("s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    BCGParameterLabel(
                        title: "Downsample",
                        explanation: "Runs the internal CWL regression at a lower sample rate to reduce computation. Full rate preserves all timing detail. A lower rate is usually sufficient for BCG/CWL structure if appropriate anti-alias filtering is used."
                    )
                    Picker("Downsample", selection: cwlDownsampleSelectionBinding(for: signal.samplingRate)) {
                        Text("Full rate (\(cwlRateLabel(signal.samplingRate)))").tag(0.0)
                        ForEach(cwlDownsampleTargets(for: signal.samplingRate), id: \.self) { target in
                            Text(cwlDownsampleOptionLabel(sourceRate: signal.samplingRate, targetRate: target))
                                .tag(target)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 170, alignment: .leading)
                    Text("internal fit only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    BCGParameterLabel(
                        title: "Anti-alias",
                        explanation: "The low-pass method applied before downsampling. Windowed-sinc provides cleaner suppression of frequencies that would fold into the lower-rate signal; block averaging is faster but less selective."
                    )
                    Picker("Anti-alias", selection: $bcg.cwlDownsampleFilter) {
                        ForEach(CWLCorrector.DownsampleFilter.allCases) { filter in
                            Text(filter.label).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220, alignment: .leading)
                    Text("before downsampling")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("")
                        .frame(width: 100, alignment: .leading)
                    Toggle("Upsample to original Hz", isOn: $bcg.cwlUpsampleToOriginalHz)
                        .toggleStyle(.checkbox)
                    BCGHelpButton(
                        title: "Upsample to original Hz",
                        explanation: "After fitting at a lower rate, maps the estimated artifact back to the recording's original sample rate before subtraction. Enable this to preserve the original output sampling rate; disable it to keep the corrected lower-rate signal."
                    )
                    Text("after CWL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(cwlDownsampleSelectionBinding(for: signal.samplingRate).wrappedValue == 0)
            }

        case .surrogatePCAS:
            surrogateOptions(for: signal)
        }
    }

    // MARK: - Surrogate separation (PCA-S)

    /// What PCA-S is about to assume, what it has to work with, and the
    /// settings that change the answer.
    ///
    /// The declarations at the top are not decoration. The brain model is a
    /// three-shell sphere fitted to nobody, and the coordinates are whatever the
    /// package carries — an operator reading a corrected recording has to be
    /// able to see both without opening the audit log (ROADMAP SI-3).
    @ViewBuilder
    func surrogateOptions(for signal: MFFSignalData) -> some View {
        let beats = surrogateBeatTimes()
        let rows = surrogateCorrectedRows(for: signal)
        let missingGeometry = surrogateMissingGeometryChannels(for: signal)

        VStack(alignment: .leading, spacing: 10) {
            Text("Assumptions")
                .font(.caption.weight(.semibold))
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    electrodeGeometry.map { "Coordinates: \($0.name)" }
                        ?? "Coordinates: none loaded",
                    systemImage: electrodeGeometry == nil ? "xmark.octagon" : "checkmark.circle"
                )
                .foregroundStyle(electrodeGeometry == nil ? Color.red : Color.secondary)
                Label(
                    "Head model: \(ForwardHeadModel.classicThreeShell.name) — "
                        + ForwardHeadModel.classicThreeShell.shells
                            .map { String(format: "%.0f", $0.radiusMeters * 1000) }
                            .joined(separator: "/") + " mm",
                    systemImage: "circle.dashed"
                )
                .foregroundStyle(.secondary)
                Label(
                    "Beats: \(beats.count) \(bcg.beatEventCode) event\(beats.count == 1 ? "" : "s")",
                    systemImage: beats.isEmpty ? "exclamationmark.triangle" : "heart"
                )
                .foregroundStyle(beats.isEmpty ? Color.orange : Color.secondary)
                Label(
                    "Channels: \(rows.count) corrected, \(signal.data.count - rows.count) excluded",
                    systemImage: "waveform"
                )
                .foregroundStyle(.secondary)
            }
            .font(.caption2)

            if !missingGeometry.isEmpty {
                Label(
                    "No coordinates for channel\(missingGeometry.count == 1 ? "" : "s") "
                        + missingGeometry.prefix(8).map(String.init).joined(separator: ", ")
                        + (missingGeometry.count > 8 ? ", …" : "")
                        + ". PCA-S will not run with an approximated montage.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Separation")
                .font(.caption.weight(.semibold))
            HStack {
                BCGParameterLabel(
                    title: "Pattern search",
                    explanation: "How the representative BCG pattern is chosen before beats are averaged. Paper follows the publication: one representative beat, then a single correlation pass. Iterative starts from the all-beat average and refines twice, which judges each beat against the artifact rather than against one noisy example."
                )
                Picker("Pattern search", selection: $bcg.surrogateSettings.patternSearch) {
                    ForEach(BCGArtifactPatternSearch.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 260, alignment: .leading)
            }
            HStack {
                BCGParameterLabel(
                    title: "Brain regularization",
                    explanation: "The penalty on the brain block. This is the mechanism, not a tuning knob: the artifact block is unregularized, so any variance the artifact topographies can explain is cheaper to put there. Halve it and the method removes less; raise it and it starts removing brain signal. The published value is 2%."
                )
                TextField("", value: $bcg.surrogateSettings.brainRegularization, format: .number.precision(.fractionLength(3)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Slider(value: $bcg.surrogateSettings.brainRegularization, in: 0.002...0.1)
            }
            HStack {
                BCGParameterLabel(
                    title: "Regional sources",
                    explanation: "How many regional sources make up the brain model. Each is three orthogonal dipoles, so 29 sources give 87 columns — the published configuration. More sources describe brain activity more richly and leave the artifact block less to absorb."
                )
                TextField("", value: $bcg.surrogateSettings.regionalSourceCount, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Stepper("", value: $bcg.surrogateSettings.regionalSourceCount, in: 8...60)
                    .labelsHidden()
            }
            HStack {
                BCGParameterLabel(
                    title: "Beat match",
                    explanation: "Spatio-temporal correlation a beat must reach to join the template. Lower it when few beats are accepted; raise it when the template looks contaminated."
                )
                TextField("", value: $bcg.surrogateSettings.correlationThreshold, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Slider(value: $bcg.surrogateSettings.correlationThreshold, in: 0.2...0.95)
            }
            HStack {
                BCGParameterLabel(
                    title: "Component reliability",
                    explanation: "The split-half correlation a template component must reach to be treated as artifact. A real BCG component is the same shape on odd and even beats; ongoing EEG that survived the average is not. Lowering this admits components that cost brain signal — measured on a brain-dominated test recording, dropping it from 0.9 to 0.5 turned a 2.8:1 recording into a 1.7:1 one."
                )
                TextField("", value: $bcg.surrogateSettings.minimumComponentReliability, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Slider(value: $bcg.surrogateSettings.minimumComponentReliability, in: 0.3...0.99)
            }

            if let report = bcg.surrogateReport {
                Divider()
                Text("Last run")
                    .font(.caption.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.summary)
                    Text("Components kept: "
                         + report.artifactComponentReliabilities
                            .map { String(format: "r=%.2f", $0) }.joined(separator: ", ")
                         + (report.reliabilityRejectedComponentCount > 0
                            ? " · \(report.reliabilityRejectedComponentCount) rejected as unreliable"
                            : ""))
                    Text("Brain model: \(report.brainColumnCount) columns from "
                         + "\(report.regionalSourceCount) regional sources, "
                         + String(format: "%.1f%% regularization", report.brainRegularization * 100))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }

    func cwlDownsampleTargets(for sourceRate: Double) -> [Double] {
        let commonRates = [2500.0, 1000.0, 500.0, 250.0, 125.0]
        return commonRates.filter { target in
            target < sourceRate - 0.5 && Downsampler.factor(sourceRate: sourceRate, targetRate: target) > 1
        }
    }

    func cwlDownsampleSelectionBinding(for sourceRate: Double) -> Binding<Double> {
        Binding(
            get: {
                let targets = cwlDownsampleTargets(for: sourceRate)
                return targets.contains(bcg.cwlDownsampleTargetHz) ? bcg.cwlDownsampleTargetHz : 0
            },
            set: { value in
                let targets = cwlDownsampleTargets(for: sourceRate)
                bcg.cwlDownsampleTargetHz = targets.contains(value) ? value : 0
            }
        )
    }

    func cwlDownsampleOptionLabel(sourceRate: Double, targetRate: Double) -> String {
        let factor = Downsampler.factor(sourceRate: sourceRate, targetRate: targetRate)
        let effectiveRate = Downsampler.effectiveRate(sourceRate: sourceRate, factor: factor)
        if abs(effectiveRate - targetRate) <= 0.5 {
            return cwlRateLabel(targetRate)
        }
        return "≈\(cwlRateLabel(effectiveRate))"
    }

    func cwlRateLabel(_ rate: Double) -> String {
        if abs(rate.rounded() - rate) < 0.05 {
            return "\(Int(rate.rounded())) Hz"
        }
        return "\(String(format: "%.1f", rate)) Hz"
    }

    func disableBCGDetection() {
        PipelineStageToggles.disableBCGDetection(bcg: bcg, artifactVM: artifactVM, template: template)
    }

    /// When the "auto-select proxy set" default is on, pick a compatible
    /// built-in BCG channel set the first time the sheet opens.
    func autoSelectBCGProxySetIfEnabled(for signal: MFFSignalData) {
        guard processingDefaults.bcgAutoSelectProxySet, bcg.channelSetID == nil else { return }
        if let set = ChannelSetStore.builtInSets.first(where: {
            $0.name.localizedCaseInsensitiveContains("BCG")
                && ($0.channelIndices.max() ?? -1) < signal.numberOfChannels
        }) {
            bcg.channelSetID = set.id
        }
    }

    func runBCGDetection(signal: MFFSignalData, selection: ClosedRange<Int>?) async {
        await processingQueue.run("BCG Detection") { [self] in
            await runBCGDetectionCore(signal: signal, selection: selection)
        }
    }

    private func runBCGDetectionCore(signal: MFFSignalData, selection: ClosedRange<Int>?) async {
        let sessionID = recordingSessionID
        bcg.isRunning = true
        bcg.progress = nil
        bcg.status = "Detecting…"
        bcg.refinedTemplate = nil
        bcg.refinedKeptCount = nil

        // Restrict to a channel set when one is selected (GFP-based methods).
        let restrictedIndices: [Int]? = bcg.channelSetID.flatMap { id in
            ChannelSetStore.shared.allSets.first(where: { $0.id == id })?
                .channelIndices.filter { signal.data.indices.contains($0) }
        }
        let channels: [[Float]] = {
            guard let restrictedIndices, !restrictedIndices.isEmpty else { return signal.data }
            return restrictedIndices.map { signal.data[$0] }
        }()
        let sr          = signal.samplingRate
        let duration    = signal.duration
        let threshold   = bcg.thresholdSD
        let method      = bcg.method
        let configuration = BCGDetectionPreviewConfiguration(
            thresholdSD: threshold,
            minHR: bcg.minHR,
            maxHR: bcg.maxHR,
            powerMinHz: bcg.powerMinHz,
            powerMaxHz: bcg.powerMaxHz,
            qrsLagSeconds: bcg.qrsLagMs / 1000,
            pcaComponents: bcg.pcaComponents,
            spatialWhiten: bcg.spatialWhiten,
            slidingNormalize: bcg.slidingNormalize,
            respAdaptive: bcg.respAdaptive
        )
        let qrsTimes = artifactVM.events
            .filter { $0.code == RWaveDetector.eventCode }
            .map(\.beginTimeSeconds)
        let hemisphericChannels = hemisphericPreviewChannels(for: signal)

        // With NonisolatedNonsendingByDefault, merely awaiting a nonisolated
        // detector does not guarantee that its CPU work leaves MainActor. Run
        // the complete algorithm path on an explicit worker instead; only the
        // event/status publication below belongs on the UI actor.
        let detectionWorker = Task.detached(priority: .userInitiated) {
            await BCGDetectionPreviewEstimator.eventTimes(
                method: method,
                channels: channels,
                samplingRate: sr,
                duration: duration,
                exemplarRange: selection,
                qrsTimes: qrsTimes,
                configuration: configuration,
                hemisphericChannels: hemisphericChannels
            ) ?? []
        }
        let times = await withTaskCancellationHandler(
            operation: {
                await detectionWorker.value
            },
            onCancel: {
                detectionWorker.cancel()
            }
        )

        guard !Task.isCancelled, sessionID == recordingSessionID else {
            if sessionID == recordingSessionID {
                bcg.isRunning = false
                bcg.progress = nil
            }
            return
        }
        let code    = bcg.eventCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let useCode = code.isEmpty ? BCGDetector.eventCode : code

        let newEvents = BCGDetector.makeEvents(
            times: times,
            idPrefix: "bcg-\(method.rawValue)",
            code: useCode,
            windowSeconds: bcg.windowSeconds
        )

        let nonBCG = artifactVM.events.filter { $0.sourceFile != BCGDetector.sourceFile }
        artifactVM.events = (nonBCG + newEvents).sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }

        if let estBPM = estimatedBPM(from: times) {
            bcg.status = "✓ \(newEvents.count) events  ·  ~\(String(format: "%.0f", estBPM)) BPM"
        } else {
            bcg.status = newEvents.isEmpty
                ? "No events detected — try lowering the threshold or check channel selection."
                : "✓ \(newEvents.count) events"
        }

        bcg.detectsArtifacts = !newEvents.isEmpty
        if !newEvents.isEmpty {
            selectedEventCodes = [useCode]
            registerBCGDefinedArtifact(events: newEvents, eventCode: useCode)
        }
        bcg.isRunning = false
        bcg.progress = nil
        if !newEvents.isEmpty {
            bcg.showsSheet = false
        }
    }

    func runBCGRefinement(signal: MFFSignalData) async {
        await processingQueue.run("BCG Refinement") { [self] in
            await runBCGRefinementCore(signal: signal)
        }
    }

    private func runBCGRefinementCore(signal: MFFSignalData) async {
        let sessionID = recordingSessionID
        let existingTimes = artifactVM.events
            .filter { $0.sourceFile == BCGDetector.sourceFile }
            .map { $0.beginTimeSeconds }
        guard !existingTimes.isEmpty else { return }

        let channels = signal.data
        let sr = signal.samplingRate

        bcg.isRefining = true
        bcg.progress = nil
        bcg.status = "Refining…"

        let result = await BCGDetector.refineSpatialPCA(
            channels: channels,
            samplingRate: sr,
            detectedTimes: existingTimes,
            rejectFraction: bcg.rejectFraction,
            numComponents: bcg.pcaComponents,
            spatialWhiten: bcg.spatialWhiten,
            slidingNormalize: bcg.slidingNormalize,
            respAdaptive: bcg.respAdaptive,
            thresholdSD: bcg.thresholdSD
        )

        guard !Task.isCancelled, sessionID == recordingSessionID else { return }
        guard let (newTimes, templateValues, keptCount) = result else {
            bcg.status = "⚠ Not enough detected events to refine"
            bcg.isRefining = false
            return
        }

        let useCode = bcg.eventCode.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? BCGDetector.eventCode : bcg.eventCode
        let newEvents = BCGDetector.makeEvents(
            times: newTimes,
            idPrefix: "bcg-refined",
            code: useCode,
            windowSeconds: bcg.windowSeconds
        )

        let nonBCG = artifactVM.events.filter { $0.sourceFile != BCGDetector.sourceFile }
        artifactVM.events = (nonBCG + newEvents).sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
        bcg.detectsArtifacts = true
        bcg.refinedTemplate = templateValues
        bcg.refinedKeptCount = keptCount

        let total = existingTimes.count
        let bpmStr = estimatedBPM(from: newTimes).map { String(format: "  ·  ~%.0f BPM", $0) } ?? ""
        bcg.status = "✓ Refined: \(keptCount)/\(total) beats kept → \(newEvents.count) events\(bpmStr)"
        registerBCGDefinedArtifact(events: newEvents, eventCode: useCode)
        bcg.isRefining = false
    }

    func registerBCGDefinedArtifact(events: [MFFEvent], eventCode: String) {
        let artifact = DefinedArtifact(
            id: bcg.definedArtifactID,
            type: .bcg,
            name: "BCG",
            eventCode: eventCode,
            events: events,
            selectedChannelIndices: [],
            windowSizeSeconds: bcg.windowSeconds,
            average: nil,
            topography: nil,
            cleaningMethod: .obs
        )
        if let index = template.definedArtifacts.firstIndex(where: { $0.id == bcg.definedArtifactID }) {
            let previous = template.definedArtifacts[index]
            template.definedArtifacts[index] = artifact
            template.definedArtifacts[index].preserveCleaningSettings(from: previous)
        } else {
            template.definedArtifacts.append(artifact)
        }
        invalidateOBSVarianceCache(for: bcg.definedArtifactID)
        clearAppliedArtifactCleaning()
    }

    func estimatedBPM(from times: [Double]) -> Double? {
        BCGDetectionPreviewEstimator.estimatedBPM(from: times)
    }

    // MARK: - CWL regression (direct correction — no events/ArtifactCleaner involved)

    @ViewBuilder
    func cwlChannelPicker() -> some View {
        if let pns = displayedPhysioSignal() {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("CWL Channels")
                        .font(.caption.weight(.semibold))
                    BCGHelpButton(
                        title: "CWL Channels",
                        explanation: "Select the external wire-loop reference channels imported with the PNS data. These channels should measure scanner- and motion-induced interference rather than ECG or respiration. The selected references become regressors for CWL correction."
                    )
                    Spacer()
                    Button("Likely CWL") {
                        bcg.selectedCWLChannels = Set(likelyCWLPNSChannelIndices(in: pns))
                    }
                    Button("All") {
                        bcg.selectedCWLChannels = Set(pns.data.indices)
                    }
                    Button("None") {
                        bcg.selectedCWLChannels.removeAll()
                    }
                }
                Text("CWL leads are imported as PNS channels, same as ECG/pulse. Select the wire-loop channels to use as regressors.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(pns.data.indices), id: \.self) { index in
                            Toggle(pnsChannelDisplayName(index: index, signal: pns), isOn: cwlPNSSelectionBinding(for: index))
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 130)
            }
        } else {
            Label("No PNS channels are loaded. Import the CWL leads as PNS channels first.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func cwlPNSSelectionBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { bcg.selectedCWLChannels.contains(index) },
            set: { isSelected in
                if isSelected {
                    bcg.selectedCWLChannels.insert(index)
                } else {
                    bcg.selectedCWLChannels.remove(index)
                }
            }
        )
    }

    /// Name-based heuristic for the CWL leads among the imported PNS channels,
    /// mirroring `likelyECGPNSChannelIndices` — matches common exporter labels
    /// for carbon-wire-loop pickups.
    func likelyCWLPNSChannelIndices(in pns: MFFSignalData) -> [Int] {
        let names = pns.channelNames ?? []
        let cwlTokens = ["cwl", "wire", "loop", "carbon"]
        return pns.data.indices.filter { index in
            guard names.indices.contains(index) else { return false }
            let lower = names[index].lowercased()
            return cwlTokens.contains { lower.contains($0) }
        }
    }

    /// When the sheet opens on the CWL tab with nothing selected yet, seed
    /// the picker with the name-based guess so the user isn't starting blank.
    func prepareCWLDefaults(pns: MFFSignalData?) {
        guard let pns else {
            bcg.selectedCWLChannels.removeAll()
            return
        }
        bcg.selectedCWLChannels = bcg.selectedCWLChannels.filter { pns.data.indices.contains($0) }
        if bcg.selectedCWLChannels.isEmpty {
            bcg.selectedCWLChannels = Set(likelyCWLPNSChannelIndices(in: pns))
        }
    }

    func runCWLCorrection(signal: MFFSignalData) async {
        await processingQueue.run("CWL Correction") { [self] in
            await runCWLCorrectionCore(signal: signal)
        }
    }

    private func runCWLCorrectionCore(signal: MFFSignalData) async {
        let sessionID = recordingSessionID
        guard let pns = displayedPhysioSignal() else {
            bcg.status = "⚠ No PNS channels loaded — import the CWL leads first."
            return
        }
        let referenceIndices = bcg.selectedCWLChannels.sorted().filter { pns.data.indices.contains($0) }
        guard !referenceIndices.isEmpty else {
            bcg.status = "⚠ Select at least one CWL reference channel."
            return
        }
        guard pns.samplingRate == signal.samplingRate, pns.data.first?.count == signal.data.first?.count else {
            bcg.status = "⚠ PNS and EEG sampling rate/length must match for CWL regression."
            return
        }

        bcg.isRunning = true
        bcg.progress = 0
        bcg.status = "Preparing CWL correction…"

        let references = referenceIndices.map { pns.data[$0] }
        let sourceData = signal.data
        let sr = signal.samplingRate
        let lagRange = bcg.cwlLagRangeMinMs...max(bcg.cwlLagRangeMaxMs, bcg.cwlLagRangeMinMs + 1)
        let lagStep = bcg.cwlLagStepMs
        let cwlDelayMs = bcg.cwlDelayMs
        let windowSeconds = bcg.cwlWindowSeconds
        let cwlAlgorithm = bcg.cwlUseEVAFastCWR ? CWLCorrector.Algorithm.evaFast : .cwRegrTool
        let selectedDownsampleTarget = cwlDownsampleTargets(for: sr).contains(bcg.cwlDownsampleTargetHz)
            ? bcg.cwlDownsampleTargetHz
            : 0
        let downsampleFactor = selectedDownsampleTarget > 0
            ? Downsampler.factor(sourceRate: sr, targetRate: selectedDownsampleTarget)
            : 1
        let downsampleEffectiveRate = Downsampler.effectiveRate(sourceRate: sr, factor: downsampleFactor)
        let downsampleFilter = bcg.cwlDownsampleFilter
        let upsampleToOriginalHz = downsampleFactor > 1 && bcg.cwlUpsampleToOriginalHz

        let (progressContinuation, progressTask) = ProgressBridge.make { [weak bcg] (update: CWLCorrector.ProgressUpdate) in
            let clamped = min(max(update.fraction, 0), 1)
            let percent = Int((clamped * 100).rounded())
            bcg?.progress = clamped
            if let detail = update.detail, !detail.isEmpty {
                bcg?.status = "\(update.message)… \(percent)% · \(detail)"
            } else {
                bcg?.status = "\(update.message)… \(percent)%"
            }
        }

        do {
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try CWLCorrector.correct(
                    eeg: sourceData,
                    references: references,
                    samplingRate: sr,
                    lagRangeMs: lagRange,
                    lagStepMs: lagStep,
                    cwlToolDelayMs: cwlDelayMs,
                    windowSeconds: windowSeconds,
                    algorithm: cwlAlgorithm,
                    downsampleFactor: downsampleFactor,
                    downsampleFilter: downsampleFilter,
                    upsampleToOriginalRate: upsampleToOriginalHz
                ) { update in
                    progressContinuation.yield(update)
                } debugLog: { message in
                    debugLog(message)
                }
            }
            let correctedData = try await withTaskCancellationHandler(
                operation: { try await worker.value },
                onCancel: {
                    worker.cancel()
                    progressContinuation.finish()
                }
            )
            progressContinuation.finish()
            progressTask.cancel()
            guard !Task.isCancelled, sessionID == recordingSessionID else {
                bcg.isRunning = false
                bcg.progress = nil
                return
            }

            let outputRate = downsampleFactor > 1 && !upsampleToOriginalHz && correctedData.first?.count != sourceData.first?.count
                ? downsampleEffectiveRate
                : sr
            if outputRate == sr, correctedData.first?.count == signal.data.first?.count {
                bcg.correctedSignal = signal.replacingSamples(correctedData, signalTypeSuffix: "CWL")
                // Only the rate-preserving branch is accounted. When CWL
                // downsamples, input and output samples do not correspond, so a
                // sample-wise difference would not be the removed signal --
                // it would be the removed signal plus the resampling. Better to
                // report nothing than to report that as artifact.
                bcg.store.cleaningVariance.record(
                    CleaningVarianceAccount.between(
                        original: signal.data,
                        cleaned: correctedData,
                        samplingRate: sr,
                        epochSeconds: CleaningVarianceAccount.defaultEpochSeconds,
                        stageName: "cwlCorrection"
                    )
                )
            } else {
                bcg.store.cleaningVariance.clear(stageName: "cwlCorrection")
                let ratio = outputRate / sr
                let segments = signal.epochSegments.compactMap { segment -> EpochSegment? in
                    let start = Int((Double(segment.startSample) * ratio).rounded())
                    let endExclusive = Int((Double(segment.endSample + 1) * ratio).rounded())
                    guard endExclusive > start else { return nil }
                    return EpochSegment(
                        startSample: start,
                        endSample: endExclusive - 1,
                        stimulusOffsetSamples: Int((Double(segment.stimulusOffsetSamples) * ratio).rounded()),
                        category: segment.category,
                        sourceCode: segment.sourceCode,
                        sourceTimeSeconds: segment.sourceTimeSeconds,
                        colorIndex: segment.colorIndex,
                        contributingEpochCount: segment.contributingEpochCount,
                        subject: segment.subject
                    )
                }
                bcg.correctedSignal = signal.reconstructingTimeline(
                    data: correctedData,
                    samplingRate: outputRate,
                    events: signal.events,
                    epochSegments: segments,
                    isSegmented: signal.isSegmented,
                    isAveraged: signal.isAveraged,
                    isGrandAverage: signal.isGrandAverage,
                    signalTypeSuffix: "CWL"
                )
            }
            bcg.progress = 1
            let algorithmSummary = " \(cwlAlgorithm.label)."
            let downsampleSummary: String
            if downsampleFactor > 1 {
                downsampleSummary = upsampleToOriginalHz
                    ? " Fit at \(cwlRateLabel(downsampleEffectiveRate)) using \(downsampleFilter.shortLabel); output upsampled to \(cwlRateLabel(sr))."
                    : " Fit and output at \(cwlRateLabel(outputRate)) using \(downsampleFilter.shortLabel)."
            } else {
                downsampleSummary = ""
            }
            bcg.status = "✓ CWL correction applied (\(referenceIndices.count) reference channel\(referenceIndices.count == 1 ? "" : "s")).\(algorithmSummary)\(downsampleSummary)"

            // Downstream stages built on the old base are now stale — same
            // cross-domain invalidation as `applyGradientCorrection`, since
            // `bcg.correctedSignal` sits in the same base-signal chain
            // between gradient correction and ICA. The `cwlCorrection` variance
            // account recorded above survives it: the cascade clears only the
            // stages it invalidates.
            invalidateDownstreamOfBaseSignalChange()
            bcg.showsSheet = false
        } catch is CancellationError {
            progressContinuation.finish()
            progressTask.cancel()
            bcg.progress = nil
        } catch {
            progressContinuation.finish()
            progressTask.cancel()
            bcg.progress = nil
            bcg.status = error.localizedDescription
        }
        bcg.isRunning = false
    }

    // MARK: - PCA-S correction

    /// Beats PCA-S will lock to: this recording's BCG events, or — when the BCG
    /// detector has not run — the R-waves an ECG detector found.
    ///
    /// Falling back to QRS is not a liberty: the mechanical beat follows the
    /// R-wave by a fixed delay, the template window starts before zero, and the
    /// pattern search aligns whatever it is given. What it must never do is
    /// invent beats.
    func surrogateBeatTimes() -> [Double] {
        let code = bcg.beatEventCode
        let bcgBeats = artifactVM.events
            .filter { $0.code == code }
            .map(\.beginTimeSeconds)
            .sorted()
        if !bcgBeats.isEmpty { return bcgBeats }
        return artifactVM.events
            .filter { $0.code == RWaveDetector.eventCode }
            .map(\.beginTimeSeconds)
            .sorted()
    }

    /// The good EEG subset: every row except the ones marked bad.
    ///
    /// Hidden channels stay in — hiding is a display decision and does not make
    /// a channel's data wrong — while a bad channel would contribute a
    /// topography the model then has to explain as brain or artifact.
    func surrogateCorrectedRows(for signal: MFFSignalData) -> [Int] {
        signal.data.indices.filter { !channels.bad.contains($0) }
    }

    /// One-based channel numbers in the corrected subset that have no
    /// coordinates, for the sheet's refusal notice.
    func surrogateMissingGeometryChannels(for signal: MFFSignalData) -> [Int] {
        guard let electrodeGeometry else { return [] }
        return surrogateCorrectedRows(for: signal)
            .filter { electrodeGeometry.positions[$0] == nil }
            .map { $0 + 1 }
    }

    func runSurrogateCorrection(signal: MFFSignalData) async {
        await processingQueue.run("BCG PCA-S Correction") { [self] in
            await runSurrogateCorrectionCore(signal: signal)
        }
    }

    private func runSurrogateCorrectionCore(signal: MFFSignalData) async {
        let sessionID = recordingSessionID
        let beats = surrogateBeatTimes()
        let rows = surrogateCorrectedRows(for: signal)
        let geometry = electrodeGeometry
        let settings = bcg.surrogateSettings
        let sourceData = signal.data
        let names = signal.channelNames
        let samplingRate = signal.samplingRate

        bcg.isRunning = true
        bcg.progress = nil
        bcg.status = "Building the surrogate model…"

        do {
            let worker = Task.detached(priority: .userInitiated) {
                try await BCGSurrogateCorrection.correct(
                    data: sourceData,
                    samplingRate: samplingRate,
                    correctedRows: rows,
                    geometry: geometry,
                    channelNames: names,
                    beatSeconds: beats,
                    settings: settings
                )
            }
            let output = try await withTaskCancellationHandler(
                operation: { try await worker.value },
                onCancel: { worker.cancel() }
            )
            guard !Task.isCancelled, sessionID == recordingSessionID else {
                bcg.isRunning = false
                bcg.progress = nil
                return
            }

            bcg.correctedSignal = signal.replacingSamples(output.data, signalTypeSuffix: "PCAS")
            bcg.appliedCorrection = .surrogatePCAS
            bcg.surrogateReport = output.report
            bcg.surrogateAuditLogLines = output.report.auditLogLines
            // The variance account the roadmap names, for the export audit log.
            recordingStore.cleaningVariance.record(
                CleaningVarianceAccount.between(
                    original: sourceData,
                    cleaned: output.data,
                    samplingRate: samplingRate,
                    epochSeconds: CleaningVarianceAccount.defaultEpochSeconds,
                    stageName: BCGSurrogateCorrection.varianceStageName
                )
            )
            bcg.status = "✓ PCA-S applied — \(output.report.summary)"
            // Same base-signal slot as CWL and gradient correction, so the same
            // shared cascade.
            invalidateDownstreamOfBaseSignalChange()
            bcg.showsSheet = false
        } catch {
            guard sessionID == recordingSessionID else { return }
            bcg.status = "⚠ \(error.localizedDescription)"
        }
        bcg.isRunning = false
        bcg.progress = nil
    }

    func disableSurrogateCorrection() {
        bcg.correctedSignal = nil
        bcg.appliedCorrection = nil
        bcg.surrogateReport = nil
        bcg.surrogateAuditLogLines = []
        bcg.status = nil
        recordingStore.cleaningVariance.clear(stageName: BCGSurrogateCorrection.varianceStageName)
        invalidateDownstreamOfBaseSignalChange()
    }

    func disableCWLCorrection() {
        bcg.correctedSignal = nil
        bcg.progress = nil
        bcg.status = nil
        // As in `clearGradientCorrection`: the shared cascade clears the stages
        // it invalidates, and the stage being removed clears its own account.
        recordingStore.cleaningVariance.clear(stageName: "cwlCorrection")
        invalidateDownstreamOfBaseSignalChange()
    }
}
