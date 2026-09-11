//
//  AccelerateFFTComplexCoefficientProvider.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Bounded-memory overlap-save convolution for the production Rhythmicity
//  backend. The direct provider remains the numerical oracle.
//

import Foundation

nonisolated struct RhythmicityFFTConvolutionPlan: Sendable, Equatable {
    var signalSamples: Int
    var kernelSamples: Int
    var fftSamples: Int
    var outputSamplesPerBlock: Int
    var firstBlockIndex: Int
    var blockCount: Int
    var estimatedWorkingSetBytes: Int
}

nonisolated enum RhythmicityFFTError: Error, Sendable, Equatable, LocalizedError {
    case invalidComputePolicy(String)
    case lengthOverflow
    case memoryBudgetTooSmall(requiredBytes: Int, configuredBytes: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidComputePolicy(message):
            return "Invalid Rhythmicity compute policy: \(message)"
        case .lengthOverflow:
            return "The Rhythmicity FFT length exceeds the supported integer range."
        case let .memoryBudgetTooSmall(required, configured):
            return "Rhythmicity requires at least \(required) working bytes; the configured budget is \(configured)."
        }
    }
}

/// Marker used by `LAVIEngine` to enable its bounded frequency worker pool.
/// Custom/reference providers retain the serial execution path.
nonisolated protocol RhythmicityProductionCoefficientProvider: ComplexCoefficientProvider {}

