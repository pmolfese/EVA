//
//  TimeFrequencyMetalBackend.swift
//  EVA
//
//  Batched, complex-Morlet backend for the all-channel explorer. The CPU
//  engine remains the numerical reference and the fallback for multitaper.
//

import Foundation
import Metal

nonisolated final class TimeFrequencyMetalBackend: @unchecked Sendable {
    private struct Parameters {
        var channelCount: UInt32
        var trialCount: UInt32
        var sampleCount: UInt32
        var frequencyCount: UInt32
        var maximumKernelLength: UInt32
    }

    struct Decomposition: Sendable {
        var meanPower: [[Double]]
        var itpc: [[Double]]
    }

    static let shared: TimeFrequencyMetalBackend? = TimeFrequencyMetalBackend()
    static var isAvailable: Bool { shared != nil }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: Bundle(for: TimeFrequencyMetalBackend.self)),
              let function = library.makeFunction(name: "tfMorletBatch"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    /// Morlet power + ITPC for an entire condition in one dispatch. Uses Float
    /// on the GPU; callers use the CPU path automatically if this allocation is
    /// not reasonable for the installed device.
    func decompose(stacks: [TimeFrequencyTrials.Stack], plan: TFFrequencyPlan) -> [Decomposition]? {
        guard let first = stacks.first, !stacks.isEmpty, !plan.frequenciesHz.isEmpty else { return nil }
        let channelCount = stacks.count, trialCount = first.trials.count, sampleCount = first.timeCount
        guard channelCount > 0, trialCount > 0, sampleCount > 0,
              stacks.allSatisfy({ $0.trials.count == trialCount && $0.timeCount == sampleCount }) else { return nil }

        let kernels = plan.frequenciesHz.indices.map {
            ComplexMorlet.kernel(frequencyHz: plan.frequenciesHz[$0], nCycles: plan.nCycles[$0], samplingRate: first.samplingRate)
        }
        let maximumKernelLength = kernels.map(\.count).max() ?? 0
        guard maximumKernelLength > 0 else { return nil }
        let outputCount = channelCount * plan.frequenciesHz.count * sampleCount
        let inputCount = channelCount * trialCount * sampleCount
        let totalBytes = (inputCount + 2 * plan.frequenciesHz.count * maximumKernelLength + 2 * outputCount) * MemoryLayout<Float>.stride
        guard totalBytes <= min(device.maxBufferLength, 768 * 1024 * 1024) else { return nil }

        var input = [Float](); input.reserveCapacity(inputCount)
        for stack in stacks { for trial in stack.trials { input.append(contentsOf: trial.map(Float.init)) } }
        var re = [Float](repeating: 0, count: plan.frequenciesHz.count * maximumKernelLength)
        var im = re
        var lengths = [UInt32](repeating: 0, count: plan.frequenciesHz.count)
        for frequency in kernels.indices {
            let kernel = kernels[frequency], base = frequency * maximumKernelLength
            lengths[frequency] = UInt32(kernel.count)
            for index in kernel.re.indices { re[base + index] = Float(kernel.re[index]); im[base + index] = Float(kernel.im[index]) }
        }
        guard let inputBuffer = buffer(input), let reBuffer = buffer(re), let imBuffer = buffer(im),
              let lengthBuffer = buffer(lengths), let powerBuffer = emptyBuffer(count: outputCount),
              let itpcBuffer = emptyBuffer(count: outputCount), let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        var parameters = Parameters(channelCount: UInt32(channelCount), trialCount: UInt32(trialCount), sampleCount: UInt32(sampleCount), frequencyCount: UInt32(plan.frequenciesHz.count), maximumKernelLength: UInt32(maximumKernelLength))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0); encoder.setBuffer(reBuffer, offset: 0, index: 1)
        encoder.setBuffer(imBuffer, offset: 0, index: 2); encoder.setBuffer(lengthBuffer, offset: 0, index: 3)
        encoder.setBuffer(powerBuffer, offset: 0, index: 4); encoder.setBuffer(itpcBuffer, offset: 0, index: 5)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 6)
        let grid = MTLSize(width: sampleCount, height: plan.frequenciesHz.count, depth: channelCount)
        let threads = MTLSize(width: min(pipeline.threadExecutionWidth, sampleCount), height: 1, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: threads)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { return nil }

        let powers = read(powerBuffer, count: outputCount), coherences = read(itpcBuffer, count: outputCount)
        var results: [Decomposition] = []
        for channel in 0..<channelCount {
            var power = [[Double]](), itpc = [[Double]]()
            for frequency in plan.frequenciesHz.indices {
                let base = (channel * plan.frequenciesHz.count + frequency) * sampleCount
                power.append((0..<sampleCount).map { Double(powers[base + $0]) })
                itpc.append((0..<sampleCount).map { Double(coherences[base + $0]) })
            }
            results.append(Decomposition(meanPower: power, itpc: itpc))
        }
        return results
    }

    /// Convenience for the selected-channel detail sheet. It uses the same
    /// batched kernel with a one-channel batch, avoiding a second numerical
    /// implementation for the drill-down path.
    func decompose(trials: [[Double]], samplingRate: Double, plan: TFFrequencyPlan) -> Decomposition? {
        decompose(stacks: [TimeFrequencyTrials.Stack(trials: trials, samplingRate: samplingRate, stimulusOffsetSamples: 0)], plan: plan)?.first
    }

    private func buffer<T>(_ values: [T]) -> MTLBuffer? {
        let size = max(values.count * MemoryLayout<T>.stride, 4)
        guard let buffer = device.makeBuffer(length: size, options: .storageModeShared) else { return nil }
        values.withUnsafeBytes { raw in if let base = raw.baseAddress { buffer.contents().copyMemory(from: base, byteCount: raw.count) } }
        return buffer
    }
    private func emptyBuffer(count: Int) -> MTLBuffer? { device.makeBuffer(length: max(count * MemoryLayout<Float>.stride, 4), options: .storageModeShared) }
    private func read(_ buffer: MTLBuffer, count: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: Float.self, capacity: count), count: count))
    }
}
