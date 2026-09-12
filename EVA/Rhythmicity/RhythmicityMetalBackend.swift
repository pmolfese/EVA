//
//  RhythmicityMetalBackend.swift
//  EVA
//
//  Bounded Morlet tiles plus batched surrogate LAVI reduction on Metal. Backend
//  selection, memory policy, cancellation, and fallback remain on the CPU.
//

import Foundation
import Metal

nonisolated enum RhythmicityMetalError: Error, Sendable, Equatable, LocalizedError {
    case unavailable
    case unsupportedShape
    case memoryBudgetExceeded(requiredBytes: Int, configuredBytes: Int)
    case allocationFailed
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "no compatible Metal compute device or Rhythmicity shader is available"
        case .unsupportedShape:
            return "the requested signal or wavelet exceeds the Metal kernel's 32-bit index range"
        case let .memoryBudgetExceeded(required, configured):
            return "the Metal tile requires \(required) bytes, above the \(configured)-byte budget"
        case .allocationFailed:
            return "Metal could not allocate the bounded coefficient tile"
        case let .commandFailed(message):
            return "the Metal command failed: \(message)"
        }
    }
}

nonisolated struct RhythmicityBackendResolution: Sendable, Equatable {
    var requested: RhythmicityComputeBackend
    var selected: RhythmicityComputeBackend
    var precision: RhythmicityPrecision
    var fallbackReason: String?
}

/// The crossover is deliberately centralized and testable. CPU profiling on
/// the reference Apple-Silicon host showed setup/transfer dominates tiny jobs;
/// Metal becomes eligible only once there is enough frequency × sample work to
/// amortize that cost. The FFT path remains the safe default below the cutoff.
nonisolated enum RhythmicityBackendResolver {
    static let minimumMetalWorkItems = 131_072

    static func resolve(
        requested: RhythmicityComputeBackend,
        sampleCount: Int,
        frequencyCount: Int,
        metalAvailable: Bool = RhythmicityMetalCoefficientProvider.isAvailable
    ) -> RhythmicityBackendResolution {
        switch requested {
        case .directReferenceCPU:
            return .init(requested: requested, selected: .directReferenceCPU, precision: .float64, fallbackReason: nil)
        case .accelerateFFTCPU:
            return .init(requested: requested, selected: .accelerateFFTCPU, precision: .float64, fallbackReason: nil)
        case .metalGPU:
            guard metalAvailable else {
                return .init(
                    requested: requested,
                    selected: .accelerateFFTCPU,
                    precision: .float64,
                    fallbackReason: RhythmicityMetalError.unavailable.localizedDescription
                )
            }
            return .init(requested: requested, selected: .metalGPU, precision: .float32, fallbackReason: nil)
        case .automatic:
            let workItems = sampleCount.multipliedReportingOverflow(by: frequencyCount)
            let isLargeEnough = !workItems.overflow && workItems.partialValue >= minimumMetalWorkItems
            if metalAvailable && isLargeEnough {
                return .init(requested: requested, selected: .metalGPU, precision: .float32, fallbackReason: nil)
            }
            return .init(
                requested: requested,
                selected: .accelerateFFTCPU,
                precision: .float64,
                fallbackReason: metalAvailable ? nil : RhythmicityMetalError.unavailable.localizedDescription
            )
        }
    }
}

