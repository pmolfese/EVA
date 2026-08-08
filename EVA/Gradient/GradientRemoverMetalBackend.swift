//
//  GradientRemoverMetalBackend.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation
import Metal

/// Metal kernels for MAS/MAR median-template construction and subtraction.
nonisolated final class GradientRemoverMetalBackend: @unchecked Sendable {
    private struct Parameters {
        var trCount: UInt32
        var spacing: UInt32
        var fitRegression: UInt32
        var reserved: UInt32 = 0
    }

    private static let maxDonors = 128

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let medianPipeline: MTLComputePipelineState
    private let regressionPipeline: MTLComputePipelineState
    private let applyPipeline: MTLComputePipelineState

    static let shared: GradientRemoverMetalBackend? = GradientRemoverMetalBackend()
    static var isAvailable: Bool { shared != nil }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        guard let queue = device.makeCommandQueue() else {
            assertionFailure("Metal device could not create the MAS/MAR command queue.")
            return nil
        }
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: GradientRemoverMetalBackend.self)) else {
            assertionFailure("EVA's compiled default.metallib could not be loaded for MAS/MAR.")
            return nil
        }
        guard
              let median = library.makeFunction(name: "gradientMedianTemplates"),
              let regression = library.makeFunction(name: "gradientRegressionCoefficients"),
              let apply = library.makeFunction(name: "gradientApplyTemplates")
        else {
            assertionFailure("A required MAS/MAR function is missing from EVA's compiled Metal library.")
            return nil
        }
        guard
              let medianPipeline = try? device.makeComputePipelineState(function: median),
              let regressionPipeline = try? device.makeComputePipelineState(function: regression),
              let applyPipeline = try? device.makeComputePipelineState(function: apply)
        else {
            assertionFailure("A required MAS/MAR Metal compute pipeline could not be created.")
            return nil
        }

        self.device = device
        self.queue = queue
        self.medianPipeline = medianPipeline
        self.regressionPipeline = regressionPipeline
        self.applyPipeline = applyPipeline
    }

    func correctMedianSegments(
        _ segments: [[Float]],
        donors: [[Int]],
        fitRegression: Bool
    ) -> [[Float]]? {
        guard let spacing = segments.first?.count,
              spacing > 0,
              segments.count == donors.count,
              segments.allSatisfy({ $0.count == spacing }),
              donors.allSatisfy({ $0.count <= Self.maxDonors })
        else { return nil }

        let trCount = segments.count
        let sampleCount = trCount * spacing
        let flatSegments = segments.flatMap { $0 }
        var donorOffsets = [UInt32](repeating: 0, count: trCount + 1)
        var donorIndices: [UInt32] = []
        donorIndices.reserveCapacity(donors.reduce(0) { $0 + $1.count })
        for tr in 0..<trCount {
            donorOffsets[tr] = UInt32(donorIndices.count)
            donorIndices.append(contentsOf: donors[tr].map(UInt32.init))
        }
        donorOffsets[trCount] = UInt32(donorIndices.count)
        if donorIndices.isEmpty { donorIndices = [0] }

        var parameters = Parameters(
            trCount: UInt32(trCount),
            spacing: UInt32(spacing),
            fitRegression: fitRegression ? 1 : 0
        )
        guard let segmentBuffer = buffer(flatSegments),
              let offsetBuffer = buffer(donorOffsets),
              let donorBuffer = buffer(donorIndices),
              let templateBuffer = device.makeBuffer(length: sampleCount * MemoryLayout<Float>.stride,
                                                     options: .storageModeShared),
              let coefficientBuffer = device.makeBuffer(length: trCount * MemoryLayout<Float>.stride,
                                                        options: .storageModeShared),
              let outputBuffer = device.makeBuffer(length: sampleCount * MemoryLayout<Float>.stride,
                                                   options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer()
        else { return nil }

        guard let medianEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        medianEncoder.setComputePipelineState(medianPipeline)
        medianEncoder.setBuffer(segmentBuffer, offset: 0, index: 0)
        medianEncoder.setBuffer(offsetBuffer, offset: 0, index: 1)
        medianEncoder.setBuffer(donorBuffer, offset: 0, index: 2)
        medianEncoder.setBuffer(templateBuffer, offset: 0, index: 3)
        medianEncoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 4)
        dispatch(medianEncoder, pipeline: medianPipeline, count: sampleCount)
        medianEncoder.endEncoding()

        guard let regressionEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        regressionEncoder.setComputePipelineState(regressionPipeline)
        regressionEncoder.setBuffer(segmentBuffer, offset: 0, index: 0)
        regressionEncoder.setBuffer(templateBuffer, offset: 0, index: 1)
        regressionEncoder.setBuffer(coefficientBuffer, offset: 0, index: 2)
        regressionEncoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 3)
        dispatch(regressionEncoder, pipeline: regressionPipeline, count: trCount)
        regressionEncoder.endEncoding()

        guard let applyEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        applyEncoder.setComputePipelineState(applyPipeline)
        applyEncoder.setBuffer(segmentBuffer, offset: 0, index: 0)
        applyEncoder.setBuffer(templateBuffer, offset: 0, index: 1)
        applyEncoder.setBuffer(coefficientBuffer, offset: 0, index: 2)
        applyEncoder.setBuffer(outputBuffer, offset: 0, index: 3)
        applyEncoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 4)
        dispatch(applyEncoder, pipeline: applyPipeline, count: sampleCount)
        applyEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let output = floats(from: outputBuffer, count: sampleCount)
        return (0..<trCount).map { tr in
            Array(output[(tr * spacing)..<((tr + 1) * spacing)])
        }
    }

    private func buffer<T>(_ values: [T]) -> MTLBuffer? {
        values.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }
    }

    private func floats(from buffer: MTLBuffer, count: Int) -> [Float] {
        let pointer = buffer.contents().bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, count: Int) {
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
    }

}
