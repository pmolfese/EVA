//
//  GradientViewModelTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Coverage for the L4 gradient store (REFACTOR.md slice 2): parameter bridge
//  and the high-motion gating.
//

import Testing
import Foundation
import SwiftUI
@testable import EVA

struct GradientViewModelTests {

    @MainActor
    @Test func parametersReflectMethodAndWindow() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.method = .fastr
        vm.trMarkerCode = "TREV"
        vm.donorVolumes = 5
        vm.slicesPerVolume = 32
        vm.ancSliceHighPass = true
        vm.ancEnabled = true
        vm.computeBackend = .metal

        let p = vm.parameters
        #expect(p["method"] == "FASTR")
        #expect(p["trMarkerCode"] == "TREV")
        #expect(p["donorVolumes"] == "5")
        #expect(p["slices"] == "32")
        #expect(p["ancSliceHighPass"] == "true")
        #expect(p["backend"] == "metal")

        let restored = GradientViewModel(store: RecordingStore())
        restored.apply(parameters: p)
        #expect(restored.method == .fastr)
        #expect(restored.slicesPerVolume == 32)
        #expect(restored.ancSliceHighPass)
        #expect(restored.computeBackend == .metal)
    }

    @MainActor
    @Test func parametersPersistDonorRanking() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.method = .fastr
        vm.donorRanking = .squaredCorrelation

        #expect(vm.parameters["donorRanking"] == "squaredCorrelation")

        let restored = GradientViewModel(store: RecordingStore())
        restored.apply(parameters: vm.parameters)
        #expect(restored.donorRanking == .squaredCorrelation)
    }

    /// The backend choice is only meaningful for the FASTR family — it is the
    /// only engine with a Metal path — so it is recorded for every method but
    /// the other two engines ignore it.
    @MainActor
    @Test func backendIsRecordedForEveryMethod() {
        for method in MRIGradientMethod.allCases {
            let vm = GradientViewModel(store: RecordingStore())
            vm.method = method
            vm.computeBackend = .metal
            #expect(vm.parameters["backend"] == "metal")

            let restored = GradientViewModel(store: RecordingStore())
            restored.apply(parameters: vm.parameters)
            #expect(restored.method == method)
            #expect(restored.computeBackend == .metal)
        }
    }

    /// Each method's parameter block carries only the keys its engine reads, so
    /// a replay file does not imply settings that had no effect on the run.
    @MainActor
    @Test func parameterKeysAreScopedToTheEngine() {
        let aas = GradientViewModel(store: RecordingStore())
        aas.method = .aas
        #expect(aas.parameters["slices"] == nil)
        #expect(aas.parameters["obs"] == nil)
        #expect(aas.parameters["allenSectionEpochs"] == nil)
        #expect(aas.parameters["localMinimumDonorCount"] == nil)

        let allen = GradientViewModel(store: RecordingStore())
        allen.method = .allenIAR
        #expect(allen.parameters["slices"] != nil)
        #expect(allen.parameters["allenSectionEpochs"] != nil)
        #expect(allen.parameters["templateScaling"] == nil)

        let mas = GradientViewModel(store: RecordingStore())
        mas.method = .mas
        #expect(mas.parameters["localMinimumDonorCount"] != nil)
        #expect(mas.parameters["obs"] == nil)
        #expect(mas.parameters["anc"] == nil)

        let fastr = GradientViewModel(store: RecordingStore())
        fastr.method = .fastr
        #expect(fastr.parameters["templateScaling"] != nil)
        #expect(fastr.parameters["obs"] != nil)
        #expect(fastr.parameters["allenSectionEpochs"] == nil)
    }

    @MainActor
    @Test func methodsRouteToTheExpectedEngine() {
        #expect(MRIGradientMethod.aas.engine == .averageTemplate)
        #expect(MRIGradientMethod.allenIAR.engine == .averageTemplate)
        #expect(MRIGradientMethod.mas.engine == .localTemplate)
        #expect(MRIGradientMethod.mar.engine == .localTemplate)
        #expect(MRIGradientMethod.fastr.engine == .sliceTemplate)
        #expect(MRIGradientMethod.moosmann.engine == .sliceTemplate)
        #expect(MRIGradientMethod.farm.engine == .sliceTemplate)

        #expect(MRIGradientMethod.moosmann.usesMotion)
        #expect(!MRIGradientMethod.fastr.usesMotion)
        #expect(MRIGradientMethod.allenIAR.supportsSliceEpochs)
        #expect(!MRIGradientMethod.mas.supportsSliceEpochs)
    }

    /// The sheet opens on the family and method the user chose in Preferences,
    /// and on the backend they set once, rather than on a hardcoded default.
    @MainActor
    @Test func newStoresSeedFromGlobalPreferences() {
        let defaults = ProcessingDefaults.shared
        let category = defaults.gradientDefaultCategory
        let template = defaults.gradientDefaultTemplateMethod
        let fastr = defaults.gradientDefaultFASTRMethod
        let backend = defaults.gradientComputeBackend
        defer {
            defaults.gradientDefaultCategory = category
            defaults.gradientDefaultTemplateMethod = template
            defaults.gradientDefaultFASTRMethod = fastr
            defaults.gradientComputeBackend = backend
        }

        defaults.gradientDefaultCategory = .fastr
        defaults.gradientDefaultFASTRMethod = .farm
        defaults.gradientDefaultTemplateMethod = .waar
        defaults.gradientComputeBackend = .metal

        let vm = GradientViewModel(store: RecordingStore(), defaults: defaults)
        #expect(vm.method == .farm)
        #expect(vm.computeBackend == .metal)

        // Switching family lands on the preferred Template method, not the first.
        vm.categoryBinding.wrappedValue = .template
        #expect(vm.method == .waar)
        // And switching back restores what was in use.
        vm.categoryBinding.wrappedValue = .fastr
        #expect(vm.method == .farm)
    }

    /// A per-family default can only hold a method from that family, so a stale
    /// or hand-edited preference cannot put the sheet in an impossible state.
    @MainActor
    @Test func perFamilyDefaultsRejectTheOtherFamily() {
        let defaults = ProcessingDefaults.shared
        let template = defaults.gradientDefaultTemplateMethod
        let fastr = defaults.gradientDefaultFASTRMethod
        defer {
            defaults.gradientDefaultTemplateMethod = template
            defaults.gradientDefaultFASTRMethod = fastr
        }

        defaults.gradientDefaultTemplateMethod = .mas
        defaults.gradientDefaultTemplateMethod = .farm   // ignored: wrong family
        #expect(defaults.gradientDefaultTemplateMethod == .mas)

        defaults.gradientDefaultFASTRMethod = .moosmann
        defaults.gradientDefaultFASTRMethod = .waas      // ignored: wrong family
        #expect(defaults.gradientDefaultFASTRMethod == .moosmann)
    }

    @MainActor
    @Test func everyMethodBelongsToExactlyOneFamily() {
        for method in MRIGradientMethod.allCases {
            #expect(method.category.allMethods.contains(method))
        }
        #expect(MRIGradientCategory.template.allMethods.count
                + MRIGradientCategory.fastr.allMethods.count == MRIGradientMethod.allCases.count)
        #expect(MRIGradientMethod.waas.engine == .localTemplate)
        #expect(MRIGradientMethod.waar.engine == .localTemplate)
        #expect(MRIGradientMethod.waas.weightsDonorsByDistance)
        #expect(MRIGradientMethod.waar.fitsTemplateScale)
        #expect(!MRIGradientMethod.mas.weightsDonorsByDistance)
    }

    // MARK: - Run reports

    /// The exclusions are the part of a run that cannot be reconstructed from
    /// the corrected samples, so they have to be recorded.
    @MainActor
    @Test func theLocalTemplateReportNamesWhatWasExcludedAndWhy() {
        let summaries = [
            LocalTemplateEventSummary(
                eventIndex: 0, donorIndices: [1, 2], skippedReason: nil,
                scaleFactors: nil, methodName: "median/unscaled",
                rejectedDonors: [.init(eventIndex: 3, correlation: 0.42)]
            ),
            LocalTemplateEventSummary(
                eventIndex: 1, donorIndices: [], skippedReason: .noCorrelatedDonors,
                scaleFactors: nil, methodName: "median/unscaled",
                rejectedDonors: [
                    .init(eventIndex: 0, correlation: -0.10),
                    .init(eventIndex: 2, correlation: 0.31)
                ]
            ),
            LocalTemplateEventSummary(
                eventIndex: 2, donorIndices: [], skippedReason: .insufficientDonors,
                scaleFactors: nil, methodName: "median/unscaled"
            )
        ]

        let lines = GradientViewModel.report(for: summaries, method: "MAS", correlationFloor: 0.9)
        let text = lines.joined(separator: "\n")

        #expect(text.contains("events=3"))
        #expect(text.contains("corrected=1"))
        #expect(text.contains("skipped=2"))
        // Both skip reasons named, with the events that hit them.
        #expect(text.contains("noCorrelatedDonors x1"))
        #expect(text.contains("insufficientDonors x1"))
        // Donor rejections counted, with the floor and the worst score.
        #expect(text.contains("correlationFloor=0.900"))
        #expect(text.contains("rejected=3"))
        #expect(text.contains("across 2 events"))
        #expect(text.contains("lowest r=-0.100"))
    }

    /// Without a floor there is nothing to report about donors, and the line
    /// should not appear at all rather than claiming zero rejections.
    @MainActor
    @Test func noCorrelationFloorMeansNoDonorLine() {
        let summaries = [
            LocalTemplateEventSummary(
                eventIndex: 0, donorIndices: [1], skippedReason: nil,
                scaleFactors: nil, methodName: "median/unscaled"
            )
        ]
        let lines = GradientViewModel.report(for: summaries, method: "MAS", correlationFloor: nil)
        #expect(!lines.contains { $0.contains("correlationFloor") })
        #expect(lines.contains { $0.contains("corrected=1") })
    }

    /// Warnings are grouped and counted: a 9000-epoch recording can raise
    /// thousands, and one line each would bury the log.
    @MainActor
    @Test func theSliceTemplateReportGroupsWarnings() {
        let diagnostics = GradientCorrectionDiagnostics(
            epochCount: 100,
            period: 100,
            samplesBefore: 0,
            samplesAfter: 100,
            referenceChannel: 2,
            computeBackend: .metal,
            highMotionVolumes: [7, 9],
            epochs: (0..<4).map {
                GradientEpochDiagnostic(
                    epoch: $0, trigger: $0 * 100, volume: $0, slicePosition: 0,
                    integerShift: 0, fractionalShift: 0, donorIndices: [],
                    templateScale: 1, corrected: $0 < 3
                )
            },
            obsComponentCounts: [3, 2],
            ancAppliedChannels: [0, 1, 2],
            warnings: [
                .templateScaleRejected(epoch: 4),
                .templateScaleRejected(epoch: 9),
                .epochOutOfBounds(epoch: 99),
                .noSupraThresholdMotion
            ]
        )

        let text = GradientViewModel.report(for: diagnostics, method: "FASTR Original")
            .joined(separator: "\n")

        #expect(text.contains("backend=metal"))
        #expect(text.contains("corrected=3"))
        #expect(text.contains("uncorrected=1"))
        #expect(text.contains("referenceChannel=3"))     // 1-based for humans
        #expect(text.contains("templateScaleRejected x2"))
        #expect(text.contains("epochs 4,9"))
        #expect(text.contains("epochOutOfBounds x1"))
        #expect(text.contains("noSupraThresholdMotion x1"))
        #expect(text.contains("highMotionVolumes=2"))
        #expect(text.contains("componentsPerChunk=3,2"))
        #expect(text.contains("appliedChannels=3"))
    }

    /// The wavelet backend is a preference for the same reason the gradient one
    /// is: it changes speed, not meaning, and it falls back on its own.
    @MainActor
    @Test func waveletBackendSeedsFromPreferences() {
        let defaults = ProcessingDefaults.shared
        let original = defaults.waveletUsesGPU
        defer { defaults.waveletUsesGPU = original }

        defaults.waveletUsesGPU = false
        #expect(!WaveletReductionViewModel(store: RecordingStore(), defaults: defaults).config.useGPU)

        defaults.waveletUsesGPU = true
        let onGPU = WaveletReductionViewModel(store: RecordingStore(), defaults: defaults).config.useGPU
        // Honoured only where a device exists; the fallback is what makes the
        // preference safe to default on.
        #expect(onGPU == WaveletMetalBackend.isAvailable)
    }

    // MARK: - Motion thresholding

    /// Motion with a large rotation and almost no translation. The two metrics
    /// must disagree about it, or the test below proves nothing.
    @MainActor
    private func rotationHeavyMotion() -> MotionParameters {
        MotionParameters(
            samples: [
                MotionSample(id: 0, roll: 0, pitch: 0, yaw: 0, dS: 0, dL: 0, dP: 0),
                MotionSample(id: 1, roll: 0, pitch: 0, yaw: 0, dS: 0.02, dL: 0, dP: 0),
                MotionSample(id: 2, roll: 6, pitch: 0, yaw: 0, dS: 0.02, dL: 0, dP: 0),
                MotionSample(id: 3, roll: 6, pitch: 0, yaw: 0, dS: 0.02, dL: 0, dP: 0)
            ],
            sourceName: "rotation.1D"
        )
    }

    /// The metric picker used to affect Moosmann only: the exclusion set came
    /// from a helper fixed to all six rigid-body terms, so a user who chose
    /// Translation Only still got an all-six set. Both must honour the choice.
    @MainActor
    @Test func theMotionMetricGovernsTheExclusionSet() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.motionParameters = rotationHeavyMotion()
        vm.motionFDThreshold = 0.5
        vm.excludeHighMotion = true

        vm.motionMetric = .translationOnly
        let translation = vm.highMotionVolumeSet()

        vm.motionMetric = .allParameters
        let allSix = vm.highMotionVolumeSet()

        // A 6-degree roll on a 50 mm sphere is several millimetres of arc, so
        // all-six catches volume 2 and translation-only does not.
        #expect(translation.isEmpty)
        #expect(allSix.contains(2))
    }

    /// Every engine has to receive the exclusion set, not just the FASTR family.
    /// Allen AAS ignored it entirely until 2026-08-09.
    @MainActor
    @Test func everyMethodReceivesMotionExclusions() {
        for method in MRIGradientMethod.allCases {
            let vm = GradientViewModel(store: RecordingStore())
            vm.method = method
            vm.motionParameters = rotationHeavyMotion()
            vm.motionFDThreshold = 0.5
            vm.motionMetric = .allParameters
            vm.excludeHighMotion = true

            if method.usesMotion {
                // Moosmann derives its own censoring from the motion file, so it
                // is handed the parameters rather than a resolved set.
                #expect(vm.parameters["motionMetric"] != nil, "\(method) should record the metric")
            } else {
                #expect(!vm.highMotionVolumeSet().isEmpty, "\(method) resolved no exclusions")
                #expect(vm.parameters["motionFDThreshold"] != nil,
                        "\(method) should record the threshold")
            }
        }
    }

    /// Turning the toggle off means no exclusions, whatever the motion file says.
    @MainActor
    @Test func exclusionsRequireTheToggle() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.motionParameters = rotationHeavyMotion()
        vm.motionFDThreshold = 0.5
        vm.motionMetric = .allParameters
        vm.excludeHighMotion = false
        #expect(vm.highMotionVolumeSet().isEmpty)
    }

    // MARK: - Donor volumes

    /// The count is a total, and the FASTR family only ever reads the total: it
    /// hands every scheme `requestedDonorCount`, which is the sum. Whatever
    /// split the view model chooses must therefore add back up exactly.
    @MainActor
    @Test func theDonorCountIsATotalAndTheSplitPreservesIt() {
        for total in [1, 2, 3, 7, 8, 30, 31] {
            let vm = GradientViewModel(store: RecordingStore())
            vm.method = .fastr
            vm.donorVolumes = total
            let restored = GradientViewModel(store: RecordingStore())
            restored.apply(parameters: vm.parameters)
            #expect(restored.donorVolumes == total, "round trip at \(total)")
        }
    }

    /// Allen AAS sizes its template by section epochs, not by a neighbourhood,
    /// so the donor control is not offered there — it used to be shown and
    /// silently ignored.
    @MainActor
    @Test func allenAASDoesNotOfferADonorWindow() {
        #expect(!MRIGradientMethod.allenIAR.usesDonorWindow)
        for method in MRIGradientMethod.allCases where method != .allenIAR {
            #expect(method.usesDonorWindow, "\(method) should offer a donor window")
        }
    }

    /// A block written before the split was retired still loads: the sum is what
    /// every engine but the local-template one was already using.
    @MainActor
    @Test func aPreSplitBlockLoadsAsTheSum() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.apply(parameters: [
            "engine": "cleanroom-1",
            "method": "FASTR",
            "windowBefore": "9",
            "windowAfter": "6"
        ])
        #expect(vm.donorVolumes == 15)
    }

    // MARK: - Retired methods

    /// Fast AAS is withdrawn from the picker but not from the app: it still
    /// resolves, still routes to an engine, and still runs.
    /// A newly-opened recording starts on Allen AAS unless the user says
    /// otherwise, and never on a retired method.
    @MainActor
    @Test func theShippedDefaultIsAllenAAS() {
        let defaults = ProcessingDefaults.shared
        let category = defaults.gradientDefaultCategory
        let template = defaults.gradientDefaultTemplateMethod
        defer {
            defaults.gradientDefaultCategory = category
            defaults.gradientDefaultTemplateMethod = template
        }

        // Clearing the stored value falls back to the shipped default.
        UserDefaults.standard.removeObject(forKey: "gradientDefaultTemplateMethodRaw")
        #expect(defaults.gradientDefaultTemplateMethod == .allenIAR)

        defaults.gradientDefaultCategory = .template
        let vm = GradientViewModel(store: RecordingStore(), defaults: defaults)
        #expect(vm.method == .allenIAR)
        #expect(!vm.method.isDeprecated)
    }

    @MainActor
    @Test func aRetiredMethodIsHiddenButStillWorks() {
        #expect(MRIGradientMethod.aas.isDeprecated)
        #expect(MRIGradientMethod.aas.deprecationNote != nil)

        // Absent from what the picker offers, present in the full list.
        #expect(!MRIGradientCategory.template.methods.contains(.aas))
        #expect(MRIGradientCategory.template.allMethods.contains(.aas))
        #expect(MRIGradientCategory.template.methods.allSatisfy { !$0.isDeprecated })
        #expect(MRIGradientCategory.fastr.methods.allSatisfy { !$0.isDeprecated })

        // Still routes and still parses, so a file naming it is not orphaned.
        #expect(MRIGradientMethod(rawValue: "AAS") == .aas)
        #expect(MRIGradientMethod.aas.engine == .averageTemplate)
    }

    /// A retired method stays visible in the dropdown while it is the selection,
    /// or the control would render blank for anyone who loaded one.
    @MainActor
    @Test func aSelectedRetiredMethodStaysInTheDropdown() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.method = .mas
        #expect(!vm.selectableMethods.contains(.aas))

        vm.method = .aas
        #expect(vm.selectableMethods.contains(.aas))
        #expect(vm.selectableMethods.last == .aas)
    }

    /// A preference must not keep steering new work onto a withdrawn method,
    /// including one stored before it was retired.
    @MainActor
    @Test func preferencesRefuseARetiredDefault() {
        let defaults = ProcessingDefaults.shared
        let original = defaults.gradientDefaultTemplateMethod
        defer { defaults.gradientDefaultTemplateMethod = original }

        defaults.gradientDefaultTemplateMethod = .mar
        defaults.gradientDefaultTemplateMethod = .aas   // ignored: retired
        #expect(defaults.gradientDefaultTemplateMethod == .mar)
        #expect(!defaults.gradientDefaultTemplateMethod.isDeprecated)
    }

    @MainActor
    @Test func highMotionSetEmptyWhenDisabled() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.excludeHighMotion = false
        #expect(vm.highMotionVolumeSet().isEmpty)
    }

    @MainActor
    @Test func highMotionSetUsesLoadedMotionAndFDThreshold() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.motionParameters = MotionParameters(
            samples: [
                MotionSample(id: 0, roll: 0, pitch: 0, yaw: 0, dS: 0.0, dL: 0, dP: 0),
                MotionSample(id: 1, roll: 0, pitch: 0, yaw: 0, dS: 0.2, dL: 0, dP: 0),
                MotionSample(id: 2, roll: 0, pitch: 0, yaw: 0, dS: 1.2, dL: 0, dP: 0),
                MotionSample(id: 3, roll: 0, pitch: 0, yaw: 0, dS: 1.3, dL: 0, dP: 0)
            ],
            sourceName: "synthetic.1D"
        )
        vm.motionFDThreshold = 0.5
        vm.excludeHighMotion = true

        #expect(vm.highMotionVolumeSet() == [2])
    }

    // MARK: - External motion input staleness (ROADMAP RW-1 item 11)

    private func motionSeries(rows: Int, source: MotionSourceFingerprint?) -> MotionParameters {
        var parameters = MotionParameters(
            samples: (0..<rows).map { index in
                MotionSample(id: index, roll: 0, pitch: 0, yaw: 0, dS: Double(index) * 0.1, dL: 0, dP: 0)
            },
            sourceName: source?.name ?? "motion.1D"
        )
        parameters.source = source
        return parameters
    }

    private var recordedSource: MotionSourceFingerprint {
        MotionSourceFingerprint(name: "run1.1D", byteCount: 4096, modifiedAt: 1_700_000_000, rowCount: 200)
    }

    /// The motion file is an input to the correction that lives outside the
    /// package. Recording it is what lets a replay notice it changed.
    @MainActor
    @Test func gradientStepRecordsWhichMotionFileItUsed() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.excludeHighMotion = true
        vm.motionParameters = motionSeries(rows: 200, source: recordedSource)

        let p = vm.parameters
        #expect(p["motionSourceName"] == "run1.1D")
        #expect(p["motionSourceBytes"] == "4096")
        #expect(p["motionSourceModified"] == "1700000000")
        #expect(p["motionSourceRows"] == "200")

        // Restoring against the same file reports nothing.
        let restored = GradientViewModel(store: RecordingStore())
        restored.motionParameters = motionSeries(rows: 200, source: recordedSource)
        restored.apply(parameters: p)
        #expect(restored.motionSourceMismatch == nil)
        #expect(restored.excludeHighMotion)
    }

    /// A trim changes which volumes are censored, so it changes the recorded
    /// row count even though the file on disk is untouched.
    @MainActor
    @Test func trimmingTheMotionSeriesChangesTheRecordedRowCount() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.excludeHighMotion = true
        vm.motionParameters = motionSeries(rows: 200, source: recordedSource).trimmed(start: 2, end: 0)

        #expect(vm.parameters["motionSourceRows"] == "198")
        #expect(vm.parameters["motionSourceName"] == "run1.1D")
    }

    /// The three ways a restored step's motion input can be wrong, each named
    /// rather than silently corrected with whatever is loaded.
    @MainActor
    @Test func restoringReportsAMismatchedOrMissingMotionInput() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.excludeHighMotion = true
        vm.motionParameters = motionSeries(rows: 200, source: recordedSource)
        let recorded = vm.parameters

        // 1. Nothing loaded at all.
        let empty = GradientViewModel(store: RecordingStore())
        empty.apply(parameters: recorded)
        let missing = try! #require(empty.motionSourceMismatch)
        #expect(missing.contains("run1.1D"))
        #expect(missing.contains("no motion file is loaded"))

        // 2. A different file.
        let other = GradientViewModel(store: RecordingStore())
        other.motionParameters = motionSeries(
            rows: 200,
            source: MotionSourceFingerprint(name: "run2.1D", byteCount: 4096, modifiedAt: 1_700_000_000, rowCount: 200)
        )
        other.apply(parameters: recorded)
        #expect(try! #require(other.motionSourceMismatch).contains("run2.1D"))

        // 3. The same name, edited since — the case a name-only check misses.
        let edited = GradientViewModel(store: RecordingStore())
        edited.motionParameters = motionSeries(
            rows: 200,
            source: MotionSourceFingerprint(name: "run1.1D", byteCount: 4192, modifiedAt: 1_700_009_999, rowCount: 200)
        )
        edited.apply(parameters: recorded)
        let editedMessage = try! #require(edited.motionSourceMismatch)
        #expect(editedMessage.contains("modified since"))
        #expect(editedMessage.contains("4192 B"))
    }

    /// A step from before the fingerprint existed, or one whose correction used
    /// no motion, has nothing to compare — and must not be reported as stale.
    @MainActor
    @Test func aStepWithNoRecordedMotionSourceIsNotAMismatch() {
        let vm = GradientViewModel(store: RecordingStore())
        vm.method = .fastr
        let withoutMotion = vm.parameters
        #expect(withoutMotion["motionSourceName"] == nil)

        let restored = GradientViewModel(store: RecordingStore())
        restored.motionParameters = motionSeries(rows: 10, source: recordedSource)
        restored.apply(parameters: withoutMotion)
        #expect(restored.motionSourceMismatch == nil)
    }
}
