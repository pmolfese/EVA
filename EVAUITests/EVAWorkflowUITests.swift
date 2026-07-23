//
//  EVAWorkflowUITests.swift
//  EVAUITests
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
//  End-to-end UI tests driving real multi-step processing workflows against
//  the fixture recordings in resources/testFiles. These are not part of the
//  regular fast test suite (large real recordings, several minutes each) —
//  run explicitly via -only-testing:EVAUITests/EVAWorkflowUITests.
//

import XCTest

final class EVAWorkflowUITests: XCTestCase {
    var app: XCUIApplication!
    private let heavyOperationTimeout: TimeInterval = 360

    override func setUpWithError() throws {
        continueAfterFailure = false
        addSystemDialogMonitor()
        app = XCUIApplication()
        app.launch()
        dismissSystemDialogs()
    }

    override func tearDownWithError() throws {
        attach("99-final-\(sanitizedTestName)")
        app = nil
    }

    // MARK: - Workflow 1: flanker — filter/notch, ocular artifacts, PSA segment+average

    @MainActor
    func testFlankerFilterArtifactsAndPSA() throws {
        openRecording("/Users/molfesepj/Documents/Programming/EVA/resources/testFiles/24624_flanker_run1_20240322_053029.mff")
        attach("01-loaded")

        // Filter: IIR Notch, Apply.
        clickButton("Filter")
        app.radioButtons["IIR Notch"].firstMatch.click()
        attach("02-filter-notch-selected")
        app.typeKey(.return, modifierFlags: [])
        waitForToolbarOperationToFinish(button: "Filter")
        attach("03-filter-applied")

        // Artifacts: Eye Blink + Eye Movement (auto-detect on toggle).
        clickToolbarMenuItem(toolbar: "Artifacts", item: "Eye Blink")
        waitForIdle()
        clickToolbarMenuItem(toolbar: "Artifacts", item: "Eye Movement")
        waitForIdle()
        attach("04-ocular-artifacts-enabled")

        // Processing > Segment...
        clickToolbarMenuItem(toolbar: "Processing", item: "Segment…")
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "PSA sheet didn't appear")
        attach("05-psa-sheet-opened")

        for code in ["LC++", "LI++", "RC++", "RI++"] {
            selectPSAEventCode(in: sheet, code: code)
        }
        attach("06-event-codes-selected")

        setToggle(in: sheet, labelPrefix: "Skip if contains artifact", on: true)
        setToggle(in: sheet, labelPrefix: "Eye Blink", on: true)
        setToggle(in: sheet, labelPrefix: "Eye Movement", on: true)
        setToggle(in: sheet, labelPrefix: "Average by category", on: true)
        setToggle(in: sheet, labelPrefix: "Average reference", on: true)
        setToggle(in: sheet, labelPrefix: "Baseline correct (pre-stimulus)", on: true)
        attach("07-psa-options-set")

