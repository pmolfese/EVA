//
//  ChannelHealthViewModelTests.swift
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

struct ChannelHealthViewModelTests {

    @MainActor
    @Test func defaultsMatchExpectedInitialState() {
        let vm = ChannelHealthViewModel(store: RecordingStore())
        #expect(vm.statusMessage == nil)
        #expect(vm.signature == nil)
        #expect(vm.task == nil)
        #expect(!vm.showsDetails)
        #expect(vm.detailsRequest == 0)
    }

    @MainActor
    @Test func detailsRequestIncrementsIndependentlyOfShowsDetails() {
        let vm = ChannelHealthViewModel(store: RecordingStore())
        vm.showsDetails = true
        vm.detailsRequest += 1
        vm.detailsRequest += 1

        #expect(vm.showsDetails)
        #expect(vm.detailsRequest == 2)
    }

    @MainActor
    @Test func trackedTaskCanBeCancelledThroughTheStore() async {
        let vm = ChannelHealthViewModel(store: RecordingStore())
        var didRun = false
        vm.task = Task {
            didRun = true
        }
        _ = await vm.task?.value
        #expect(didRun)

        vm.task = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        vm.task?.cancel()
        #expect(vm.task?.isCancelled == true)
    }
}

struct ChannelGoodnessSettingsTests {
    @MainActor
    @Test func automaticWaveletsDefaultPersistAndRestore() throws {
        let suite = "ChannelGoodnessSettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ChannelGoodnessSettings(defaults: defaults)
        #expect(settings.runWaveletsAutomatically)
        settings.runWaveletsAutomatically = false
        #expect(!ChannelGoodnessSettings(defaults: defaults).runWaveletsAutomatically)
        settings.restoreDefaults()
        #expect(ChannelGoodnessSettings(defaults: defaults).runWaveletsAutomatically)
    }

    @MainActor
    @Test func oldPreferencesEnableAutomaticWaveletsAndKeepCustomSettings() throws {
        let suite = "ChannelGoodnessSettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ChannelGoodnessSettings(defaults: defaults)
        settings.wavelet.levelCount = 4
        let data = try #require(defaults.data(forKey: "ChannelGoodnessSettings.v1"))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "runWaveletsAutomatically")
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "ChannelGoodnessSettings.v1")
        let restored = ChannelGoodnessSettings(defaults: defaults)
        #expect(restored.runWaveletsAutomatically)
        #expect(restored.wavelet.levelCount == 4)
    }
}
