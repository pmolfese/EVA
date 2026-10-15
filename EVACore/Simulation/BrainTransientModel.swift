//
//  BrainTransientModel.swift
//  EVACore
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Genuine sharp *brain* transients — K-complexes, sleep spindles, sharp waves —
//  added to the clean EEG, not to the artifact layer. They exist so a cleaner's
//  oversmoothing can be measured: a wavelet reducer that thresholds transient
//  coefficients will happily delete a real K-complex, and the only way to catch
//  that is to seed brain features it must NOT remove and check whether they
//  survived (`score-preservation`). Truth carries each event's time, type,
//  duration, amplitude and strongest channel.
//
//  Central-maximal topography (vertex-weighted), which is where K-complexes and
//  spindles are largest. Off by default (Optional, nil), so scenarios that omit
//  it are byte-identical to the paper model.
//

import Foundation

nonisolated struct BrainTransientConfig: Codable, Sendable, Equatable {
    /// Events per minute (across all enabled types, round-robin).
    var ratePerMinute: Double = 6
    /// Peak amplitude at the strongest channel. K-complexes are large (100–300 µV).
    var amplitudeMicrovolts: Double = 150
    var includeKComplex: Bool = true
    var includeSpindle: Bool = true
    var includeSharpWave: Bool = true

    static let `default` = BrainTransientConfig()

    var enabledTypes: [BrainTransientKind] {
        var types: [BrainTransientKind] = []
        if includeKComplex { types.append(.kComplex) }
        if includeSpindle { types.append(.spindle) }
        if includeSharpWave { types.append(.sharpWave) }
        return types
    }
}

nonisolated enum BrainTransientKind: String, Codable, Sendable, CaseIterable {
    case kComplex
    case spindle
    case sharpWave

    /// Total duration of the event's waveform, in seconds.
    var durationSeconds: Double {
        switch self {
        case .kComplex: return 0.6
        case .spindle: return 0.8
        case .sharpWave: return 0.12
        }
    }

    /// Amplitude relative to the configured reference (a K-complex). Real spindles
    /// are far smaller than K-complexes; sharp waves sit in between. Keeps the
    /// per-type sizes physiological rather than all equal.
    var relativeAmplitude: Double {
        switch self {
        case .kComplex: return 1.0
        case .spindle: return 0.17
        case .sharpWave: return 0.55
        }
    }

    /// Unit-peak waveform sampled over `[0, durationSeconds]`.
    func waveform(sampleCount: Int, samplingRate: Double) -> [Double] {
        guard sampleCount > 0 else { return [] }
        var values = [Double](repeating: 0, count: sampleCount)
        for index in 0..<sampleCount {
            let t = Double(index) / samplingRate
            switch self {
            case .kComplex:
                // Sharp negative trough near 120 ms, slower positive rebound.
                values[index] = -exp(-pow((t - 0.12) / 0.045, 2)) + 0.6 * exp(-pow((t - 0.38) / 0.13, 2))
            case .spindle:
                // 13 Hz waxing–waning burst under a Gaussian envelope.
                values[index] = sin(2 * .pi * 13 * t) * exp(-pow((t - 0.4) / 0.22, 2))
            case .sharpWave:
                // A brief, sharp deflection — the hardest thing to preserve.
                values[index] = -exp(-pow((t - 0.05) / 0.014, 2))
            }
        }
        // Normalize to unit peak so the amplitude knob means microvolts.
        let peak = values.map(abs).max() ?? 0
        if peak > 1e-12 { for index in values.indices { values[index] /= peak } }
        return values
    }
}

nonisolated struct BrainTransientTruth: Codable, Sendable {
    var type: String
    var onsetSeconds: Double
    var durationSeconds: Double
    var peakAmplitudeMicrovolts: Double
    var strongestChannel: Int
}

nonisolated struct BrainTransientInjection: Sendable {
    var episodes: [BrainTransientTruth]
    /// Central-maximal, peak-normalized weight per channel.
    var topography: [Double]
}

nonisolated enum BrainTransientModel {

    /// Vertex-weighted topography: largest at the top of the head, falling off
    /// with arc distance from it. K-complexes and spindles are central-maximal.
    static func topography(positions: [(x: Double, y: Double, z: Double)]) -> [Double] {
        let weights = positions.map { position -> Double in
            // z near 1 is the vertex; use (1 - z) as an arc-distance proxy.
            exp(-pow((1 - position.z) / 0.6, 2))
        }
        let peak = weights.map(abs).max() ?? 0
        return peak > 1e-12 ? weights.map { $0 / peak } : weights
    }

    static func inject(
        into channels: inout [[Double]],
        config: SimulationConfig,
        montage: Montage,
        source: inout GaussianSource
    ) -> BrainTransientInjection? {
        guard let model = config.brainTransients else { return nil }
        let types = model.enabledTypes
        guard !types.isEmpty, model.ratePerMinute > 0 else { return nil }

        let samplingRate = config.samplingRate
        let sampleCount = config.sampleCount
        let weights = topography(positions: montage.positions)
        let strongest = weights.enumerated().max { abs($0.element) < abs($1.element) }?.offset ?? 0

        // Evenly spaced onsets with mild jitter, keeping a whole event in bounds.
        let interval = 60.0 / model.ratePerMinute
        var episodes: [BrainTransientTruth] = []
        var typeIndex = 0
        var time = interval
        while time < config.durationSeconds - 1 {
            let kind = types[typeIndex % types.count]
            typeIndex += 1
            let jitter = 0.15 * interval * source.gaussian()
            let onset = max(0.5, time + jitter)
            let waveformSamples = Int((kind.durationSeconds * samplingRate).rounded())
            let waveform = kind.waveform(sampleCount: waveformSamples, samplingRate: samplingRate)
            let start = Int((onset * samplingRate).rounded())
            if start >= 0, start + waveformSamples <= sampleCount {
                let peakAmplitude = model.amplitudeMicrovolts * kind.relativeAmplitude
                for channel in channels.indices {
                    let gain = peakAmplitude * weights[channel]
                    for offset in 0..<waveformSamples {
                        channels[channel][start + offset] += gain * waveform[offset]
                    }
                }
                episodes.append(BrainTransientTruth(
                    type: kind.rawValue, onsetSeconds: onset, durationSeconds: kind.durationSeconds,
                    peakAmplitudeMicrovolts: peakAmplitude, strongestChannel: strongest))
            }
            time += interval
        }
        return BrainTransientInjection(episodes: episodes, topography: weights)
    }
}
