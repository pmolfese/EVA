//
//  OperationProgressCenter.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Single owner of in-flight operation progress, replacing the per-view-model
//  `operationProgress` properties (`REWIND.md` work item 9, "progress
//  consolidation").
//
//  Why this exists rather than each view model keeping its own:
//
//  - **One consumer, one source.** The toolbar status area previously reached
//    into `gradient.operationProgress` and `filter.operationProgress` by name, so
//    every new long-running stage meant editing the status view too. It now reads
//    one ordered list, and a new stage appears simply by reporting into it.
//  - **`REWIND.md` needs it.** The history tree's Queue tab is the single surface
//    that shows what is running, regardless of which stage owns it. That is not
//    expressible while progress is scattered across view models.
//  - **It pairs with `ProcessingQueue`.** That already serializes *which*
//    operation runs; this holds *how far along* it is. Together they are the
//    "queue and tree are one state machine" model REWIND describes.
//
//  Ordering is insertion order, so the status area lists operations in the order
//  they started rather than in an arbitrary dictionary order.
//
//  Migration note: `GradientViewModel` and `FilterViewModel` keep an
//  `operationProgress` property, but it is now a computed forwarder into this
//  center keyed by the operation's own `source`. That kept the migration to two
//  small edits per view model instead of rewriting their progress plumbing, and
//  it means any future stage can join by adding the same forwarder.
//

import SwiftUI

@Observable
final class OperationProgressCenter {
    /// In-flight operations, in the order they started.
    private(set) var operations: [OperationProgress] = []

    var isEmpty: Bool { operations.isEmpty }

    func progress(for source: String) -> OperationProgress? {
        operations.first { $0.source == source }
    }

    /// Publishes (or clears, when `progress` is nil) the progress for a source.
    ///
    /// Keyed by `source` rather than by a caller-supplied token because
    /// `OperationProgress` already carries it, which keeps the two from drifting.
    func set(_ progress: OperationProgress?, for source: String) {
        guard let progress else {
            operations.removeAll { $0.source == source }
            return
        }

        if let index = operations.firstIndex(where: { $0.source == source }) {
            operations[index] = progress
        } else {
            operations.append(progress)
        }
    }

    /// Drops everything. Used when a recording closes.
    func reset() {
        operations.removeAll()
    }
}
