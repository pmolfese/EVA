//
//  SimulatorHelp.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Explanatory `?` popovers for Simulator Studio.
//
//  Simulator Studio has around seventy knobs, and a good number of them are not
//  guessable from their label: nothing in the words "Spatial model" tells you
//  that picking the wrong one makes an ICA benchmark meaningless, and nothing in
//  "Lead-field terms" tells you it is a numerical convergence setting rather
//  than a physiological one. This file carries the explanations for the ones
//  that need them.
//
//  Two rules for what goes in here, both learned from the options above:
//
//  * **A knob gets a topic when the label alone cannot tell you which value to
//    pick.** "Duration" does not need one. "Radius fraction" does. Adding a
//    popover to an obvious control is not free — it trains people to stop
//    reading the ones that matter.
//  * **Say what changes in the output, not what the field is named.** "Sets the
//    beat-to-beat variation" is worthless. "Every complex gets its own P/QRS/T
//    amplitude, so a detector cannot lock onto one stamped template" tells you
//    whether you want it.
//
//  Numbers quoted here are from the model source (`EVACore/Simulation`) and its
//  cited papers. When a default changes there, it changes here too.
//

import SwiftUI

/// One `?` popover's content.
///
/// The `options` list is what makes this worth a type rather than a string: for
/// a picker, "why pick one over the other" is the entire question, and it can
/// only be answered by putting the choices side by side.
struct HelpTopic {
    struct Option: Identifiable {
        let name: String
        let detail: String
        var id: String { name }
    }

    struct Resource: Identifiable {
        let title: String
        let url: URL
        var id: String { url.absoluteString }
    }

    let title: String
    /// What the control does, in a sentence or two.
    let summary: String
    /// Per-choice breakdown, for pickers and toggles with a real trade-off.
    var options: [Option] = []
    /// What to actually set it to, and when. The part people came for.
    var guidance: String? = nil
    /// Published source, when the model follows one.
    var reference: String? = nil
    /// Clickable primary sources or method repositories.
    var resources: [Resource] = []
}

// MARK: - Views

/// The `?` next to a control, and the popover it opens.
///
/// Deliberately a button rather than a `.help()` tooltip alone: these
/// explanations run to a paragraph and often compare several choices, which a
/// tooltip cannot hold and cannot be read at leisure. The tooltip is still set,
/// so hovering gives the one-line summary without a click.
struct HelpButton: View {
    let topic: HelpTopic
    @State private var shows = false

    var body: some View {
        Button {
            shows.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(topic.summary)
        .popover(isPresented: $shows, arrowEdge: .trailing) {
            HelpTopicView(topic: topic)
        }
    }
}

/// One topic laid out: summary, the per-choice breakdown when there is one, the
/// practical guidance, and the reference.
struct HelpTopicView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(topic.title).font(.headline)