/// Calculates FFT tiling and worker limits before allocations begin.
nonisolated enum RhythmicityProductionWorkPlanner {
    static let maximumKernelCacheBytes = 128 * 1_024 * 1_024

    static func convolutionPlan(
        signalSamples: Int,
        kernelSamples: Int,
        policy: RhythmicityComputePolicy
    ) throws -> RhythmicityFFTConvolutionPlan {
        try validate(policy)
        guard signalSamples >= 0, kernelSamples > 0 else {
            throw RhythmicityFFTError.invalidComputePolicy(
                "signal length must be nonnegative and kernel length must be positive"
            )
        }
        guard signalSamples > 0 else {
            return RhythmicityFFTConvolutionPlan(
                signalSamples: 0,
                kernelSamples: kernelSamples,
                fftSamples: 0,
                outputSamplesPerBlock: 0,
                firstBlockIndex: 0,
                blockCount: 0,
                estimatedWorkingSetBytes: 0
            )
        }
        let requestedOutputSamples = min(policy.preferredOutputTileSamples, signalSamples)
        let (minimumFFT, overflow) = requestedOutputSamples
            .addingReportingOverflow(kernelSamples - 1)
        guard !overflow, let fftSamples = nextPowerOfTwo(minimumFFT) else {
            throw RhythmicityFFTError.lengthOverflow
        }
        let outputSamples = fftSamples - kernelSamples + 1
        guard outputSamples > 0 else { throw RhythmicityFFTError.lengthOverflow }

        // The requested output is the central `signalSamples` portion of the
        // full linear convolution, beginning at kernelSamples / 2.
        let firstFullIndex = kernelSamples / 2
        let (lastFullIndex, lastOverflow) = firstFullIndex
            .addingReportingOverflow(signalSamples - 1)
        guard !lastOverflow else { throw RhythmicityFFTError.lengthOverflow }
        let firstBlock = firstFullIndex / outputSamples
        let lastBlock = lastFullIndex / outputSamples

        // Conservative peak: returned complex tile (2S), kernel (2M), and
        // sixteen FFT-length Double buffers across transform input/output and
        // the two complex products. Kernel spectra cached outside this amount
        // are reserved separately by `workerCount`.
        let estimatedDoubles = 2 * signalSamples + 2 * kernelSamples + 16 * fftSamples
        let (estimatedBytes, byteOverflow) = estimatedDoubles.multipliedReportingOverflow(by: 8)
        guard !byteOverflow else { throw RhythmicityFFTError.lengthOverflow }
        return RhythmicityFFTConvolutionPlan(
            signalSamples: signalSamples,
            kernelSamples: kernelSamples,
            fftSamples: fftSamples,
            outputSamplesPerBlock: outputSamples,
            firstBlockIndex: firstBlock,
            blockCount: lastBlock - firstBlock + 1,
            estimatedWorkingSetBytes: estimatedBytes
        )
    }

    static func kernelCacheBudget(policy: RhythmicityComputePolicy) -> Int {
        min(policy.memoryBudgetBytes / 8, maximumKernelCacheBytes)
    }

    static func workerCount(
        workItemCount: Int,
        totalInputSamples: Int,
        longestRunSamples: Int,
        maximumKernelSamples: Int,
        policy: RhythmicityComputePolicy
    ) throws -> Int {
        try validate(policy)
        guard workItemCount > 0 else { return 0 }
        let plan = try convolutionPlan(
            signalSamples: longestRunSamples,
            kernelSamples: maximumKernelSamples,
            policy: policy
        )
        let (inputBytes, inputOverflow) = totalInputSamples.multipliedReportingOverflow(by: 8)
        guard !inputOverflow else { throw RhythmicityFFTError.lengthOverflow }
        let cacheBytes = kernelCacheBudget(policy: policy)
        let fixedBytes = inputBytes + cacheBytes
        let required = fixedBytes + plan.estimatedWorkingSetBytes
        guard required <= policy.memoryBudgetBytes else {
            throw RhythmicityFFTError.memoryBudgetTooSmall(
                requiredBytes: required,
                configuredBytes: policy.memoryBudgetBytes
            )
        }
        let memoryWorkers = max(
            (policy.memoryBudgetBytes - fixedBytes) / max(plan.estimatedWorkingSetBytes, 1),
            1
        )
        let requestedWorkers = policy.maximumWorkerCount == 0
            ? evaMaxWorkers
            : min(policy.maximumWorkerCount, evaMaxWorkers)
        return min(workItemCount, requestedWorkers, memoryWorkers)
    }

    static func validate(_ policy: RhythmicityComputePolicy) throws {
        guard policy.preferredOutputTileSamples > 0 else {
            throw RhythmicityFFTError.invalidComputePolicy(
                "preferred output tile length must be positive"
            )
        }
        guard policy.maximumWorkerCount >= 0 else {
            throw RhythmicityFFTError.invalidComputePolicy(
                "maximum worker count must be zero (automatic) or positive"
            )
        }
        guard policy.memoryBudgetBytes > 0 else {
            throw RhythmicityFFTError.invalidComputePolicy(
                "memory budget must be positive"
            )
        }
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int? {
        guard value > 0 else { return nil }
        var result = 1
        while result < value {
            guard result <= Int.max / 2 else { return nil }
            result <<= 1
        }
        return result
    }
}

/// Accelerate-backed complex convolution. Each block includes `M - 1` samples
/// of history; only the uncontaminated `N - M + 1` outputs are retained. This
/// is overlap-save and therefore never allocates a full convolution or a
/// frequency × time cube.
nonisolated final class AccelerateFFTComplexCoefficientProvider:
    RhythmicityProductionCoefficientProvider,
    @unchecked Sendable
{
    typealias BlockProgress = @Sendable (_ completedBlocks: Int, _ totalBlocks: Int) -> Void

    let policy: RhythmicityComputePolicy
    private let blockProgress: BlockProgress?
    private let kernelCache: RhythmicityKernelSpectrumCache

    init(
        policy: RhythmicityComputePolicy = .productionDefault,
        blockProgress: BlockProgress? = nil
    ) {
        self.policy = policy
        self.blockProgress = blockProgress
        self.kernelCache = RhythmicityKernelSpectrumCache(
            maximumBytes: RhythmicityProductionWorkPlanner.kernelCacheBudget(policy: policy)
        )
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
        let kernel = LAVI2026Morlet.kernel(
            frequencyHz: frequencyHz,
            widthCycles: widthCycles,
            samplingRate: samplingRate
        )
        guard !signal.isEmpty else {
            return ComplexCoefficientTile(
                frequencyHz: frequencyHz,
                real: [],
                imaginary: [],
                validSampleRange: 0..<0
            )
        }
        let tiling = try RhythmicityProductionWorkPlanner.convolutionPlan(
            signalSamples: signal.count,
            kernelSamples: kernel.count,
            policy: policy
        )
        let reservedCacheBytes = RhythmicityProductionWorkPlanner.kernelCacheBudget(policy: policy)
        guard tiling.estimatedWorkingSetBytes <= policy.memoryBudgetBytes - reservedCacheBytes else {
            throw RhythmicityFFTError.memoryBudgetTooSmall(
                requiredBytes: tiling.estimatedWorkingSetBytes + reservedCacheBytes,
                configuredBytes: policy.memoryBudgetBytes
            )
        }
        let transform = try RhythmicityDFTPlan(count: tiling.fftSamples)
        let cacheKey = RhythmicityKernelSpectrumKey(
            samplingRateBits: samplingRate.bitPattern,
            frequencyBits: frequencyHz.bitPattern,
            widthBits: widthCycles.bitPattern,
            fftSamples: tiling.fftSamples
        )
        let spectra = kernelCache.value(for: cacheKey) ?? {
            var paddedReal = [Double](repeating: 0, count: tiling.fftSamples)
            var paddedImaginary = [Double](repeating: 0, count: tiling.fftSamples)
            paddedReal.replaceSubrange(0..<kernel.count, with: kernel.real)
            paddedImaginary.replaceSubrange(0..<kernel.count, with: kernel.imaginary)
            let realSpectrum = transform.forward(paddedReal)
            let imaginarySpectrum = transform.forward(paddedImaginary)
            let value = RhythmicityKernelSpectra(
                realKernelReal: realSpectrum.real,
                realKernelImaginary: realSpectrum.imaginary,
                imaginaryKernelReal: imaginarySpectrum.real,
                imaginaryKernelImaginary: imaginarySpectrum.imaginary
            )
            kernelCache.insert(value, for: cacheKey)
            return value
        }()

        var outputReal = [Double](repeating: 0, count: signal.count)
        var outputImaginary = [Double](repeating: 0, count: signal.count)
        let overlap = kernel.count - 1
        let requestedLower = kernel.count / 2
        let requestedUpper = requestedLower + signal.count

        for localBlock in 0..<tiling.blockCount {
            try cancellation.check()
            let blockIndex = tiling.firstBlockIndex + localBlock
            let fullOutputStart = blockIndex * tiling.outputSamplesPerBlock
            let inputStart = fullOutputStart - overlap
            var paddedSignal = [Double](repeating: 0, count: tiling.fftSamples)
            let sourceLower = max(inputStart, 0)
            let sourceUpper = min(inputStart + tiling.fftSamples, signal.count)
            if sourceUpper > sourceLower {
                let destinationLower = sourceLower - inputStart
                paddedSignal.replaceSubrange(
                    destinationLower..<(destinationLower + sourceUpper - sourceLower),
                    with: signal[sourceLower..<sourceUpper]
                )
            }
            let signalSpectrum = transform.forward(paddedSignal)
            let realProduct = complexProduct(
                leftReal: signalSpectrum.real,
                leftImaginary: signalSpectrum.imaginary,
                rightReal: spectra.realKernelReal,
                rightImaginary: spectra.realKernelImaginary
            )
            let imaginaryProduct = complexProduct(
                leftReal: signalSpectrum.real,
                leftImaginary: signalSpectrum.imaginary,
                rightReal: spectra.imaginaryKernelReal,
                rightImaginary: spectra.imaginaryKernelImaginary
            )
            let convolvedReal = transform.inverse(
                real: realProduct.real,
                imaginary: realProduct.imaginary
            )
            let convolvedImaginary = transform.inverse(
                real: imaginaryProduct.real,
                imaginary: imaginaryProduct.imaginary
            )

            let validFullLower = fullOutputStart
            let validFullUpper = fullOutputStart + tiling.outputSamplesPerBlock
            let copyLower = max(validFullLower, requestedLower)
            let copyUpper = min(validFullUpper, requestedUpper)
            if copyUpper > copyLower {
                for fullIndex in copyLower..<copyUpper {
                    let blockOffset = overlap + fullIndex - fullOutputStart
                    let outputIndex = fullIndex - requestedLower
                    outputReal[outputIndex] = convolvedReal[blockOffset]
                    outputImaginary[outputIndex] = convolvedImaginary[blockOffset]
                }
            }
            blockProgress?(localBlock + 1, tiling.blockCount)
            try cancellation.check()
        }

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
            real: outputReal,
            imaginary: outputImaginary,
            validSampleRange: validRange
        )
    }

    private func complexProduct(
        leftReal: [Double],
        leftImaginary: [Double],
        rightReal: [Double],
        rightImaginary: [Double]
    ) -> (real: [Double], imaginary: [Double]) {
        var real = [Double](repeating: 0, count: leftReal.count)
        var imaginary = [Double](repeating: 0, count: leftReal.count)
        for index in leftReal.indices {
            real[index] = leftReal[index] * rightReal[index]
                - leftImaginary[index] * rightImaginary[index]
            imaginary[index] = leftReal[index] * rightImaginary[index]
                + leftImaginary[index] * rightReal[index]
        }
        return (real, imaginary)
    }
}

