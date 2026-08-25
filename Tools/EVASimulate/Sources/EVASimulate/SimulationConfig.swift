//
//  SimulationConfig.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Every knob of the forward model, with defaults taken from the paper this
//  harness reproduces:
//
//    Grouiller F, Vercueil L, Krainik A, Segebarth C, Kahane P, David O (2007).
//    A comparative study of different artefact removal algorithms for EEG
//    signals acquired during functional MRI. NeuroImage 38(1):124-37.
//
//  Where the paper states a value it is used verbatim and cited in the comment.
//  Where it does not (the shape of the synthetic gradient and BCG waveforms,
//  most obviously) the choice is EVA's and is called out as such, because the
//  distinction matters when interpreting a sweep: a result that depends on an
//  invented waveform shape is weaker evidence than one that depends on a
//  measured template. Prefer `--gradient-template` with a real measured
//  template when you have one.
//

import Foundation

nonisolated struct SimulationConfig: Codable, Sendable {

    // MARK: Recording geometry

    /// The paper ran at 1024 Hz; the operational default is 1000 Hz. That
    /// started as a workaround for millisecond-quantized MFF event times, which
    /// roadmap item 4.9 fixed — every rate now round-trips exactly, so this is
    /// an ordinary default rather than a constraint. Use
    /// scenarios/paper-default.json for the exact published sampling rate.
    var channelCount: Int = 20
    var samplingRate: Double = 1000
    var durationSeconds: Double = 180
    var seed: UInt64 = 20_260_821

    /// Rate the artifact waveforms are modelled at before being point-sampled
    /// onto the EEG clock, as a multiple of `samplingRate`. This is what makes
    /// the clock-offset model meaningful: the drift below is a fraction of an
    /// output sample per TR, so the continuous artifact has to exist at a finer
    /// resolution than the output grid for that shift to be representable.
    /// 64 puts the timing quantum at 15.625 µs (at 1000 Hz out), well under the
    /// 152 µs/s drift.
    var artifactOversampleFactor: Int = 64

    /// Anti-alias the modelled artifact at this fraction of the output Nyquist
    /// before point-sampling, standing in for the amplifier's own anti-alias
    /// filter (the paper's rig used a Sigma-Delta converter at 268.8 Hz).
    /// Set to 0 to sample the raw high-rate waveform instead, which lets the
    /// full aliasing of an unfiltered artifact through.
    var artifactAntiAliasFraction: Double = 0.9

    // MARK: EEG

    /// Paper: "a linear mixture of seven Gaussian distributions", each bandpass
    /// filtered into a different band between 1 and 70 Hz. The band edges and
    /// per-band amplitudes below are EVA's, chosen for a roughly 1/f falloff;
    /// the paper fit theirs to one subject's spectrum and does not print them.
    /// The gap from 45 to 55 Hz is the paper's modelled notch-filter dropout.
    var eegBands: [EEGBand] = EEGBand.defaults

    /// Paper: alpha amplitude alternates between 10 µV (eyes open) and 30 µV
    /// (eyes closed) as the subject opens and closes their eyes every 20 s,
    /// modelled as a sine — so one full cycle is 40 s.
    var alphaLowMicrovolts: Double = 10
    var alphaHighMicrovolts: Double = 30
    var alphaCycleSeconds: Double = 40

    /// Paper: spatial correlation modelled as circular connectivity between
    /// channels with a Gaussian smoothing kernel of SD 4 channels applied at
    /// each time bin.
    var spatialSmoothingChannels: Double = 4

    /// Paper: std(EEG) was 10.9 µV across their simulations, which is what
    /// makes their reported SNRs comparable to ours. The generated EEG is
    /// scaled by one global factor to hit this.
    var eegTargetStdMicrovolts: Double = 10.9

    /// The published Grouiller model remains the default. Dipoles are opt-in so
    /// the original benchmark continues to reproduce the paper.
    var eegGenerationModel: EEGGenerationModel = .grouiller
    var dipoleSourceCount: Int = 7
    var dipoleSourceRadiusFraction: Double = 0.85
    var dipoleOrientationPattern: DipoleOrientationPattern = .mixed
    /// Legacy field retained for older scenarios. `recordingReference`, when
    /// present, supersedes it and applies to every additive signal layer.
    var dipoleReference: EEGReference = .average
    var recordingReference: EEGReference? = nil
    var leadFieldTerms: Int = 100
    var sphericalHeadModel: SphericalHeadModel = .classicThreeShell
    /// Pearson correlation imposed between S001 and S002 after independent
    /// signals are generated within S001's configured band. Zero disables it.
    var dipoleSourceCorrelation: Double = 0
    /// Move S002 this many degrees from S001, transporting its orientation with
    /// it. Zero keeps the prefix-stable catalog unchanged.
    var dipoleNearPairSeparationDegrees: Double = 0
    /// Rotate S001 by this many degrees during the recording. Zero is static.
    var dipoleMotionDegrees: Double = 0
    var dipoleMotionStartFraction: Double = 0.45
    var dipoleMotionTransitionFraction: Double = 0.10

    // MARK: Neural non-stationarity

    /// Nil preserves the stationary Grouiller/paper model. The opt-in model can
    /// independently add burst-like alpha, slow spectral dynamics, topographic
    /// microstates, and phase-amplitude coupling.
    var neuralNonstationarity: NeuralNonstationarityConfig? = nil

    // MARK: Gradient artifact

    var gradientEnabled: Bool = true

    /// Quiet time before the scanner starts and after it stops, in seconds.
    ///
    /// The gradient artifact is absent in these windows; the ballistocardiogram
    /// is not. That asymmetry is physical, not a convenience: the BCG comes from
    /// pulsatile motion inside the *static* B0 field, which is on the whole time
    /// the subject is in the bore, while the imaging artifact only exists while
    /// gradients are switching. A recording that starts before the sequence does
    /// therefore shows clean-looking EEG that is already contaminated by the
    /// cardiac artifact — which is exactly the thing worth showing a class, and
    /// exactly the thing that makes "just look at the trace" a bad way to judge
    /// a correction.
    var preScanSeconds: Double = 0
    var postScanSeconds: Double = 0

    /// Paper's GE-EPI sequence: TR = 3 s, 41 adjacent slices.
    var repetitionTimeSeconds: Double = 3.0
    var slicesPerVolume: Int = 41
    /// Duration of one slice's gradient artifact. Paper: "usually about 60 ms".
    var sliceArtifactSeconds: Double = 0.060

    /// Paper: artifact amplitude was varied between channels, 0 to 7000 µV
    /// peak-to-peak, to model observed channel differences. Spread linearly
    /// across channels from `min` to `max`.
    var gradientAmplitudeMinMicrovolts: Double = 500
    var gradientAmplitudeMaxMicrovolts: Double = 7000

    /// Paper: a 152 µs-per-second timing offset between the EEG and MRI clocks,
    /// matching what they measured on their own rig. This is the dominant
    /// source of residual gradient spikes after template subtraction, and the
    /// reason sampling rate matters at all.
    var clockOffsetMicrosecondsPerSecond: Double = 152

    /// Paper: a slow modulation of artifact amplitude, up to 500 µV, modelled
    /// as a sine of period 200 s; simulations used 10% of mean amplitude unless
    /// the modulation itself was the swept parameter (they swept 0-25%).
    var slowModulationFraction: Double = 0.10
    var slowModulationPeriodSeconds: Double = 200

    /// Frequency of the modelled EPI readout, whose harmonics make up the
    /// synthetic slice waveform. EVA's choice, not the paper's — a real
    /// template loaded with `--gradient-template` overrides all of this.
    var gradientReadoutHz: Double = 1000
    /// Ramp time of the modelled gradient trapezoids. Short ramps make the
    /// induced dB/dt broadband and spiky, which is what the real artifact looks
    /// like; this is the main handle on how hard the synthetic artifact is.
    var gradientRampSeconds: Double = 0.00015

    /// Optional measured slice template. Keeping the asset reference and rate
    /// in the Codable configuration makes scenario files and truth sidecars
    /// describe the actual model rather than only its synthetic fallback.
    var gradientTemplatePath: String? = nil
    var gradientTemplateRateHz: Double? = nil

    // MARK: Ballistocardiogram

    var bcgEnabled: Bool = true

    /// Paper: heart rate modulated smoothly between 65 and 85 bpm by a sine of
    /// one-minute period.
    var heartRateMinBPM: Double = 65
    var heartRateMaxBPM: Double = 85
    var heartRateCycleSeconds: Double = 60

    /// Paper: mean BCG amplitude per channel was varied from 10 to 200 µV to
    /// span the contamination levels seen from low field up to 3T and beyond.
    var bcgAmplitudeMicrovolts: Double = 100

    /// Paper: each beat's amplitude weights the previous beat's amplitude and a
    /// fresh normal draw of SD 15% of the mean equally.
    var bcgAmplitudeJitterFraction: Double = 0.15

    /// Paper: phase lags between vessel pulsations over the head, modelled as a
    /// per-channel latency of SD 15 ms.
    var bcgChannelLatencySDSeconds: Double = 0.015

    // The three BCG generator settings are Optional rather than defaulted, and
    // deliberately so. Swift's synthesized `Decodable` does *not* fall back to a
    // property's default value when a key is absent, and every scenario file
    // ever written carries the complete configuration — so a non-optional
    // addition here would make every existing scenario, including users' own,
    // fail to load. `recordingReference` established this pattern for the same
    // reason. Read them through the `effective...` accessors below.

    /// How the BCG is distributed over the head.
    ///
    /// `.channelIndex` is the original weighting and remains the default so the
    /// published benchmark reproduces unchanged; it is a function of channel
    /// *index*, not electrode position, and is rank one. `.generators` places
    /// four physical generators with real topographies — see
    /// `BCGGeneratorModel`. Anything that turns on BCG topography or on the
    /// artifact's spatial rank needs `.generators`.
    var bcgSpatialModel: BCGSpatialModel? = nil

    /// Static field strength in tesla. Both motional EMF and the Hall
    /// separation are linear in B, so amplitude scales from the 3 T reference
    /// the paper's 10-200 µV range describes. Only `.generators` uses it.
    var bcgFieldStrengthTesla: Double? = nil

    /// Beat-to-beat variation of each generator's share, independently drawn.
    /// Because the generators differ in topography *and* delay, this makes the
    /// composite's shape vary from beat to beat, not only its size. Zero
    /// restores a fixed morphology.
    var bcgMorphologyJitterFraction: Double? = nil

    /// Paper: automatic QRS detection jitters the recovered beat time by about
    /// 20 ms; simulations used 25 ms SD and swept 0-50 ms.
    ///
    /// This is the single most important knob in the whole model, because it is
    /// the one that separates methods which depend on beat timing (AAS and its
    /// relatives) from those which do not (reference-channel regression, ICA).
    /// It perturbs only the *event times written to the file* — the artifact
    /// itself is injected at the true beat times.
    var qrsDetectionJitterSDSeconds: Double = 0.025

    /// Beat-to-beat heart-rate variability, as a fraction of the RR interval.
    ///
    /// The paper's cardiac model has none: heart rate is a smooth 60 s sine, so
    /// RR walks monotonically and the ECG looks drawn rather than recorded.
    /// A resting adult's RR standard deviation is 3-8% of the mean, which is
    /// where the default sits. `--hrv 0` restores the paper's exact timing for
    /// benchmark comparability.
    var heartRateVariability: Double = 0.04

    /// Respiration rate, in Hz. Drives respiratory sinus arrhythmia, ECG
    /// amplitude modulation and baseline wander. 0.25 Hz is 15 breaths/min.
    var respirationHz: Double = 0.25

    /// Duration of one modelled BCG waveform.
    var bcgWaveformSeconds: Double = 0.6

    // MARK: Auxiliary channels

    /// Write a synthetic ECG as a PNS channel, so R-wave detection can be
    /// exercised end to end rather than being handed the answer.
    var includeECG: Bool = true
    /// R-peak amplitude of the synthetic ECG. ~1 mV is the usual scale for a
    /// scalp-lead ECG through an EEG amplifier.
    var ecgAmplitudeMicrovolts: Double = 1000

    /// Write a synthetic motion-sensor channel as PNS. Paper §"Kalman Adaptive
    /// Filtering": the sensor sees the BCG through a saturating nonlinearity,
    /// modelled as sigmoid(a·x) with a = 0.1 applied to the across-channel mean
    /// BCG. This exists to give reference-channel methods (CWL regression, and
    /// the adaptive filter in TODO_Aug21.md item 2) something to regress
    /// against that is deliberately *not* a linear copy of the artifact.
    var includeMotionSensor: Bool = true
    var motionSensorSigmoidGain: Double = 0.1

    // MARK: Ocular artifacts

    /// Blinks per minute; 0 disables them. Off by default — the paper's
    /// simulations were explicitly free of ocular artifacts, and turning them on
    /// would silently change every benchmark number. A resting adult blinks
    /// somewhere around 12-20 times a minute.
    var blinksPerMinute: Double = 0
    /// Peak blink amplitude at the frontal pole, in µV. Real blinks run
    /// 50-200 µV at Fp1/Fp2 — far larger than the EEG they sit on, which is the
    /// whole pedagogical point.
    var blinkAmplitudeMicrovolts: Double = 100
    /// Window the blink waveform is modelled over. Long enough that the decay
    /// has finished before the window closes.
    var blinkDurationSeconds: Double = 0.6

    /// Saccades per minute; 0 disables eye movements.
    var saccadesPerMinute: Double = 0
    /// Scalp amplitude at full gaze deflection, in µV.
    var eyeMovementAmplitudeMicrovolts: Double = 40
    /// How long the eyes take to reach the new position. Real saccades are
    /// 30-80 ms depending on how far they travel.
    var saccadeTransitionSeconds: Double = 0.04
    var ocularSpatialModel: OcularSpatialModel = .heuristic

    // MARK: Muscle artifact

    /// Nil keeps muscular activity out of the paper/default benchmark. EMG is
    /// deliberately opt-in because it overlaps neural beta/gamma activity and
    /// changes the question a correction benchmark is answering.
    var emg: EMGConfig? = nil
    var chewing: ChewingConfig? = nil
    var swallowing: SwallowingConfig? = nil
    var cableMovement: CableMovementConfig? = nil
    var sweat: SweatConfig? = nil

    // MARK: Non-additive recording artifacts

    var bridgedChannelPairs: [ChannelBridge]? = nil
    var badReference: BadReferenceConfig? = nil
    /// Symmetric amplifier rails in µV. Nil leaves the signal linear.
    var clippingThresholdMicrovolts: Double? = nil

    // MARK: Event-related potentials

    /// Nil preserves the paper-default continuous EEG exactly. An ERPConfig is
    /// a complete opt-in experimental design and component model.
    var erp: ERPConfig? = nil

    // MARK: Recording defects

    /// Channels deliberately made bad, keyed by 1-based channel number.
    var badChannels: [Int: ChannelDefect] = [:]

    /// Record a per-electrode impedance measurement in the file, the way a real
    /// EGI system does. On by default: a recording without one is the unusual
    /// case, and EVA's health scoring simply skips impedance when it is absent.
    var includeImpedance: Bool = true
    /// Typical impedance of a *healthy* electrode, in kΩ. Values scatter around
    /// this; bad channels get values appropriate to their defect instead.
    /// Per-subject electrode placement variation, in degrees (roadmap 3.1).
    /// Nil keeps the nominal montage, which is what every single-subject
    /// scenario wants.
    var montageJitterDegrees: Double? = nil

    var impedanceTypicalKOhm: Double = 12

    /// Couples the simulated contact impedance to Johnson noise and mains
    /// pickup. Nil restores the pre-2.2 behaviour in which impedance was only a
    /// recorded measurement. Optional also keeps older scenario files readable.
    var impedanceNoise: ImpedanceNoiseConfig? = ImpedanceNoiseConfig()

    /// Mains frequency, in Hz; 0 disables line noise. Off by default for the
    /// same reason ocular artifacts are — but it is the single most useful thing
    /// to switch on for a filtering demo, since a notch filter has nothing to
    /// show without it.
    var lineNoiseHz: Double = 0
    var lineNoiseAmplitudeMicrovolts: Double = 8

    // MARK: Spatial model

    var spatialModel: SpatialModel = .circular

    static let `default` = SimulationConfig()

    var sampleCount: Int {
        max(1, Int((durationSeconds * samplingRate).rounded()))
    }

    /// Volumes that fit inside the scanning window, i.e. the recording minus
    /// the quiet lead-in and lead-out.
    var volumeCount: Int {
        let scanning = durationSeconds - max(0, preScanSeconds) - max(0, postScanSeconds)
        return max(0, Int(scanning / repetitionTimeSeconds))
    }

    var sliceIntervalSeconds: Double {
        repetitionTimeSeconds / Double(max(1, slicesPerVolume))
    }

    var artifactRate: Double {
        samplingRate * Double(max(1, artifactOversampleFactor))
    }

    var effectiveRecordingReference: EEGReference {
        recordingReference ?? dipoleReference
    }

    var effectiveBCGSpatialModel: BCGSpatialModel { bcgSpatialModel ?? .channelIndex }
    var effectiveBCGFieldStrengthTesla: Double { bcgFieldStrengthTesla ?? 3.0 }
    var effectiveBCGMorphologyJitterFraction: Double { bcgMorphologyJitterFraction ?? 0.20 }
}

