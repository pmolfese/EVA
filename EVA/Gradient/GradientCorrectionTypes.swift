//
//  GradientCorrectionTypes.swift
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
//  Configuration, error, warning, and diagnostic types for the gradient-artifact
//  template corrector.
//

import Foundation

// MARK: - Donor strategy

/// How donor epochs are chosen when building an artifact template.
///
/// The scientific motivation for each strategy is described in the literature
/// cited by the functional spec (Niazy et al. 2005; Moosmann et al. 2009;
/// van der Meer et al. 2010; Glaser et al. 2013). These are cited as method
/// references only.
nonisolated enum GradientTemplateScheme: String, CaseIterable, Identifiable, Sendable {
    /// Average the epochs nearest in time to the target.
    case temporalNeighbors
    /// Prefer donors that are not separated from the target by a head-motion
    /// event, and never donate from a high-motion volume.
    case motionInformed
    /// Rank donors by Pearson correlation of artifact waveform with the target.
    case correlationRanked
    /// Rank donors by *squared* correlation, so strong anti-correlation also
    /// qualifies.
    case squaredCorrelationRanked

    var id: String { rawValue }

    var label: String {
        switch self {
        case .temporalNeighbors: return "Temporal Neighbors"
        case .motionInformed: return "Motion-Informed"
        case .correlationRanked: return "Correlation-Ranked"
        case .squaredCorrelationRanked: return "Squared-Correlation-Ranked"
        }
    }
}

/// How the donor template's amplitude is matched to the target epoch.
///
/// This is a real trade-off, not a formality. Scaling the template exists
/// because artifact amplitude genuinely changes over a scan, and because
/// templates built near the edges of a recording are biased. But the scale is
/// fitted from a single epoch-length window, and over a window that short a
/// physiological rhythm is not orthogonal to the artifact — so part of the brain
/// signal gets absorbed into the scale and subtracted along with the artifact.
///
/// EVA therefore separates the benefit from the failure mode rather than
/// choosing between them. See the "Template Scale Safety" section of the
/// functional spec.
nonisolated enum GradientTemplateScaling: String, CaseIterable, Identifiable, Sendable {
    /// Subtract the donor average as-is (`alpha = 1`). Cannot eat correlated
    /// signal; cannot follow a changing artifact amplitude either.
    case unscaled
    /// Fit a scale per epoch, then take a running median across neighbouring
    /// epochs. Amplitude changes that persist — the kind head motion and hardware
    /// drift produce — survive the median and are tracked. Epoch-to-epoch scatter,
    /// including the part contributed by brain signal, does not.
    case driftTracking
    /// Use each epoch's raw fit, `alpha = dot(target, template) / dot(template,
    /// template)`. Tracks any amplitude change immediately, including a
    /// single-epoch one, at the cost of absorbing whatever signal correlates with
    /// the template in that window.
    case leastSquares

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unscaled: return "Unscaled Average"
        case .driftTracking: return "Drift-Tracking (Smoothed Fit)"
        case .leastSquares: return "Per-Epoch Least Squares"
        }
    }
}

/// Which rigid-body terms contribute to a volume's motion magnitude.
nonisolated enum GradientMotionMetric: String, CaseIterable, Identifiable, Sendable {
    /// Translations only.
    case translationOnly
    /// Translations plus rotations, with rotations converted to arc length on a
    /// sphere of the configured radius.
    case allParameters

    var id: String { rawValue }

    var label: String {
        switch self {
        case .translationOnly: return "Translation Only"
        case .allParameters: return "All Six Parameters"
        }
    }

    var help: String {
        switch self {
        case .translationOnly:
            return "Sum the absolute volume-to-volume change in the three translation terms. Rotations are ignored, which keeps the metric in millimetres of head displacement without assuming a head radius."
        case .allParameters:
            return "Framewise displacement over all six rigid-body terms (Power et al. 2012), with rotations converted to arc length on a sphere of the configured radius. More sensitive to nodding and rolling."
        }
    }
}