                Text(topic.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !topic.options.isEmpty {
                    Divider()
                    ForEach(topic.options) { option in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.name).font(.caption.weight(.semibold))
                            Text(option.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let guidance = topic.guidance {
                    Divider()
                    Text("Which to use")
                        .font(.caption.weight(.semibold))
                    Text(guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let reference = topic.reference {
                    Divider()
                    Text(reference)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !topic.resources.isEmpty {
                    ForEach(topic.resources) { resource in
                        Link(resource.title, destination: resource.url)
                            .font(.caption)
                    }
                }
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
        .frame(maxHeight: 460)
    }
}

/// A control's label, with a `?` after it when the label alone is not enough.
struct RowLabel: View {
    let title: String
    var help: HelpTopic? = nil
    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            if let help { HelpButton(topic: help) }
        }
    }
}

// MARK: - Topics

/// Every popover's text, in one place, so the tab layouts stay readable and the
/// wording can be reviewed as a body of writing rather than hunted through view
/// builders.
enum SimulatorHelp {

    // MARK: Recording

    static let oversample = HelpTopic(
        title: "Artifact oversampling",
        summary: """
        Artifact waveforms are modelled at this multiple of the output sampling \
        rate, then point-sampled onto the EEG clock.
        """,
        guidance: """
        This is what makes the gradient clock offset mean anything. That drift \
        is a small fraction of an output sample per TR, so the continuous \
        artifact has to exist on a finer grid than the output for the shift to \
        be representable at all. At the default 64 and 1000 Hz out, the timing \
        quantum is 15.6 µs — well under the 152 µs/s drift. Lowering it makes \
        gradient residuals artificially clean; raising it costs memory and time \
        and buys nothing.
        """
    )

    static let antiAlias = HelpTopic(
        title: "Anti-alias fraction",
        summary: """
        Low-passes the modelled artifact at this fraction of the output Nyquist \
        before sampling it, standing in for the amplifier's own anti-alias \
        filter.
        """,
        guidance: """
        0.9 models a normal amplifier. Set it to 0 to sample the raw high-rate \
        waveform instead, which lets the full aliasing of an unfiltered \
        artifact through — realistic only for a rig that genuinely lacks the \
        filter, but useful when the point of the exercise is to show what \
        aliasing does to a gradient artifact.
        """
    )

    static let samplingRate = HelpTopic(
        title: "Sampling rate",
        summary: """
        The output rate of the simulated recording.
        """,
        guidance: """
        This matters more than usual in EEG–fMRI. Gradient artifact correction \
        subtracts a template, and the residual left behind is set by how \
        precisely each slice can be located in time — which the sample period \
        bounds. 1000 Hz is the ordinary default; the published benchmark used \
        5000 Hz, which is in scenarios/paper-default.json.
        """
    )

    // MARK: Sources

    static let generator = HelpTopic(
        title: "EEG generator",
        summary: """
        How the background EEG is built, and — this is the part that bites — \
        where its spatial structure comes from.
        """,
        options: [
            .init(name: "Grouiller (spatial)", detail: """
            The published model: band-limited signals with correlation imposed \
            between channels by a Gaussian kernel of SD 4 channels, applied \
            along the *channel ordering*. Fast, and the only setting that \
            reproduces the paper's numbers.
            """),
            .init(name: "Dipole (forward)", detail: """
            Dipolar sources inside a layered head model, projected to the \
            electrodes through a real lead field. Topographies then obey the \
            montage's actual geometry, and source-space ground truth becomes \
            available to write out.
            """)
        ],
        guidance: """
        Pick Dipole for anything that reads topography — ICA, PCA, source \
        localization, topography-gated OBS, any claim about spatial rank. Under \
        Grouiller, neighbouring *channels* are correlated rather than \
        neighbouring *electrodes*, so those methods are being scored against a \
        field no head produces. Pick Grouiller when you need comparability with \
        the published benchmark, or when the spatial dimension genuinely does \
        not enter the question.
        """,
        reference: "Grouiller et al. (2007), NeuroImage 38(1):124-137"
    )

    static let targetAmplitude = HelpTopic(
        title: "Target amplitude",
        summary: """
        The generated EEG is scaled by one global factor so its standard \
        deviation lands on this value.
        """,
        guidance: """
        It is the denominator of every SNR the simulator reports, so changing it \
        rescales all of them. 10.9 µV is the paper's measured value and the \
        reason its reported SNRs are comparable to EVA's — leave it there unless \
        you are deliberately modelling a different recording.
        """
    )

    static let sourceCount = HelpTopic(
        title: "Source count",
        summary: """
        How many dipolar generators produce the background EEG.
        """,
        guidance: """
        This sets the true spatial rank of the brain signal, which is the number \
        every decomposition method is implicitly trying to find. A handful of \
        sources gives ICA a well-posed problem; dozens make the mixture \
        effectively full-rank and any fixed component count arbitrary. Raise it \
        when you want to show a method failing on an under-determined mixture.
        """
    )

    static let radiusFraction = HelpTopic(
        title: "Radius fraction",
        summary: """
        How deep the sources sit, as a fraction of the brain-shell radius. 1.0 \
        is the shell surface; 0 is the centre of the head.
        """,
        guidance: """
        Depth controls topographic focality, and focality is what most \
        separation methods actually key on. At the default 0.85 the sources sit \
        just under the cortical surface and produce tight, well-localized \
        topographies. Push it toward 0.3-0.5 for deep sources: the scalp \
        patterns broaden, overlap, and become much harder to separate — which is \
        the honest test of a localization or ICA claim.
        """
    )

    static let orientation = HelpTopic(
        title: "Source orientation",
        summary: """
        The direction each dipole points, relative to the local radial \
        direction (straight out toward the scalp).
        """,
        options: [
            .init(name: "Radial", detail: """
            Every source points outward. Produces the classic single-peak \
            topography directly over the source — the easiest possible case.
            """),
            .init(name: "Tangential", detail: """
            Sources lie in the plane of the surface, alternating between the two \
            tangent directions. Produces dipolar two-lobed topographies with the \
            zero-crossing *over* the source, which is where naive \
            peak-finding localizers go wrong.
            """),
            .init(name: "Mixed", detail: """
            Cycles through radial, the two tangents, and oblique combinations. \
            The realistic default: a real cortex has all of these at once.
            """),
            .init(name: "Free", detail: """
            Deterministic oblique orientations with non-zero x, y and z on every \
            source. No orientation is privileged, so a fitter that assumes \
            radial or fixed orientation has nowhere to hide.
            """)
        ],
        guidance: """
        Use Tangential or Free to stress-test localization. Radial flatters \
        almost everything, so a method that only works there has not been tested.
        """
    )

    static let sourceMotion = HelpTopic(
        title: "Source motion",
        summary: """
        Rotates the first source by this many degrees partway through the \
        recording, instead of holding it still for the whole run.
        """,
        guidance: """
        Zero is a static source. Any non-zero value breaks the stationarity \
        assumption that ICA and every fixed spatial filter rest on: the mixing \
        matrix is no longer constant, so a filter estimated on the first half is \
        wrong for the second. That is the point — it is how you find out whether \
        a pipeline notices.
        """
    )

    static let shells = HelpTopic(
        title: "Head model shells",
        summary: """
        The concentric conductivity layers the forward model solves through.
        """,
        options: [
            .init(name: "3-shell", detail: """
            Brain / skull / scalp at 72, 79 and 85 mm with conductivities \
            0.33 / 0.0042 / 0.33 S/m — the classic model used across the \
            three-sphere validation literature.
            """),
            .init(name: "4-shell", detail: """
            The same three, plus a thin cerebrospinal-fluid layer at 74 mm \
            with conductivity 1.79 S/m. CSF is thin and highly conductive, and \
            it changes how the skull's insulation shapes the surface field.
            """)
        ],
        guidance: """
        Use 4-shell when the exercise is about the head model itself — \
        source-informed filters such as PCA-S are sensitive to exactly this \
        geometry difference, and the Rusiniak PCA-S paper's model carries the \
        CSF layer. The two differ only by that layer, so generating with one and \
        correcting with the other is a clean, controlled model-mismatch \
        experiment.
        """,
        reference: "Rusiniak et al. (2022); CSF conductivity from Baumann et al. (1997)"
    )

    static let reference = HelpTopic(
        title: "Reference",
        summary: """
        The reference the simulated potentials are expressed against.
        """,
        options: [
            .init(name: "Average", detail: """
            Each sample has the across-channel mean subtracted, as an \
            average-referenced recording does. Rank drops by one, which every \
            downstream decomposition sees.
            """),
            .init(name: "Infinity", detail: """
            Potentials as computed by the forward model, against a reference at \
            infinity. Physically the cleanest, but not what an amplifier records.
            """)
        ],
        guidance: """
        Match this to whatever your pipeline expects. Average is the safe \
        default because it is what real files usually carry; Infinity is the one \
        to use when you are validating a forward or inverse solution and want the \
        rank-reduction step out of the way.
        """
    )

    static let leadFieldTerms = HelpTopic(
        title: "Lead-field terms",
        summary: """
        Number of Legendre series terms used to evaluate the multi-shell forward \
        solution. A numerical setting, not a physiological one.
        """,
        guidance: """
        The series converges more slowly the closer a source sits to the brain \
        shell boundary, so shallow sources need more terms. 100 is comfortably \
        converged at the default radius fraction of 0.85. Raise it if you push \
        sources very close to the surface and see topographies that look \
        rippled; there is no accuracy left to gain otherwise, only run time.
        """
    )

    static let electrodeJitter = HelpTopic(
        title: "Electrode jitter",
        summary: """
        Perturbs each electrode's angular position by this many degrees before \
        computing the forward solution.
        """,
        guidance: """
        Zero gives every electrode its nominal, exactly-known position. That is \
        an unrealistically generous assumption for anything that uses electrode \
        coordinates — surrogate BCG models, source localization, template \
        montages — because in a real cap nobody knows where the electrodes are to \
        better than a few degrees. A few degrees of jitter is the difference \
        between measuring a method and measuring its best case.
        """
    )

    // MARK: Background

    static let alpha = HelpTopic(
        title: "Alpha modulation",
        summary: """
        Alpha-band amplitude swings between the low and high values on a sine of \
        the given period, modelling a subject opening and closing their eyes.
        """,
        guidance: """
        The default 10 → 30 µV over a 40 s cycle is the paper's eyes-open / \
        eyes-closed model. Its real use is as a *non-stationarity you know the \
        answer to*: any method that assumes stationary background — most spatial \
        filters — should visibly struggle here, and if yours does not, check \
        that it is doing anything at all.
        """
    )

    static let bandAmplitudes = HelpTopic(
        title: "Band amplitudes",
        summary: """
        Per-band amplitude of the background EEG, before the whole signal is \
        rescaled to the target amplitude.
        """,
        guidance: """
        These set the *shape* of the background spectrum; the target amplitude \
        sets its overall size. Alpha is left blank because it is driven by the \
        eyes-open/closed cycle instead. Flattening the high bands makes filter \
        and wavelet demonstrations much less interesting, since there is nothing \
        left up there to remove.
        """
    )

    // MARK: Gradient

    static let clockOffset = HelpTopic(
        title: "Clock offset",
        summary: """
        Timing drift between the EEG amplifier's clock and the scanner's, in \
        microseconds per second.
        """,
        guidance: """
        This is the single most important knob on this tab. Template subtraction \
        assumes every slice artifact lands at the same place relative to the \
        sample grid; the clock drift means it does not, and the mismatch is what \
        survives correction. Set it to 0 and average artifact subtraction looks \
        perfect — which is exactly why no honest benchmark uses 0. The default \
        152 µs/s is what the paper measured on their own rig.
        """
    )

    static let slowModulation = HelpTopic(
        title: "Slow modulation",
        summary: """
        Slowly varying gradient amplitude, as a fraction of the mean, on a 200 s \
        sine — the drift a real artifact shows as the subject settles and the \
        hardware warms.
        """,
        guidance: """
        It is what makes a *fixed* template insufficient, and therefore what \
        separates methods that adapt their template over time from methods that \
        do not. The paper used 10% and swept 0-25%.
        """
    )

    static let scanWindow = HelpTopic(
        title: "Pre-scan and post-scan",
        summary: """
        Quiet time before the scanner starts and after it stops.
        """,
        guidance: """
        The gradient artifact is absent in these windows. The ballistocardiogram \
        is not — it comes from pulsatile motion in the *static* B0 field, which \
        is on the whole time the subject is in the bore. So these windows look \
        like clean EEG and are already contaminated, which is both a good thing \
        to show a class and a good reason not to trust "just look at the trace" \
        as a way of judging a correction.
        """
    )

    // MARK: Cardiac

    static let bcgAmplitude = HelpTopic(
        title: "BCG amplitude",
        summary: """
        Mean peak-to-peak amplitude of the ballistocardiogram on the \
        strongest channel.
        """,
        guidance: """
        This is the contamination level, and it scales with field strength: \
        roughly 10 µV at low field up through 200 µV at 3T and beyond. It is the \
        natural axis to sweep — it answers "at what point does my correction stop \
        working", which is usually the question worth asking.
        """
    )

    static let amplitudeJitter = HelpTopic(
        title: "Amplitude jitter",
        summary: """
        Beat-to-beat variation in BCG amplitude. Each beat averages the previous \
        beat's amplitude with a fresh draw of this SD, so the variation is \
        correlated rather than independent.
        """,
        guidance: """
        Zero makes every beat the same height, which is the condition template \
        subtraction is built for and never encounters. Raising it is how you \
        find out whether a method fits per-beat amplitude or just subtracts a \
        mean.
        """
    )

    static let heartRateVariability = HelpTopic(
        title: "Heart-rate variability",
        summary: """
        Beat-to-beat variation in the RR interval, as a fraction of it — built \
        from respiratory sinus arrhythmia, Mayer waves near 0.1 Hz, and a little \
        uncorrelated noise.
        """,
        guidance: """
        The paper's model has none: heart rate is a smooth 60 s sine, so RR walks \
        monotonically and no beat ever surprises anything downstream. A resting \
        adult sits at 3-8%, which is where the default is. Set it to 0 to restore \
        the paper's exact timing for benchmark comparability — but not to \
        evaluate anything that assumes a stable rate, because that assumption \
        will hold perfectly and tell you nothing.
        """
    )

    static let respiration = HelpTopic(
        title: "Respiration",
        summary: """
        Breathing rate. 0.25 Hz is 15 breaths per minute.
        """,
        guidance: """
        It drives three things at once: respiratory sinus arrhythmia in the beat \
        timing, a few percent of amplitude modulation on the ECG, and slow \
        baseline wander. It is the common cause behind several signals, so a \
        method that treats them as independent will mis-model it.
        """
    )

    static let bcgSpatialModel = HelpTopic(
        title: "BCG spatial model",
        summary: """
        Where the artifact's topography and its spatial rank come from.
        """,
        options: [
            .init(name: "Channel index", detail: """
            One template scaled by 0.35 + 0.65·cos(2π·channel/N) — a function of \
            the channel's *index*, not of where the electrode sits. Rank one, \
            plus a little approximate rank from per-channel latency. Kept as the \
            default so the published benchmark reproduces unchanged.
            """),
            .init(name: "Physical generators", detail: """
            Four distinct physical events with their own topographies, delays and \
            per-beat weights: aortic flow, left and right superficial temporal \
            vessel pulsation, and head rotation in the static field. Rank emerges \
            from the physics instead of being asserted.
            """)
        ],
        guidance: """
        Choose Physical generators for any comparison involving PCA, ICA, OBS \
        component counts, or topography-gated correction. Against a rank-one \
        artifact, OBS with four components is trivially near-optimal and PCA-S, \
        ICA-S and OBS become indistinguishable — the comparison you wanted to run \
        is the one the channel-index model cannot resolve. Real subjects show 4-8 \
        principal components, mean 5.7.
        """,
        reference: "Rusiniak et al. (2022), component counts; FMRIB OBS default of 4"
    )

    static let ecgMorphologyJitter = HelpTopic(
        title: "Beat-to-beat variation",
        summary: """
        Gives every ECG complex its own P, QRS and T amplitudes and its own PR \
        and QT timing, instead of stamping one identical waveform at each beat.
        """,
        options: [
            .init(name: "0 (default)", detail: """
            Every complex is a pixel-identical copy. Any template matcher gets a \
            perfect score, because the template it is looking for is literally \
            the one that was used to build the signal.
            """),
            .init(name: "0.05 - 0.10", detail: """
            Reads as a recorded trace. P and T amplitudes take the full fraction; \
            the QRS takes 30% of it, because fast depolarization through fixed \
            conduction tissue is the most reproducible feature on a real strip.
            """),
            .init(name: "Above ~0.20", detail: """
            Starts to look arrhythmic rather than merely alive. Useful if that is \
            what you want to model, misleading if it is not.
            """)
        ],
        guidance: """
        Turn it on whenever the ECG is an *input* to something being evaluated — \
        R-peak detection, BCG timing, any correction driven by detected beats. \
        Leave it at 0 when you need to compare against previously published \
        numbers, all of which were measured against the stamped waveform.
        """,
        reference: "Morphology model: McSharry et al. (2003), IEEE TBME 50(3):289-294"
    )

    static let ecgNoise = HelpTopic(
        title: "ECG sensor noise",
        summary: """
        Broadband noise layered onto the ECG channel, in µV RMS — standing in for \
        chest-wall EMG and electrode noise.
        """,
        guidance: """
        5-20 µV against a 1 mV R wave is realistic. This is what makes R-peak \
        detection a task rather than an argmax: with a noiseless trace, the \
        crudest possible detector scores perfectly and you learn nothing about \
        the one you actually intend to ship. Defaults to 0 so existing detection \
        benchmarks are unchanged.
        """
    )

    static let ecgAmplitude = HelpTopic(
        title: "R-peak amplitude",
        summary: """
        Height of the R wave. The other waves scale with it: P is 25% of it, Q \
        −17%, S −25%, T 40%.
        """,
        guidance: """
        About 1 mV is the usual scale for a scalp-lead ECG through an EEG \
        amplifier — roughly a hundred times the EEG it sits beside, which is why \
        it needs its own display scale to look like anything.
        """
    )

    static let motionSensor = HelpTopic(
        title: "Motion sensor channel",
        summary: """
        A modelled motion sensor — carbon-wire loop, piezo — that sees the \
        across-channel mean BCG through a saturating nonlinearity.
        """,
        guidance: """
        The nonlinearity is the entire point. A reference channel that were a \
        linear copy of the artifact would make regression-based correction \
        trivially perfect and tell you nothing about how it behaves on real \
        hardware. Turn this on only if you are evaluating reference-channel \
        methods; otherwise it is an extra PNS trace that looks like a \
        malfunctioning sensor, because a saturating sensor is what it is.
        """
    )

    static let motionSensorGain = HelpTopic(
        title: "Sigmoid gain",
        summary: """
        How hard the modelled sensor saturates. Dimensionless: it applies to the \
        mean BCG normalized by its own RMS, so the amount of saturation does not \
        ride on the BCG amplitude.
        """,
        guidance: """
        At the default 1.0 the peaks compress to 92% of full scale without a \
        single sample pinning to the rail, and they do it identically at 10 µV and \
        at 200 µV of BCG — which is what lets you sweep BCG amplitude without \
        secretly sweeping how much information the reference carries. Below about \
        0.5 the channel is nearly a linear copy; above about 1.5 it starts \
        clipping and stops being a nonlinearity at all.
        """
    )

    // MARK: Ocular

    static let ocularSpatialModel = HelpTopic(
        title: "Ocular spatial model",
        summary: """
        How blink and eye-movement topographies are produced.
        """,
        options: [
            .init(name: "Heuristic", detail: """
            Hand-drawn frontal topographies: immediately recognizable, and \
            explicitly ad hoc.
            """),
            .init(name: "Dipole", detail: """
            Two corneo-retinal dipoles in a homogeneous conductor, \
            average-referenced and normalized at the scalp. Still simplified, but \
            physically derived rather than asserted.
            """)
        ],
        guidance: """
        Heuristic is fine for teaching — the pattern is meant to be obvious. Use \
        Dipole whenever an ocular-removal method is being scored, for the same \
        reason as the BCG spatial model: a topography that was drawn rather than \
        derived can accidentally match, or accidentally defeat, whatever the \
        method assumes.
        """
    )

    // MARK: Muscle and defects

    static let clipping = HelpTopic(
        title: "Clipping",
        summary: """
        Hard-limits every channel at ± this value, as an amplifier at the end of \
        its input range does.
        """,
        guidance: """
        Clipping destroys information rather than adding a signal, so nothing \
        recovers it — which makes this the right way to check that a pipeline \
        *detects and reports* saturated segments instead of quietly filtering \
        them and producing a confident, wrong answer.
        """
    )

    static let lineNoise = HelpTopic(
        title: "Line noise",
        summary: """
        Mains interference at 50 or 60 Hz, with its harmonics.
        """,
        guidance: """
        Match it to the region you are modelling: 60 Hz in the Americas, 50 Hz \
        across most of Europe and Asia. It matters beyond realism — a notch \
        filter at the wrong frequency leaves the interference untouched *and* \
        puts a hole in the spectrum, which is a failure worth being able to \
        reproduce on demand.
        """
    )

    static let impedance = HelpTopic(
        title: "Impedance",
        summary: """
        Records a per-electrode impedance measurement in the file, the way a real \
        EGI system does, and scatters values around the typical figure.
        """,
        guidance: """
        Impedance is a property of the electrodes, not of the samples, and it is \
        written to the clean file as well as the contaminated one. That is not an \
        oversight: it means the ground-truth file can show a poor electrode \
        alongside perfect samples, which is exactly the lesson — the measurement \
        was taken before anything was recorded, and a good impedance reading does \
        not promise good data.
        """
    )

    static let badChannelCount = HelpTopic(
        title: "Bad channel count",
        summary: """
        Spoils this many channels, chosen deterministically from the seed rather         than named one by one.
        """,
        guidance: """
        The interesting question is almost never *which* electrode failed — it is         how a pipeline behaves with some number of them failing. A count turns         "how many bad channels before interpolation stops being trustworthy" into         a two-minute sweep instead of an afternoon of editing scenario files. The         same seed always picks the same channels, and channels a scenario named         explicitly are kept and counted separately.
        """
    )

    static let badChannelDefect = HelpTopic(
        title: "Defect kind",
        summary: """
        What is wrong with the counted channels. Each failure mode defeats a         different naive analysis, which is what makes them worth having as         separate kinds.
        """,
        options: [
            .init(name: "One of each", detail: """
            Deals the kinds out in turn, so five bad channels give one of every             failure mode. The right choice when the question is whether a             detector catches all of them.
            """),
            .init(name: "Flat", detail: """
            Dead or shorted — near-zero signal. Reads *excellent* on impedance,             because the electrolyte path is too good.
            """),
            .init(name: "Noisy", detail: """
            High-impedance contact: broadband noise swamping the EEG. The one             case where impedance correctly predicts bad data.
            """),
            .init(name: "Drift", detail: """
            A slowly failing contact. Survives a notch filter, defeats amplitude             thresholds, and is fixed by a high-pass — so it is the one that             reveals whether a pipeline high-passes before it thresholds.
            """),
            .init(name: "Pop", detail: """
            Intermittent electrode pops: sudden steps that decay back. Bad             enough to matter, brief enough that whole-channel rejection is the             wrong response.
            """),
            .init(name: "Line", detail: """
            Heavy mains pickup on one channel only, which makes it a clean             demonstration that a notch filter is a per-channel decision. Needs             line noise switched on to do anything.
            """)
        ]
    )

    static let badChannelPlacement = HelpTopic(
        title: "Placement",
        summary: """
        Which electrodes the counted bad channels are allowed to land on.
        """,
        options: [
            .init(name: "Anywhere", detail: """
            Any electrode. The realistic default — electrodes fail where they             fail.
            """),
            .init(name: "Eye electrodes only", detail: """
            The periocular sites: the electrodes that see the most blink,             identified from the montage's own blink topography rather than from             a list of 10-20 names, so it works on an imported 256-channel net             too. On a 10-20 cap this is Fp1 and Fp2.
            """),
            .init(name: "Avoid eye electrodes", detail: """
            Everywhere except those, so ocular detection is left intact and             whatever else you are testing is the only thing degraded.
            """)
        ],
        guidance: """
        "Eye electrodes only" is the setting with teeth. Every threshold-based         blink and eye-movement detector reads the periocular sites and compares         them to a µV threshold, so a flat one silently stops reporting blinks         and a noisy one reports hundreds — and in the flat case the artifacts are         still in the recording, on every other channel, with the truth file         listing exactly when they happened. A pipeline that reports zero blinks         and proceeds confidently has just failed in the way that is hardest to         notice on real data.
        """
    )

    static let highImpedanceCount = HelpTopic(
        title: "High-impedance channels",
        summary: """
        Gives this many channels a poor impedance reading while leaving their         data alone. Never overlaps the bad channels.
        """,
        guidance: """
        This is the other half of what impedance screening gets wrong. A flat,         bridged electrode reads *excellent* because the electrolyte path is too         good; these channels read poor and carry perfectly usable EEG. Between         them the two cases show that impedance is a useful screen and not a         proxy for data quality. The only real consequence in the samples is the         Johnson-Nyquist thermal noise the impedance itself implies, which the         contact-noise model already generates from the recorded value — nothing         artificial is added.
        """
    )

    static let eogDefects = HelpTopic(
        title: "Eye (EOG) electrodes",
        summary: """
        Spoils the dedicated VEOG and HEOG traces, which are separate physical         electrodes from the EEG montage and fail separately from it.
        """,
        guidance: """
        This breaks something different from a bad periocular EEG channel.         Pipelines that regress the EEG against a recorded EOG produce a         confident, wrong correction when the reference itself is bad, because         nothing in the regression can tell a dead reference from an eye that         never moved — it subtracts nothing and reports success. Flat is the         quiet failure; noisy is the loud one, where the regression subtracts         noise from every channel it touches. The traces only exist when blinks         or eye movements are enabled.
        """
    )

    static let badChannels = HelpTopic(
        title: "Bad channels",
        summary: """
        Deliberately spoils individual channels, each with a named defect \
        (noisy, drifting, flat, and so on).
        """,
        guidance: """
        The channel numbers and their defects are written to the truth sidecar, \
        so a bad-channel detector can be scored exactly rather than judged by \
        eye. Every automatic detector has a threshold, and the only way to find \
        out where it sits is to hand it a file whose answer you already know.
        """
    )

    // MARK: ERP

    static let targetFraction = HelpTopic(
        title: "Target fraction",
        summary: """
        Proportion of trials that are targets (oddballs); the rest are standards.
        """,
        guidance: """
        In an oddball design this fraction *is* the manipulation — the P300 \
        appears because targets are rare. 0.2 is the usual value. Push it toward \
        0.5 and the effect you are trying to measure largely goes away, which is \
        worth seeing once. It also sets how many target trials the average is \
        built from, and therefore how noisy the ERP is.
        """
    )

    static let erpLatency = HelpTopic(
        title: "Peak latency",
        summary: """
        When the ERP component peaks after stimulus onset.
        """,
        guidance: """
        0.3 s is a P300. Trials are jittered around this value, so the averaged \
        peak is always lower and broader than the single-trial peak — which is \
        the smearing that single-trial analysis exists to undo, and a good thing \
        to be able to demonstrate with the true latency known.
        """
    )

    // MARK: Sweep and group

    static let sweepParameter = HelpTopic(
        title: "Sweep parameter",
        summary: """
        Which single setting varies across the generated runs. Everything else         is held at the Generate tab's values.
        """,
        guidance: """
        A sweep is only interpretable if exactly one thing moves, which is what         this enforces. The most informative axes are the ones that set how hard         the problem is — BCG amplitude, gradient clock offset, QRS jitter —         because the result is a curve showing where a method stops working,         rather than a single number saying whether it worked once.
        """
    )

    static let homogeneous = HelpTopic(
        title: "Homogeneous cohort",
        summary: """
        Draws every subject from identical settings — same head, same electrode         placement, same alpha, same artifact severity.
        """,
        guidance: """
        This is a negative control, not a shortcut. There is genuinely no         between-subject structure in a homogeneous cohort, so a group-level         method that reports a significant effect on one is finding noise, and         you have just measured its false-positive behaviour. Turn it off for         anything meant to resemble a real study.
        """
    )

    static let betweenSubjectSDs = HelpTopic(
        title: "Between-subject SDs",
        summary: """
        How much each property varies across the cohort, drawn independently         per subject and recorded in the participants table.
        """,
        options: [
            .init(name: "Head radius", detail: """
            Adult head size varies by several percent. It matters more than it             sounds: it changes the forward model, so every subject's topography             differs even for identical sources — which is precisely what defeats             a group analysis that assumes a shared spatial filter.
            """),
            .init(name: "Placement", detail: """
            Cap placement is never twice the same, in degrees of electrode             position.
            """),
            .init(name: "Alpha, BCG, impedance", detail: """
            Background amplitude, artifact severity and recording quality — the             three axes along which real subjects differ most, and the reason             some subjects in any cohort are simply harder to clean.
            """),
            .init(name: "ERP effect", detail: """
            Between-subject spread of the condition difference, as a fraction of             the population effect. This is the variance component a             mixed-effects model exists to estimate, so it is the one to set             deliberately when testing a group statistic.
            """)
        ]
    )

    // MARK: Output

    static let writeSources = HelpTopic(
        title: "Source-space ground truth",
        summary: """
        Writes each dipole's true time course, in nA·m, as a separate file \
        alongside the recording. Requires the dipole generator.
        """,
        guidance: """
        This is what lets a source-localization result be *scored* rather than \
        admired: you have the true position, orientation and moment of every \
        source, so error is a number instead of an impression.
        """
    )
}
