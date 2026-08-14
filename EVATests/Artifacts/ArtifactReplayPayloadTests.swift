//
//  ArtifactReplayPayloadTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The drawn-artifact payload — `REWIND.md` work item 4's last piece.
//
//  The load-bearing property is different from ICA's. ICA stores an operator and
//  replays it exactly; this stores a *definition* and re-derives the template,
//  so what has to hold is that re-deriving against the same signal reproduces
//  what the detector originally built. Everything else follows from that.
//

import Testing
import Foundation
@testable import EVA

struct ArtifactReplayPayloadTests {

    private let samplingRate = 100.0
    private let sampleCount = 2_000
    private let windowSeconds = 0.4

    private func signal(channels: Int = 4, scale: Float = 1) -> MFFSignalData {
        var rng = SeededGenerator(seed: 99)
        let data = (0..<channels).map { channel in
            (0..<sampleCount).map { sample -> Float in
                let base = Float(sin(2 * .pi * 10 * Double(sample) / samplingRate))
                return scale * (base + Float.random(in: -0.2...0.2, using: &rng) + Float(channel))
            }
        }
        return SyntheticSignal.make(data, samplingRate: samplingRate)
    }

    private func events(_ centers: [Double]) -> [MFFEvent] {
        centers.enumerated().map { index, time in
            MFFEvent(
                id: "blink-\(index)", code: "BLINK", beginTimeSeconds: time,
                rawBeginTime: "\(time)", sourceFile: "eye.xml"
            )
        }
    }

    private func artifact(
        method: ArtifactCleaningMethod = .regression,
        in signal: MFFSignalData
    ) -> DefinedArtifact {
        let list = events([2.0, 5.0, 8.0, 11.0])
        var made = DefinedArtifact(
            type: .ocular,
            name: "Blink",
            eventCode: "BLINK",
            events: list,
            selectedChannelIndices: [0],
            windowSizeSeconds: windowSeconds,
            average: nil,
            topography: nil,
            cleaningMethod: method
        )
        made.average = ArtifactTemplateDetector.templateAverage(
            signal: signal,
            events: list,
            selectedChannelIndices: [0],
            windowSizeSeconds: windowSeconds
        )
        return made
    }

    // MARK: - The load-bearing property