/// One band-limited Gaussian source in the EEG mixture.
nonisolated struct EEGBand: Codable, Sendable {
    var name: String
    var lowHz: Double
    var highHz: Double
    /// Standard deviation this band contributes, in µV, before the global scale
    /// to `eegTargetStdMicrovolts`. `nil` for the alpha band, whose amplitude is
    /// driven by the eyes-open/eyes-closed envelope instead.
    var amplitudeMicrovolts: Double?

    var isAlpha: Bool { amplitudeMicrovolts == nil }

    /// Seven sources spanning 1-70 Hz with a 45-55 Hz gap for the line-noise
    /// notch, falling off roughly as 1/f.
    static let defaults: [EEGBand] = [
        EEGBand(name: "delta", lowHz: 1, highHz: 4, amplitudeMicrovolts: 8.0),
        EEGBand(name: "theta", lowHz: 4, highHz: 8, amplitudeMicrovolts: 5.0),
        EEGBand(name: "alpha", lowHz: 8, highHz: 12, amplitudeMicrovolts: nil),
        EEGBand(name: "beta-low", lowHz: 12, highHz: 20, amplitudeMicrovolts: 3.0),
        EEGBand(name: "beta-high", lowHz: 20, highHz: 30, amplitudeMicrovolts: 2.0),
        EEGBand(name: "gamma-low", lowHz: 30, highHz: 45, amplitudeMicrovolts: 1.2),
        EEGBand(name: "gamma-high", lowHz: 55, highHz: 70, amplitudeMicrovolts: 0.8)
    ]
}

