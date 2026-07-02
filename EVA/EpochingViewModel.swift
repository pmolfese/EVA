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

    var parameters: [String: String] {
        [
            "preStimulusMs": String(format: "%.0f", preStimulus * 1000),
            "postStimulusMs": String(format: "%.0f", postStimulus * 1000),
            "baselineCorrected": "\(baselineCorrected)",
            "averageReference": "\(averageReference)"
        ]
    }
}
