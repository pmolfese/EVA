//
//  main.swift
//  EVA Helper
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
//  Proof-of-concept command-line helper for MFF AAS + CWL cleanup.
//

import Foundation

enum HelperError: LocalizedError {
    case usage(String)
    case helpRequested
    case missingPNS
    case missingCWLChannels
    case incompatibleCWLTiming
    case unsupportedSegmentedInput
    case unsupportedInput(URL)
    case outputExists(URL)
    case noTREvents(String)
    case noEventCandidates
    case compareMismatch(
        maxDifference: Double,
        rmsDifference: Double,
        relativeMaxDifference: Double?,
        relativeRMSDifference: Double?,
        maxTolerance: Double,
        rmsTolerance: Double,
        relativeMaxTolerance: Double,
        relativeRMSTolerance: Double
    )

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        case .helpRequested:
            return nil
        case .missingPNS:
            return "No PNS signal was found. CWL channels must be present as PNS channels."
        case .missingCWLChannels:
            return "No PNS channel names start with CWL."
        case .incompatibleCWLTiming:
            return "CWL correction requires EEG and selected CWL channels to share sample rate and sample count."
        case .unsupportedSegmentedInput:
            return "This helper POC expects a continuous MFF file, not a segmented or averaged MFF."
        case .unsupportedInput(let url):
            return "Unsupported input type \(url.lastPathComponent). Use .mff, .vhdr, .eeg, or .vmrk."
        case .outputExists(let url):
            return "\(url.path) already exists. Choose a different --prefix or pass --overwrite."
        case .noTREvents(let code):
            return "No usable TR events were found for event code \(code)."
        case .noEventCandidates:
            return "The MFF did not contain any event code with at least two events."
        case .compareMismatch(
            let maxDifference,
            let rmsDifference,
            let relativeMaxDifference,
            let relativeRMSDifference,
            let maxTolerance,
            let rmsTolerance,
            let relativeMaxTolerance,
            let relativeRMSTolerance
        ):
            if let relativeMaxDifference, let relativeRMSDifference {
                return String(
                    format: "CWL backend comparison exceeded tolerance: absolute max %.6g (limit %.6g), RMS %.6g (limit %.6g); relative max %.6g (limit %.6g), relative RMS %.6g (limit %.6g).",
                    maxDifference,
                    maxTolerance,
                    rmsDifference,
                    rmsTolerance,
                    relativeMaxDifference,
                    relativeMaxTolerance,
                    relativeRMSDifference,
                    relativeRMSTolerance
                )
            }
            return String(
                format: "CWL backend comparison exceeded tolerance: absolute max %.6g (limit %.6g), RMS %.6g (limit %.6g).",
                maxDifference,
                maxTolerance,
                rmsDifference,
                rmsTolerance
            )
        }
    }
}

struct Options {
    var inputURL: URL
    var prefix: String
    var trCode: String?
    var downsampleRate: Double?
    var overwrite = false
    var verbose = false
    var windowBefore = GradientRemover.Window.default.before
    var windowAfter = GradientRemover.Window.default.after
    var useOriginalCWL = false
    var originalCWLDelaySeconds = 0.021
    var originalCWLTaperFactor = 1
    var cwlBackend = CWLCorrectorEngine.Backend.metal
    var cwlGPUKernel = CWLCorrectorEngine.GPUKernel.sampleParallel
    var cwlGPUBatchWindows = 1
    var cwlLagMinMs = -50.0
    var cwlLagMaxMs = 150.0
    var cwlLagStepMs = 10.0
    var cwlWindowSeconds = 4.0
    var cwlHopSeconds: Double?
    var compareAssert = true
    var compareMaxDiff = 1e-2
    var compareRMSDiff = 1e-3
    var compareRelativeMaxDiff = 5e-2
    var compareRelativeRMSDiff = 1e-2

