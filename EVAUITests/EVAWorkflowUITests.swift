//
//  EVAWorkflowUITests.swift
//  EVAUITests
//
//  End-to-end UI tests driving real multi-step processing workflows against
//  the fixture recordings in resources/testFiles. These are not part of the
//  regular fast test suite (large real recordings, several minutes each) —
//  run explicitly via -only-testing:EVAUITests/EVAWorkflowUITests.
//

import XCTest

final class EVAWorkflowUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    // MARK: - Workflow 1: flanker — filter/notch, ocular artifacts, PSA segment+average

    @MainActor
    func testFlankerFilterArtifactsAndPSA() throws {
        openRecording("/Users/molfesepj/Documents/Programming/EVA/resources/testFiles/24624_flanker_run1_20240322_053029.mff")
        attach("01-loaded")

        // Filter: IIR Notch, Apply.
        app.buttons["Filter"].click()
        app.radioButtons["IIR Notch"].firstMatch.click()
        attach("02-filter-notch-selected")
        app.buttons["Apply Filter"].firstMatch.click()
        waitForAppReady()
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
        setToggle(in: sheet, labelPrefix: "Interpolate bad channels per epoch", on: true)
        setToggle(in: sheet, labelPrefix: "Average by category", on: true)
        setToggle(in: sheet, labelPrefix: "Average reference", on: true)
        setToggle(in: sheet, labelPrefix: "Baseline correct (pre-stimulus)", on: true)
        attach("07-psa-options-set")

        let applyButton = sheet.buttons["Apply"]
        XCTAssertTrue(applyButton.waitForExistence(timeout: 5))
        XCTAssertTrue(applyButton.isEnabled, "PSA Apply should be enabled once codes are selected")
        applyButton.click()
        waitForSheetBusyIndicator(sheet, timeout: 90)
        attach("08-psa-applied")
    }

    // MARK: - Workflow 2: NEF — AAS + motion, IIR notch, BCG Spatial PCA, OBS clean, PSA on "Stim"

    @MainActor
    func testNEFMotionBCGAndPSA() throws {
        openRecording("/Users/molfesepj/Documents/Programming/EVA/resources/testFiles/NEF_S02/NEF_S02_Naming2_Run1_20220407_033054.mff")
        attach("01-loaded")

        // MRI: AAS method, load motion file, skip 82 TREV events.
        app.buttons["MRI"].click()
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
            app.buttons["MRI"].click()
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
        waitForAppReady()
        attach("05-mri-applied")

        // Filter: IIR Notch, Apply.
        app.buttons["Filter"].click()
        app.radioButtons["IIR Notch"].firstMatch.click()
        app.buttons["Apply Filter"].firstMatch.click()
        waitForAppReady()
        attach("06-filter-applied")

        // Artifacts: BCG Detection with Spatial PCA.
        clickToolbarMenuItem(toolbar: "Artifacts", item: "BCG Detection…")
        let bcgSheet = app.sheets.firstMatch
        XCTAssertTrue(bcgSheet.waitForExistence(timeout: 5), "BCG sheet didn't appear")
        bcgSheet.radioButtons["Spatial PCA"].firstMatch.click()
        attach("07-bcg-spatial-pca-selected")
        bcgSheet.buttons["Detect BCG"].firstMatch.click()
        // The sheet shows a spinner only while bcg.isRunning; wait for it to
        // clear rather than for any particular downstream UI to appear.
        waitForSheetBusyIndicator(bcgSheet, timeout: 90)
        attach("08-bcg-detected")
        // BCG sheet has no explicit "Done"; Cancel just closes without undoing detection.
        bcgSheet.buttons["Cancel"].firstMatch.click()

        // Artifacts: Clean Artifacts... -> Treatment = OBS -> Apply.
        clickToolbarMenuItem(toolbar: "Artifacts", item: "Clean Artifacts…")
        let cleanSheet = app.sheets.firstMatch
        XCTAssertTrue(cleanSheet.waitForExistence(timeout: 5), "Clean Artifacts sheet didn't appear")
        attach("09-clean-artifacts-opened")
        cleanSheet.popUpButtons.firstMatch.click()
        app.menuItems["OBS"].firstMatch.click()
        attach("10-obs-selected")
        cleanSheet.buttons["Apply"].firstMatch.click()
        waitForSheetBusyIndicator(cleanSheet, timeout: 90)
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
        waitForSheetBusyIndicator(psaSheet, timeout: 90)
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
        // The toolbar renders as soon as the recording view appears — no need
        // to wait for full background processing ("Ready") before proceeding.
        XCTAssertTrue(app.buttons["Filter"].waitForExistence(timeout: 30), "Waveform toolbar never appeared")
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

    /// Waits for a sheet's own busy spinner (shown only while its operation is
    /// actually running) to clear, instead of guessing a fixed delay or
    /// waiting on unrelated downstream UI.
    private func waitForSheetBusyIndicator(_ sheet: XCUIElement, timeout: TimeInterval) {
        let spinner = sheet.progressIndicators.firstMatch
        _ = spinner.waitForExistence(timeout: 3)
        if spinner.exists {
            XCTAssertTrue(spinner.waitForNonExistence(timeout: timeout), "Operation never finished")
        }
    }

    /// Waits for the toolbar status area to read "Ready" again — it only
    /// shows that once every tracked background operation (filter, MRI
    /// gradient, wavelet, health, …) has actually finished, all funneled
    /// through one serial processing queue. First waits for it to briefly
    /// go non-"Ready" (confirming the just-started operation actually began
    /// before we start polling for completion — clicking Apply doesn't flip
    /// the underlying `isProcessing`/`isFiltering` flags synchronously, and
    /// operations queue behind each other), tolerating an operation so fast
    /// it never visibly leaves "Ready" in the first place.
    private func waitForAppReady(timeout: TimeInterval = 180) {
        let ready = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Ready'")).firstMatch
        _ = ready.waitForNonExistence(timeout: 5)
        XCTAssertTrue(ready.waitForExistence(timeout: timeout), "App never returned to Ready")
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
