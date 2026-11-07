//
//  EEGAnalysisEngine.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Accelerate
import Foundation

/// A value snapshot of the recording and analysis choices for one run.
/// Sendable allows this request to cross concurrency boundaries; it does not
/// make later changes to a separate UI model part of this request.
nonisolated struct EEGAnalysisRequest: Sendable {
    var packageName: String
    var signal: MFFSignalData
    var processing: EEGAnalysisProcessingSnapshot
    var segmentLengthSeconds: Double
    var keptGrades: [ChannelHealthGrade]
    var artifactRejectionThreshold: Double
    var artifactSources: [EEGArtifactRejectionSource]
    var selectedArtifactSourceIDs: Set<String>
    var excludedChannelIndices: Set<Int>
    var segmentGoodnessBase: SegmentHealthMetricSettings = .defaults
    var frequencyBands: [EEGFrequencyBand]
    var connectivityBand: EEGFrequencyBand
    var connectivityMetrics: [EEGConnectivityMetric]
    var channelSets: [ChannelSet]
    var includesChannelConnectivity: Bool
    var includesRegionConnectivity: Bool
}

/// Computes a report from temporary segments without changing recording samples.
/// The pipeline is segment quality → retained data → spectral power/connectivity
/// → exportable summaries. Channel and sample indices are zero-based internally.
nonisolated enum EEGAnalysisEngine {
    /// Builds the complete report from the request: assess segments, select usable
    /// data, and compute the requested power and connectivity summaries. Progress
    /// is a fraction of the whole run; each stage maps its own fraction into a slice.
    /// Cancellation can leave optional analyses absent; this API returns a report
    /// rather than throwing a cancellation error. The caller owns UI publication.
    static func analyze(
        request: EEGAnalysisRequest,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> EEGAnalysisResult {
        let signal = request.signal
        let segments = temporarySegments(
            for: signal,
            lengthSeconds: request.segmentLengthSeconds
        )
        // Assessed means a source was actually included in this run. With no
        // source selected — none offered, or all unticked — nothing has looked
        // at artifacts, and the segment score says so rather than scoring the
        // absence as clean (ROADMAP RW-1 item 16).
        let selectedSources = request.artifactSources.filter {
            request.selectedArtifactSourceIDs.contains($0.id)
        }
        let artifacts: SegmentHealthArtifactAssessment = selectedSources.isEmpty
            ? .notAssessed
            : .assessed(artifactIntervals(
                for: request.artifactSources,
                selectedSourceIDs: request.selectedArtifactSourceIDs,
                signal: signal
            ))
        progress?(0.04)

        let health = SegmentHealthAnalyzer.analyze(
            signal: signal,
            segments: segments,
            excludedChannelIndices: request.excludedChannelIndices,
            artifacts: artifacts,
            base: request.segmentGoodnessBase,
            progress: { fraction in
                progress?(0.04 + 0.24 * fraction)
            }
        )
        let decisions = segmentDecisions(
            healthResults: health.results,
            featuresBySegmentID: health.featuresBySegmentID,
            keptGrades: request.keptGrades,
            artifactThreshold: request.artifactRejectionThreshold
        )
        // Key paths (\.property) are shorthand for reading a property in each item.
        // A Set makes membership checks independent of the order of health results.
        let keptSegmentIDs = Set(decisions.filter(\.isIncluded).map(\.segmentID))
        let keptSegments = segments.filter { keptSegmentIDs.contains($0.segmentID) }
        let includedChannels = includedChannelIndices(
            in: signal,
            excluding: request.excludedChannelIndices
        )
        progress?(0.32)

        let spectral = await spectralAnalysis(
            signal: signal,
            segments: keptSegments,
            channelIndices: includedChannels,
            bands: request.frequencyBands,
            progress: { fraction in
                progress?(0.32 + 0.32 * fraction)
            }
        )
        progress?(0.66)

        let connectivity = await connectivityAnalysis(
            signal: signal,
            segments: keptSegments,
            channelIndices: includedChannels,
            channelSets: request.channelSets,
            band: request.connectivityBand,
            metrics: request.connectivityMetrics,
            includesChannelConnectivity: request.includesChannelConnectivity,
            includesRegionConnectivity: request.includesRegionConnectivity,
            progress: { fraction in
                progress?(0.66 + 0.30 * fraction)
            }
        )
        progress?(0.98)

        let summary = segmentSummary(decisions: decisions)
        let configuration = EEGAnalysisConfiguration(
            segmentLengthSeconds: request.segmentLengthSeconds,
            keptSegmentGrades: request.keptGrades,
            artifactRejectionThreshold: request.artifactRejectionThreshold,
            selectedArtifactSourceNames: request.artifactSources
                .filter { request.selectedArtifactSourceIDs.contains($0.id) }
                .map(\.name)
                .sorted(),
            frequencyBands: request.frequencyBands,
            connectivityBand: request.connectivityBand,
            connectivityMetrics: request.connectivityMetrics,
            includesChannelConnectivity: request.includesChannelConnectivity,
            includesRegionConnectivity: request.includesRegionConnectivity
        )

        progress?(1)
        return EEGAnalysisResult(
            schemaVersion: 1,
            createdAt: Date(),
            recording: EEGAnalysisRecordingSummary(
                packageName: request.packageName,
                signalType: signal.signalType,
                samplingRate: signal.samplingRate,
                durationSeconds: signal.duration,
                channelCount: signal.numberOfChannels,
                analyzedChannelCount: includedChannels.count
            ),
            processing: request.processing,
            configuration: configuration,
            segments: summary,
            segmentDecisions: decisions,
            spectral: spectral,
            connectivity: connectivity
        )
    }

    /// Returns an export-sized copy, omitting detail arrays the user did not request.
    /// Summary values and configuration remain intact; analysis is not recomputed.
    /// Optional.map transforms an existing result while preserving nil when absent.
    static func exportResult(
        _ result: EEGAnalysisResult,
        options: EEGAnalysisExportOptions
    ) -> EEGAnalysisResult {
        EEGAnalysisResult(
            schemaVersion: result.schemaVersion,
            createdAt: result.createdAt,
            recording: result.recording,
            processing: result.processing,
            configuration: result.configuration,
            segments: result.segments,
            segmentDecisions: options.includesSegmentDetails ? result.segmentDecisions : [],
            spectral: result.spectral.map { spectral in
                EEGSpectralAnalysisResult(
                    segmentCount: spectral.segmentCount,
                    durationSeconds: spectral.durationSeconds,
                    channelCount: spectral.channelCount,
                    fftBinHz: spectral.fftBinHz,
                    bands: spectral.bands,
                    channels: options.includesPerChannelDetails ? spectral.channels : []
                )
            },
            connectivity: result.connectivity.map { connectivity in
                EEGConnectivityAnalysisResult(
                    band: connectivity.band,
                    metrics: connectivity.metrics,
                    channelPairs: options.includesConnectivityPairs ? connectivity.channelPairs : [],
                    regionPairs: options.includesConnectivityPairs ? connectivity.regionPairs : []
                )
            }
        )
    }

    /// Builds a rectangular table of text cells, including its header row.
    /// This does not quote CSV text or write a file; the export layer does that.
    /// Channel numbers in the table are one-based display labels, unlike array indices.
    static func csvRows(
        for result: EEGAnalysisResult,
        options: EEGAnalysisExportOptions
    ) -> [[String]] {
        var rows: [[String]] = [[
            "row_type",
            "scope",
            "channel_index",
            "channel_name",
            "node_a",
            "node_b",
            "band",
            "metric",
            "value"
        ]]

        /// Appends one recording-level key/value row using the shared nine-column schema.
        /// This nested function captures and mutates the enclosing rows array.
        func appendSummary(_ metric: String, _ value: CustomStringConvertible) {
            rows.append(["summary", "recording", "", "", "", "", "", metric, "\(value)"])
        }

        appendSummary("package_name", result.recording.packageName)
        appendSummary("signal_type", result.recording.signalType)
        appendSummary("sampling_rate_hz", clean(result.recording.samplingRate))
        appendSummary("duration_seconds", clean(result.recording.durationSeconds))
        appendSummary("channel_count", result.recording.channelCount)
        appendSummary("analyzed_channel_count", result.recording.analyzedChannelCount)
        appendSummary("segment_length_seconds", clean(result.configuration.segmentLengthSeconds))
        appendSummary("total_segments", result.segments.totalSegmentCount)
        appendSummary("included_segments", result.segments.includedSegmentCount)
        appendSummary("included_duration_seconds", clean(result.segments.includedDurationSeconds))

        if let spectral = result.spectral {
            for band in spectral.bands {
                rows.append(["spectral", "recording", "", "", "", "", band.bandName, "mean_absolute_power", "\(clean(band.meanAbsolutePower))"])
                rows.append(["spectral", "recording", "", "", "", "", band.bandName, "mean_relative_power", "\(clean(band.meanRelativePower))"])
            }

            if options.includesPerChannelDetails {
                for channel in spectral.channels {
                    for band in channel.bandValues {
                        rows.append([
                            "spectral",
                            "channel",
                            "\(channel.channelIndex + 1)",
                            channel.channelName,
                            "",
                            "",
                            band.bandName,
                            "absolute_power",
                            "\(clean(band.absolutePower))"
                        ])
                        rows.append([
                            "spectral",
                            "channel",
                            "\(channel.channelIndex + 1)",
                            channel.channelName,
                            "",
                            "",
                            band.bandName,
                            "relative_power",
                            "\(clean(band.relativePower))"
                        ])
                    }
                }
            }
        }

        if options.includesConnectivityPairs, let connectivity = result.connectivity {
            for pair in connectivity.regionPairs + connectivity.channelPairs {
                for metric in pair.metricValues {
                    rows.append([
                        "connectivity",
                        pair.scope.rawValue,
                        "",
                        "",
                        pair.nodeA.name,
                        pair.nodeB.name,
                        connectivity.band.name,
                        metric.metric.shortName,
                        "\(clean(metric.value))"
                    ])
                }
            }
        }

        return rows
    }

    // MARK: - Segments

    /// Partitions the recording into adjacent, nonoverlapping analysis windows.
    /// Seconds are rounded to samples, with at least one sample per window. End
    /// indices are inclusive, and the last window may be shorter. Invalid input
    /// with no samples or a nonpositive sample rate produces no segments.
    private static func temporarySegments(
        for signal: MFFSignalData,
        lengthSeconds: Double
    ) -> [SegmentHealthInputSegment] {
        guard let sampleCount = signal.data.first?.count,
              sampleCount > 0,
              signal.samplingRate > 0 else {
            return []
        }

        let windowSamples = max(Int((lengthSeconds * signal.samplingRate).rounded()), 1)
        var segments: [SegmentHealthInputSegment] = []
        var index = 0
        for start in stride(from: 0, to: sampleCount, by: windowSamples) {
            let end = min(start + windowSamples - 1, sampleCount - 1)
            segments.append(
                SegmentHealthInputSegment(
                    segmentID: "eeg-analysis-\(index)-\(start)-\(end)",
                    segmentIndex: index,
                    category: "Resting",
                    startSample: start,
                    endSample: end,
                    stimulusOffsetSamples: nil,
                    sourceCode: nil,
                    sourceTimeSeconds: nil,
                    contributingEpochCount: 1
                )
            )
            index += 1
        }
        return segments
    }

    /// Joins health results to artifact features by stable segment ID. A segment
    /// is retained only if its grade is allowed and measured overlap is within the
    /// threshold. Missing artifact assessment is recorded as nil, not measured zero.
    private static func segmentDecisions(
        healthResults: [SegmentHealthResult],
        featuresBySegmentID: [String: SegmentHealthFeatures],
        keptGrades: [ChannelHealthGrade],
        artifactThreshold: Double
    ) -> [EEGAnalysisSegmentDecision] {
        healthResults.map { result in
            // `nil` overlap means artifacts were not assessed. A segment cannot
            // be rejected for exceeding a threshold nobody measured, so the
            // artifact test passes — but the decision records the absence
            // rather than reporting 0% overlap, which would read as measured.
            let artifactOverlap = featuresBySegmentID[result.segmentID]?.artifactOverlapFraction
            let artifactCount = featuresBySegmentID[result.segmentID]?.artifactCount
            let healthOK = keptGrades.contains(result.grade)
            let artifactOK = (artifactOverlap ?? 0) <= artifactThreshold
            var reasons: [String] = []
            if !healthOK {
                reasons.append("health:\(result.grade.rawValue)")
            }
            if !artifactOK, let artifactOverlap {
                reasons.append(String(format: "artifact_overlap:%.1f%%", artifactOverlap * 100))
            }
            return EEGAnalysisSegmentDecision(
                segmentID: result.segmentID,
                segmentIndex: result.segmentIndex,
                startSample: result.startSample,
                endSample: result.endSample,
                startTimeSeconds: result.startTimeSeconds,
                endTimeSeconds: result.endTimeSeconds,
                durationSeconds: result.durationSeconds,
                healthGrade: result.grade,
                healthGoodPercentage: result.goodPercentage,
                artifactOverlapFraction: artifactOverlap,
                artifactCount: artifactCount,
                isIncluded: healthOK && artifactOK,
                rejectionReasons: reasons
            )
        }
    }

    /// Counts inclusion/rejection outcomes and sums durations in seconds. Health
    /// and artifact rejection counts may overlap: one segment can fail both checks.
    private static func segmentSummary(decisions: [EEGAnalysisSegmentDecision]) -> EEGAnalysisSegmentSummary {
        let included = decisions.filter(\.isIncluded)
        return EEGAnalysisSegmentSummary(
            totalSegmentCount: decisions.count,
            includedSegmentCount: included.count,
            rejectedByHealthCount: decisions.filter { $0.rejectionReasons.contains { $0.hasPrefix("health:") } }.count,
            rejectedByArtifactCount: decisions.filter { $0.rejectionReasons.contains { $0.hasPrefix("artifact_overlap:") } }.count,
            totalDurationSeconds: decisions.reduce(0) { $0 + $1.durationSeconds },
            includedDurationSeconds: included.reduce(0) { $0 + $1.durationSeconds }
        )
    }

    /// Converts selected detectors’ event-centered windows into inclusive sample
    /// intervals. Starts round down, ends round up, and both are clamped to the
    /// recording. The output is sorted by start; overlapping events remain separate.
    private static func artifactIntervals(
        for sources: [EEGArtifactRejectionSource],
        selectedSourceIDs: Set<String>,
        signal: MFFSignalData
    ) -> [SegmentHealthArtifactInterval] {
        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 0 else {
            return []
        }

        var intervals: [SegmentHealthArtifactInterval] = []
        for source in sources where selectedSourceIDs.contains(source.id) {
            let windowSeconds = max(source.windowSizeSeconds, 0.001)
            for event in source.events {
                let halfWindow = windowSeconds / 2
                // Centred on the event's own centre, which for an onset-stamped
                // source is not `beginTimeSeconds` — that put the flagged
                // interval half a window early for Topography/Continuous events.
                let startSeconds = event.centerTimeSeconds - halfWindow
                let endSeconds = event.centerTimeSeconds + halfWindow
                let start = min(max(Int((startSeconds * signal.samplingRate).rounded(.down)), 0), sampleCount - 1)
                let end = min(max(Int((endSeconds * signal.samplingRate).rounded(.up)), start), sampleCount - 1)
                intervals.append(
                    SegmentHealthArtifactInterval(
                        artifactID: "\(source.id)-\(event.id)",
                        code: event.code,
                        startSample: start,
                        endSample: end,
                        sourceFile: source.name
                    )
                )
            }
        }
        return intervals.sorted { $0.startSample < $1.startSample }
    }

    // MARK: - Spectral power

    /// Computes each retained channel’s band powers concurrently, then averages
    /// those values for the recording. Returns nil for missing inputs, cancellation
    /// or no usable spectra. Topography arrays retain the recording’s full channel
    /// index space, using zero at channels absent from this analysis.
    private static func spectralAnalysis(
        signal: MFFSignalData,
        segments: [SegmentHealthInputSegment],
        channelIndices: [Int],
        bands: [EEGFrequencyBand],
        progress: (@Sendable (Double) -> Void)?
    ) async -> EEGSpectralAnalysisResult? {
        guard !segments.isEmpty, !channelIndices.isEmpty, !bands.isEmpty else { return nil }

        let total = max(channelIndices.count, 1)
        var works = [SpectralChannelWork?](repeating: nil, count: channelIndices.count)
        let progressLock = NSLock()
        nonisolated(unsafe) var completed = 0

        works.withUnsafeMutableBufferPointer { out in
            // Each iteration writes a distinct index; bounded to evaMaxWorkers
            // so a large channel count can't spawn unbounded concurrent tasks.
            nonisolated(unsafe) let out = out
            evaConcurrentPerform(iterations: channelIndices.count) { i in
                guard !Task.isCancelled else { return }
                out[i] = spectralChannelWork(
                    signal: signal,
                    segments: segments,
                    bands: bands,
                    channelIndex: channelIndices[i]
                )
                progressLock.lock()
                completed += 1
                let done = completed
                progressLock.unlock()
                progress?(Double(done) / Double(total))
            }
        }

        if Task.isCancelled { return nil }

        var channelResults: [EEGSpectralChannelResult] = []
        channelResults.reserveCapacity(channelIndices.count)
        var binHzAccumulator = 0.0
        var binHzCount = 0
        for work in works {
            guard let work else { continue }
            channelResults.append(work.result)
            binHzAccumulator += work.binHz
            binHzCount += 1
        }

        guard !channelResults.isEmpty else { return nil }

        let summaries = bands.map { band in
            let perChannel = channelResults.map { channel in
                channel.bandValues.first { $0.bandName == band.name }?.relativePower ?? 0
            }
            let absolute = channelResults.map { channel in
                channel.bandValues.first { $0.bandName == band.name }?.absolutePower ?? 0
            }
            var topographyValues = [Double](repeating: 0, count: signal.numberOfChannels)
            for channel in channelResults {
                topographyValues[channel.channelIndex] = channel.bandValues.first { $0.bandName == band.name }?.relativePower ?? 0
            }
            return EEGSpectralRecordingBandSummary(
                bandName: band.name,
                lowHz: band.lowHz,
                highHz: band.highHz,
                meanAbsolutePower: clean(mean(absolute)),
                meanRelativePower: clean(mean(perChannel)),
                channelRelativePowers: topographyValues.map(clean)
            )
        }

        return EEGSpectralAnalysisResult(
            segmentCount: segments.count,
            durationSeconds: segments.reduce(0) { total, segment in
                total + Double(segment.endSample - segment.startSample + 1) / max(signal.samplingRate, 1)
            },
            channelCount: channelResults.count,
            fftBinHz: clean(binHzCount > 0 ? binHzAccumulator / Double(binHzCount) : 0),
            bands: summaries,
            channels: channelResults.sorted { $0.channelIndex < $1.channelIndex }
        )
    }

    private struct SpectralChannelWork: Sendable {
        var result: EEGSpectralChannelResult
        var binHz: Double
    }

    /// Builds one channel’s averaged spectrum and integrates each requested band.
    /// Relative power divides by the sum of requested band powers, not by all FFT
    /// bins; overlapping bands can count the same frequency twice in that total.
    /// Returns nil when cancelled or when no usable Fourier windows exist.
    private static func spectralChannelWork(
        signal: MFFSignalData,
        segments: [SegmentHealthInputSegment],
        bands: [EEGFrequencyBand],
        channelIndex: Int
    ) -> SpectralChannelWork? {
        if Task.isCancelled { return nil }
        guard let spectrum = averagedPowerSpectrum(
            samplesProvider: { sample in
                guard signal.data.indices.contains(channelIndex),
                      signal.data[channelIndex].indices.contains(sample) else {
                    return nil
                }
                return signal.data[channelIndex][sample]
            },
            samplingRate: signal.samplingRate,
            segments: segments
        ) else {
            return nil
        }

        let bandPowers = bands.map { band in
            bandPower(spectrum.power, binHz: spectrum.binHz, low: band.lowHz, high: band.highHz)
        }
        // The floor protects division and logarithms from zero; it is not a measured
        // noise floor and can make a zero-power result report a tiny positive total.
        let total = max(bandPowers.reduce(0, +), 1e-12)
        let values = zip(bands, bandPowers).map { band, power in
            EEGSpectralBandValue(
                bandName: band.name,
                lowHz: band.lowHz,
                highHz: band.highHz,
                absolutePower: clean(power),
                relativePower: clean(power / total),
                log10Power: clean(log10(max(power, 1e-12)))
            )
        }
        return SpectralChannelWork(
            result: EEGSpectralChannelResult(
                channelIndex: channelIndex,
                channelName: channelName(for: channelIndex, in: signal),
                totalPower: clean(total),
                bandValues: values
            ),
            binHz: spectrum.binHz
        )
    }

    // MARK: - Connectivity

    /// Creates single-channel nodes and region nodes, then computes pairs within
    /// each scope. A region’s trace is the sample-wise mean of its valid channels.
    /// No channel-to-region pairs are produced. Returns nil when the requested
    /// configuration or usable data yields no pairs.
    private static func connectivityAnalysis(
        signal: MFFSignalData,
        segments: [SegmentHealthInputSegment],
        channelIndices: [Int],
        channelSets: [ChannelSet],
        band: EEGFrequencyBand,
        metrics: [EEGConnectivityMetric],
        includesChannelConnectivity: Bool,
        includesRegionConnectivity: Bool,
        progress: (@Sendable (Double) -> Void)?
    ) async -> EEGConnectivityAnalysisResult? {
        guard !segments.isEmpty,
              !metrics.isEmpty,
              includesChannelConnectivity || includesRegionConnectivity else {
            return nil
        }

        let channelNodes = includesChannelConnectivity
            ? channelIndices.map {
                EEGConnectivityNode(
                    id: "channel-\($0)",
                    name: channelName(for: $0, in: signal),
                    scope: .channel,
                    channelIndices: [$0]
                )
            }
            : []
        let validChannelSetNodes = includesRegionConnectivity
            ? channelSets.compactMap { set -> EEGConnectivityNode? in
                let valid = set.channelIndices
                    .filter { channelIndices.contains($0) && signal.data.indices.contains($0) }
                    .sorted()
                guard !valid.isEmpty else { return nil }
                return EEGConnectivityNode(
                    id: "region-\(set.id.uuidString)",
                    name: set.name,
                    scope: .region,
                    channelIndices: valid
                )
            }
            : []

        let totalNodeCount = channelNodes.count + validChannelSetNodes.count
        guard totalNodeCount > 1 else { return nil }

        let allSpectra = await spectra(
            for: channelNodes + validChannelSetNodes,
            signal: signal,
            segments: segments,
            band: band,
            progress: { fraction in
                progress?(0.55 * fraction)
            }
        )
        let channelSpectra = allSpectra.filter { $0.node.scope == .channel }
        let regionSpectra = allSpectra.filter { $0.node.scope == .region }

        let channelPairs = includesChannelConnectivity
            ? await pairResults(from: channelSpectra, metrics: metrics, progressBase: 0.55, progressWeight: 0.25, progress: progress)
            : []
        let regionPairs = includesRegionConnectivity
            ? await pairResults(from: regionSpectra, metrics: metrics, progressBase: 0.80, progressWeight: 0.20, progress: progress)
            : []

        guard !channelPairs.isEmpty || !regionPairs.isEmpty else { return nil }
        return EEGConnectivityAnalysisResult(
            band: band,
            metrics: metrics,
            channelPairs: channelPairs,
            regionPairs: regionPairs
        )
    }

    private struct NodeSpectraWork: Sendable {
        var offset: Int
        var node: EEGConnectivityNode
        var spectra: [BandWindowSpectrum]
    }

    /// Computes band-limited complex Fourier windows for every node in parallel.
    /// Optional work slots let failed/cancelled nodes be omitted. Stored offsets
    /// restore input order regardless of the order workers finish.
    private static func spectra(
        for nodes: [EEGConnectivityNode],
        signal: MFFSignalData,
        segments: [SegmentHealthInputSegment],
        band: EEGFrequencyBand,
        progress: (@Sendable (Double) -> Void)?
    ) async -> [(node: EEGConnectivityNode, spectra: [BandWindowSpectrum])] {
        guard !nodes.isEmpty else { return [] }
        let total = max(nodes.count, 1)
        var works = [NodeSpectraWork?](repeating: nil, count: nodes.count)
        let progressLock = NSLock()
        nonisolated(unsafe) var completed = 0

        works.withUnsafeMutableBufferPointer { out in
            // Each iteration writes a distinct index; bounded to evaMaxWorkers.
            nonisolated(unsafe) let out = out
            evaConcurrentPerform(iterations: nodes.count) { offset in
                guard !Task.isCancelled else { return }
                if let nodeSpectra = bandWindowSpectra(
                    signal: signal,
                    segments: segments,
                    node: nodes[offset],
                    band: band
                ), !nodeSpectra.isEmpty {
                    out[offset] = NodeSpectraWork(offset: offset, node: nodes[offset], spectra: nodeSpectra)
                }
                progressLock.lock()
                completed += 1
                let done = completed
                progressLock.unlock()
                progress?(Double(done) / Double(total))
            }
        }

        return works
            .compactMap { $0 }
            .sorted { $0.offset < $1.offset }
            .map { (node: $0.node, spectra: $0.spectra) }
    }

    /// Evaluates each unordered pair once (A–B, never A–A or a second B–A).
    /// Workers fill separate slots; the final sort preserves predictable pair order.
    /// Progress is scaled into the caller’s stage interval. Cancelled work may leave
    /// slots empty, so callers must account for cancellation before publication.
    private static func pairResults(
        from spectra: [(node: EEGConnectivityNode, spectra: [BandWindowSpectrum])],
        metrics: [EEGConnectivityMetric],
        progressBase: Double,
        progressWeight: Double,
        progress: (@Sendable (Double) -> Void)?
    ) async -> [EEGConnectivityPairResult] {
        guard spectra.count > 1 else { return [] }
        var pairIndices: [(pairIndex: Int, left: Int, right: Int)] = []
        pairIndices.reserveCapacity(spectra.count * (spectra.count - 1) / 2)
        var pairIndex = 0
        for left in 0..<(spectra.count - 1) {
            for right in (left + 1)..<spectra.count {
                pairIndices.append((pairIndex, left, right))
                pairIndex += 1
            }
        }
        // Freeze the pair list before concurrent closures capture it. Each tuple
        // records the destination slot as well as the two source nodes.
        let finalizedPairIndices = pairIndices

        let pairCount = max(finalizedPairIndices.count, 1)
        var works = [ConnectivityPairWork?](repeating: nil, count: finalizedPairIndices.count)
        let progressLock = NSLock()
        nonisolated(unsafe) var completed = 0

        works.withUnsafeMutableBufferPointer { out in
            // Each iteration writes a distinct index; bounded to evaMaxWorkers —
            // pair count is O(n²) in node count, so this is the fan-out most
            // likely to oversubscribe the machine if left unbounded.
            nonisolated(unsafe) let out = out
            evaConcurrentPerform(iterations: finalizedPairIndices.count) { i in
                guard !Task.isCancelled else { return }
                let pair = finalizedPairIndices[i]
                let metricValues = connectivityMetrics(
                    spectraA: spectra[pair.left].spectra,
                    spectraB: spectra[pair.right].spectra,
                    metrics: metrics
                )
                if !metricValues.isEmpty {
                    out[i] = ConnectivityPairWork(
                        pairIndex: pair.pairIndex,
                        result: EEGConnectivityPairResult(
                            scope: spectra[pair.left].node.scope,
                            nodeA: spectra[pair.left].node,
                            nodeB: spectra[pair.right].node,
                            metricValues: metricValues
                        )
                    )
                }
                progressLock.lock()
                completed += 1
                let done = completed
                progressLock.unlock()
                if done % 64 == 0 || done == pairCount {
                    progress?(progressBase + progressWeight * Double(done) / Double(pairCount))
                }
            }
        }

        return works
            .compactMap { $0 }
            .sorted { $0.pairIndex < $1.pairIndex }
            .compactMap(\.result)
    }

    private struct ConnectivityPairWork: Sendable {
        var pairIndex: Int
        var result: EEGConnectivityPairResult?
    }

    /// Reduces corresponding complex windows into the requested connectivity metrics.
    /// Inputs must describe matching windows and frequency bins; unequal lengths
    /// are truncated to their common prefix, not aligned by time metadata. Small
    /// denominators are guarded, and undefined numeric outputs are converted to zero.
    private static func connectivityMetrics(
        spectraA: [BandWindowSpectrum],
        spectraB: [BandWindowSpectrum],
        metrics: [EEGConnectivityMetric]
    ) -> [EEGConnectivityMetricValue] {
        let count = min(spectraA.count, spectraB.count)
        guard count > 0 else { return [] }

        var sumPxx = 0.0
        var sumPyy = 0.0
        var crossRe = 0.0
        var crossIm = 0.0
        // PLV is accumulated per frequency bin (summed only across windows,
        // never across bins) because phase difference varies with frequency
        // for any fixed time delay; summing raw phase vectors across bins
        // before taking one magnitude would let genuine phase locking at
        // different frequencies cancel out.
        var plvBinRe: [Double] = []
        var plvBinIm: [Double] = []
        var plvBinCounts: [Int] = []
        var absImagCross = 0.0
        var ampA: [Double] = []
        var ampB: [Double] = []
        ampA.reserveCapacity(count)
        ampB.reserveCapacity(count)

        for index in 0..<count {
            let a = spectraA[index]
            let b = spectraB[index]
            let binCount = min(a.real.count, b.real.count, a.imag.count, b.imag.count)
            guard binCount > 0 else { continue }
            var windowAmpA = 0.0
            var windowAmpB = 0.0
            for bin in 0..<binCount {
                let ar = a.real[bin]
                let ai = a.imag[bin]
                let br = b.real[bin]
                let bi = b.imag[bin]
                let pxx = ar * ar + ai * ai
                let pyy = br * br + bi * bi
                // Multiply A by the complex conjugate of B. Its magnitude reflects joint
                // amplitude; its angle is their phase difference at this frequency.
                let re = ar * br + ai * bi
                let im = ai * br - ar * bi
                sumPxx += pxx
                sumPyy += pyy
                crossRe += re
                crossIm += im
                absImagCross += abs(im)
                windowAmpA += pxx
                windowAmpB += pyy
                let magnitude = sqrt(re * re + im * im)
                if magnitude > 1e-12 {
                    if plvBinRe.count <= bin {
                        plvBinRe.append(contentsOf: repeatElement(0, count: bin - plvBinRe.count + 1))
                        plvBinIm.append(contentsOf: repeatElement(0, count: bin - plvBinIm.count + 1))
                        plvBinCounts.append(contentsOf: repeatElement(0, count: bin - plvBinCounts.count + 1))
                    }
                    // Normalize to a unit vector so PLV measures phase agreement rather than
                    // signal amplitude. Repeated windows add vectors pointing in that phase.
                    plvBinRe[bin] += re / magnitude
                    plvBinIm[bin] += im / magnitude
                    plvBinCounts[bin] += 1
                }
            }
            ampA.append(sqrt(max(windowAmpA, 0)))
            ampB.append(sqrt(max(windowAmpB, 0)))
        }

        let denom = max(sqrt(sumPxx * sumPyy), 1e-12)
        var values: [EEGConnectivityMetricValue] = []
        values.reserveCapacity(metrics.count)
        for metric in metrics {
            let value: Double
            switch metric {
            case .coherence:
                value = (crossRe * crossRe + crossIm * crossIm) / max(sumPxx * sumPyy, 1e-12)
            case .imaginaryCoherence:
                value = abs(crossIm) / denom
            case .phaseLockingValue:
                var bandPLV = 0.0
                var contributingBins = 0
                for bin in plvBinRe.indices where plvBinCounts[bin] > 0 {
                    let re = plvBinRe[bin], im = plvBinIm[bin]
                    bandPLV += sqrt(re * re + im * im) / Double(plvBinCounts[bin])
                    contributingBins += 1
                }
                value = contributingBins > 0 ? bandPLV / Double(contributingBins) : 0
            // Opposite imaginary signs cancel in the numerator, while the denominator
            // keeps their absolute weights; consistent nonzero lag approaches one.
            case .weightedPhaseLagIndex:
                value = absImagCross > 1e-12 ? abs(crossIm) / absImagCross : 0
            case .amplitudeEnvelopeCorrelation:
                value = pearson(ampA, ampB) ?? 0
            }
            values.append(EEGConnectivityMetricValue(metric: metric, value: clean(value)))
        }
        return values
    }

    private struct BandWindowSpectrum: Sendable {
        var real: [Double]
        var imag: [Double]
    }

    /// Returns complex coefficients for the selected frequency band in every full
    /// window. Windows overlap by 50%, stay inside each segment, are demeaned and
    /// Hann-tapered. DC and Nyquist bins are excluded. nil means invalid setup; an
    /// empty array means setup succeeded but no complete window fit.
    private static func bandWindowSpectra(
        signal: MFFSignalData,
        segments: [SegmentHealthInputSegment],
        node: EEGConnectivityNode,
        band: EEGFrequencyBand
    ) -> [BandWindowSpectrum]? {
        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 0 else {
            return nil
        }

        let fftLength = analysisFFTLength(samplingRate: signal.samplingRate, segments: segments)
        guard fftLength >= 16,
              let dft = try? vDSP.DiscreteFourierTransform(
                previous: nil,
                count: fftLength,
                direction: .forward,
                transformType: .complexComplex,
                ofType: Float.self
              ) else {
            return nil
        }

        let binHz = signal.samplingRate / Double(fftLength)
        let lowBin = max(Int((band.lowHz / binHz).rounded(.down)), 1)
        let highBin = min(Int((band.highHz / binHz).rounded(.up)), fftLength / 2 - 1)
        guard highBin >= lowBin else { return nil }

        let window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: fftLength,
            isHalfWindow: false
        )
        let imaginaryInput = [Float](repeating: 0, count: fftLength)
        let step = max(fftLength / 2, 1)
        var output: [BandWindowSpectrum] = []

        for segment in segments {
            var start = max(segment.startSample, 0)
            let end = min(segment.endSample, sampleCount - 1)
            while start + fftLength - 1 <= end {
                var realInput = [Float](repeating: 0, count: fftLength)
                for offset in 0..<fftLength {
                    realInput[offset] = nodeValue(signal: signal, node: node, sample: start + offset)
                }
                let mean = vDSP.mean(realInput)
                realInput = vDSP.multiply(vDSP.add(-mean, realInput), window)
                let transformed = dft.transform(real: realInput, imaginary: imaginaryInput)
                output.append(
                    BandWindowSpectrum(
                        real: (lowBin...highBin).map { Double(transformed.real[$0]) },
                        imag: (lowBin...highBin).map { Double(transformed.imaginary[$0]) }
                    )
                )
                start += step
            }
        }

        return output
    }

    // MARK: - FFT helpers

    /// Averages squared Fourier magnitudes over full, half-overlapping windows.
    /// The provider returns one sample or nil; missing/nonfinite samples become zero,
    /// and windows with fewer than half their samples valid are skipped. The output
    /// is raw averaged squared magnitude, not a power spectral density normalized
    /// by sample rate or window energy. Returns nil if no usable window remains.
    private static func averagedPowerSpectrum(
        samplesProvider: (Int) -> Float?,
        samplingRate: Double,
        segments: [SegmentHealthInputSegment]
    ) -> (power: [Double], binHz: Double)? {
        guard samplingRate > 0 else { return nil }
        let fftLength = analysisFFTLength(samplingRate: samplingRate, segments: segments)
        guard fftLength >= 16,
              let dft = try? vDSP.DiscreteFourierTransform(
                previous: nil,
                count: fftLength,
                direction: .forward,
                transformType: .complexComplex,
                ofType: Float.self
              ) else {
            return nil
        }

        let window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: fftLength,
            isHalfWindow: false
        )
        let imaginaryInput = [Float](repeating: 0, count: fftLength)
        let half = fftLength / 2
        let step = max(fftLength / 2, 1)
        var averagePower = [Double](repeating: 0, count: half)
        var windowCount = 0

        for segment in segments {
            var start = max(segment.startSample, 0)
            let end = max(segment.endSample, start)
            while start + fftLength - 1 <= end {
                var realInput = [Float](repeating: 0, count: fftLength)
                var validCount = 0
                for offset in 0..<fftLength {
                    if let value = samplesProvider(start + offset), value.isFinite {
                        realInput[offset] = value
                        validCount += 1
                    }
                }
                guard validCount >= fftLength / 2 else {
                    start += step
                    continue
                }
                // Subtract the mean to reduce DC; taper the edges to reduce leakage caused
                // by treating each finite window as a periodically repeating signal.
                // The zero imaginary input embeds real EEG samples in a complex transform.
                let mean = vDSP.mean(realInput)
                realInput = vDSP.multiply(vDSP.add(-mean, realInput), window)
                let transformed = dft.transform(real: realInput, imaginary: imaginaryInput)
                for bin in 0..<half {
                    let re = Double(transformed.real[bin])
                    let im = Double(transformed.imaginary[bin])
                    averagePower[bin] += re * re + im * im
                }
                windowCount += 1
                start += step
            }
        }

        guard windowCount > 0 else { return nil }
        for bin in 0..<half {
            averagePower[bin] /= Double(windowCount)
        }
        return (averagePower, samplingRate / Double(fftLength))
    }

    /// Chooses a power-of-two transform length near two seconds, limited by the
    /// longest segment and a 4096-sample cap. The minimum is 16 even when segments
    /// are shorter; the window loops then produce no complete windows.
    private static func analysisFFTLength(
        samplingRate: Double,
        segments: [SegmentHealthInputSegment]
    ) -> Int {
        let longestSegment = segments
            .map { max($0.endSample - $0.startSample + 1, 0) }
            .max() ?? 0
        let target = min(max(Int(samplingRate * 2), 64), 4096)
        let capped = max(min(target, longestSegment), 16)
        var length = 16
        while length * 2 <= capped {
            length *= 2
        }
        return length
    }

    /// Sums positive-frequency bins spanning the requested Hz interval. Bounds
    /// round outward to include neighboring bins; DC is excluded. An empty or
    /// nonoverlapping range returns zero. This is a bin sum, not an integral times Hz.
    private static func bandPower(_ spectrum: [Double], binHz: Double, low: Double, high: Double) -> Double {
        guard binHz > 0, !spectrum.isEmpty else { return 0 }
        let lowBin = max(Int((low / binHz).rounded(.down)), 1)
        let highBin = min(Int((high / binHz).rounded(.up)), spectrum.count - 1)
        guard highBin >= lowBin else { return 0 }
        var sum = 0.0
        for bin in lowBin...highBin {
            sum += spectrum[bin]
        }
        return clean(sum)
    }

    // MARK: - Common helpers

    /// Keeps nonempty signal rows that are not explicitly excluded. This selects
    /// channels only; it does not check equal row lengths or finite sample values.
    private static func includedChannelIndices(in signal: MFFSignalData, excluding excluded: Set<Int>) -> [Int] {
        signal.data.indices
            .filter { !excluded.contains($0) && !signal.data[$0].isEmpty }
            .sorted()
    }

    /// Uses recorded channel metadata when available, otherwise a one-based Ch label.
    private static func channelName(for channelIndex: Int, in signal: MFFSignalData) -> String {
        if let names = signal.channelNames,
           names.indices.contains(channelIndex),
           !names[channelIndex].isEmpty {
            return names[channelIndex]
        }
        return "Ch \(channelIndex + 1)"
    }

    /// Averages finite, in-bounds samples across a node’s channels at one time.
    /// A channel node has one member; a region has several. If none contributes,
    /// returns zero so the Fourier input still has a value at this time point.
    private static func nodeValue(signal: MFFSignalData, node: EEGConnectivityNode, sample: Int) -> Float {
        var sum = 0.0
        var count = 0
        for channelIndex in node.channelIndices {
            guard signal.data.indices.contains(channelIndex),
                  signal.data[channelIndex].indices.contains(sample) else {
                continue
            }
            let value = Double(signal.data[channelIndex][sample])
            guard value.isFinite else { continue }
            sum += value
            count += 1
        }
        return count > 0 ? Float(sum / Double(count)) : 0
    }

    /// Returns the arithmetic mean, using zero for empty or nonfinite results.
    /// Nonfinite elements are not removed before summing.
    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return clean(values.reduce(0, +) / Double(values.count))
    }

    /// Computes Pearson correlation on the common prefix of two arrays. Subtracting
    /// each mean removes offsets; dividing by both centered vector lengths removes
    /// scale. Returns nil for fewer than two pairs or effectively constant data.
    private static func pearson(_ a: [Double], _ b: [Double]) -> Double? {
        let count = min(a.count, b.count)
        guard count > 1 else { return nil }
        let meanA = mean(Array(a.prefix(count)))
        let meanB = mean(Array(b.prefix(count)))
        var numerator = 0.0
        var sumA = 0.0
        var sumB = 0.0
        for index in 0..<count {
            let da = a[index] - meanA
            let db = b[index] - meanB
            numerator += da * db
            sumA += da * da
            sumB += db * db
        }
        let denominator = sqrt(sumA * sumB)
        guard denominator > 1e-12 else { return nil }
        return clean(numerator / denominator)
    }

    /// Replaces NaN and infinity with zero before values enter report/export models.
    private static func clean(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
