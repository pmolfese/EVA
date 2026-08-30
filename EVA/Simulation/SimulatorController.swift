//
//  SimulatorController.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-1 app-level coordinator, the Simulated Recording window's analogue of
//  `BatchController`. It owns the editable `SimulationConfig` the Generate tabs
//  bind to, the output options, and the top-level mode selection; it runs
//  generation off the main thread through `SimulatorRunner` and reports phase back
//  to `SimulatorWindowView`. Owned by `EVAApp` and injected at the `Window` scene
//  root, like `BatchController`.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class SimulatorController {

    /// Top-level modes of the Simulator studio window. Only `.generate` is
    /// implemented; the others are visible-but-inert placeholders that the shell
    /// makes room for (SIM-1 follow-ups: Score, Sweep, Group).
    enum Mode: String, CaseIterable, Identifiable {
        case generate, score, sweep, group
        var id: String { rawValue }
        var title: String {
            switch self {
            case .generate: return "Generate"
            case .score: return "Score"
            case .sweep: return "Sweep"
            case .group: return "Group"
            }
        }
        var systemImage: String {
            switch self {
            case .generate: return "waveform.badge.plus"
            case .score: return "checkmark.seal"
            case .sweep: return "slider.horizontal.3"
            case .group: return "person.3"
            }
        }
        var isImplemented: Bool { self == .generate || self == .score }
    }

    enum Phase: Equatable {
        case idle
        case generating
        case done
        case failed(String)
    }

    var mode: Mode = .generate

    /// The scenario being authored. Starts from the same defaults the CLI uses
    /// with no flags (`SimulationConfig.default`), so an unedited Generate
    /// reproduces the tool's out-of-the-box recording.
    var config = SimulationConfig.default
    var scenarioName = "Simulated Recording"

    /// Output options (where files go, prefix, source-space truth). The URL is
    /// resolved from an `NSOpenPanel`, so the app holds security-scoped access to
    /// it when the runner copies results there.
    var options = SimulatorRunner.Options()
    var openAfterGenerate = true

    private(set) var phase: Phase = .idle
    private(set) var statusMessage = ""
    private(set) var lastOutput: SimulatorRunner.Output?

    var isGenerating: Bool { phase == .generating }

    // MARK: - Knob adapters
    //
    // Some artifacts are expressed as a magnitude or an optional sub-model rather
    // than a Bool. These map a plain switch onto a sensible enabled value while
    // preserving the underlying knob so the tabs can offer detail when on.

    var blinksEnabled: Bool {
        get { config.blinksPerMinute > 0 }
        set { config.blinksPerMinute = newValue ? 15 : 0 }
    }

    var saccadesEnabled: Bool {
        get { config.saccadesPerMinute > 0 }
        set { config.saccadesPerMinute = newValue ? 20 : 0 }
    }

    var emgEnabled: Bool {
        get { config.emg != nil }
        set { config.emg = newValue ? EMGConfig() : nil }
    }

    var clippingEnabled: Bool {
        get { config.clippingThresholdMicrovolts != nil }
        set { config.clippingThresholdMicrovolts = newValue ? 200 : nil }
    }

    // MARK: - Generation

    /// Generates the recording off the main thread and, on success, calls `open`
    /// with the contaminated `.mff` (only when `openAfterGenerate`).
    func generate(open: @escaping (URL) -> Void) {
        guard phase != .generating else { return }
        phase = .generating
        statusMessage = "Generating…"

        let config = self.config
        let name = scenarioName
        let options = self.options
        let shouldOpen = openAfterGenerate

        Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try SimulatorRunner.generate(config: config, name: name, options: options)
                }.value
                self.lastOutput = output
                self.phase = .done
                self.statusMessage = "Generated \(output.noisyURL.lastPathComponent) in \(output.directory.lastPathComponent)."
                if shouldOpen { open(output.noisyURL) }
            } catch {
                self.lastOutput = nil
                self.phase = .failed(error.localizedDescription)
                self.statusMessage = error.localizedDescription
            }
        }
    }

    /// Re-opens the most recently generated recording without regenerating.
    func reopenLast(open: @escaping (URL) -> Void) {
        guard let output = lastOutput else { return }
        open(output.noisyURL)
    }

    /// Clears a done/failed banner back to the editable state (the tabs stay as
    /// the user left them).
    func clearStatus() {
        phase = .idle
        statusMessage = ""
    }

    // MARK: - Score mode

    /// Ground-truth recording (`_clean.mff`).
    var scoreTruthURL: URL?
    /// The recording after cleaning in EVA — what is being scored.
    var scoreCorrectedURL: URL?
    /// Optional uncorrected recording (`_noisy.mff`), so the table shows what the
    /// correction bought.
    var scoreBaselineURL: URL?

    private(set) var scorePhase: Phase = .idle
    private(set) var scoreMessage = ""
    private(set) var scoreOutcome: SimulatorRunner.ScoreOutcome?

    var isScoring: Bool { scorePhase == .generating }

    /// If a recording was just generated, its clean/noisy files are the obvious
    /// truth/baseline — offer them as a starting point.
    func prefillScoreFromLastGeneration() {
        guard let output = lastOutput else { return }
        scoreTruthURL = output.cleanURL
        scoreBaselineURL = output.noisyURL
    }

    func score() {
        guard scorePhase != .generating else { return }
        guard let truth = scoreTruthURL, let corrected = scoreCorrectedURL else {
            scorePhase = .failed("Choose both a ground-truth and a corrected recording.")
            return
        }
        scorePhase = .generating
        scoreMessage = "Scoring…"
        let baseline = scoreBaselineURL

        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try SimulatorRunner.score(truth: truth, corrected: corrected, baseline: baseline)
                }.value
                self.scoreOutcome = outcome
                self.scorePhase = .done
                self.scoreMessage = "Scored \(corrected.lastPathComponent)."
            } catch {
                self.scoreOutcome = nil
                self.scorePhase = .failed(error.localizedDescription)
                self.scoreMessage = error.localizedDescription
            }
        }
    }

    func clearScoreStatus() {
        scorePhase = .idle
        scoreMessage = ""
    }
}
