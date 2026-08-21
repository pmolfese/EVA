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

    /// Paper: simulations ran over 20 channels for 3 minutes at 1024 Hz.
    var channelCount: Int = 20
    var samplingRate: Double = 1024
    var durationSeconds: Double = 180
    var seed: UInt64 = 20_260_821

    /// Rate the artifact waveforms are modelled at before being point-sampled
    /// onto the EEG clock, as a multiple of `samplingRate`. This is what makes
    /// the clock-offset model meaningful: the drift below is a fraction of an
    /// output sample per TR, so the continuous artifact has to exist at a finer
    /// resolution than the output grid for that shift to be representable.
    /// 64 puts the timing quantum at ~15 µs (at 1024 Hz out), well under the
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

    /// Paper: automatic QRS detection jitters the recovered beat time by about
    /// 20 ms; simulations used 25 ms SD and swept 0-50 ms.
    ///
    /// This is the single most important knob in the whole model, because it is
    /// the one that separates methods which depend on beat timing (AAS and its
    /// relatives) from those which do not (reference-channel regression, ICA).
    /// It perturbs only the *event times written to the file* — the artifact
    /// itself is injected at the true beat times.
    var qrsDetectionJitterSDSeconds: Double = 0.025

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

    // MARK: Recording defects

    /// Channels deliberately made bad, keyed by 1-based channel number.
    var badChannels: [Int: ChannelDefect] = [:]

    /// Record a per-electrode impedance measurement in the file, the way a real
    /// EGI system does. On by default: a recording without one is the unusual
    /// case, and EVA's health scoring simply skips impedance when it is absent.
    var includeImpedance: Bool = true
    /// Typical impedance of a *healthy* electrode, in kΩ. Values scatter around
    /// this; bad channels get values appropriate to their defect instead.
    var impedanceTypicalKOhm: Double = 12

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