nonisolated struct NeuralNonstationarityConfig: Codable, Sendable {
    var alphaBursts: AlphaBurstConfig? = AlphaBurstConfig()
    var spectralDynamics: SpectralDynamicsConfig? = SpectralDynamicsConfig()
    var microstates: MicrostateConfig? = MicrostateConfig()
    var phaseAmplitudeCoupling: PhaseAmplitudeCouplingConfig? = PhaseAmplitudeCouplingConfig()
}

nonisolated struct AlphaBurstConfig: Codable, Sendable {
    var burstsPerMinute: Double = 12
    var meanDurationSeconds: Double = 1.0
    var durationSDSeconds: Double = 0.25
    /// Fraction of the block-design alpha amplitude retained between spindles.
    var backgroundFraction: Double = 0.05
}

nonisolated struct SpectralDynamicsConfig: Codable, Sendable {
    /// Stationary SD of the log-amplitude Ornstein-Uhlenbeck process.
    var logAmplitudeSD: Double = 0.35
    var timeConstantSeconds: Double = 12
    var updateIntervalSeconds: Double = 1
}

nonisolated struct MicrostateConfig: Codable, Sendable {
    var stateCount: Int = 4
    var meanDwellSeconds: Double = 0.10
    var minimumDwellSeconds: Double = 0.04
    var maximumDwellSeconds: Double = 0.25
    var transitionSeconds: Double = 0.01
    /// RMS of the added broadband carrier before the final common EEG scale.
    var amplitudeMicrovolts: Double = 4
    var carrierLowHz: Double = 2
    var carrierHighHz: Double = 20
}

