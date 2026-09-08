//
//  ERPTruth.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Shared ERP ground-truth model types. Extracted from RichMetrics so the ERP
//  generator (generation core, compiled into the app) can emit these without
//  pulling in the CLI-side metrics files. The scoring side (RichMetrics,
//  ERPEvaluation, SelfTest) consumes the same types from the CLI target.
//

import Foundation

nonisolated struct ERPComponent: Codable, Sendable {
    var id: String
    var peakLatencySeconds: Double
    var peakAmplitudeMicrovolts: Double
}

nonisolated struct ERPComponentSet: Codable, Sendable {
    var components: [ERPComponent]
}
