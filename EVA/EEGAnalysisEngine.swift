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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//

import Accelerate
import Foundation

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
    var frequencyBands: [EEGFrequencyBand]
    var connectivityBand: EEGFrequencyBand
    var connectivityMetrics: [EEGConnectivityMetric]
    var channelSets: [ChannelSet]
    var includesChannelConnectivity: Bool
    var includesRegionConnectivity: Bool
}

nonisolated enum EEGAnalysisEngine {
    static func analyze(
        request: EEGAnalysisRequest,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> EEGAnalysisResult {
        let signal = request.signal
        let segments = temporarySegments(
            for: signal,
            lengthSeconds: request.segmentLengthSeconds
        )
        let artifactIntervals = artifactIntervals(
            for: request.artifactSources,
            selectedSourceIDs: request.selectedArtifactSourceIDs,
            signal: signal
        )
        progress?(0.04)

        let health = SegmentHealthAnalyzer.analyze(
            signal: signal,
            segments: segments,
            excludedChannelIndices: request.excludedChannelIndices,
            artifactIntervals: artifactIntervals,
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

    private static func segmentDecisions(
        healthResults: [SegmentHealthResult],
        featuresBySegmentID: [String: SegmentHealthFeatures],
        keptGrades: [ChannelHealthGrade],
        artifactThreshold: Double
    ) -> [EEGAnalysisSegmentDecision] {
        healthResults.map { result in
            let artifactOverlap = featuresBySegmentID[result.segmentID]?.artifactOverlapFraction ?? 0
            let artifactCount = featuresBySegmentID[result.segmentID]?.artifactCount ?? 0
            let healthOK = keptGrades.contains(result.grade)
            let artifactOK = artifactOverlap <= artifactThreshold
            var reasons: [String] = []
            if !healthOK {
                reasons.append("health:\(result.grade.rawValue)")
            }
            if !artifactOK {
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
                let startSeconds = event.beginTimeSeconds - halfWindow
                let endSeconds = event.beginTimeSeconds + halfWindow
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

    private static func spectralAnalysis(
        signal: MFFSignalData,
        segments: [SegmentHealthInputSegment],
        channelIndices: [Int],
        bands: [EEGFrequencyBand],
        progress: (@Sendable (Double) -> Void)?
    ) async -> EEGSpectralAnalysisResult? {
        guard !segments.isEmpty, !channelIndices.isEmpty, !bands.isEmpty else { return nil }

        var channelResults: [EEGSpectralChannelResult] = []
        channelResults.reserveCapacity(channelIndices.count)
        var binHzAccumulator = 0.0
        var binHzCount = 0

        await withTaskGroup(of: SpectralChannelWork?.self) { group in
            for channelIndex in channelIndices {
                group.addTask {
                    spectralChannelWork(
                        signal: signal,
                        segments: segments,
                        bands: bands,
                        channelIndex: channelIndex
                    )
                }
            }

            let total = max(channelIndices.count, 1)
            var completed = 0
            for await work in group {
                completed += 1
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if let work {
                    channelResults.append(work.result)
                    binHzAccumulator += work.binHz
                    binHzCount += 1
                }
                progress?(Double(completed) / Double(total))
            }
        }

        if Task.isCancelled { return nil }
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

    private static func spectra(
        for nodes: [EEGConnectivityNode],
        signal: MFFSignalData,
        segments: [SegmentHealthInputSegment],
        band: EEGFrequencyBand,
        progress: (@Sendable (Double) -> Void)?
    ) async -> [(node: EEGConnectivityNode, spectra: [BandWindowSpectrum])] {
        guard !nodes.isEmpty else { return [] }
        var output: [NodeSpectraWork] = []
        output.reserveCapacity(nodes.count)

        await withTaskGroup(of: NodeSpectraWork?.self) { group in
            for (offset, node) in nodes.enumerated() {
                group.addTask {
                    if Task.isCancelled { return nil }
                    guard let nodeSpectra = bandWindowSpectra(
                        signal: signal,
                        segments: segments,
                        node: node,
                        band: band
                    ), !nodeSpectra.isEmpty else {
                        return nil
                    }
                    return NodeSpectraWork(offset: offset, node: node, spectra: nodeSpectra)
                }
            }

            let total = max(nodes.count, 1)
            var completed = 0
            for await work in group {
                completed += 1
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if let work {
                    output.append(work)
                }
                progress?(Double(completed) / Double(total))
            }
        }

        return output
            .sorted { $0.offset < $1.offset }
            .map { (node: $0.node, spectra: $0.spectra) }
    }

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

        let pairCount = max(pairIndices.count, 1)
        var results: [ConnectivityPairWork] = []
        results.reserveCapacity(pairCount)

        await withTaskGroup(of: ConnectivityPairWork?.self) { group in
            for pair in pairIndices {
                group.addTask {
                    if Task.isCancelled { return nil }
                    let metricValues = connectivityMetrics(
                        spectraA: spectra[pair.left].spectra,
                        spectraB: spectra[pair.right].spectra,
                        metrics: metrics
                    )
                    guard !metricValues.isEmpty else {
                        return ConnectivityPairWork(pairIndex: pair.pairIndex, result: nil)
                    }
                    return ConnectivityPairWork(
                        pairIndex: pair.pairIndex,
                        result: EEGConnectivityPairResult(
                            scope: spectra[pair.left].node.scope,
                            nodeA: spectra[pair.left].node,
                            nodeB: spectra[pair.right].node,
                            metricValues: metricValues
                        )
                    )
                }
            }

            var completed = 0
            for await work in group {
                completed += 1
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if let work, work.result != nil {
                    results.append(work)
                }
                if completed % 64 == 0 || completed == pairCount {
                    progress?(progressBase + progressWeight * Double(completed) / Double(pairCount))
                }
            }
        }

        return results
            .sorted { $0.pairIndex < $1.pairIndex }
            .compactMap(\.result)
    }

    private struct ConnectivityPairWork: Sendable {
        var pairIndex: Int
        var result: EEGConnectivityPairResult?
    }

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
        var plvRe = 0.0
        var plvIm = 0.0
        var plvCount = 0
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
                    plvRe += re / magnitude
                    plvIm += im / magnitude
                    plvCount += 1
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
                value = plvCount > 0
                    ? sqrt(plvRe * plvRe + plvIm * plvIm) / Double(plvCount)
                    : 0
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

    private static func includedChannelIndices(in signal: MFFSignalData, excluding excluded: Set<Int>) -> [Int] {
        signal.data.indices
            .filter { !excluded.contains($0) && !signal.data[$0].isEmpty }
            .sorted()
    }

    private static func channelName(for channelIndex: Int, in signal: MFFSignalData) -> String {
        if let names = signal.channelNames,
           names.indices.contains(channelIndex),
           !names[channelIndex].isEmpty {
            return names[channelIndex]
        }
        return "Ch \(channelIndex + 1)"
    }

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

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return clean(values.reduce(0, +) / Double(values.count))
    }

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

    private static func clean(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
