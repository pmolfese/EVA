//
//  BCGDetectionViewModelTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Testing
import Foundation
@testable import EVA

struct BCGDetectionViewModelTests {

    @MainActor
    @Test func initializesMethodFromProcessingDefaults() {
        let original = ProcessingDefaults.shared.bcgDefaultMethodRaw
        defer { ProcessingDefaults.shared.bcgDefaultMethodRaw = original }

        ProcessingDefaults.shared.bcgDefaultMethodRaw = "spatialPCA"
        let vm = BCGDetectionViewModel(store: RecordingStore())
        #expect(vm.method == .spatialPCA)
    }

    @MainActor
    @Test func fallsBackToSpatialPCAForUnknownStoredMethod() {
        let original = ProcessingDefaults.shared.bcgDefaultMethodRaw
        defer { ProcessingDefaults.shared.bcgDefaultMethodRaw = original }

        ProcessingDefaults.shared.bcgDefaultMethodRaw = "not-a-real-method"
        let vm = BCGDetectionViewModel(store: RecordingStore())
        #expect(vm.method == .spatialPCA)
    }

    @MainActor
    @Test func defaultsMatchExpectedInitialState() {
        let vm = BCGDetectionViewModel(store: RecordingStore())
        #expect(!vm.detectsArtifacts)
        #expect(!vm.showsSheet)
        #expect(vm.eventCode == "BCG")
        #expect(vm.thresholdSD == 2.5)
        #expect(vm.minHR == 40)
        #expect(vm.maxHR == 120)
        #expect(vm.pcaComponents == 1)
        #expect(!vm.spatialWhiten)
        #expect(vm.slidingNormalize)
        #expect(vm.respAdaptive)
        #expect(!vm.isRunning)
        #expect(vm.refinedTemplate == nil)
        #expect(!vm.isRefining)
        #expect(!vm.isEstimating)
        #expect(vm.algorithmResults.isEmpty)
    }

    @Test func previewBPMUsesMedianBeatInterval() {
        let result = BCGDetectionPreviewEstimator.result(from: [0, 1, 2, 4])
        #expect(result.count == 4)
        #expect(result.bpm == 60)
    }

    @Test func previewMarksNonDetectionMethodsUnavailable() async {
        let configuration = BCGDetectionPreviewConfiguration(
            thresholdSD: 2.5,
            minHR: 40,
            maxHR: 120,
            powerMinHz: 0.8,
            powerMaxHz: 1.5,
            qrsLagSeconds: 0.3,
            pcaComponents: 1,
            spatialWhiten: false,
            slidingNormalize: true,
            respAdaptive: true
        )
        let cwl = await BCGDetectionPreviewEstimator.eventTimes(
            method: .cwlRegression,
            channels: [[0, 1, 0]],
            samplingRate: 250,
            duration: 1,
            exemplarRange: nil,
            qrsTimes: [],
            configuration: configuration
        )
        let qrsWithoutECG = await BCGDetectionPreviewEstimator.eventTimes(
            method: .qrsLocking,
            channels: [[0, 1, 0]],
            samplingRate: 250,
            duration: 1,
            exemplarRange: nil,
            qrsTimes: [],
            configuration: configuration
        )
        #expect(cwl == nil)
        #expect(qrsWithoutECG == nil)
    }

    @MainActor
    @Test func publishedPropertiesAreIndependentlyMutable() {
        let vm = BCGDetectionViewModel(store: RecordingStore())
        vm.method = .qrsLocking
        vm.windowSeconds = 0.5
        vm.thresholdSD = 3.0
        vm.channelSetID = nil

        #expect(vm.method == .qrsLocking)
        #expect(vm.windowSeconds == 0.5)
        #expect(vm.thresholdSD == 3.0)
    }

    @MainActor
    @Test func parametersCaptureBCGAndCWLSettings() {
        let vm = BCGDetectionViewModel(store: RecordingStore())
        vm.method = .cwlRegression
        vm.eventCode = "R"
        vm.windowSeconds = 0.55
        vm.thresholdSD = 3.25
        vm.selectedCWLChannels = [0, 2]
        vm.cwlUseEVAFastCWR = true
        vm.cwlDelayMs = 25
        vm.cwlLagRangeMinMs = -40
        vm.cwlLagRangeMaxMs = 160
        vm.cwlLagStepMs = 5
        vm.cwlWindowSeconds = 5
        vm.cwlDownsampleTargetHz = 250
        vm.cwlDownsampleFilter = .blockAverage
        vm.cwlUpsampleToOriginalHz = true

        let p = vm.parameters

        #expect(p["method"] == BCGDetectionMethod.cwlRegression.rawValue)
        #expect(p["eventCode"] == "R")
        #expect(p["windowSeconds"] == "0.550000")
        #expect(p["thresholdSD"] == "3.250000")
        #expect(p["cwlSelectedChannels"] == "1,3")
        #expect(p["cwlUseEVAFastCWR"] == "true")
        #expect(p["cwlDelayMs"] == "25.000000")
        #expect(p["cwlLagRangeMinMs"] == "-40.000000")
        #expect(p["cwlLagRangeMaxMs"] == "160.000000")
        #expect(p["cwlLagStepMs"] == "5.000000")
        #expect(p["cwlWindowSeconds"] == "5.000000")
        #expect(p["cwlDownsampleTargetHz"] == "250.000000")
        #expect(p["cwlDownsampleFilter"] == CWLCorrector.DownsampleFilter.blockAverage.rawValue)
        #expect(p["cwlUpsampleToOriginalHz"] == "true")
    }
}