    static func parse(_ arguments: [String]) throws -> Options {
        var inputPath: String?
        var prefix: String?
        var trCode: String?
        var downsampleRate: Double?
        var overwrite = false
        var verbose = false
        var windowBefore = GradientRemover.Window.default.before
        var windowAfter = GradientRemover.Window.default.after
        var useOriginalCWL = false
        var originalCWLDelaySeconds = 0.021
        var originalCWLTaperFactor = 1
        var cwlBackend = CWLCorrectorEngine.Backend.metal
        var cwlGPUKernel = CWLCorrectorEngine.GPUKernel.sampleParallel
        var cwlGPUBatchWindows = 1
        var cwlLagMinMs = -50.0
        var cwlLagMaxMs = 150.0
        var cwlLagStepMs = 10.0
        var cwlWindowSeconds = 4.0
        var cwlHopSeconds: Double?
        var compareAssert = true
        var compareMaxDiff = 1e-2
        var compareRMSDiff = 1e-3
        var compareRelativeMaxDiff = 5e-2
        var compareRelativeRMSDiff = 1e-2

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                throw HelperError.helpRequested
            case "--prefix":
                index += 1
                prefix = try value(at: index, in: arguments, flag: argument)
            case "--tr-code":
                index += 1
                trCode = try value(at: index, in: arguments, flag: argument)
            case "--downsample":
                index += 1
                downsampleRate = try doubleValue(at: index, in: arguments, flag: argument)
            case "--downsample-rate", "--downsample-before-cwl", "--downsample-before-cwl-rate":
                throw HelperError.usage("\(argument) was removed. Use --downsample <hz> to downsample after AAS and before CWL.")
            case "--overwrite":
                overwrite = true
            case "--verbose":
                verbose = true
            case "--window-before":
                index += 1
                windowBefore = try intValue(at: index, in: arguments, flag: argument)
            case "--window-after":
                index += 1
                windowAfter = try intValue(at: index, in: arguments, flag: argument)
            case "--orig":
                useOriginalCWL = true
            case "--orig-delay":
                index += 1
                originalCWLDelaySeconds = try doubleValue(at: index, in: arguments, flag: argument)
                useOriginalCWL = true
            case "--orig-taper-factor":
                index += 1
                originalCWLTaperFactor = try intValue(at: index, in: arguments, flag: argument)
                useOriginalCWL = true
            case "--cwl-backend":
                index += 1
                let raw = try value(at: index, in: arguments, flag: argument)
                guard let backend = CWLCorrectorEngine.Backend(rawValue: raw) else {
                    throw HelperError.usage("--cwl-backend must be metal, cpu, or compare.")
                }
                cwlBackend = backend
            case "--cwl-gpu-kernel":
                index += 1
                let raw = try value(at: index, in: arguments, flag: argument)
                guard let kernel = CWLCorrectorEngine.GPUKernel(rawValue: raw) else {
                    throw HelperError.usage("--cwl-gpu-kernel must be serial or sample-parallel.")
                }
                cwlGPUKernel = kernel
            case "--gpu-batch-windows":
                index += 1
                cwlGPUBatchWindows = try intValue(at: index, in: arguments, flag: argument)
            case "--cwl-lag-min":
                index += 1
                cwlLagMinMs = try doubleValue(at: index, in: arguments, flag: argument)
            case "--cwl-lag-max":
                index += 1
                cwlLagMaxMs = try doubleValue(at: index, in: arguments, flag: argument)
            case "--cwl-lag-step":
                index += 1
                cwlLagStepMs = try doubleValue(at: index, in: arguments, flag: argument)
            case "--cwl-window":
                index += 1
                cwlWindowSeconds = try doubleValue(at: index, in: arguments, flag: argument)
            case "--cwl-hop":
                index += 1
                cwlHopSeconds = try doubleValue(at: index, in: arguments, flag: argument)
            case "--compare-no-assert":
                compareAssert = false
            case "--compare-max-diff":
                index += 1
                compareMaxDiff = try doubleValue(at: index, in: arguments, flag: argument)
            case "--compare-rms-diff":
                index += 1
                compareRMSDiff = try doubleValue(at: index, in: arguments, flag: argument)
            case "--compare-relative-max-diff":
                index += 1
                compareRelativeMaxDiff = try doubleValue(at: index, in: arguments, flag: argument)
            case "--compare-relative-rms-diff":
                index += 1
                compareRelativeRMSDiff = try doubleValue(at: index, in: arguments, flag: argument)
            default:
                if argument.hasPrefix("-") {
                    throw HelperError.usage("Unknown flag: \(argument)")
                }
                guard inputPath == nil else {
                    throw HelperError.usage("Unexpected extra input path: \(argument)")
                }
                inputPath = argument
            }
            index += 1
        }

        guard let inputPath else {
            throw HelperError.usage("Missing input recording path.")
        }
        guard let prefix, !prefix.isEmpty else {
            throw HelperError.usage("Missing required --prefix value.")
        }
        guard !prefix.contains("/") && !prefix.contains("\\") else {
            throw HelperError.usage("--prefix must be a filename prefix, not a path.")
        }
        if let downsampleRate, downsampleRate <= 0 {
            throw HelperError.usage("--downsample must be followed by a positive target frequency in Hz.")
        }
        guard windowBefore > 0, windowAfter > 0 else {
            throw HelperError.usage("--window-before and --window-after must be positive.")
        }
        guard originalCWLDelaySeconds >= 0, originalCWLTaperFactor >= 1 else {
            throw HelperError.usage("--orig-delay must be non-negative and --orig-taper-factor must be at least 1.")
        }
        guard cwlGPUBatchWindows > 0 else {
            throw HelperError.usage("--gpu-batch-windows must be positive.")
        }
        guard cwlLagMinMs <= cwlLagMaxMs else {
            throw HelperError.usage("--cwl-lag-min must be less than or equal to --cwl-lag-max.")
        }
        guard cwlLagStepMs > 0, cwlWindowSeconds > 0 else {
            throw HelperError.usage("--cwl-lag-step and --cwl-window must be positive.")
        }
        if let cwlHopSeconds, cwlHopSeconds <= 0 {
            throw HelperError.usage("--cwl-hop must be positive.")
        }
        guard compareMaxDiff >= 0, compareRMSDiff >= 0 else {
            throw HelperError.usage("--compare-max-diff and --compare-rms-diff must be non-negative.")
        }
        guard compareRelativeMaxDiff >= 0, compareRelativeRMSDiff >= 0 else {
            throw HelperError.usage("--compare-relative-max-diff and --compare-relative-rms-diff must be non-negative.")
        }

        return Options(
            inputURL: absoluteFileURL(inputPath),
            prefix: prefix,
            trCode: trCode,
            downsampleRate: downsampleRate,
            overwrite: overwrite,
            verbose: verbose,
            windowBefore: windowBefore,
            windowAfter: windowAfter,
            useOriginalCWL: useOriginalCWL,
            originalCWLDelaySeconds: originalCWLDelaySeconds,
            originalCWLTaperFactor: originalCWLTaperFactor,
            cwlBackend: cwlBackend,
            cwlGPUKernel: cwlGPUKernel,
            cwlGPUBatchWindows: cwlGPUBatchWindows,
            cwlLagMinMs: cwlLagMinMs,
            cwlLagMaxMs: cwlLagMaxMs,
            cwlLagStepMs: cwlLagStepMs,
            cwlWindowSeconds: cwlWindowSeconds,
            cwlHopSeconds: cwlHopSeconds,
            compareAssert: compareAssert,
            compareMaxDiff: compareMaxDiff,
            compareRMSDiff: compareRMSDiff,
            compareRelativeMaxDiff: compareRelativeMaxDiff,
            compareRelativeRMSDiff: compareRelativeRMSDiff
        )
    }

    private static func value(at index: Int, in arguments: [String], flag: String) throws -> String {
        guard arguments.indices.contains(index) else {
            throw HelperError.usage("Missing value for \(flag).")
        }
        return arguments[index]
    }

    private static func doubleValue(at index: Int, in arguments: [String], flag: String) throws -> Double {
        let raw = try value(at: index, in: arguments, flag: flag)
        guard let value = Double(raw) else {
            throw HelperError.usage("Expected a number for \(flag), got \(raw).")
        }
        return value
    }

    private static func intValue(at index: Int, in arguments: [String], flag: String) throws -> Int {
        let raw = try value(at: index, in: arguments, flag: flag)
        guard let value = Int(raw) else {
            throw HelperError.usage("Expected an integer for \(flag), got \(raw).")
        }
        return value
    }
}

