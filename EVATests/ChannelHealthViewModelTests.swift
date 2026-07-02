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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//

import Testing
import Foundation
@testable import EVA

struct ChannelHealthViewModelTests {

    @MainActor
    @Test func defaultsMatchExpectedInitialState() {
        let vm = ChannelHealthViewModel()
        #expect(vm.statusMessage == nil)
        #expect(vm.signature == nil)
        #expect(vm.task == nil)
        #expect(!vm.showsDetails)
        #expect(vm.detailsRequest == 0)
    }

    @MainActor
    @Test func detailsRequestIncrementsIndependentlyOfShowsDetails() {
        let vm = ChannelHealthViewModel()
        vm.showsDetails = true
        vm.detailsRequest += 1
        vm.detailsRequest += 1

        #expect(vm.showsDetails)
        #expect(vm.detailsRequest == 2)
    }

    @MainActor
    @Test func trackedTaskCanBeCancelledThroughTheStore() async {
        let vm = ChannelHealthViewModel()
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
