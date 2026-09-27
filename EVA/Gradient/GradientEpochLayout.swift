//
//  GradientEpochLayout.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Independent implementation written from EVA's own functional specification
//  (docs/provenance/fastr-functional-spec.md) under the clean-room process
//  described in docs/provenance/README.md. No third-party artifact-correction source
//  was consulted.
//
//  Turns scanner volume triggers into the fixed-length artifact epochs that the
//  template corrector operates on: optionally subdividing each volume interval
//  into acquisition groups, moving onto the internally upsampled sample axis,
//  and deriving a nominal artifact period from the median trigger spacing.
//

import Foundation

/// The artifact-epoch grid derived from a recording's volume triggers.
///
/// All sample indices are on the **upsampled** axis — i.e. already multiplied by
/// the configured upsample factor.
nonisolated struct GradientEpochLayout: Sendable {
    /// A trigger interval longer than this multiple of the median is treated as
    /// one or more missing markers. Shared with `GradientCoverage`.
    static let missingTriggerGapFactor = 1.5

    /// Epoch trigger positions, ascending, on the upsampled sample axis.
    let triggers: [Int]
    /// Volume index each epoch belongs to, 0-based.
    let volumeIndex: [Int]
    /// Acquisition-group position within its volume, 0-based. The legacy
    /// `slicePosition` name is retained for diagnostic/replay compatibility.
    let slicePosition: [Int]
    /// Median spacing between adjacent epoch triggers: the nominal artifact period.
    let period: Int
    /// Samples of the epoch window that precede the trigger.
    let samplesBefore: Int
    /// Samples of the epoch window that follow the trigger.
    let samplesAfter: Int
    /// Acquisition groups per volume. The legacy name is retained internally.
    let slicesPerVolume: Int
    /// Number of distinct volumes represented.
    let volumeCount: Int
    /// Total samples on the upsampled axis.
    let upsampledSampleCount: Int

    /// Window length, including the trigger sample itself.
    var length: Int { samplesBefore + samplesAfter + 1 }
    var count: Int { triggers.count }

    /// Epoch index for a given (volume, acquisition-group position), or nil when that
    /// combination fell outside the recording and no epoch was created.
    private let epochByVolumeAndSlice: [Int: Int]

    func epochIndex(volume: Int, slicePosition slice: Int) -> Int? {
        epochByVolumeAndSlice[volume * slicesPerVolume + slice]
    }

    /// First sample of epoch `index`'s window once `shift` is applied, or nil
    /// when the shifted window would fall outside the recording.
    func windowStart(of index: Int, shift: Int = 0) -> Int? {
        let start = triggers[index] + shift - samplesBefore
        guard start >= 0, start + length <= upsampledSampleCount else { return nil }
        return start
    }

    /// Whether some epoch's unshifted window runs past the recording by exactly
    /// one sample.
    ///
    /// A window includes the trigger at each end, so its closing sample is the
    /// next epoch's trigger. After the final volume there is no next epoch, and a
    /// recording that stops one period after the last trigger — a scan recorded
    /// with no tail — never contains that sample.
    var lacksOnlyClosingSample: Bool {
        (0..<count).contains { index in
            let start = triggers[index] - samplesBefore
            return start >= 0 && start + length == upsampledSampleCount + 1
        }
    }

    /// The same epoch grid over a recording `samples` longer, at the original
    /// sampling rate. Only which windows fit changes; triggers, period, and
    /// window geometry do not.
    func extended(bySamples samples: Int, upsampleFactor: Int) -> GradientEpochLayout {
        GradientEpochLayout(
            triggers: triggers,
            volumeIndex: volumeIndex,
            slicePosition: slicePosition,
            period: period,
            samplesBefore: samplesBefore,
            samplesAfter: samplesAfter,
            slicesPerVolume: slicesPerVolume,
            volumeCount: volumeCount,
            upsampledSampleCount: upsampledSampleCount + samples * max(1, upsampleFactor),
            epochByVolumeAndSlice: epochByVolumeAndSlice
        )
    }

    /// Builds the epoch grid.
    ///
    /// - Volume triggers are sorted, de-duplicated, and clipped to the recording.
    /// - Fewer than two usable triggers is an error: no artifact period can be
    ///   established.
    /// - With `slicesPerVolume > 1`, each volume interval is divided into that
    ///   many equal acquisition groups. The final volume has no successor, so it reuses the
    ///   preceding interval; slice triggers past the end of the recording are
    ///   dropped rather than clamped.
    static func build(
        volumeTriggers: [Int],
        sampleCount: Int,
        slicesPerVolume: Int,
        upsampleFactor: Int,
        relativeTriggerPosition: Double
    ) throws -> GradientEpochLayout {
        try build(
            volumeTriggers: volumeTriggers,
            sampleCount: sampleCount,
            acquisitionSchedule: .uniform(groupsPerVolume: slicesPerVolume),
            samplingRate: 1,
            upsampleFactor: upsampleFactor,
            relativeTriggerPosition: relativeTriggerPosition
        )
    }

    /// Builds an epoch grid from a normalized acquisition-group schedule.
    ///
    /// Positions are rounded only after they have been projected onto the
    /// internally upsampled grid. This matters for slice/group periods that are
    /// fractional at the recording's native sampling rate: rounding first and
    /// multiplying afterwards discards exactly the timing resolution that
    /// upsampling was meant to provide.
    static func build(
        volumeTriggers: [Int],
        sampleCount: Int,
        acquisitionSchedule: GradientAcquisitionSchedule,
        samplingRate: Double,
        upsampleFactor: Int,
        relativeTriggerPosition: Double
    ) throws -> GradientEpochLayout {
        let slices = acquisitionSchedule.groupsPerVolume
        guard slices >= 1 else {
            throw GradientCorrectionError.invalidConfiguration("acquisition schedule must contain at least one group")
        }
        guard samplingRate.isFinite, samplingRate > 0 else {
            throw GradientCorrectionError.invalidConfiguration("samplingRate must be positive")
        }
        switch acquisitionSchedule {
        case .uniform:
            break
        case .offsetsFractionOfTR(let offsets):
            guard offsets.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 1 }),
                  zip(offsets, offsets.dropFirst()).allSatisfy({ $0 < $1 }) else {
                throw GradientCorrectionError.invalidConfiguration(
                    "fractional acquisition offsets must be finite, strictly increasing, and in [0, 1)"
                )
            }
        case .offsetsSeconds(let offsets):
            guard offsets.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  zip(offsets, offsets.dropFirst()).allSatisfy({ $0 < $1 }) else {
                throw GradientCorrectionError.invalidConfiguration(
                    "acquisition offsets in seconds must be finite, non-negative, and strictly increasing"
                )
            }
        }
        let factor = max(1, upsampleFactor)

        let volumes = Array(Set(volumeTriggers.filter { $0 >= 0 && $0 < sampleCount })).sorted()
        guard volumes.count >= 2 else {
            throw GradientCorrectionError.insufficientTriggers(volumes.count)
        }

        var triggers: [Int] = []
        var volumeIndex: [Int] = []
        var slicePosition: [Int] = []
        var lookup: [Int: Int] = [:]
        triggers.reserveCapacity(volumes.count * slices)

        // A gap much longer than the typical TR is a missing marker, not a long
        // volume: the scanner does not change its TR mid-run. Subdividing the
        // gap would place every slice of that volume at the wrong spacing, so
        // such a volume is sliced on the median TR instead and the TRs whose
        // markers are missing are left uncovered (and reported as such — see
        // `GradientCoverage.missingTriggerGaps`). ROADMAP MRI-1, 2026-09-26.
        let volumeIntervals = zip(volumes, volumes.dropFirst()).map { $1 - $0 }.sorted()
        let typicalInterval = volumeIntervals[volumeIntervals.count / 2]
        func sliced(_ interval: Int) -> Int {
            Double(interval) > Self.missingTriggerGapFactor * Double(typicalInterval) ? typicalInterval : interval
        }
        var previousInterval = sliced(volumes[1] - volumes[0])
        for v in volumes.indices {
            let interval = v + 1 < volumes.count ? sliced(volumes[v + 1] - volumes[v]) : previousInterval
            if v + 1 < volumes.count { previousInterval = interval }
            guard interval > 0 else { continue }

            let offsets: [Double]
            switch acquisitionSchedule {
            case .uniform:
                offsets = (0..<slices).map { Double($0) * Double(interval) / Double(slices) }
            case .offsetsFractionOfTR(let fractions):
                offsets = fractions.map { $0 * Double(interval) }
            case .offsetsSeconds(let seconds):
                offsets = seconds.map { $0 * samplingRate }
                guard offsets.last.map({ $0 < Double(interval) }) ?? false else {
                    throw GradientCorrectionError.invalidConfiguration(
                        "acquisition offsets must fall before the next volume trigger"
                    )
                }
            }

            for (slice, offset) in offsets.enumerated() {
                let position = Int(
                    (Double(volumes[v]) * Double(factor) + offset * Double(factor)).rounded()
                )
                guard position < sampleCount * factor else { continue }
                lookup[v * slices + slice] = triggers.count
                triggers.append(position)
                volumeIndex.append(v)
                slicePosition.append(slice)
            }
        }

        guard triggers.count >= 2 else {
            throw GradientCorrectionError.insufficientTriggers(triggers.count)
        }

        // Nominal artifact period: the median spacing between adjacent epoch
        // triggers. The median rather than the mean so that one irregular gap
        // (a dropped trigger, a paused sequence) does not distort the window.
        var spacings: [Int] = []
        spacings.reserveCapacity(triggers.count - 1)
        for i in 1..<triggers.count { spacings.append(triggers[i] - triggers[i - 1]) }
        guard spacings.allSatisfy({ $0 > 0 }) else {
            throw GradientCorrectionError.degenerateEpochGeometry
        }
        spacings.sort()
        let period = spacings[spacings.count / 2]
        guard period >= 2 else { throw GradientCorrectionError.degenerateEpochGeometry }

        let fraction = min(max(relativeTriggerPosition, 0), 1)
        let before = Int((Double(period) * fraction).rounded())
        let after = Int((Double(period) * (1 - fraction)).rounded())

        return GradientEpochLayout(
            triggers: triggers,
            volumeIndex: volumeIndex,
            slicePosition: slicePosition,
            period: period,
            samplesBefore: before,
            samplesAfter: after,
            slicesPerVolume: slices,
            volumeCount: volumes.count,
            upsampledSampleCount: sampleCount * factor,
            epochByVolumeAndSlice: lookup
        )
    }
}