nonisolated struct PhaseAmplitudeCouplingConfig: Codable, Sendable {
    var phaseFrequencyHz: Double = 6
    var targetBandName: String = "gamma-low"
    /// Cosine modulation depth, from 0 (none) through 1 (zero at opposition).
    var strength: Double = 0.7
    var preferredPhaseRadians: Double = 0
    /// Adds a visible phase-providing oscillator to the band containing
    /// `phaseFrequencyHz`, relative to that band's unit-RMS stochastic carrier.
    var phaseCarrierFraction: Double = 0.25
}


/// How EEG channels are made spatially correlated.
nonisolated enum SpatialModel: String, Codable, Sendable, CaseIterable {
    /// The paper's model: smooth across adjacent channel *indices*, wrapping
    /// around. Keeps benchmark numbers comparable with the published ones.
    case circular
    /// Smooth by actual distance between electrodes on the scalp. Not the
    /// paper's model, but the one that makes a topographic map look like a
    /// topographic map — prefer it for demos and for anything that tests a
    /// method's use of topography.
    case geometric
}

nonisolated enum EEGGenerationModel: String, Codable, Sendable, CaseIterable {
    case grouiller
    case dipole
}

nonisolated enum DipoleOrientationPattern: String, Codable, Sendable, CaseIterable {
    case radial
    case tangential
    case mixed
    /// Deterministic oblique orientations with non-zero x/y/z components.
    case free
}

