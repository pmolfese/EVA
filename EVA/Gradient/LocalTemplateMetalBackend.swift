//
//  LocalTemplateMetalBackend.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Metal backend for the clean-room local-template corrector (MAS/MAR/wAAS/wAAR),
//  ported from `LocalTemplateArtifactCorrector`. No third-party
//  artifact-correction source was consulted.
//
//  This restores the GPU option MAS and MAR had under the engine EVA retired in
//  2026-08-09, and it is the better fit of the two families for a GPU: the work
//  is tens of millions of independent donor reductions over (channel, sample),
//  with no cross-thread dependency at all.
//
//  Same discipline as `GradientMetalBackend`: the CPU decides everything
//  discrete — which events are corrected, which donors are eligible, the
//  correlation floor, the skip reasons — and hands this only the arithmetic. See
//  docs/provenance/README.md.
//

import Foundation
import Metal

/// Everything the kernels need about one run, with every decision already made.
///
/// Built by `LocalTemplateArtifactCorrector` from the events it has already
/// filtered, so a skipped event simply never appears in the cover table.
nonisolated struct LocalTemplatePlan: Sendable {
    let sampleCount: Int
    let eventCount: Int
    /// Per event, in the corrector's own event order.
    let centers: [Int32]
    let windowStart: [Int32]
    let windowEnd: [Int32]
    /// `donorOffsets` has `eventCount + 1` entries; event `e`'s donors are
    /// `donorIndices[donorOffsets[e] ..< donorOffsets[e + 1]]`.
    let donorOffsets: [Int32]
    let donorIndices: [Int32]
    /// Per output sample, which events cover it, in ascending event order.
    /// `coverOffsets` has `sampleCount + 1` entries.
    let coverOffsets: [Int32]
    let coverEvents: [Int32]
    let reducer: UInt32
    let timeConstant: Float
    let appliesScale: Bool

    /// Widest donor list any event has. The kernels reduce in registers, so a
    /// run past their capacity stays on the CPU.
    var widestDonorList: Int {
        var widest = 0
        for event in 0..<eventCount {
            widest = max(widest, Int(donorOffsets[event + 1] - donorOffsets[event]))
        }
        return widest
    }
}

