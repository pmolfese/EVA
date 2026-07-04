//
//  RecordingCombiner.swift
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
//  Engine for combining several single-subject recordings into one appended or
//  grand-averaged MFF. Produces an MFFSignalData + segments, writes them to a
//  temporary .mff via MFFWriter (so every existing view/export works), and
//  stamps the package with provenance (eva.xml + log_eva_*.txt).
//

import Foundation

/// A loaded recording ready to be combined.
nonisolated struct CombineInput: Sendable {
    let url: URL
    let signal: MFFSignalData
    let segments: [EpochSegment]
    let badChannels: Set<Int>
    let geometry: ElectrodeGeometry?
}

nonisolated enum RecordingCombiner {
    struct Result: Sendable {
        let signal: MFFSignalData
        let segments: [EpochSegment]
        let kind: MFFExportKind
        let provenance: CombineProvenance
        /// Per-file, per-primary noise curve for the butterfly band, keyed by
        /// category, from the grand average.
        let noiseCurvesByCategory: [String: [Float]]
    }

    // MARK: - Summaries & compatibility

    /// Builds a sanity-table row (categories, trial counts, per-file SNR).
    static func summarize(_ input: CombineInput) -> RecordingSummary {
        let signal = input.signal
        let byCategory = Dictionary(grouping: input.segments, by: \.category)
        let baseline = input.segments.map(\.stimulusOffsetSamples).min() ?? 0

        // Rejection detail comes only from eva.xml (an `average` step). A plain
        // MFF records just the survivors.
        let script = EVAProcessingScriptXML.read(fromPackage: input.url)
        let hasProcessingRecord = script != nil
        let rejectionByCategory: [String: CategoryRejection] = {
            guard let step = script?.steps.last(where: { $0.operation == .average && !$0.rejections.isEmpty }) else {
                return [:]
            }
            return Dictionary(uniqueKeysWithValues: step.rejections.map { ($0.category, $0) })
        }()

        var categories: [CategorySummary] = []
        for (name, segs) in byCategory.sorted(by: { $0.key < $1.key }) {
            let included = signal.isAveraged
                ? segs.reduce(0) { $0 + $1.contributingEpochCount }
                : segs.count
            if let rejection = rejectionByCategory[name] {
                categories.append(CategorySummary(
                    name: name,
                    totalTrials: rejection.total,
                    goodTrials: rejection.included,
                    exclusionReasons: rejection.reasons
                ))
            } else {
                categories.append(CategorySummary(name: name, totalTrials: included, goodTrials: included))
            }
        }

        let epochLen = input.segments.map { $0.endSample - $0.startSample + 1 }.min() ?? 0
        let snr = pooledSNR(input: input, baselineSampleCount: baseline)

        return RecordingSummary(
            url: input.url,
            fileName: input.url.lastPathComponent,
            netName: signal.channelNames?.count == signal.numberOfChannels ? "" : "",
            channelCount: signal.numberOfChannels,
            samplingRate: signal.samplingRate,
            epochLengthSamples: epochLen,
            isAveraged: signal.isAveraged,
            categories: categories,
            hasProcessingRecord: hasProcessingRecord,
            snr: snr
        )
    }

    /// Per-file SNR from pooling every category's single trials (noise is
    /// stimulus-independent). Averaged files fall back to count/baseline metrics.
    private static func pooledSNR(input: CombineInput, baselineSampleCount: Int) -> SNRMetrics {
        if input.signal.isAveraged {
            // Use the largest category's averaged waveform.
            let byCategory = Dictionary(grouping: input.segments, by: \.category)
            guard let (_, segs) = byCategory.max(by: { $0.value.count < $1.value.count }),
                  let seg = segs.first,
                  let avg = slice(signal: input.signal, segment: seg) else {
                return SNRMetrics()
            }
            let n = segs.reduce(0) { $0 + $1.contributingEpochCount }
            return EpochSNR.metricsForAveraged(average: avg, trialCount: n, baselineSampleCount: baselineSampleCount)
        }

        // Pool all trials cropped to a common stimulus-locked window.
        guard let pooled = pooledTrials(input: input) else { return SNRMetrics() }
        return EpochSNR.metrics(trials: pooled.trials, baselineSampleCount: pooled.baseline)
    }

    private static func pooledTrials(input: CombineInput) -> (trials: [[[Float]]], baseline: Int)? {
        let segs = input.segments
        guard !segs.isEmpty else { return nil }
        let pre = segs.map(\.stimulusOffsetSamples).min() ?? 0
        let post = segs.map { ($0.endSample - $0.startSample) - $0.stimulusOffsetSamples }.min() ?? 0
        guard pre + post > 1 else { return nil }
        var trials: [[[Float]]] = []
        for seg in segs {
            let stim = seg.startSample + seg.stimulusOffsetSamples
            let lo = stim - pre, hi = stim + post
            guard lo >= 0, hi < (input.signal.data.first?.count ?? 0) else { continue }
            let trial = input.signal.data.map { Array($0[lo...hi]) }
            trials.append(trial)
        }
        return trials.isEmpty ? nil : (trials, pre)
    }

    /// Compatibility of `summary` against the reference file.
    static func compatibility(of summary: RecordingSummary, reference: RecordingSummary) -> [CompatibilityFlag] {
        var flags: [CompatibilityFlag] = []
        if summary.epochLengthSamples == 0 { flags.append(.notSegmented) }
        if summary.channelCount != reference.channelCount {
            flags.append(.channelCountMismatch(summary.channelCount, expected: reference.channelCount))
        }
        if abs(summary.samplingRate - reference.samplingRate) > 0.5 {
            flags.append(.samplingRateMismatch(summary.samplingRate, expected: reference.samplingRate))
        }
        return flags
    }

    // MARK: - Append

    static func append(
        _ inputs: [CombineInput],
        log: EVAProcessLog
    ) -> (signal: MFFSignalData, segments: [EpochSegment]) {
        precondition(!inputs.isEmpty)
        let channelCount = inputs[0].signal.numberOfChannels
        var combined = [[Float]](repeating: [], count: channelCount)
        var segments: [EpochSegment] = []
        var sampleOffset = 0

        for input in inputs {
            let len = input.signal.data.first?.count ?? 0
            for c in 0..<channelCount where c < input.signal.data.count {
                combined[c].append(contentsOf: input.signal.data[c])
            }
            for seg in input.segments {
                segments.append(EpochSegment(
                    startSample: seg.startSample + sampleOffset,
                    endSample: seg.endSample + sampleOffset,
                    stimulusOffsetSamples: seg.stimulusOffsetSamples,
                    category: seg.category,
                    sourceCode: seg.sourceCode,
                    sourceTimeSeconds: Double(seg.startSample + sampleOffset + seg.stimulusOffsetSamples) / input.signal.samplingRate,
                    colorIndex: seg.colorIndex,
                    contributingEpochCount: seg.contributingEpochCount
                ))
            }
            sampleOffset += len
            log.append("Appended \(input.url.lastPathComponent): \(input.segments.count) segments, \(len) samples")
        }

        let base = inputs[0].signal
        let signal = base.replacingData(combined, signalTypeSuffix: "combined-append")
        return (signal, segments)
    }

    // MARK: - Grand average

    struct GrandAverageOutput: Sendable {
        let signal: MFFSignalData
        let segments: [EpochSegment]
        let noiseByCategory: [String: [Float]]
        /// Normalized (sum = 1) weight actually applied to each file.
        let weightByFile: [URL: Double]
    }

    static func grandAverage(
        _ inputs: [CombineInput],
        categoryMap: [URL: [String: String]],   // per-file: rawName → canonicalName
        weighting: WeightingMode,
        badChannelPolicy: BadChannelPolicy,
        rebaseline: Bool,
        log: EVAProcessLog
    ) -> GrandAverageOutput? {
        precondition(!inputs.isEmpty)
        let channelCount = inputs[0].signal.numberOfChannels

        // Gather each file's per-canonical-category average, stimulus-aligned.
        struct FileAverage { let url: URL; let waveform: [[Float]]; let pre: Int; let post: Int; let trials: Int; let weight: Double; let bad: Set<Int> }
        var byCategory: [String: [FileAverage]] = [:]
        var rawWeightByFile: [URL: Double] = [:]

        for input in inputs {
            let map = categoryMap[input.url] ?? [:]
            let grouped = Dictionary(grouping: input.segments, by: { map[$0.category] ?? $0.category })
            for (canonical, segs) in grouped {
                guard let avg = fileCategoryAverage(input: input, segments: segs, rebaseline: rebaseline) else { continue }
                let weight: Double
                switch weighting {
                case .equalPerFile:      weight = 1
                case .byTrialCount:      weight = Double(avg.trials)
                case .byInverseVariance:
                    let snr = EpochSNR.metrics(
                        trials: avg.singleTrials,
                        baselineSampleCount: avg.pre
                    )
                    weight = snr.inverseVarianceWeight
                }
                rawWeightByFile[input.url, default: 0] += weight
                byCategory[canonical, default: []].append(
                    FileAverage(url: input.url, waveform: avg.waveform, pre: avg.pre, post: avg.post,
                                trials: avg.trials, weight: weight, bad: input.badChannels)
                )
            }
        }

        guard !byCategory.isEmpty else { return nil }

        // Combine each category to a common stimulus-locked window.
        var outSegments: [EpochSegment] = []
        var outData = [[Float]](repeating: [], count: channelCount)
        var noiseByCategory: [String: [Float]] = [:]
        let colorIndices = Self.colorIndices(for: byCategory.keys.sorted())
        var cursor = 0

        for canonical in byCategory.keys.sorted() {
            let files = byCategory[canonical]!
            let pre = files.map(\.pre).min() ?? 0
            let post = files.map(\.post).min() ?? 0
            let window = pre + post + 1
            guard window > 1 else { continue }

            var summed = [[Float]](repeating: [Float](repeating: 0, count: window), count: channelCount)
            var weightPerChannel = [Double](repeating: 0, count: channelCount)
            // Plus-minus residual across files (each file-average is a unit) → noise band.
            var residual = [[Float]](repeating: [Float](repeating: 0, count: window), count: channelCount)
            var residualWeight = [Double](repeating: 0, count: channelCount)

            for (fileIndex, file) in files.enumerated() {
                let stim = file.pre
                let sign: Float = (fileIndex % 2 == 0) ? 1 : -1
                for c in 0..<channelCount {
                    let contributes = badChannelPolicy == .interpolatePerFile || !file.bad.contains(c)
                    guard contributes, c < file.waveform.count else { continue }
                    let ch = file.waveform[c]
                    for k in 0..<window {
                        let idx = stim - pre + k
                        guard idx >= 0, idx < ch.count else { continue }
                        summed[c][k] += Float(file.weight) * ch[idx]
                        residual[c][k] += sign * Float(file.weight) * ch[idx]
                    }
                    weightPerChannel[c] += file.weight
                    residualWeight[c] += file.weight
                }
            }
            for c in 0..<channelCount {
                let w = weightPerChannel[c]
                if w > 0 { for k in 0..<window { summed[c][k] /= Float(w) } }
                let rw = residualWeight[c]
                if rw > 0 { for k in 0..<window { residual[c][k] /= Float(rw) } }
            }

            // Per-sample noise curve = RMS across channels of the ± residual.
            if files.count >= 2 {
                var noise = [Float](repeating: 0, count: window)
                for k in 0..<window {
                    var sum: Float = 0
                    for c in 0..<channelCount { sum += residual[c][k] * residual[c][k] }
                    noise[k] = (sum / Float(channelCount)).squareRoot()
                }
                noiseByCategory[canonical] = noise
            }

            let startSample = cursor
            let endSample = cursor + window - 1
            for c in 0..<channelCount { outData[c].append(contentsOf: summed[c]) }
            let totalTrials = files.reduce(0) { $0 + $1.trials }
            outSegments.append(EpochSegment(
                startSample: startSample,
                endSample: endSample,
                stimulusOffsetSamples: pre,
                category: canonical,
                sourceCode: canonical,
                sourceTimeSeconds: Double(startSample + pre) / inputs[0].signal.samplingRate,
                colorIndex: colorIndices[canonical] ?? 0,
                contributingEpochCount: totalTrials
            ))
            cursor += window
            log.append("Grand-averaged “\(canonical)”: \(files.count) files, \(totalTrials) trials, window \(window) samples\(rebaseline ? ", re-baselined" : "")")
        }

        // Normalize per-file weights to sum = 1 for provenance.
        let totalWeight = rawWeightByFile.values.reduce(0, +)
        var weightByFile: [URL: Double] = [:]
        if totalWeight > 0 { for (url, w) in rawWeightByFile { weightByFile[url] = w / totalWeight } }

        let base = inputs[0].signal
        let signal = base.replacingData(outData, signalTypeSuffix: "grand-average")
        return GrandAverageOutput(signal: signal, segments: outSegments,
                                  noiseByCategory: noiseByCategory, weightByFile: weightByFile)
    }

    /// A file's average for one canonical category, plus its single trials (for
    /// inverse-variance weighting), stimulus-aligned. When `rebaseline`, each
    /// epoch is baseline-corrected (per-channel mean over the pre-stimulus
    /// window subtracted) before averaging.
    private static func fileCategoryAverage(
        input: CombineInput,
        segments: [EpochSegment],
        rebaseline: Bool
    ) -> (waveform: [[Float]], singleTrials: [[[Float]]], pre: Int, post: Int, trials: Int)? {
        guard !segments.isEmpty else { return nil }

        if input.signal.isAveraged, segments.count == 1, let seg = segments.first,
           var wave = slice(signal: input.signal, segment: seg) {
            let pre = seg.stimulusOffsetSamples
            let post = (seg.endSample - seg.startSample) - pre
            if rebaseline, pre > 0 { baselineCorrect(&wave, baselineSampleCount: pre) }
            return (wave, [], pre, post, seg.contributingEpochCount)
        }

        // Average the file's single trials, stimulus-aligned.
        let pre = segments.map(\.stimulusOffsetSamples).min() ?? 0
        let post = segments.map { ($0.endSample - $0.startSample) - $0.stimulusOffsetSamples }.min() ?? 0
        let window = pre + post + 1
        guard window > 1 else { return nil }
        let channelCount = input.signal.numberOfChannels
        var trials: [[[Float]]] = []
        for seg in segments {
            let stim = seg.startSample + seg.stimulusOffsetSamples
            let lo = stim - pre, hi = stim + post
            guard lo >= 0, hi < (input.signal.data.first?.count ?? 0) else { continue }
            var trial = input.signal.data.map { Array($0[lo...hi]) }
            if rebaseline, pre > 0 { baselineCorrect(&trial, baselineSampleCount: pre) }
            trials.append(trial)
        }
        guard !trials.isEmpty else { return nil }
        let avg = EpochSNR.averageTrials(trials, channels: channelCount, samples: window)
        return (avg, trials, pre, post, trials.count)
    }

    /// Subtracts each channel's mean over the leading `baselineSampleCount`
    /// samples (the pre-stimulus window) from the whole epoch, in place.
    private static func baselineCorrect(_ epoch: inout [[Float]], baselineSampleCount: Int) {
        for c in epoch.indices {
            let n = min(baselineSampleCount, epoch[c].count)
            guard n > 0 else { continue }
            var sum: Float = 0
            for s in 0..<n { sum += epoch[c][s] }
            let mean = sum / Float(n)
            for s in epoch[c].indices { epoch[c][s] -= mean }
        }
    }

    private static func slice(signal: MFFSignalData, segment: EpochSegment) -> [[Float]]? {
        let lo = segment.startSample, hi = segment.endSample
        guard lo >= 0, hi < (signal.data.first?.count ?? 0), hi >= lo else { return nil }
        return signal.data.map { Array($0[lo...hi]) }
    }

    private static func colorIndices(for categories: [String]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (i, name) in categories.enumerated() { out[name] = i }
        return out
    }

    // MARK: - Temp package output

    /// Writes a combined result to a temporary .mff and stamps eva.xml + log,
    /// plus the per-category noise band as `eva_noise.json` (see `NoiseSidecar`).
    static func writeTempPackage(
        signal: MFFSignalData,
        segments: [EpochSegment],
        kind: MFFExportKind,
        script: EVAProcessingScript,
        log: EVAProcessLog,
        noiseByCategory: [String: [Float]] = [:],
        baseName: String
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EVA-Combined-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let packageURL = dir.appendingPathComponent("\(baseName).mff")

        try MFFWriter.write(
            signal: signal,
            pnsSignal: nil,          // PNS is dropped for combining/averaging.
            segments: segments,
            kind: kind,
            to: packageURL
        )
        try? EVAProcessingScriptXML.write(script, toPackage: packageURL)
        try? log.write(toPackage: packageURL)
        if !noiseByCategory.isEmpty {
            try? NoiseSidecar.write(noiseByCategory, toPackage: packageURL)
        }
        return packageURL
    }
}

/// Per-category grand-average noise band (RMS-across-channels of the ±
/// residual), persisted alongside a combined package so the butterfly plot can
/// shade it after the signal round-trips through MFF (which drops single trials).
nonisolated enum NoiseSidecar {
    static let fileName = "eva_noise.json"

    static func write(_ noiseByCategory: [String: [Float]], toPackage packageURL: URL) throws {
        let data = try JSONEncoder().encode(noiseByCategory)
        try data.write(to: packageURL.appendingPathComponent(fileName), options: .atomic)
    }

    static func read(fromPackageContaining signalURL: URL) -> [String: [Float]]? {
        let url = signalURL.deletingLastPathComponent().appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: [Float]].self, from: data)
    }
}