struct EventCandidate {
    let code: String
    let count: Int
    let firstTime: Double
    let lastTime: Double
    let medianGap: Double
    let minGap: Double
    let maxGap: Double
    let sourceFiles: [String]
}

struct LoadedRecording {
    var signal: MFFSignalData
    var pnsSignal: MFFSignalData?
    var description: String
}

final class ProgressPrinter {
    private var lastPercent = -1
    private var lastMessage = ""
    private var printedProgress = false

    func update(_ fraction: Double, _ message: String, detail: String? = nil) {
        let clamped = min(max(fraction, 0), 1)
        let percent = Int((clamped * 100).rounded(.down))
        let display = detail.map { "\(message) - \($0)" } ?? message
        guard percent != lastPercent || display != lastMessage else { return }
        lastPercent = percent
        lastMessage = display
        printedProgress = true
        writeStdout(String(format: "\u{001B}[2K\r%3d%% %@", percent, display))
    }

    func finishLine(clear: Bool = false) {
        if printedProgress {
            writeStdout(clear ? "\u{001B}[2K\r" : "\n")
            printedProgress = false
        }
        lastPercent = -1
        lastMessage = ""
    }

    func clearLine() {
        finishLine(clear: true)
    }

    func log(_ message: String) {
        clearLine()
        writeStdoutLine("[verbose] \(message)")
    }
}

func usage() -> String {
    """
    Usage:
      eva-helper <input.mff|input.vhdr|input.eeg|input.vmrk> --prefix <prefix> [options]

    Required:
      --prefix <prefix>          Prefix for the output MFF package name.

    Options:
      --tr-code <code>           Skip interactive TR event selection.
      --downsample <hz>          Downsample after AAS and before CWL.
      --overwrite                Replace an existing output package.
      --verbose                  Print CPU/GPU preparation and submission details.
      --window-before <n>        AAS template TRs before current TR (default 4).
      --window-after <n>         AAS template TRs after current TR (default 4).
      --orig                     Use MATLAB CWRegrTool-style tapered Hann CWL.
      --orig-delay <seconds>     Original CWL delay half-width (default 0.021).
      --orig-taper-factor <n>    Original CWL taper factor (default 1).
      --cwl-backend <name>       CWL backend: metal, cpu, compare (default metal).
      --cwl-gpu-kernel <name>    Metal kernel: serial, sample-parallel (default sample-parallel).
      --gpu-batch-windows <n>    Submit this many CWL windows per command buffer (default 1).
      --cwl-lag-min <ms>         CWL minimum lag in ms (default -50).
      --cwl-lag-max <ms>         CWL maximum lag in ms (default 150).
      --cwl-lag-step <ms>        CWL lag step in ms (default 10).
      --cwl-window <seconds>     CWL sliding regression window (default 4).
      --cwl-hop <seconds>        Hop between CWL windows (default half of --cwl-window).
      --compare-max-diff <value> Fail compare if max abs diff exceeds this (default 1e-2).
      --compare-rms-diff <value> Fail compare if RMS diff exceeds this (default 1e-3).
      --compare-relative-max-diff <value>
                                  Relative max diff tolerance vs correction magnitude (default 5e-2).
      --compare-relative-rms-diff <value>
                                  Relative RMS diff tolerance vs correction magnitude (default 1e-2).
      --compare-no-assert        Report compare metrics without failing on mismatch.

    Notes:
      --orig --cwl-backend compare reports Metal-vs-original differences without asserting equivalence.
    """
}