    /// Re-deriving against the signal the template was drawn on must reproduce
    /// the original samples exactly. If it does not, regression's output moves
    /// for reasons unrelated to the data.
    @Test func rederivingAgainstTheSameSignalReproducesTheTemplate() throws {
        let base = signal()
        let original = artifact(in: base)
        let originalSamples = try #require(original.average?.allChannelSamples)

        let payload = ArtifactReplayPayload(artifacts: [original])
        let resolved = payload.artifacts(rederivedAgainst: base)
        let rederived = try #require(resolved.first?.average?.allChannelSamples)

        #expect(rederived.count == originalSamples.count)
        for channel in originalSamples.indices {
            #expect(rederived[channel] == originalSamples[channel],
                    "channel \(channel) template differs after re-derivation")
        }
    }

    /// And the cleaning built on it lands on the same samples.
    @Test func cleaningFromARederivedPayloadMatchesTheOriginal() throws {
        let base = signal()
        let original = artifact(in: base)
        let excluded = Set<Int>()

        let direct = ArtifactCleaner.cleanedSignal(
            from: base, artifacts: [original], excluding: excluded
        )
        let payload = ArtifactReplayPayload(artifacts: [original])
        let replayed = ArtifactCleaner.cleanedSignal(
            from: base,
            artifacts: payload.artifacts(rederivedAgainst: base),
            excluding: excluded
        )

        #expect(!direct.summaries.isEmpty, "the fixture must actually clean something")
        for channel in direct.signal.data.indices {
            #expect(replayed.signal.data[channel] == direct.signal.data[channel],
                    "channel \(channel) differs")
        }
    }

    /// The point of re-deriving rather than storing: the template follows the
    /// signal it is subtracted from. A stored average drawn on different data
    /// would not.
    @Test func rederivingAgainstADifferentSignalGivesADifferentTemplate() throws {
        let drawnOn = signal()
        let original = artifact(in: drawnOn)
        let rescaled = signal(scale: 3)

        let payload = ArtifactReplayPayload(artifacts: [original])
        let resolved = payload.artifacts(rederivedAgainst: rescaled)

        let originalSamples = try #require(original.average?.allChannelSamples.first)
        let rederived = try #require(resolved.first?.average?.allChannelSamples.first)
        #expect(rederived != originalSamples)
    }

    // MARK: - What the payload carries

    @Test func derivedFieldsAreStrippedButParametersSurvive() throws {
        let base = signal()
        var original = artifact(method: .obs, in: base)
        original.obsPCAComponentCount = 5
        original.obsEdgeTaperSeconds = 0.42
        original.appliedMethod = .obs
        original.cleanedAt = Date(timeIntervalSince1970: 0)

        let payload = ArtifactReplayPayload(artifacts: [original])
        let stored = try #require(payload.artifacts.first)

        #expect(stored.average == nil, "the template is derived, not stored")
        #expect(stored.topography == nil)
        #expect(stored.appliedMethod == nil, "applied state describes a run, not a definition")
        #expect(stored.cleanedAt == nil)

        // Everything that defines the cleaning survives.
        #expect(stored.cleaningMethod == .obs)
        #expect(stored.obsPCAComponentCount == 5)
        #expect(stored.obsEdgeTaperSeconds == 0.42)
        #expect(stored.events.map(\.beginTimeSeconds) == original.events.map(\.beginTimeSeconds))
        #expect(stored.selectedChannelIndices == [0])
        #expect(stored.windowSizeSeconds == windowSeconds)
    }

    /// `DefinedArtifact` is `Codable` by synthesis rather than an explicit
    /// `CodingKeys` list, so a cleaning parameter added later is persisted
    /// automatically. This pins that a non-default value on a rarely-touched
    /// parameter survives the trip.
    @Test func lessObviousParametersSurviveTheRoundTrip() throws {
        let base = signal()
        var original = artifact(method: .obs, in: base)
        original.obsPerChannelAlignment = true
        original.obsClusterCount = 4
        original.localTemplateWindowSize = 31
        original.waasDecayFactor = 0.55
        original.usesVariableEventDuration = true

        let payload = ArtifactReplayPayload(artifacts: [original])
        let data = try ArtifactReplayPayload.encoder().encode(payload)
        let decoded = try ArtifactReplayPayload.decoder().decode(ArtifactReplayPayload.self, from: data)
        let stored = try #require(decoded.artifacts.first)

        #expect(stored.obsPerChannelAlignment)
        #expect(stored.obsClusterCount == 4)
        #expect(stored.localTemplateWindowSize == 31)
        #expect(stored.waasDecayFactor == 0.55)
        #expect(stored.usesVariableEventDuration)
    }

    // MARK: - Package I/O

    @Test func packageRoundTrip() throws {
        let base = signal()
        let payload = ArtifactReplayPayload(artifacts: [artifact(in: base)])

        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }

        try payload.write(toPackage: package)
        let read = try #require(ArtifactReplayPayload.read(fromPackage: package))

        #expect(read.artifacts.count == 1)
        #expect(read.artifacts[0].name == "Blink")
        #expect(read.replayIdentityBytes == payload.replayIdentityBytes)
    }

    @Test func readRefusesAbsentCorruptOrFutureSidecars() throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }

        #expect(ArtifactReplayPayload.read(fromPackage: package) == nil)

        try Data("not json".utf8)
            .write(to: package.appendingPathComponent(ArtifactReplayPayload.fileName))
        #expect(ArtifactReplayPayload.read(fromPackage: package) == nil)

        var future = ArtifactReplayPayload(artifacts: [artifact(in: signal())])
        future.schemaVersion = ArtifactReplayPayload.currentSchemaVersion + 1
        try future.write(toPackage: package)
        #expect(ArtifactReplayPayload.read(fromPackage: package) == nil)
    }

    // MARK: - Replay identity

    @Test func identityIgnoresProvenanceButTracksTheDefinition() throws {
        let base = signal()
        let a = ArtifactReplayPayload(artifacts: [artifact(in: base)])

        var later = a
        later.createdAt = a.createdAt.addingTimeInterval(9_000)
        #expect(a.replayIdentityBytes == later.replayIdentityBytes)

        var movedEvents = artifact(in: base)
        movedEvents.events = events([2.0, 5.0, 8.5, 11.0])
        #expect(ArtifactReplayPayload(artifacts: [movedEvents]).replayIdentityBytes
                != a.replayIdentityBytes)

        var otherMethod = artifact(in: base)
        otherMethod.cleaningMethod = .obs
        #expect(ArtifactReplayPayload(artifacts: [otherMethod]).replayIdentityBytes
                != a.replayIdentityBytes)
    }
}
