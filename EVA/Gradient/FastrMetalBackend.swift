//
//  FastrMetalBackend.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Accelerate
import Foundation
import Metal

/// Metal acceleration for the dense Float kernels in FASTR. Algorithmic choices
/// (alignment, donor selection, OBS PCA, and ANC) remain in `FastrCorrector`.
nonisolated final class FastrMetalBackend: @unchecked Sendable {
    private struct ResampleParameters {
        var inputCount: UInt32
        var outputCount: UInt32
        var factor: UInt32
        var tapCount: UInt32
        var mean: Float
    }

    private struct BatchResampleParameters {
        var inputCount: UInt32
        var outputCount: UInt32
        var factor: UInt32
        var tapCount: UInt32
        var channelCount: UInt32
    }

    private struct TemplateParameters {
        var sampleCount: UInt32
        var epochCount: UInt32
        var artifactLength: UInt32
        var fixedAlpha: UInt32
    }

    private struct BatchTemplateParameters {
        var sampleCount: UInt32
        var epochCount: UInt32
        var artifactLength: UInt32
        var prePeak: UInt32
        var channelCount: UInt32
        var epochOffset: UInt32
    }

    private struct OBSParameters {
        var sampleCount: UInt32
        var epochCount: UInt32
        var artifactLength: UInt32
        var basisCount: UInt32
    }

    private struct OBSChannelParameters {
        var sampleCount: UInt32
        var epochCount: UInt32
        var artifactLength: UInt32
        var basisCount: UInt32
        var channelCount: UInt32
    }

    private struct BatchFIRParameters {
        var sampleCount: UInt32
        var tapCount: UInt32
        var channelCount: UInt32
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let interpolatePipeline: MTLComputePipelineState
    private let batchInterpolatePipeline: MTLComputePipelineState
    private let templateAlphaPipeline: MTLComputePipelineState
    private let templateNoisePipeline: MTLComputePipelineState
    private let batchTemplateNoisePipeline: MTLComputePipelineState
    private let correctDecimatePipeline: MTLComputePipelineState
    private let batchCorrectDecimatePipeline: MTLComputePipelineState
    private let obsCoefficientPipeline: MTLComputePipelineState
    private let obsFitPipeline: MTLComputePipelineState
    private let obsCoefficientChannelsPipeline: MTLComputePipelineState
    private let obsFitChannelsPipeline: MTLComputePipelineState
    private let batchFIRFilterPipeline: MTLComputePipelineState

    static let shared: FastrMetalBackend? = FastrMetalBackend()
    static var isAvailable: Bool { shared != nil }

    /// The device's single-buffer size limit, used to bound how many
    /// channels can be batched into one GPU dispatch (the largest per-batch
    /// buffer is one Float array sized channelCount x upsampled-sample-count).
    var maxBufferLength: Int { device.maxBufferLength }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        guard let queue = device.makeCommandQueue() else {
            assertionFailure("Metal device could not create the FASTR command queue.")
            return nil
        }
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: FastrMetalBackend.self)) else {
            assertionFailure("EVA's compiled default.metallib could not be loaded for FASTR.")
            return nil
        }
        guard
              let interpolate = library.makeFunction(name: "fastrInterpolate"),
              let batchInterpolate = library.makeFunction(name: "fastrInterpolateChannels"),
              let templateAlpha = library.makeFunction(name: "fastrTemplateAlpha"),
              let templateNoise = library.makeFunction(name: "fastrTemplateNoise"),
              let batchTemplateNoise = library.makeFunction(name: "fastrAverageTemplateNoiseChannels"),
              let correctDecimate = library.makeFunction(name: "fastrCorrectDecimate"),
              let batchCorrectDecimate = library.makeFunction(name: "fastrCorrectDecimateChannels"),
              let obsCoefficient = library.makeFunction(name: "fastrOBSCoefficients"),
              let obsFit = library.makeFunction(name: "fastrOBSFits"),
              let obsCoefficientChannels = library.makeFunction(name: "fastrOBSCoefficientsChannels"),
              let obsFitChannels = library.makeFunction(name: "fastrOBSFitsChannels"),
              let batchFIRFilter = library.makeFunction(name: "fastrBatchFIRFilter")
        else {
            assertionFailure("A required FASTR function is missing from EVA's compiled Metal library.")
            return nil
        }
        guard
              let interpolatePipeline = try? device.makeComputePipelineState(function: interpolate),
              let batchInterpolatePipeline = try? device.makeComputePipelineState(function: batchInterpolate),
              let templateAlphaPipeline = try? device.makeComputePipelineState(function: templateAlpha),
              let templateNoisePipeline = try? device.makeComputePipelineState(function: templateNoise),
              let batchTemplateNoisePipeline = try? device.makeComputePipelineState(function: batchTemplateNoise),
              let correctDecimatePipeline = try? device.makeComputePipelineState(function: correctDecimate),
              let batchCorrectDecimatePipeline = try? device.makeComputePipelineState(function: batchCorrectDecimate),
              let obsCoefficientPipeline = try? device.makeComputePipelineState(function: obsCoefficient),
              let obsFitPipeline = try? device.makeComputePipelineState(function: obsFit),
              let obsCoefficientChannelsPipeline = try? device.makeComputePipelineState(function: obsCoefficientChannels),
              let obsFitChannelsPipeline = try? device.makeComputePipelineState(function: obsFitChannels),
              let batchFIRFilterPipeline = try? device.makeComputePipelineState(function: batchFIRFilter)
        else {
            assertionFailure("A required FASTR Metal compute pipeline could not be created.")
            return nil
        }

        self.device = device
        self.queue = queue
        self.interpolatePipeline = interpolatePipeline
        self.batchInterpolatePipeline = batchInterpolatePipeline
        self.templateAlphaPipeline = templateAlphaPipeline
        self.templateNoisePipeline = templateNoisePipeline
        self.batchTemplateNoisePipeline = batchTemplateNoisePipeline
        self.correctDecimatePipeline = correctDecimatePipeline
        self.batchCorrectDecimatePipeline = batchCorrectDecimatePipeline
        self.obsCoefficientPipeline = obsCoefficientPipeline
        self.obsFitPipeline = obsFitPipeline
        self.obsCoefficientChannelsPipeline = obsCoefficientChannelsPipeline
        self.obsFitChannelsPipeline = obsFitChannelsPipeline
        self.batchFIRFilterPipeline = batchFIRFilterPipeline
    }

    func interpolate(_ input: [Float], factor: Int, subtractMean: Bool) -> [Double]? {
        guard !input.isEmpty else { return [] }
        guard factor > 1 else {
            if !subtractMean { return input.map(Double.init) }
            let mean = input.reduce(0, +) / Float(input.count)
            return input.map { Double($0 - mean) }
        }

        let tapValues = DSP.windowedSincLowPass(
            numtaps: 2 * 4 * factor + 1,
            cutoff: 1.0 / Double(factor),
            gain: Double(factor)
        ).map(Float.init)
        let outputCount = input.count * factor
        let mean = subtractMean ? input.reduce(0, +) / Float(input.count) : 0
        var parameters = ResampleParameters(
            inputCount: UInt32(input.count),
            outputCount: UInt32(outputCount),
            factor: UInt32(factor),
            tapCount: UInt32(tapValues.count),
            mean: mean
        )

        guard let inputBuffer = buffer(input),
              let tapsBuffer = buffer(tapValues),
              let outputBuffer = device.makeBuffer(length: outputCount * MemoryLayout<Float>.stride,
                                                    options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(interpolatePipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(tapsBuffer, offset: 0, index: 1)
        encoder.setBuffer(outputBuffer, offset: 0, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<ResampleParameters>.stride, index: 3)
        dispatch(encoder, pipeline: interpolatePipeline, count: outputCount)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        return floats(from: outputBuffer, count: outputCount).map(Double.init)
    }

    func interpolateChannels(
        _ inputs: [[Float]],
        factor: Int,
        subtractMean: Bool
    ) -> [[Double]]? {
        guard let inputCount = inputs.first?.count,
              inputCount > 0,
              inputs.allSatisfy({ $0.count == inputCount })
        else { return inputs.isEmpty ? [] : nil }
        guard factor > 1 else {
            return inputs.map { input in
                guard subtractMean else { return input.map(Double.init) }
                let mean = input.reduce(0, +) / Float(input.count)
                return input.map { Double($0 - mean) }
            }
        }

        let taps = DSP.windowedSincLowPass(
            numtaps: 2 * 4 * factor + 1,
            cutoff: 1.0 / Double(factor),
            gain: Double(factor)
        ).map(Float.init)
        let channelCount = inputs.count
        let outputCount = inputCount * factor
        let flatInput = inputs.flatMap { $0 }
        let means = subtractMean
            ? inputs.map { $0.reduce(0, +) / Float($0.count) }
            : [Float](repeating: 0, count: channelCount)
        var parameters = BatchResampleParameters(
            inputCount: UInt32(inputCount),
            outputCount: UInt32(outputCount),
            factor: UInt32(factor),
            tapCount: UInt32(taps.count),
            channelCount: UInt32(channelCount)
        )
        let totalOutputCount = channelCount * outputCount

        guard let inputBuffer = buffer(flatInput),
              let tapsBuffer = buffer(taps),
              let meansBuffer = buffer(means),
              let outputBuffer = device.makeBuffer(
                length: totalOutputCount * MemoryLayout<Float>.stride,
                options: .storageModeShared
              ),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(batchInterpolatePipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(tapsBuffer, offset: 0, index: 1)
        encoder.setBuffer(meansBuffer, offset: 0, index: 2)
        encoder.setBuffer(outputBuffer, offset: 0, index: 3)
        encoder.setBytes(&parameters, length: MemoryLayout<BatchResampleParameters>.stride, index: 4)
        dispatch(encoder, pipeline: batchInterpolatePipeline, count: totalOutputCount)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let output = floats(from: outputBuffer, count: totalOutputCount)
        return (0..<channelCount).map { channel in
            let start = channel * outputCount
            return output[start..<(start + outputCount)].map(Double.init)
        }
    }

    func buildTemplateNoise(
        data: [Double],
        templates: [[Double]?],
        targetStarts: [Int],
        fixedAlpha: Bool
    ) -> [Double]? {
        guard !data.isEmpty, templates.count == targetStarts.count else { return nil }
        guard let artifactLength = templates.compactMap({ $0?.count }).first, artifactLength > 0 else {
            return [Double](repeating: 0, count: data.count)
        }

        let epochCount = templates.count
        var flatTemplates = [Float](repeating: 0, count: epochCount * artifactLength)
        var valid = [UInt32](repeating: 0, count: epochCount)
        var owner = [Int32](repeating: -1, count: data.count)
        for epoch in 0..<epochCount {
            guard let template = templates[epoch], template.count == artifactLength else { continue }
            let start = targetStarts[epoch]
            guard start >= 0, start + artifactLength <= data.count else { continue }
            valid[epoch] = 1
            let base = epoch * artifactLength
            for i in 0..<artifactLength {
                flatTemplates[base + i] = Float(template[i])
                owner[start + i] = Int32(epoch)
            }
        }

        var parameters = TemplateParameters(
            sampleCount: UInt32(data.count),
            epochCount: UInt32(epochCount),
            artifactLength: UInt32(artifactLength),
            fixedAlpha: fixedAlpha ? 1 : 0
        )
        let dataFloat = data.map(Float.init)
        let starts = targetStarts.map(Int32.init)
        guard let dataBuffer = buffer(dataFloat),
              let templatesBuffer = buffer(flatTemplates),
              let startsBuffer = buffer(starts),
              let validBuffer = buffer(valid),
              let ownerBuffer = buffer(owner),
              let alphaBuffer = device.makeBuffer(length: epochCount * MemoryLayout<Float>.stride,
                                                  options: .storageModeShared),
              let noiseBuffer = device.makeBuffer(length: data.count * MemoryLayout<Float>.stride,
                                                  options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer()
        else { return nil }

        guard let alphaEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        alphaEncoder.setComputePipelineState(templateAlphaPipeline)
        alphaEncoder.setBuffer(dataBuffer, offset: 0, index: 0)
        alphaEncoder.setBuffer(templatesBuffer, offset: 0, index: 1)
        alphaEncoder.setBuffer(startsBuffer, offset: 0, index: 2)
        alphaEncoder.setBuffer(validBuffer, offset: 0, index: 3)
        alphaEncoder.setBuffer(alphaBuffer, offset: 0, index: 4)
        alphaEncoder.setBytes(&parameters, length: MemoryLayout<TemplateParameters>.stride, index: 5)
        dispatch(alphaEncoder, pipeline: templateAlphaPipeline, count: epochCount)
        alphaEncoder.endEncoding()

        guard let noiseEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        noiseEncoder.setComputePipelineState(templateNoisePipeline)
        noiseEncoder.setBuffer(templatesBuffer, offset: 0, index: 0)
        noiseEncoder.setBuffer(startsBuffer, offset: 0, index: 1)
        noiseEncoder.setBuffer(ownerBuffer, offset: 0, index: 2)
        noiseEncoder.setBuffer(alphaBuffer, offset: 0, index: 3)
        noiseEncoder.setBuffer(noiseBuffer, offset: 0, index: 4)
        noiseEncoder.setBytes(&parameters, length: MemoryLayout<TemplateParameters>.stride, index: 5)
        dispatch(noiseEncoder, pipeline: templateNoisePipeline, count: data.count)
        noiseEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        return floats(from: noiseBuffer, count: data.count).map(Double.init)
    }

    func buildTemplateNoiseChannels(
        data: [[Double]],
        markers: [Int],
        targetStarts: [Int],
        donorRows: [[Int]],
        prePeak: Int,
        artifactLength: Int,
        fixedAlpha: [Bool]
    ) -> [[Double]]? {
        buildTemplateNoiseChannels(
            data: data,
            markers: markers,
            targetStarts: targetStarts,
            donorRows: donorRows,
            prePeak: prePeak,
            artifactLength: artifactLength,
            fixedAlpha: fixedAlpha,
            epochChunkSize: 256
        )
    }

    func buildTemplateNoiseChannels(
        data: [[Double]],
        markers: [Int],
        targetStarts: [Int],
        donorRows: [[Int]],
        prePeak: Int,
        artifactLength: Int,
        fixedAlpha: [Bool],
        epochChunkSize: Int
    ) -> [[Double]]? {
        guard let sampleCount = data.first?.count,
              sampleCount > 0,
              !markers.isEmpty,
              markers.count == targetStarts.count,
              markers.count == donorRows.count,
              artifactLength > 0,
              epochChunkSize > 0,
              prePeak >= 0,
              data.allSatisfy({ $0.count == sampleCount }),
              fixedAlpha.count == data.count
        else { return nil }

        var donorOffsets = [UInt32]()
        donorOffsets.reserveCapacity(donorRows.count + 1)
        donorOffsets.append(0)
        var donorIndices = [UInt32]()
        for row in donorRows {
            for donor in row {
                guard donor >= 0, donor < markers.count else { return nil }
                donorIndices.append(UInt32(donor))
            }
            donorOffsets.append(UInt32(donorIndices.count))
        }
        guard !donorIndices.isEmpty else {
            return data.map { _ in [Double](repeating: 0, count: sampleCount) }
        }

        let validStarts = targetStarts.map { start in
            start >= 0 && start + artifactLength <= sampleCount ? Int32(start) : -1
        }
        var owner = [Int32](repeating: -1, count: sampleCount)
        for epoch in targetStarts.indices where validStarts[epoch] >= 0 && !donorRows[epoch].isEmpty {
            let start = Int(validStarts[epoch])
            for sample in 0..<artifactLength {
                owner[start + sample] = Int32(epoch)
            }
        }

        let channelCount = data.count
        let flatData = data.flatMap { $0.map(Float.init) }
        let markerValues = markers.map(Int32.init)
        let fixedValues = fixedAlpha.map { $0 ? UInt32(1) : UInt32(0) }
        var parameters = BatchTemplateParameters(
            sampleCount: UInt32(sampleCount),
            epochCount: UInt32(markers.count),
            artifactLength: UInt32(artifactLength),
            prePeak: UInt32(prePeak),
            channelCount: UInt32(channelCount),
            epochOffset: 0
        )

        let threadLimit = min(batchTemplateNoisePipeline.maxTotalThreadsPerThreadgroup, 256)
        var threadCount = 1
        while threadCount <= threadLimit / 2 { threadCount *= 2 }
        let scratchLength = (artifactLength + 2 * threadCount) * MemoryLayout<Float>.stride
        guard scratchLength <= device.maxThreadgroupMemoryLength,
              let dataBuffer = buffer(flatData),
              let markersBuffer = buffer(markerValues),
              let startsBuffer = buffer(validStarts),
              let offsetsBuffer = buffer(donorOffsets),
              let donorsBuffer = buffer(donorIndices),
              let ownerBuffer = buffer(owner),
              let fixedBuffer = buffer(fixedValues),
              let noiseBuffer = device.makeBuffer(
                length: channelCount * sampleCount * MemoryLayout<Float>.stride,
                options: .storageModeShared
              )
        else { return nil }

        for chunkStart in stride(from: 0, to: markers.count, by: epochChunkSize) {
            guard !Task.isCancelled else { return nil }
            let chunkEnd = min(chunkStart + epochChunkSize, markers.count)
            parameters.epochOffset = UInt32(chunkStart)

            guard let commandBuffer = queue.makeCommandBuffer() else { return nil }
            commandBuffer.label = "FASTR templates \(chunkStart)..<\(chunkEnd)"
            if chunkStart == 0 {
                guard let clearEncoder = commandBuffer.makeBlitCommandEncoder() else { return nil }
                clearEncoder.fill(buffer: noiseBuffer, range: 0..<noiseBuffer.length, value: 0)
                clearEncoder.endEncoding()
            }

            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(batchTemplateNoisePipeline)
            encoder.setBuffer(dataBuffer, offset: 0, index: 0)
            encoder.setBuffer(markersBuffer, offset: 0, index: 1)
            encoder.setBuffer(startsBuffer, offset: 0, index: 2)
            encoder.setBuffer(offsetsBuffer, offset: 0, index: 3)
            encoder.setBuffer(donorsBuffer, offset: 0, index: 4)
            encoder.setBuffer(ownerBuffer, offset: 0, index: 5)
            encoder.setBuffer(fixedBuffer, offset: 0, index: 6)
            encoder.setBuffer(noiseBuffer, offset: 0, index: 7)
            encoder.setBytes(&parameters, length: MemoryLayout<BatchTemplateParameters>.stride, index: 8)
            encoder.setThreadgroupMemoryLength(scratchLength, index: 0)
            encoder.dispatchThreadgroups(
                MTLSize(width: chunkEnd - chunkStart, height: channelCount, depth: 1),
                threadsPerThreadgroup: MTLSize(width: threadCount, height: 1, depth: 1)
            )
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard commandBuffer.status == .completed else {
                let detail = commandBuffer.error?.localizedDescription ?? "status \(commandBuffer.status.rawValue)"
                NSLog("FASTR Metal template chunk failed: %@", detail)
                return nil
            }
        }

        let values = floats(from: noiseBuffer, count: channelCount * sampleCount)
        return (0..<channelCount).map { channel in
            let start = channel * sampleCount
            return values[start..<(start + sampleCount)].map(Double.init)
        }
    }

    func correctAndDecimate(
        original: [Double],
        templateNoise: [Double],
        residualNoise: [Double],
        factor: Int,
        targetCount: Int
    ) -> (clean: [Double], noise: [Double])? {
        guard original.count == templateNoise.count,
              original.count == residualNoise.count,
              !original.isEmpty else { return nil }

        let taps = factor > 1
            ? DSP.windowedSincLowPass(numtaps: 31, cutoff: 1.0 / Double(factor), gain: 1).map(Float.init)
            : [1]
        var parameters = ResampleParameters(
            inputCount: UInt32(original.count),
            outputCount: UInt32(targetCount),
            factor: UInt32(max(1, factor)),
            tapCount: UInt32(taps.count),
            mean: 0
        )
        guard let originalBuffer = buffer(original.map(Float.init)),
              let templateBuffer = buffer(templateNoise.map(Float.init)),
              let residualBuffer = buffer(residualNoise.map(Float.init)),
              let tapsBuffer = buffer(taps),
              let cleanBuffer = device.makeBuffer(length: targetCount * MemoryLayout<Float>.stride,
                                                  options: .storageModeShared),
              let noiseBuffer = device.makeBuffer(length: targetCount * MemoryLayout<Float>.stride,
                                                  options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(correctDecimatePipeline)
        encoder.setBuffer(originalBuffer, offset: 0, index: 0)
        encoder.setBuffer(templateBuffer, offset: 0, index: 1)
        encoder.setBuffer(residualBuffer, offset: 0, index: 2)
        encoder.setBuffer(tapsBuffer, offset: 0, index: 3)
        encoder.setBuffer(cleanBuffer, offset: 0, index: 4)
        encoder.setBuffer(noiseBuffer, offset: 0, index: 5)
        encoder.setBytes(&parameters, length: MemoryLayout<ResampleParameters>.stride, index: 6)
        dispatch(encoder, pipeline: correctDecimatePipeline, count: targetCount)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        return (
            floats(from: cleanBuffer, count: targetCount).map(Double.init),
            floats(from: noiseBuffer, count: targetCount).map(Double.init)
        )
    }

    func correctAndDecimateChannels(
        original: [[Double]],
        templateNoise: [[Double]],
        residualNoise: [[Double]],
        factor: Int,
        targetCount: Int
    ) -> (clean: [[Double]], noise: [[Double]])? {
        guard let inputCount = original.first?.count,
              inputCount > 0,
              original.count == templateNoise.count,
              original.count == residualNoise.count,
              original.allSatisfy({ $0.count == inputCount }),
              templateNoise.allSatisfy({ $0.count == inputCount }),
              residualNoise.allSatisfy({ $0.count == inputCount }),
              targetCount > 0
        else { return nil }

        let taps = factor > 1
            ? DSP.windowedSincLowPass(numtaps: 31, cutoff: 1.0 / Double(factor), gain: 1).map(Float.init)
            : [1]
        let channelCount = original.count
        var parameters = BatchResampleParameters(
            inputCount: UInt32(inputCount),
            outputCount: UInt32(targetCount),
            factor: UInt32(max(1, factor)),
            tapCount: UInt32(taps.count),
            channelCount: UInt32(channelCount)
        )
        let totalOutputCount = channelCount * targetCount
        guard let originalBuffer = buffer(original.flatMap { $0.map(Float.init) }),
              let templateBuffer = buffer(templateNoise.flatMap { $0.map(Float.init) }),
              let residualBuffer = buffer(residualNoise.flatMap { $0.map(Float.init) }),
              let tapsBuffer = buffer(taps),
              let cleanBuffer = device.makeBuffer(
                length: totalOutputCount * MemoryLayout<Float>.stride,
                options: .storageModeShared
              ),
              let noiseBuffer = device.makeBuffer(
                length: totalOutputCount * MemoryLayout<Float>.stride,
                options: .storageModeShared
              ),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(batchCorrectDecimatePipeline)
        encoder.setBuffer(originalBuffer, offset: 0, index: 0)
        encoder.setBuffer(templateBuffer, offset: 0, index: 1)
        encoder.setBuffer(residualBuffer, offset: 0, index: 2)
        encoder.setBuffer(tapsBuffer, offset: 0, index: 3)
        encoder.setBuffer(cleanBuffer, offset: 0, index: 4)
        encoder.setBuffer(noiseBuffer, offset: 0, index: 5)
        encoder.setBytes(&parameters, length: MemoryLayout<BatchResampleParameters>.stride, index: 6)
        dispatch(encoder, pipeline: batchCorrectDecimatePipeline, count: totalOutputCount)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let clean = floats(from: cleanBuffer, count: totalOutputCount)
        let noise = floats(from: noiseBuffer, count: totalOutputCount)
        func channels(from values: [Float]) -> [[Double]] {
            (0..<channelCount).map { channel in
                let start = channel * targetCount
                return values[start..<(start + targetCount)].map(Double.init)
            }
        }
        return (channels(from: clean), channels(from: noise))
    }

    func fitOptimalBasis(
        data: [Double],
        epochStarts: [Int],
        columns: [[Double]]
    ) -> [Double]? {
        let basisCount = columns.count
        guard !data.isEmpty,
              !epochStarts.isEmpty,
              basisCount > 0,
              basisCount <= 32,
              let artifactLength = columns.first?.count,
              artifactLength > 0,
              columns.allSatisfy({ $0.count == artifactLength })
        else { return nil }

        var gram = [[Double]](
            repeating: [Double](repeating: 0, count: basisCount),
            count: basisCount
        )
        for row in 0..<basisCount {
            for column in row..<basisCount {
                var value = 0.0
                vDSP_dotprD(
                    columns[row], 1, columns[column], 1,
                    &value, vDSP_Length(artifactLength)
                )
                gram[row][column] = value
                gram[column][row] = value
            }
        }

        var inverse = [Double](repeating: 0, count: basisCount * basisCount)
        for column in 0..<basisCount {
            var unit = [Double](repeating: 0, count: basisCount)
            unit[column] = 1
            guard let solution = LinearAlgebra.solveLinearSystem(gram, unit) else { return nil }
            for row in 0..<basisCount {
                inverse[row * basisCount + column] = solution[row]
            }
        }

        var dual = [Float](repeating: 0, count: basisCount * artifactLength)
        for row in 0..<basisCount {
            for sample in 0..<artifactLength {
                var value = 0.0
                for column in 0..<basisCount {
                    value += inverse[row * basisCount + column] * columns[column][sample]
                }
                dual[row * artifactLength + sample] = Float(value)
            }
        }

        let validStarts = epochStarts.map { start in
            start >= 0 && start + artifactLength <= data.count ? Int32(start) : -1
        }
        let flatColumns = columns.flatMap { $0.map(Float.init) }
        var parameters = OBSParameters(
            sampleCount: UInt32(data.count),
            epochCount: UInt32(epochStarts.count),
            artifactLength: UInt32(artifactLength),
            basisCount: UInt32(basisCount)
        )
        let coefficientCount = epochStarts.count * basisCount
        let fitCount = epochStarts.count * artifactLength
        guard let dataBuffer = buffer(data.map(Float.init)),
              let startsBuffer = buffer(validStarts),
              let dualBuffer = buffer(dual),
              let columnsBuffer = buffer(flatColumns),
              let coefficientBuffer = device.makeBuffer(
                length: coefficientCount * MemoryLayout<Float>.stride,
                options: .storageModeShared
              ),
              let fitBuffer = device.makeBuffer(
                length: fitCount * MemoryLayout<Float>.stride,
                options: .storageModeShared
              ),
              let commandBuffer = queue.makeCommandBuffer()
        else { return nil }

        guard let coefficientEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        coefficientEncoder.setComputePipelineState(obsCoefficientPipeline)
        coefficientEncoder.setBuffer(dataBuffer, offset: 0, index: 0)
        coefficientEncoder.setBuffer(startsBuffer, offset: 0, index: 1)
        coefficientEncoder.setBuffer(dualBuffer, offset: 0, index: 2)
        coefficientEncoder.setBuffer(coefficientBuffer, offset: 0, index: 3)
        coefficientEncoder.setBytes(&parameters, length: MemoryLayout<OBSParameters>.stride, index: 4)
        dispatch(coefficientEncoder, pipeline: obsCoefficientPipeline, count: coefficientCount)
        coefficientEncoder.endEncoding()

        guard let fitEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        fitEncoder.setComputePipelineState(obsFitPipeline)
        fitEncoder.setBuffer(startsBuffer, offset: 0, index: 0)
        fitEncoder.setBuffer(columnsBuffer, offset: 0, index: 1)
        fitEncoder.setBuffer(coefficientBuffer, offset: 0, index: 2)
        fitEncoder.setBuffer(fitBuffer, offset: 0, index: 3)
        fitEncoder.setBytes(&parameters, length: MemoryLayout<OBSParameters>.stride, index: 4)
        dispatch(fitEncoder, pipeline: obsFitPipeline, count: fitCount)
        fitEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let fits = floats(from: fitBuffer, count: fitCount)
        var fitted = [Double](repeating: 0, count: data.count)
        for epoch in epochStarts.indices {
            let start = validStarts[epoch]
            guard start >= 0 else { continue }
            let fitBase = epoch * artifactLength
            for sample in 0..<artifactLength {
                fitted[Int(start) + sample] = Double(fits[fitBase + sample])
            }
        }
        return fitted
    }

    /// Channel-batched OBS fit. Fits every channel's PCA design onto its
    /// high-passed residual in a single dispatch instead of one Metal round
    /// trip per channel — the per-channel calls previously ran from inside a
    /// concurrent CPU loop, which serialized on the shared command queue and
    /// let per-call dispatch overhead dominate the (tiny) actual GPU work.
    ///
    /// `columnsPerChannel[c]` may have a different basis count than other
    /// channels (auto PC selection is data-dependent); rows are zero-padded
    /// up to the batch's max basis count so a single dispatch shape covers
    /// every channel — the zero rows contribute nothing to the fit. An empty
    /// `columnsPerChannel[c]` means OBS was skipped for that channel and its
    /// result is all zero.
    func fitOptimalBasisChannels(
        data: [[Double]],
        epochStarts: [Int],
        columnsPerChannel: [[[Double]]]
    ) -> [[Double]]? {
        let channelCount = data.count
        guard channelCount > 0,
              channelCount == columnsPerChannel.count,
              !epochStarts.isEmpty,
              let sampleCount = data.first?.count,
              sampleCount > 0,
              data.allSatisfy({ $0.count == sampleCount })
        else { return nil }

        let artifactLength = columnsPerChannel.compactMap { $0.first?.count }.first ?? 0
        let maxBasisCount = columnsPerChannel.map(\.count).max() ?? 0
        guard artifactLength > 0, maxBasisCount > 0, maxBasisCount <= 32 else {
            return data.map { _ in [Double](repeating: 0, count: sampleCount) }
        }
        guard columnsPerChannel.allSatisfy({ $0.allSatisfy { $0.count == artifactLength } }) else { return nil }

        // Per-channel dual basis (pseudoinverse of the design columns), computed
        // on the CPU as in the single-channel path, then packed with the
        // channel's (possibly zero-padded) design columns.
        var flatDual = [Float](repeating: 0, count: channelCount * maxBasisCount * artifactLength)
        var flatColumns = [Float](repeating: 0, count: channelCount * maxBasisCount * artifactLength)
        for channel in 0..<channelCount {
            let columns = columnsPerChannel[channel]
            let basisCount = columns.count
            guard basisCount > 0 else { continue }

            var gram = [[Double]](repeating: [Double](repeating: 0, count: basisCount), count: basisCount)
            for row in 0..<basisCount {
                for column in row..<basisCount {
                    var value = 0.0
                    vDSP_dotprD(columns[row], 1, columns[column], 1, &value, vDSP_Length(artifactLength))
                    gram[row][column] = value
                    gram[column][row] = value
                }
            }
            var inverse = [Double](repeating: 0, count: basisCount * basisCount)
            for column in 0..<basisCount {
                var unit = [Double](repeating: 0, count: basisCount)
                unit[column] = 1
                guard let solution = LinearAlgebra.solveLinearSystem(gram, unit) else { return nil }
                for row in 0..<basisCount {
                    inverse[row * basisCount + column] = solution[row]
                }
            }

            let channelBase = channel * maxBasisCount * artifactLength
            for row in 0..<basisCount {
                let dualBase = channelBase + row * artifactLength
                let columnsBase = channelBase + row * artifactLength
                for sample in 0..<artifactLength {
                    var value = 0.0
                    for column in 0..<basisCount {
                        value += inverse[row * basisCount + column] * columns[column][sample]
                    }
                    flatDual[dualBase + sample] = Float(value)
                    flatColumns[columnsBase + sample] = Float(columns[row][sample])
                }
            }
        }

        let validStarts = epochStarts.map { start in
            start >= 0 && start + artifactLength <= sampleCount ? Int32(start) : -1
        }
        let flatData = data.flatMap { $0.map(Float.init) }
        var parameters = OBSChannelParameters(
            sampleCount: UInt32(sampleCount),
            epochCount: UInt32(epochStarts.count),
            artifactLength: UInt32(artifactLength),
            basisCount: UInt32(maxBasisCount),
            channelCount: UInt32(channelCount)
        )
        let coefficientCount = channelCount * epochStarts.count * maxBasisCount
        let fitCount = channelCount * epochStarts.count * artifactLength
        guard let dataBuffer = buffer(flatData),
              let startsBuffer = buffer(validStarts),
              let dualBuffer = buffer(flatDual),
              let columnsBuffer = buffer(flatColumns),
              let coefficientBuffer = device.makeBuffer(
                length: coefficientCount * MemoryLayout<Float>.stride,
                options: .storageModeShared
              ),
              let fitBuffer = device.makeBuffer(
                length: fitCount * MemoryLayout<Float>.stride,
                options: .storageModeShared
              ),
              let commandBuffer = queue.makeCommandBuffer()
        else { return nil }

        guard let coefficientEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        coefficientEncoder.setComputePipelineState(obsCoefficientChannelsPipeline)
        coefficientEncoder.setBuffer(dataBuffer, offset: 0, index: 0)
        coefficientEncoder.setBuffer(startsBuffer, offset: 0, index: 1)
        coefficientEncoder.setBuffer(dualBuffer, offset: 0, index: 2)
        coefficientEncoder.setBuffer(coefficientBuffer, offset: 0, index: 3)
        coefficientEncoder.setBytes(&parameters, length: MemoryLayout<OBSChannelParameters>.stride, index: 4)
        dispatch(coefficientEncoder, pipeline: obsCoefficientChannelsPipeline, count: coefficientCount)
        coefficientEncoder.endEncoding()

        guard let fitEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        fitEncoder.setComputePipelineState(obsFitChannelsPipeline)
        fitEncoder.setBuffer(startsBuffer, offset: 0, index: 0)
        fitEncoder.setBuffer(columnsBuffer, offset: 0, index: 1)
        fitEncoder.setBuffer(coefficientBuffer, offset: 0, index: 2)
        fitEncoder.setBuffer(fitBuffer, offset: 0, index: 3)
        fitEncoder.setBytes(&parameters, length: MemoryLayout<OBSChannelParameters>.stride, index: 4)
        dispatch(fitEncoder, pipeline: obsFitChannelsPipeline, count: fitCount)
        fitEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let fits = floats(from: fitBuffer, count: fitCount)
        return (0..<channelCount).map { channel in
            var fitted = [Double](repeating: 0, count: sampleCount)
            guard !columnsPerChannel[channel].isEmpty else { return fitted }
            let channelBase = channel * epochStarts.count * artifactLength
            for epoch in epochStarts.indices {
                let start = validStarts[epoch]
                guard start >= 0 else { continue }
                let fitBase = channelBase + epoch * artifactLength
                for sample in 0..<artifactLength {
                    fitted[Int(start) + sample] = Double(fits[fitBase + sample])
                }
            }
            return fitted
        }
    }

    /// Channel-batched zero-phase (forward-backward) FIR filtering — matches
    /// `DSP.filtfiltFIR(taps, signal)` applied to every row of `signals`, but
    /// does the O(N·taps) convolution for the whole batch in two GPU
    /// dispatches total instead of one CPU `filtfiltFIR` call (two
    /// convolution passes each) per channel.
    ///
    /// Reflection padding and the final forward/reverse/forward/reverse
    /// sequence mirror `DSP.filtfiltFIR` exactly; only the convolution passes
    /// themselves move to the GPU, with the (cheap, O(pad)) padding and
    /// reversal done on the CPU between dispatches.
    func filtfiltChannels(taps: [Double], signals: [[Double]]) -> [[Double]]? {
        let nb = taps.count
        guard nb > 1,
              let sampleCount = signals.first?.count,
              sampleCount > 3 * (nb - 1),
              signals.allSatisfy({ $0.count == sampleCount })
        else { return nil }

        let pad = 3 * (nb - 1)
        let extLength = sampleCount + 2 * pad
        let channelCount = signals.count
        let tapsFloat = taps.map(Float.init)

        // Odd (point-symmetric) reflection padding, matching DSP.filtfiltFIR.
        var ext = [Float](repeating: 0, count: channelCount * extLength)
        for c in 0..<channelCount {
            let x = signals[c]
            let base = c * extLength
            for i in 0..<pad { ext[base + i] = Float(2 * x[0] - x[pad - i]) }
            for i in 0..<sampleCount { ext[base + pad + i] = Float(x[i]) }
            let last = sampleCount - 1
            for i in 0..<pad { ext[base + pad + sampleCount + i] = Float(2 * x[last] - x[last - 1 - i]) }
        }

        guard let firstPass = runBatchFIR(ext, taps: tapsFloat, sampleCount: extLength, channelCount: channelCount)
        else { return nil }

        var reversed = [Float](repeating: 0, count: channelCount * extLength)
        for c in 0..<channelCount {
            let base = c * extLength
            for i in 0..<extLength { reversed[base + i] = firstPass[base + extLength - 1 - i] }
        }

        guard let secondPass = runBatchFIR(reversed, taps: tapsFloat, sampleCount: extLength, channelCount: channelCount)
        else { return nil }

        return (0..<channelCount).map { c in
            let base = c * extLength
            return (0..<sampleCount).map { i in
                Double(secondPass[base + extLength - 1 - (pad + i)])
            }
        }
    }

    private func runBatchFIR(_ input: [Float], taps: [Float], sampleCount: Int, channelCount: Int) -> [Float]? {
        var parameters = BatchFIRParameters(
            sampleCount: UInt32(sampleCount),
            tapCount: UInt32(taps.count),
            channelCount: UInt32(channelCount)
        )
        let total = sampleCount * channelCount
        guard let inputBuffer = buffer(input),
              let tapsBuffer = buffer(taps),
              let outputBuffer = device.makeBuffer(length: total * MemoryLayout<Float>.stride, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(batchFIRFilterPipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(tapsBuffer, offset: 0, index: 1)
        encoder.setBuffer(outputBuffer, offset: 0, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<BatchFIRParameters>.stride, index: 3)
        dispatch(encoder, pipeline: batchFIRFilterPipeline, count: total)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        return floats(from: outputBuffer, count: total)
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
