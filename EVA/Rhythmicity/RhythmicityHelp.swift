//
//  RhythmicityHelp.swift
//  EVA
//

import SwiftUI

/// Primary scientific source for EVA's LAVI, ABBA, WTPL, and rhythmic-burst
/// workflows. Keeping the citation and URLs in code prevents UI help and export
/// documentation from drifting apart.
enum RhythmicityReferences {
    static let paperCitation = "Karvat, G., Crespo-García, M., Vishne, G., Anderson, M. C., & Landau, A. N. (2026). Universal rhythmic architecture uncovers two modes of neural dynamics. Nature Communications, 17, 7024. https://doi.org/10.1038/s41467-026-73553-8"
    static let repositoryCitation = "Karvat, G., & Vishne, G. (2026). LAVI code as used for the manuscript ‘Universal rhythmic architecture uncovers two modes of neural dynamics’ (Zenodo 19581527). https://doi.org/10.5281/zenodo.19581527"
    static let paperURL = URL(string: "https://doi.org/10.1038/s41467-026-73553-8")!
    static let repositoryURL = URL(string: "https://doi.org/10.5281/zenodo.19581527")!
}

enum RhythmicityHelpTopics {
    static let overview = HelpTopic(
        title: "About Rhythmicity Explorer",
        summary: "Rhythmicity Explorer measures phase persistence rather than signal power. Bands mode uses LAVI and ABBA to find individualized sustained and transient frequency regions; Event-related mode maps within-trial phase persistence (WTPL); Bursts mode describes short neural-rhythm episodes. None of these results are artifact labels.",
        options: [
            .init(name: "Bands", detail: "Computes a recording-level LAVI spectrum and uses ABBA to divide it into relatively sustained and transient regions."),
            .init(name: "Event-related", detail: "Computes WTPL in retained epochs, with raw, baseline-relative, and condition-difference views."),
            .init(name: "Bursts", detail: "Finds high-power episodes and summarizes their duration, rhythmicity, occupancy, and band membership.")
        ],
        guidance: "Use Bands to define subject-specific frequency regions, Event-related for time-locked phase persistence, and Bursts to characterize intermittent episodes. Interpret LAVI/WTPL separately from power and ITPC.",
        reference: "\(RhythmicityReferences.paperCitation)\n\nReference implementation: \(RhythmicityReferences.repositoryCitation)",
        resources: [
            .init(title: "Open the paper", url: RhythmicityReferences.paperURL),
            .init(title: "Open the archived LAVI implementation", url: RhythmicityReferences.repositoryURL)
        ]
    )

    static let mode = HelpTopic(
        title: "Analysis mode",
        summary: "The three modes answer different questions and produce different units; switching modes does not convert one result into another.",
        options: overview.options,
        guidance: "Choose the mode that matches the scientific claim you intend to make. A power burst, persistent within-trial phase, and a sustained recording-level band are related but not interchangeable.",
        reference: RhythmicityReferences.paperCitation,
        resources: [.init(title: "Open the paper", url: RhythmicityReferences.paperURL)]
    )

    static let significance = HelpTopic(
        title: "LAVI significance",
        summary: "Controls whether ABBA regions receive inferential labels relative to recording-matched surrogate noise.",
        options: [
            .init(name: "Paper 2026", detail: "Fits the aperiodic spectrum and computes 200 deterministic IAAFT surrogates per channel. The fifth-lowest and fifth-highest values form the two-sided α=.05 ribbon at each frequency."),
            .init(name: "Exploratory", detail: "Computes LAVI and median-defined ABBA regions without surrogate inference. Regions remain useful for exploration but are not labeled significant or nonsignificant.")
        ],
        guidance: "Use Paper 2026 for confirmatory or reported analyses. Exploratory mode is much faster and appropriate while checking channels, ranges, or preprocessing.",
        reference: RhythmicityReferences.paperCitation,
        resources: [.init(title: "Open the paper", url: RhythmicityReferences.paperURL)]
    )

    static let dataSelection = HelpTopic(
        title: "Data selection",
        summary: "Determines which samples contribute evidence. Valid LAVI lag pairs never cross a selection, epoch, artifact, or nonfinite-data boundary.",
        guidance: "Use the whole recording for stable subject-level bands. Use a selected or visible range only when that interval is the intended analysis unit and contains enough clean cycles at the lowest frequency."
    )

