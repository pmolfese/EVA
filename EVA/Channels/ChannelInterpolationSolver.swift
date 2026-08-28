//
//  ChannelInterpolationSolver.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  One implementation of "repair this channel from its neighbours", shared by
//  the interactive click, headless replay, batch, and history re-derivation.
//
//  ## Why it is one function
//
//  ROADMAP RW-1 item 3 asks for interactive/replay/re-derivation *parity* on
//  channel decisions, and item 4 asks for that parity to be shown by byte
//  comparison. Two implementations of a spherical-spline solve cannot be made
//  byte-identical by inspection — they have to be the same arithmetic in the
//  same order. `WaveformView.interpolate` used to own the only copy; every other
//  path either skipped interpolation (`ProcessingCore` had no case for it, which
//  is why re-derivation refused any path containing one) or had to invent its
//  own. This is that copy, lifted out and made callable without a view.
//
//  ## Why re-solving is enough — no sidecar
//
//  The weights are a pure function of two things the package already carries:
//  the electrode positions, and which channels were good at the time. The good
//  set is recoverable from `eva.xml` itself — `markBad` records the bad list and
//  `interpolateChannels` records the repaired list, and a channel being repaired
//  disqualifies it as a donor. So the recipe re-solves deterministically, and
//  persisting replacement *samples* would only add a large sidecar that goes
//  stale the moment anything upstream is re-run (RW-1 item 3, settled
//  2026-08-26).
//
//  The samples themselves are deliberately not the persistent artifact anywhere
//  in EVA: `ChannelInterpolationSnapshot` re-derives them from the recipe
//  against whatever signal is currently at the end of the pipeline, so filtering
//  or cleaning applied later cannot leave a repaired channel showing pre-filter
//  data.
//
//  ## Failure is a value, not a message
//
//  A solve can fail for reasons that are not bugs — a package with no electrode
//  geometry, a montage missing that electrode's coordinates, a degenerate donor
//  set. Item 3 requires that such a failure *never* leaves stale replacement
//  samples active: the channel goes back to bad and the loss is recorded. That
//  is only enforceable if the failure reaches the caller as a value it must
//  handle, so `solve` returns a `Result` and the reasons are enumerated.
//

import Accelerate
import Foundation

nonisolated enum ChannelInterpolationSolver {

    /// A solved repair: the donor recipe (persistent) and the replacement
    /// samples it produces against the signal that was passed in (a cache —
    /// see `ChannelInterpolationSnapshot`).
    struct Solution: Equatable, Sendable {
        var indices: [Int]
        var weights: [Float]
        var replacement: [Float]
    }

    /// Why a repair could not be produced. Every case is a state a real package
    /// can be in, not an internal error.
    enum Failure: Error, Equatable, Sendable {
        /// The channel number is not in this recording.
        case channelOutOfRange(Int)
        /// No 3D coordinates for this electrode (or none for the montage at all).
        case noElectrodeGeometry(Int)
        /// Fewer than three usable donors, or a singular system.
        case cannotSolve(Int)

        /// Operator-facing sentence, in the same voice as the interactive status
        /// line — these strings reach the channel row, the status history, and
        /// the processing audit log.
        var message: String {
            switch self {
            case .channelOutOfRange(let index):
                return "Ch \(index + 1) is not in this recording."
            case .noElectrodeGeometry(let index):
                return "No 3D coordinates for Ch \(index + 1); can't interpolate."
            case .cannotSolve(let index):
                return "Couldn't compute interpolation weights for Ch \(index + 1)."
            }
        }
    }

    /// Repairs `target` from the good channels of `signal`.
    ///
    /// `bad` and `alreadyInterpolated` are the ambient channel state: neither a
    /// channel judged unusable nor one that is itself a repair may donate, since
    /// a repaired channel carries no independent information about the scalp.
    /// The target is excluded from its own donor set.
    static func solve(
        target: Int,
        in signal: MFFSignalData,
        bad: Set<Int>,
        alreadyInterpolated: Set<Int>,
        positions: [Int: SIMD3<Double>]
    ) -> Result<Solution, Failure> {
        guard signal.data.indices.contains(target) else {
            return .failure(.channelOutOfRange(target))
        }
        guard positions[target] != nil else {
            return .failure(.noElectrodeGeometry(target))
        }

        let good = signal.data.indices.filter {
            $0 != target
                && !bad.contains($0)
                && !alreadyInterpolated.contains($0)
                && positions[$0] != nil
        }

        guard let (indices, weights) = SphericalSpline.interpolationWeights(
            target: target,
            good: good,
            positions: positions
        ) else {
            return .failure(.cannotSolve(target))
        }

        let length = signal.data[target].count
        var series = [Float](repeating: 0, count: length)
        for (channelIndex, weight) in zip(indices, weights) {
            let source = signal.data[channelIndex]
            guard source.count == length else { continue }
            // series += Float(weight) * source
            vDSP.add(multiplication: (source, Float(weight)), series, result: &series)
        }

        return .success(Solution(
            indices: indices,
            weights: weights.map(Float.init),
            replacement: series
        ))
    }
}
