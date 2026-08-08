//
//  OperationProgress.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation

/// Shared live progress presented by long-running toolbar operations.
nonisolated struct OperationProgress: Sendable, Equatable {
    enum StageState: Sendable, Equatable {
        case pending
        case active
        case complete
    }

    struct Stage: Sendable, Equatable, Identifiable {
        let name: String
        let state: StageState

        var id: String { name }
    }

    let source: String
    let title: String
    let subtitle: String
    let phase: String
    let detail: String?
    let fraction: Double
    let stages: [Stage]
    let startedAt: Date

    var clampedFraction: Double { min(max(fraction, 0), 1) }

    func updating(
        fraction: Double,
        phase: String,
        detail: String? = nil,
        activeStage: Int
    ) -> OperationProgress {
        OperationProgress(
            source: source,
            title: title,
            subtitle: subtitle,
            phase: phase,
            detail: detail,
            fraction: min(max(fraction, 0), 1),
            stages: stages.enumerated().map { index, stage in
                Stage(
                    name: stage.name,
                    state: index < activeStage ? .complete : (index == activeStage ? .active : .pending)
                )
            },
            startedAt: startedAt
        )
    }

    static func started(
        source: String,
        title: String,
        subtitle: String,
        phase: String,
        stages: [String]
    ) -> OperationProgress {
        OperationProgress(
            source: source,
            title: title,
            subtitle: subtitle,
            phase: phase,
            detail: nil,
            fraction: 0,
            stages: stages.enumerated().map { index, name in
                Stage(name: name, state: index == 0 ? .active : .pending)
            },
            startedAt: Date()
        )
    }
}
