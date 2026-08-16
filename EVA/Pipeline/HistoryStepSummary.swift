//
//  HistoryStepSummary.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  How a history node renders: the short title on the rail and the one-line
//  parameter subtitle under it ("FASTR · 21 TR · 30 donors", "0.1–40 Hz").
//
//  A free function over the step's serialized `parameters` rather than a method
//  on any view model, for the reason the whole REWIND design keeps running into:
//  a node has to render from what was *recorded*, not from whatever the live view
//  models happen to hold. A node three steps back describes settings the view
//  models no longer have.
//
//  Titles here are deliberately shorter than `ReplayStepDisplay.label(for:)`.
//  That one names a step in a checklist with room to breathe; this one sits in a
//  ~260 pt rail beside its parameters, where "Band-pass / Line-noise Filter ·
//  0.1–40 Hz" wraps to three lines and reads worse than "filter · 0.1–40 Hz".
//  Lowercase matches the figure in `REWIND.md` and reads as a log rather than a
//  set of headings.
//

import Foundation

nonisolated enum HistoryStepSummary {

    /// Short rail title, e.g. `filter`, `ICA`, `gradient correction`.
    static func title(for operation: EVAProcessingStep.Operation) -> String {
        switch operation {
        case .mriGradientCorrection: return "gradient correction"
        case .filter: return "filter"
        case .thresholdArtifactDetection: return "artifact detection"
        case .icaClean: return "ICA"
        case .artifactClean: return "artifact cleaning"
        case .waveletReduce: return "wavelet reduction"
        case .interpolateChannels: return "interpolate"
        case .markBad: return "mark bad"
        case .segment: return "segment"
        case .baseline: return "baseline"
        case .average: return "average"
        case .combine: return "combine"
        case .combineBadChannelPolicy: return "combine bad channels"
        case .split: return "split"
        case .reference: return "Reference"
        case .bcgDetection: return "BCG detection"
        case .ecgDetection: return "ECG detection"
        }
    }

    /// One-line parameter summary, or `""` when the step has nothing worth
    /// showing. Only the parameters that *identify* a step to a human go here —
    /// the rest are available by opening the stage.
    static func subtitle(for step: EVAProcessingStep) -> String {
        let p = step.parameters
        var parts: [String] = []

        switch step.operation {
        case .filter:
            if let band = band(from: p) { parts.append(band) }
            switch p["lineNoiseMode"] {
            case "notch":
                parts.append("\(p["lineNoiseHz"] ?? "60") Hz notch")
            case "adaptiveCleanLine":
                parts.append("CleanLine \(p["lineNoiseHz"] ?? "60") Hz")
            default:
                break
            }
            if p["averageReference"] == "true" { parts.append("avg ref") }

        case .mriGradientCorrection:
            if let method = p["method"] { parts.append(method) }
            if let donors = p["donorVolumes"] { parts.append("\(donors) donors") }
            if p["anc"] == "true" { parts.append("ANC") }
            if p["excludeHighMotion"] == "true" { parts.append("motion censored") }

        case .icaClean:
            if let method = p["method"] { parts.append(method) }
            if let components = p["components"] { parts.append("\(components) components") }
            if p["averageReference"] == "true" { parts.append("avg ref") }

        case .waveletReduce:
            if let family = p["family"] { parts.append(family) }
            if let levels = p["levelCount"] { parts.append("\(levels) levels") }
            if let rule = p["thresholdRule"] { parts.append(rule) }
            if p["useGPU"] == "true" { parts.append("GPU") }

        case .thresholdArtifactDetection:
            if p["eyeBlink"] == "true" { parts.append("blinks") }
            if p["eyeMovement"] == "true" { parts.append("movements") }

        case .segment:
            if let codes = p["eventCodes"], !codes.isEmpty {
                let count = codes.split(separator: ",").count
                parts.append("\(count) \(count == 1 ? "condition" : "conditions")")
            }
            if let field = p["segmentField"], field != PSASegmentField.code.rawValue {
                parts.append("on \(field.lowercased())")
            }
            if let window = window(from: p) { parts.append(window) }
            if p["average"] == "true" { parts.append("averaged") }

        case .artifactClean:
            if let count = p["artifactCount"] {
                parts.append("\(count) \(count == "1" ? "template" : "templates")")
            }

        case .bcgDetection, .ecgDetection:
            if let method = p["method"] { parts.append(method) }

        case .markBad:
            if let channels = p["channels"], !channels.isEmpty {
                parts.append(channelCount(channels))
            }

        case .interpolateChannels:
            if let channels = p["channels"], !channels.isEmpty {
                parts.append(channelCount(channels))
            }
            if p["method"] == ChannelDecisionSteps.methodParameterValue {
                parts.append("spherical spline")
            }

        case .reference:
            parts.append(Rereferencing.scheme(from: p).displayName.lowercased())
            if Rereferencing.domain(from: p) == .epoch { parts.append("epochs") }
            // The excluded set is the whole reason this is a step rather than a
            // filter option, so the rail says so rather than making you open it.
            if let count = p["excludedCount"].flatMap(Int.init), count > 0 {
                parts.append("\(count) ch excluded")
            }

        case .baseline:
            break // No parameters — the title alone ("baseline") says it all.

        case .average, .combine, .combineBadChannelPolicy, .split:
            break
        }

        // A step with nothing recognized still says *something* rather than
        // rendering as a bare title with no explanation of what it did.
        if parts.isEmpty, !p.isEmpty {
            parts.append("\(p.count) \(p.count == 1 ? "setting" : "settings")")
        }
        return parts.joined(separator: " · ")
    }

    /// `4 ch` — the count, not the list. The rail is ~260 pt wide and a 40-channel
    /// rejection would push everything else off the row; the list is one click
    /// away in the step's own panel, and in full in `log_eva_*.txt`.
    private static func channelCount(_ list: String) -> String {
        "\(list.split(separator: ",").count) ch"
    }

    /// `0.1–40 Hz`, `0.1 Hz high-pass`, `40 Hz low-pass`, or nil when neither
    /// edge is set (a line-noise-only or reference-only filter step).
    private static func band(from p: [String: String]) -> String? {
        switch (p["highPassHz"], p["lowPassHz"]) {
        case let (high?, low?): return "\(high)–\(low) Hz"
        case let (high?, nil): return "\(high) Hz high-pass"
        case let (nil, low?): return "\(low) Hz low-pass"
        case (nil, nil): return nil
        }
    }

    /// `−100–600 ms` from the PSA epoch bounds. Uses a true minus sign because
    /// the pre-stimulus value is already serialized with a hyphen and the two
    /// read badly side by side.
    private static func window(from p: [String: String]) -> String? {
        guard let pre = p["preStimulusMs"], let post = p["postStimulusMs"] else { return nil }
        return "\(pre.replacingOccurrences(of: "-", with: "−"))–\(post) ms"
    }
}