nonisolated final class LocalTemplateMetalBackend: @unchecked Sendable {

    /// Mirrors `LTParams` in LocalTemplateKernels.metal.
    private struct Parameters {
        var channelCount: UInt32 = 0
        var sampleCount: UInt32 = 0
        var eventCount: UInt32 = 0
        var reducer: UInt32 = 0
        var timeConstant: Float = 1
        var appliesScale: UInt32 = 0
    }

    /// Must match `kLTMaxDonors` in the kernel source.
    static let maximumDonors = 32

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let scalePipeline: MTLComputePipelineState
    private let accumulatePipeline: MTLComputePipelineState

    static let shared: LocalTemplateMetalBackend? = LocalTemplateMetalBackend()
    static var isAvailable: Bool { shared != nil }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(
                  bundle: Bundle(for: LocalTemplateMetalBackend.self)
              )
        else { return nil }
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            guard let function = library.makeFunction(name: name) else { return nil }
            return try? device.makeComputePipelineState(function: function)
        }
        guard let scale = pipeline("ltLeastSquaresScales"),
              let accumulate = pipeline("ltAccumulateAndSubtract")
        else {
            assertionFailure("A local-template Metal pipeline could not be created.")
            return nil
        }
        self.device = device
        self.queue = queue
        self.scalePipeline = scale
        self.accumulatePipeline = accumulate
    }

    /// Whether this run can go on the GPU at all.
    ///
    /// The only hard limit is the donor count the kernels can reduce in
    /// registers. Everything else falls back for speed, not correctness.
    func canRun(_ plan: LocalTemplatePlan) -> Bool {
        plan.eventCount > 0
            && plan.sampleCount > 0
            && plan.widestDonorList <= Self.maximumDonors
    }

    // MARK: - Buffers

    private func buffer<T>(_ values: [T], _ label: String) -> MTLBuffer? {
        let length = max(MemoryLayout<T>.stride * values.count, 4)
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            return nil
        }
        buffer.label = label
        if !values.isEmpty {
            values.withUnsafeBytes { raw in
                buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
        }
        return buffer
    }

    private func read(_ buffer: MTLBuffer, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let pointer = buffer.contents().bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        _ pipeline: MTLComputePipelineState,
        threads: Int
    ) {
        guard threads > 0 else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.dispatchThreads(
            MTLSize(width: threads, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: min(pipeline.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1
            )
        )
    }

    // MARK: - Run

    /// Corrects every channel, returning the cleaned signal, the artifact
    /// estimate, and the per-`(channel, event)` scales when a regression fit was
    /// requested.
    ///
    /// Returns nil when the device declines the work, so the caller falls back
    /// to the CPU rather than failing the run.
    func correct(
        channels: [[Float]],
        plan: LocalTemplatePlan
    ) -> (cleaned: [[Float]], artifact: [[Float]], scales: [Float])? {
        let channelCount = channels.count
        let sampleCount = plan.sampleCount
        let total = channelCount * sampleCount
        guard channelCount > 0, total > 0, canRun(plan) else { return nil }

        var flat = [Float](repeating: 0, count: total)
        for channel in 0..<channelCount {
            let base = channel * sampleCount
            for sample in 0..<sampleCount { flat[base + sample] = channels[channel][sample] }
        }

        guard let channelBuffer = buffer(flat, "lt.channels"),
              let centerBuffer = buffer(plan.centers, "lt.centers"),
              let startBuffer = buffer(plan.windowStart, "lt.windowStart"),
              let endBuffer = buffer(plan.windowEnd, "lt.windowEnd"),
              let donorOffsetBuffer = buffer(plan.donorOffsets, "lt.donorOffsets"),
              let donorIndexBuffer = buffer(
                  plan.donorIndices.isEmpty ? [Int32(0)] : plan.donorIndices, "lt.donorIndices"
              ),
              let coverOffsetBuffer = buffer(plan.coverOffsets, "lt.coverOffsets"),
              let coverEventBuffer = buffer(
                  plan.coverEvents.isEmpty ? [Int32(0)] : plan.coverEvents, "lt.coverEvents"
              ),
              let scaleBuffer = device.makeBuffer(
                  length: max(4 * channelCount * plan.eventCount, 4), options: .storageModeShared
              ),
              let artifactBuffer = device.makeBuffer(length: 4 * total, options: .storageModeShared),
              let cleanedBuffer = device.makeBuffer(length: 4 * total, options: .storageModeShared),
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder()
        else { return nil }

        var parameters = Parameters(
            channelCount: UInt32(channelCount),
            sampleCount: UInt32(sampleCount),
            eventCount: UInt32(plan.eventCount),
            reducer: plan.reducer,
            timeConstant: plan.timeConstant,
            appliesScale: plan.appliesScale ? 1 : 0
        )

        if plan.appliesScale {
            encoder.setBuffer(channelBuffer, offset: 0, index: 0)
            encoder.setBuffer(centerBuffer, offset: 0, index: 1)
            encoder.setBuffer(startBuffer, offset: 0, index: 2)
            encoder.setBuffer(endBuffer, offset: 0, index: 3)
            encoder.setBuffer(donorOffsetBuffer, offset: 0, index: 4)
            encoder.setBuffer(donorIndexBuffer, offset: 0, index: 5)
            encoder.setBuffer(scaleBuffer, offset: 0, index: 6)
            encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 7)
            dispatch(encoder, scalePipeline, threads: channelCount * plan.eventCount)
        }

        encoder.setBuffer(channelBuffer, offset: 0, index: 0)
        encoder.setBuffer(centerBuffer, offset: 0, index: 1)
        encoder.setBuffer(startBuffer, offset: 0, index: 2)
        encoder.setBuffer(endBuffer, offset: 0, index: 3)
        encoder.setBuffer(donorOffsetBuffer, offset: 0, index: 4)
        encoder.setBuffer(donorIndexBuffer, offset: 0, index: 5)
        encoder.setBuffer(scaleBuffer, offset: 0, index: 6)
        encoder.setBuffer(coverOffsetBuffer, offset: 0, index: 7)
        encoder.setBuffer(coverEventBuffer, offset: 0, index: 8)
        encoder.setBuffer(artifactBuffer, offset: 0, index: 9)
        encoder.setBuffer(cleanedBuffer, offset: 0, index: 10)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 11)
        dispatch(encoder, accumulatePipeline, threads: total)

        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.error == nil else { return nil }

        let cleanedValues = read(cleanedBuffer, count: total)
        let artifactValues = read(artifactBuffer, count: total)
        var cleaned = [[Float]](repeating: [], count: channelCount)
        var artifact = [[Float]](repeating: [], count: channelCount)
        for channel in 0..<channelCount {
            let base = channel * sampleCount
            cleaned[channel] = Array(cleanedValues[base..<(base + sampleCount)])
            artifact[channel] = Array(artifactValues[base..<(base + sampleCount)])
        }
        let scales = plan.appliesScale
            ? read(scaleBuffer, count: channelCount * plan.eventCount)
            : []
        return (cleaned, artifact, scales)
    }
}
