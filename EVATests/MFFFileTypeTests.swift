//
//  MFFFileTypeTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Detected file-type classification + session category-rename resolution.
//

import Testing
import Foundation
@testable import EVA

struct MFFFileTypeTests {

    private func signal(segmented: Bool, averaged: Bool, grand: Bool,
                        segments: [EpochSegment] = []) -> MFFSignalData {
        MFFSignalData(
            signalURL: URL(fileURLWithPath: "/x.mff"),
            signalType: "EEG",
            numberOfChannels: 1,
            samplingRate: 250,
            duration: 1,
            recordingStartTime: nil,
            events: [],
            data: [[0, 0, 0]],
            epochSegments: segments,
            isSegmented: segmented,
            isAveraged: averaged,
            isGrandAverage: grand
        )
    }

    @Test func detectedTypePrecedence() {
        #expect(signal(segmented: false, averaged: false, grand: false).detectedFileType == .continuous)
        #expect(signal(segmented: true, averaged: false, grand: false).detectedFileType == .segmented)
        #expect(signal(segmented: true, averaged: true, grand: false).detectedFileType == .averaged)
        #expect(signal(segmented: true, averaged: true, grand: true).detectedFileType == .grandAverage)
    }

    @Test func subjectsAndCategoriesDerived() {
        let segs = [
            EpochSegment(startSample: 0, endSample: 1, stimulusOffsetSamples: 0, category: "A",
                         sourceCode: "A", sourceTimeSeconds: 0, colorIndex: 0, contributingEpochCount: 1, subject: "G1"),
            EpochSegment(startSample: 2, endSample: 3, stimulusOffsetSamples: 0, category: "A",
                         sourceCode: "A", sourceTimeSeconds: 0, colorIndex: 0, contributingEpochCount: 1, subject: "G2")
        ]
        let s = signal(segmented: true, averaged: true, grand: true, segments: segs)
        #expect(s.categories == ["A"])
        #expect(s.subjects == ["G1", "G2"])
        #expect(s.hasMultipleSubjects)
    }

    @MainActor
    @Test func overlaySelectionResolvesAllAndToggles() {
        let vm = EpochingViewModel()
        let available = ["A", "B", "C"]

        // Empty selection resolves to "all".
        #expect(vm.overlayCategories(available: available) == Set(available))
        #expect(vm.isOverlaySelected("A", available: available))

        // Toggling one off from "all" leaves the rest.
        vm.toggleOverlayCategory("A", available: available)
        #expect(vm.overlayCategories(available: available) == ["B", "C"])
        #expect(!vm.isOverlaySelected("A", available: available))

        // Toggling it back on restores all.
        vm.toggleOverlayCategory("A", available: available)
        #expect(vm.overlayCategories(available: available) == Set(available))

        // Never lets the selection become empty.
        vm.overlaySelectedCategories = ["A"]
        vm.toggleOverlayCategory("A", available: available)
        #expect(vm.overlayCategories(available: available) == ["A"])
    }

    @MainActor
    @Test func displayCategoryHonorsRenames() {
        let vm = EpochingViewModel()
        #expect(vm.displayCategory("A") == "A")
        vm.categoryRenames["A"] = "Target"
        #expect(vm.displayCategory("A") == "Target")
        vm.categoryRenames["A"] = "   " // whitespace-only falls back to the code
        #expect(vm.displayCategory("A") == "A")
    }
}
