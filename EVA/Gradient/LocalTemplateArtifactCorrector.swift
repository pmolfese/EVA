//
//  LocalTemplateArtifactCorrector.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Independent implementation based on
//  docs/provenance/amri-functional-spec.md. No third-party
//  artifact-correction source was consulted.
//

import Foundation

/// A half-open correction window relative to an event center.
///
/// For example, `startOffset: -10, endOffset: 20` covers 30 samples, from ten
/// samples before the center through nineteen samples after it. Windows are
/// clipped to the recording; they are never padded with invented signal.
nonisolated struct LocalTemplateSampleWindow: Sendable, Equatable {
    var startOffset: Int
    var endOffset: Int

    var length: Int { endOffset - startOffset }
}

/// An event expressed directly in recording samples.
nonisolated struct LocalTemplateSampleEvent: Sendable, Equatable {
    var centerSample: Int
    var window: LocalTemplateSampleWindow
    /// Ineligible events can still be corrected, but can never contribute to a
    /// neighboring event's template.
    var isDonorEligible: Bool = true
}

/// A user event expressed in seconds.
nonisolated struct LocalTemplateTimedEvent: Sendable, Equatable {
    var centerTime: TimeInterval
    var duration: TimeInterval? = nil
    var isDonorEligible: Bool = true
}

/// How time-based user-event windows are constructed.
nonisolated enum LocalTemplateTimedWindow: Sendable, Equatable {
    /// A fixed window shared by every event.
    case fixed(secondsBefore: TimeInterval, secondsAfter: TimeInterval)
    /// A window centered on each event and sized from that event's duration.
    /// An event without a measured duration is treated as one sample long.
    case eventDuration(paddingBefore: TimeInterval = 0, paddingAfter: TimeInterval = 0)
}

/// Sample-wise reduction used to form a local artifact template.
nonisolated enum LocalTemplateReducer: Sendable, Equatable {
    case mean
    case median
    /// Exponential temporal weighting, `exp(-distance / timeConstantSamples)`.
    case exponentiallyWeighted(timeConstantSamples: Double)

    fileprivate var name: String {
        switch self {
        case .mean: return "mean"
        case .median: return "median"
        case .exponentiallyWeighted: return "exponentially-weighted-mean"
        }
    }
}

/// How the template is matched to the target before subtraction.
nonisolated enum LocalTemplateFit: Sendable, Equatable {
    /// Subtract the template as constructed (`alpha = 1`).
    case unscaled
    /// Fit each channel independently with
    /// `alpha = dot(target, template) / dot(template, template)`.
    /// No intercept, demeaning, or baseline removal is applied.
    case leastSquares

    fileprivate var name: String {
        switch self {
        case .unscaled: return "unscaled"
        case .leastSquares: return "least-squares"
        }
    }
}

/// Behavior when fewer than `minimumDonorCount` eligible neighbors exist.
nonisolated enum LocalTemplateInsufficientDonorPolicy: Sendable, Equatable {
    /// Proceed with every available donor. All reducers have a hard minimum of
    /// one donor.
    case useAvailable
    /// Leave the target unchanged unless the configured minimum is met.
    case skipTarget
}

nonisolated struct LocalTemplateConfiguration: Sendable, Equatable {
    var donorsBefore: Int = 2
    var donorsAfter: Int = 2
    var excludedDonorIndices: Set<Int> = []
    var minimumDonorDistanceSamples: Int = 0
    var minimumDonorCount: Int = 1
    var insufficientDonorPolicy: LocalTemplateInsufficientDonorPolicy = .useAvailable
    var reducer: LocalTemplateReducer = .median
    var fit: LocalTemplateFit = .unscaled

    /// Smallest Pearson correlation a donor's window must reach against the
    /// target's before it may contribute, or nil to accept every eligible donor.
    ///
    /// Nearness in time is a proxy for similarity, and usually a good one, but it
    /// is only a proxy: a donor interrupted by movement or a dropout is still a
    /// near neighbour. This compares the waveforms directly and drops the ones
    /// that do not match, which is what the reducer's robustness cannot do on its
    /// own once a majority of donors are contaminated.
    ///
    /// Scoring is done on a single representative channel — the highest-variance
    /// one, ties to the lowest index — so a donor set is shared by every channel.
    /// That keeps one template geometry for the whole recording, and it is what
    /// lets the templates be built concurrently. See the note on
    /// `representativeChannelIndex` about making this selectable later.
    ///
    /// Defaults to nil: this is an addition, and it must not change the result of
    /// a run that did not ask for it.
    var minimumDonorCorrelation: Double? = nil

    /// Which backend runs the dense arithmetic.
    ///
    /// Changes how fast a run is, never what it decides: donor selection, the
    /// correlation floor, and every skip reason are settled on the CPU before a
    /// backend sees anything. `.metal` falls back silently when no device is
    /// present or the run is past what the kernels can reduce in registers.
    var computeBackend: GradientComputeBackend = .cpu
}

