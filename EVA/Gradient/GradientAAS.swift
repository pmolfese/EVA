//
//  GradientAAS.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Independent AAS-family implementations written from published method
//  descriptions and EVA's own functional requirements. This file intentionally
//  keeps the practical EVA local-window AAS and a more Allen/IAR-style AAS in
//  one place: they are the same average-template subtraction family with
//  different defaults and guardrails.
//

import Accelerate
import Foundation

nonisolated enum GradientAAS {

    enum Preset: String, CaseIterable, Identifiable, Sendable {
        /// EVA's practical AAS behavior: detrend each volume epoch, build a
        /// local template from neighboring TRs, and subtract it.
        /// Novel implementation by J. Teves & P. Molfese, NIH.
        ///
        /// **Deprecated 2026-08-09.** Withdrawn from the method picker. It
        /// earned its place by being the fast option, and that distinction is
        /// gone: `LocalTemplateArtifactCorrector` and `GradientTemplateCorrector`
        /// are both GPU-backed, and MAS now corrects a 64-channel ten-minute
        /// recording in about a tenth of a second — faster than this ever was.
        /// The default method is now Allen AAS, which is the same family done
        /// closer to the published description; MAS is the nearer match if what
        /// you want is specifically a local-neighbour template.
        ///
        /// Kept, not deleted: eva.xml files that select `AAS` must keep
        /// reproducing, so this preset still runs when one asks for it. Do not
        /// build anything new on it.
        case evaLocal
        /// Allen et al.-style imaging artifact reduction: fixed sections,
        /// running-template correlation gating, optional timing interpolation,
        /// and optional adaptive noise cancellation.
        case allenIAR

        var id: String { rawValue }
    }

    enum EpochUnit: String, CaseIterable, Identifiable, Sendable {
        case volume
        case slice

        var id: String { rawValue }
    }

    enum TemplateWindow: Sendable, Equatable {
        case localNeighbors(before: Int, after: Int)
        case fixedSections(epochCount: Int)
    }

    enum DetrendMode: String, CaseIterable, Identifiable, Sendable {
        case none
        case constant
        case linear

        var id: String { rawValue }
    }

    enum TimingInterpolation: Sendable, Equatable {
        case none
        /// Upsample internally with EVA's windowed-sinc resampler before
        /// building and subtracting templates. This gives the same practical
        /// purpose as Allen et al.'s sinc interpolation to the slice-timing
        /// signal, while keeping the implementation aligned with EVA's clean
        /// resampling primitive.
        case sinc(upsampleFactor: Int)
    }

    struct Config: Sendable {
        var preset: Preset
        var epochUnit: EpochUnit
        var slicesPerVolume: Int
        var relativeTriggerPosition: Double
        var templateWindow: TemplateWindow
        var detrendMode: DetrendMode
        var timingInterpolation: TimingInterpolation
        var correlationGate: Double?
        var alwaysIncludeInitialEpochs: Int
        var anc: Bool
        var ancHighPass: GradientANC.HighPassPolicy
        var ancFilterLength: Int
        var ancStepSize: Double
        /// Volumes that are still corrected but never contribute to a template.
        ///
        /// Same rule as the FASTR family: a volume the user has censored, or one
        /// the motion file marks as high-motion, is a bad thing to average into
        /// a template but still needs its own artifact removed. Allen's
        /// correlation gate rejects epochs that do not match the running
        /// template, which catches some of the same cases, but it is inferred
        /// from the data rather than told — an explicit censor list is the user
        /// saying so.
        var censoredVolumes: Set<Int> = []

        /// **Deprecated** — see `Preset.evaLocal`. Reachable only through replay
        /// of a file that selects `AAS`.
        static var evaLocal: Config {
            // Novel implementation by J. Teves & P. Molfese, NIH.
            Config(
                preset: .evaLocal,
                epochUnit: .volume,
                slicesPerVolume: 1,
                relativeTriggerPosition: 0,
                templateWindow: .localNeighbors(before: 4, after: 4),
                detrendMode: .linear,
                timingInterpolation: .none,
                correlationGate: nil,
                alwaysIncludeInitialEpochs: 0,
                anc: false,
                ancHighPass: .fixed2Hz,
                ancFilterLength: 32,
                ancStepSize: 0.01
            )
        }

        static var allenIARVolume: Config {
            Config(
                preset: .allenIAR,
                epochUnit: .volume,
                slicesPerVolume: 1,
                relativeTriggerPosition: 0,
                templateWindow: .fixedSections(epochCount: 25),
                detrendMode: .none,
                timingInterpolation: .sinc(upsampleFactor: 1),
                correlationGate: 0.975,
                alwaysIncludeInitialEpochs: 5,
                anc: true,
                ancHighPass: .fixed2Hz,
                ancFilterLength: 32,
                ancStepSize: 0.01
            )
        }

        static func allenIARSlice(slicesPerVolume: Int, samplingRate: Double, trSeconds: Double?) -> Config {
            let slices = max(1, slicesPerVolume)
            let epochRate: Double
            if let trSeconds, trSeconds > 0 {
                epochRate = Double(slices) / trSeconds
            } else {
                epochRate = 100.0 / 7.5
            }
            let epochs = max(25, Int((7.5 * epochRate).rounded()))
            return Config(
                preset: .allenIAR,
                epochUnit: .slice,
                slicesPerVolume: slices,
                relativeTriggerPosition: 0,
                templateWindow: .fixedSections(epochCount: epochs),
                detrendMode: .none,
                timingInterpolation: .sinc(upsampleFactor: 1),
                correlationGate: 0.975,
                alwaysIncludeInitialEpochs: 5,
                anc: true,
                ancHighPass: .sliceTriggerDependent,
                ancFilterLength: 32,
                ancStepSize: 0.01
            )
        }
    }

    static func correct(
        channels: [[Float]],
        volumeTriggers: [Int],
        config: Config,
        samplingRate: Double,
        progress: (Double) -> Void = { _ in }
    ) throws -> GradientCorrectionResult {

        guard !channels.isEmpty else { throw GradientCorrectionError.noChannels }
        let sampleCount = channels[0].count
        guard sampleCount > 0 else { throw GradientCorrectionError.emptyChannels }
        guard channels.allSatisfy({ $0.count == sampleCount }) else {
            throw GradientCorrectionError.mismatchedChannelLengths
        }
        guard samplingRate > 0 else {
            throw GradientCorrectionError.invalidConfiguration("samplingRate must be positive")
        }
        guard (0...1).contains(config.relativeTriggerPosition) else {
            throw GradientCorrectionError.invalidConfiguration("relativeTriggerPosition must be between 0 and 1")
        }

        let upsampleFactor: Int
        switch config.timingInterpolation {
        case .none:
            upsampleFactor = 1
        case .sinc(let factor):
            upsampleFactor = max(1, factor)
        }

        let layout = try GradientEpochLayout.build(
            volumeTriggers: volumeTriggers,
            sampleCount: sampleCount,
            slicesPerVolume: config.epochUnit == .slice ? max(1, config.slicesPerVolume) : 1,
            upsampleFactor: upsampleFactor,
            relativeTriggerPosition: config.relativeTriggerPosition
        )

        let workingChannels = upsampleFactor > 1
            ? channels.map { GradientSincResampler.upsample($0, factor: upsampleFactor) }
            : channels
        let workingRate = samplingRate * Double(upsampleFactor)
        let representative = 0

        var correctedWorking = workingChannels
        var artifactWorking = workingChannels.map { [Float](repeating: 0, count: $0.count) }
        var diagnostics: [GradientEpochDiagnostic] = []
        var warnings: [GradientCorrectionWarning] = []
        var ancApplied: Set<Int> = []

        let correctionPlans = buildPlans(
            channels: workingChannels,
            layout: layout,
            config: config
        )
        let units = max(1, workingChannels.count)

        // Channels are independent right up to the diagnostics, so the whole
        // per-channel body runs concurrently and its side effects — warnings,
        // the representative channel's epoch records, and the ANC-applied set —
        // are collected per channel and merged in channel order afterwards.
        // Scheduling changes; arithmetic does not.
        var channelWarnings = [[GradientCorrectionWarning]](repeating: [], count: workingChannels.count)
        var channelDiagnostics = [[GradientEpochDiagnostic]](repeating: [], count: workingChannels.count)
        var channelANCApplied = [Bool](repeating: false, count: workingChannels.count)
        let progressLock = NSLock()
        nonisolated(unsafe) var completedChannels = 0

        correctedWorking.withUnsafeMutableBufferPointer { correctedBuffer in
        let correctedOut = GradientUnsafeSendable(base: correctedBuffer.baseAddress!)
        artifactWorking.withUnsafeMutableBufferPointer { artifactBuffer in
        let artifactOut = GradientUnsafeSendable(base: artifactBuffer.baseAddress!)
        channelWarnings.withUnsafeMutableBufferPointer { warningBuffer in
        let warningOut = GradientUnsafeSendable(base: warningBuffer.baseAddress!)
        channelDiagnostics.withUnsafeMutableBufferPointer { diagnosticBuffer in
        let diagnosticOut = GradientUnsafeSendable(base: diagnosticBuffer.baseAddress!)
        channelANCApplied.withUnsafeMutableBufferPointer { ancBuffer in
        let ancOut = GradientUnsafeSendable(base: ancBuffer.baseAddress!)

        evaConcurrentPerform(iterations: workingChannels.count) { channelIndex in
            var warnings: [GradientCorrectionWarning] = []
            var diagnostics: [GradientEpochDiagnostic] = []
            let channel = workingChannels[channelIndex]

            // Every epoch is detrended once and reused, rather than re-detrended
            // each time it is someone's donor. With a donor window of eight that
            // was nine passes over the same samples; the values are identical
            // either way, so this is pure redundancy.
            var epochCache = [[Float]?](repeating: nil, count: layout.count)
            for epoch in 0..<layout.count {
                guard let epochStart = layout.windowStart(of: epoch) else { continue }
                epochCache[epoch] = preprocess(
                    Array(channel[epochStart..<(epochStart + layout.length)]),
                    mode: config.detrendMode
                )
            }
            let plans = correctionPlans[channelIndex]
            var corrected = channel
            var artifact = [Float](repeating: 0, count: channel.count)

            for plan in plans {
                guard let start = layout.windowStart(of: plan.epoch) else {
                    warnings.append(.epochOutOfBounds(epoch: plan.epoch))
                    if channelIndex == representative {
                        diagnostics.append(diagnostic(
                            epoch: plan.epoch,
                            layout: layout,
                            donors: [],
                            corrected: false
                        ))
                    }
                    continue
                }
                guard !plan.donorIndices.isEmpty else {
                    warnings.append(.noEligibleDonors(epoch: plan.epoch))
                    if channelIndex == representative {
                        diagnostics.append(diagnostic(
                            epoch: plan.epoch,
                            layout: layout,
                            donors: [],
                            corrected: false
                        ))
                    }
                    continue
                }

                guard let target = epochCache[plan.epoch] else { continue }
                let donorEpochs = plan.donorIndices.compactMap { epochCache[$0] }
                guard !donorEpochs.isEmpty else {
                    warnings.append(.noEligibleDonors(epoch: plan.epoch))
                    continue
                }

                let template = meanTemplate(donorEpochs)
                let energy = template.reduce(0.0) { $0 + Double($1 * $1) }
                guard energy > 1e-12 else {
                    warnings.append(.degenerateTemplate(epoch: plan.epoch))
                    continue
                }

                let length = vDSP_Length(layout.length)
                template.withUnsafeBufferPointer { source in
                    artifact.withUnsafeMutableBufferPointer { destination in
                        let slot = destination.baseAddress! + start
                        vDSP_vadd(slot, 1, source.baseAddress!, 1, slot, 1, length)
                    }
                    target.withUnsafeBufferPointer { targetValues in
                        corrected.withUnsafeMutableBufferPointer { destination in
                            vDSP_vsub(
                                source.baseAddress!, 1,
                                targetValues.baseAddress!, 1,
                                destination.baseAddress! + start, 1,
                                length
                            )
                        }
                    }
                }

                if channelIndex == representative {
                    diagnostics.append(diagnostic(
                        epoch: plan.epoch,
                        layout: layout,
                        donors: plan.donorIndices,
                        corrected: true
                    ))
                }
            }

            if config.anc {
                let cutoff = GradientANC.cutoffHz(
                    policy: config.ancHighPass,
                    epochPeriodSamples: max(1, layout.period),
                    samplingRate: workingRate
                )
                let anc = GradientANC.apply(
                    cleaned: corrected,
                    reference: artifact,
                    cutoffHz: cutoff,
                    samplingRate: workingRate,
                    filterLength: config.ancFilterLength,
                    stepSize: config.ancStepSize
                )
                if anc.applied {
                    corrected = anc.output
                    ancOut.base[channelIndex] = true
                } else {
                    warnings.append(.ancSkippedForUninformativeReference(channel: channelIndex))
                }
            }

            correctedOut.base[channelIndex] = corrected
            artifactOut.base[channelIndex] = artifact
            warningOut.base[channelIndex] = warnings
            diagnosticOut.base[channelIndex] = diagnostics
            progressLock.lock()
            completedChannels += 1
            let done = completedChannels
            progressLock.unlock()
            progress(Double(done) / Double(units))
        }

        } } } } }

        for channelIndex in workingChannels.indices {
            warnings.append(contentsOf: channelWarnings[channelIndex])
            if channelANCApplied[channelIndex] { ancApplied.insert(channelIndex) }
        }
        diagnostics.append(contentsOf: channelDiagnostics[representative])

        let output: [[Float]]
        if upsampleFactor > 1 {
            output = correctedWorking.map { downsample($0, factor: upsampleFactor, targetCount: sampleCount) }
        } else {
            output = correctedWorking
        }

        return GradientCorrectionResult(
            channels: output,
            diagnostics: GradientCorrectionDiagnostics(
                epochCount: layout.count,
                period: layout.period,
                samplesBefore: layout.samplesBefore,
                samplesAfter: layout.samplesAfter,
                referenceChannel: representative,
                computeBackend: .cpu,
                highMotionVolumes: [],
                epochs: diagnostics.sorted { $0.epoch < $1.epoch },
                obsComponentCounts: [],
                ancAppliedChannels: ancApplied,
                warnings: warnings
            )
        )
    }

    private struct EpochPlan {
        let epoch: Int
        let donorIndices: [Int]
    }

    private static func buildPlans(
        channels: [[Float]],
        layout: GradientEpochLayout,
        config: Config
    ) -> [[EpochPlan]] {
        channels.map { channel in
            var plans: [EpochPlan] = []
            plans.reserveCapacity(layout.count)
            switch config.templateWindow {
            case .localNeighbors(let before, let after):
                for epoch in 0..<layout.count {
                    guard layout.windowStart(of: epoch) != nil else {
                        plans.append(EpochPlan(epoch: epoch, donorIndices: []))
                        continue
                    }
                    let lo = max(0, epoch - max(0, before))
                    let hi = min(layout.count - 1, epoch + max(0, after))
                    let donors = (lo...hi).filter {
                        $0 != epoch
                            && layout.windowStart(of: $0) != nil
                            && !config.censoredVolumes.contains(layout.volumeIndex[$0])
                    }
                    plans.append(EpochPlan(epoch: epoch, donorIndices: donors))
                }

            case .fixedSections(let epochCount):
                let sectionLength = max(1, epochCount)
                var sectionStart = 0
                while sectionStart < layout.count {
                    let sectionEnd = min(layout.count, sectionStart + sectionLength)
                    let section = Array(sectionStart..<sectionEnd)
                    let validSection = section.filter {
                        layout.windowStart(of: $0) != nil
                            && !config.censoredVolumes.contains(layout.volumeIndex[$0])
                    }
                    let donors = acceptedSectionDonors(
                        validSection,
                        channel: channel,
                        layout: layout,
                        config: config
                    )
                    for epoch in section {
                        plans.append(EpochPlan(
                            epoch: epoch,
                            donorIndices: donors.filter { $0 != epoch }
                        ))
                    }
                    sectionStart = sectionEnd
                }
            }
            return plans
        }
    }

    private static func acceptedSectionDonors(
        _ candidates: [Int],
        channel: [Float],
        layout: GradientEpochLayout,
        config: Config
    ) -> [Int] {
        guard let gate = config.correlationGate else { return candidates }
        guard !candidates.isEmpty else { return [] }

        var accepted: [Int] = []
        var runningTemplate: [Float]?

        for candidate in candidates {
            guard let start = layout.windowStart(of: candidate) else { continue }
            let epoch = preprocess(
                Array(channel[start..<(start + layout.length)]),
                mode: config.detrendMode
            )

            if accepted.count < max(0, config.alwaysIncludeInitialEpochs) || runningTemplate == nil {
                accepted.append(candidate)
                runningTemplate = runningTemplate.map { meanUpdating($0, count: accepted.count - 1, next: epoch) } ?? epoch
                continue
            }

            let r = pearson(epoch, runningTemplate ?? epoch)
            if r >= gate {
                accepted.append(candidate)
                runningTemplate = meanUpdating(runningTemplate ?? epoch, count: accepted.count - 1, next: epoch)
            }
        }

        return accepted
    }

    private static func diagnostic(
        epoch: Int,
        layout: GradientEpochLayout,
        donors: [Int],
        corrected: Bool
    ) -> GradientEpochDiagnostic {
        GradientEpochDiagnostic(
            epoch: epoch,
            trigger: layout.triggers[epoch],
            volume: layout.volumeIndex[epoch],
            slicePosition: layout.slicePosition[epoch],
            integerShift: 0,
            fractionalShift: 0,
            donorIndices: donors,
            templateScale: 1,
            corrected: corrected
        )
    }

    private static func preprocess(_ values: [Float], mode: DetrendMode) -> [Float] {
        switch mode {
        case .none:
            return values
        case .constant:
            guard !values.isEmpty else { return values }
            let mean = values.reduce(Float(0), +) / Float(values.count)
            return values.map { $0 - mean }
        case .linear:
            return linearDetrend(values)
        }
    }

    private static func meanTemplate(_ epochs: [[Float]]) -> [Float] {
        guard let length = epochs.first?.count, length > 0 else { return [] }
        var result = [Float](repeating: 0, count: length)
        result.withUnsafeMutableBufferPointer { accumulator in
            let destination = accumulator.baseAddress!
            for epoch in epochs {
                epoch.withUnsafeBufferPointer { source in
                    vDSP_vadd(destination, 1, source.baseAddress!, 1, destination, 1, vDSP_Length(length))
                }
            }
            var scale = Float(epochs.count)
            vDSP_vsdiv(destination, 1, &scale, destination, 1, vDSP_Length(length))
        }
        return result
    }

    private static func meanUpdating(_ current: [Float], count: Int, next: [Float]) -> [Float] {
        guard current.count == next.count, count > 0 else { return next }
        let denominator = Float(count + 1)
        return zip(current, next).map { ($0.0 * Float(count) + $0.1) / denominator }
    }

    private static func pearson(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let meanA = Double(a.reduce(0, +)) / Double(a.count)
        let meanB = Double(b.reduce(0, +)) / Double(b.count)
        var aa = 0.0
        var bb = 0.0
        var ab = 0.0
        for i in a.indices {
            let da = Double(a[i]) - meanA
            let db = Double(b[i]) - meanB
            aa += da * da
            bb += db * db
            ab += da * db
        }
        let denom = (aa * bb).squareRoot()
        guard denom > 1e-12 else { return 0 }
        return ab / denom
    }

    private static func downsample(_ values: [Float], factor: Int, targetCount: Int) -> [Float] {
        var decimated = GradientSincResampler.decimate(values, factor: factor)
        if decimated.count > targetCount {
            decimated.removeLast(decimated.count - targetCount)
        } else if decimated.count < targetCount {
            decimated.append(contentsOf: repeatElement(decimated.last ?? 0, count: targetCount - decimated.count))
        }
        return decimated
    }

    private static func linearDetrend(_ values: [Float]) -> [Float] {
        let count = values.count
        guard count > 1 else { return values }
        let n = Float(count)
        let sumX = Float(count - 1) * n / 2
        let sumXX = Float(count - 1) * Float(count) * Float(2 * count - 1) / 6
        var sumY = Float(0)
        vDSP_sve(values, 1, &sumY, vDSP_Length(count))

        var ramp = [Float](repeating: 0, count: count)
        var rampStart = Float(0)
        var rampStep = Float(1)
        vDSP_vramp(&rampStart, &rampStep, &ramp, 1, vDSP_Length(count))
        var sumXY = Float(0)
        vDSP_dotpr(values, 1, ramp, 1, &sumXY, vDSP_Length(count))

        let denom = n * sumXX - sumX * sumX
        guard abs(denom) > 1e-12 else { return values }
        let slope = (n * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / n

        // The fitted line as a ramp, subtracted in one pass.
        var line = [Float](repeating: 0, count: count)
        var lineStart = intercept
        var lineStep = slope
        vDSP_vramp(&lineStart, &lineStep, &line, 1, vDSP_Length(count))
        var detrended = [Float](repeating: 0, count: count)
        vDSP_vsub(line, 1, values, 1, &detrended, 1, vDSP_Length(count))
        return detrended
    }
}
