//
//  GradientMetalBackend.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Metal backend for EVA's clean-room gradient corrector, ported from
//  EVA/Gradient/ per docs/provenance/fastr-gpu-port-plan.md. No
//  third-party artifact-correction source was consulted, and no part of EVA's
//  earlier ported Metal backend was read while writing this.
//
//  What runs here and what does not:
//
//    - On the GPU: epoch extraction (which fuses the upsample so a full
//      upsampled copy of every channel is never materialised), correlation donor
//      scoring, template construction and its two dot products, residuals and the
//      re-phased artifact estimate, the OBS Gram matrices, and the gather that
//      turns per-epoch estimates back into a corrected recording.
//    - On the CPU, always: every discrete decision, the OBS eigen-decomposition
//      (n <= 256, and its eigenvalue ratios pick a component count), and the
//      basis projection, which is two orders of magnitude cheaper than the Gram
//      that feeds it.
//    - On the CPU, deliberately: adaptive noise cancellation. This is a stated
//      deviation from the port plan's Phase 6, and not because ANC is cheap —
//      measured on a 64-channel ten-minute recording it costs about 0.65 s,
//      making it the largest remaining stage once OBS is off. The reason is
//      parity. NLMS is a recursive filter: each sample's weight update feeds the
//      next, so over 600,000 adaptation steps a float32 weight trajectory does
//      not track a float64 one to anything like the tolerance the rest of this
//      backend meets. Bulk sums narrow safely; a 600,000-step recursion does
//      not. `GradientCPUBackend` runs the channels concurrently across cores
//      instead, which is a good fit for what is a set of independent sequential
//      streams. If ANC is ever moved, it needs its own tolerance and its own
//      argument, not this file's.
//
//  Float32 is not a parity problem here because it is not allowed to reach a
//  decision: the driver rounds every value a comparison depends on onto a fixed
//  grid first. See `GradientTemplateCorrector.quantized`.
//

import Foundation
import Metal