        let applyButton = sheet.buttons["Apply"]
        XCTAssertTrue(applyButton.waitForExistence(timeout: 5))
        XCTAssertTrue(applyButton.isEnabled, "PSA Apply should be enabled once codes are selected")
        applyButton.click()
        waitForPSAOperationToFinish(sheet)
        attach("08-psa-applied")
    }

    // MARK: - Workflow 2: NEF — AAS + motion, IIR notch, BCG Spatial PCA, OBS clean, PSA on "Stim"

    @MainActor
    func testNEFMotionBCGAndPSA() throws {
        openRecording("/Users/molfesepj/Documents/Programming/EVA/resources/testFiles/NEF_S02/NEF_S02_Naming2_Run1_20220407_033054.mff")
        attach("01-loaded")

        // MRI: AAS method, load motion file, skip 82 TREV events.
        clickButton("MRI")
        app.radioButtons["AAS"].firstMatch.click()
        attach("02-mri-aas-selected")

        app.buttons["Configure Motion…"].firstMatch.click()
        let motionSheet = app.sheets.firstMatch
        XCTAssertTrue(motionSheet.waitForExistence(timeout: 5), "Motion config sheet didn't appear")
        motionSheet.buttons["Load Motion File…"].firstMatch.click()
        chooseFile(filePath: "/Users/molfesepj/Documents/Programming/EVA/resources/testFiles/NEF_S02/motion_run1.1D")
        attach("03-motion-file-loaded")
        motionSheet.buttons["Done"].firstMatch.click()
        XCTAssertTrue(motionSheet.waitForNonExistence(timeout: 10), "Motion sheet never dismissed")

        // The app-modal NSOpenPanel used to load the motion file can leave the
        // main window without key status, so the next "MRI" click sometimes
        // doesn't register as opening the popover — retry until it does.
        let trMarkerLabel = app.staticTexts["TR Marker Event"]
        for _ in 0..<5 where !trMarkerLabel.exists {
            app.activate()
            clickButton("MRI", timeout: 3)
            _ = trMarkerLabel.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(trMarkerLabel.exists, "MRI popover never reopened after Configure Motion")

        let skipFields = app.textFields.matching(NSPredicate(format: "value == '0'"))
        let skipFirstField = skipFields.element(boundBy: 0)
        XCTAssertTrue(skipFirstField.waitForExistence(timeout: 5), "Skip First field not found")
        skipFirstField.click()
        skipFirstField.typeKey("a", modifierFlags: [.command])
        skipFirstField.typeText("82")
        skipFirstField.typeKey(.tab, modifierFlags: [])
        attach("04-mri-skip-set")
        app.buttons["Apply"].firstMatch.click()
        waitForToolbarOperationToFinish(button: "MRI")
        attach("05-mri-applied")

        // Filter: IIR Notch, Apply.
        clickButton("Filter")
        app.radioButtons["IIR Notch"].firstMatch.click()
        app.typeKey(.return, modifierFlags: [])
        waitForToolbarOperationToFinish(button: "Filter")
        attach("06-filter-applied")

        // Artifacts: BCG Detection with Spatial PCA.
        clickToolbarMenuItem(toolbar: "Artifacts", item: "BCG Detection…")
        let bcgSheet = app.sheets.firstMatch
        XCTAssertTrue(bcgSheet.waitForExistence(timeout: 5), "BCG sheet didn't appear")
        bcgSheet.radioButtons["Spatial PCA"].firstMatch.click()
        attach("07-bcg-spatial-pca-selected")
        bcgSheet.buttons["Detect BCG"].firstMatch.click()
        waitForBCGDetectionToFinish(bcgSheet)
        attach("08-bcg-detected")
        // Successful BCG detection closes the sheet; close it manually only if
        // the detector stayed open after producing no events.
        if bcgSheet.exists {
            bcgSheet.buttons["Cancel"].firstMatch.click()
            XCTAssertTrue(bcgSheet.waitForNonExistence(timeout: 10), "BCG sheet never dismissed")
        }

        // Artifacts: Clean Artifacts... -> Treatment = OBS -> Apply.
        clickToolbarMenuItem(toolbar: "Artifacts", item: "Clean Artifacts…")
        let cleanSheet = app.sheets.firstMatch
        XCTAssertTrue(cleanSheet.waitForExistence(timeout: 5), "Clean Artifacts sheet didn't appear")
        attach("09-clean-artifacts-opened")
        let cleanApplyButton = cleanSheet.buttons["Apply"].firstMatch
        XCTAssertTrue(cleanApplyButton.waitForExistence(timeout: 5), "Clean Artifacts Apply button not found")
        XCTAssertTrue(cleanApplyButton.isEnabled, "Clean Artifacts Apply should be enabled for the BCG artifact")
        attach("10-obs-selected")
        cleanApplyButton.click()
        waitForArtifactCleaningToFinish(cleanSheet)
        attach("11-obs-applied")
        cleanSheet.buttons["Close"].firstMatch.click()

        // Processing > Segment on "Stim", no interpolate, average + reference + baseline.
        clickToolbarMenuItem(toolbar: "Processing", item: "Segment…")
        let psaSheet = app.sheets.firstMatch
        XCTAssertTrue(psaSheet.waitForExistence(timeout: 5), "PSA sheet didn't appear")
        selectPSAEventCode(in: psaSheet, code: "Stim")

        setToggle(in: psaSheet, labelPrefix: "Average by category", on: true)
        setToggle(in: psaSheet, labelPrefix: "Average reference", on: true)
        setToggle(in: psaSheet, labelPrefix: "Baseline correct (pre-stimulus)", on: true)
        attach("12-psa-options-set")

        let applyButton = psaSheet.buttons["Apply"]
        XCTAssertTrue(applyButton.waitForExistence(timeout: 5))
        applyButton.click()
        waitForPSAOperationToFinish(psaSheet)
        attach("13-psa-applied")
    }

    // MARK: - Shared helpers

    private func openRecording(_ path: String) {
        let openButton = app.buttons["Open Recording..."]
        XCTAssertTrue(openButton.waitForExistence(timeout: 10), "Launch screen Open Recording button not found")
        openButton.click()
        let panel = app.sheets["open-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "Open panel didn't appear")
        panel.typeKey("g", modifierFlags: [.command, .shift])
        let goToField = app.textFields.firstMatch
        XCTAssertTrue(goToField.waitForExistence(timeout: 5))
        goToField.typeText(path)
        goToField.typeKey(.return, modifierFlags: [])
        sleep(1)
        panel.buttons["Open"].firstMatch.click()
        waitForRecordingToolbarReady()
    }

    /// Opens an already-open panel (`app.sheets["open-panel"]` or an app-modal
    /// `NSOpenPanel` dialog) directly to `filePath` via Cmd+Shift+G. Typing the
    /// *file's* full path (not just its containing folder) into "Go to Folder"
    /// navigates there and pre-selects the file, so a second Return opens it
    /// directly — avoids clicking the file row, which can land on a stale/
    /// mid-scroll hit point right after the folder navigates.
    private func chooseFile(filePath: String) {
        let panel = app.sheets["open-panel"].exists ? app.sheets["open-panel"] : app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        panel.typeKey("g", modifierFlags: [.command, .shift])
        let goToField = app.textFields.firstMatch
        XCTAssertTrue(goToField.waitForExistence(timeout: 5))
        goToField.typeText(filePath)
        goToField.typeKey(.return, modifierFlags: [])
        sleep(1)
        panel.typeKey(.return, modifierFlags: [])
    }

    /// Clicks a toolbar button/menu (e.g. "Artifacts", "Processing") then a menu item inside it.
    private func clickToolbarMenuItem(toolbar: String, item: String) {
        app.menuButtons[toolbar].firstMatch.click()
        let menuItem = app.menuItems[item]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "Menu item '\(item)' not found under \(toolbar)")
        menuItem.click()
    }

    /// Selects one PSA event code's checkbox (e.g. "LC++", "Stim"). The row's
    /// AX label is "<code>, Labels: <code>" (VStack of code + label-detail
    /// Text), so we match with a prefix predicate rather than an exact one.
    /// Matching rows can be scrolled out of the sheet's fixed-height list, so
    /// this types into "Filter events" first to narrow the list down to one
    /// visible row, then clears the filter for the next call.
    private func selectPSAEventCode(in sheet: XCUIElement, code: String) {
        let searchField = sheet.textFields["Filter events"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.click()
        searchField.typeText(code)

        let toggle = sheet.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", code)).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Missing event code row: \(code)")
        toggle.click()

        searchField.click()
        searchField.typeKey("a", modifierFlags: [.command])
        searchField.typeKey(.delete, modifierFlags: [])
    }

    /// Sets a checkbox-style Toggle on/off within `scope`, matched by a label
    /// prefix — several Toggles in these sheets pair their nominal title with
    /// trailing detail text (e.g. "Eye Blink, Default detector"), so an exact
    /// match on the title alone fails.
    private func setToggle(in scope: XCUIElement, labelPrefix: String, on: Bool) {
        let target = scope.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix)).firstMatch
        guard target.waitForExistence(timeout: 5) else {
            XCTFail("Toggle '\(labelPrefix)' not found")
            return
        }
        let isOn = (target.value as? String) == "1" || (target.value as? Bool) == true
        if isOn != on {
            target.click()
        }
    }

    private func waitForIdle() {
        sleep(2)
    }

    /// The waveform toolbar appears before a large recording has finished
    /// loading, but its controls stay disabled until the file is actually
    /// ready. Wait on enabled state so the first workflow click cannot land on
    /// a stale loading-screen toolbar element.
    private func waitForRecordingToolbarReady(timeout: TimeInterval = 120) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            dismissSystemDialogs()
            let filter = app.buttons["Filter"].firstMatch
            if filter.exists, filter.isEnabled {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTFail("Waveform toolbar never became ready")
    }

    private func clickButton(_ label: String, timeout: TimeInterval = 10) {
        dismissSystemDialogs()
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "\(label) button not found")
        waitForElementToEnable(button, timeout: timeout, description: "\(label) button")
        button.click()
    }

    private func waitForElementToEnable(_ element: XCUIElement, timeout: TimeInterval, description: String) {
        let enabled = NSPredicate(format: "isEnabled == true")
        let enabledExpectation = XCTNSPredicateExpectation(predicate: enabled, object: element)
        let result = XCTWaiter.wait(for: [enabledExpectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(description) never enabled")
    }

    /// Waits for a toolbar-backed operation to complete. Successful operations
    /// leave their last status message in the toolbar, so waiting for literal
    /// "Ready" is stale; the toolbar button itself is disabled while work runs.
    private func waitForToolbarOperationToFinish(button label: String, timeout: TimeInterval = 180) {
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(label) toolbar button not found")
        waitForBriefDisableThenEnable(button, timeout: timeout, description: "\(label) operation")
    }

    private func waitForPSAOperationToFinish(_ sheet: XCUIElement) {
        XCTAssertTrue(sheet.waitForNonExistence(timeout: heavyOperationTimeout), "PSA sheet never dismissed after Apply")
        dismissSystemDialogs()
    }

    private func waitForBCGDetectionToFinish(_ sheet: XCUIElement) {
        let bcgEventFilter = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "BCG,")).firstMatch
        let deadline = Date().addingTimeInterval(heavyOperationTimeout)
        while Date() < deadline {
            if bcgEventFilter.exists {
                XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "BCG sheet did not dismiss after detecting events")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTFail("BCG detection never produced BCG events")
    }

    private func waitForArtifactCleaningToFinish(_ sheet: XCUIElement) {
        waitForSheetButtonCycle(sheet, button: "Apply", description: "Artifact cleaning")
    }

    /// Waits for a sheet operation by watching a control that is disabled only
    /// while processing is active. The sheet itself stays open after successful
    /// processing, so the test closes it explicitly after capturing the result.
    private func waitForSheetButtonCycle(
        _ sheet: XCUIElement,
        button label: String,
        description: String,
        timeout: TimeInterval = 360
    ) {
        let button = sheet.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(label) button not found")
        waitForBriefDisableThenEnable(button, timeout: timeout, description: description)
    }

    private func waitForBriefDisableThenEnable(_ element: XCUIElement, timeout: TimeInterval, description: String) {
        waitForBriefDisable(element)

        let enabled = NSPredicate(format: "isEnabled == true")
        let enabledExpectation = XCTNSPredicateExpectation(predicate: enabled, object: element)
        let result = XCTWaiter.wait(for: [enabledExpectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(description) never finished")
    }

    private func waitForBriefDisable(_ element: XCUIElement) {
        let disabled = NSPredicate(format: "isEnabled == false")

        let disabledExpectation = XCTNSPredicateExpectation(predicate: disabled, object: element)
        _ = XCTWaiter.wait(for: [disabledExpectation], timeout: 3)
    }

    private func addSystemDialogMonitor() {
        addUIInterruptionMonitor(withDescription: "System permission dialogs") { alert in
            for title in ["Allow", "OK"] {
                let button = alert.buttons[title].firstMatch
                if button.exists {
                    button.click()
                    return true
                }
            }
            return false
        }
    }

    private func dismissSystemDialogs() {
        let allow = app.buttons["Allow"].firstMatch
        if allow.exists {
            allow.click()
        }
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var sanitizedTestName: String {
        name
            .replacingOccurrences(of: "EVAWorkflowUITests.", with: "")
            .replacingOccurrences(of: "()", with: "")
    }
}