nonisolated enum LocalTemplateSkipReason: String, Sendable, Equatable {
    case outsideRecording
    case insufficientDonors
    case noTemplateSamples
    /// Every eligible donor fell below `minimumDonorCorrelation`.
    case noCorrelatedDonors
}

/// A donor the correlation floor turned away, with the score that did it.
nonisolated struct LocalTemplateRejectedDonor: Sendable, Equatable {
    var eventIndex: Int
    var correlation: Double
}

nonisolated struct LocalTemplateEventSummary: Sendable, Equatable {
    var eventIndex: Int
    var donorIndices: [Int]
    var skippedReason: LocalTemplateSkipReason?
    /// One scale per channel for least-squares fitting, or `nil` when the
    /// unscaled fit is selected or the event is skipped.
    var scaleFactors: [Double]?
    var methodName: String
    /// Donors that were eligible by position but fell below
    /// `minimumDonorCorrelation`. Empty when no floor was configured.
    ///
    /// Recorded rather than merely omitted from `donorIndices` so a run can
    /// answer "what did you leave out, and why" instead of only "what did you
    /// use" — the exclusions are the part a reviewer cannot reconstruct.
    var rejectedDonors: [LocalTemplateRejectedDonor] = []

    var donorCount: Int { donorIndices.count }
}

nonisolated struct LocalTemplateCorrectionResult: Sendable, Equatable {
    var cleanedChannels: [[Float]]
    var artifactEstimate: [[Float]]
    var eventSummaries: [LocalTemplateEventSummary]
}

nonisolated enum LocalTemplateCorrectionError: Error, Sendable, Equatable {
    case inconsistentChannelLengths
    case nonFiniteInput(channel: Int, sample: Int)
    case invalidSamplingRate
    case invalidWindow(event: Int)
    case invalidConfiguration
    case cannotInferGradientEpochLength
}