nonisolated enum OcularSpatialModel: String, Codable, Sendable, CaseIterable {
    /// Original teaching topographies: recognizable, explicitly ad hoc.
    case heuristic
    /// Two corneo-retinal dipoles in a homogeneous conductor, average-referenced
    /// and normalized at the scalp. Still simplified, but physically derived.
    case dipole
}

nonisolated struct EMGConfig: Codable, Sendable {
    /// Mean burst count per minute. Intervals are exponentially distributed
    /// with a refractory floor, so the activity clusters without overlapping
    /// unrealistically at every draw.
    var burstsPerMinute: Double = 8
    /// RMS carrier amplitude at the strongest electrode during the plateau of
    /// an average burst. Individual bursts vary around this value.
    var amplitudeMicrovolts: Double = 50
    /// Mean duration; individual bursts vary from 0.6x to 1.4x this value.
    var burstDurationSeconds: Double = 0.75
    /// Surface EMG is broadband and predominantly above ordinary EEG rhythms.
    var lowHz: Double = 20
    var highHz: Double = 200
}

nonisolated struct ChewingConfig: Codable, Sendable {
    var episodesPerMinute: Double = 2
    var amplitudeMicrovolts: Double = 100
    var durationSeconds: Double = 4
    var cycleHz: Double = 1.5
    var lowHz: Double = 20
    var highHz: Double = 150
}