    static let channels = HelpTopic(
        title: "Channel scope",
        summary: "LAVI, WTPL, and burst measurements are computed per channel; this setting chooses the channels included in the run.",
        guidance: "Use Current while iterating, a Named Set for a planned ROI, or all usable channels for topography and export. Interpolated channels remain identified in provenance."
    )

    static let wtplDisplay = HelpTopic(
        title: "WTPL display",
        summary: "Raw WTPL is local within-trial phase persistence from 0 to 1. ΔWTPL subtracts each frequency's mean over the explicit baseline. Neither quantity is ITPC or power.",
        guidance: "Use Raw for absolute phase persistence. Use ΔWTPL when the scientific question concerns change from a complete, prespecified baseline."
    )

    static let wtplBaseline = HelpTopic(
        title: "ΔWTPL baseline",
        summary: "The complete requested interval must exist in every contributing epoch. EVA reports ΔWTPL unavailable instead of silently shortening the baseline.",
        guidance: "Choose a prestimulus interval that is fully contained in the retained epochs and document it with the exported settings."
    )

    static let burstThresholds = HelpTopic(
        title: "Burst thresholds",
        summary: "Peak threshold finds candidate power maxima; the power boundary determines where a burst begins and ends around each peak. Both are frequency-specific percentiles.",
        guidance: "The paper workflow uses P90 peaks and P75 boundaries. Raising P90 finds fewer, stronger bursts; raising P75 shortens their measured duration.",
        reference: RhythmicityReferences.paperCitation,
        resources: [.init(title: "Open the paper", url: RhythmicityReferences.paperURL)]
    )

    static let burstBoundary = HelpTopic(
        title: "Burst boundary",
        summary: "Chooses whether burst duration is defined by normalized power or by an explicit WTPL cutoff.",
        options: [
            .init(name: "Power percentile", detail: "Expands around the P90 peak until power falls below the selected boundary percentile; P75 matches the paper workflow."),
            .init(name: "WTPL threshold", detail: "Defines the interval by within-trial phase persistence instead of power, useful when oscillatory continuity is the duration of interest.")
        ],
        guidance: "Use power boundaries for direct paper-style burst detection. Use WTPL only when your analysis explicitly defines a burst by phase persistence."
    )

    static let bandSource = HelpTopic(
        title: "Band source",
        summary: "Assigns each WTPL cell or detected burst to frequency bands without changing the underlying LAVI, WTPL, or power calculation.",
        guidance: "Use a fresh Rhythmicity Explorer band set for subject-specific sustained/transient identity; use saved preferences or EVA defaults when consistent group-wide boundaries are required."
    )
}