func remapCWLProgress(
    _ progress: @escaping (CWLCorrectorEngine.ProgressUpdate) -> Void,
    start: Double,
    end: Double
) -> (CWLCorrectorEngine.ProgressUpdate) -> Void {
    { update in
        progress(CWLCorrectorEngine.ProgressUpdate(
            fraction: start + (end - start) * min(max(update.fraction, 0), 1),
            phase: update.phase,
            message: update.message,
            detail: update.detail
        ))
    }
}

func run() throws {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    let outputURL = options.inputURL
        .deletingLastPathComponent()
        .appendingPathComponent(options.prefix + options.inputURL.deletingPathExtension().lastPathComponent)
        .appendingPathExtension("mff")

    if FileManager.default.fileExists(atPath: outputURL.path), !options.overwrite {
        throw HelperError.outputExists(outputURL)
    }

    let progress = ProgressPrinter()
    defer { progress.finishLine() }
    let verboseLog: ((String) -> Void)? = options.verbose ? { progress.log($0) } : nil

    writeStdoutLine("EVA helper POC")
    writeStdoutLine("Input:  \(options.inputURL.path)")
    writeStdoutLine("Output: \(outputURL.path)")
    verboseLog?("Options: backend=\(options.cwlBackend.rawValue), gpuKernel=\(options.cwlGPUKernel.rawValue), gpuBatchWindows=\(options.cwlGPUBatchWindows), orig=\(options.useOriginalCWL)")

    let loaded = try loadRecording(from: options.inputURL, progress: progress, verbose: verboseLog)
    let signal = loaded.signal
    guard !signal.isSegmented, !signal.isAveraged else {
        throw HelperError.unsupportedSegmentedInput
    }

    guard let pnsSignal = loaded.pnsSignal else {
        throw HelperError.missingPNS
    }
    progress.finishLine()
    verboseLog?("Loaded \(loaded.description): EEG channels=\(signal.numberOfChannels), PNS/reference channels=\(pnsSignal.numberOfChannels), samples=\(signal.sampleCount)")

    let trCode = try options.trCode ?? promptForTRCode(events: signal.events)
    let trSamples = trMarkers(in: signal, code: trCode, samplingRate: signal.samplingRate)
    guard trSamples.count >= 2 else {
        throw HelperError.noTREvents(trCode)
    }
    writeStdoutLine("Using TR event code \(displayCode(trCode)) (\(trSamples.count) events).")

    let window = GradientRemover.Window(before: options.windowBefore, after: options.windowAfter)

    verboseLog?("AAS CPU: correcting all \(signal.numberOfChannels) EEG channels")
    progress.update(0.20, "Applying AAS MRI correction to EEG")
    let aasEEG = try GradientRemover.correct(
        channels: signal.data,
        trSamples: trSamples,
        window: window,
        reducer: .weightedMean,
        fit: .subtract
    ) { fraction in
        progress.update(0.20 + 0.24 * fraction, "Applying AAS MRI correction to EEG")
    }
    var currentSignal = signal.copying(
        data: aasEEG,
        samplingRate: signal.samplingRate,
        signalTypeSuffix: "AAS"
    )

    let pnsTRSamples = trMarkers(in: signal, code: trCode, samplingRate: pnsSignal.samplingRate)
    verboseLog?("AAS CPU: correcting \(pnsSignal.numberOfChannels) PNS/reference channels")
    progress.update(0.44, "Applying AAS MRI correction to PNS")
    let aasPNS = try GradientRemover.correct(
        channels: pnsSignal.data,
        trSamples: pnsTRSamples,
        window: window,
        reducer: .weightedMean,
        fit: .subtract
    ) { fraction in
        progress.update(0.44 + 0.10 * fraction, "Applying AAS MRI correction to PNS")
    }
    var currentPNS = pnsSignal.copying(
        data: aasPNS,
        samplingRate: pnsSignal.samplingRate,
        signalTypeSuffix: "AAS"
    )

    var cwlProgressStart = 0.54
    if let targetRate = options.downsampleRate {
        if targetRate < currentSignal.samplingRate {
            verboseLog?(String(format: "Downsample before CWL: %.3f Hz -> %.3f Hz", currentSignal.samplingRate, targetRate))
            let downsampleStart = 0.54
            let downsampleMid = 0.56
            let downsampleEnd = 0.58
            progress.update(downsampleStart, "Downsampling before CWL")
            currentSignal = downsample(
                currentSignal,
                targetRate: targetRate,
                signalTypeSuffix: "DS"
            ) { fraction in
                progress.update(
                    downsampleStart + (downsampleMid - downsampleStart) * fraction,
                    "Downsampling EEG before CWL"
                )
            }
            currentPNS = downsample(
                currentPNS,
                targetRate: targetRate,
                signalTypeSuffix: "DS"
            ) { fraction in
                progress.update(
                    downsampleMid + (downsampleEnd - downsampleMid) * fraction,
                    "Downsampling PNS before CWL"
                )
            }
            cwlProgressStart = downsampleEnd
            progress.finishLine()
            writeStdoutLine(String(format: "Downsampled before CWL to %.3f Hz.", currentSignal.samplingRate))
        } else {
            verboseLog?(String(format: "Downsample before CWL skipped: selected %.3f Hz for %.3f Hz input", targetRate, currentSignal.samplingRate))
        }
    }

    progress.clearLine()
    let cwlIndices = cwlChannelIndices(in: currentPNS)
    guard !cwlIndices.isEmpty else {
        throw HelperError.missingCWLChannels
    }
    writeStdoutLine("Using CWL PNS channels:")
    for index in cwlIndices {
        writeStdoutLine("  \(index + 1): \(channelName(at: index, in: currentPNS, fallbackPrefix: "PNS"))")
    }

    guard samplingRatesMatch(currentSignal.samplingRate, currentPNS.samplingRate),
          currentSignal.sampleCount == currentPNS.sampleCount else {
        throw HelperError.incompatibleCWLTiming
    }

    let references = cwlIndices.map { currentPNS.data[$0] }
    let cwlProgressEnd = 0.86
    progress.update(cwlProgressStart, "Running CWL regression")
    let cwlProgress: (CWLCorrectorEngine.ProgressUpdate) -> Void = { update in
        progress.update(
            cwlProgressStart + (cwlProgressEnd - cwlProgressStart) * update.fraction,
            update.message,
            detail: update.detail
        )
    }
    let cwlResult: CWLCorrectorEngine.RunInfo
    if options.useOriginalCWL && options.cwlBackend == .compare {
        verboseLog?("Original CWL compare mode: comparing Metal path against MATLAB-style tapered Hann CPU path")
        let fastConfig = CWLCorrectorEngine.Config(
            backend: .metal,
            gpuKernel: options.cwlGPUKernel,
            gpuBatchWindows: options.cwlGPUBatchWindows,
            lagRangeMs: options.cwlLagMinMs...options.cwlLagMaxMs,
            lagStepMs: options.cwlLagStepMs,
            windowSeconds: options.cwlWindowSeconds,
            hopSeconds: options.cwlHopSeconds
        )
        let fast = try CWLCorrectorEngine.correct(
            eeg: currentSignal.data,
            references: references,
            samplingRate: currentSignal.samplingRate,
            config: fastConfig,
            progress: remapCWLProgress(cwlProgress, start: 0.0, end: 0.50),
            verbose: verboseLog
        )
        let original = try OriginalCWLCorrectorEngine.correct(
            eeg: currentSignal.data,
            references: references,
            samplingRate: currentSignal.samplingRate,
            config: OriginalCWLCorrectorEngine.Config(
                windowSeconds: options.cwlWindowSeconds,
                delaySeconds: options.originalCWLDelaySeconds,
                taperFactor: options.originalCWLTaperFactor
            ),
            progress: remapCWLProgress(cwlProgress, start: 0.50, end: 0.98),
            verbose: verboseLog
        )
        var comparison = CWLCorrectorEngine.compare(fast.corrected, original.corrected)
        let fastDelta = CWLCorrectorEngine.compare(fast.corrected, currentSignal.data)
        let originalDelta = CWLCorrectorEngine.compare(original.corrected, currentSignal.data)
        comparison.relativeMaxDifference = comparison.maxAbsoluteDifference
            / max(fastDelta.maxAbsoluteDifference, originalDelta.maxAbsoluteDifference, 1e-12)
        comparison.relativeRMSDifference = comparison.rmsDifference
            / max(fastDelta.rmsDifference, originalDelta.rmsDifference, 1e-12)
        cwlProgress(CWLCorrectorEngine.ProgressUpdate(
            fraction: 1,
            phase: .comparing,
            message: "Compared CWL to original",
            detail: String(format: "max %.6g, rms %.6g", comparison.maxAbsoluteDifference, comparison.rmsDifference)
        ))
        verboseLog?(
            String(
                format: "CWL original compare: fast windows=%d regressors=%d, original windows=%d regressors=%d",
                fast.windowCount,
                fast.regressorCount,
                original.windowCount,
                original.regressorCount
            )
        )
        verboseLog?(
            String(
                format: "CWL original compare detail: max at channel %d sample %d, metal %.6g, original %.6g",
                comparison.maxChannel + 1,
                comparison.maxSample,
                comparison.leftValue,
                comparison.rightValue
            )
        )
        cwlResult = CWLCorrectorEngine.RunInfo(
            corrected: original.corrected,
            backendDescription: "\(original.backendDescription) + Metal \(options.cwlGPUKernel.rawValue) diagnostic compare",
            deviceName: fast.deviceName,
            windowCount: original.windowCount,
            regressorCount: original.regressorCount,
            cpuSeconds: original.cpuSeconds,
            gpuSeconds: fast.gpuSeconds,
            comparison: comparison
        )
    } else if options.useOriginalCWL {
        verboseLog?("Original CWL mode: using MATLAB-style tapered Hann CPU path; Metal/backend flags are ignored")
        cwlResult = try OriginalCWLCorrectorEngine.correct(
            eeg: currentSignal.data,
            references: references,
            samplingRate: currentSignal.samplingRate,
            config: OriginalCWLCorrectorEngine.Config(
                windowSeconds: options.cwlWindowSeconds,
                delaySeconds: options.originalCWLDelaySeconds,
                taperFactor: options.originalCWLTaperFactor
            ),
            progress: cwlProgress,
            verbose: verboseLog
        )
    } else {
        let cwlConfig = CWLCorrectorEngine.Config(
            backend: options.cwlBackend,
            gpuKernel: options.cwlGPUKernel,
            gpuBatchWindows: options.cwlGPUBatchWindows,
            lagRangeMs: options.cwlLagMinMs...options.cwlLagMaxMs,
            lagStepMs: options.cwlLagStepMs,
            windowSeconds: options.cwlWindowSeconds,
            hopSeconds: options.cwlHopSeconds
        )
        cwlResult = try CWLCorrectorEngine.correct(
            eeg: currentSignal.data,
            references: references,
            samplingRate: currentSignal.samplingRate,
            config: cwlConfig,
            progress: cwlProgress,
            verbose: verboseLog
        )
    }
    currentSignal = currentSignal.copying(
        data: cwlResult.corrected,
        samplingRate: currentSignal.samplingRate,
        signalTypeSuffix: "CWL"
    )
    progress.finishLine()
    writeStdoutLine("CWL backend: \(cwlResult.backendDescription)")
    if let deviceName = cwlResult.deviceName {
        writeStdoutLine("Metal CWL device: \(deviceName)")
    }
    writeStdoutLine("CWL windows: \(cwlResult.windowCount), lagged regressors: \(cwlResult.regressorCount)")
    if let gpuSeconds = cwlResult.gpuSeconds {
        writeStdoutLine(String(format: "CWL GPU time: %.3fs", gpuSeconds))
    }
    if let cpuSeconds = cwlResult.cpuSeconds {
        writeStdoutLine(String(format: "CWL CPU time: %.3fs", cpuSeconds))
    }
    let comparisonIsDiagnostic = options.useOriginalCWL && options.cwlBackend == .compare
    if let comparison = cwlResult.comparison {
        writeStdoutLine(String(format: "CWL compare: max diff %.6g, RMS diff %.6g", comparison.maxAbsoluteDifference, comparison.rmsDifference))
        if let relativeMax = comparison.relativeMaxDifference,
           let relativeRMS = comparison.relativeRMSDifference {
            writeStdoutLine(String(format: "CWL compare relative: max %.6g, RMS %.6g", relativeMax, relativeRMS))
        }
        if comparisonIsDiagnostic {
            writeStdoutLine("CWL compare assertion: skipped (original MATLAB-style CWL and Metal helper CWL are different algorithms).")
        } else if options.compareAssert {
            let absolutePassed = comparison.maxAbsoluteDifference <= options.compareMaxDiff
                && comparison.rmsDifference <= options.compareRMSDiff
            let relativePassed: Bool
            if let relativeMax = comparison.relativeMaxDifference,
               let relativeRMS = comparison.relativeRMSDifference {
                relativePassed = relativeMax <= options.compareRelativeMaxDiff
                    && relativeRMS <= options.compareRelativeRMSDiff
            } else {
                relativePassed = false
            }
            let passed = absolutePassed || relativePassed
            let basis = absolutePassed ? "absolute" : (relativePassed ? "relative" : "none")
            writeStdoutLine(String(
                format: "CWL compare assertion: %@ via %@ (absolute max <= %.6g, RMS <= %.6g; relative max <= %.6g, RMS <= %.6g)",
                passed ? "pass" : "FAIL",
                basis,
                options.compareMaxDiff,
                options.compareRMSDiff,
                options.compareRelativeMaxDiff,
                options.compareRelativeRMSDiff
            ))
            if !passed {
                throw HelperError.compareMismatch(
                    maxDifference: comparison.maxAbsoluteDifference,
                    rmsDifference: comparison.rmsDifference,
                    relativeMaxDifference: comparison.relativeMaxDifference,
                    relativeRMSDifference: comparison.relativeRMSDifference,
                    maxTolerance: options.compareMaxDiff,
                    rmsTolerance: options.compareRMSDiff,
                    relativeMaxTolerance: options.compareRelativeMaxDiff,
                    relativeRMSTolerance: options.compareRelativeRMSDiff
                )
            }
        }
    }

    progress.update(0.92, "Writing MFF")
    try MFFWriter.write(
        signal: currentSignal,
        pnsSignal: currentPNS,
        segments: [],
        kind: .continuous,
        to: outputURL
    )
    progress.update(1.0, "Done")
    progress.finishLine()
    writeStdoutLine("Wrote \(outputURL.path)")
}

