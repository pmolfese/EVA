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

extension SimulationConfig {

    /// Turns `badChannelCount` and `highImpedanceChannelCount` into explicit
    /// channel numbers, so everything downstream — the defect injector, the
    /// impedance model, the truth sidecar — sees one authored list and cannot
    /// disagree about which electrodes were picked.
    ///
    /// Call once, after the configuration is otherwise final and before any
    /// generation reads `badChannels`. It is idempotent only in the sense that
    /// the counts are consumed: calling it twice would spoil twice as many
    /// channels, which is why generation calls it in exactly one place.
    ///
    /// Selection is a seeded shuffle of the channels that are not already
    /// spoken for, drawn from its own random stream. Bad and high-impedance
    /// channels come out of the same shuffled pool, so they are guaranteed
    /// disjoint — a channel cannot be simultaneously "broken" and "the clean
    /// one that merely reads poorly", which is the whole distinction being
    /// modelled.
    mutating func resolveChannelSelectionCounts(montage: Montage?) {
        let wantedBad = max(0, badChannelCount ?? 0)
        let wantedHighImpedance = max(0, highImpedanceChannelCount ?? 0)
        guard wantedBad > 0 || wantedHighImpedance > 0, channelCount > 0 else { return }

        // Explicitly named channels keep what they were given and stay out of
        // the draw. A count asks for that many *more*, not for a total.
        var alreadyHighImpedance = effectiveHighImpedanceChannels
        var available = (1...channelCount).filter {
            badChannels[$0] == nil && !alreadyHighImpedance.contains($0)
        }

        // Which electrodes count as periocular is decided by the montage's own
        // blink topography rather than by matching names against a list of
        // 10-20 labels. That is the same weighting the blink injector uses, so
        // "the electrodes an eye detector reads" and "the electrodes a blink
        // actually lands on" are guaranteed to be the same set — and it works
        // on an imported 256-channel net, where no name list would.
        let periocular = Set(Self.periocularChannels(montage: montage, channelCount: channelCount))
        var badPool: [Int]
        switch effectiveBadChannelPlacement {
        case .anywhere:
            badPool = available
        case .periocular:
            badPool = available.filter { periocular.contains($0) }
        case .avoidPeriocular:
            badPool = available.filter { !periocular.contains($0) }
        }

        var source = GaussianSource(seed: SimulationSeedStreams.channelSelection(base: seed))
        Self.shuffle(&badPool, source: &source)

        let kinds = ChannelDefect.allCases
        let badEnd = min(wantedBad, badPool.count)
        for offset in 0..<badEnd {
            // Cycling rather than drawing: asking for five bad channels with no
            // kind pinned gives one of each failure mode, which is the request
            // people actually mean.
            badChannels[badPool[offset]] = badChannelDefect ?? kinds[offset % kinds.count]
        }

        // High-impedance channels are drawn from whatever the bad draw left, so
        // the two sets stay disjoint under every placement.
        let spoiled = Set(badPool.prefix(badEnd))
        available.removeAll { spoiled.contains($0) }
        Self.shuffle(&available, source: &source)
        let impedanceEnd = min(wantedHighImpedance, available.count)
        if impedanceEnd > 0 {
            alreadyHighImpedance.append(contentsOf: available.prefix(impedanceEnd))
            alreadyHighImpedance.sort()
            highImpedanceChannels = alreadyHighImpedance
        }
    }

    /// Electrodes that see enough blink to be what an eye-artifact detector
    /// reads: at least half the peak blink weight. On a 10-20 montage that is
    /// Fp1/Fp2 and their immediate neighbours.
    ///
    /// Falls back to the first few channels when there is no montage, which is
    /// the same fallback EVA's own detector uses when a layout is unrecognized.
    static func periocularChannels(montage: Montage?, channelCount: Int) -> [Int] {
        guard let montage, !montage.electrodes.isEmpty else {
            return Array(1...min(channelCount, 4))
        }
        let weights = OcularArtifactModel.blinkTopography(positions: montage.positions)
        let peak = weights.map(abs).max() ?? 0
        guard peak > 0 else { return Array(1...min(channelCount, 4)) }
        let selected = weights.indices
            .filter { weights[$0] >= 0.5 * peak && $0 < channelCount }
            .map { $0 + 1 }
        // A montage with no clearly frontal electrode still has a *most* frontal
        // one, and silently selecting nothing would turn `--bad-channel-placement
        // periocular` into a no-op rather than an error.
        if selected.isEmpty, let best = weights.indices.max(by: { weights[$0] < weights[$1] }) {
            return [best + 1]
        }
        return selected
    }

    private static func shuffle(_ values: inout [Int], source: inout GaussianSource) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, to: 0, by: -1) {
            let draw = Int(source.uniform() * Double(index + 1))
            values.swapAt(index, min(max(draw, 0), index))
        }
    }
}