/// How many optimal-basis-set components are removed from the residual.
nonisolated enum GradientOBSMode: Sendable, Equatable {
    case off
    /// Retain however many components are needed to explain
    /// `obsVarianceThreshold` of the residual variance, up to
    /// `obsMaximumComponents`.
    case automatic
    case fixed(componentCount: Int)

    var isEnabled: Bool { self != .off }
}

// MARK: - Configuration

nonisolated struct GradientCorrectionConfig: Sendable {

    // Epoch geometry

    /// Internal upsample factor. 1 disables upsampling entirely.
    var upsampleFactor: Int = 1
    /// Slices per volume. 1 means volume-level epochs.
    var numberOfSlices: Int = 1
    /// Where the trigger sits inside its artifact epoch, as a fraction of the
    /// epoch. 0 puts the whole window after the trigger.
    var relativeTriggerPosition: Double = 0

    // Donor window

    /// Donor epochs to take from before the target.
    var averagingWindowBefore: Int = 15
    /// Donor epochs to take from after the target.
    var averagingWindowAfter: Int = 15
    /// Symmetric fallback used only when both directional windows are zero.
    var averagingWindow: Int = 30

    /// Whether the target epoch may serve as its own donor. Off for every
    /// strategy by default; the spec allows squared-correlation ranking to opt in.
    var allowsSelfDonation: Bool = false

    /// How the template's amplitude is matched to the target epoch.
    var templateScaling: GradientTemplateScaling = .driftTracking
    /// Epochs the `.driftTracking` median spans. Wider rejects more scatter but
    /// takes longer to follow a real change.
    var templateScaleSmoothingEpochs: Int = 15
    /// Fitted scales outside this range are treated as failed fits rather than
    /// applied. A template that needs to be scaled by 10x to match its epoch did
    /// not describe that epoch.
    var templateScaleRange: ClosedRange<Double> = 0.2...5

    // Strategy

    var templateScheme: GradientTemplateScheme = .temporalNeighbors

    /// Minimum correlation a candidate must reach to qualify under
    /// `correlationRanked`.
    var correlationThreshold: Double = 0.9
    /// If fewer than this many candidates qualify, `correlationRanked` falls back
    /// to temporal neighbors for that epoch.
    var minimumCorrelatedDonors: Int = 4
    /// How many same-slice epochs on each side of the target are considered as
    /// correlation candidates. Bounds an otherwise quadratic search.
    var correlationSearchWindow: Int = 240

    // Alignment

    /// Whether to search for a per-epoch integer alignment shift.
    var alignmentEnabled: Bool = true
    /// Whether to additionally estimate and apply a sub-sample shift.
    var subSampleAlignment: Bool = false
    /// Alignment search radius in upsampled samples. `nil` derives a radius from
    /// the artifact period.
    var alignmentSearchRadius: Int? = nil

    // Motion

    var motion: [MotionSample]? = nil
    /// Framewise-displacement threshold, in mm, above which a volume is treated
    /// as high-motion.
    var motionThresholdMm: Double = 0.5
    var motionMetric: GradientMotionMetric = .translationOnly
    /// Sphere radius used to convert rotations to mm of arc length.
    var motionRadiusMm: Double = 50

    /// Volumes that must still be corrected but must never donate.
    var censoredVolumes: Set<Int> = []
    /// Channels passed through untouched.
    var excludedChannels: Set<Int> = []

    // OBS

    var obs: GradientOBSMode = .off
    /// Share of residual variance `.automatic` component selection must explain.
    var obsVarianceThreshold: Double = 0.9
    /// Ceiling on `.automatic` component selection.
    var obsMaximumComponents: Int = 5
    /// Length of recording each OBS basis is estimated over. The residual's shape
    /// drifts across a long scan, so one basis for the whole session fits none of
    /// it well.
    var obsChunkSeconds: Double = 60
    /// Cap on epochs contributing to one basis, to bound the eigen-decomposition.
    var obsMaximumEpochsPerChunk: Int = 256
    /// Minimum residual energy, as a fraction of the energy template subtraction
    /// already removed, for OBS to run on a chunk.
    ///
    /// OBS cannot tell structured artifact from structured brain signal — it
    /// removes whatever dominates the residual. When template subtraction has
    /// already explained nearly all of the artifact, what is left is mostly
    /// signal, and running OBS on it does nothing but delete data. This floor
    /// stops the stage where it has nothing left to find.
    var obsResidualEnergyFloor: Double = 0.01
    /// Channels that skip the OBS stage but still receive template subtraction.
    ///
    /// `excludedChannels` passes a channel through untouched; this is the other
    /// thing a user may want — correct the artifact, but do not let a stage that
    /// models the *residual* near a questionable channel. The two are separate
    /// because conflating them is how a channel ends up either over-processed or
    /// not corrected at all.
    var obsExcludedChannels: Set<Int> = []
    /// Channels that skip adaptive noise cancellation but still receive template
    /// subtraction (and OBS, unless also listed above).
    var ancExcludedChannels: Set<Int> = []

    // ANC

    var anc: Bool = false
    var ancHighPass: GradientANC.HighPassPolicy = .fixed2Hz
    var ancFilterLength: Int = 32
    /// NLMS step size. Stable for 0 < step < 2, but stability is not the only
    /// concern: a large step lets the weights chase sample-to-sample detail and
    /// start fitting brain signal that has nothing to do with the reference. The
    /// default is deliberately small, trading adaptation speed for a filter that
    /// tracks the artifact's slow drift and little else.
    var ancStepSize: Double = 0.01

    // Compute

    /// Which backend runs the dense stages. `.metal` falls back to the CPU
    /// silently when no usable device is present, and on recordings small enough
    /// that the round trip costs more than it saves.
    ///
    /// This changes how the arithmetic is scheduled, never what is computed:
    /// every discrete decision is made on the CPU from deterministically rounded
    /// values, so the two backends agree exactly on donor sets, shifts, component
    /// counts and warnings, and differ only within the numerical tolerance
    /// documented in `docs/provenance/fastr-gpu-port-plan.md`.
    var computeBackend: GradientComputeBackend = .cpu

    /// Smallest workload — epoch samples summed over every corrected channel —
    /// that `.metal` is actually used for. Buffer setup and round-trip latency
    /// dominate below some size, and the user should not have to reason about
    /// where that crossover is. Set to 0 to force the GPU path.
    ///
    /// The default is where the crossover was measured on Apple silicon: the GPU
    /// runs at 0.9x of the CPU at a workload of 160,000, 1.24x at 490,000, and
    /// keeps climbing from there.
    var metalMinimumWorkload: Int = 250_000

    init() {}

    /// Donor count actually requested, honoring the symmetric fallback.
    var requestedDonorCount: Int {
        let directional = max(0, averagingWindowBefore) + max(0, averagingWindowAfter)
        return directional > 0 ? directional : max(1, averagingWindow)
    }
}