func loadRecording(
    from inputURL: URL,
    progress: ProgressPrinter,
    verbose: ((String) -> Void)?
) throws -> LoadedRecording {
    switch inputURL.pathExtension.lowercased() {
    case "mff":
        let reader = MFFReader()
        verbose?("Loading MFF EEG signal")
        progress.update(0.00, "Loading EEG from MFF")
        let signal = try reader.loadSignal(from: inputURL) { fraction in
            progress.update(0.01 + 0.12 * fraction, "Loading EEG from MFF")
        }
        verbose?("Loading MFF PNS signal")
        let pnsSignal = try reader.loadPNSSignal(from: inputURL) { fraction in
            progress.update(0.13 + 0.07 * fraction, "Loading PNS from MFF")
        }
        return LoadedRecording(signal: signal, pnsSignal: pnsSignal, description: "MFF")

    case "vhdr", "eeg", "vmrk":
        verbose?("Loading BrainVision recording")
        progress.update(0.00, "Loading BrainVision recording")
        let loaded = try BrainVisionHelperReader.load(from: inputURL) { fraction in
            progress.update(0.01 + 0.19 * fraction, "Loading BrainVision recording")
        }
        return LoadedRecording(
            signal: loaded.signal,
            pnsSignal: loaded.referenceSignal,
            description: "BrainVision \(loaded.headerURL.lastPathComponent)"
        )

    default:
        throw HelperError.unsupportedInput(inputURL)
    }
}

