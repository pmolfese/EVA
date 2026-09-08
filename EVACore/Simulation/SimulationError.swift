//
//  SimulationError.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Shared error type for the in-app simulator. Extracted from SimulationWriter so
//  the generation core (ERPGenerator, GradientArtifactModel, SimulationScenario)
//  can throw it without depending on the CLI-side writer/metrics files, which are
//  not compiled into the app target.
//

import Foundation

nonisolated enum SimulateError: LocalizedError {
    case badTemplate(String)
    case usage(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .badTemplate(let detail): return "Bad gradient template: \(detail)"
        case .usage(let detail): return detail
        case .io(let detail): return detail
        }
    }
}
