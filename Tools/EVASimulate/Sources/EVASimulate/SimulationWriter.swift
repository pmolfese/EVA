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

// `SimulateError` moved to EVA/Simulation/SimulationError.swift (SIM-0) so the
// generation core can throw it without depending on this CLI-side writer.

/// Everything a scoring run needs that the recordings themselves do not carry.
nonisolated struct SimulationTruth: Codable, Sendable {
    var config: SimulationConfig
    var cleanStandardDeviation: Double
    /// Alpha envelope decimated to 1 Hz — enough to correlate recovered alpha
    /// power against the eyes-open/eyes-closed design, without carrying a
    /// full-rate copy of a sine wave in the sidecar.
    var alphaEnvelope1Hz: [Double]
    /// Exact burst, spectral-envelope, microstate, and PAC truth for opt-in
    /// non-stationary EEG. Optional keeps earlier sidecars readable.
    var neuralNonstationarity: NeuralNonstationarityTruth? = nil
    var gradientVolumeOnsetsSeconds: [Double]
    var gradientQuantizedVolumeOnsetsSeconds: [Double]
    var gradientChannelAmplitudesMicrovolts: [Double]
    var bcgTrueBeatSeconds: [Double]
    var bcgDetectedBeatSeconds: [Double]
    var bcgChannelScales: [Double]
    var bcgChannelLatenciesSeconds: [Double]
    /// Spatial model used for the BCG: `channelIndex` (paper default, rank one,
    /// weighted by channel number) or `generators` (physically placed).
    var bcgSpatialModel: String? = nil
    /// Present only under `generators`. Each physical generator's topography,
    /// delay, width, share and per-beat weights — enough to score a recovered
    /// component against the generator that produced it.
    var bcgGenerators: [BCGGeneratorTruth]? = nil
    /// Normalized singular values of the generator topography matrix, largest
    /// first, and the count above 1%. This is the claim to check against
    /// Rusiniak et al.'s reported 4-8 components: the old channel-index model
    /// had exactly one.
    var bcgNormalizedSingularValues: [Double]? = nil
    var bcgSpatialRank: Int? = nil
    var bcgFieldStrengthTesla: Double? = nil
    var montageName: String
    var channelNames: [String]
    /// Reference applied to the complete additive sensor mixture before
    /// physical recording defects such as a bad reference, bridges, or rails.
    var recordingReference: EEGReference? = nil
    var referenceApplicationStage: String? = nil
    /// 1-based channel number -> the defect applied to it.
    var badChannels: [String: String]
    var blinkSeconds: [Double]
    var saccadeSeconds: [Double]
    /// Per-channel weight of the blink and horizontal-gaze topographies, so a
    /// demo can check that a recovered component really matches the one that
    /// was injected.
    var blinkTopography: [Double]
    var horizontalEyeTopography: [Double]
    /// Muscle bursts and their three normalized source-region topographies.
    /// Optional so truth sidecars written before EMG support remain readable.
    var emgBursts: [EMGBurstTruth]? = nil
    var emgLeftTemporalisTopography: [Double]? = nil
    var emgRightTemporalisTopography: [Double]? = nil
    var emgPosteriorNeckTopography: [Double]? = nil
    var chewingEpisodes: [ArtifactEpisodeTruth]? = nil
    var swallowingEpisodes: [ArtifactEpisodeTruth]? = nil
    var cableMovementEpisodes: [ArtifactEpisodeTruth]? = nil
    var sweatEpisodes: [ArtifactEpisodeTruth]? = nil
    var chewingTopography: [Double]? = nil
    var swallowingTopography: [Double]? = nil
    var badReferenceRMSMicrovolts: Double? = nil
    var bridgedChannelPairs: [ChannelBridge]? = nil
    var clippedSampleCounts: [Int]? = nil
    /// Per-channel electrode impedance in kΩ, empty when none was recorded.
    var impedancesKOhm: [Double]
    /// Latent contact impedance and its coupled noise realization. Optional so
    /// truth sidecars from before roadmap item 2.2 remain readable. The latent
    /// values remain populated when ICAL measurement export is disabled.
    var simulatedImpedancesKOhm: [Double]? = nil
    var impedanceThermalNoiseRMSMicrovolts: [Double]? = nil
    var impedanceLineNoiseGainsMicrovolts: [Double]? = nil
    /// When the scanner was actually running, in seconds.
    var scanStartSeconds: Double
    var scanEndSeconds: Double
    /// Present only for `--eeg-model dipole`. Full-rate source signals are
    /// exactly regenerable from these per-source seeds and the configuration;
    /// the small realized gain matrix is recorded directly.
    var sourceSpace: SourceSpaceTruth?
    var ocularDipoles: [OcularDipoleTruth]
    /// Populated by the ERP simulator in roadmap item 1.2. The metric and file
    /// contract exist now so future ERP truth is immediately scoreable.
    var erpComponents: [ERPComponent]? = nil
    var erpTrials: [ERPTrialTruth]? = nil
    var erpSource: SimulatedSource? = nil
    var erpTopography: [Double]? = nil
    var erpWaveformDescription: String? = nil
    var erpRealizedLatencyAmplitudeCorrelation: Double? = nil
    var erpRandomSeeds: ERPRandomSeedTruth? = nil
    /// Every ERP generator that contributed, with its placement, topography and
    /// per-trial latency and amplitude. Also records each component's distance
    /// to the nearest ongoing-EEG source, so a signal sitting on top of a noise
    /// source is visible rather than assumed away (roadmap 4.3).
    var erpComponentSources: [ERPComponentTruth]? = nil
    /// The frame `erpComponentSources` positions are expressed in.
    var erpCoordinateFrame: String? = nil
}