func promptForTRCode(events: [MFFEvent]) throws -> String {
    let candidates = eventCandidates(events)
    guard !candidates.isEmpty else { throw HelperError.noEventCandidates }

    writeStdoutLine("TR event candidates:")
    for (index, candidate) in candidates.enumerated() {
        let spacing = candidate.minGap == candidate.maxGap
            ? seconds(candidate.medianGap)
            : "\(seconds(candidate.medianGap)) median, \(seconds(candidate.minGap))...\(seconds(candidate.maxGap)) range"
        writeStdoutLine("  [\(index + 1)] \(displayCode(candidate.code))  count=\(candidate.count)  first=\(seconds(candidate.firstTime))  last=\(seconds(candidate.lastTime))  gap=\(spacing)")
    }

    while true {
        writeStdout("Select TR event number or code: ")
        guard let line = readLine() else {
            let examples = candidates.prefix(3)
                .map { "--tr-code \"\(displayCode($0.code))\"" }
                .joined(separator: " or ")
            throw HelperError.usage(
                "No TR event selection was provided on stdin. Re-run with \(examples)."
            )
        }
        let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            continue
        }
        if let selectedIndex = Int(raw), candidates.indices.contains(selectedIndex - 1) {
            return candidates[selectedIndex - 1].code
        }
        if let match = candidates.first(where: { $0.code.caseInsensitiveCompare(raw) == .orderedSame }) {
            return match.code
        }
        writeStdoutLine("No TR candidate matched \(raw).")
    }
}