// MARK: - Errors

nonisolated enum GradientCorrectionError: LocalizedError, Equatable {
    case noChannels
    case emptyChannels
    case mismatchedChannelLengths
    case insufficientTriggers(Int)
    case degenerateEpochGeometry
    case invalidConfiguration(String)
    case backendFailure(String)

    var errorDescription: String? {
        switch self {
        case .noChannels:
            return "No channels were supplied to gradient correction."
        case .emptyChannels:
            return "The supplied channels contain no samples."
        case .mismatchedChannelLengths:
            return "All channels must have the same number of samples."
        case .insufficientTriggers(let count):
            return "Gradient correction needs at least two volume triggers inside the recording, but found \(count)."
        case .degenerateEpochGeometry:
            return "The triggers are too closely spaced to define an artifact epoch."
        case .invalidConfiguration(let detail):
            return "Invalid gradient-correction configuration: \(detail)"
        case .backendFailure(let detail):
            return "The gradient-correction compute backend failed: \(detail)"
        }
    }
}

// MARK: - Warnings

/// Non-fatal conditions worth surfacing. Every fallback the corrector takes
/// records one, so a run can be explained after the fact.
nonisolated enum GradientCorrectionWarning: Sendable, Hashable {
    case epochOutOfBounds(epoch: Int)
    case noEligibleDonors(epoch: Int)
    case degenerateTemplate(epoch: Int)
    case templateScaleRejected(epoch: Int)
    case motionUnavailableForScheme
    case noSupraThresholdMotion
    case motionRowsFrontPadded(count: Int)
    case motionRowsTruncated(count: Int)
    case donorsCrossedMotionBarrier(epoch: Int)
    case correlationDonorsFellBack(epoch: Int)
    case obsChunkTooSmall(epochCount: Int)
    case obsBasisUnavailable(chunkStart: Int)
    case obsResidualBelowFloor(chunkStart: Int)
    case ancSkippedForUninformativeReference(channel: Int)

    var message: String {
        switch self {
        case .epochOutOfBounds(let epoch):
            return "Epoch \(epoch) extends past the recording and was left uncorrected."
        case .noEligibleDonors(let epoch):
            return "No eligible donor epochs for epoch \(epoch); it was left uncorrected."
        case .degenerateTemplate(let epoch):
            return "The donor template for epoch \(epoch) carries no energy; no subtraction was applied."
        case .templateScaleRejected(let epoch):
            return "The fitted template scale for epoch \(epoch) was not a usable amplitude; neighbouring epochs were used instead."
        case .motionUnavailableForScheme:
            return "Motion-informed donors were requested but no motion parameters were supplied; using temporal neighbors."
        case .noSupraThresholdMotion:
            return "No volume exceeded the motion threshold; using temporal neighbors."
        case .motionRowsFrontPadded(let count):
            return "Motion file had \(count) fewer rows than volumes; front-padded with zero motion to align to volume indices."
        case .motionRowsTruncated(let count):
            return "Motion file had \(count) more rows than volumes; extra trailing rows were ignored."
        case .donorsCrossedMotionBarrier(let epoch):
            return "Epoch \(epoch) had too few donors on its side of a motion event; donors were taken across it."
        case .correlationDonorsFellBack(let epoch):
            return "Too few epochs met the correlation threshold for epoch \(epoch); using temporal neighbors."
        case .obsChunkTooSmall(let epochCount):
            return "An OBS chunk held only \(epochCount) usable epochs, too few to estimate a basis; it was skipped."
        case .obsBasisUnavailable(let chunkStart):
            return "No usable OBS basis could be estimated for the chunk starting at epoch \(chunkStart); it was skipped."
        case .obsResidualBelowFloor(let chunkStart):
            return "Template subtraction already explained the artifact in the chunk starting at epoch \(chunkStart); OBS was skipped so it could not remove signal instead."
        case .ancSkippedForUninformativeReference(let channel):
            return "The artifact reference for channel \(channel) carried no usable variance; ANC was skipped."
        }
    }
}