/// Shared local-template artifact correction for scanner-volume and arbitrary
/// user events.
///
/// Each target is corrected independently. If target windows overlap, their
/// artifact estimates are combined with a raised-cosine overlap-add and divided
/// by the accumulated weights. This makes overlap handling deterministic and
/// avoids discontinuities at window boundaries.
nonisolated enum LocalTemplateArtifactCorrector {

    /// Correct events whose centers and windows are already expressed in samples.
    static func correct(
        channels: [[Float]],
        events: [LocalTemplateSampleEvent],
        configuration: LocalTemplateConfiguration = LocalTemplateConfiguration()
    ) throws -> LocalTemplateCorrectionResult {
        let sampleCount = try validate(channels: channels)
        try validate(configuration: configuration)

        for (index, event) in events.enumerated() where event.window.length <= 0 {
            throw LocalTemplateCorrectionError.invalidWindow(event: index)
        }

        guard !channels.isEmpty, sampleCount > 0 else {
            return LocalTemplateCorrectionResult(
                cleanedChannels: channels,
                artifactEstimate: channels.map { _ in [] },
                eventSummaries: events.indices.map {
                    summary(index: $0, donors: [], reason: .outsideRecording, scales: nil, configuration: configuration)
                }
            )
        }

        var accumulatedArtifact = Array(
            repeating: Array(repeating: 0.0, count: sampleCount),
            count: channels.count
        )
        var accumulatedWeight = Array(
            repeating: Array(repeating: 0.0, count: sampleCount),
            count: channels.count
        )
        var summaries: [LocalTemplateEventSummary] = []
        summaries.reserveCapacity(events.count)

        // Only needed when the correlation floor is on, and it costs a pass over
        // the recording, so it is not computed otherwise.
        let representative = configuration.minimumDonorCorrelation == nil
            ? 0
            : representativeChannelIndex(channels)

        // Decisions first, for every target, before any arithmetic. Both
        // backends consume these, so neither can decide something the other
        // would not.
        let decisions = events.indices.map { index in
            decide(
                targetIndex: index,
                events: events,
                channels: channels,
                representative: representative,
                sampleCount: sampleCount,
                configuration: configuration
            )
        }

        func eventSummary(for index: Int, scales: [Double]?) -> LocalTemplateEventSummary {
            let decision = decisions[index]
            return Self.summary(
                index: index,
                donors: decision.reason == .outsideRecording ? [] : decision.donors,
                reason: decision.reason,
                scales: decision.isCorrected ? scales : nil,
                configuration: configuration,
                rejected: decision.rejected
            )
        }

        // The GPU path, when it is asked for and can take the work. It declines
        // rather than fails — a donor list past what the kernels reduce in
        // registers falls through to the CPU below.
        if configuration.computeBackend == .metal,
           let backend = LocalTemplateMetalBackend.shared {
            let plan = makePlan(
                decisions: decisions,
                events: events,
                sampleCount: sampleCount,
                configuration: configuration
            )
            if backend.canRun(plan),
               let output = backend.correct(channels: channels, plan: plan) {
                let fitsScale = configuration.fit == .leastSquares
                let summaries = events.indices.map { index -> LocalTemplateEventSummary in
                    guard fitsScale, decisions[index].isCorrected else {
                        return eventSummary(for: index, scales: nil)
                    }
                    let scales = (0..<channels.count).map { channel in
                        Double(output.scales[channel * events.count + index])
                    }
                    return eventSummary(for: index, scales: scales)
                }
                return LocalTemplateCorrectionResult(
                    cleanedChannels: output.cleaned,
                    artifactEstimate: output.artifact,
                    eventSummaries: summaries
                )
            }
        }

        for targetIndex in events.indices {
            let target = events[targetIndex]
            let decision = decisions[targetIndex]
            guard decision.isCorrected else {
                summaries.append(eventSummary(for: targetIndex, scales: nil))
                continue
            }
            let donors = decision.donors

            let offsets = Array(target.window.startOffset..<target.window.endOffset)
            // The raised-cosine taper depends only on position within the
            // window, so it is the same for every channel. Computing it here
            // instead of per (channel, sample) removes one sin() per sample per
            // channel — tens of millions of them on a real recording.
            let taper = (0..<offsets.count).map { taperWeight(position: $0, count: offsets.count) }
            let templates = buildTemplates(
                channels: channels,
                events: events,
                donors: donors,
                targetIndex: targetIndex,
                offsets: offsets,
                reducer: configuration.reducer
            )

            // Fitting and accumulation are per-channel and touch only that
            // channel's row, so they run together in one concurrent pass.
            var scales = Array(repeating: 1.0, count: channels.count)
            scales.withUnsafeMutableBufferPointer { scaleBuffer in
                let scaleOut = GradientUnsafeSendable(base: scaleBuffer.baseAddress!)
                accumulatedArtifact.withUnsafeMutableBufferPointer { artifactBuffer in
                    let artifactOut = GradientUnsafeSendable(base: artifactBuffer.baseAddress!)
                    accumulatedWeight.withUnsafeMutableBufferPointer { weightBuffer in
                        let weightOut = GradientUnsafeSendable(base: weightBuffer.baseAddress!)
                        // `offsets` is contiguous, so the in-bounds positions
                        // form one range. Computing it once replaces a bounds
                        // check per sample.
                        let base = target.centerSample + target.window.startOffset
                        let firstPosition = max(0, -base)
                        let lastPosition = min(offsets.count, sampleCount - base)

                        evaConcurrentPerform(iterations: channels.count) { channelIndex in
                            var scale = 1.0
                            if configuration.fit == .leastSquares {
                                scale = leastSquaresScale(
                                    channel: channels[channelIndex],
                                    center: target.centerSample,
                                    offsets: offsets,
                                    template: templates[channelIndex]
                                )
                                scaleOut.base[channelIndex] = scale
                            }
                            guard firstPosition < lastPosition else { return }
                            let row = templates[channelIndex]
                            artifactOut.base[channelIndex].withUnsafeMutableBufferPointer { artifactRow in
                                weightOut.base[channelIndex].withUnsafeMutableBufferPointer { weightRow in
                                    for position in firstPosition..<lastPosition {
                                        guard let templateValue = row[position] else { continue }
                                        let weight = taper[position]
                                        let sample = base + position
                                        artifactRow[sample] += scale * templateValue * weight
                                        weightRow[sample] += weight
                                    }
                                }
                            }
                        }
                    }
                }
            }

            summaries.append(eventSummary(
                for: targetIndex,
                scales: configuration.fit == .leastSquares ? scales : nil
            ))
        }

        var artifact = Array(
            repeating: [Float](repeating: 0, count: sampleCount),
            count: channels.count
        )
        var cleaned = channels
        let finalAccumulatedWeight = accumulatedWeight
        let finalAccumulatedArtifact = accumulatedArtifact
        artifact.withUnsafeMutableBufferPointer { artifactBuffer in
            let artifactOut = GradientUnsafeSendable(base: artifactBuffer.baseAddress!)
            cleaned.withUnsafeMutableBufferPointer { cleanedBuffer in
                let cleanedOut = GradientUnsafeSendable(base: cleanedBuffer.baseAddress!)
                evaConcurrentPerform(iterations: channels.count) { channelIndex in
                    for sample in channels[channelIndex].indices {
                        let weight = finalAccumulatedWeight[channelIndex][sample]
                        if weight > 0 {
                            let value = Float(finalAccumulatedArtifact[channelIndex][sample] / weight)
                            artifactOut.base[channelIndex][sample] = value
                            cleanedOut.base[channelIndex][sample] -= value
                        }
                    }
                }
            }
        }

        return LocalTemplateCorrectionResult(
            cleanedChannels: cleaned,
            artifactEstimate: artifact,
            eventSummaries: summaries
        )
    }


    /// Everything decided about one target before any arithmetic runs.
    nonisolated struct EventDecision: Sendable {
        var donors: [Int] = []
        var reason: LocalTemplateSkipReason?
        var rejected: [LocalTemplateRejectedDonor] = []
        var isCorrected: Bool { reason == nil }
    }

    /// Decides one target's donors, or why it is skipped.
    ///
    /// Extracted so the CPU and GPU paths cannot drift: both consume the same
    /// decisions rather than each making their own. Nothing here reads channel
    /// data except the correlation floor, which reads one representative channel.
    private static func decide(
        targetIndex: Int,
        events: [LocalTemplateSampleEvent],
        channels: [[Float]],
        representative: Int,
        sampleCount: Int,
        configuration: LocalTemplateConfiguration
    ) -> EventDecision {
        let target = events[targetIndex]
        guard overlapsRecording(target, sampleCount: sampleCount) else {
            return EventDecision(reason: .outsideRecording)
        }

        var decision = EventDecision()
        decision.donors = selectDonors(
            for: targetIndex, events: events, configuration: configuration
        )

        // The correlation floor narrows the eligible set; everything after it —
        // the minimum count and the insufficient-donor policy — then applies to
        // what survived. Composing rather than adding a second policy means
        // there is one answer to "what happens when donors run out".
        if let floor = configuration.minimumDonorCorrelation, !decision.donors.isEmpty {
            var accepted: [Int] = []
            accepted.reserveCapacity(decision.donors.count)
            for donorIndex in decision.donors {
                let correlation = donorCorrelation(
                    channel: channels[representative],
                    target: target,
                    donor: events[donorIndex]
                )
                if correlation >= floor {
                    accepted.append(donorIndex)
                } else {
                    decision.rejected.append(
                        LocalTemplateRejectedDonor(eventIndex: donorIndex, correlation: correlation)
                    )
                }
            }
            decision.donors = accepted
            if decision.donors.isEmpty {
                decision.reason = .noCorrelatedDonors
                return decision
            }
        }

        let requiredDonors = max(1, configuration.minimumDonorCount)
        if decision.donors.isEmpty || (
            decision.donors.count < requiredDonors &&
            configuration.insufficientDonorPolicy == .skipTarget
        ) {
            decision.reason = .insufficientDonors
            return decision
        }

        guard hasAnyTemplateSample(
            target: target, donors: decision.donors, events: events, sampleCount: sampleCount
        ) else {
            decision.reason = .noTemplateSamples
            return decision
        }
        return decision
    }

    /// Whether any offset in the target window has at least one donor covering it
    /// with an in-range sample.
    ///
    /// This is pure geometry — whether a template sample exists never depends on
    /// what the channel data is, only on whether a donor reaches that offset. The
    /// CPU path used to discover it by inspecting the built templates; deciding
    /// it up front is equivalent and lets both backends reach the same verdict
    /// without one of them having to build templates first.
    private static func hasAnyTemplateSample(
        target: LocalTemplateSampleEvent,
        donors: [Int],
        events: [LocalTemplateSampleEvent],
        sampleCount: Int
    ) -> Bool {
        for offset in target.window.startOffset..<target.window.endOffset {
            for donorIndex in donors {
                let donor = events[donorIndex]
                guard offset >= donor.window.startOffset, offset < donor.window.endOffset else {
                    continue
                }
                let sample = donor.centerSample + offset
                if sample >= 0, sample < sampleCount { return true }
            }
        }
        return false
    }

    /// Packs the decisions into the flat form the Metal kernels read.
    ///
    /// Skipped events simply never enter the cover table, so the GPU cannot
    /// correct something the CPU decided to leave alone.
    private static func makePlan(
        decisions: [EventDecision],
        events: [LocalTemplateSampleEvent],
        sampleCount: Int,
        configuration: LocalTemplateConfiguration
    ) -> LocalTemplatePlan {
        var donorOffsets: [Int32] = [0]
        var donorIndices: [Int32] = []
        donorOffsets.reserveCapacity(events.count + 1)
        for index in events.indices {
            if decisions[index].isCorrected {
                donorIndices.append(contentsOf: decisions[index].donors.map(Int32.init))
            }
            donorOffsets.append(Int32(donorIndices.count))
        }

        var coverCounts = [Int](repeating: 0, count: sampleCount)
        func span(_ index: Int) -> Range<Int>? {
            guard decisions[index].isCorrected else { return nil }
            let event = events[index]
            let base = event.centerSample + event.window.startOffset
            let lower = max(0, base)
            let upper = min(sampleCount, base + event.window.length)
            return lower < upper ? lower..<upper : nil
        }
        for index in events.indices {
            guard let range = span(index) else { continue }
            for sample in range { coverCounts[sample] += 1 }
        }
        var coverOffsets = [Int32](repeating: 0, count: sampleCount + 1)
        var running = 0
        for sample in 0..<sampleCount {
            coverOffsets[sample] = Int32(running)
            running += coverCounts[sample]
        }
        coverOffsets[sampleCount] = Int32(running)
        var coverEvents = [Int32](repeating: -1, count: running)
        var filled = [Int32](repeating: 0, count: sampleCount)
        for index in events.indices {
            guard let range = span(index) else { continue }
            for sample in range {
                coverEvents[Int(coverOffsets[sample] + filled[sample])] = Int32(index)
                filled[sample] += 1
            }
        }

        let reducerCode: UInt32
        var timeConstant: Float = 1
        switch configuration.reducer {
        case .mean: reducerCode = 0
        case .median: reducerCode = 1
        case let .exponentiallyWeighted(constant):
            reducerCode = 2
            timeConstant = Float(constant)
        }

        return LocalTemplatePlan(
            sampleCount: sampleCount,
            eventCount: events.count,
            centers: events.map { Int32($0.centerSample) },
            windowStart: events.map { Int32($0.window.startOffset) },
            windowEnd: events.map { Int32($0.window.endOffset) },
            donorOffsets: donorOffsets,
            donorIndices: donorIndices,
            coverOffsets: coverOffsets,
            coverEvents: coverEvents,
            reducer: reducerCode,
            timeConstant: timeConstant,
            appliesScale: configuration.fit == .leastSquares
        )
    }

    /// Correct scanner-volume artifacts. Triggers are sorted and deduplicated;
    /// triggers outside the recording are discarded. With no explicit epoch
    /// length, the rounded median interval between valid triggers is used and
    /// each epoch begins at its trigger.
    static func correctGradient(
        channels: [[Float]],
        trSamples: [Int],
        samplingRate: Double,
        epochLengthSamples: Int? = nil,
        configuration: LocalTemplateConfiguration = LocalTemplateConfiguration()
    ) throws -> LocalTemplateCorrectionResult {
        guard samplingRate.isFinite, samplingRate > 0 else {
            throw LocalTemplateCorrectionError.invalidSamplingRate
        }
        let sampleCount = try validate(channels: channels)
        let triggers = Array(Set(trSamples.filter { $0 >= 0 && $0 < sampleCount })).sorted()

        let epochLength: Int
        if let supplied = epochLengthSamples {
            guard supplied > 0 else {
                throw LocalTemplateCorrectionError.invalidWindow(event: 0)
            }
            epochLength = supplied
        } else {
            guard triggers.count >= 2 else {
                throw LocalTemplateCorrectionError.cannotInferGradientEpochLength
            }
            let intervals = zip(triggers, triggers.dropFirst()).map { $1 - $0 }.sorted()
            epochLength = medianInteger(intervals)
            guard epochLength > 0 else {
                throw LocalTemplateCorrectionError.cannotInferGradientEpochLength
            }
        }

        let window = LocalTemplateSampleWindow(startOffset: 0, endOffset: epochLength)
        let events = triggers.map { LocalTemplateSampleEvent(centerSample: $0, window: window) }
        return try correct(channels: channels, events: events, configuration: configuration)
    }

    /// Correct arbitrary user events described in seconds. Conversion to samples
    /// uses nearest-sample rounding. Event-duration windows are centered on each
    /// event and may therefore have different lengths.
    static func correctTimedEvents(
        channels: [[Float]],
        events: [LocalTemplateTimedEvent],
        samplingRate: Double,
        window: LocalTemplateTimedWindow,
        configuration: LocalTemplateConfiguration = LocalTemplateConfiguration()
    ) throws -> LocalTemplateCorrectionResult {
        guard samplingRate.isFinite, samplingRate > 0 else {
            throw LocalTemplateCorrectionError.invalidSamplingRate
        }

        let sampleEvents = try events.enumerated().map { index, event in
            guard event.centerTime.isFinite else {
                throw LocalTemplateCorrectionError.invalidWindow(event: index)
            }
            let center = Int((event.centerTime * samplingRate).rounded())
            let sampleWindow: LocalTemplateSampleWindow

            switch window {
            case let .fixed(secondsBefore, secondsAfter):
                guard secondsBefore.isFinite, secondsAfter.isFinite,
                      secondsBefore >= 0, secondsAfter >= 0 else {
                    throw LocalTemplateCorrectionError.invalidWindow(event: index)
                }
                let before = Int((secondsBefore * samplingRate).rounded())
                let after = Int((secondsAfter * samplingRate).rounded())
                sampleWindow = LocalTemplateSampleWindow(
                    startOffset: -before,
                    endOffset: max(1, after)
                )

            case let .eventDuration(paddingBefore, paddingAfter):
                let duration = event.duration ?? (1 / samplingRate)
                guard duration.isFinite, duration >= 0,
                      paddingBefore.isFinite, paddingBefore >= 0,
                      paddingAfter.isFinite, paddingAfter >= 0 else {
                    throw LocalTemplateCorrectionError.invalidWindow(event: index)
                }
                let durationSamples = max(1, Int((duration * samplingRate).rounded()))
                let durationBefore = durationSamples / 2
                let durationAfter = durationSamples - durationBefore
                sampleWindow = LocalTemplateSampleWindow(
                    startOffset: -durationBefore - Int((paddingBefore * samplingRate).rounded()),
                    endOffset: durationAfter + Int((paddingAfter * samplingRate).rounded())
                )
            }

            return LocalTemplateSampleEvent(
                centerSample: center,
                window: sampleWindow,
                isDonorEligible: event.isDonorEligible
            )
        }

        return try correct(channels: channels, events: sampleEvents, configuration: configuration)
    }

    // MARK: - Validation

    private static func validate(channels: [[Float]]) throws -> Int {
        let sampleCount = channels.first?.count ?? 0
        guard channels.allSatisfy({ $0.count == sampleCount }) else {
            throw LocalTemplateCorrectionError.inconsistentChannelLengths
        }
        for (channelIndex, channel) in channels.enumerated() {
            for (sampleIndex, value) in channel.enumerated() where !value.isFinite {
                throw LocalTemplateCorrectionError.nonFiniteInput(
                    channel: channelIndex,
                    sample: sampleIndex
                )
            }
        }
        return sampleCount
    }

    private static func validate(configuration: LocalTemplateConfiguration) throws {
        guard configuration.donorsBefore >= 0,
              configuration.donorsAfter >= 0,
              configuration.donorsBefore + configuration.donorsAfter > 0,
              configuration.minimumDonorDistanceSamples >= 0,
              configuration.minimumDonorCount >= 1 else {
            throw LocalTemplateCorrectionError.invalidConfiguration
        }
        if case let .exponentiallyWeighted(timeConstant) = configuration.reducer,
           (!timeConstant.isFinite || timeConstant <= 0) {
            throw LocalTemplateCorrectionError.invalidConfiguration
        }
    }

    // MARK: - Donors

    private static func selectDonors(
        for targetIndex: Int,
        events: [LocalTemplateSampleEvent],
        configuration: LocalTemplateConfiguration
    ) -> [Int] {
        let targetCenter = events[targetIndex].centerSample
        var before: [Int] = []
        var after: [Int] = []

        for candidateIndex in events.indices where candidateIndex != targetIndex {
            let candidate = events[candidateIndex]
            guard candidate.isDonorEligible,
                  !configuration.excludedDonorIndices.contains(candidateIndex) else {
                continue
            }
            let distance = absoluteDistance(candidate.centerSample, targetCenter)
            guard distance >= configuration.minimumDonorDistanceSamples else {
                continue
            }
            if candidate.centerSample < targetCenter {
                before.append(candidateIndex)
            } else {
                after.append(candidateIndex)
            }
        }

        let ordered: (Int, Int) -> Bool = { lhs, rhs in
            let lhsDistance = absoluteDistance(events[lhs].centerSample, targetCenter)
            let rhsDistance = absoluteDistance(events[rhs].centerSample, targetCenter)
            return lhsDistance == rhsDistance ? lhs < rhs : lhsDistance < rhsDistance
        }
        before.sort(by: ordered)
        after.sort(by: ordered)

        var selected = Array(before.prefix(configuration.donorsBefore))
        selected.append(contentsOf: after.prefix(configuration.donorsAfter))

        // Shift the local window at recording boundaries to retain the requested
        // total donor count whenever the opposite side has spare candidates.
        let desired = configuration.donorsBefore + configuration.donorsAfter
        if selected.count < desired {
            let selectedSet = Set(selected)
            let remainder = (before + after)
                .filter { !selectedSet.contains($0) }
                .sorted(by: ordered)
            selected.append(contentsOf: remainder.prefix(desired - selected.count))
        }

        // If the caller asks to use what is available, broaden beyond the normal
        // local-window size only when necessary to reach its requested minimum.
        if configuration.insufficientDonorPolicy == .useAvailable,
           selected.count < configuration.minimumDonorCount {
            let selectedSet = Set(selected)
            let remainder = (before + after)
                .filter { !selectedSet.contains($0) }
                .sorted(by: ordered)
            selected.append(contentsOf: remainder.prefix(configuration.minimumDonorCount - selected.count))
        }

        return selected.sorted(by: ordered)
    }

    // MARK: - Template construction

    private static func buildTemplates(
        channels: [[Float]],
        events: [LocalTemplateSampleEvent],
        donors: [Int],
        targetIndex: Int,
        offsets: [Int],
        reducer: LocalTemplateReducer
    ) -> [[Double?]] {
        // Channels are independent here, and this is the hot loop of the whole
        // corrector: one reduction per (channel, offset, donor). Running the
        // channels concurrently changes scheduling only — each writes its own
        // row and the arithmetic inside a row is untouched — so the result is
        // identical to the serial order.
        var templates = [[Double?]](repeating: [], count: channels.count)
        templates.withUnsafeMutableBufferPointer { buffer in
            let out = GradientUnsafeSendable(base: buffer.baseAddress!)
            evaConcurrentPerform(iterations: channels.count) { channelIndex in
                out.base[channelIndex] = templateRow(
                    channel: channels[channelIndex],
                    events: events,
                    donors: donors,
                    targetIndex: targetIndex,
                    offsets: offsets,
                    reducer: reducer
                )
            }
        }
        return templates
    }

    private static func templateRow(
        channel: [Float],
        events: [LocalTemplateSampleEvent],
        donors: [Int],
        targetIndex: Int,
        offsets: [Int],
        reducer: LocalTemplateReducer
    ) -> [Double?] {
        var row = [Double?](repeating: nil, count: offsets.count)
        guard !donors.isEmpty else { return row }

        // One scratch pair for the whole row, and the reduction reads it through
        // a pointer rather than being handed an Array.
        //
        // This inner block runs once per (channel, sample) — tens of millions of
        // times on a real recording — and profiling put ~127 ns in it, far more
        // than eight loads and a median of eight can account for. Passing an
        // Array of tuples per call was the cost: allocation, retain/release, and
        // a copy-on-write check on every append. Neither the sort nor the buffer
        // traffic explained it; swapping mean for median moved the total by only
        // 8%, and the whole cost is linear in event count, so the full-size
        // output buffers are nearly free.
        let capacity = donors.count
        let values = UnsafeMutablePointer<Double>.allocate(capacity: capacity)
        let weights = UnsafeMutablePointer<Double>.allocate(capacity: capacity)
        defer {
            values.deallocate()
            weights.deallocate()
        }

        let sampleCount = channel.count
        let targetCenter = events[targetIndex].centerSample

        channel.withUnsafeBufferPointer { source in
            for position in offsets.indices {
                let offset = offsets[position]
                var count = 0

                for donorIndex in donors {
                    let donor = events[donorIndex]
                    guard offset >= donor.window.startOffset,
                          offset < donor.window.endOffset else {
                        continue
                    }
                    let sample = donor.centerSample + offset
                    guard sample >= 0, sample < sampleCount else { continue }

                    switch reducer {
                    case .mean, .median:
                        weights[count] = 1
                    case let .exponentiallyWeighted(timeConstant):
                        let distance = Double(absoluteDistance(donor.centerSample, targetCenter))
                        weights[count] = exp(-distance / timeConstant)
                    }
                    values[count] = Double(source[sample])
                    count += 1
                }

                row[position] = reduceScratch(
                    values: values,
                    weights: weights,
                    count: count,
                    using: reducer
                )
            }
        }
        return row
    }

    /// The same three reductions as `reduce(values:using:)`, over a caller-owned
    /// scratch buffer so the inner loop allocates nothing.
    ///
    /// The median sorts in place with insertion sort: `count` is the donor count,
    /// single digits in practice, where insertion sort beats a general sort and
    /// needs no scratch of its own. Summation order matches the Array form, so
    /// the results are identical.
    private static func reduceScratch(
        values: UnsafeMutablePointer<Double>,
        weights: UnsafeMutablePointer<Double>,
        count: Int,
        using reducer: LocalTemplateReducer
    ) -> Double? {
        guard count > 0 else { return nil }
        switch reducer {
        case .mean:
            var total = 0.0
            for index in 0..<count { total += values[index] }
            return total / Double(count)

        case .median:
            for index in 1..<count {
                let value = values[index]
                var slot = index - 1
                while slot >= 0, values[slot] > value {
                    values[slot + 1] = values[slot]
                    slot -= 1
                }
                values[slot + 1] = value
            }
            let middle = count / 2
            if count.isMultiple(of: 2) {
                return (values[middle - 1] + values[middle]) / 2
            }
            return values[middle]

        case .exponentiallyWeighted:
            var totalWeight = 0.0
            for index in 0..<count { totalWeight += weights[index] }
            guard totalWeight.isFinite, totalWeight > 0 else { return nil }
            var total = 0.0
            for index in 0..<count { total += values[index] * weights[index] }
            return total / totalWeight
        }
    }

    private static func reduce(
        values: [(value: Double, weight: Double)],
        using reducer: LocalTemplateReducer
    ) -> Double? {
        guard !values.isEmpty else { return nil }
        switch reducer {
        case .mean:
            return values.reduce(0) { $0 + $1.value } / Double(values.count)

        case .median:
            let sorted = values.map(\.value).sorted()
            let middle = sorted.count / 2
            if sorted.count.isMultiple(of: 2) {
                return (sorted[middle - 1] + sorted[middle]) / 2
            }
            return sorted[middle]

        case .exponentiallyWeighted:
            let totalWeight = values.reduce(0) { $0 + $1.weight }
            guard totalWeight.isFinite, totalWeight > 0 else { return nil }
            return values.reduce(0) { $0 + $1.value * $1.weight } / totalWeight
        }
    }

    private static func leastSquaresScale(
        channel: [Float],
        center: Int,
        offsets: [Int],
        template: [Double?]
    ) -> Double {
        var numerator = 0.0
        var denominator = 0.0
        for position in offsets.indices {
            let sample = center + offsets[position]
            guard channel.indices.contains(sample), let templateValue = template[position] else {
                continue
            }
            numerator += Double(channel[sample]) * templateValue
            denominator += templateValue * templateValue
        }
        guard denominator.isFinite, denominator > 1e-12 else { return 0 }
        let scale = numerator / denominator
        return scale.isFinite ? scale : 0
    }

    // MARK: - Small helpers

    private static func overlapsRecording(
        _ event: LocalTemplateSampleEvent,
        sampleCount: Int
    ) -> Bool {
        event.centerSample + event.window.endOffset > 0 &&
        event.centerSample + event.window.startOffset < sampleCount
    }

    private static func taperWeight(position: Int, count: Int) -> Double {
        guard count > 1 else { return 1 }
        let phase = Double(position + 1) / Double(count + 1) * Double.pi
        let sine = sin(phase)
        return sine * sine
    }

    private static func absoluteDistance(_ lhs: Int, _ rhs: Int) -> Int {
        let distance = lhs >= rhs ? lhs - rhs : rhs - lhs
        return distance >= 0 ? distance : Int.max
    }

    private static func medianInteger(_ sortedValues: [Int]) -> Int {
        let middle = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return Int((Double(sortedValues[middle - 1]) + Double(sortedValues[middle])) / 2.0 + 0.5)
        }
        return sortedValues[middle]
    }

    /// The channel donor correlations are scored on: the highest-variance one,
    /// ties to the lowest index.
    ///
    /// Artifact dominates variance, so this is the channel where the artifact
    /// waveform is clearest and a contaminated donor stands out most; a flat or
    /// disconnected channel carries no similarity information at all. The same
    /// rule picks the FASTR family's alignment reference, for the same reason.
    ///
    /// FUTURE: make this selectable — "representative | all | subset". Scoring
    /// per channel would let different channels correct with different donors,
    /// which is a scientific choice and not only a performance one, and it would
    /// end the assumption that a donor set can be shared across channels.
    static func representativeChannelIndex(_ channels: [[Float]]) -> Int {
        var best = 0
        var bestVariance = -Double.infinity
        for index in channels.indices {
            let channel = channels[index]
            guard !channel.isEmpty else { continue }
            var mean = 0.0
            for value in channel { mean += Double(value) }
            mean /= Double(channel.count)
            var variance = 0.0
            for value in channel {
                let deviation = Double(value) - mean
                variance += deviation * deviation
            }
            variance /= Double(channel.count)
            if variance > bestVariance {
                bestVariance = variance
                best = index
            }
        }
        return best
    }

    /// Pearson correlation between a target window and a donor window, over the
    /// offsets both cover and the recording contains.
    ///
    /// Windows can differ in length when events carry their own durations, so the
    /// comparison uses their intersection rather than assuming a shared shape. A
    /// flat window correlates with nothing and scores 0, which keeps it out of any
    /// non-negative floor. Same definition as
    /// `GradientDonorSelection.pearsonCorrelation`, in Double.
    static func donorCorrelation(
        channel: [Float],
        target: LocalTemplateSampleEvent,
        donor: LocalTemplateSampleEvent
    ) -> Double {
        let lower = max(target.window.startOffset, donor.window.startOffset)
        let upper = min(target.window.endOffset, donor.window.endOffset)
        guard lower < upper else { return 0 }

        var targetValues: [Double] = []
        var donorValues: [Double] = []
        targetValues.reserveCapacity(upper - lower)
        donorValues.reserveCapacity(upper - lower)
        for offset in lower..<upper {
            let targetSample = target.centerSample + offset
            let donorSample = donor.centerSample + offset
            guard targetSample >= 0, targetSample < channel.count,
                  donorSample >= 0, donorSample < channel.count else { continue }
            targetValues.append(Double(channel[targetSample]))
            donorValues.append(Double(channel[donorSample]))
        }
        guard targetValues.count > 1 else { return 0 }

        var targetMean = 0.0
        var donorMean = 0.0
        for index in targetValues.indices {
            targetMean += targetValues[index]
            donorMean += donorValues[index]
        }
        targetMean /= Double(targetValues.count)
        donorMean /= Double(donorValues.count)

        var covariance = 0.0
        var targetVariance = 0.0
        var donorVariance = 0.0
        for index in targetValues.indices {
            let targetDeviation = targetValues[index] - targetMean
            let donorDeviation = donorValues[index] - donorMean
            covariance += targetDeviation * donorDeviation
            targetVariance += targetDeviation * targetDeviation
            donorVariance += donorDeviation * donorDeviation
        }
        let denominator = (targetVariance * donorVariance).squareRoot()
        guard denominator > 1e-20 else { return 0 }
        return covariance / denominator
    }

    private static func summary(
        index: Int,
        donors: [Int],
        reason: LocalTemplateSkipReason?,
        scales: [Double]?,
        configuration: LocalTemplateConfiguration,
        rejected: [LocalTemplateRejectedDonor] = []
    ) -> LocalTemplateEventSummary {
        LocalTemplateEventSummary(
            eventIndex: index,
            donorIndices: donors,
            skippedReason: reason,
            scaleFactors: scales,
            methodName: "\(configuration.reducer.name)/\(configuration.fit.name)",
            rejectedDonors: rejected
        )
    }
}
