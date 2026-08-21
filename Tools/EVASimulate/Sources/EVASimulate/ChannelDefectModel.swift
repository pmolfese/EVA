//
//  ChannelDefectModel.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Bad channels and mains noise — recording defects rather than physiology.
//
//  Both are applied to the contaminated recording only, never to the ground
//  truth. That is the honest arrangement: a dead electrode is not part of the
//  brain signal you were trying to measure, so a correction that fails to
//  recover it *should* score badly on that channel. It also means a scoring run
//  on a file with a flat channel will show one channel dragging the average
//  down, which is correct and worth knowing about rather than hiding.
//
//  The defects are chosen to defeat different naive analyses, since that is what
//  makes them useful to teach with: a flat channel breaks anything that
//  normalizes per channel, a drifting one sails through a notch filter and
//  breaks amplitude thresholds, a popping one breaks epoch rejection, and a
//  single line-contaminated channel makes the point that filtering decisions are
//  per channel rather than per recording.
//

import Foundation

nonisolated enum ChannelDefectModel {

    /// Applies each requested defect in place. `badChannels` is keyed by 1-based
    /// channel number, matching how channels are labelled in the UI rather than
    /// how they are indexed in the array — an off-by-one here would silently
    /// wreck the wrong electrode.
    static func apply(
        to channels: inout [[Double]],
        config: SimulationConfig,
        source: inout GaussianSource
    ) -> [String: String] {
        var applied: [String: String] = [:]
        let eegScale = config.eegTargetStdMicrovolts

        for (number, defect) in config.badChannels.sorted(by: { $0.key < $1.key }) {
            let index = number - 1
            guard index >= 0, index < channels.count else { continue }
            applied["\(number)"] = defect.rawValue

            switch defect {
            case .flat:
                // Not exactly zero: a truly dead line still carries amplifier
                // noise, and a channel of literal zeros is easier to detect than
                // anything real.
                for i in channels[index].indices {
                    channels[index][i] = 0.4 * source.gaussian()
                }

            case .noisy:
                let amplitude = 8 * eegScale
                for i in channels[index].indices {
                    channels[index][i] += amplitude * source.gaussian()
                }

            case .drift:
                // A random walk, low-passed by construction, plus a slow sine so
                // the drift is visible at a glance rather than only in the stats.
                var walk = 0.0
                let step = 0.6 * eegScale / config.samplingRate.squareRoot()
                for i in channels[index].indices {
                    walk += step * source.gaussian()
                    let t = Double(i) / config.samplingRate
                    channels[index][i] += walk + 12 * eegScale * sin(2 * Double.pi * 0.05 * t)
                }

            case .pop:
                // Steps every few seconds that decay back over ~1 s, which is
                // what a momentarily lifting electrode looks like.
                var t = 2.0
                while t < config.durationSeconds {
                    let amplitude = (source.uniform() < 0.5 ? -1 : 1) * (10 + 25 * source.uniform()) * eegScale
                    let start = Int(t * config.samplingRate)
                    let decay = 0.8 * config.samplingRate
                    var offset = 0
                    while start + offset < channels[index].count, Double(offset) < 4 * decay {
                        channels[index][start + offset] += amplitude * exp(-Double(offset) / decay)
                        offset += 1
                    }
                    t += 3 + 4 * source.uniform()
                }

            case .line:
                guard config.lineNoiseHz > 0 else {
                    // Asking for mains pickup on a channel while modelling no
                    // mains at all is a contradiction worth surfacing rather
                    // than silently producing a clean channel.
                    applied["\(number)"] = "line (inactive — needs --line-noise)"
                    continue
                }
                let amplitude = 12 * config.lineNoiseAmplitudeMicrovolts
                for i in channels[index].indices {
                    let t = Double(i) / config.samplingRate
                    channels[index][i] += amplitude * sin(2 * Double.pi * config.lineNoiseHz * t)
                }
            }
        }
        return applied
    }

    /// Mains interference on every channel: the fundamental, a little third
    /// harmonic, and a slowly wandering amplitude so a fixed notch cannot
    /// perfectly cancel it.
    ///
    /// The wander matters for teaching. Perfectly stationary line noise is
    /// removed completely by an ideal notch, which would suggest the problem is
    /// easier than it is; real mains drifts in amplitude and phase, which is why
    /// adaptive approaches like CleanLine exist.
    static func applyLineNoise(
        to channels: inout [[Double]],
        config: SimulationConfig,
        source: inout GaussianSource
    ) {
        guard config.lineNoiseHz > 0, config.lineNoiseAmplitudeMicrovolts > 0 else { return }

        for channel in channels.indices {
            // Each electrode picks up its own amount, as lead dress and
            // impedance vary around the head.
            let gain = config.lineNoiseAmplitudeMicrovolts * (0.6 + 0.8 * source.uniform())
            let phase = 2 * Double.pi * source.uniform()
            for i in channels[channel].indices {
                let t = Double(i) / config.samplingRate
                let wander = 1 + 0.25 * sin(2 * Double.pi * 0.037 * t + phase)
                channels[channel][i] += gain * wander * sin(2 * Double.pi * config.lineNoiseHz * t + phase)
                    + 0.25 * gain * sin(2 * Double.pi * 3 * config.lineNoiseHz * t + phase)
            }
        }
    }
}
