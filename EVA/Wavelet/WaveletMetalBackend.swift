//
//  WaveletMetalBackend.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Metal acceleration for the Wavelet Artifact Explorer's decomposition. Only
//  the transform runs here — it's the dominant cost and is perfectly parallel
//  over (sample x channel). The windowed median/MAD statistics and candidate
//  extraction stay on the CPU, where sorting and sequential run-walking belong.
//  Same split as `FastrMetalBackend`: dense kernels on the GPU, algorithmic
//  choices on the CPU.
//
//  Results are float, where the CPU path is double, so the two agree closely
//  but not bitwise — see `WaveletArtifactAnalyzer`'s GPU note.
//

import Foundation
import Metal

nonisolated final class WaveletMetalBackend: @unchecked Sendable {
    private struct SWTParameters {
        var sampleCount: UInt32
        var channelCount: UInt32
        var lowLength: UInt32
        var highLength: UInt32
        var dilation: UInt32
    }

    private struct AccumulateParameters {
        var sampleCount: UInt32
        var channelCount: UInt32
        var levelCount: UInt32
        var windowCount: UInt32
        var edgeMarginStart: UInt32
        var edgeMarginEnd: UInt32
        var thresholdScale: Float
        var softThreshold: UInt32
    }

    /// Everything one batch of channels needs after the transform, so the
    /// detail bands never have to come back to the CPU.
    struct AccumulateRequest {
        var levelDelays: [Int]
        /// `(level * channelCount + channel) * windowCount` threshold values.
        var thresholds: [Float]
        var windowCenters: [Int]
        var edgeMarginStart: Int
        var edgeMarginEnd: Int
        var thresholdScale: Float
        var usesSoftThreshold: Bool
    }

    struct AccumulateResult {
        /// `[channel][sample]`
        var energySalience: [[Float]]
        var dominantLevels: [[UInt8]]
        /// `[channel][level]`
        var totalEnergyByLevel: [[Double]]
        var artifactEnergyByLevel: [[Double]]
    }

    private struct DWTParameters {
        var inputLength: UInt32
        var channelCount: UInt32
        var lowLength: UInt32
        var highLength: UInt32
    }

    private struct IDWTParameters {
        var outputLength: UInt32
        var channelCount: UInt32
        var lowLength: UInt32
        var highLength: UInt32
        var shift: Int32
    }

    private struct ISWTParameters {
        var sampleCount: UInt32
        var channelCount: UInt32
        var lowLength: UInt32
        var highLength: UInt32
        var dilation: UInt32
        var shift: Int32
    }

    private struct ShrinkParameters {
        var bandLength: UInt32
        var channelCount: UInt32
        var windowCount: UInt32
        var thresholdScale: Float
        var softThreshold: UInt32
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let swtLevelPipeline: MTLComputePipelineState
    private let accumulatePipeline: MTLComputePipelineState
    private let levelEnergyPipeline: MTLComputePipelineState
    private let dwtLevelPipeline: MTLComputePipelineState
    private let idwtLevelPipeline: MTLComputePipelineState
    private let iswtLevelPipeline: MTLComputePipelineState
    private let shrinkPipeline: MTLComputePipelineState
    private let bandEnergyPipeline: MTLComputePipelineState

    static let shared: WaveletMetalBackend? = WaveletMetalBackend()
    static var isAvailable: Bool { shared != nil }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        guard let queue = device.makeCommandQueue() else {
            assertionFailure("Metal device could not create the wavelet command queue.")
            return nil
        }
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: WaveletMetalBackend.self)) else {
            assertionFailure("EVA's compiled default.metallib could not be loaded for the wavelet scan.")
            return nil
        }
        guard
            let swtLevel = library.makeFunction(name: "waveletSWTLevel"),
            let accumulate = library.makeFunction(name: "waveletThresholdAccumulate"),
            let levelEnergy = library.makeFunction(name: "waveletLevelEnergy"),
            let dwtLevel = library.makeFunction(name: "waveletDWTLevel"),
            let idwtLevel = library.makeFunction(name: "waveletIDWTLevel"),
            let iswtLevel = library.makeFunction(name: "waveletISWTLevel"),
            let shrinkDetail = library.makeFunction(name: "waveletShrinkDetail"),
            let bandEnergy = library.makeFunction(name: "waveletReduceBandEnergy")
        else {
            assertionFailure("A required wavelet function is missing from EVA's compiled Metal library.")
            return nil
        }
        guard
            let swtLevelPipeline = try? device.makeComputePipelineState(function: swtLevel),
            let accumulatePipeline = try? device.makeComputePipelineState(function: accumulate),
            let levelEnergyPipeline = try? device.makeComputePipelineState(function: levelEnergy),
            let dwtLevelPipeline = try? device.makeComputePipelineState(function: dwtLevel),
            let idwtLevelPipeline = try? device.makeComputePipelineState(function: idwtLevel),
            let iswtLevelPipeline = try? device.makeComputePipelineState(function: iswtLevel),
            let shrinkPipeline = try? device.makeComputePipelineState(function: shrinkDetail),
            let bandEnergyPipeline = try? device.makeComputePipelineState(function: bandEnergy)
        else {
            assertionFailure("A wavelet Metal compute pipeline could not be created.")
            return nil
        }

        self.device = device
        self.queue = queue
        self.swtLevelPipeline = swtLevelPipeline
        self.accumulatePipeline = accumulatePipeline
        self.levelEnergyPipeline = levelEnergyPipeline
        self.dwtLevelPipeline = dwtLevelPipeline
        self.idwtLevelPipeline = idwtLevelPipeline
        self.iswtLevelPipeline = iswtLevelPipeline
        self.shrinkPipeline = shrinkPipeline
        self.bandEnergyPipeline = bandEnergyPipeline
    }

    /// Detail bands held on-device between the transform and the accumulation,
    /// with the CPU reading only a strided subsample out of them (they're
    /// shared-storage, so that's a direct read, not a copy).
    final class ResidentDetails {
        fileprivate let buffer: MTLBuffer
        let sampleCount: Int
        let channelCount: Int
        let levelCount: Int

        fileprivate init(buffer: MTLBuffer, sampleCount: Int, channelCount: Int, levelCount: Int) {
            self.buffer = buffer
            self.sampleCount = sampleCount
            self.channelCount = channelCount
            self.levelCount = levelCount
        }

        /// Every `stride`-th coefficient of one band, with `delay` applied so
        /// the sample matches what the accumulate kernel will threshold.
        func subsample(level: Int, channel: Int, delay: Int, from start: Int, to end: Int, stride: Int) -> [Float] {
            guard level < levelCount, channel < channelCount, stride > 0, end > start else { return [] }
            let base = (level * channelCount + channel) * sampleCount
            let pointer = buffer.contents().bindMemory(to: Float.self, capacity: levelCount * channelCount * sampleCount)
            var values: [Float] = []
            values.reserveCapacity((end - start) / stride + 1)
            var sample = start
            while sample < end {
                values.append(sample >= delay ? pointer[base + (sample - delay)] : 0)
                sample += stride
            }
            return values
        }
    }

    /// How many channels can share one dispatch without any single buffer
    /// exceeding the device limit. The largest allocation is one
    /// `channelCount x sampleCount` float buffer, and three of those are live
    /// at once (input, approx, detail) plus one detail buffer per level.
    func maximumBatchChannels(sampleCount: Int, levelCount: Int) -> Int {
        guard sampleCount > 0 else { return 1 }
        let bytesPerChannel = sampleCount * MemoryLayout<Float>.stride
        let buffersPerChannel = 3 + max(levelCount, 1)
        let budget = min(device.maxBufferLength, 512 * 1024 * 1024)
        return max(budget / max(bytesPerChannel * buffersPerChannel, 1), 1)
    }

    /// Transform a batch of channels, leaving every level's detail band on the
    /// device. Nothing is read back here — the caller subsamples for
    /// thresholds and then calls `accumulate`.
    func residentDetails(
        channels: [[Float]],
        levelCount: Int,
        lowPass: [Float],
        highPass: [Float]
    ) -> ResidentDetails? {
        guard !channels.isEmpty, levelCount > 0 else { return nil }
        let sampleCount = channels[0].count
        guard sampleCount > 0, channels.allSatisfy({ $0.count == sampleCount }) else { return nil }
        let channelCount = channels.count
        let planeCount = sampleCount * channelCount
        let planeBytes = planeCount * MemoryLayout<Float>.stride

        var flattened = [Float]()
        flattened.reserveCapacity(planeCount)
        for channel in channels {
            flattened.append(contentsOf: channel)
        }

        guard
            let inputBuffer = device.makeBuffer(bytes: flattened, length: planeBytes, options: .storageModeShared),
            let approxBuffer = device.makeBuffer(length: planeBytes, options: .storageModeShared),
            let scratchBuffer = device.makeBuffer(length: planeBytes, options: .storageModeShared),
            let detailBuffer = device.makeBuffer(length: planeBytes * levelCount, options: .storageModeShared),
            let lowBuffer = device.makeBuffer(
                bytes: lowPass,
                length: lowPass.count * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ),
            let highBuffer = device.makeBuffer(
                bytes: highPass,
                length: highPass.count * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ),
            let commandBuffer = queue.makeCommandBuffer()
        else {
            return nil
        }

        var readBuffer = inputBuffer
        var writeBuffer = approxBuffer

        for level in 0..<levelCount {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            var parameters = SWTParameters(
                sampleCount: UInt32(sampleCount),
                channelCount: UInt32(channelCount),
                lowLength: UInt32(lowPass.count),
                highLength: UInt32(highPass.count),
                dilation: UInt32(1 << level)
            )
            encoder.setComputePipelineState(swtLevelPipeline)
            encoder.setBuffer(readBuffer, offset: 0, index: 0)
            encoder.setBuffer(writeBuffer, offset: 0, index: 1)
            encoder.setBuffer(detailBuffer, offset: level * planeBytes, index: 2)
            encoder.setBuffer(lowBuffer, offset: 0, index: 3)
            encoder.setBuffer(highBuffer, offset: 0, index: 4)
            encoder.setBytes(&parameters, length: MemoryLayout<SWTParameters>.stride, index: 5)
            dispatch2D(encoder, pipeline: swtLevelPipeline, width: sampleCount, height: channelCount)
            encoder.endEncoding()

            if level + 1 < levelCount {
                if level == 0 {
                    readBuffer = approxBuffer
                    writeBuffer = scratchBuffer
                } else {
                    swap(&readBuffer, &writeBuffer)
                }
            }
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.error == nil else { return nil }

        return ResidentDetails(
            buffer: detailBuffer,
            sampleCount: sampleCount,
            channelCount: channelCount,
            levelCount: levelCount
        )
    }

    /// Threshold and accumulate the resident bands on-device, returning only
    /// the per-sample salience, dominant-level map, and per-level energies —
    /// a fraction of the coefficients' size.
    func accumulate(_ details: ResidentDetails, request: AccumulateRequest) -> AccumulateResult? {
        let sampleCount = details.sampleCount
        let channelCount = details.channelCount
        let levelCount = details.levelCount
        let windowCount = request.windowCenters.count
        guard windowCount > 0,
              request.thresholds.count == levelCount * channelCount * windowCount,
              request.levelDelays.count == levelCount
        else {
            return nil
        }

        let planeCount = sampleCount * channelCount
        let delays = request.levelDelays.map { UInt32($0) }
        let centers = request.windowCenters.map { UInt32($0) }

        guard
            let thresholdBuffer = device.makeBuffer(
                bytes: request.thresholds,
                length: request.thresholds.count * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ),
            let centerBuffer = device.makeBuffer(
                bytes: centers,
                length: centers.count * MemoryLayout<UInt32>.stride,
                options: .storageModeShared
            ),
            let delayBuffer = device.makeBuffer(
                bytes: delays,
                length: delays.count * MemoryLayout<UInt32>.stride,
                options: .storageModeShared
            ),
            let salienceBuffer = device.makeBuffer(
                length: planeCount * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ),
            let dominantBuffer = device.makeBuffer(
                length: planeCount * MemoryLayout<UInt8>.stride,
                options: .storageModeShared
            ),
            let totalEnergyBuffer = device.makeBuffer(
                length: levelCount * channelCount * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ),
            let artifactEnergyBuffer = device.makeBuffer(
                length: levelCount * channelCount * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ),
            let commandBuffer = queue.makeCommandBuffer()
        else {
            return nil
        }

        var accumulateParameters = AccumulateParameters(
            sampleCount: UInt32(sampleCount),
            channelCount: UInt32(channelCount),
            levelCount: UInt32(levelCount),
            windowCount: UInt32(windowCount),
            edgeMarginStart: UInt32(max(request.edgeMarginStart, 0)),
            edgeMarginEnd: UInt32(max(request.edgeMarginEnd, 0)),
            thresholdScale: request.thresholdScale,
            softThreshold: request.usesSoftThreshold ? 1 : 0
        )

        guard let accumulateEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        accumulateEncoder.setComputePipelineState(accumulatePipeline)
        accumulateEncoder.setBuffer(details.buffer, offset: 0, index: 0)
        accumulateEncoder.setBuffer(thresholdBuffer, offset: 0, index: 1)
        accumulateEncoder.setBuffer(centerBuffer, offset: 0, index: 2)
        accumulateEncoder.setBuffer(delayBuffer, offset: 0, index: 3)
        accumulateEncoder.setBuffer(salienceBuffer, offset: 0, index: 4)
        accumulateEncoder.setBuffer(dominantBuffer, offset: 0, index: 5)
        accumulateEncoder.setBytes(&accumulateParameters, length: MemoryLayout<AccumulateParameters>.stride, index: 6)
        dispatch2D(accumulateEncoder, pipeline: accumulatePipeline, width: sampleCount, height: channelCount)
        accumulateEncoder.endEncoding()

        guard let energyEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        energyEncoder.setComputePipelineState(levelEnergyPipeline)
        energyEncoder.setBuffer(details.buffer, offset: 0, index: 0)
        energyEncoder.setBuffer(thresholdBuffer, offset: 0, index: 1)
        energyEncoder.setBuffer(centerBuffer, offset: 0, index: 2)
        energyEncoder.setBuffer(delayBuffer, offset: 0, index: 3)
        energyEncoder.setBuffer(totalEnergyBuffer, offset: 0, index: 4)
        energyEncoder.setBuffer(artifactEnergyBuffer, offset: 0, index: 5)
        energyEncoder.setBytes(&accumulateParameters, length: MemoryLayout<AccumulateParameters>.stride, index: 6)
        dispatch2D(energyEncoder, pipeline: levelEnergyPipeline, width: levelCount, height: channelCount)
        energyEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.error == nil else { return nil }

        let saliencePointer = salienceBuffer.contents().bindMemory(to: Float.self, capacity: planeCount)
        let dominantPointer = dominantBuffer.contents().bindMemory(to: UInt8.self, capacity: planeCount)
        let totalPointer = totalEnergyBuffer.contents().bindMemory(to: Float.self, capacity: levelCount * channelCount)
        let artifactPointer = artifactEnergyBuffer.contents().bindMemory(to: Float.self, capacity: levelCount * channelCount)

        var salience: [[Float]] = []
        var dominant: [[UInt8]] = []
        var totals: [[Double]] = []
        var artifacts: [[Double]] = []
        salience.reserveCapacity(channelCount)
        dominant.reserveCapacity(channelCount)
        totals.reserveCapacity(channelCount)
        artifacts.reserveCapacity(channelCount)

        for channel in 0..<channelCount {
            let start = channel * sampleCount
            salience.append(Array(UnsafeBufferPointer(start: saliencePointer + start, count: sampleCount)))
            dominant.append(Array(UnsafeBufferPointer(start: dominantPointer + start, count: sampleCount)))
            totals.append((0..<levelCount).map { Double(totalPointer[$0 * channelCount + channel]) })
            artifacts.append((0..<levelCount).map { Double(artifactPointer[$0 * channelCount + channel]) })
        }

        return AccumulateResult(
            energySalience: salience,
            dominantLevels: dominant,
            totalEnergyByLevel: totals,
            artifactEnergyByLevel: artifacts
        )
    }

    // MARK: - Reduction (decompose → threshold → reconstruct on-device)

    /// The forward transform's on-device output for one batch of channels:
    /// every detail band plus the deepest approximation, all resident in GPU
    /// memory. The host reads only strided subsamples (for the robust
    /// thresholds) before `reductionFinish` thresholds and reconstructs
    /// without the bands ever leaving the device.
    final class ResidentReductionBands {
        fileprivate let kind: WaveletTransformKind
        let paddedLength: Int
        let channelCount: Int
        let levelCount: Int
        /// Detail band lengths, finest level first (halving per level for the
        /// DWT, constant `paddedLength` for the SWT).
        let bandLengths: [Int]
        fileprivate let detailBuffers: [MTLBuffer]
        fileprivate let pingBuffer: MTLBuffer
        fileprivate let pongBuffer: MTLBuffer
        /// Which of ping/pong holds the deepest approximation after forward.
        fileprivate let approxIsPing: Bool
        fileprivate let approxLength: Int

        fileprivate init(
            kind: WaveletTransformKind,
            paddedLength: Int,
            channelCount: Int,
            levelCount: Int,
            bandLengths: [Int],
            detailBuffers: [MTLBuffer],
            pingBuffer: MTLBuffer,
            pongBuffer: MTLBuffer,
            approxIsPing: Bool,
            approxLength: Int
        ) {
            self.kind = kind
            self.paddedLength = paddedLength
            self.channelCount = channelCount
            self.levelCount = levelCount
            self.bandLengths = bandLengths
            self.detailBuffers = detailBuffers
            self.pingBuffer = pingBuffer
            self.pongBuffer = pongBuffer
            self.approxIsPing = approxIsPing
            self.approxLength = approxLength
        }

        /// Every `stride`-th coefficient of one band slice, read directly from
        /// the shared-storage buffer — the host's input for the robust
        /// (median/MAD) threshold statistics.
        func detailSubsample(level: Int, channel: Int, from start: Int, to end: Int, stride: Int) -> [Float] {
            guard level < levelCount, channel < channelCount, stride > 0 else { return [] }
            let bandLength = bandLengths[level]
            let clampedEnd = min(end, bandLength)
            guard clampedEnd > start else { return [] }
            let pointer = detailBuffers[level].contents()
                .bindMemory(to: Float.self, capacity: channelCount * bandLength)
            let base = channel * bandLength
            var values: [Float] = []
            values.reserveCapacity((clampedEnd - start) / stride + 1)
            var sample = start
            while sample < clampedEnd {
                values.append(pointer[base + sample])
                sample += stride
            }
            return values
        }
    }

    /// Per-level threshold tables for `reductionFinish`. `values[level]` holds
    /// `channel * windowCount + window` gate values; `centers[level]` the
    /// window centres in that band's own coordinates (one entry → one global
    /// gate for the whole band).
    struct ReductionThresholds {
        var values: [[Float]]
        var centers: [[UInt32]]
    }

    /// How many channels one reduction dispatch can hold within the memory
    /// budget. The DWT pyramid needs ~4 padded planes per channel (input, two
    /// ping-pong planes, and all detail bands sum to under one plane); the SWT
    /// needs a full plane per level plus three.
    func maximumReductionBatchChannels(paddedLength: Int, levelCount: Int, kind: WaveletTransformKind) -> Int {
        guard paddedLength > 0 else { return 1 }
        let planesPerChannel = kind == .dwt ? 4 : 3 + max(levelCount, 1)
        let bytesPerChannel = paddedLength * planesPerChannel * MemoryLayout<Float>.stride
        let budget = min(device.maxBufferLength, 512 * 1024 * 1024)
        return max(budget / max(bytesPerChannel, 1), 1)
    }

    /// Runs the forward transform for a batch of equal-length (already
    /// detrended and padded) channels, leaving every band on-device. For the
    /// DWT, `paddedLength` must be divisible by 2^levelCount.
    func reductionForward(
        channels: [[Float]],
        kind: WaveletTransformKind,
        levelCount: Int,
        decompositionLowPass: [Float],
        decompositionHighPass: [Float]
    ) -> ResidentReductionBands? {
        guard !channels.isEmpty, levelCount > 0 else { return nil }
        let paddedLength = channels[0].count
        guard paddedLength > 0, channels.allSatisfy({ $0.count == paddedLength }) else { return nil }
        if kind == .dwt {
            guard paddedLength % (1 << levelCount) == 0 else { return nil }
        }
        let channelCount = channels.count
        let planeCount = paddedLength * channelCount
        let planeBytes = planeCount * MemoryLayout<Float>.stride

        var flattened = [Float]()
        flattened.reserveCapacity(planeCount)
        for channel in channels {
            flattened.append(contentsOf: channel)
        }

        var bandLengths: [Int] = []
        bandLengths.reserveCapacity(levelCount)
        for level in 0..<levelCount {
            bandLengths.append(kind == .dwt ? paddedLength >> (level + 1) : paddedLength)
        }

        guard
            let inputBuffer = device.makeBuffer(bytes: flattened, length: planeBytes, options: .storageModeShared),
            let pingBuffer = device.makeBuffer(length: planeBytes, options: .storageModeShared),
            let pongBuffer = device.makeBuffer(length: planeBytes, options: .storageModeShared),
            let lowBuffer = device.makeBuffer(
                bytes: decompositionLowPass,
                length: decompositionLowPass.count * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ),
            let highBuffer = device.makeBuffer(
                bytes: decompositionHighPass,
                length: decompositionHighPass.count * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ),
            let commandBuffer = queue.makeCommandBuffer()
        else {
            return nil
        }

        var detailBuffers: [MTLBuffer] = []
        detailBuffers.reserveCapacity(levelCount)
        for level in 0..<levelCount {
            let bytes = bandLengths[level] * channelCount * MemoryLayout<Float>.stride
            guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else { return nil }
            detailBuffers.append(buffer)
        }

        // Levels are sequential (each consumes the previous approximation);
        // separate encoders in one command buffer give the implicit barrier.
        var readBuffer = inputBuffer
        for level in 0..<levelCount {
            let writeBuffer = level % 2 == 0 ? pingBuffer : pongBuffer
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            switch kind {
            case .dwt:
                let inputLength = kind == .dwt ? paddedLength >> level : paddedLength
                var parameters = DWTParameters(
                    inputLength: UInt32(inputLength),
                    channelCount: UInt32(channelCount),
                    lowLength: UInt32(decompositionLowPass.count),
                    highLength: UInt32(decompositionHighPass.count)
                )
                encoder.setComputePipelineState(dwtLevelPipeline)
                encoder.setBuffer(readBuffer, offset: 0, index: 0)
                encoder.setBuffer(writeBuffer, offset: 0, index: 1)
                encoder.setBuffer(detailBuffers[level], offset: 0, index: 2)
                encoder.setBuffer(lowBuffer, offset: 0, index: 3)
                encoder.setBuffer(highBuffer, offset: 0, index: 4)
                encoder.setBytes(&parameters, length: MemoryLayout<DWTParameters>.stride, index: 5)
                dispatch2D(encoder, pipeline: dwtLevelPipeline, width: inputLength / 2, height: channelCount)
            case .swt:
                var parameters = SWTParameters(
                    sampleCount: UInt32(paddedLength),
                    channelCount: UInt32(channelCount),
                    lowLength: UInt32(decompositionLowPass.count),
                    highLength: UInt32(decompositionHighPass.count),
                    dilation: UInt32(1 << level)
                )
                encoder.setComputePipelineState(swtLevelPipeline)
                encoder.setBuffer(readBuffer, offset: 0, index: 0)
                encoder.setBuffer(writeBuffer, offset: 0, index: 1)
                encoder.setBuffer(detailBuffers[level], offset: 0, index: 2)
                encoder.setBuffer(lowBuffer, offset: 0, index: 3)
                encoder.setBuffer(highBuffer, offset: 0, index: 4)
                encoder.setBytes(&parameters, length: MemoryLayout<SWTParameters>.stride, index: 5)
                dispatch2D(encoder, pipeline: swtLevelPipeline, width: paddedLength, height: channelCount)
            }
            encoder.endEncoding()
            readBuffer = writeBuffer
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.error == nil else { return nil }

        return ResidentReductionBands(
            kind: kind,
            paddedLength: paddedLength,
            channelCount: channelCount,
            levelCount: levelCount,
            bandLengths: bandLengths,
            detailBuffers: detailBuffers,
            pingBuffer: pingBuffer,
            pongBuffer: pongBuffer,
            approxIsPing: (levelCount - 1) % 2 == 0,
            approxLength: kind == .dwt ? paddedLength >> levelCount : paddedLength
        )
    }

    /// Thresholds every band in place (keeping only the above-gate artifact
    /// coefficients), measures each band's total/kept energy, reconstructs the
    /// artifact from the kept details plus the approximation, and reads back
    /// only the artifact plane and the per-level energies.
    func reductionFinish(
        _ bands: ResidentReductionBands,
        thresholds: ReductionThresholds,
        thresholdScale: Float,
        usesSoftThreshold: Bool,
        reconstructionLowPass: [Float],
        reconstructionHighPass: [Float],
        reconstructionShift: Int
    ) -> (artifact: [[Float]], totalEnergyByLevel: [[Double]], keptEnergyByLevel: [[Double]])? {
        let channelCount = bands.channelCount
        let levelCount = bands.levelCount
        guard thresholds.values.count == levelCount, thresholds.centers.count == levelCount else { return nil }
        for level in 0..<levelCount {
            let windowCount = thresholds.centers[level].count
            guard windowCount > 0, thresholds.values[level].count == channelCount * windowCount else { return nil }
        }

        guard
            let lowBuffer = device.makeBuffer(
                bytes: reconstructionLowPass,
                length: reconstructionLowPass.count * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ),
            let highBuffer = device.makeBuffer(
                bytes: reconstructionHighPass,
                length: reconstructionHighPass.count * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ),
            let commandBuffer = queue.makeCommandBuffer()
        else {
            return nil
        }

        var totalEnergyBuffers: [MTLBuffer] = []
        var keptEnergyBuffers: [MTLBuffer] = []
        let energyBytes = channelCount * MemoryLayout<Float>.stride

        // Per level: measure the band's energies, then shrink it in place.
        for level in 0..<levelCount {
            let bandLength = bands.bandLengths[level]
            let windowCount = thresholds.centers[level].count
            guard
                let thresholdBuffer = device.makeBuffer(
                    bytes: thresholds.values[level],
                    length: thresholds.values[level].count * MemoryLayout<Float>.stride,
                    options: .storageModeShared
                ),
                let centerBuffer = device.makeBuffer(
                    bytes: thresholds.centers[level],
                    length: windowCount * MemoryLayout<UInt32>.stride,
                    options: .storageModeShared
                ),
                let totalBuffer = device.makeBuffer(length: energyBytes, options: .storageModeShared),
                let keptBuffer = device.makeBuffer(length: energyBytes, options: .storageModeShared)
            else {
                return nil
            }
            totalEnergyBuffers.append(totalBuffer)
            keptEnergyBuffers.append(keptBuffer)

            var parameters = ShrinkParameters(
                bandLength: UInt32(bandLength),
                channelCount: UInt32(channelCount),
                windowCount: UInt32(windowCount),
                thresholdScale: thresholdScale,
                softThreshold: usesSoftThreshold ? 1 : 0
            )

            guard let energyEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            energyEncoder.setComputePipelineState(bandEnergyPipeline)
            energyEncoder.setBuffer(bands.detailBuffers[level], offset: 0, index: 0)
            energyEncoder.setBuffer(thresholdBuffer, offset: 0, index: 1)
            energyEncoder.setBuffer(centerBuffer, offset: 0, index: 2)
            energyEncoder.setBuffer(totalBuffer, offset: 0, index: 3)
            energyEncoder.setBuffer(keptBuffer, offset: 0, index: 4)
            energyEncoder.setBytes(&parameters, length: MemoryLayout<ShrinkParameters>.stride, index: 5)
            let energyWidth = max(min(bandEnergyPipeline.threadExecutionWidth, channelCount), 1)
            energyEncoder.dispatchThreads(
                MTLSize(width: channelCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: energyWidth, height: 1, depth: 1)
            )
            energyEncoder.endEncoding()

            guard let shrinkEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            shrinkEncoder.setComputePipelineState(shrinkPipeline)
            shrinkEncoder.setBuffer(bands.detailBuffers[level], offset: 0, index: 0)
            shrinkEncoder.setBuffer(thresholdBuffer, offset: 0, index: 1)
            shrinkEncoder.setBuffer(centerBuffer, offset: 0, index: 2)
            shrinkEncoder.setBytes(&parameters, length: MemoryLayout<ShrinkParameters>.stride, index: 3)
            dispatch2D(shrinkEncoder, pipeline: shrinkPipeline, width: bandLength, height: channelCount)
            shrinkEncoder.endEncoding()
        }

        // Inverse chain: start from the deepest approximation and fold each
        // (now-shrunk) detail band back in, ping-ponging the two planes.
        var readBuffer = bands.approxIsPing ? bands.pingBuffer : bands.pongBuffer
        var writeBuffer = bands.approxIsPing ? bands.pongBuffer : bands.pingBuffer
        for level in stride(from: levelCount - 1, through: 0, by: -1) {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            switch bands.kind {
            case .dwt:
                let outputLength = bands.paddedLength >> level
                var parameters = IDWTParameters(
                    outputLength: UInt32(outputLength),
                    channelCount: UInt32(channelCount),
                    lowLength: UInt32(reconstructionLowPass.count),
                    highLength: UInt32(reconstructionHighPass.count),
                    shift: Int32(reconstructionShift)
                )
                encoder.setComputePipelineState(idwtLevelPipeline)
                encoder.setBuffer(readBuffer, offset: 0, index: 0)
                encoder.setBuffer(bands.detailBuffers[level], offset: 0, index: 1)
                encoder.setBuffer(writeBuffer, offset: 0, index: 2)
                encoder.setBuffer(lowBuffer, offset: 0, index: 3)
                encoder.setBuffer(highBuffer, offset: 0, index: 4)
                encoder.setBytes(&parameters, length: MemoryLayout<IDWTParameters>.stride, index: 5)
                dispatch2D(encoder, pipeline: idwtLevelPipeline, width: outputLength, height: channelCount)
            case .swt:
                let dilation = 1 << level
                var parameters = ISWTParameters(
                    sampleCount: UInt32(bands.paddedLength),
                    channelCount: UInt32(channelCount),
                    lowLength: UInt32(reconstructionLowPass.count),
                    highLength: UInt32(reconstructionHighPass.count),
                    dilation: UInt32(dilation),
                    shift: Int32(reconstructionShift * dilation)
                )
                encoder.setComputePipelineState(iswtLevelPipeline)
                encoder.setBuffer(readBuffer, offset: 0, index: 0)
                encoder.setBuffer(bands.detailBuffers[level], offset: 0, index: 1)
                encoder.setBuffer(writeBuffer, offset: 0, index: 2)
                encoder.setBuffer(lowBuffer, offset: 0, index: 3)
                encoder.setBuffer(highBuffer, offset: 0, index: 4)
                encoder.setBytes(&parameters, length: MemoryLayout<ISWTParameters>.stride, index: 5)
                dispatch2D(encoder, pipeline: iswtLevelPipeline, width: bands.paddedLength, height: channelCount)
            }
            encoder.endEncoding()
            swap(&readBuffer, &writeBuffer)
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.error == nil else { return nil }

        // After the loop's final swap, `readBuffer` holds the full-length
        // artifact plane.
        let paddedLength = bands.paddedLength
        let artifactPointer = readBuffer.contents()
            .bindMemory(to: Float.self, capacity: channelCount * paddedLength)
        var artifact: [[Float]] = []
        artifact.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            let start = channel * paddedLength
            artifact.append(Array(UnsafeBufferPointer(start: artifactPointer + start, count: paddedLength)))
        }

        var totalEnergy = [[Double]](repeating: [Double](repeating: 0, count: levelCount), count: channelCount)
        var keptEnergy = totalEnergy
        for level in 0..<levelCount {
            let totalPointer = totalEnergyBuffers[level].contents().bindMemory(to: Float.self, capacity: channelCount)
            let keptPointer = keptEnergyBuffers[level].contents().bindMemory(to: Float.self, capacity: channelCount)
            for channel in 0..<channelCount {
                totalEnergy[channel][level] = Double(totalPointer[channel])
                keptEnergy[channel][level] = Double(keptPointer[channel])
            }
        }

        return (artifact, totalEnergy, keptEnergy)
    }

    private func dispatch2D(
        _ encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let threadWidth = max(min(pipeline.threadExecutionWidth, width), 1)
        let threadHeight = max(min(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, height), 1)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
    }

    /// Undecimated wavelet detail bands for a batch of equal-length channels.
    /// Returns `[channel][level][sample]`, matching
    /// `WaveletTransform.forwardSWT(_:levels:)`'s `details`. Returns nil if the
    /// GPU work could not be encoded, so callers can fall back to the CPU.
    func forwardSWTDetails(
        channels: [[Float]],
        levelCount: Int,
        lowPass: [Float],
        highPass: [Float]
    ) -> [[[Float]]]? {
        guard !channels.isEmpty, levelCount > 0 else { return nil }
        let sampleCount = channels[0].count
        guard sampleCount > 0, channels.allSatisfy({ $0.count == sampleCount }) else { return nil }
        let channelCount = channels.count
        let elementCount = sampleCount * channelCount
        let byteCount = elementCount * MemoryLayout<Float>.stride

        var flattened = [Float]()
        flattened.reserveCapacity(elementCount)
        for channel in channels {
            flattened.append(contentsOf: channel)
        }

        guard
            let inputBuffer = device.makeBuffer(bytes: flattened, length: byteCount, options: .storageModeShared),
            let approxBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared),
            let scratchBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared),
            let lowBuffer = device.makeBuffer(
                bytes: lowPass,
                length: lowPass.count * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ),
            let highBuffer = device.makeBuffer(
                bytes: highPass,
                length: highPass.count * MemoryLayout<Float>.stride,
                options: .storageModeShared
            )
        else {
            return nil
        }

        var detailBuffers: [MTLBuffer] = []
        detailBuffers.reserveCapacity(levelCount)
        for _ in 0..<levelCount {
            guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else { return nil }
            detailBuffers.append(buffer)
        }

        guard let commandBuffer = queue.makeCommandBuffer() else { return nil }

        // Levels are sequential: each consumes the previous level's
        // approximation. Level 0 reads the untouched input, after which the
        // two approximation buffers simply alternate. Separate compute
        // encoders in one command buffer run in order with an implicit
        // barrier, which is exactly the dependency this needs.
        var readBuffer = inputBuffer
        var writeBuffer = approxBuffer

        for level in 0..<levelCount {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            var parameters = SWTParameters(
                sampleCount: UInt32(sampleCount),
                channelCount: UInt32(channelCount),
                lowLength: UInt32(lowPass.count),
                highLength: UInt32(highPass.count),
                dilation: UInt32(1 << level)
            )
            encoder.setComputePipelineState(swtLevelPipeline)
            encoder.setBuffer(readBuffer, offset: 0, index: 0)
            encoder.setBuffer(writeBuffer, offset: 0, index: 1)
            encoder.setBuffer(detailBuffers[level], offset: 0, index: 2)
            encoder.setBuffer(lowBuffer, offset: 0, index: 3)
            encoder.setBuffer(highBuffer, offset: 0, index: 4)
            encoder.setBytes(&parameters, length: MemoryLayout<SWTParameters>.stride, index: 5)

            let width = max(min(swtLevelPipeline.threadExecutionWidth, sampleCount), 1)
            let height = max(
                min(swtLevelPipeline.maxTotalThreadsPerThreadgroup / width, channelCount),
                1
            )
            encoder.dispatchThreads(
                MTLSize(width: sampleCount, height: channelCount, depth: 1),
                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
            )
            encoder.endEncoding()

            if level + 1 < levelCount {
                if level == 0 {
                    // The input buffer must stay intact, so step onto the pair
                    // of scratch buffers rather than swapping it back in.
                    readBuffer = approxBuffer
                    writeBuffer = scratchBuffer
                } else {
                    swap(&readBuffer, &writeBuffer)
                }
            }
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.error == nil else { return nil }

        var results = [[[Float]]](
            repeating: [[Float]](repeating: [], count: levelCount),
            count: channelCount
        )
        for level in 0..<levelCount {
            let pointer = detailBuffers[level].contents().bindMemory(to: Float.self, capacity: elementCount)
            for channel in 0..<channelCount {
                let start = channel * sampleCount
                results[channel][level] = Array(UnsafeBufferPointer(start: pointer + start, count: sampleCount))
            }
        }
        return results
    }
}