nonisolated struct SwallowingConfig: Codable, Sendable {
    var eventsPerMinute: Double = 2
    var amplitudeMicrovolts: Double = 120
    var durationSeconds: Double = 1.0
    var lowHz: Double = 20
    var highHz: Double = 150
}

nonisolated struct CableMovementConfig: Codable, Sendable {
    var eventsPerMinute: Double = 2
    var amplitudeMicrovolts: Double = 150
    var durationSeconds: Double = 3
    var oscillationHz: Double = 0.8
}

nonisolated struct SweatConfig: Codable, Sendable {
    var episodesPerMinute: Double = 1
    var amplitudeMicrovolts: Double = 100
    var durationSeconds: Double = 15
    var affectedChannelCount: Int = 1
}

nonisolated struct ChannelBridge: Codable, Sendable, Hashable {
    var firstChannel: Int
    var secondChannel: Int
}

nonisolated struct BadReferenceConfig: Codable, Sendable {
    var amplitudeMicrovolts: Double = 50
    var lowHz: Double = 0.2
    var highHz: Double = 30
}

/// Physically motivated contact-noise coupling. Johnson-Nyquist voltage is
/// calculated from temperature, resistance, and the recording's Nyquist
/// bandwidth. Mains pickup has no equally universal closed form, so its
/// impedance exponent and safety clamp are explicit simulation parameters.
nonisolated struct ImpedanceNoiseConfig: Codable, Sendable {
    var temperatureKelvin: Double = 298.15
    /// Fixed physical reference for the phenomenological mains law. Optional
    /// keeps early 2.2 scenario drafts (which omitted the field) readable.
    var referenceImpedanceKOhm: Double? = 12
    var lineNoiseImpedanceExponent: Double = 1
    var maximumLineNoiseScale: Double = 10
}

