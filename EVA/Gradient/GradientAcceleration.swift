//
//  GradientAcceleration.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Port of EVA's own clean-room gradient corrector onto a pluggable compute
//  backend, per docs/provenance/fastr-gpu-port-plan.md. No third-party
//  artifact-correction source was consulted, and no part of EVA's earlier ported
//  Metal backend was read while writing this.
//
//  The seam is at the level of *stages*, not one monolithic GPU path, so a parity
//  failure can be bisected to a single kernel and mixed CPU/GPU pipelines are
//  possible.
//
//  Two rules shape every type here.
//
//    1. The CPU owns every decision; a backend owns only arithmetic. Donor
//       ranking, component counts, scale rejection, chunk skipping and the ANC
//       go/no-go all live in `GradientTemplateCorrector`, driven by values that
//       are deterministically rounded before they are compared. A backend
//       returns dense intermediates and nothing else.
//    2. Every stage is batched across channels by contract. `GradientCPUBackend`
//       satisfies that by looping channels — which is why its arithmetic, and so
//       its output, is unchanged from the single-threaded implementation — while
//       a GPU backend can saturate the device with one dispatch.
//

import Foundation

// MARK: - Backend selection

/// Which compute backend runs the dense stages of gradient correction.
nonisolated enum GradientComputeBackend: String, CaseIterable, Identifiable, Sendable {
    /// Straight Swift, parallel across channels. The definition of correct.
    case cpu
    /// Metal compute kernels, batched across channels. Falls back to `.cpu`
    /// silently when no usable device is present or the recording is too small
    /// for the round trip to pay for itself.
    case metal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .metal: return "GPU (Metal)"
        }
    }
}

// MARK: - Batch geometry

/// Everything about the epoch grid that does not depend on which channel is
/// being corrected. Built once per run and handed to every stage.
///
/// All sample indices are on the **upsampled** axis.
nonisolated struct GradientBatchPlan: Sendable {
    /// Samples per channel before upsampling.
    let sampleCount: Int
    let upsampleFactor: Int
    let epochCount: Int
    /// Epoch window length, `layout.length`.
    let windowLength: Int
    /// First upsampled sample of each epoch's window, or -1 when the shifted
    /// window falls outside the recording.
    let windowStarts: [Int]
    /// Per-epoch sub-sample offset, already zeroed when sub-sample alignment is
    /// off, so a backend never has to consult the configuration.
    let fractionalShifts: [Double]

    var upsampledCount: Int { sampleCount * upsampleFactor }

    func isInBounds(_ epoch: Int) -> Bool { windowStarts[epoch] >= 0 }

    /// Matches the corrector's own test: an offset this small is not worth a
    /// resampling pass and would only add interpolation error.
    func appliesFractionalDelay(_ epoch: Int) -> Bool {
        abs(fractionalShifts[epoch]) > 1e-9
    }

    var hasAnyFractionalDelay: Bool {
        fractionalShifts.contains { abs($0) > 1e-9 }
    }

    /// Floats in one `channel x epoch x sample` buffer for `channels` channels.
    func epochBufferCount(channels: Int) -> Int {
        channels * epochCount * windowLength
    }
}

/// One (target, candidate) correlation to evaluate. The pair list depends only
/// on the layout and on epoch eligibility, both of which are channel-independent,
/// so it is built once and evaluated for every channel at once.
nonisolated struct GradientEpochPair: Sendable {
    let target: Int32
    let candidate: Int32
}

/// Donor epochs per `(channel, epoch)` slot, flattened.
///
/// `offsets` has `channelCount * epochCount + 1` entries; the donors for slot
/// `channel * epochCount + epoch` are `indices[offsets[slot] ..< offsets[slot + 1]]`.
nonisolated struct GradientDonorTable: Sendable {
    let offsets: [Int32]
    let indices: [Int32]
}

/// One OBS chunk's detrended residual epochs, as a slice of a concatenated
/// buffer. Jobs are ragged — chunks differ in how many epochs survived — so each
/// carries its own size.
nonisolated struct GradientGramJob: Sendable {
    /// Offset into the concatenated detrended buffer, in floats.
    let offset: Int
    /// Number of residual epochs in this job.
    let size: Int
}

