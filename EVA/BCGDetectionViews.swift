//
//  BCGDetectionViews.swift
//  EVA
//
//  BCG (ballistocardiogram) detection sheet and its supporting helpers,
//  extracted from WaveformView.swift during the L5 view-decomposition refactor.
//  This is an extension of WaveformView (not a standalone type), following the
//  same pattern as ECGDetectionViews.swift — the cluster reads/writes
//  WaveformView's own @State and stores (bcg, artifactVM, template), so this is
//  a file split, not a state extraction.
//

import SwiftUI

extension WaveformView {
    // MARK: - BCG Detection sheet

    @ViewBuilder
    func bcgDetectionSheet(for signal: MFFSignalData, selection: ClosedRange<Int>?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("BCG Detection")
                    .font(.headline)
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
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            // Method description
            Text(bcg.method.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider()

            // Per-method options
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    bcgMethodOptions(for: signal, selection: selection)

                    // Channel restriction — applies to the GFP-based methods.
                    if bcg.method != .qrsLocking {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("BCG Channels")
                                .font(.caption.weight(.semibold))
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

                    // Shared options
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Output")
                            .font(.caption.weight(.semibold))

                        HStack {
                            Text("Event code")
                                .font(.caption)
                                .frame(width: 100, alignment: .leading)
                            TextField("BCG", text: $bcg.eventCode)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("Window")
                                .font(.caption)
                                .padding(.leading, 8)
                            TextField("s", value: $bcg.windowSeconds, format: .number.precision(.fractionLength(3)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                            Text("s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Threshold")
                                .font(.caption)
                                .frame(width: 100, alignment: .leading)
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

                    if let status = bcg.status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(status.hasPrefix("✓") ? Color.green : .secondary)
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
                                Text("Reject fraction")
                                    .font(.caption)
                                    .frame(width: 100, alignment: .leading)
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
                                        colorBarPlacement: .trailing,
                                        minimumMapHeight: 80
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
                if bcg.detectsArtifacts {
                    Button("Disable BCG Detection", role: .destructive) {
                        disableBCGDetection()
                        bcg.showsSheet = false
                    }
                }
                Spacer()
                if bcg.isRunning || bcg.isRefining {
                    ProgressView().controlSize(.small)
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
                .disabled(bcg.isRunning || (bcg.method == .qrsLocking && !detectsECGArtifacts))
            }
            .padding(20)
        }
        .frame(width: 644)
        .disabled(bcg.isRunning || bcg.isRefining)
    }

    @ViewBuilder
    func bcgMethodOptions(for signal: MFFSignalData, selection: ClosedRange<Int>?) -> some View {
        switch bcg.method {
        case .periodicity:
            VStack(alignment: .leading, spacing: 10) {
                Text("Heart rate range")
                    .font(.caption.weight(.semibold))
                HStack {
                    Text("Min HR")
                        .font(.caption)
                        .frame(width: 100, alignment: .leading)
                    TextField("BPM", value: $bcg.minHR, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("BPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $bcg.minHR, in: 30...80, step: 1)
                }
                HStack {
                    Text("Max HR")
                        .font(.caption)
                        .frame(width: 100, alignment: .leading)
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
                    Text("Components")
                        .font(.caption)
                        .frame(width: 100, alignment: .leading)
                    Stepper("\(bcg.pcaComponents)", value: $bcg.pcaComponents, in: 1...4)
                        .labelsHidden()
                    Text("\(bcg.pcaComponents) PC\(bcg.pcaComponents == 1 ? "" : "s") combined via RSS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help("Project onto the top N spatial components and combine scores via root-sum-of-squares. 2–3 components captures BCG sources that span more than one dipole.")

                Toggle(isOn: $bcg.spatialWhiten) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Spatial whitening")
                            .font(.caption)
                        Text("Suppresses alpha / muscle before PCA so BCG stands out")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Equalises all spatial directions by the background covariance before computing the BCG subspace. Reduces contamination from large non-BCG sources in the exemplar PCs.")

                Toggle(isOn: $bcg.respAdaptive) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Respiratory envelope normalization")
                            .font(.caption)
                        Text("6 s sliding RMS — tracks ~0.2 Hz BCG amplitude modulation")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .help("BCG amplitude is modulated ~10–20% by breathing. A short sliding RMS normalisation keeps sensitivity uniform across the breath cycle, preventing missed beats at respiratory troughs.")

                Toggle(isOn: $bcg.slidingNormalize) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sliding z-score normalization")
                            .font(.caption)
                        Text("30 s window — adapts to slow amplitude drift across the run")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Normalises the detection signal in a 30 s rolling window so the fixed SD threshold adapts to slow changes in BCG amplitude over the course of the recording.")
            }

        case .cardiacPowerMap:
            VStack(alignment: .leading, spacing: 10) {
                Text("Cardiac frequency band")
                    .font(.caption.weight(.semibold))
                HStack {
                    Text("Low cutoff")
                        .font(.caption)
                        .frame(width: 100, alignment: .leading)
                    TextField("Hz", value: $bcg.powerMinHz, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("Hz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $bcg.powerMinHz, in: 0.3...1.5, step: 0.05)
                }
                HStack {
                    Text("High cutoff")
                        .font(.caption)
                        .frame(width: 100, alignment: .leading)
                    TextField("Hz", value: $bcg.powerMaxHz, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("Hz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $bcg.powerMaxHz, in: 0.8...3.0, step: 0.05)
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
                    Text("Min HR")
                        .font(.caption)
                        .frame(width: 100, alignment: .leading)
                    TextField("BPM", value: $bcg.minHR, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Slider(value: $bcg.minHR, in: 30...80, step: 1)
                }
                HStack {
                    Text("Max HR")
                        .font(.caption)
                        .frame(width: 100, alignment: .leading)
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
                if detectsECGArtifacts {
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
                    Text("Lag")
                        .font(.caption)
                        .frame(width: 100, alignment: .leading)
                    TextField("ms", value: $bcg.qrsLagMs, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $bcg.qrsLagMs, in: 100...700, step: 10)
                }
                .help("Typical BCG onset lags the R-wave by 200–400 ms. Start at 300 ms and adjust to align the BCG artifact peak with detected events.")
            }
        }
    }

    func disableBCGDetection() {
        bcg.detectsArtifacts = false
        artifactVM.events = artifactVM.events.filter { $0.sourceFile != BCGDetector.sourceFile }
        template.definedArtifacts.removeAll { $0.id == bcgDefinedArtifactID }
        bcg.refinedTemplate = nil
        bcg.refinedKeptCount = nil
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
        let sessionID = recordingSessionID
        bcg.isRunning = true
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

        let times: [Double]

        switch method {
        case .periodicity:
            times = await BCGDetector.periodicityEvents(
                channels: channels,
                samplingRate: sr,
                minHR: bcg.minHR,
                maxHR: bcg.maxHR,
                thresholdSD: threshold
            )

        case .spatialPCA:
            let nComp      = bcg.pcaComponents
            let whiten     = bcg.spatialWhiten
            let slideNorm  = bcg.slidingNormalize
            let respNorm   = bcg.respAdaptive
            times = await BCGDetector.spatialPCAEvents(
                channels: channels,
                samplingRate: sr,
                exemplarRange: selection,
                numComponents: nComp,
                spatialWhiten: whiten,
                slidingNormalize: slideNorm,
                respAdaptive: respNorm,
                thresholdSD: threshold
            )

        case .cardiacPowerMap:
            times = await BCGDetector.cardiacPowerEvents(
                channels: channels,
                samplingRate: sr,
                minHz: bcg.powerMinHz,
                maxHz: bcg.powerMaxHz,
                thresholdSD: threshold
            )

        case .virtualECGPCA:
            let minRR = 60.0 / max(bcg.maxHR, 1) * 0.6
            if let pc = await BCGDetector.virtualECGComponent(
                channels: channels,
                samplingRate: sr,
                minHR: bcg.minHR,
                maxHR: bcg.maxHR
            ) {
                let source = ECGDetectionSource(
                    id: "bcg-virtual-ecg",
                    label: "Virtual ECG",
                    channelLabels: ["PC1"],
                    channels: [pc],
                    samplingRate: sr,
                    duration: duration
                )
                let config = ECGDetectionConfiguration(
                    algorithm: .panTompkins,
                    thresholdSD: threshold,
                    minimumRRSeconds: minRR,
                    polarity: .either
                )
                let worker = Task.detached(priority: .userInitiated) {
                    RWaveDetector.detect(sources: [source], configuration: config)
                        .map(\.beginTimeSeconds)
                }
                times = await withTaskCancellationHandler(
                    operation: {
                        await worker.value
                    },
                    onCancel: {
                        worker.cancel()
                    }
                )
            } else {
                times = []
            }

        case .panTompkinsProxy:
            let minRR = 60.0 / max(bcg.maxHR, 1) * 0.6
            let labels = restrictedIndices?.map { "Ch \($0 + 1)" }
                ?? channels.indices.map { "Ch \($0 + 1)" }
            let source = ECGDetectionSource(
                id: "bcg-pan-tompkins",
                label: "BCG Proxy",
                channelLabels: labels,
                channels: channels,
                samplingRate: sr,
                duration: duration
            )
            let config = ECGDetectionConfiguration(
                algorithm: .panTompkins,
                thresholdSD: threshold,
                minimumRRSeconds: minRR,
                polarity: .either
            )
            let worker = Task.detached(priority: .userInitiated) {
                RWaveDetector.detect(sources: [source], configuration: config)
                    .map(\.beginTimeSeconds)
            }
            times = await withTaskCancellationHandler(
                operation: {
                    await worker.value
                },
                onCancel: {
                    worker.cancel()
                }
            )

        case .qrsLocking:
            let qrsTimes = artifactVM.events
                .filter { $0.code == RWaveDetector.eventCode }
                .map { $0.beginTimeSeconds }
            times = BCGDetector.qrsLockingEvents(
                qrsTimes: qrsTimes,
                lagSeconds: bcg.qrsLagMs / 1000.0,
                recordingDuration: duration
            )
        }

        guard !Task.isCancelled, sessionID == recordingSessionID else { return }
        let code    = bcg.eventCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let useCode = code.isEmpty ? BCGDetector.eventCode : code

        let newEvents: [MFFEvent] = times.enumerated().map { (idx, t) in
            MFFEvent(
                id: "bcg-\(method.rawValue)-\(idx)-\(t)",
                code: useCode,
                beginTimeSeconds: t,
                rawBeginTime: String(format: "%.4f", t),
                sourceFile: BCGDetector.sourceFile
            )
        }

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
        showsEventsPanel = !newEvents.isEmpty
        if !newEvents.isEmpty {
            selectedEventCodes = [useCode]
            registerBCGDefinedArtifact(events: newEvents, eventCode: useCode)
        }
        bcg.isRunning = false
        if !newEvents.isEmpty {
            bcg.showsSheet = false
        }
    }

    func runBCGRefinement(signal: MFFSignalData) async {
        let sessionID = recordingSessionID
        let existingTimes = artifactVM.events
            .filter { $0.sourceFile == BCGDetector.sourceFile }
            .map { $0.beginTimeSeconds }
        guard !existingTimes.isEmpty else { return }

        let channels = signal.data
        let sr = signal.samplingRate

        bcg.isRefining = true
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
        let newEvents: [MFFEvent] = newTimes.enumerated().map { (idx, t) in
            MFFEvent(id: "bcg-refined-\(idx)-\(t)",
                     code: useCode,
                     beginTimeSeconds: t,
                     rawBeginTime: String(format: "%.4f", t),
                     sourceFile: BCGDetector.sourceFile)
        }

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
            id: bcgDefinedArtifactID,
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
        if let index = template.definedArtifacts.firstIndex(where: { $0.id == bcgDefinedArtifactID }) {
            let prevMethod    = template.definedArtifacts[index].cleaningMethod
            let prevOBSComps  = template.definedArtifacts[index].obsPCAComponentCount
            let prevTaper     = template.definedArtifacts[index].obsEdgeTaperSeconds
            let prevBaseline  = template.definedArtifacts[index].obsPreservesLocalBaseline
            let prevOverlap   = template.definedArtifacts[index].obsUsesOverlapAdd
            template.definedArtifacts[index] = artifact
            template.definedArtifacts[index].cleaningMethod              = prevMethod
            template.definedArtifacts[index].obsPCAComponentCount        = prevOBSComps
            template.definedArtifacts[index].obsEdgeTaperSeconds         = prevTaper
            template.definedArtifacts[index].obsPreservesLocalBaseline   = prevBaseline
            template.definedArtifacts[index].obsUsesOverlapAdd           = prevOverlap
        } else {
            template.definedArtifacts.append(artifact)
        }
        invalidateOBSVarianceCache(for: bcgDefinedArtifactID)
        clearAppliedArtifactCleaning()
    }

    func estimatedBPM(from times: [Double]) -> Double? {
        guard times.count >= 2 else { return nil }
        let sorted = times.sorted()
        let ipi = zip(sorted.dropFirst(), sorted).map { $0 - $1 }
        let median = ipi.sorted()[ipi.count / 2]
        guard median > 0 else { return nil }
        return 60.0 / median
    }
}
