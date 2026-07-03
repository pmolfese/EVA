//
//  EpochingViewModel.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  L4 store for the PSA epoching / averaging domain and the averaged-data
//  display state (butterfly, overlaid categories, noise band), extracted from
//  WaveformView (REFACTOR.md slice 4). State-ownership extraction: the store
//  holds the epoching parameters, rejection settings, results, and display
//  toggles; WaveformView still drives the epoching orchestration.
//

import Combine
import SwiftUI

@MainActor
final class EpochingViewModel: ObservableObject {
    // MARK: Sheet / selection
    @Published var showsSheet = false
    @Published var segmentField = PSASegmentField.code
    @Published var eventSearchText = ""
    @Published var selectedEventCodes = Set<String>()

    // MARK: Epoch window (portable → eva.xml)
    @Published var preStimulus = 0.2
    @Published var postStimulus = 0.8
    @Published var offset = 0.0
    @Published var baselineCorrected = false
    @Published var averageReference = false
    @Published var averageOnApply = false

    // MARK: Category naming / timing markers
    @Published var categoryNames = [String: String]()
    @Published var timingMarkerEnabledValues = Set<String>()
    @Published var timingMarkerValuesBySegmentValue = [String: String]()
    @Published var timingTolerance = 0.5

    // MARK: Artifact rejection
    @Published var skipIfContainsArtifact = false
    @Published var skipEyeBlinks = true
    @Published var skipEyeMovements = true
    @Published var skippedDefinedArtifactIDs = Set<DefinedArtifact.ID>()
    @Published var knownArtifactIDsForRejection = Set<DefinedArtifact.ID>()

    // MARK: Run state
    @Published var statusMessage: String?
    @Published var isApplying = false
    @Published var phaseMessage: String?

    // MARK: Results
    @Published var epochedSignal: MFFSignalData?
    @Published var epochSegments: [EpochSegment] = []
    @Published var isAveraged = false

    // MARK: Averaged-data display
    @Published var showsButterflyPlot = false
    @Published var showsNoiseBand = true
    @Published var showsOverlaidCategories = false
    @Published var butterflyTopomapRelativeSample: Int?

    // MARK: Figure labeling (session-only; never mutates EpochSegment.category)
    /// Category → user-facing display name, for publication figures/legends.
    @Published var categoryRenames = [String: String]()

    /// The display label for a category, honoring any session rename.
    func displayCategory(_ category: String) -> String {
        let renamed = categoryRenames[category]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (renamed?.isEmpty == false) ? renamed! : category
    }

    // MARK: Topomap color scale (Cmd-hold control in the topography pane)
    enum TopomapScaleMode: String, CaseIterable, Identifiable { case microvolts = "µV", zScore = "Z"; var id: String { rawValue } }
    @Published var topomapScaleMode: TopomapScaleMode = .microvolts

    /// µV mode: when true, topomaps use the manual min/max below instead of the
    /// auto symmetric ±scale. Tightening the range intensifies the colors.
    @Published var topomapScaleManual = false
    @Published var topomapScaleMin = -5.0
    @Published var topomapScaleMax = 5.0
    /// Lock min = −max so the scale stays symmetric about 0.
    @Published var topomapSymmetric = true

    /// Z-score mode: color scale spans ±`topomapZSigma` SD about the mean. Mean/SD
    /// auto-compute from the displayed maps unless the user overrides them.
    @Published var topomapZSigma = 2.0
    @Published var topomapZMean = 0.0
    @Published var topomapZSD = 1.0
    @Published var topomapZManual = false

    // MARK: Multi-condition overlay (figure building)
    /// Categories chosen for overlay. Empty == all (so no seeding is needed).
    @Published var overlaySelectedCategories: Set<String> = []
    /// Butterfly panel: overlay selected conditions on shared axes vs. stacked.
    @Published var showsOverlayButterfly = false

    /// Effective overlay selection over the currently-available categories
    /// (empty selection resolves to "all").
    func overlayCategories(available: [String]) -> Set<String> {
        overlaySelectedCategories.isEmpty ? Set(available) : overlaySelectedCategories.intersection(available)
    }

    func isOverlaySelected(_ category: String, available: [String]) -> Bool {
        overlayCategories(available: available).contains(category)
    }

    func toggleOverlayCategory(_ category: String, available: [String]) {
        var current = overlayCategories(available: available) // resolves "all" first
        if current.contains(category) { current.remove(category) } else { current.insert(category) }
        // Keep at least one selected.
        if current.isEmpty { current = [category] }
        overlaySelectedCategories = current
    }

    var parameters: [String: String] {
        var p: [String: String] = [
            "preStimulusMs": String(format: "%.0f", preStimulus * 1000),
            "postStimulusMs": String(format: "%.0f", postStimulus * 1000),
            "offsetMs": String(format: "%.0f", offset * 1000),
            "baselineCorrected": "\(baselineCorrected)",
            "averageReference": "\(averageReference)",
            "average": "\(averageOnApply)",
            "skipEyeBlinks": "\(skipEyeBlinks)",
            "skipEyeMovements": "\(skipEyeMovements)",
            "skipArtifacts": "\(skipIfContainsArtifact)"
        ]
        if !selectedEventCodes.isEmpty {
            p["eventCodes"] = selectedEventCodes.sorted().joined(separator: ",")
        }
        // Only non-default category names (a code defaults to itself) need carrying.
        for code in selectedEventCodes where (categoryNames[code].map { $0 != code } ?? false) {
            p["category.\(code)"] = categoryNames[code]!
        }
        return p
    }

    /// Deserialization inverse of `parameters` for Copy Processing / replay.
    /// Event codes are portable when the target recording has the same codes.
    func apply(parameters p: [String: String]) {
        if let v = p["preStimulusMs"].flatMap(Double.init) { preStimulus = v / 1000 }
        if let v = p["postStimulusMs"].flatMap(Double.init) { postStimulus = v / 1000 }
        if let v = p["offsetMs"].flatMap(Double.init) { offset = v / 1000 }
        if let v = p["baselineCorrected"] { baselineCorrected = (v == "true") }
        if let v = p["averageReference"] { averageReference = (v == "true") }
        if let v = p["average"] { averageOnApply = (v == "true") }
        if let v = p["skipEyeBlinks"] { skipEyeBlinks = (v == "true") }
        if let v = p["skipEyeMovements"] { skipEyeMovements = (v == "true") }
        if let v = p["skipArtifacts"] { skipIfContainsArtifact = (v == "true") }
        if let codes = p["eventCodes"] {
            selectedEventCodes = Set(codes.split(separator: ",").map(String.init))
        }
        for (key, value) in p where key.hasPrefix("category.") {
            categoryNames[String(key.dropFirst("category.".count))] = value
        }
    }

    func resetForClose() {
        showsSheet = false
        eventSearchText = ""
        selectedEventCodes.removeAll()
        categoryNames.removeAll()
        timingMarkerEnabledValues.removeAll()
        timingMarkerValuesBySegmentValue.removeAll()
        skippedDefinedArtifactIDs.removeAll()
        knownArtifactIDsForRejection.removeAll()
        statusMessage = nil
        isApplying = false
        phaseMessage = nil
        epochedSignal = nil
        epochSegments = []
        isAveraged = false
        showsButterflyPlot = false
        showsOverlaidCategories = false
        butterflyTopomapRelativeSample = nil
        categoryRenames.removeAll()
        overlaySelectedCategories.removeAll()
        showsOverlayButterfly = false
        topomapScaleMode = .microvolts
        topomapScaleManual = false
        topomapSymmetric = true
        topomapZManual = false
        topomapZSigma = 2.0
    }
}