nonisolated struct SourceSpaceTruth: Codable, Sendable {
    var model: String
    var headModel: SphericalHeadModel
    var sources: [SimulatedSource]
    var leadField: LeadField
    var calibrationFactor: Double
    var sourceCorrelationMatrix: [[Double]]
    var topographicCorrelationMatrix: [[Double]]
    var motions: [SourceMotionTruth]
}

nonisolated enum SimulationWriter {

    /// A fixed timestamp rather than `Date()`: two runs of the same seed should
    /// produce byte-identical packages, and a recording time that moves would
    /// break that for no benefit.
    static let recordingStart = Date(timeIntervalSince1970: 1_755_000_000)

    /// Snaps an event time to the sample grid — the finest grid a discrete
    /// recording actually has, and the one a reader recovers.
    ///
    /// This used to snap to a whole millisecond instead, because `MFFWriter`
    /// formatted event times with `DateFormatter`, which carries millisecond
    /// internal precision no matter how many fractional digits the format
    /// string asks for. At 1024 Hz a sample is 976.5625 µs, so that displaced
    /// markers by up to half a sample and an occasional TR interval landed two
    /// samples off the median, which EVA's gradient stage rejects. Roadmap item
    /// 4.9 fixed the writer and the reader; event times now survive at
    /// microsecond precision, so nothing here needs to compensate.
    ///
    /// Three cleverer schemes were tried under the old constraint and all made
    /// things worse. Recording them so they are not tried again: repairing
    /// violations one at a time walks the error down the train; fitting each
    /// marker to its ideal position independently still leaves pairs two samples
    /// apart, because one marker can land 0.9 samples low while its neighbour
    /// lands 0.9 high; and constraining the interval while walking the train
    /// produces occasional large excursions when neither permitted interval is
    /// reachable. None of them could succeed, because a 0.977 ms sample grid is
    /// not representable on a 1 ms one — which is why the fix had to be in the
    /// writer's precision rather than here.
    static func writableEventTime(_ seconds: Double, samplingRate: Double) -> Double {
        (seconds * samplingRate).rounded() / samplingRate
    }

    /// Which sample EVA will recover from a written event time.
    static func recoveredSample(_ seconds: Double, samplingRate: Double) -> Int {
        Int((seconds * samplingRate).rounded())
    }

    /// Places a run of periodic markers on the sample grid. No interval repair
    /// is attempted or needed: rounding each onset to its own nearest sample
    /// keeps every marker within half a sample of the truth, so any two adjacent
    /// intervals differ by at most one sample.
    static func periodicMarkerTimes(onsets: [Double], samplingRate: Double) -> [Double] {
        onsets.map { writableEventTime($0, samplingRate: samplingRate) }
    }

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
        ocular: OcularInjection?,
        erp: ERPInjection?,
        emg: EMGInjection? = nil,
        additional: AdditionalArtifactInjection? = nil,
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
            let trTimes = periodicMarkerTimes(
                onsets: gradient.quantizedVolumeOnsetsSeconds,
                samplingRate: config.samplingRate
            )
            for (index, time) in trTimes.enumerated() {
                events.append(MFFEvent(
                    id: "sim-trev-\(index)",
                    code: "TREV",
                    label: "Volume \(index + 1)",
                    beginTimeSeconds: time,
                    rawBeginTime: String(format: "%.6f", time),
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
                    beginTimeSeconds: writableEventTime(beat, samplingRate: config.samplingRate),
                    rawBeginTime: String(format: "%.6f", writableEventTime(beat, samplingRate: config.samplingRate)),
                    sourceFile: "EVASimulate"
                ))
            }
            for (index, beat) in bcg.trueBeatSeconds.enumerated() {
                events.append(MFFEvent(
                    id: "sim-qrst-\(index)",
                    code: "QRSt",
                    label: "True beat",
                    eventDescription: "Ground-truth beat time; the artifact was injected here",
                    beginTimeSeconds: writableEventTime(beat, samplingRate: config.samplingRate),
                    rawBeginTime: String(format: "%.6f", writableEventTime(beat, samplingRate: config.samplingRate)),
                    sourceFile: "EVASimulate"
                ))
            }
        }

        if let ocular {
            for (index, time) in ocular.blinkSeconds.enumerated() {
                let aligned = writableEventTime(time, samplingRate: config.samplingRate)
                events.append(MFFEvent(
                    id: "sim-blink-\(index)",
                    code: "blnk",
                    label: "Blink",
                    beginTimeSeconds: aligned,
                    rawBeginTime: String(format: "%.6f", aligned),
                    sourceFile: "EVASimulate",
                    durationSeconds: config.blinkDurationSeconds
                ))
            }
            for (index, time) in ocular.saccadeSeconds.enumerated() {
                let aligned = writableEventTime(time, samplingRate: config.samplingRate)
                events.append(MFFEvent(
                    id: "sim-saccade-\(index)",
                    code: "eyem",
                    label: "Eye movement",
                    beginTimeSeconds: aligned,
                    rawBeginTime: String(format: "%.6f", aligned),
                    sourceFile: "EVASimulate",
                    durationSeconds: config.saccadeTransitionSeconds
                ))
            }
        }

        if let emg {
            for burst in emg.bursts {
                let aligned = writableEventTime(burst.onsetSeconds, samplingRate: config.samplingRate)
                events.append(MFFEvent(
                    id: "sim-\(burst.id)",
                    code: "emg",
                    label: "Muscle burst",
                    eventDescription: "Simulated \(burst.muscle.rawValue) EMG burst",
                    beginTimeSeconds: aligned,
                    rawBeginTime: String(format: "%.6f", aligned),
                    sourceFile: "EVASimulate",
                    durationSeconds: burst.durationSeconds
                ))
            }
        }

        if let additional {
            let episodeGroups: [([ArtifactEpisodeTruth], String, String)] = [
                (additional.chewingEpisodes, "chew", "Chewing episode"),
                (additional.swallowingEpisodes, "swal", "Swallow"),
                (additional.cableMovementEpisodes, "move", "Cable movement"),
                (additional.sweatEpisodes, "swet", "Sweat drift")
            ]
            for (episodes, code, label) in episodeGroups {
                for episode in episodes {
                    let aligned = writableEventTime(episode.onsetSeconds, samplingRate: config.samplingRate)
                    events.append(MFFEvent(
                        id: "sim-\(episode.id)", code: code, label: label,
                        eventDescription: "Simulated \(episode.kind) artifact",
                        beginTimeSeconds: aligned,
                        rawBeginTime: String(format: "%.6f", aligned),
                        sourceFile: "EVASimulate",
                        durationSeconds: episode.durationSeconds
                    ))
                }
            }
        }

        if let erp {
            for trial in erp.trials {
                let aligned = writableEventTime(trial.onsetSeconds, samplingRate: config.samplingRate)
                events.append(MFFEvent(
                    id: "sim-\(trial.id)",
                    code: trial.eventCode,
                    label: trial.condition,
                    eventDescription: trial.omitted
                        ? "Stimulus presented; neural response deliberately omitted"
                        : "Simulated \(trial.condition) ERP trial",
                    beginTimeSeconds: aligned,
                    rawBeginTime: String(format: "%.6f", aligned),
                    sourceFile: "EVASimulate"
                ))
            }
        }

        return events.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
    }

    static func pnsSignal(
        ecg: [Double]?,
        motion: [Double]?,
        veog: [Double]?,
        heog: [Double]?,
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
        // The EOG pair goes out as PNS rather than as extra EEG channels
        // because that is where a real recording puts it, and because it keeps
        // the EEG channel count equal to the montage — which the layout files,
        // and everything that reads them, depend on.
        if let veog {
            channels.append(veog)
            names.append("VEOG")
        }
        if let heog {
            channels.append(heog)
            names.append("HEOG")
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
