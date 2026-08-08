//
//  ProcessingQueue.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Serializes EVA's major processing operations (filter, gradient correction,
//  ICA, wavelet reduction, artifact cleaning, channel/segment health, PSA
//  segmentation, BCG detection) so at most one runs at a time, even if the
//  user triggers several in quick succession from different panels. Each of
//  these operations independently assumes it can use up to `evaMaxWorkers`
//  (activeProcessorCount - 2) cores; running two at once means they fight
//  over the same core budget instead of the intended "leave some cores free"
//  guarantee, and BOTH finish slower than if they'd simply run back to back.
//

import Combine
import SwiftUI

@MainActor
final class ProcessingQueue: ObservableObject {
    struct QueuedOperation: Identifiable, Equatable {
        let id = UUID()
        let label: String
    }

    /// Operations waiting or currently running, in FIFO order. `queue.first`
    /// (if any) is the one currently executing; the rest are waiting their turn.
    @Published private(set) var queue: [QueuedOperation] = []
    private var tail: Task<Void, Never>?

    var isBusy: Bool { !queue.isEmpty }
    var currentLabel: String? { queue.first?.label }
    /// Labels waiting behind the currently-running operation, in order.
    var waitingLabels: [String] { queue.dropFirst().map(\.label) }

    /// Enqueues `operation`, running it only after everything already queued
    /// has finished, and returning once `operation` itself completes. Safe to
    /// call from multiple places "simultaneously" — the synchronous prefix of
    /// this method (append to queue, chain onto the previous tail) can't
    /// interleave with another call, since MainActor methods only yield at an
    /// `await`, so FIFO order is guaranteed regardless of call order.
    func run(_ label: String, operation: @escaping @MainActor () async -> Void) async {
        let entry = QueuedOperation(label: label)
        queue.append(entry)

        let previousTail = tail
        let newTail = Task { @MainActor [weak self] in
            await previousTail?.value
            await operation()
            self?.queue.removeAll { $0.id == entry.id }
        }
        tail = newTail
        await newTail.value
    }
}
