//
//  SimulationWriter.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Writing a simulation out as real MFF packages, so the contaminated recording
//  goes through exactly the same import, detection, correction and export path
//  as a scanner recording would. Nothing here takes a shortcut into EVA's
//  internals: if a correction can be run on this, it can be run on real data,
//  and vice versa.
//
//  Two packages are written per run — the ground truth and the contaminated
//  recording — plus a JSON sidecar holding everything that cannot be recovered
//  from the files themselves (the true beat times as opposed to the jittered
//  ones, the per-channel artifact amplitudes, the alpha block design, the seed).
//

import Foundation

nonisolated enum SimulateError: LocalizedError {
    case badTemplate(String)
    case usage(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .badTemplate(let detail): return "Bad gradient template: \(detail)"
        case .usage(let detail): return detail
        case .io(let detail): return detail
        }
    }
}

/// Everything a scoring run needs that the recordings themselves do not carry.
nonisolated struct SimulationTruth: Codable, Sendable {
    var config: SimulationConfig
    var cleanStandardDeviation: Double
    /// Alpha envelope decimated to 1 Hz — enough to correlate recovered alpha
    /// power against the eyes-open/eyes-closed design, without carrying a
    /// full-rate copy of a sine wave in the sidecar.
    var alphaEnvelope1Hz: [Double]
    var gradientVolumeOnsetsSeconds: [Double]
    var gradientQuantizedVolumeOnsetsSeconds: [Double]
    var gradientChannelAmplitudesMicrovolts: [Double]
    var bcgTrueBeatSeconds: [Double]
    var bcgDetectedBeatSeconds: [Double]
    var bcgChannelScales: [Double]
    var bcgChannelLatenciesSeconds: [Double]
}

nonisolated enum SimulationWriter {

    /// A fixed timestamp rather than `Date()`: two runs of the same seed should
    /// produce byte-identical packages, and a recording time that moves would
    /// break that for no benefit.
    static let recordingStart = Date(timeIntervalSince1970: 1_755_000_000)

    static func channelNames(count: Int) -> [String] {
        (1...max(1, count)).map { "E\($0)" }
    }

    static func signal(
        channels: [[Double]],
        config: SimulationConfig,
        signalType: String,
        events: [MFFEvent],
        packageURL: URL,
        names: [String]? = nil
    ) -> MFFSignalData {
        let data = channels.map { channel in channel.map { Float($0) } }
        return MFFSignalData(
            signalURL: packageURL.appendingPathComponent("signal1.bin"),
            signalType: signalType,
            numberOfChannels: data.count,
            samplingRate: config.samplingRate,
            duration: Double(config.sampleCount) / config.samplingRate,
            recordingStartTime: recordingStart,
            events: events,
            data: data,
            channelNames: names ?? channelNames(count: data.count)
        )
    }

    static func events(
        gradient: GradientInjection?,
        bcg: BCGInjection?,
        config: SimulationConfig
    ) -> [MFFEvent] {
        var events: [MFFEvent] = []

        if let gradient {
            // TREV is what EVA's gradient stage looks for by default, and the
            // *quantized* onset is what a real recorded trigger carries — the
            // amplifier can only timestamp it to its own sample clock. Writing
            // the exact continuous onset instead would hand the correction a
            // precision no real recording has, and would hide the very residual
            // the clock-offset model exists to produce.
            for (index, onset) in gradient.quantizedVolumeOnsetsSeconds.enumerated() {
                events.append(MFFEvent(
                    id: "sim-trev-\(index)",
                    code: "TREV",
                    label: "Volume \(index + 1)",
                    beginTimeSeconds: onset,
                    rawBeginTime: String(format: "%.6f", onset),
                    sourceFile: "EVASimulate"
                ))
            }
        }

        if let bcg {
            for (index, beat) in bcg.detectedBeatSeconds.enumerated() {
                events.append(MFFEvent(
                    id: "sim-qrsd-\(index)",
                    code: "QRSd",
                    label: "Detected beat",
                    eventDescription: "QRS as an automatic detector would report it, "
                        + "jittered by \(Int(config.qrsDetectionJitterSDSeconds * 1000)) ms SD",
                    beginTimeSeconds: beat,
                    rawBeginTime: String(format: "%.6f", beat),
                    sourceFile: "EVASimulate"
                ))
            }
            for (index, beat) in bcg.trueBeatSeconds.enumerated() {
                events.append(MFFEvent(
                    id: "sim-qrst-\(index)",
                    code: "QRSt",
                    label: "True beat",
                    eventDescription: "Ground-truth beat time; the artifact was injected here",
                    beginTimeSeconds: beat,
                    rawBeginTime: String(format: "%.6f", beat),
                    sourceFile: "EVASimulate"
                ))
            }
        }

        return events.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
    }

    static func pnsSignal(
        ecg: [Double]?,
        motion: [Double]?,
        config: SimulationConfig,
        packageURL: URL
    ) -> MFFSignalData? {
        var channels: [[Double]] = []
        var names: [String] = []
        if let ecg {
            channels.append(ecg)
            names.append("ECG")
        }
        if let motion {
            channels.append(motion)
            names.append("Motion")
        }
        guard !channels.isEmpty else { return nil }

        return MFFSignalData(
            signalURL: packageURL.appendingPathComponent("signal2.bin"),
            signalType: "PNS",
            numberOfChannels: channels.count,
            samplingRate: config.samplingRate,
            duration: Double(config.sampleCount) / config.samplingRate,
            recordingStartTime: recordingStart,
            events: [],
            data: channels.map { channel in channel.map { Float($0) } },
            channelNames: names
        )
    }

    static func writeTruth(_ truth: SimulationTruth, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(truth)
        try data.write(to: url)
    }

    static func decimateToOneHz(_ envelope: [Double], samplingRate: Double) -> [Double] {
        let step = max(1, Int(samplingRate.rounded()))
        return stride(from: 0, to: envelope.count, by: step).map { envelope[$0] }
    }
}
