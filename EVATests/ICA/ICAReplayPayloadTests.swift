//
//  ICAReplayPayloadTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The claim under test is `REWIND.md`'s: re-applying ICA from a stored payload
//  is a matrix multiply that reproduces the *same bytes* as the in-memory
//  decomposition. Every assertion here is on exact `Float` equality, not a
//  tolerance — an approximate match would not support the design's promise that
//  navigating back to a node returns you to the same data.
//

import Testing
import Foundation
@testable import EVA

struct ICAReplayPayloadTests {

    private let samplingRate = 200.0
    private let count = 2000

    private func sources() -> [[Double]] {
        let s0 = (0..<count).map { sin(2 * .pi * 7 * Double($0) / samplingRate) }
        let s1 = (0..<count).map { 2 * (Double($0 % 50) / 50.0) - 1 }
        let s2 = (0..<count).map { Double(($0 / 31) % 2) * 2 - 1 }
        return [s0, s1, s2]
    }

    private func mixedChannels(channelCount: Int) -> [[Float]] {
        let src = sources()
        let mixing: [[Double]] = [
            [0.8, 0.3, -0.4],
            [-0.5, 0.9, 0.2],
            [0.2, -0.7, 0.8],
            [0.6, 0.4, 0.5]
        ]
        return (0..<channelCount).map { c in
            (0..<count).map { t -> Float in
                let a = mixing[c][0] * src[0][t]
                let b = mixing[c][1] * src[1][t]
                let d = mixing[c][2] * src[2][t]
                return Float(a + b + d)
            }
        }
    }

    private func config(
        averageReference: Bool = false,
        fitFilter: ICAFitFilterSettings? = nil
    ) -> ICAConfiguration {
        ICAConfiguration(
            method: .picard,
            componentCount: 3,
            varianceThreshold: 0.99999,
            averageReference: averageReference,
            downsampleRate: samplingRate,
            maxIterations: 300,
            learningRate: nil,
            fitFilter: fitFilter,
            convergenceTolerance: 1e-7,
            minimumIterations: 1
        )
    }

    private func fitted(
        averageReference: Bool = false,
        fitFilter: ICAFitFilterSettings? = nil,
        excluding excluded: Set<Int> = [0]
    ) throws -> (signal: MFFSignalData, decomposition: ICADecomposition) {
        let signal = SyntheticSignal.make(mixedChannels(channelCount: 4), samplingRate: samplingRate)
        var decomposition = try ICAArtifactDetector.fit(
            signal: signal,
            configuration: config(averageReference: averageReference, fitFilter: fitFilter)
        )
        decomposition.excludedComponents = excluded
        return (signal, decomposition)
    }

    // MARK: - The load-bearing test

