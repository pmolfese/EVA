//
//  InterpolatedSignalResolver.swift
//  EVA
//
//  Resolves recipe-based channel interpolation once per processed-signal and
//  interpolation revision. Heavy sample composition never runs from a SwiftUI
//  body update.
//

import Foundation
import Observation

@Observable
final class InterpolatedSignalResolver {
    nonisolated struct Key: Hashable, Sendable {
        let signalRevision: UUID
        let interpolationRevision: Int
    }

    private var cachedKey: Key?
    private var cachedSignal: MFFSignalData?
    private var latestRequestedKey: Key?
    private(set) var isResolving = false

    /// Diagnostic counter used by regression tests and performance debugging.
    @ObservationIgnored private(set) var computationCount = 0

    func key(
        for signal: MFFSignalData,
        snapshot: ChannelInterpolationSnapshot
    ) -> Key {
        Key(
            signalRevision: signal.dataRevision,
            interpolationRevision: snapshot.revision
        )
    }

    func cachedSignal(for key: Key) -> MFFSignalData? {
        cachedKey == key ? cachedSignal : nil
    }

    /// Rebuilds the resolved signal away from the main actor. Call this from a
    /// `.task(id:)`; changing the key cancels the old view task, while the final
    /// key check prevents a completed stale calculation from being published.
    func resolve(
        signal: MFFSignalData,
        snapshot: ChannelInterpolationSnapshot
    ) async {
        let requestedKey = key(for: signal, snapshot: snapshot)
        guard cachedKey != requestedKey else { return }

        latestRequestedKey = requestedKey
        isResolving = true
        computationCount += 1

        let resolved = await Task.detached(priority: .userInitiated) {
            snapshot.applying(to: signal)
        }.value

        guard !Task.isCancelled, latestRequestedKey == requestedKey else {
            if latestRequestedKey == requestedKey {
                isResolving = false
            }
            return
        }

        cachedKey = requestedKey
        cachedSignal = resolved
        isResolving = false
    }

    /// Correctness fallback for synchronous consumers such as export snapshot
    /// creation. Normal waveform rendering never calls this on a cache miss.
    func resolveSynchronously(
        signal: MFFSignalData,
        snapshot: ChannelInterpolationSnapshot
    ) -> MFFSignalData {
        let requestedKey = key(for: signal, snapshot: snapshot)
        if let cached = cachedSignal(for: requestedKey) {
            return cached
        }

        computationCount += 1
        let resolved = snapshot.applying(to: signal)
        latestRequestedKey = requestedKey
        cachedKey = requestedKey
        cachedSignal = resolved
        isResolving = false
        return resolved
    }

    func reset() {
        latestRequestedKey = nil
        cachedKey = nil
        cachedSignal = nil
        isResolving = false
    }
}
