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
    let alreadyInterpolatedChannels: Set<Int>
    let geometry: ElectrodeGeometry?

    init(
        url: URL,
        signal: MFFSignalData,
        segments: [EpochSegment],
        badChannels: Set<Int>,
        alreadyInterpolatedChannels: Set<Int> = [],
        geometry: ElectrodeGeometry?
    ) {
        self.url = url
        self.signal = signal
        self.segments = segments
        self.badChannels = badChannels
        self.alreadyInterpolatedChannels = alreadyInterpolatedChannels
        self.geometry = geometry
    }
}

nonisolated struct RestoredBadChannelState: Sendable, Equatable {
    let bad: Set<Int>
    let alreadyInterpolated: Set<Int>
}

nonisolated enum CombineError: LocalizedError, Equatable {
    case noInputs
    case noUsableCategories
    case channelMapping(url: URL, failure: ChannelMappingFailure)
    case samplingRateMismatch(url: URL, actual: Double, expected: Double)
    case epochLengthMismatch(url: URL, actual: Int, expected: Int)
    case malformedSignal(url: URL, reason: String)
    case interpolationUnavailable(url: URL, reason: InterpolationFailureReason)

    enum InterpolationFailureReason: Equatable {
        case missingGeometry
        case insufficientDonors(Set<Int>)
    }

    var errorDescription: String? {
        switch self {
        case .noInputs:
            return "No recordings were supplied for combining."
        case .noUsableCategories:
            return "The recordings have no usable categories to combine."
        case .channelMapping(let url, let failure):
            return "\(url.lastPathComponent): \(failure.message)."
        case .samplingRateMismatch(let url, let actual, let expected):
            return "\(url.lastPathComponent): sampling rate \(actual) Hz does not match \(expected) Hz."
        case .epochLengthMismatch(let url, let actual, let expected):
            return "\(url.lastPathComponent): epoch length \(actual) samples does not match \(expected) samples."
        case .malformedSignal(let url, let reason):
            return "\(url.lastPathComponent): \(reason)."
        case .interpolationUnavailable(let url, .missingGeometry):
            return "\(url.lastPathComponent): interpolation requested but no electrode geometry is available."
        case .interpolationUnavailable(let url, .insufficientDonors(let channels)):
            return "\(url.lastPathComponent): unable to interpolate channels \(ChannelDecisionSteps.channelList(channels)); their positions or sufficient good donors are unavailable."
        }
    }
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
        let psaArtifactThresholds = script?.steps
            .last(where: { $0.operation == .segment })
            .flatMap { PSAArtifactThresholdSnapshot(parameters: $0.parameters) }
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

        var summary = RecordingSummary(
            url: input.url,
            fileName: input.url.lastPathComponent,
            netName: input.geometry?.name ?? "",
            channelCount: signal.numberOfChannels,
            samplingRate: signal.samplingRate,
            epochLengthSamples: epochLen,
            isAveraged: signal.isAveraged,
            categories: categories,
            hasProcessingRecord: hasProcessingRecord,
            psaArtifactThresholds: psaArtifactThresholds,
            snr: snr
        )
        summary.channelLayout = ChannelLayoutSignature(
            channelNames: signal.channelNames,
            expectedCount: signal.numberOfChannels
        )
        return summary
    }

    static func restoredBadChannelState(fromPackage url: URL) -> RestoredBadChannelState {
        guard let script = EVAProcessingScriptXML.read(fromPackage: url) else {
            return RestoredBadChannelState(bad: [], alreadyInterpolated: [])
        }
        let bad = script.steps.last(where: { $0.operation == .markBad })?
            .parameters["channels"]
            .map(ChannelDecisionSteps.channelIndices(from:)) ?? []
        let interpolated = script.steps.last(where: { $0.operation == .interpolateChannels })?
            .parameters["channels"]
            .map(ChannelDecisionSteps.channelIndices(from:)) ?? []
        return RestoredBadChannelState(bad: bad, alreadyInterpolated: interpolated)
    }

    static func badChannelProvenanceSteps(
        for inputs: [CombineInput],
        policy: BadChannelPolicy
    ) -> [EVAProcessingStep] {
        inputs.map { input in
            let appliedChannels: Set<Int>
            switch policy {
            case .interpolatePerFile:
                appliedChannels = input.badChannels.subtracting(input.alreadyInterpolatedChannels)
            case .excludePerChannel:
                appliedChannels = input.badChannels
            }
            return EVAProcessingStep(
                operation: .combineBadChannelPolicy,
                parameters: [
                    "file": input.url.lastPathComponent,
                    "policy": policy.rawValue,
                    "channels": ChannelDecisionSteps.channelList(appliedChannels),
                    "alreadyInterpolatedChannels": ChannelDecisionSteps.channelList(input.alreadyInterpolatedChannels)
                ],
                replayable: false,
                note: "Per-contributor bad-channel handling used by grand average."
            )
        }
    }

    static func channelMapping(
        of summary: RecordingSummary,
        reference: RecordingSummary
    ) -> ChannelMappingResult {
        channelMapping(source: summary.channelLayout, reference: reference.channelLayout)
    }

    private static func channelMapping(
        source: ChannelLayoutSignature,
        reference: ChannelLayoutSignature
    ) -> ChannelMappingResult {
        guard !source.namesInOrder.isEmpty, !reference.namesInOrder.isEmpty else {
            return .unresolved(.missingNames)
        }
        let duplicates = source.duplicateNames.union(reference.duplicateNames)
        guard source.hasUniqueNames, reference.hasUniqueNames else {
            return duplicates.isEmpty ? .unresolved(.missingNames) : .unresolved(.duplicateNames(duplicates))
        }
        if source.namesInOrder == reference.namesInOrder { return .identity }
        let sourceSet = Set(source.namesInOrder)
        let referenceSet = Set(reference.namesInOrder)
        guard sourceSet == referenceSet else {
            return .unresolved(.setMismatch(
                missing: referenceSet.subtracting(sourceSet),
                extra: sourceSet.subtracting(referenceSet)
            ))
        }
        let sourceIndex = Dictionary(uniqueKeysWithValues: source.namesInOrder.enumerated().map { ($1, $0) })
        return .remapped(sourceIndexByReferenceIndex: reference.namesInOrder.map { sourceIndex[$0]! })
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
        if abs(summary.samplingRate - reference.samplingRate) >= 1e-9 {
            flags.append(.samplingRateMismatch(summary.samplingRate, expected: reference.samplingRate))
        }
        if summary.epochLengthSamples > 0,
           reference.epochLengthSamples > 0,
           summary.epochLengthSamples != reference.epochLengthSamples {
            flags.append(.epochLengthMismatch(
                summary.epochLengthSamples,
                expected: reference.epochLengthSamples
            ))
        }
        if case .unresolved(let failure) = channelMapping(of: summary, reference: reference) {
            flags.append(.channelIdentityUnresolved(failure))
        }
        return flags
    }

    // MARK: - Append

    static func append(
        _ inputs: [CombineInput],
        log: EVAProcessLog
    ) throws -> (signal: MFFSignalData, segments: [EpochSegment]) {
        let inputs = try validatedAndRemappedInputs(inputs)
        let channelCount = inputs[0].signal.numberOfChannels
        var combined = [[Float]](repeating: [], count: channelCount)
        var segments: [EpochSegment] = []
        var events: [MFFEvent] = []
        var sampleOffset = 0

        for input in inputs {
            let len = input.signal.data.first?.count ?? 0
            for c in 0..<channelCount {
                combined[c].append(contentsOf: input.signal.data[c])
            }
            let offsetSeconds = Double(sampleOffset) / input.signal.samplingRate
            events.append(contentsOf: input.signal.events.map { event in
                MFFEvent(
                    id: "\(input.url.lastPathComponent)-\(event.id)",
                    code: event.code,
                    label: event.label,
                    eventDescription: event.eventDescription,
                    cell: event.cell,
                    beginTimeSeconds: event.beginTimeSeconds + offsetSeconds,
                    rawBeginTime: event.rawBeginTime,
                    sourceFile: input.url.lastPathComponent,
                    durationSeconds: event.durationSeconds
                )
            })
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
        let signal = base.reconstructingTimeline(
            data: combined,
            events: events,
            epochSegments: segments,
            isSegmented: true,
            isAveraged: false,
            isGrandAverage: false,
            signalTypeSuffix: "combined-append"
        )
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
    ) throws -> GrandAverageOutput {
        let inputs = try validatedAndRemappedInputs(inputs)
        let channelCount = inputs[0].signal.numberOfChannels

        // Gather each file's per-canonical-category average, stimulus-aligned.
        struct FileAverage { let url: URL; let waveform: [[Float]]; let pre: Int; let post: Int; let trials: Int; let weight: Double; let bad: Set<Int> }
        var byCategory: [String: [FileAverage]] = [:]
        var rawWeightByFile: [URL: Double] = [:]

        for input in inputs {
            let map = categoryMap[input.url] ?? [:]
            let grouped = Dictionary(grouping: input.segments, by: { map[$0.category] ?? $0.category })
            for (canonical, segs) in grouped {
                guard let avg = try fileCategoryAverage(
                    input: input,
                    segments: segs,
                    rebaseline: rebaseline,
                    badChannelPolicy: badChannelPolicy
                ) else { continue }
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

        guard !byCategory.isEmpty else { throw CombineError.noUsableCategories }

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
        let signal = base.reconstructingTimeline(
            data: outData,
            events: [],
            epochSegments: outSegments,
            isSegmented: true,
            isAveraged: true,
            isGrandAverage: true,
            signalTypeSuffix: "grand-average"
        )
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
        rebaseline: Bool,
        badChannelPolicy: BadChannelPolicy
    ) throws -> (waveform: [[Float]], singleTrials: [[[Float]]], pre: Int, post: Int, trials: Int)? {
        guard !segments.isEmpty else { return nil }

        let unresolvedBad = input.badChannels.subtracting(input.alreadyInterpolatedChannels)
        var interpolationWeights: [Int: (indices: [Int], weights: [Double])] = [:]
        if badChannelPolicy == .interpolatePerFile, !unresolvedBad.isEmpty {
            guard let geometry = input.geometry else {
                throw CombineError.interpolationUnavailable(url: input.url, reason: .missingGeometry)
            }
            let good = (0..<input.signal.numberOfChannels).filter { !unresolvedBad.contains($0) }
            interpolationWeights = SphericalSpline.interpolationWeightsBatch(
                targets: unresolvedBad.sorted(),
                good: good,
                positions: geometry.positions
            )
            let failed = unresolvedBad.subtracting(interpolationWeights.keys)
            guard failed.isEmpty else {
                throw CombineError.interpolationUnavailable(url: input.url, reason: .insufficientDonors(failed))
            }
        }

        if input.signal.isAveraged, segments.count == 1, let seg = segments.first,
           var wave = slice(signal: input.signal, segment: seg) {
            applyInterpolation(interpolationWeights, to: &wave)
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
            applyInterpolation(interpolationWeights, to: &trial)
            if rebaseline, pre > 0 { baselineCorrect(&trial, baselineSampleCount: pre) }
            trials.append(trial)
        }
        guard !trials.isEmpty else { return nil }
        let avg = EpochSNR.averageTrials(trials, channels: channelCount, samples: window)
        return (avg, trials, pre, post, trials.count)
    }

    private static func applyInterpolation(
        _ recipes: [Int: (indices: [Int], weights: [Double])],
        to channels: inout [[Float]]
    ) {
        guard let sampleCount = channels.first?.count else { return }
        let source = channels
        for (target, recipe) in recipes where channels.indices.contains(target) {
            var replacement = [Float](repeating: 0, count: sampleCount)
            for (index, weight) in zip(recipe.indices, recipe.weights)
                where source.indices.contains(index) && source[index].count == sampleCount {
                let w = Float(weight)
                for sample in 0..<sampleCount { replacement[sample] += w * source[index][sample] }
            }
            channels[target] = replacement
        }
    }

    private static func validatedAndRemappedInputs(_ inputs: [CombineInput]) throws -> [CombineInput] {
        guard let reference = inputs.first else { throw CombineError.noInputs }
        let referenceRate = reference.signal.samplingRate
        let referenceEpochLength = reference.segments.map { $0.endSample - $0.startSample + 1 }.min() ?? 0
        let referenceLayout = ChannelLayoutSignature(
            channelNames: reference.signal.channelNames,
            expectedCount: reference.signal.numberOfChannels
        )

        return try inputs.map { input in
            guard input.signal.data.count == input.signal.numberOfChannels,
                  let sampleCount = input.signal.data.first?.count,
                  input.signal.data.allSatisfy({ $0.count == sampleCount }) else {
                throw CombineError.malformedSignal(url: input.url, reason: "channel data are empty or ragged")
            }
            guard input.signal.samplingRate.isFinite, input.signal.samplingRate > 0,
                  referenceRate.isFinite, referenceRate > 0 else {
                throw CombineError.malformedSignal(url: input.url, reason: "sampling rate is not finite and positive")
            }
            guard !input.segments.isEmpty else {
                throw CombineError.malformedSignal(url: input.url, reason: "recording has no epoch segments")
            }
            guard abs(input.signal.samplingRate - referenceRate) < 1e-9 else {
                throw CombineError.samplingRateMismatch(
                    url: input.url,
                    actual: input.signal.samplingRate,
                    expected: referenceRate
                )
            }
            let epochLength = input.segments.map { $0.endSample - $0.startSample + 1 }.min() ?? 0
            if epochLength > 0, referenceEpochLength > 0, epochLength != referenceEpochLength {
                throw CombineError.epochLengthMismatch(
                    url: input.url,
                    actual: epochLength,
                    expected: referenceEpochLength
                )
            }
            guard input.segments.allSatisfy({
                $0.startSample >= 0 && $0.endSample >= $0.startSample && $0.endSample < sampleCount
            }) else {
                throw CombineError.malformedSignal(url: input.url, reason: "epoch segments are outside the signal bounds")
            }
            let channelIndices = input.badChannels.union(input.alreadyInterpolatedChannels)
            guard channelIndices.allSatisfy({ (0..<input.signal.numberOfChannels).contains($0) }) else {
                throw CombineError.malformedSignal(url: input.url, reason: "bad-channel provenance contains an invalid channel index")
            }
            guard input.signal.impedancesKOhm.map({ $0.count == input.signal.numberOfChannels }) ?? true,
                  input.signal.positiveUpFlags.map({ $0.count == input.signal.numberOfChannels }) ?? true else {
                throw CombineError.malformedSignal(url: input.url, reason: "channel metadata do not match the signal channel count")
            }
            let sourceLayout = ChannelLayoutSignature(
                channelNames: input.signal.channelNames,
                expectedCount: input.signal.numberOfChannels
            )
            let mapping = channelMapping(source: sourceLayout, reference: referenceLayout)
            switch mapping {
            case .identity:
                return input
            case .unresolved(let failure):
                throw CombineError.channelMapping(url: input.url, failure: failure)
            case .remapped(let sourceIndexByReferenceIndex):
                let remappedData = sourceIndexByReferenceIndex.map { input.signal.data[$0] }
                let remappedImpedances = input.signal.impedancesKOhm.map { values in
                    sourceIndexByReferenceIndex.map { values.indices.contains($0) ? values[$0] : .nan }
                }
                let remappedPositiveUp = input.signal.positiveUpFlags.map { values in
                    sourceIndexByReferenceIndex.map { values.indices.contains($0) ? values[$0] : true }
                }
                let sourceToReference = Dictionary(
                    uniqueKeysWithValues: sourceIndexByReferenceIndex.enumerated().map { ($1, $0) }
                )
                let remapSet: (Set<Int>) -> Set<Int> = { sourceSet in
                    Set(sourceSet.compactMap { sourceToReference[$0] })
                }
                let positions = input.geometry.map { geometry in
                    Dictionary(uniqueKeysWithValues: geometry.positions.compactMap { sourceIndex, position in
                        sourceToReference[sourceIndex].map { ($0, position) }
                    })
                }
                let signal = MFFSignalData(
                    signalURL: input.signal.signalURL,
                    signalType: input.signal.signalType,
                    numberOfChannels: reference.signal.numberOfChannels,
                    samplingRate: input.signal.samplingRate,
                    duration: input.signal.duration,
                    recordingStartTime: input.signal.recordingStartTime,
                    events: input.signal.events,
                    data: remappedData,
                    channelNames: reference.signal.channelNames,
                    epochSegments: input.signal.epochSegments,
                    isSegmented: input.signal.isSegmented,
                    isAveraged: input.signal.isAveraged,
                    isGrandAverage: input.signal.isGrandAverage,
                    impedancesKOhm: remappedImpedances,
                    positiveUpFlags: remappedPositiveUp
                )
                return CombineInput(
                    url: input.url,
                    signal: signal,
                    segments: input.segments,
                    badChannels: remapSet(input.badChannels),
                    alreadyInterpolatedChannels: remapSet(input.alreadyInterpolatedChannels),
                    geometry: positions.map { ElectrodeGeometry(name: input.geometry?.name ?? "", positions: $0) }
                )
            }
        }
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