    /// The whole design rests on this: a payload round-tripped through disk and
    /// re-applied must produce the identical samples the live decomposition did.
    ///
    /// This is also the guard on `ICAReplayPayload.decomposition` deliberately
    /// leaving `componentMaps`/`componentSources` empty. If `cleanedSignal` ever
    /// starts reading a field the payload does not carry, this fails here rather
    /// than producing quietly different data in a replayed session.
    @Test func rehydratedApplyMatchesFitApply() async throws {
        let (signal, decomposition) = try fitted(excluding: [0, 2])

        let direct = ICAArtifactDetector.cleanedSignal(
            from: signal,
            decomposition: decomposition,
            excluding: decomposition.excludedComponents
        )

        let payload = ICAReplayPayload(decomposition: decomposition, method: .picard)
        let encoded = try ICAReplayPayload.encoder().encode(payload)
        let decoded = try ICAReplayPayload.decoder().decode(ICAReplayPayload.self, from: encoded)
        let replayed = try await ICAReplay.apply(to: signal, payload: decoded)

        #expect(replayed.data.count == direct.data.count)
        for channel in direct.data.indices {
            #expect(replayed.data[channel] == direct.data[channel],
                    "channel \(channel) differs after payload round-trip")
        }
    }

    /// Same, with the average-reference convention on — it selects a different
    /// centring path inside `cleanedSignal`, so it is a genuinely separate case.
    @Test func rehydratedApplyMatchesUnderAverageReference() async throws {
        let (signal, decomposition) = try fitted(averageReference: true, excluding: [1])

        let direct = ICAArtifactDetector.cleanedSignal(
            from: signal,
            decomposition: decomposition,
            excluding: decomposition.excludedComponents
        )
        let payload = ICAReplayPayload(decomposition: decomposition)
        let replayed = try await ICAReplay.apply(to: signal, payload: payload)

        for channel in direct.data.indices {
            #expect(replayed.data[channel] == direct.data[channel],
                    "channel \(channel) differs under average reference")
        }
    }

    /// With a fit filter, the activation copy is rebuilt by band-passing the base
    /// signal. Replay must reproduce that copy, not silently fall back to the
    /// unfiltered base — the failure mode would be different samples, not an error.
    @Test func rehydratedApplyRebuildsTheActivationCopy() async throws {
        let fitFilter = ICAFitFilterSettings(lowCutoff: 1, highCutoff: 40, notch60HzEnabled: false)
        let (signal, decomposition) = try fitted(fitFilter: fitFilter, excluding: [0])

        let activation = try await ICAReplay.activationSignal(for: signal, fitFilter: fitFilter)
        #expect(activation != nil)

        let direct = ICAArtifactDetector.cleanedSignal(
            from: signal,
            activationSignal: activation,
            decomposition: decomposition,
            excluding: decomposition.excludedComponents
        )
        let payload = ICAReplayPayload(decomposition: decomposition)
        let replayed = try await ICAReplay.apply(to: signal, payload: payload)

        for channel in direct.data.indices {
            #expect(replayed.data[channel] == direct.data[channel],
                    "channel \(channel) differs with a fit filter")
        }

        // And the activation copy is genuinely different from the base, so the
        // test above is not passing by accident.
        #expect(activation?.data[0] != signal.data[0])
    }

    // MARK: - Encoding

    /// Matrices go to disk as raw little-endian Float64, not decimal text,
    /// specifically so no value passes through a lossy representation.
    @Test func matrixRoundTripsExactly() {
        let values: [[Double]] = [
            [0.1, -1.0 / 3.0, .pi],
            [Double.leastNormalMagnitude, 1e300, -0.0]
        ]
        let matrix = ICAMatrix(values)
        #expect(matrix.rows == 2)
        #expect(matrix.columns == 3)
        #expect(matrix.isWellFormed)
        let back = matrix.values
        for row in values.indices {
            for column in values[row].indices {
                #expect(back[row][column].bitPattern == values[row][column].bitPattern)
            }
        }
    }

    @Test func matrixNormalizesRaggedInput() {
        // Short rows zero-fill, long rows truncate — the consumer indexes it as a
        // dense buffer, so a ragged nested array must not produce a ragged store.
        let matrix = ICAMatrix([[1, 2, 3], [4], [5, 6, 7, 8]])
        #expect(matrix.isWellFormed)
        #expect(matrix.values == [[1, 2, 3], [4, 0, 0], [5, 6, 7]])
    }

    @Test func packageRoundTrip() throws {
        let (_, decomposition) = try fitted(excluding: [1, 2])
        let payload = ICAReplayPayload(decomposition: decomposition, method: .picard)

        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICAReplayPayloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }

        try payload.write(toPackage: package)
        let read = try #require(ICAReplayPayload.read(fromPackage: package))

        #expect(read.excludedComponents == [1, 2])
        #expect(read.method == ICAMethod.picard.rawValue)
        #expect(read.unmixingMatrix == payload.unmixingMatrix)
        #expect(read.mixingMatrix == payload.mixingMatrix)
        #expect(read.replayIdentityBytes == payload.replayIdentityBytes)
    }

    @Test func readReturnsNilForAbsentOrCorruptSidecar() throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICAReplayPayloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }

        #expect(ICAReplayPayload.read(fromPackage: package) == nil)

        try Data("not json".utf8).write(to: package.appendingPathComponent(ICAReplayPayload.fileName))
        #expect(ICAReplayPayload.read(fromPackage: package) == nil)
    }

    /// A payload written by a newer build must be refused outright rather than
    /// half-understood. The seeded solvers make refitting a viable fallback, so
    /// refusing costs time, while partial trust would cost correctness.
    @Test func readRefusesAFutureSchema() throws {
        let (_, decomposition) = try fitted()
        var payload = ICAReplayPayload(decomposition: decomposition)
        payload.schemaVersion = ICAReplayPayload.currentSchemaVersion + 1

        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICAReplayPayloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }

        try payload.write(toPackage: package)
        #expect(ICAReplayPayload.read(fromPackage: package) == nil)
    }

    // MARK: - Replay identity

    /// The digest covers what changes the samples and nothing else. If
    /// provenance leaked into it, two payloads producing identical data would
    /// hash differently and the history tree would recompute work it already has.
    @Test func replayIdentityIgnoresProvenance() throws {
        let (_, decomposition) = try fitted()
        let a = ICAReplayPayload(decomposition: decomposition, method: .picard)
        var b = a
        b.createdAt = a.createdAt.addingTimeInterval(9_000)
        b.iterations = a.iterations + 17
        b.method = ICAMethod.infomax.rawValue
        b.sourceSignalPath = "/somewhere/else.bin"
        b.explainedVariance = []

        #expect(a.replayIdentityBytes == b.replayIdentityBytes)
    }

    @Test func replayIdentityTracksTheExclusionSet() throws {
        let (_, decomposition) = try fitted(excluding: [0])
        let a = ICAReplayPayload(decomposition: decomposition)
        var withMore = decomposition
        withMore.excludedComponents = [0, 1]
        let b = ICAReplayPayload(decomposition: withMore)

        #expect(a.replayIdentityBytes != b.replayIdentityBytes)
    }

    @Test func replayIdentityTracksTheOperator() throws {
        let (_, decomposition) = try fitted()
        let a = ICAReplayPayload(decomposition: decomposition)
        var perturbed = decomposition
        perturbed.unmixingMatrix[0][0] += 1e-12
        let b = ICAReplayPayload(decomposition: perturbed)

        #expect(a.replayIdentityBytes != b.replayIdentityBytes)
    }

    /// Exclusion order must not affect identity: the same removal expressed two
    /// ways is the same node.
    @Test func replayIdentityIsOrderIndependent() throws {
        let (_, decomposition) = try fitted()
        var a = decomposition; a.excludedComponents = [2, 0, 1]
        var b = decomposition; b.excludedComponents = [0, 1, 2]

        #expect(ICAReplayPayload(decomposition: a).replayIdentityBytes
                == ICAReplayPayload(decomposition: b).replayIdentityBytes)
    }

    // MARK: - Guards

    @Test func applyRefusesAChannelCountMismatch() async throws {
        let (_, decomposition) = try fitted()
        let payload = ICAReplayPayload(decomposition: decomposition)
        let narrower = SyntheticSignal.make(mixedChannels(channelCount: 3), samplingRate: samplingRate)

        await #expect(throws: ICAReplayError.self) {
            _ = try await ICAReplay.apply(to: narrower, payload: payload)
        }
    }

    @Test func applyWithNoExclusionsIsIdentity() async throws {
        let (signal, decomposition) = try fitted(excluding: [])
        let payload = ICAReplayPayload(decomposition: decomposition)
        let replayed = try await ICAReplay.apply(to: signal, payload: payload)

        for channel in signal.data.indices {
            #expect(replayed.data[channel] == signal.data[channel])
        }
    }
}