private nonisolated struct RhythmicityKernelSpectrumKey: Hashable {
    var samplingRateBits: UInt64
    var frequencyBits: UInt64
    var widthBits: UInt64
    var fftSamples: Int
}

private nonisolated struct RhythmicityKernelSpectra {
    var realKernelReal: [Double]
    var realKernelImaginary: [Double]
    var imaginaryKernelReal: [Double]
    var imaginaryKernelImaginary: [Double]

    var byteCount: Int { realKernelReal.count * 4 * MemoryLayout<Double>.stride }
}

/// Small LRU bounded to one eighth of the total backend budget. Spectrum
/// entries are immutable and can safely be shared by frequency workers.
private nonisolated final class RhythmicityKernelSpectrumCache: @unchecked Sendable {
    private struct Entry {
        var spectra: RhythmicityKernelSpectra
        var access: UInt64
    }

    private let lock = NSLock()
    private let maximumBytes: Int
    private var entries: [RhythmicityKernelSpectrumKey: Entry] = [:]
    private var totalBytes = 0
    private var access: UInt64 = 0

    init(maximumBytes: Int) { self.maximumBytes = max(maximumBytes, 0) }

    func value(for key: RhythmicityKernelSpectrumKey) -> RhythmicityKernelSpectra? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        access &+= 1
        entry.access = access
        entries[key] = entry
        return entry.spectra
    }

    func insert(_ spectra: RhythmicityKernelSpectra, for key: RhythmicityKernelSpectrumKey) {
        guard spectra.byteCount <= maximumBytes else { return }
        lock.lock()
        defer { lock.unlock() }
        if let old = entries.removeValue(forKey: key) { totalBytes -= old.spectra.byteCount }
        while totalBytes + spectra.byteCount > maximumBytes,
              let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key,
              let removed = entries.removeValue(forKey: oldest) {
            totalBytes -= removed.spectra.byteCount
        }
        access &+= 1
        entries[key] = Entry(spectra: spectra, access: access)
        totalBytes += spectra.byteCount
    }
}