// MARK: - Diagnostics and result

/// Per-epoch record of what the corrector did, captured for the diagnostic
/// channel. Donor choice under the correlation strategies is channel-dependent,
/// so these describe one representative channel rather than all of them.
nonisolated struct GradientEpochDiagnostic: Sendable {
    let epoch: Int
    let trigger: Int
    let volume: Int
    let slicePosition: Int
    let integerShift: Int
    let fractionalShift: Double
    let donorIndices: [Int]
    let templateScale: Double
    let corrected: Bool
}

nonisolated struct GradientCorrectionDiagnostics: Sendable {
    let epochCount: Int
    let period: Int
    let samplesBefore: Int
    let samplesAfter: Int
    /// Channel the alignment estimate and per-epoch records were taken from.
    let referenceChannel: Int
    /// The backend that actually ran, after availability and workload fallbacks.
    /// A run configured for `.metal` on a machine without a usable device, or on
    /// a recording too small to be worth the round trip, reports `.cpu` here.
    let computeBackend: GradientComputeBackend
    let highMotionVolumes: Set<Int>
    let epochs: [GradientEpochDiagnostic]
    /// Components removed per OBS chunk, for the diagnostic channel. Empty when
    /// OBS was off.
    let obsComponentCounts: [Int]
    /// Channels where ANC ran. A channel is absent when ANC was off or its
    /// reference carried no usable variance.
    let ancAppliedChannels: Set<Int>
    let warnings: [GradientCorrectionWarning]

    var correctedEpochCount: Int { epochs.filter(\.corrected).count }
}

nonisolated struct GradientCorrectionResult: Sendable {
    let channels: [[Float]]
    let diagnostics: GradientCorrectionDiagnostics
}
