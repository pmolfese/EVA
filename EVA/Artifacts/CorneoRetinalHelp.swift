//
//  CorneoRetinalHelp.swift
//  EVA
//

import Foundation

enum CorneoRetinalReferences {
    static let maacCitation = "Dien, J. (2024). Multi-Algorithm Artifact Correction (MAAC) procedure part one: Algorithm and example. Biological Psychology, 188, 108775. https://doi.org/10.1016/j.biopsycho.2024.108775"
    static let maacURL = URL(string: "https://doi.org/10.1016/j.biopsycho.2024.108775")!
}

enum CorneoRetinalHelpTopics {
    static let overview = HelpTopic(
        title: "About Corneo-Retinal Dipole Correction",
        summary: "MAAC-2 removes the continuous scalp field caused by eye position. It derives horizontal and vertical CRD maps from HEOG/VEOG, refines their continuous amplitudes with reverse-EMCP regression, then subtracts horizontal before vertical.",
        options: [
            .init(name: "Analyze", detail: "Detects preliminary blink spans, estimates both CRD scalp maps, and reports their continuous correction amplitudes without changing the recording."),
            .init(name: "Use MAAC-2 Result", detail: "Adds a replayable whole-recording CRD correction to Clean Artifacts. Applying remains a separate, reversible step.")
        ],
        guidance: "Run MAAC-1 first and blink ICA afterward when following the MAAC order. This corrects slow eye-position fields; it does not correct the brief saccadic spike or the eyelid artifact itself.",
        reference: CorneoRetinalReferences.maacCitation,
        resources: [.init(title: "Open the MAAC paper", url: CorneoRetinalReferences.maacURL)]
    )

    static let channelRoles = HelpTopic(
        title: "CRD channel roles",
        summary: "The left-minus-right HEOG difference is the rough horizontal eye-position trace. The lower-minus-upper VEOG difference is the rough vertical trace.",
        options: [
            .init(name: "Left / Right HEOG", detail: "Outer-canthi channels or groups on opposite sides of the eyes. Reversing them changes sign but not the removed subspace."),
            .init(name: "Upper / Lower VEOG", detail: "Periocular electrodes above and below the eyes. At least one usable channel is required in each group.")
        ],
        guidance: "Entries are one-based channel numbers separated by commas. Verify automatic assignments for unlabeled nets. Marked-bad and interpolated channels are excluded from the scalp fit."
    )

    static let blinkMask = HelpTopic(
        title: "Blink masking and interpolation",
        summary: "Blink samples are excluded while estimating the CRD maps so the eyelid field cannot distort them. The continuous eye-position predictor is linearly interpolated across those gaps because eye position still exists during a blink.",
        guidance: "The padding extends each preliminary blink span on both sides. Increase it if blink onset or recovery visibly leaks into the CRD maps; reduce it if closely spaced blinks exclude too much of the recording.",
        reference: CorneoRetinalReferences.maacCitation
    )

    static let preliminaryBlinkScan = HelpTopic(
        title: "MAAC preliminary blink scan",
        summary: "This is a specialized MAAC-2 mask detector, not the general ocular-artifact threshold. It measures the explicitly assigned upper-minus-lower VEOG trace and requires both a large deflection and a rapid rise and fall.",
        options: [
            .init(name: "Blink threshold", detail: "Minimum upper/lower VEOG divergence. The MAAC paper uses 150 µV."),
            .init(name: "Rise/fall slope", detail: "Rejects slow drifts that happen to cross the amplitude threshold. Both onset and recovery must be sufficiently rapid."),
            .init(name: "Eye Blink events", detail: "Accepted spans are shown as ordinary Eye Blink markers so you can inspect them on the waveform. They remain MAAC estimation masks and are not automatically used for epoch rejection or blink correction.")
        ],
        guidance: "Start with 150 µV and 0.5 µV/ms. Raise either value when slow vertical drift is being marked; lower cautiously when clearly visible blinks are missed.",
        reference: CorneoRetinalReferences.maacCitation
    )

    static let blinkMaskReview = HelpTopic(
        title: "Review the MAAC blink mask",
        summary: "Every preliminary blink remains available here for inspection before the CRD maps are accepted. Inclusion controls which spans are withheld from map estimation; it does not reject an epoch or remove the eyelid blink.",
        options: [
            .init(name: "Include in mask", detail: "Checked spans are excluded while estimating the horizontal and vertical CRD maps. Unchecked detections remain in this table for comparison."),
            .init(name: "Show in Waveform", detail: "Centers the recording on the selected blink and highlights its complete current span."),
            .init(name: "Start / End", detail: "Adjusts the selected mask boundary one sample at a time. The shaded waveform span updates immediately."),
            .init(name: "Update Estimate", detail: "Recomputes both CRD maps after inclusion or boundary changes. Use Result remains unavailable until this finishes.")
        ],
        guidance: "Include the eyelid transient from its first clear departure through recovery. Exclude threshold hits that are slow drift, movement without a blink, or obvious channel noise.",
        reference: CorneoRetinalReferences.maacCitation
    )

    static let centralFraction = HelpTopic(
        title: "Horizontal-center fraction",
        summary: "Only samples with the smallest horizontal eye-position magnitudes contribute to the vertical CRD map, reducing contamination from horizontal gaze.",
        guidance: "One eighth is the EP Toolkit/MAAC setting. Larger fractions provide more samples but admit more horizontal contamination; smaller fractions are cleaner but can make the vertical estimate unstable.",
        reference: CorneoRetinalReferences.maacCitation
    )

    static let qualityControl = HelpTopic(
        title: "MAAC-2 quality control",
        summary: "The horizontal and vertical maps show the unit-amplitude spatial patterns actually used for subtraction. RMS values summarize the continuous amount removed; masked samples show how much data was withheld from template estimation.",
        guidance: "Expect a left-right opponent horizontal map and a frontopolar/periocular vertical map. Do not apply when the maps are dominated by one bad electrode or lack the expected ocular geometry."
    )
}