func eventCandidates(_ events: [MFFEvent]) -> [EventCandidate] {
    let grouped = Dictionary(grouping: events, by: \.code)
    return grouped.compactMap { code, codeEvents in
        let times = codeEvents.map(\.beginTimeSeconds).sorted()
        guard times.count >= 2 else { return nil }
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        return EventCandidate(
            code: code,
            count: times.count,
            firstTime: times[0],
            lastTime: times[times.count - 1],
            medianGap: median(gaps),
            minGap: gaps.min() ?? 0,
            maxGap: gaps.max() ?? 0,
            sourceFiles: Array(Set(codeEvents.map(\.sourceFile))).sorted()
        )
    }
    .sorted {
        if $0.count != $1.count { return $0.count > $1.count }
        return $0.code.localizedStandardCompare($1.code) == .orderedAscending
    }
}

func trMarkers(in signal: MFFSignalData, code: String, samplingRate: Double) -> [Int] {
    signal.events
        .filter { $0.code.caseInsensitiveCompare(code) == .orderedSame }
        .map { Int(($0.beginTimeSeconds * samplingRate).rounded()) }
        .sorted()
}

func cwlChannelIndices(in pns: MFFSignalData) -> [Int] {
    (0..<pns.numberOfChannels).filter { index in
        channelName(at: index, in: pns, fallbackPrefix: "PNS")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: "CWL", options: [.caseInsensitive, .anchored]) != nil
    }
}

func channelName(at index: Int, in signal: MFFSignalData, fallbackPrefix: String) -> String {
    if let names = signal.channelNames, names.indices.contains(index), !names[index].isEmpty {
        return names[index]
    }
    return "\(fallbackPrefix) \(index + 1)"
}

