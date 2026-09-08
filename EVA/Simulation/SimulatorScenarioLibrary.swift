//
//  SimulatorScenarioLibrary.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-1 — the bundled scenario presets. `Tools/EVASimulate/scenarios` is copied
//  into the app as a folder reference (single source of truth with the CLI's own
//  copy), and these presets are the same `SimulationScenario` artifacts the CLI
//  reads, so a GUI starting point round-trips exactly.
//

import Foundation

nonisolated enum SimulatorScenarioLibrary {

    struct Preset: Identifiable, Sendable {
        let id = UUID()
        let url: URL
        let name: String
        let description: String
    }

    /// The bundled presets, parsed once on first access.
    static let all: [Preset] = load()

    /// Resolves a preset back to its `SimulationConfig` and name.
    static func config(for preset: Preset) -> (config: SimulationConfig, name: String)? {
        guard let scenario = try? SimulationScenarioFile.load(from: preset.url) else { return nil }
        return (scenario.config, scenario.name)
    }

    private static func load() -> [Preset] {
        guard let urls = Bundle.main.urls(
            forResourcesWithExtension: "json", subdirectory: "scenarios"
        ) else { return [] }
        return urls
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let scenario = try? SimulationScenarioFile.load(from: url) else { return nil }
                return Preset(url: url, name: scenario.name, description: scenario.description)
            }
    }
}
