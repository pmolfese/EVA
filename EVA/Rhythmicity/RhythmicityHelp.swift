//
//  RhythmicityHelp.swift
//  EVA
//

import SwiftUI

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
                    article("Using ABBA bands in Time-Frequency", "Use in Time-Frequency publishes the displayed channel's band borders for this recording session. Choose Rhythmicity Explorer in the Time-Frequency Band source picker to overlay borders and peaks and use those same ranges for ROI scalars. The overlay does not change ERSP or ITPC values, the selected-channel borders are stated when applied across an all-channel view, stale bands are refused, and saved user band preferences are never changed.")
                    article("WTPL, ITPC, and bursts", "Within-Trial Phase Locking compares phase across nearby times inside one trial. ITPC compares phase across trials at one time and frequency. The Event-related and Bursts workspaces are planned follow-ons; rhythmic bursts are analysis annotations and are never artifact-rejection instructions by themselves.")
                    article("Citation", "Karvat G, et al. (2026). Universal rhythmic architecture uncovers two modes of neural dynamics. Nature Communications. EVA's behavioral reference is the authors' LAVI repository at commit 78386879eeb8cf9be06a1edfa6917c91b2d0d2ba. Cite the paper and report EVA's exported method version, parameters, seed, source revision, and warnings.")
                    Link("Open the paper", destination: URL(string: "https://www.nature.com/articles/s41467-026-73553-8")!)
                    Link("Open-access full text", destination: URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/PMC13392403/")!)
                    Link("Authors' LAVI repository", destination: URL(string: "https://github.com/laaanchic/LAVI")!)
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
