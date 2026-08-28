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
//  into equal slice intervals, moving onto the internally upsampled sample axis,
//  and deriving a nominal artifact period from the median trigger spacing.
//

import Foundation

/// The artifact-epoch grid derived from a recording's volume triggers.
///
/// All sample indices are on the **upsampled** axis — i.e. already multiplied by
/// the configured upsample factor.
nonisolated struct GradientEpochLayout: Sendable {
    /// Epoch trigger positions, ascending, on the upsampled sample axis.
    let triggers: [Int]
    /// Volume index each epoch belongs to, 0-based.
    let volumeIndex: [Int]
    /// Slice position of each epoch within its volume, 0-based.
    let slicePosition: [Int]
    /// Median spacing between adjacent epoch triggers: the nominal artifact period.
    let period: Int
    /// Samples of the epoch window that precede the trigger.
    let samplesBefore: Int
    /// Samples of the epoch window that follow the trigger.
    let samplesAfter: Int
    /// Slices per volume this layout was built with.
    let slicesPerVolume: Int
    /// Number of distinct volumes represented.
    let volumeCount: Int
    /// Total samples on the upsampled axis.
    let upsampledSampleCount: Int

    /// Window length, including the trigger sample itself.
    var length: Int { samplesBefore + samplesAfter + 1 }
    var count: Int { triggers.count }

    /// Epoch index for a given (volume, slice position), or nil when that
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

    /// Builds the epoch grid.
    ///
    /// - Volume triggers are sorted, de-duplicated, and clipped to the recording.
    /// - Fewer than two usable triggers is an error: no artifact period can be
    ///   established.
    /// - With `slicesPerVolume > 1`, each volume interval is divided into that
    ///   many equal parts. The final volume has no successor, so it reuses the
    ///   preceding interval; slice triggers past the end of the recording are
    ///   dropped rather than clamped.
    static func build(
        volumeTriggers: [Int],
        sampleCount: Int,
        slicesPerVolume: Int,
        upsampleFactor: Int,
        relativeTriggerPosition: Double
    ) throws -> GradientEpochLayout {
        let slices = max(1, slicesPerVolume)
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

        var previousInterval = volumes[1] - volumes[0]
        for v in volumes.indices {
            let interval = v + 1 < volumes.count ? volumes[v + 1] - volumes[v] : previousInterval
            if v + 1 < volumes.count { previousInterval = interval }
            guard interval > 0 else { continue }

            for slice in 0..<slices {
                let offset = (Double(slice) * Double(interval) / Double(slices)).rounded()
                let position = volumes[v] + Int(offset)
                guard position < sampleCount else { continue }
                lookup[v * slices + slice] = triggers.count
                triggers.append(position * factor)
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