func downsample(
    _ signal: MFFSignalData,
    targetRate: Double,
    signalTypeSuffix: String,
    progress: (Double) -> Void
) -> MFFSignalData {
    let factor = Downsampler.factor(sourceRate: signal.samplingRate, targetRate: targetRate)
    guard factor > 1 else {
        progress(1)
        return signal
    }

    var output: [[Float]] = []
    output.reserveCapacity(signal.data.count)
    for (index, channel) in signal.data.enumerated() {
        let decimated = Downsampler.blockAveraged(channel.map(Double.init), by: factor).map(Float.init)
        output.append(decimated)
        progress(Double(index + 1) / Double(max(signal.data.count, 1)))
    }

    return signal.copying(
        data: output,
        samplingRate: Downsampler.effectiveRate(sourceRate: signal.samplingRate, factor: factor),
        signalTypeSuffix: signalTypeSuffix
    )
}

func samplingRatesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
    abs(lhs - rhs) < 0.0001
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    if sorted.count % 2 == 0 {
        return (sorted[mid - 1] + sorted[mid]) / 2
    }
    return sorted[mid]
}

func seconds(_ value: Double) -> String {
    String(format: "%.3fs", value)
}

func displayCode(_ code: String) -> String {
    code.isEmpty ? "(empty)" : code
}

func absoluteFileURL(_ path: String) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(path)
        .standardizedFileURL
}

func writeStdout(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

func writeStdoutLine(_ text: String = "") {
    writeStdout(text + "\n")
}

func writeStderr(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

func runCWLSelfTest() throws {
    let sampleRate = 128.0
    let sampleCount = 768
    let references: [[Float]] = (0..<2).map { referenceIndex in
        (0..<sampleCount).map { sample in
            let t = Double(sample) / sampleRate
            return Float(
                sin(2 * Double.pi * (1.1 + 0.07 * Double(referenceIndex)) * t)
                + 0.25 * sin(2 * Double.pi * 2.3 * t + Double(referenceIndex))
            )
        }
    }
    let eeg: [[Float]] = (0..<4).map { channelIndex in
        let laggedA = helperShifted(references[0], by: channelIndex - 1)
        let laggedB = helperShifted(references[1], by: 2 - channelIndex)
        return (0..<sampleCount).map { sample in
            let t = Double(sample) / sampleRate
            let brain = 0.2 * sin(2 * Double.pi * (8 + Double(channelIndex)) * t)
            let artifact = 0.7 * Double(laggedA[sample]) - 0.35 * Double(laggedB[sample])
            return Float(brain + artifact)
        }
    }

    for kernel in [CWLCorrectorEngine.GPUKernel.serial, .sampleParallel] {
        var config = CWLCorrectorEngine.Config()
        config.backend = .compare
        config.gpuKernel = kernel
        config.lagRangeMs = -20...40
        config.lagStepMs = 20
        config.windowSeconds = 1
        config.hopSeconds = 0.5
        let result = try CWLCorrectorEngine.correct(
            eeg: eeg,
            references: references,
            samplingRate: sampleRate,
            config: config,
            progress: nil,
            verbose: { writeStdoutLine("[self-test] \($0)") }
        )
        if let comparison = result.comparison {
            writeStdoutLine(String(format: "[self-test] %@ max %.6g rms %.6g", kernel.rawValue, comparison.maxAbsoluteDifference, comparison.rmsDifference))
        }
    }
}

func helperShifted(_ signal: [Float], by lag: Int) -> [Float] {
    guard lag != 0 else { return signal }
    let sampleCount = signal.count
    return (0..<sampleCount).map { sample in
        signal[min(max(sample - lag, 0), sampleCount - 1)]
    }
}

extension MFFSignalData {
    var sampleCount: Int {
        data.first?.count ?? 0
    }

    func copying(
        data newData: [[Float]],
        samplingRate newSamplingRate: Double,
        signalTypeSuffix: String? = nil
    ) -> MFFSignalData {
        let newSampleCount = newData.first?.count ?? 0
        return MFFSignalData(
            signalURL: signalURL,
            signalType: signalTypeSuffix.map { "\(signalType) \($0)" } ?? signalType,
            numberOfChannels: newData.count,
            samplingRate: newSamplingRate,
            duration: newSamplingRate > 0 ? Double(newSampleCount) / newSamplingRate : duration,
            recordingStartTime: recordingStartTime,
            events: events,
            data: newData,
            channelNames: channelNames,
            epochSegments: epochSegments,
            isSegmented: isSegmented,
            isAveraged: isAveraged,
            isGrandAverage: isGrandAverage,
            impedancesKOhm: impedancesKOhm,
            positiveUpFlags: positiveUpFlags
        )
    }
}

do {
    if CommandLine.arguments.contains("--self-test-cwl") {
        try runCWLSelfTest()
        Foundation.exit(0)
    }
    try run()
} catch HelperError.helpRequested {
    writeStdoutLine(usage())
} catch {
    writeStderr("error: \(error.localizedDescription)\n\n")
    writeStderr(usage())
    writeStderr("\n")
    Foundation.exit(1)
}