nonisolated final class RhythmicityMetalCoefficientProvider: ComplexCoefficientProvider, @unchecked Sendable {
    private struct Parameters {
        var sampleCount: UInt32
        var tapCount: UInt32
        var cropOffset: UInt32
    }

    private struct BatchedParameters {
        var sampleCount: UInt32
        var tapCount: UInt32
        var cropOffset: UInt32
        var batchCount: UInt32
    }

    private struct ReductionParameters {
        var sampleCount: UInt32
        var validLower: UInt32
        var validUpper: UInt32
        var wholeLag: UInt32
        var frequencyIndex: UInt32
        var frequencyCount: UInt32
        var lagFraction: Float
    }

    private struct MetalReduction {
        var numeratorReal: Float = 0
        var numeratorRealCompensation: Float = 0
        var numeratorImaginary: Float = 0
        var numeratorImaginaryCompensation: Float = 0
        var firstEnergy: Float = 0
        var firstEnergyCompensation: Float = 0
        var secondEnergy: Float = 0
        var secondEnergyCompensation: Float = 0
        var pairCount: UInt32 = 0
    }

    static let shared: RhythmicityMetalCoefficientProvider? = RhythmicityMetalCoefficientProvider()
    static var isAvailable: Bool { shared != nil }

    let memoryBudgetBytes: Int
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let batchedPipeline: MTLComputePipelineState
    private let reductionPipeline: MTLComputePipelineState

    init?(memoryBudgetBytes: Int = RhythmicityComputePolicy.productionDefault.memoryBudgetBytes) {
        guard memoryBudgetBytes > 0,
              let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: Bundle(for: RhythmicityMetalCoefficientProvider.self)),
              let function = library.makeFunction(name: "rhythmicityMorletCoefficients"),
              let batchedFunction = library.makeFunction(name: "rhythmicityBatchedMorletCoefficients"),
              let reductionFunction = library.makeFunction(name: "rhythmicityAccumulateLAVI"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let batchedPipeline = try? device.makeComputePipelineState(function: batchedFunction),
              let reductionPipeline = try? device.makeComputePipelineState(function: reductionFunction) else { return nil }
        self.memoryBudgetBytes = memoryBudgetBytes
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.batchedPipeline = batchedPipeline
        self.reductionPipeline = reductionPipeline
    }

    func coefficients(
        signal: [Double],
        samplingRate: Double,
        frequencyHz: Double,
        widthCycles: Double,
        edgePolicy: RhythmicityEdgePolicy,
        cancellation: RhythmicityCancellation
    ) throws -> ComplexCoefficientTile {
        try cancellation.check()
        guard !signal.isEmpty else {
            return ComplexCoefficientTile(
                frequencyHz: frequencyHz,
                real: [],
                imaginary: [],
                validSampleRange: 0..<0
            )
        }
        let kernel = LAVI2026Morlet.kernel(
            frequencyHz: frequencyHz,
            widthCycles: widthCycles,
            samplingRate: samplingRate
        )
        guard signal.count <= Int(UInt32.max), kernel.count <= Int(UInt32.max) else {
            throw RhythmicityMetalError.unsupportedShape
        }

        let floatBytes = MemoryLayout<Float>.stride
        let valueCount = 3 * signal.count + 2 * kernel.count
        let (requiredBytes, overflow) = valueCount.multipliedReportingOverflow(by: floatBytes)
        guard !overflow else { throw RhythmicityMetalError.unsupportedShape }
        let deviceBudget = min(memoryBudgetBytes, device.maxBufferLength)
        guard requiredBytes <= deviceBudget else {
            throw RhythmicityMetalError.memoryBudgetExceeded(
                requiredBytes: requiredBytes,
                configuredBytes: deviceBudget
            )
        }

        let samples = signal.map(Float.init)
        let kernelReal = kernel.real.map(Float.init)
        let kernelImaginary = kernel.imaginary.map(Float.init)
        guard let sampleBuffer = buffer(samples),
              let realKernelBuffer = buffer(kernelReal),
              let imaginaryKernelBuffer = buffer(kernelImaginary),
              let outputRealBuffer = emptyBuffer(count: signal.count),
              let outputImaginaryBuffer = emptyBuffer(count: signal.count),
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw RhythmicityMetalError.allocationFailed
        }
        var parameters = Parameters(
            sampleCount: UInt32(signal.count),
            tapCount: UInt32(kernel.count),
            cropOffset: UInt32(kernel.count / 2)
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(sampleBuffer, offset: 0, index: 0)
        encoder.setBuffer(realKernelBuffer, offset: 0, index: 1)
        encoder.setBuffer(imaginaryKernelBuffer, offset: 0, index: 2)
        encoder.setBuffer(outputRealBuffer, offset: 0, index: 3)
        encoder.setBuffer(outputImaginaryBuffer, offset: 0, index: 4)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 5)
        encoder.dispatchThreads(
            MTLSize(width: signal.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: min(pipeline.maxTotalThreadsPerThreadgroup, max(pipeline.threadExecutionWidth, 1)),
                height: 1,
                depth: 1
            )
        )
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        try cancellation.check()
        guard command.status == .completed else {
            throw RhythmicityMetalError.commandFailed(
                command.error?.localizedDescription ?? "unknown command-buffer error"
            )
        }

        let real = read(outputRealBuffer, count: signal.count).map(Double.init)
        let imaginary = read(outputImaginaryBuffer, count: signal.count).map(Double.init)
        let validRange: Range<Int>
        switch edgePolicy {
        case .referenceSamePadding:
            validRange = signal.indices
        case .validOnly:
            validRange = LAVI2026Morlet.validSampleRange(
                sampleCount: signal.count,
                tapCount: kernel.count
            )
        }
        return ComplexCoefficientTile(
            frequencyHz: frequencyHz,
            real: real,
            imaginary: imaginary,
            validSampleRange: validRange
        )
    }

    /// Largest surrogate batch that keeps the input runs, two reusable
    /// coefficient tiles, compact reductions, and all wavelet kernels inside
    /// the configured Metal allowance.
    func maximumLAVIBatchSize(
        runSampleCounts: [Int],
        frequenciesHz: [Double],
        samplingRate: Double,
        widthCycles: Double,
        requestedCount: Int
    ) throws -> Int {
        guard requestedCount > 0, !runSampleCounts.isEmpty, !frequenciesHz.isEmpty else { return 0 }
        guard runSampleCounts.allSatisfy({ $0 > 0 && $0 <= Int(UInt32.max) }) else {
            throw RhythmicityMetalError.unsupportedShape
        }
        let totalSamples = try checkedSum(runSampleCounts)
        guard totalSamples <= Int(UInt32.max) else {
            throw RhythmicityMetalError.unsupportedShape
        }
        let longestRun = runSampleCounts.max() ?? 0
        let kernelSamples = frequenciesHz.map {
            LAVI2026Morlet.kernel(
                frequencyHz: $0,
                widthCycles: widthCycles,
                samplingRate: samplingRate
            ).count
        }
        guard kernelSamples.allSatisfy({ $0 <= Int(UInt32.max) }) else {
            throw RhythmicityMetalError.unsupportedShape
        }

        let kernelValues = try checkedProduct(try checkedSum(kernelSamples), 2)
        let fixedBytes = try checkedProduct(kernelValues, MemoryLayout<Float>.stride)
        let coefficientValues = try checkedProduct(longestRun, 2)
        let perSurrogateFloatValues = try checkedSum([totalSamples, coefficientValues])
        let perSurrogateFloatBytes = try checkedProduct(
            perSurrogateFloatValues,
            MemoryLayout<Float>.stride
        )
        let reductionBytes = try checkedProduct(
            frequenciesHz.count,
            MemoryLayout<MetalReduction>.stride
        )
        let retainedSurrogateBytes = try checkedProduct(
            totalSamples,
            MemoryLayout<Double>.stride
        )
        let perSurrogateBytes = try checkedSum([
            perSurrogateFloatBytes,
            reductionBytes,
            retainedSurrogateBytes,
        ])
        let configuredBudget = memoryBudgetBytes
        let oneBatchBytes = try checkedSum([fixedBytes, perSurrogateBytes])
        guard oneBatchBytes <= configuredBudget else {
            throw RhythmicityMetalError.memoryBudgetExceeded(
                requiredBytes: oneBatchBytes,
                configuredBytes: configuredBudget
            )
        }

        let memoryCapacity = (configuredBudget - fixedBytes) / max(perSurrogateBytes, 1)
        let inputBufferCapacity = device.maxBufferLength
            / max(try checkedProduct(longestRun, MemoryLayout<Float>.stride), 1)
        let gridCapacity = Int(UInt32.max) / max(longestRun, 1)
        return max(min(requestedCount, memoryCapacity, inputBufferCapacity, gridCapacity), 1)
    }

    /// Computes all frequency profiles for a bounded surrogate batch. Only the
    /// compact LAVI reductions are copied back; coefficient tiles remain on the
    /// GPU and are reused for each finite run and frequency.
    func laviProfiles(
        surrogateRuns: [[[Double]]],
        samplingRate: Double,
        frequenciesHz: [Double],
        widthCycles: Double,
        lagCycles: Double,
        edgePolicy: RhythmicityEdgePolicy,
        cancellation: RhythmicityCancellation
    ) throws -> [[Double]] {
        try cancellation.check()
        guard !surrogateRuns.isEmpty else { return [] }
        guard let first = surrogateRuns.first, !first.isEmpty, !frequenciesHz.isEmpty else {
            throw RhythmicityMetalError.unsupportedShape
        }
        let runSampleCounts = first.map(\.count)
        guard surrogateRuns.allSatisfy({ runs in
            runs.count == runSampleCounts.count
                && zip(runs.map(\.count), runSampleCounts).allSatisfy { pair in
                    pair.0 == pair.1
                }
                && runs.allSatisfy { $0.allSatisfy(\.isFinite) }
        }) else {
            throw RhythmicityMetalError.unsupportedShape
        }
        let batchCount = surrogateRuns.count
        let batchCapacity = try maximumLAVIBatchSize(
            runSampleCounts: runSampleCounts,
            frequenciesHz: frequenciesHz,
            samplingRate: samplingRate,
            widthCycles: widthCycles,
            requestedCount: batchCount
        )
        guard batchCount <= batchCapacity,
              batchCount <= Int(UInt32.max),
              frequenciesHz.count <= Int(UInt32.max) else {
            throw RhythmicityMetalError.unsupportedShape
        }

        var inputBuffers: [MTLBuffer] = []
        inputBuffers.reserveCapacity(runSampleCounts.count)
        for runIndex in runSampleCounts.indices {
            var values: [Float] = []
            values.reserveCapacity(batchCount * runSampleCounts[runIndex])
            for surrogate in surrogateRuns {
                values.append(contentsOf: surrogate[runIndex].map(Float.init))
            }
            guard let input = buffer(values) else { throw RhythmicityMetalError.allocationFailed }
            inputBuffers.append(input)
        }

        let longestRun = runSampleCounts.max() ?? 0
        let coefficientCount = try checkedProduct(batchCount, longestRun)
        let reductionCount = try checkedProduct(batchCount, frequenciesHz.count)
        guard let outputReal = emptyBuffer(count: coefficientCount),
              let outputImaginary = emptyBuffer(count: coefficientCount),
              let reductions = buffer([MetalReduction](repeating: MetalReduction(), count: reductionCount)),
              let command = queue.makeCommandBuffer() else {
            throw RhythmicityMetalError.allocationFailed
        }
        command.label = "Rhythmicity batched surrogate LAVI"

        var retainedKernelBuffers: [MTLBuffer] = []
        retainedKernelBuffers.reserveCapacity(frequenciesHz.count * 2)
        for (frequencyIndex, frequencyHz) in frequenciesHz.enumerated() {
            try cancellation.check()
            let kernel = LAVI2026Morlet.kernel(
                frequencyHz: frequencyHz,
                widthCycles: widthCycles,
                samplingRate: samplingRate
            )
            guard let realKernel = buffer(kernel.real.map(Float.init)),
                  let imaginaryKernel = buffer(kernel.imaginary.map(Float.init)) else {
                throw RhythmicityMetalError.allocationFailed
            }
            retainedKernelBuffers.append(realKernel)
            retainedKernelBuffers.append(imaginaryKernel)
            let exactLag = lagCycles * samplingRate / frequencyHz
            let wholeLag = Int(floor(exactLag))
            let lagFraction = Float(exactLag - Double(wholeLag))

            for runIndex in runSampleCounts.indices {
                let sampleCount = runSampleCounts[runIndex]
                guard wholeLag >= 0, wholeLag + 1 < sampleCount else { continue }
                let validRange: Range<Int>
                switch edgePolicy {
                case .referenceSamePadding:
                    validRange = 0..<sampleCount
                case .validOnly:
                    validRange = LAVI2026Morlet.validSampleRange(
                        sampleCount: sampleCount,
                        tapCount: kernel.count
                    )
                }
                let validUpper = min(
                    sampleCount - wholeLag - 1,
                    validRange.upperBound - wholeLag - 1
                )
                guard validUpper > validRange.lowerBound else { continue }
                guard let coefficientEncoder = command.makeComputeCommandEncoder() else {
                    throw RhythmicityMetalError.allocationFailed
                }
                var coefficientParameters = BatchedParameters(
                    sampleCount: UInt32(sampleCount),
                    tapCount: UInt32(kernel.count),
                    cropOffset: UInt32(kernel.count / 2),
                    batchCount: UInt32(batchCount)
                )
                coefficientEncoder.setComputePipelineState(batchedPipeline)
                coefficientEncoder.setBuffer(inputBuffers[runIndex], offset: 0, index: 0)
                coefficientEncoder.setBuffer(realKernel, offset: 0, index: 1)
                coefficientEncoder.setBuffer(imaginaryKernel, offset: 0, index: 2)
                coefficientEncoder.setBuffer(outputReal, offset: 0, index: 3)
                coefficientEncoder.setBuffer(outputImaginary, offset: 0, index: 4)
                coefficientEncoder.setBytes(
                    &coefficientParameters,
                    length: MemoryLayout<BatchedParameters>.stride,
                    index: 5
                )
                coefficientEncoder.dispatchThreads(
                    MTLSize(width: batchCount * sampleCount, height: 1, depth: 1),
                    threadsPerThreadgroup: threadgroupSize(for: batchedPipeline)
                )
                coefficientEncoder.endEncoding()

                guard let reductionEncoder = command.makeComputeCommandEncoder() else {
                    throw RhythmicityMetalError.allocationFailed
                }
                var reductionParameters = ReductionParameters(
                    sampleCount: UInt32(sampleCount),
                    validLower: UInt32(validRange.lowerBound),
                    validUpper: UInt32(validRange.upperBound),
                    wholeLag: UInt32(wholeLag),
                    frequencyIndex: UInt32(frequencyIndex),
                    frequencyCount: UInt32(frequenciesHz.count),
                    lagFraction: lagFraction
                )
                reductionEncoder.setComputePipelineState(reductionPipeline)
                reductionEncoder.setBuffer(outputReal, offset: 0, index: 0)
                reductionEncoder.setBuffer(outputImaginary, offset: 0, index: 1)
                reductionEncoder.setBuffer(reductions, offset: 0, index: 2)
                reductionEncoder.setBytes(
                    &reductionParameters,
                    length: MemoryLayout<ReductionParameters>.stride,
                    index: 3
                )
                reductionEncoder.dispatchThreads(
                    MTLSize(width: batchCount, height: 1, depth: 1),
                    threadsPerThreadgroup: threadgroupSize(for: reductionPipeline)
                )
                reductionEncoder.endEncoding()
            }
        }
        _ = retainedKernelBuffers
        command.commit()
        command.waitUntilCompleted()
        try cancellation.check()
        guard command.status == .completed else {
            throw RhythmicityMetalError.commandFailed(
                command.error?.localizedDescription ?? "unknown command-buffer error"
            )
        }

        let compact = readReductions(reductions, count: reductionCount)
        return (0..<batchCount).map { batchIndex in
            (0..<frequenciesHz.count).map { frequencyIndex in
                let reduction = compact[batchIndex * frequenciesHz.count + frequencyIndex]
                guard reduction.pairCount > 0,
                      reduction.firstEnergy > 0,
                      reduction.secondEnergy > 0 else { return Double.nan }
                let numerator = hypot(
                    Double(reduction.numeratorReal),
                    Double(reduction.numeratorImaginary)
                )
                let denominator = sqrt(
                    Double(reduction.firstEnergy) * Double(reduction.secondEnergy)
                )
                return min(max(numerator / denominator, 0), 1)
            }
        }
    }

    private func buffer<T>(_ values: [T]) -> MTLBuffer? {
        let length = max(values.count * MemoryLayout<T>.stride, 4)
        guard length <= device.maxBufferLength,
              let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        values.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                buffer.contents().copyMemory(from: baseAddress, byteCount: bytes.count)
            }
        }
        return buffer
    }

    private func emptyBuffer(count: Int) -> MTLBuffer? {
        let length = max(count * MemoryLayout<Float>.stride, 4)
        guard length <= device.maxBufferLength else { return nil }
        return device.makeBuffer(length: length, options: .storageModeShared)
    }

    private func read(_ buffer: MTLBuffer, count: Int) -> [Float] {
        Array(UnsafeBufferPointer(
            start: buffer.contents().bindMemory(to: Float.self, capacity: count),
            count: count
        ))
    }

    private func readReductions(_ buffer: MTLBuffer, count: Int) -> [MetalReduction] {
        Array(UnsafeBufferPointer(
            start: buffer.contents().bindMemory(to: MetalReduction.self, capacity: count),
            count: count
        ))
    }

    private func threadgroupSize(for pipeline: MTLComputePipelineState) -> MTLSize {
        MTLSize(
            width: min(
                pipeline.maxTotalThreadsPerThreadgroup,
                max(pipeline.threadExecutionWidth, 1)
            ),
            height: 1,
            depth: 1
        )
    }

    private func checkedProduct(_ left: Int, _ right: Int) throws -> Int {
        let result = left.multipliedReportingOverflow(by: right)
        guard !result.overflow else { throw RhythmicityMetalError.unsupportedShape }
        return result.partialValue
    }

    private func checkedSum(_ values: [Int]) throws -> Int {
        try values.reduce(0) { partial, value in
            let result = partial.addingReportingOverflow(value)
            guard !result.overflow else { throw RhythmicityMetalError.unsupportedShape }
            return result.partialValue
        }
    }
}