nonisolated final class GradientMetalBackend: GradientBackend, @unchecked Sendable {

    /// Mirrors `GCRParams` in GradientCleanroomKernels.metal. Field order and
    /// types must match exactly.
    private struct Parameters {
        var channelCount: UInt32 = 0
        var sampleCount: UInt32 = 0
        var upsampleFactor: UInt32 = 0
        var epochCount: UInt32 = 0
        var windowLength: UInt32 = 0
        var pairCount: UInt32 = 0
        var maxCover: UInt32 = 0
        var hasOBS: UInt32 = 0
        var jobCount: UInt32 = 0
        var maxJobSize: UInt32 = 0
    }

    /// Boxes a device buffer between stages so it never round-trips through host
    /// memory.
    private final class DeviceStorage {
        let buffer: MTLBuffer
        let count: Int
        init(buffer: MTLBuffer, count: Int) {
            self.buffer = buffer
            self.count = count
        }
    }

    /// Which epochs cover each output sample, in ascending epoch order. Built on
    /// the CPU and reused across tiles, since it depends only on the epoch grid.
    private struct CoverTable {
        let epochs: [Int32]
        let maxCover: Int
        let windowStarts: [Int]
        let sampleCount: Int
        let upsampleFactor: Int
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let extractPipeline: MTLComputePipelineState
    private let statsPipeline: MTLComputePipelineState
    private let correlatePipeline: MTLComputePipelineState
    private let templatePipeline: MTLComputePipelineState
    private let momentsPipeline: MTLComputePipelineState
    private let residualPipeline: MTLComputePipelineState
    private let gramPipeline: MTLComputePipelineState
    private let assemblePipeline: MTLComputePipelineState

    private let cacheLock = NSLock()
    private var cachedCover: CoverTable?

    static let shared: GradientMetalBackend? = GradientMetalBackend()
    static var isAvailable: Bool { shared != nil }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        guard let queue = device.makeCommandQueue() else {
            assertionFailure("Metal device could not create the gradient command queue.")
            return nil
        }
        guard let library = try? device.makeDefaultLibrary(
            bundle: Bundle(for: GradientMetalBackend.self)
        ) else {
            assertionFailure("EVA's compiled default.metallib could not be loaded for gradient correction.")
            return nil
        }
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            guard let function = library.makeFunction(name: name) else { return nil }
            return try? device.makeComputePipelineState(function: function)
        }
        guard
            let extractPipeline = pipeline("gcrExtractEpochs"),
            let statsPipeline = pipeline("gcrEpochStats"),
            let correlatePipeline = pipeline("gcrCorrelate"),
            let templatePipeline = pipeline("gcrBuildTemplates"),
            let momentsPipeline = pipeline("gcrTemplateMoments"),
            let residualPipeline = pipeline("gcrResiduals"),
            let gramPipeline = pipeline("gcrGram"),
            let assemblePipeline = pipeline("gcrAssemble")
        else {
            assertionFailure("A gradient-correction Metal pipeline could not be created.")
            return nil
        }

        self.device = device
        self.queue = queue
        self.extractPipeline = extractPipeline
        self.statsPipeline = statsPipeline
        self.correlatePipeline = correlatePipeline
        self.templatePipeline = templatePipeline
        self.momentsPipeline = momentsPipeline
        self.residualPipeline = residualPipeline
        self.gramPipeline = gramPipeline
        self.assemblePipeline = assemblePipeline
    }

    var backend: GradientComputeBackend { .metal }

    // MARK: - Tiling

    /// Channels that fit in flight at once.
    ///
    /// Five `channel x epoch x sample` buffers are live at the peak — windows,
    /// templates, residuals, estimates, OBS contributions — plus three
    /// `channel x sample` ones. A 64-channel ten-minute recording would want well
    /// over a gigabyte if it were done in one shot, which is why the driver tiles.
    func maximumTileChannels(plan: GradientBatchPlan) -> Int {
        let epochBytes = 4 * max(plan.epochCount * plan.windowLength, 1)
        let sampleBytes = 4 * max(plan.sampleCount, 1)
        let perChannel = 5 * epochBytes + 3 * sampleBytes

        let workingSet = Int(device.recommendedMaxWorkingSetSize)
        let budget = workingSet > 0 ? min(workingSet / 3, 1 << 30) : (1 << 28)
        var tile = max(1, budget / max(perChannel, 1))

        // No single buffer may exceed the device limit either.
        let largest = max(epochBytes, sampleBytes)
        tile = min(tile, max(1, device.maxBufferLength / max(largest, 1)))
        return tile
    }

    // MARK: - Buffer plumbing

    private func makeBuffer(bytes count: Int, label: String) throws -> MTLBuffer {
        guard let buffer = device.makeBuffer(
            length: max(count, 4),
            options: .storageModeShared
        ) else {
            throw GradientCorrectionError.backendFailure("could not allocate \(label) (\(count) bytes)")
        }
        buffer.label = label
        return buffer
    }

    private func makeBuffer<T>(_ values: [T], label: String) throws -> MTLBuffer {
        let buffer = try makeBuffer(bytes: MemoryLayout<T>.stride * values.count, label: label)
        guard !values.isEmpty else { return buffer }
        values.withUnsafeBytes { raw in
            buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }
        return buffer
    }

    private func read<T>(_ buffer: MTLBuffer, count: Int, as type: T.Type) -> [T] {
        guard count > 0 else { return [] }
        let pointer = buffer.contents().bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private func storage(_ buffer: GradientDeviceBuffer, stage: String) throws -> DeviceStorage {
        guard let device = buffer.storage as? DeviceStorage else {
            throw GradientCorrectionError.backendFailure(
                "\(stage) received a buffer from a different compute backend"
            )
        }
        return device
    }

    private func commandBuffer(_ stage: String) throws -> MTLCommandBuffer {
        guard let command = queue.makeCommandBuffer() else {
            throw GradientCorrectionError.backendFailure("no command buffer for \(stage)")
        }
        return command
    }

    private func encoder(_ command: MTLCommandBuffer, _ stage: String) throws -> MTLComputeCommandEncoder {
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw GradientCorrectionError.backendFailure("no compute encoder for \(stage)")
        }
        return encoder
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        _ pipeline: MTLComputePipelineState,
        threads: Int
    ) {
        guard threads > 0 else { return }
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.setComputePipelineState(pipeline)
        encoder.dispatchThreads(
            MTLSize(width: threads, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
    }

    private func run(_ command: MTLCommandBuffer, stage: String) throws {
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error {
            throw GradientCorrectionError.backendFailure("\(stage): \(error.localizedDescription)")
        }
    }

    // MARK: - Resampling tables

    /// Polyphase upsampling taps, matching `GradientSincResampler.upsample`
    /// exactly — including the per-phase normalisation to unity DC gain, without
    /// which a constant input comes back with a few tenths of a percent of ripple.
    private static func upsampleTaps(factor: Int) -> [Float] {
        let lobes = GradientSincResampler.upsampleLobes
        let tapCount = 2 * lobes
        guard factor > 1 else { return [Float](repeating: 0, count: tapCount) }
        var taps = [Double](repeating: 0, count: factor * tapCount)
        for phase in 0..<factor {
            let offset = Double(phase) / Double(factor)
            var sum = 0.0
            for tap in 0..<tapCount {
                let distance = offset - Double(tap - lobes + 1)
                let weight = GradientSincResampler.kernel(distance, lobes: lobes)
                taps[phase * tapCount + tap] = weight
                sum += weight
            }
            if abs(sum) > 1e-12 {
                for tap in 0..<tapCount { taps[phase * tapCount + tap] /= sum }
            }
        }
        return taps.map(Float.init)
    }

    /// Fractional-delay taps and the integer part of the read position, matching
    /// `GradientSincResampler.fractionalDelay`.
    ///
    /// The delay is constant across an epoch, so `floor(n - delay)` is just
    /// `n + floor(-delay)` and the tap set is computed once. Recomputing per
    /// sample would be slower and a source of drift.
    private static func delayTaps(for delay: Double) -> (taps: [Float], base: Int32) {
        let lobes = GradientSincResampler.delayLobes
        let tapCount = 2 * lobes
        let shifted = -delay
        let fraction = shifted - shifted.rounded(.down)
        var taps = [Double](repeating: 0, count: tapCount)
        var sum = 0.0
        for (slot, offset) in ((-lobes + 1)...lobes).enumerated() {
            let weight = GradientSincResampler.kernel(fraction - Double(offset), lobes: lobes)
            taps[slot] = weight
            sum += weight
        }
        if abs(sum) > 1e-12 {
            for slot in 0..<tapCount { taps[slot] /= sum }
        }
        return (taps.map(Float.init), Int32(shifted.rounded(.down)))
    }

    /// Tap tables for every epoch, in one direction.
    ///
    /// - Parameter inverse: false for extraction, which moves each epoch onto the
    ///   shared grid by `-offset`; true for re-phasing an estimate back onto the
    ///   epoch's own grid by `+offset`.
    private static func epochDelayTables(
        plan: GradientBatchPlan,
        inverse: Bool
    ) -> (taps: [Float], bases: [Int32], flags: [UInt32]) {
        let tapCount = 2 * GradientSincResampler.delayLobes
        var taps = [Float](repeating: 0, count: plan.epochCount * tapCount)
        var bases = [Int32](repeating: 0, count: plan.epochCount)
        var flags = [UInt32](repeating: 0, count: plan.epochCount)
        for epoch in 0..<plan.epochCount {
            let offset = plan.fractionalShifts[epoch]
            guard abs(offset) > 1e-9 else { continue }
            let (values, base) = delayTaps(for: inverse ? offset : -offset)
            for slot in 0..<tapCount { taps[epoch * tapCount + slot] = values[slot] }
            bases[epoch] = base
            flags[epoch] = 1
        }
        return (taps, bases, flags)
    }

    private func coverTable(plan: GradientBatchPlan) -> CoverTable {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedCover,
           cached.sampleCount == plan.sampleCount,
           cached.upsampleFactor == plan.upsampleFactor,
           cached.windowStarts == plan.windowStarts {
            return cached
        }

        let sampleCount = plan.sampleCount
        let factor = plan.upsampleFactor
        let length = plan.windowLength

        // Only positions that survive decimation are ever read, so the table
        // covers output samples rather than the upsampled axis.
        func range(of epoch: Int) -> ClosedRange<Int>? {
            let start = plan.windowStarts[epoch]
            guard start >= 0 else { return nil }
            let first = (start + factor - 1) / factor
            let last = min((start + length - 1) / factor, sampleCount - 1)
            guard first <= last else { return nil }
            return first...last
        }

        var counts = [Int32](repeating: 0, count: sampleCount)
        for epoch in 0..<plan.epochCount {
            guard let span = range(of: epoch) else { continue }
            for sample in span { counts[sample] += 1 }
        }
        let maxCover = Int(counts.max() ?? 0)
        guard maxCover > 0 else {
            let table = CoverTable(
                epochs: [], maxCover: 0, windowStarts: plan.windowStarts,
                sampleCount: sampleCount, upsampleFactor: factor
            )
            cachedCover = table
            return table
        }

        var epochs = [Int32](repeating: -1, count: sampleCount * maxCover)
        var filled = [Int32](repeating: 0, count: sampleCount)
        for epoch in 0..<plan.epochCount {
            guard let span = range(of: epoch) else { continue }
            for sample in span {
                epochs[sample * maxCover + Int(filled[sample])] = Int32(epoch)
                filled[sample] += 1
            }
        }

        let table = CoverTable(
            epochs: epochs, maxCover: maxCover, windowStarts: plan.windowStarts,
            sampleCount: sampleCount, upsampleFactor: factor
        )
        cachedCover = table
        return table
    }

    // MARK: - Stage 1: epoch extraction

    func extractEpochWindows(
        channels: [[Float]],
        plan: GradientBatchPlan
    ) throws -> GradientDeviceBuffer {
        let channelCount = channels.count
        let total = plan.epochBufferCount(channels: channelCount)
        let output = try makeBuffer(bytes: 4 * max(total, 1), label: "gradient.windows")
        guard total > 0 else {
            return GradientDeviceBuffer(DeviceStorage(buffer: output, count: 0))
        }

        var flat = [Float](repeating: 0, count: channelCount * plan.sampleCount)
        for channel in 0..<channelCount {
            let base = channel * plan.sampleCount
            for sample in 0..<plan.sampleCount { flat[base + sample] = channels[channel][sample] }
        }

        let starts = plan.windowStarts.map(Int32.init)
        let delays = Self.epochDelayTables(plan: plan, inverse: false)
        var parameters = Parameters(
            channelCount: UInt32(channelCount),
            sampleCount: UInt32(plan.sampleCount),
            upsampleFactor: UInt32(plan.upsampleFactor),
            epochCount: UInt32(plan.epochCount),
            windowLength: UInt32(plan.windowLength)
        )

        let command = try commandBuffer("extractEpochWindows")
        let encoder = try encoder(command, "extractEpochWindows")
        encoder.setBuffer(try makeBuffer(flat, label: "gradient.channels"), offset: 0, index: 0)
        encoder.setBuffer(try makeBuffer(starts, label: "gradient.starts"), offset: 0, index: 1)
        encoder.setBuffer(
            try makeBuffer(Self.upsampleTaps(factor: plan.upsampleFactor), label: "gradient.upsampleTaps"),
            offset: 0, index: 2
        )
        encoder.setBuffer(try makeBuffer(delays.taps, label: "gradient.delayTaps"), offset: 0, index: 3)
        encoder.setBuffer(try makeBuffer(delays.bases, label: "gradient.delayBase"), offset: 0, index: 4)
        encoder.setBuffer(try makeBuffer(delays.flags, label: "gradient.delayFlags"), offset: 0, index: 5)
        encoder.setBuffer(output, offset: 0, index: 6)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 7)
        dispatch(encoder, extractPipeline, threads: total)
        encoder.endEncoding()
        try run(command, stage: "extractEpochWindows")

        return GradientDeviceBuffer(DeviceStorage(buffer: output, count: total))
    }

    // MARK: - Stage 2: correlation donor scoring

    func epochCorrelations(
        pairs: [GradientEpochPair],
        windows: GradientDeviceBuffer,
        channelCount: Int,
        plan: GradientBatchPlan
    ) throws -> [Double] {
        let source = try storage(windows, stage: "epochCorrelations")
        let pairCount = pairs.count
        let total = channelCount * pairCount
        guard total > 0 else { return [] }

        var flatPairs = [Int32](repeating: 0, count: 2 * pairCount)
        for index in 0..<pairCount {
            flatPairs[2 * index] = pairs[index].target
            flatPairs[2 * index + 1] = pairs[index].candidate
        }

        let slotCount = channelCount * plan.epochCount
        let means = try makeBuffer(bytes: 4 * slotCount, label: "gradient.means")
        let norms = try makeBuffer(bytes: 4 * slotCount, label: "gradient.norms")
        let output = try makeBuffer(bytes: 4 * total, label: "gradient.correlations")

        var parameters = Parameters(
            channelCount: UInt32(channelCount),
            sampleCount: UInt32(plan.sampleCount),
            upsampleFactor: UInt32(plan.upsampleFactor),
            epochCount: UInt32(plan.epochCount),
            windowLength: UInt32(plan.windowLength),
            pairCount: UInt32(pairCount)
        )

        let command = try commandBuffer("epochCorrelations")
        let encoder = try encoder(command, "epochCorrelations")

        encoder.setBuffer(source.buffer, offset: 0, index: 0)
        encoder.setBuffer(means, offset: 0, index: 1)
        encoder.setBuffer(norms, offset: 0, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 3)
        dispatch(encoder, statsPipeline, threads: slotCount)

        encoder.setBuffer(source.buffer, offset: 0, index: 0)
        encoder.setBuffer(means, offset: 0, index: 1)
        encoder.setBuffer(norms, offset: 0, index: 2)
        encoder.setBuffer(try makeBuffer(flatPairs, label: "gradient.pairs"), offset: 0, index: 3)
        encoder.setBuffer(output, offset: 0, index: 4)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 5)
        dispatch(encoder, correlatePipeline, threads: total)

        encoder.endEncoding()
        try run(command, stage: "epochCorrelations")

        return read(output, count: total, as: Float.self).map(Double.init)
    }

    // MARK: - Stage 3: templates

    func buildTemplates(
        windows: GradientDeviceBuffer,
        donors: GradientDonorTable,
        channelCount: Int,
        plan: GradientBatchPlan
    ) throws -> GradientTemplateBatch {
        let source = try storage(windows, stage: "buildTemplates")
        let slotCount = channelCount * plan.epochCount
        let total = slotCount * plan.windowLength
        let templates = try makeBuffer(bytes: 4 * max(total, 1), label: "gradient.templates")
        guard total > 0 else {
            return GradientTemplateBatch(
                present: [], energies: [], projections: [],
                templates: GradientDeviceBuffer(DeviceStorage(buffer: templates, count: 0))
            )
        }

        let energyBuffer = try makeBuffer(bytes: 4 * slotCount, label: "gradient.energies")
        let projectionBuffer = try makeBuffer(bytes: 4 * slotCount, label: "gradient.projections")
        var parameters = Parameters(
            channelCount: UInt32(channelCount),
            sampleCount: UInt32(plan.sampleCount),
            upsampleFactor: UInt32(plan.upsampleFactor),
            epochCount: UInt32(plan.epochCount),
            windowLength: UInt32(plan.windowLength)
        )

        let command = try commandBuffer("buildTemplates")
        let encoder = try encoder(command, "buildTemplates")

        encoder.setBuffer(source.buffer, offset: 0, index: 0)
        encoder.setBuffer(try makeBuffer(donors.offsets, label: "gradient.donorOffsets"), offset: 0, index: 1)
        encoder.setBuffer(
            try makeBuffer(donors.indices.isEmpty ? [Int32(0)] : donors.indices, label: "gradient.donorIndices"),
            offset: 0, index: 2
        )
        encoder.setBuffer(templates, offset: 0, index: 3)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 4)
        dispatch(encoder, templatePipeline, threads: total)

        encoder.setBuffer(source.buffer, offset: 0, index: 0)
        encoder.setBuffer(templates, offset: 0, index: 1)
        encoder.setBuffer(energyBuffer, offset: 0, index: 2)
        encoder.setBuffer(projectionBuffer, offset: 0, index: 3)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 4)
        dispatch(encoder, momentsPipeline, threads: slotCount)

        encoder.endEncoding()
        try run(command, stage: "buildTemplates")

        let energyValues = read(energyBuffer, count: slotCount, as: Float.self)
        let projectionValues = read(projectionBuffer, count: slotCount, as: Float.self)
        var present = [Bool](repeating: false, count: slotCount)
        var energies = [Double](repeating: 0, count: slotCount)
        var projections = [Double](repeating: 0, count: slotCount)
        for slot in 0..<slotCount {
            guard donors.offsets[slot + 1] > donors.offsets[slot] else { continue }
            let energy = Double(energyValues[slot])
            guard energy > 1e-20 else { continue }
            present[slot] = true
            energies[slot] = energy
            projections[slot] = Double(projectionValues[slot])
        }

        return GradientTemplateBatch(
            present: present,
            energies: energies,
            projections: projections,
            templates: GradientDeviceBuffer(DeviceStorage(buffer: templates, count: total))
        )
    }

    // MARK: - Stage 4: residuals and estimates

    func residualsAndEstimates(
        windows: GradientDeviceBuffer,
        templates: GradientTemplateBatch,
        scales: [Double],
        channelCount: Int,
        plan: GradientBatchPlan,
        needsResiduals: Bool
    ) throws -> GradientResidualBatch {
        let source = try storage(windows, stage: "residualsAndEstimates")
        let shapes = try storage(templates.templates, stage: "residualsAndEstimates")
        let slotCount = channelCount * plan.epochCount
        let total = slotCount * plan.windowLength
        let estimates = try makeBuffer(bytes: 4 * max(total, 1), label: "gradient.estimates")
        guard total > 0 else {
            return GradientResidualBatch(
                residuals: [],
                estimates: GradientDeviceBuffer(DeviceStorage(buffer: estimates, count: 0))
            )
        }

        let residuals = try makeBuffer(bytes: 4 * total, label: "gradient.residuals")
        let delays = Self.epochDelayTables(plan: plan, inverse: true)
        var parameters = Parameters(
            channelCount: UInt32(channelCount),
            sampleCount: UInt32(plan.sampleCount),
            upsampleFactor: UInt32(plan.upsampleFactor),
            epochCount: UInt32(plan.epochCount),
            windowLength: UInt32(plan.windowLength)
        )

        let command = try commandBuffer("residualsAndEstimates")
        let encoder = try encoder(command, "residualsAndEstimates")
        encoder.setBuffer(source.buffer, offset: 0, index: 0)
        encoder.setBuffer(shapes.buffer, offset: 0, index: 1)
        encoder.setBuffer(try makeBuffer(scales.map(Float.init), label: "gradient.scales"), offset: 0, index: 2)
        encoder.setBuffer(
            try makeBuffer(templates.present.map { $0 ? UInt8(1) : UInt8(0) }, label: "gradient.present"),
            offset: 0, index: 3
        )
        encoder.setBuffer(try makeBuffer(delays.taps, label: "gradient.inverseDelayTaps"), offset: 0, index: 4)
        encoder.setBuffer(try makeBuffer(delays.bases, label: "gradient.inverseDelayBase"), offset: 0, index: 5)
        encoder.setBuffer(try makeBuffer(delays.flags, label: "gradient.inverseDelayFlags"), offset: 0, index: 6)
        encoder.setBuffer(residuals, offset: 0, index: 7)
        encoder.setBuffer(estimates, offset: 0, index: 8)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 9)
        dispatch(encoder, residualPipeline, threads: total)
        encoder.endEncoding()
        try run(command, stage: "residualsAndEstimates")

        return GradientResidualBatch(
            residuals: needsResiduals ? read(residuals, count: total, as: Float.self) : [],
            estimates: GradientDeviceBuffer(DeviceStorage(buffer: estimates, count: total))
        )
    }

    // MARK: - Stage 5: OBS Gram

    func gramMatrices(
        jobs: [GradientGramJob],
        detrended: [Float],
        windowLength: Int
    ) throws -> [[Double]] {
        guard !jobs.isEmpty else { return [] }
        let maxJobSize = jobs.map(\.size).max() ?? 0
        guard maxJobSize > 0 else { return jobs.map { _ in [] } }

        let detrendedBuffer = try makeBuffer(detrended, label: "gradient.detrended")
        var results = [[Double]](repeating: [], count: jobs.count)

        // One block's Gram output is `jobs * maxJobSize^2` floats; 16 million of
        // them is 64 MB, which is a comfortable working set.
        let perJob = maxJobSize * maxJobSize
        let jobsPerBlock = max(1, 16_000_000 / max(perJob, 1))

        var first = 0
        while first < jobs.count {
            let last = min(first + jobsPerBlock, jobs.count)
            let block = Array(jobs[first..<last])
            let output = try makeBuffer(bytes: 4 * block.count * perJob, label: "gradient.gram")

            var parameters = Parameters(
                windowLength: UInt32(windowLength),
                jobCount: UInt32(block.count),
                maxJobSize: UInt32(maxJobSize)
            )
            let command = try commandBuffer("gramMatrices")
            let encoder = try encoder(command, "gramMatrices")
            encoder.setComputePipelineState(gramPipeline)
            encoder.setBuffer(detrendedBuffer, offset: 0, index: 0)
            encoder.setBuffer(try makeBuffer(block.map { Int32($0.offset) }, label: "gradient.jobOffsets"), offset: 0, index: 1)
            encoder.setBuffer(try makeBuffer(block.map { Int32($0.size) }, label: "gradient.jobSizes"), offset: 0, index: 2)
            encoder.setBuffer(output, offset: 0, index: 3)
            encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 4)

            let side = min(16, gramPipeline.threadExecutionWidth)
            encoder.dispatchThreads(
                MTLSize(width: maxJobSize, height: maxJobSize, depth: block.count),
                threadsPerThreadgroup: MTLSize(width: side, height: side, depth: 1)
            )
            encoder.endEncoding()
            try run(command, stage: "gramMatrices")

            let values = read(output, count: block.count * perJob, as: Float.self)
            for (index, job) in block.enumerated() {
                let base = index * perJob
                var gram = [Double](repeating: 0, count: job.size * job.size)
                for row in 0..<job.size {
                    for column in 0..<job.size {
                        gram[row * job.size + column] =
                            Double(values[base + row * maxJobSize + column])
                    }
                }
                results[first + index] = gram
            }
            first = last
        }
        return results
    }

    // MARK: - Stage 6: assembly

    func assembleCorrection(
        inputs: [[Float]],
        estimates: GradientDeviceBuffer,
        obsContributions: [Float]?,
        present: [Bool],
        plan: GradientBatchPlan
    ) throws -> (cleaned: [[Float]], artifact: [[Float]]) {
        let source = try storage(estimates, stage: "assembleCorrection")
        let channelCount = inputs.count
        let sampleCount = plan.sampleCount
        let total = channelCount * sampleCount
        guard total > 0 else { return ([], []) }

        let cover = coverTable(plan: plan)
        guard cover.maxCover > 0 else {
            // No epoch is in bounds, so nothing is subtracted anywhere.
            return (inputs, inputs.map { [Float](repeating: 0, count: $0.count) })
        }

        var flat = [Float](repeating: 0, count: total)
        for channel in 0..<channelCount {
            let base = channel * sampleCount
            for sample in 0..<sampleCount { flat[base + sample] = inputs[channel][sample] }
        }

        let cleanedBuffer = try makeBuffer(bytes: 4 * total, label: "gradient.cleaned")
        let artifactBuffer = try makeBuffer(bytes: 4 * total, label: "gradient.artifact")
        var parameters = Parameters(
            channelCount: UInt32(channelCount),
            sampleCount: UInt32(sampleCount),
            upsampleFactor: UInt32(plan.upsampleFactor),
            epochCount: UInt32(plan.epochCount),
            windowLength: UInt32(plan.windowLength),
            maxCover: UInt32(cover.maxCover),
            hasOBS: obsContributions == nil ? 0 : 1
        )

        let command = try commandBuffer("assembleCorrection")
        let encoder = try encoder(command, "assembleCorrection")
        encoder.setBuffer(try makeBuffer(flat, label: "gradient.inputs"), offset: 0, index: 0)
        encoder.setBuffer(source.buffer, offset: 0, index: 1)
        encoder.setBuffer(
            try makeBuffer(obsContributions ?? [Float(0)], label: "gradient.obs"),
            offset: 0, index: 2
        )
        encoder.setBuffer(
            try makeBuffer(present.map { $0 ? UInt8(1) : UInt8(0) }, label: "gradient.presentFlags"),
            offset: 0, index: 3
        )
        encoder.setBuffer(try makeBuffer(cover.epochs, label: "gradient.cover"), offset: 0, index: 4)
        encoder.setBuffer(
            try makeBuffer(plan.windowStarts.map(Int32.init), label: "gradient.assembleStarts"),
            offset: 0, index: 5
        )
        encoder.setBuffer(cleanedBuffer, offset: 0, index: 6)
        encoder.setBuffer(artifactBuffer, offset: 0, index: 7)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 8)
        dispatch(encoder, assemblePipeline, threads: total)
        encoder.endEncoding()
        try run(command, stage: "assembleCorrection")

        let cleanedValues = read(cleanedBuffer, count: total, as: Float.self)
        let artifactValues = read(artifactBuffer, count: total, as: Float.self)
        var cleaned = [[Float]](repeating: [], count: channelCount)
        var artifacts = [[Float]](repeating: [], count: channelCount)
        for channel in 0..<channelCount {
            let base = channel * sampleCount
            cleaned[channel] = Array(cleanedValues[base..<(base + sampleCount)])
            artifacts[channel] = Array(artifactValues[base..<(base + sampleCount)])
        }
        return (cleaned, artifacts)
    }

    // MARK: - Stage 7: ANC

    /// Left on the CPU by measurement, not oversight — see the file header.
    func adaptiveNoiseCancel(
        cleaned: [[Float]],
        references: [[Float]],
        request: GradientANCRequest
    ) throws -> [GradientANC.Result] {
        try GradientCPUBackend.shared.adaptiveNoiseCancel(
            cleaned: cleaned,
            references: references,
            request: request
        )
    }
}
