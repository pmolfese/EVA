//
//  SimulationScenario.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  A stable, human-readable envelope for a complete SimulationConfig. Keeping
//  schema metadata outside the configuration lets the model evolve without
//  confusing a scenario's identity and description with simulation inputs.
//

import Foundation

nonisolated struct SimulationScenario: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var name: String
    var description: String
    var config: SimulationConfig
}

nonisolated enum SimulationScenarioFile {
    static func load(from url: URL) throws -> SimulationScenario {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SimulateError.io("could not read scenario \(url.path): \(error.localizedDescription)")
        }

        let scenario: SimulationScenario
        do {
            scenario = try JSONDecoder().decode(SimulationScenario.self, from: data)
        } catch {
            throw SimulateError.io(
                "could not decode scenario \(url.path): \(error.localizedDescription)"
            )
        }
        guard scenario.schemaVersion == SimulationScenario.currentSchemaVersion else {
            throw SimulateError.io(
                "scenario \(url.path) uses schemaVersion \(scenario.schemaVersion); "
                + "this build supports \(SimulationScenario.currentSchemaVersion)"
            )
        }

        var resolved = scenario
        if let path = resolved.config.gradientTemplatePath,
           !(path as NSString).isAbsolutePath {
            resolved.config.gradientTemplatePath = url.deletingLastPathComponent()
                .appendingPathComponent(path).standardizedFileURL.path
        }
        return resolved
    }

    static func write(
        config: SimulationConfig,
        to url: URL,
        name: String? = nil,
        description: String = "Resolved EVA Simulate scenario"
    ) throws {
        let scenarioName = name ?? url.deletingPathExtension().lastPathComponent
        let scenario = SimulationScenario(
            name: scenarioName,
            description: description,
            config: config
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try encoder.encode(scenario).write(to: url, options: .atomic)
        } catch {
            throw SimulateError.io("could not write scenario \(url.path): \(error.localizedDescription)")
        }
    }
}