struct RhythmicityHelpView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Rhythmicity Explorer Help")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    article("What LAVI measures", "The Lagged-Angle Vector Index measures how consistently a signal's complex time-frequency representation maintains its phase relationship over a fixed lag. Values nearer 1 mean higher rhythmicity. LAVI is invariant to nonzero amplitude scaling and is not power, oscillation strength, or evidence of a larger neural response.")
                    article("Sustained and transient bands", "ABBA divides each channel's LAVI profile around its median. Above-median regions are called sustained; below-median regions are called transient. These are temporal-dynamics descriptions, not functional diagnoses. Band borders remain channel- and recording-specific.")
                    article("Matched surrogate ribbon", "Paper 2026 inference fits the aperiodic spectrum, generates 200 seed-controlled IAAFT surrogate signals, and uses the fifth-lowest and fifth-highest LAVI at each frequency as the two-sided α=.05 limits. Crossing a limit means significant relative to matched surrogate noise—not that an oscillation is necessarily real or functionally meaningful.")
                    article("Unanchored or nonsignificant", "Canonical names are assigned only when a sustained peak exists between 6 and 14 Hz. Otherwise EVA keeps every region and labels it Unanchored. A nonsignificant region is different from one for which significance was not computed, and both are different from insufficient valid duration.")
                    article("Data quality and duration", "Lag pairs never cross epoch, excluded-artifact, or nonfinite-data boundaries. Below 3 Hz, several minutes of usable data are recommended. Above roughly 40–45 Hz, at least 1 kHz sampling is recommended. Strong 50/60 Hz notches can distort neighboring rhythmicity; export records the processing information available to EVA.")
                    article("Metal acceleration", "Automatic mode uses the compiled Rhythmicity Metal kernel for workloads above EVA's measured crossover and otherwise uses the Double-precision Accelerate FFT path. Unsupported devices, allocation limits, or GPU command failures fall back to CPU and appear in the result warnings. Preferences can force CPU-only analysis. Exports and restored results report the backend and precision actually used.")
                    article("Saved results and staleness", "A completed Bands analysis is saved for this recording so its compact spectrum, bands, selection, and provenance can be inspected after reopening EVA. Source samples and surrogate waveforms are never saved. EVA checks the processed-signal revision, selection and channel context, method version, pinned upstream reference, and a content checksum. A mismatch is shown as stale and must be recomputed before the bands can be reused as current results.")
                    article("Using ABBA bands in Time-Frequency", "Use in Time-Frequency publishes the displayed channel's band borders for this recording session. Choose Rhythmicity Explorer in the Time-Frequency Band source picker to overlay borders and peaks and use those same ranges for ROI scalars. The overlay does not change ERSP or ITPC values, the selected-channel borders are stated when applied across an all-channel view, stale bands are refused, and saved user band preferences are never changed.")
                    article("Within-Trial Phase Locking (WTPL)", "Event-related mode measures whether phase persists from each time point to one cycle before and one cycle after it, independently inside every retained epoch. Raw WTPL ranges from 0 to 1. Higher values mean stronger local within-trial phase persistence; they do not mean greater power or stronger phase alignment between trials.")
                    article("Raw WTPL, ΔWTPL, and conditions", "Raw WTPL is the condition mean at every frequency and time. ΔWTPL subtracts that frequency's mean over the explicit baseline. EVA uses the complete requested interval or reports it unavailable—it never silently shortens the baseline. A − B maps subtract condition means after each condition is computed. The Valid counts display shows how many trials support each cell; for A − B it shows the smaller count from the two conditions.")
                    article("WTPL is not ITPC", "WTPL compares nearby times within each trial, then averages those trial-level values. ITPC compares different trials at the same time and frequency. A rhythmic response whose phase varies between trials can have high WTPL and low ITPC; a stimulus-aligned phase reset can raise ITPC while local WTPL changes around the reset. Interpret and report the two measures separately.")
                    article("WTPL edges and export", "A cell is invalid when the Morlet coefficient or either signed one-cycle lag is unavailable. Invalid cells stay NaN and are hatched rather than replaced with zero. Event-related exports include raw WTPL, ΔWTPL, valid-count NPY maps, band × window scalar CSV, axes, method settings, processing provenance, and warnings. Time-Frequency also offers WTPL as an optional shortcut using this same engine.")
                    article("Rhythmic bursts", "Bursts mode finds two-dimensional power peaks above each frequency's 90th percentile, refines their intervals with the 75th-percentile power boundary or an explicit WTPL threshold, and merges overlapping peaks only when their frequencies are close. The map, linked waveform, and table report duration, relative power, WTPL, rate, occupancy, and band consistency.")
                    article("Burst bands and safety", "Choose EVA defaults, saved preferences, or a fresh channel-specific LAVI/ABBA result for burst band assignment. Only the LAVI/ABBA source can carry sustained/transient identity. Rhythmic bursts describe neural dynamics: they are not artifact candidates, never enter cleaning automatically, and Bursts mode intentionally has no clean or apply action.")
                    article("Burst export", "Exports contain a burst CSV, band-summary CSV, normalized-power and WTPL NPY maps, axis sidecars, warnings, and a versioned manifest with the pinned reference, parameters, selection, signal revision, and processing history. The manifest explicitly labels the domain as neural-rhythmicity analysis rather than artifact rejection.")
                    article("Citation", "\(RhythmicityReferences.paperCitation)\n\n\(RhythmicityReferences.repositoryCitation)\n\nEVA's behavioral reference is the authors' LAVI repository at commit 78386879eeb8cf9be06a1edfa6917c91b2d0d2ba. Report EVA's exported method version, parameters, seed, source revision, and warnings.")
                    Link("Open the paper", destination: RhythmicityReferences.paperURL)
                    Link("Open-access full text", destination: URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/PMC13392403/")!)
                    Link("Authors' archived LAVI implementation", destination: RhythmicityReferences.repositoryURL)
                }
                .textSelection(.enabled)
                .padding(22)
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 600, idealHeight: 720)
    }

    private func article(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