nonisolated enum ChannelDefectModel {

    /// Applies each requested defect in place. `badChannels` is keyed by 1-based
    /// channel number, matching how channels are labelled in the UI rather than
    /// how they are indexed in the array — an off-by-one here would silently
    /// wreck the wrong electrode.
    static func apply(
        to channels: inout [[Double]],
        config: SimulationConfig,
        impedances: [Float]? = nil,
        source: inout GaussianSource
    ) -> [String: String] {
        var applied: [String: String] = [:]

        for (number, defect) in config.badChannels.sorted(by: { $0.key < $1.key }) {
            let index = number - 1
            guard index >= 0, index < channels.count else { continue }
            let impedance = impedances.flatMap { index < $0.count ? Double($0[index]) : nil }
            applied["\(number)"] = spoil(
                &channels[index], defect: defect, config: config,
                impedanceKOhm: impedance, source: &source
            )
        }
        return applied
    }

    /// Applies the same defects to the dedicated EOG traces, which are separate
    /// physical electrodes from the EEG montage and fail separately.
    ///
    /// Worth having because it breaks a *different* thing. A spoiled periocular
    /// EEG electrode defeats threshold-based blink detection; a spoiled VEOG or
    /// HEOG defeats regression-based ocular correction, which cannot tell a dead
    /// reference from an eye that never moved and will happily subtract nothing
    /// while reporting success.
    static func applyToEOG(
        veog: inout [Double],
        heog: inout [Double],
        config: SimulationConfig,
        source: inout GaussianSource
    ) -> [String: String] {
        var applied: [String: String] = [:]
        for channel in EOGChannel.allCases {
            guard let defect = config.effectiveEOGDefects[channel] else { continue }
            switch channel {
            case .veog:
                applied[channel.label] = spoil(
                    &veog, defect: defect, config: config, impedanceKOhm: nil, source: &source
                )
            case .heog:
                applied[channel.label] = spoil(
                    &heog, defect: defect, config: config, impedanceKOhm: nil, source: &source
                )
            }
        }
        return applied
    }

    /// One channel's defect, in place. Returns what was actually applied, which
    /// is not always what was asked for — see `.line`.
    private static func spoil(
        _ samples: inout [Double],
        defect: ChannelDefect,
        config: SimulationConfig,
        impedanceKOhm: Double?,
        source: inout GaussianSource
    ) -> String {
        let eegScale = config.eegTargetStdMicrovolts

        switch defect {
        case .flat:
            // Not exactly zero: a truly dead line still carries amplifier
            // noise, and a channel of literal zeros is easier to detect than
            // anything real.
            for i in samples.indices {
                samples[i] = 0.4 * source.gaussian()
            }

        case .noisy:
            let amplitude = 8 * eegScale
            for i in samples.indices {
                samples[i] += amplitude * source.gaussian()
            }

        case .drift:
            // A random walk, low-passed by construction, plus a slow sine so
            // the drift is visible at a glance rather than only in the stats.
            var walk = 0.0
            let step = 0.6 * eegScale / config.samplingRate.squareRoot()
            for i in samples.indices {
                walk += step * source.gaussian()
                let t = Double(i) / config.samplingRate
                samples[i] += walk + 12 * eegScale * sin(2 * Double.pi * 0.05 * t)
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
                while start + offset < samples.count, Double(offset) < 4 * decay {
                    samples[start + offset] += amplitude * exp(-Double(offset) / decay)
                    offset += 1
                }
                t += 3 + 4 * source.uniform()
            }

        case .line:
            guard config.lineNoiseHz > 0 else {
                // Asking for mains pickup on a channel while modelling no
                // mains at all is a contradiction worth surfacing rather
                // than silently producing a clean channel.
                return "line (inactive — needs --line-noise)"
            }
            let scale = impedanceKOhm
                .map { ImpedanceModel.lineNoiseScale(impedanceKOhm: $0, config: config) } ?? 1
            let amplitude = 12 * config.lineNoiseAmplitudeMicrovolts * scale
            for i in samples.indices {
                let t = Double(i) / config.samplingRate
                samples[i] += amplitude * sin(2 * Double.pi * config.lineNoiseHz * t)
            }
        }
        return defect.rawValue
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
        impedances: [Float]? = nil,
        source: inout GaussianSource
    ) -> [Double] {
        var gains = [Double](repeating: 0, count: channels.count)
        guard config.lineNoiseHz > 0, config.lineNoiseAmplitudeMicrovolts > 0 else { return gains }

        for channel in channels.indices {
            // Each electrode picks up its own amount, as lead dress and
            // impedance vary around the head.
            let contactScale = impedances.flatMap {
                channel < $0.count ? Double($0[channel]) : nil
            }.map {
                ImpedanceModel.lineNoiseScale(impedanceKOhm: $0, config: config)
            } ?? 1
            // Lead dress still matters, but impedance is the dominant source of
            // between-channel variation when coupling is enabled.
            let dress = config.impedanceNoise == nil
                ? (0.6 + 0.8 * source.uniform())
                : (0.9 + 0.2 * source.uniform())
            let gain = config.lineNoiseAmplitudeMicrovolts * contactScale * dress
            gains[channel] = gain
            let phase = 2 * Double.pi * source.uniform()
            for i in channels[channel].indices {
                let t = Double(i) / config.samplingRate
                let wander = 1 + 0.25 * sin(2 * Double.pi * 0.037 * t + phase)
                channels[channel][i] += gain * wander * sin(2 * Double.pi * config.lineNoiseHz * t + phase)
                    + 0.25 * gain * sin(2 * Double.pi * 3 * config.lineNoiseHz * t + phase)
            }
        }
        return gains
    }
}