nonisolated enum ERPWaveformKind: String, Codable, Sendable, CaseIterable {
    case gaussian
    case biphasic
    case measured
}

nonisolated struct ERPConfig: Codable, Sendable {
    var trialCount: Int = 80
    var startSeconds: Double = 1
    var interStimulusIntervalSeconds: Double = 1.5
    var interStimulusJitterSeconds: Double = 0.2
    var targetFraction: Double = 0.2
    var peakLatencySeconds: Double = 0.3
    var latencyJitterSDSeconds: Double = 0.03
    /// Zero is Gaussian. Positive/negative values add a standardized quadratic
    /// term to create right/left-skewed latency distributions.
    var latencySkew: Double = 0
    var targetAmplitudeMicrovolts: Double = 8
    var standardAmplitudeRatio: Double = 0.5
    var amplitudeJitterFraction: Double = 0.2
    var latencyAmplitudeCorrelation: Double = 0
    var omissionRate: Double = 0.05
    var waveform: ERPWaveformKind = .gaussian
    var widthSeconds: Double = 0.06
    var measuredTemplatePath: String? = nil
    var measuredTemplateRateHz: Double? = nil

    /// Explicitly placed components. When nil, the single legacy component
    /// described by the fields above is used, unchanged — so scenarios written
    /// before roadmap 4.3 reproduce byte-for-byte.
    ///
    /// When present, these replace the single component entirely. Each carries
    /// its own generator, waveform and per-condition amplitudes, which is what
    /// makes published dipole models (and overlapping P1/N1/P2 complexes)
    /// expressible at all.
    var components: [ERPComponentConfig]? = nil
}

