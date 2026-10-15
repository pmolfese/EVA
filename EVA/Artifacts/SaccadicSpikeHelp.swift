//
//  SaccadicSpikeHelp.swift
//  EVA
//

import Foundation

/// Scientific sources for the MAAC-1 detector and the canonical saccadic-spike
/// scalp template. Keeping these references in code gives the UI and future
/// exports a single source of truth.
enum SaccadicSpikeReferences {
    static let maacCitation = "Dien, J. (2024). Multi-Algorithm Artifact Correction (MAAC) procedure part one: Algorithm and example. Biological Psychology, 188, 108775. https://doi.org/10.1016/j.biopsycho.2024.108775"
    static let templateCitation = "Semlitsch, H. V., Anderer, P., Schuster, P., & Presslich, O. (1986). A solution for reliable and valid reduction of ocular artifacts, applied to the P300 ERP. Psychophysiology, 23(6), 695–703. https://doi.org/10.1111/j.1469-8986.1986.tb00696.x"
    static let maacURL = URL(string: "https://doi.org/10.1016/j.biopsycho.2024.108775")!
    static let templateURL = URL(string: "https://doi.org/10.1111/j.1469-8986.1986.tb00696.x")!
}

enum SaccadicSpikeHelpTopics {
    static let overview = HelpTopic(
        title: "About Saccadic Spike Potential",
        summary: "This MAAC-1 tool detects the brief biphasic voltage transient associated with saccades, estimates its scalp amplitude at each confirmed event, and removes only the canonical spike topography with a spatial filter. It does not remove the slower corneoretinal eye-movement artifact.",
        options: [
            .init(name: "Detect", detail: "Scans the Cz-referenced first derivative for VEOG-dominant candidates, confirms the expected 4/8 ms biphasic pattern, and enforces a 100 ms refractory interval."),
            .init(name: "Inspect", detail: "Review the preliminary and confirmed counts, critical threshold, detected event markers, and template scalp map before applying anything."),
            .init(name: "Use Detected SPs", detail: "Adds the confirmed events and spatial-filter result to EVA's artifact workflow so the correction remains reviewable and reversible.")
        ],
        guidance: "Run this before slower ocular correction when following the MAAC ordering. Verify the channel roles and topography; a large discrepancy between preliminary and confirmed counts can indicate unsuitable channels or thresholds.",
        reference: "Primary method: \(SaccadicSpikeReferences.maacCitation)\n\nCanonical ocular-artifact template lineage: \(SaccadicSpikeReferences.templateCitation)",
        resources: [
            .init(title: "Open the MAAC paper", url: SaccadicSpikeReferences.maacURL),
            .init(title: "Open the ocular-artifact paper", url: SaccadicSpikeReferences.templateURL)
        ]
    )

    static let template = HelpTopic(
        title: "Spatial template",
        summary: "The template supplies the scalp pattern removed at each confirmed saccadic-spike event; the event-specific amplitude is estimated from the recording.",
        options: [
            .init(name: "Canonical (recommended)", detail: "Maps EVA's bundled 33-channel saccadic-spike template to the recording montage by electrode position."),
            .init(name: "Session average", detail: "Builds a template from preliminary VEOG-dominant candidates in this recording. It can adapt to the session, but is more vulnerable to contamination by false candidates.")
        ],
        guidance: "Use Canonical unless the montage cannot be mapped or validation shows a consistently mismatched topography. The MAAC paper reports the file template as more reliable.",
        reference: SaccadicSpikeReferences.maacCitation,
        resources: [.init(title: "Open the MAAC paper", url: SaccadicSpikeReferences.maacURL)]
    )

    static let threshold = HelpTopic(
        title: "Detection threshold",
        summary: "Sets the robust-noise multiplier used by the derivative-domain candidate and confirmation gates. A recording-relative scale avoids assuming the same amplifier noise floor for every dataset.",
        guidance: "Higher σ values are more conservative and produce fewer candidates. Lower values increase sensitivity but can admit muscle, motion, or amplifier transients. Start at 5σ and use the counts, event timing, and scalp map for quality control. The fixed 100 µV maximum derivative safeguard remains in force.",
        reference: SaccadicSpikeReferences.maacCitation
    )

    static let channelRoles = HelpTopic(
        title: "Channel roles",
        summary: "Cz defines the reference-independent derivative; VEOG channels identify eye-dominant candidates; lower VEOG scales the template; HEOG channels are excluded from the spatial amplitude estimate.",
        options: [
            .init(name: "Cz", detail: "A single central channel. EVA auto-selects a channel named Cz or the electrode nearest the layout center."),
            .init(name: "VEOG / Lower VEOG", detail: "Vertical periocular channels used for candidate detection; Lower VEOG must be a subset used for scaling."),
            .init(name: "HEOG", detail: "Horizontal periocular channels excluded from the scalp-pattern amplitude fit so they do not dominate it.")
        ],
        guidance: "Entries are one-based channel numbers separated by commas. Confirm automatic assignments whenever channel labels or montage metadata are incomplete. Bad and interpolated channels are excluded automatically."
    )

    static let qualityControl = HelpTopic(
        title: "Quality control",
        summary: "Preliminary is the count after the VEOG-dominance scan; Confirmed is the subset with the expected biphasic timing and refractory spacing. Critical is the recording-specific derivative threshold used at confirmation.",
        guidance: "Inspect confirmed event markers against visible saccades and verify that the template map has an ocular/frontocentral pattern. Do not apply the result when the map is implausible or confirmed events align with non-ocular transients."
    )
}