/// A dense `channel x epoch x sample` intermediate that stays wherever it was
/// produced.
///
/// The driver never reads one of these — it hands the box straight back to the
/// backend that made it. That keeps the CPU backend's `Double` templates exact
/// without forcing a GPU backend to round-trip every buffer through host memory
/// between stages, which for a 64-channel recording is hundreds of megabytes of
/// traffic that buys nothing.
nonisolated final class GradientDeviceBuffer: @unchecked Sendable {
    let storage: AnyObject
    init(_ storage: AnyObject) { self.storage = storage }
}

/// Templates and the two scalars the CPU needs to decide a scale from them.
nonisolated final class GradientTemplateBatch: @unchecked Sendable {
    /// `channel * epochCount + epoch`. False when the epoch had no window, no
    /// donors, or a template carrying no energy.
    let present: [Bool]
    /// `dot(template, template)` per slot. Zero where absent.
    let energies: [Double]
    /// `dot(target, template)` per slot. Zero where absent.
    let projections: [Double]
    let templates: GradientDeviceBuffer

    init(
        present: [Bool],
        energies: [Double],
        projections: [Double],
        templates: GradientDeviceBuffer
    ) {
        self.present = present
        self.energies = energies
        self.projections = projections
        self.templates = templates
    }
}

/// What template subtraction leaves behind, and what it takes away.
nonisolated struct GradientResidualBatch {
    /// `(channel * epochCount + epoch) * windowLength + index`, on the shared
    /// aligned grid, so OBS can compare shapes across epochs. Empty when the
    /// caller said it did not need them — only OBS does, and reading them back
    /// from a device is not free.
    let residuals: [Float]
    /// Same layout, but re-phased onto each epoch's own sub-sample grid. This is
    /// what gets subtracted from the recording.
    let estimates: GradientDeviceBuffer
}

nonisolated struct GradientANCRequest: Sendable {
    let cutoffHz: Double
    let samplingRate: Double
    let filterLength: Int
    let stepSize: Double
}

// MARK: - The stage seam

/// One accelerated stage per method. Every method is batched across channels and
/// free of discrete decisions; see the file header.
nonisolated protocol GradientBackend: AnyObject {
    var backend: GradientComputeBackend { get }

    /// Channels this backend can hold in flight at once without exceeding its
    /// memory budget. The driver tiles the recording to this width.
    func maximumTileChannels(plan: GradientBatchPlan) -> Int

    /// Upsamples each channel and lifts every epoch window onto the shared
    /// aligned grid, applying each epoch's integer shift and sub-sample delay.
    ///
    /// - Returns: `channels.count * epochCount * windowLength` values,
    ///   channel-major, zero where the epoch's window is out of bounds.
    func extractEpochWindows(
        channels: [[Float]],
        plan: GradientBatchPlan
    ) throws -> GradientDeviceBuffer

    /// Pearson correlation of every `(channel, pair)` combination.
    ///
    /// - Returns: `channelCount * pairs.count` values, channel-major.
    func epochCorrelations(
        pairs: [GradientEpochPair],
        windows: GradientDeviceBuffer,
        channelCount: Int,
        plan: GradientBatchPlan
    ) throws -> [Double]

    /// Donor-average template, its energy, and the target's projection onto it,
    /// for every `(channel, epoch)`.
    func buildTemplates(
        windows: GradientDeviceBuffer,
        donors: GradientDonorTable,
        channelCount: Int,
        plan: GradientBatchPlan
    ) throws -> GradientTemplateBatch

    /// Residual and re-phased artifact estimate for every `(channel, epoch)`,
    /// given the scales the driver resolved.
    func residualsAndEstimates(
        windows: GradientDeviceBuffer,
        templates: GradientTemplateBatch,
        scales: [Double],
        channelCount: Int,
        plan: GradientBatchPlan,
        needsResiduals: Bool
    ) throws -> GradientResidualBatch

    /// Epoch-by-epoch Gram matrix of each job's detrended residuals.
    ///
    /// Returned as `Double` even from a float backend: the eigenvalue ratios
    /// drive a discrete component count, so the decomposition stays on the CPU
    /// and must not be fed a silently narrowed matrix.
    func gramMatrices(
        jobs: [GradientGramJob],
        detrended: [Float],
        windowLength: Int
    ) throws -> [[Double]]

    /// Gathers the per-epoch estimates into one artifact estimate, averages where
    /// adjacent epochs overlap, decimates back to the recorded rate, and
    /// subtracts.
    ///
    /// Samples no epoch covers must come out of this bit-identical to `inputs`.
    func assembleCorrection(
        inputs: [[Float]],
        estimates: GradientDeviceBuffer,
        obsContributions: [Float]?,
        present: [Bool],
        plan: GradientBatchPlan
    ) throws -> (cleaned: [[Float]], artifact: [[Float]])

    /// Normalized-LMS adaptive noise cancellation, one independent stream per
    /// channel.
    func adaptiveNoiseCancel(
        cleaned: [[Float]],
        references: [[Float]],
        request: GradientANCRequest
    ) throws -> [GradientANC.Result]
}