/// One explicitly placed ERP generator.
///
/// ## Coordinate frame
///
/// Positions and orientations are in the simulator's own frame:
/// **+x toward the right ear, +y toward the nose, +z toward the vertex**, origin
/// at the centre of the spherical head model, in **millimetres**. This is the
/// same frame `Montage` uses for electrode directions and `SimulatedSource` uses
/// for dipoles, so a position here is directly comparable to the neural sources
/// in the truth sidecar.
///
/// Published models are usually stated in Talairach or MNI coordinates, whose
/// axes match this frame's — right, anterior, superior — but whose origin is the
/// anterior commissure rather than a sphere centre. `talairachApproximate`
/// converts under a declared approximation; read its documentation before
/// using it for anything that turns on absolute position.
nonisolated struct ERPComponentConfig: Codable, Sendable {
    var id: String = "component"
    /// Millimetres in the simulator frame. Nil places the component the way the
    /// legacy single-component path did, which is convenient for varying only
    /// timing, and is recorded as such in the truth sidecar.
    var positionMillimetres: Vector3D? = nil
    /// Need not be normalized; it is normalized on use.
    var orientation: Vector3D? = nil
    var peakLatencySeconds: Double = 0.1
    var widthSeconds: Double = 0.03
    var waveform: ERPWaveformKind = .gaussian
    var measuredTemplatePath: String? = nil
    var measuredTemplateRateHz: Double? = nil
    /// Peak source amplitude for target trials.
    var targetAmplitudeMicrovolts: Double = 8
    /// Multiplier applied on standard trials. A component that is genuinely
    /// target-specific takes 0 here; one that is stimulus-driven takes 1.
    var standardAmplitudeRatio: Double = 0.5
    /// Per-trial latency jitter for this component. Components of a real
    /// complex do not jitter together, which is precisely what single-trial
    /// latency estimators are built to resolve.
    var latencyJitterSDSeconds: Double = 0.02
    var amplitudeJitterFraction: Double = 0.2

    /// Talairach/MNI (x right, y anterior, z superior, millimetres, origin at
    /// the anterior commissure) into the simulator frame.
    ///
    /// **This is an approximation and should be treated as one.** The simulator's
    /// origin is the centre of a sphere, not the anterior commissure, and a
    /// sphere is not a head. The AC sits below and behind a head's centroid, so
    /// a fixed offset is applied; no scaling or shear is attempted. Positions
    /// converted this way preserve the *relative* geometry of a published model
    /// — which is what makes a bilateral pair bilateral — far better than they
    /// preserve absolute anatomical location. A claim that turns on absolute
    /// position needs a real head model, not this.
    static func talairachApproximate(x: Double, y: Double, z: Double) -> Vector3D {
        // Anterior commissure relative to the sphere centre, in millimetres.
        let anteriorCommissureOffset = Vector3D(x: 0, y: 4, z: -12)
        return Vector3D(x: x, y: y, z: z) + anteriorCommissureOffset
    }
}

/// A way for one channel to be bad. Each is something that really happens to
/// an electrode, and each defeats a different naive analysis — which is what
/// makes them worth teaching with.
nonisolated enum ChannelDefect: String, Codable, Sendable, CaseIterable {
    /// Dead or shorted: almost no signal at all.
    case flat
    /// High-impedance contact: broadband noise swamping the EEG.
    case noisy
    /// Drifting baseline from a slowly failing contact — survives a notch
    /// filter, defeats amplitude thresholds, fixed by a high-pass.
    case drift
    /// Intermittent electrode pops: sudden steps that decay back.
    case pop
    /// Heavy mains pickup on one channel only, which is what makes it a good
    /// demonstration that a notch filter is a per-channel decision.
    case line

    var summary: String {
        switch self {
        case .flat: return "dead/shorted — near-zero signal"
        case .noisy: return "high impedance — broadband noise"
        case .drift: return "failing contact — large slow drift"
        case .pop: return "intermittent electrode pops"
        case .line: return "heavy mains pickup"
        }
    }
}