// MARK: - Shared helpers

/// A pointer that may cross a `concurrentPerform` boundary. Every use in this
/// file writes to a disjoint per-channel range, so the aliasing the compiler
/// cannot prove is genuinely absent.
nonisolated struct GradientUnsafeSendable<T>: @unchecked Sendable {
    let base: UnsafeMutablePointer<T>
}

nonisolated struct GradientUnsafeSendableConst<T>: @unchecked Sendable {
    let base: UnsafePointer<T>
}

nonisolated enum GradientParallel {
    /// Runs `body` once per independent unit of work — a channel, or an OBS job —
    /// concurrently when that is worth doing.
    ///
    /// Every caller here writes to a disjoint range, so this changes scheduling
    /// and nothing else: each unit's arithmetic, and therefore its output, is
    /// identical to the serial order.
    static func forEach(_ count: Int, _ body: @Sendable (Int) -> Void) {
        guard count > 1 else {
            if count == 1 { body(0) }
            return
        }
        DispatchQueue.concurrentPerform(iterations: count, execute: body)
    }
}

// MARK: - CPU backend

/// The reference implementation. Every loop here is the corrector's original
/// arithmetic in its original order, so this backend defines what correct means
/// and a GPU backend is measured against it.
///
/// Parallelism here is across channels only. Channels are independent all the way
/// to the diagnostics, so `concurrentPerform` changes scheduling and nothing
/// else. Nothing inside a channel is vectorised, deliberately: `vDSP` reassociates
/// sums, and a reference implementation that drifts is not one.
nonisolated final class GradientCPUBackend: GradientBackend {

    /// Boxes a flat host array between stages.
    fileprivate final class HostBuffer<Element> {
        let values: [Element]
        init(_ values: [Element]) { self.values = values }
    }

    static let shared = GradientCPUBackend()

    var backend: GradientComputeBackend { .cpu }

    /// The CPU holds one channel's intermediates at a time regardless of tile
    /// width, so there is nothing to bound.
    func maximumTileChannels(plan: GradientBatchPlan) -> Int { .max }

    private func floats(_ buffer: GradientDeviceBuffer, stage: String) throws -> [Float] {
        guard let box = buffer.storage as? HostBuffer<Float> else {
            throw GradientCorrectionError.backendFailure(
                "\(stage) received a buffer from a different compute backend"
            )
        }
        return box.values
    }

    func extractEpochWindows(
        channels: [[Float]],
        plan: GradientBatchPlan
    ) throws -> GradientDeviceBuffer {
        let channelCount = channels.count
        let epochCount = plan.epochCount
        let length = plan.windowLength
        var output = [Float](repeating: 0, count: plan.epochBufferCount(channels: channelCount))
        guard channelCount > 0, epochCount > 0, length > 0 else {
            return GradientDeviceBuffer(HostBuffer(output))
        }

        output.withUnsafeMutableBufferPointer { buffer in
            let out = GradientUnsafeSendable(base: buffer.baseAddress!)
            GradientParallel.forEach(channelCount) { channel in
                let upsampled = GradientSincResampler.upsample(
                    channels[channel],
                    factor: plan.upsampleFactor
                )
                for epoch in 0..<epochCount {
                    let start = plan.windowStarts[epoch]
                    guard start >= 0 else { continue }
                    var window = Array(upsampled[start..<(start + length)])
                    let offset = plan.fractionalShifts[epoch]
                    if abs(offset) > 1e-9 {
                        window = GradientSincResampler.fractionalDelay(window, by: -offset)
                    }
                    let base = (channel * epochCount + epoch) * length
                    for index in 0..<length { out.base[base + index] = window[index] }
                }
            }
        }
        return GradientDeviceBuffer(HostBuffer(output))
    }

    func epochCorrelations(
        pairs: [GradientEpochPair],
        windows: GradientDeviceBuffer,
        channelCount: Int,
        plan: GradientBatchPlan
    ) throws -> [Double] {
        let source = try floats(windows, stage: "epochCorrelations")
        let pairCount = pairs.count
        let epochCount = plan.epochCount
        let length = plan.windowLength
        var output = [Double](repeating: 0, count: channelCount * pairCount)
        guard channelCount > 0, pairCount > 0 else { return output }

        source.withUnsafeBufferPointer { sourceBuffer in
            let windows = GradientUnsafeSendableConst(base: sourceBuffer.baseAddress!)
            output.withUnsafeMutableBufferPointer { buffer in
                let out = GradientUnsafeSendable(base: buffer.baseAddress!)
                GradientParallel.forEach(channelCount) { channel in
                    let channelBase = channel * epochCount * length
                    for index in 0..<pairCount {
                        let a = windows.base + channelBase + Int(pairs[index].target) * length
                        let b = windows.base + channelBase + Int(pairs[index].candidate) * length
                        out.base[channel * pairCount + index] =
                            GradientDonorSelection.pearsonCorrelation(a, b, count: length)
                    }
                }
            }
        }
        return output
    }

    func buildTemplates(
        windows: GradientDeviceBuffer,
        donors: GradientDonorTable,
        channelCount: Int,
        plan: GradientBatchPlan
    ) throws -> GradientTemplateBatch {
        let source = try floats(windows, stage: "buildTemplates")
        let epochCount = plan.epochCount
        let length = plan.windowLength
        let slotCount = channelCount * epochCount
        var templates = [Double](repeating: 0, count: slotCount * length)
        var present = [Bool](repeating: false, count: slotCount)
        var energies = [Double](repeating: 0, count: slotCount)
        var projections = [Double](repeating: 0, count: slotCount)
        guard slotCount > 0, length > 0 else {
            return GradientTemplateBatch(
                present: present, energies: energies, projections: projections,
                templates: GradientDeviceBuffer(HostBuffer(templates))
            )
        }

        source.withUnsafeBufferPointer { sourceBuffer in
            let windows = GradientUnsafeSendableConst(base: sourceBuffer.baseAddress!)
            templates.withUnsafeMutableBufferPointer { templateBuffer in
                let templates = GradientUnsafeSendable(base: templateBuffer.baseAddress!)
                present.withUnsafeMutableBufferPointer { presentBuffer in
                    let present = GradientUnsafeSendable(base: presentBuffer.baseAddress!)
                    energies.withUnsafeMutableBufferPointer { energyBuffer in
                        let energies = GradientUnsafeSendable(base: energyBuffer.baseAddress!)
                        projections.withUnsafeMutableBufferPointer { projectionBuffer in
                            let projections = GradientUnsafeSendable(base: projectionBuffer.baseAddress!)
                            GradientParallel.forEach(channelCount) { channel in
                                for epoch in 0..<epochCount {
                                    let slot = channel * epochCount + epoch
                                    let first = Int(donors.offsets[slot])
                                    let last = Int(donors.offsets[slot + 1])
                                    guard last > first else { continue }

                                    let template = templates.base + slot * length
                                    for cursor in first..<last {
                                        let donor = windows.base
                                            + (channel * epochCount + Int(donors.indices[cursor])) * length
                                        for index in 0..<length {
                                            template[index] += Double(donor[index])
                                        }
                                    }
                                    let inverse = 1.0 / Double(last - first)
                                    for index in 0..<length { template[index] *= inverse }

                                    // The template describes the artifact's shape;
                                    // projecting the target onto it recovers this
                                    // epoch's amplitude.
                                    let target = windows.base + slot * length
                                    var energy = 0.0
                                    var projection = 0.0
                                    for index in 0..<length {
                                        energy += template[index] * template[index]
                                        projection += Double(target[index]) * template[index]
                                    }
                                    guard energy > 1e-20 else { continue }
                                    present.base[slot] = true
                                    energies.base[slot] = energy
                                    projections.base[slot] = projection
                                }
                            }
                        }
                    }
                }
            }
        }

        return GradientTemplateBatch(
            present: present,
            energies: energies,
            projections: projections,
            templates: GradientDeviceBuffer(HostBuffer(templates))
        )
    }

    func residualsAndEstimates(
        windows: GradientDeviceBuffer,
        templates: GradientTemplateBatch,
        scales: [Double],
        channelCount: Int,
        plan: GradientBatchPlan,
        needsResiduals: Bool
    ) throws -> GradientResidualBatch {
        let source = try floats(windows, stage: "residualsAndEstimates")
        guard let storage = templates.templates.storage as? HostBuffer<Double> else {
            throw GradientCorrectionError.backendFailure(
                "template batch was produced by a different compute backend"
            )
        }
        let epochCount = plan.epochCount
        let length = plan.windowLength
        let slotCount = channelCount * epochCount
        // Sized to 1 rather than 0 when unwanted, so the pointer below is valid.
        var residuals = [Float](repeating: 0, count: needsResiduals ? slotCount * length : 1)
        var estimates = [Float](repeating: 0, count: slotCount * length)
        guard slotCount > 0, length > 0 else {
            return GradientResidualBatch(
                residuals: [],
                estimates: GradientDeviceBuffer(HostBuffer(estimates))
            )
        }

        source.withUnsafeBufferPointer { windowBuffer in
            let windows = GradientUnsafeSendableConst(base: windowBuffer.baseAddress!)
            storage.values.withUnsafeBufferPointer { templateBuffer in
                let allTemplates = GradientUnsafeSendableConst(base: templateBuffer.baseAddress!)
                residuals.withUnsafeMutableBufferPointer { residualBuffer in
                    let residuals = GradientUnsafeSendable(base: residualBuffer.baseAddress!)
                    estimates.withUnsafeMutableBufferPointer { estimateBuffer in
                        let estimates = GradientUnsafeSendable(base: estimateBuffer.baseAddress!)
                        GradientParallel.forEach(channelCount) { channel in
                            for epoch in 0..<epochCount {
                                let slot = channel * epochCount + epoch
                                guard templates.present[slot] else { continue }
                                let scale = scales[slot]
                                let template = allTemplates.base + slot * length
                                let target = windows.base + slot * length
                                let base = slot * length

                                if needsResiduals {
                                    for index in 0..<length {
                                        residuals.base[base + index] =
                                            target[index] - Float(template[index] * scale)
                                    }
                                }
                                var estimate = [Float](repeating: 0, count: length)
                                for index in 0..<length {
                                    estimate[index] = Float(template[index] * scale)
                                }
                                let offset = plan.fractionalShifts[epoch]
                                if abs(offset) > 1e-9 {
                                    // Put the estimate back on this epoch's own
                                    // sub-sample phase.
                                    estimate = GradientSincResampler.fractionalDelay(estimate, by: offset)
                                }
                                for index in 0..<length {
                                    estimates.base[base + index] = estimate[index]
                                }
                            }
                        }
                    }
                }
            }
        }

        return GradientResidualBatch(
            residuals: needsResiduals ? residuals : [],
            estimates: GradientDeviceBuffer(HostBuffer(estimates))
        )
    }

    func gramMatrices(
        jobs: [GradientGramJob],
        detrended: [Float],
        windowLength: Int
    ) throws -> [[Double]] {
        guard !jobs.isEmpty else { return [] }
        var results = [[Double]](repeating: [], count: jobs.count)
        results.withUnsafeMutableBufferPointer { buffer in
            let out = GradientUnsafeSendable(base: buffer.baseAddress!)
            detrended.withUnsafeBufferPointer { source in
                let values = GradientUnsafeSendableConst(base: source.baseAddress!)
                GradientParallel.forEach(jobs.count) { index in
                    let job = jobs[index]
                    let size = job.size
                    var gram = [Double](repeating: 0, count: size * size)
                    for row in 0..<size {
                        let a = values.base + job.offset + row * windowLength
                        for column in row..<size {
                            let b = values.base + job.offset + column * windowLength
                            var total = 0.0
                            for sample in 0..<windowLength {
                                total += Double(a[sample]) * Double(b[sample])
                            }
                            gram[row * size + column] = total
                            gram[column * size + row] = total
                        }
                    }
                    out.base[index] = gram
                }
            }
        }
        return results
    }

    func assembleCorrection(
        inputs: [[Float]],
        estimates: GradientDeviceBuffer,
        obsContributions: [Float]?,
        present: [Bool],
        plan: GradientBatchPlan
    ) throws -> (cleaned: [[Float]], artifact: [[Float]]) {
        let estimates = try floats(estimates, stage: "assembleCorrection")
        let channelCount = inputs.count
        let epochCount = plan.epochCount
        let length = plan.windowLength
        let sampleCount = plan.sampleCount
        let upsampledCount = plan.upsampledCount
        let factor = plan.upsampleFactor

        var cleaned = [[Float]](repeating: [], count: channelCount)
        var artifacts = [[Float]](repeating: [], count: channelCount)
        guard channelCount > 0 else { return (cleaned, artifacts) }

        cleaned.withUnsafeMutableBufferPointer { cleanedBuffer in
            let cleaned = GradientUnsafeSendable(base: cleanedBuffer.baseAddress!)
            artifacts.withUnsafeMutableBufferPointer { artifactBuffer in
                let artifacts = GradientUnsafeSendable(base: artifactBuffer.baseAddress!)
                GradientParallel.forEach(channelCount) { channel in
                    var artifact = [Float](repeating: 0, count: upsampledCount)
                    var coverage = [Int32](repeating: 0, count: upsampledCount)

                    for epoch in 0..<epochCount {
                        let slot = channel * epochCount + epoch
                        guard present[slot] else { continue }
                        let start = plan.windowStarts[epoch]
                        guard start >= 0 else { continue }
                        let base = slot * length
                        for index in 0..<length {
                            artifact[start + index] += estimates[base + index]
                            coverage[start + index] += 1
                        }
                    }

                    // OBS is accumulated in a second pass, after every template
                    // contribution, so the summation order does not depend on
                    // whether the stage ran.
                    if let obsContributions {
                        for epoch in 0..<epochCount {
                            let slot = channel * epochCount + epoch
                            guard present[slot] else { continue }
                            let start = plan.windowStarts[epoch]
                            guard start >= 0 else { continue }
                            let base = slot * length
                            for index in 0..<length {
                                artifact[start + index] += obsContributions[base + index]
                            }
                        }
                    }

                    // Adjacent epochs share their boundary sample; average where
                    // they overlap rather than letting the later epoch win.
                    for index in 0..<upsampledCount where coverage[index] > 1 {
                        artifact[index] /= Float(coverage[index])
                    }

                    let atSampleRate = GradientSincResampler.decimate(artifact, factor: factor)
                    var output = [Float](repeating: 0, count: sampleCount)
                    for sample in 0..<sampleCount {
                        output[sample] = inputs[channel][sample] - atSampleRate[sample]
                    }
                    cleaned.base[channel] = output
                    artifacts.base[channel] = atSampleRate
                }
            }
        }
        return (cleaned, artifacts)
    }

    func adaptiveNoiseCancel(
        cleaned: [[Float]],
        references: [[Float]],
        request: GradientANCRequest
    ) throws -> [GradientANC.Result] {
        let channelCount = cleaned.count
        guard channelCount > 0 else { return [] }
        var results = [GradientANC.Result?](repeating: nil, count: channelCount)
        results.withUnsafeMutableBufferPointer { buffer in
            let out = GradientUnsafeSendable(base: buffer.baseAddress!)
            GradientParallel.forEach(channelCount) { channel in
                out.base[channel] = GradientANC.apply(
                    cleaned: cleaned[channel],
                    reference: references[channel],
                    cutoffHz: request.cutoffHz,
                    samplingRate: request.samplingRate,
                    filterLength: request.filterLength,
                    stepSize: request.stepSize
                )
            }
        }
        return results.enumerated().map { index, result in
            result ?? GradientANC.Result(output: cleaned[index], applied: false)
        }
    }
}
