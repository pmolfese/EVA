//
//  BatchCheckpointTests.swift
//  EVATests
//


import Foundation
import Testing
@testable import EVA

struct BatchCheckpointTests {
    private enum TestFailure: Error { case expected }

    private func folder(_ name: String = "eva-batch-checkpoint") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func script(_ steps: [EVAProcessingStep]) -> EVAProcessingScript {
        var script = EVAProcessingScript()
        script.steps = steps
        return script
    }

    private func basicPlan() -> BatchPrefixPlan {
        BatchPrefixPlanner.plan(
            script: script([
                EVAProcessingStep(operation: .mriGradientCorrection, parameters: ["window": "31"]),
                EVAProcessingStep(operation: .filter, parameters: ["highPassHz": "1"]),
            ]),
            availability: .none,
            skipUnsupportedDecisions: false,
            mode: .fullAuto
        )
    }

    private func writePackage(at url: URL, prefix: EVAProcessingScript) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("signal bytes".utf8).write(to: url.appendingPathComponent("signal1.bin"))
        try EVAProcessingScriptXML.write(prefix, toPackage: url)
    }

    private func oneComponentPayload() -> ICAReplayPayload {
        var decomposition = ICADecomposition(
            sourceSignalPath: "source.mff",
            sourceSamplingRate: 250,
            analysisSamplingRate: 250,
            decimation: 1,
            fitFilter: nil,
            convergenceTolerance: 0,
            minimumIterations: 0,
            finalChange: 0,
            varianceThreshold: 1,
            pcaVarianceRetained: 1,
            averageReference: false,
            channelCount: 1,
            sampleCount: 10,
            componentCount: 1,
            iterations: 1,
            channelMeans: [0],
            mixingMatrix: [[1]],
            unmixingMatrix: [[1]],
            componentMaps: [[1]],
            componentSources: [[0]],
            explainedVariance: [1],
            pcaExplainedVariance: [1]
        )
        decomposition.excludedComponents = [0]
        return ICAReplayPayload(decomposition: decomposition)
    }

    @Test func destinationUsesTheDedicatedPartialFolderAndPreparedSuffix() {
        let destination = BatchCheckpointStore.destination(
            for: URL(fileURLWithPath: "/input/session.one.mff"),
            outputFolder: URL(fileURLWithPath: "/output")
        )
        #expect(destination.path == "/output/partial/session.one-prepared.mff")
    }

    @Test func manifestRoundTripsAndExactlyMatchingPackageIsReusable() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("recording-prepared.mff", isDirectory: true)
        let plan = basicPlan()
        let identity = BatchCheckpointIdentity.make(
            sourceFingerprint: "source-abc",
            plan: plan,
            payloadDigests: []
        )
        let manifest = BatchCheckpointManifest(
            plan: plan,
            identity: identity,
            auditLogLines: ["gradient correction complete"],
            createdAt: Date(timeIntervalSince1970: 1_000),
            appVersion: "test"
        )

        try await BatchCheckpointStore.publish(manifest: manifest, to: destination) { staging in
            try writePackage(at: staging, prefix: plan.prefix)
        }

        let decoded = try #require(BatchCheckpointStore.readManifest(from: destination))
        #expect(decoded == manifest)
        #expect(decoded.completedSteps.map(\.operation) == [.mriGradientCorrection])
        #expect(decoded.remainingStepIDs == plan.remainder.steps.map(\.id))
        guard case .reusable(let reused) = BatchCheckpointStore.reuseStatus(
            at: destination,
            expected: identity
        ) else {
            Issue.record("expected reusable checkpoint")
            return
        }
        #expect(reused == manifest)
    }

    @Test func reuseExplainsEveryIdentityMismatch() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("prepared.mff", isDirectory: true)
        let plan = basicPlan()
        let identity = BatchCheckpointIdentity.make(
            sourceFingerprint: "old-source",
            plan: plan,
            payloadDigests: []
        )
        let manifest = BatchCheckpointManifest(plan: plan, identity: identity, auditLogLines: [])
        try await BatchCheckpointStore.publish(manifest: manifest, to: destination) { staging in
            try writePackage(at: staging, prefix: plan.prefix)
        }

        let expected = BatchCheckpointIdentity(
            sourceFingerprint: "new-source",
            prefixDigest: "new-prefix",
            payloadDigests: [BatchCheckpointPayloadDigest(
                prefixStepIndex: 0,
                operation: .icaClean,
                sha256: "new-payload"
            )],
            policyDigest: "new-policy"
        )
        #expect(BatchCheckpointStore.reuseStatus(at: destination, expected: expected) == .incompatible([
            .sourceFingerprint, .prefix, .payload, .policy,
        ]))
    }

    @Test func manifestWithoutMatchingEvaXMLIsNeverReusable() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("prepared.mff", isDirectory: true)
        let plan = basicPlan()
        let identity = BatchCheckpointIdentity.make(
            sourceFingerprint: "source",
            plan: plan,
            payloadDigests: []
        )
        let manifest = BatchCheckpointManifest(plan: plan, identity: identity, auditLogLines: [])
        try await BatchCheckpointStore.publish(manifest: manifest, to: destination) { staging in
            try writePackage(at: staging, prefix: plan.prefix)
        }

        try EVAProcessingScriptXML.write(EVAProcessingScript(), toPackage: destination)
        guard case .incomplete(let reason) = BatchCheckpointStore.reuseStatus(
            at: destination,
            expected: identity
        ) else {
            Issue.record("expected an incomplete checkpoint")
            return
        }
        #expect(reason.contains("does not match"))
    }

    @Test func ICAIdentityMustMatchTheSidecarInsideTheCheckpoint() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("ica-prepared.mff", isDirectory: true)
        let payload = oneComponentPayload()
        let plan = BatchPrefixPlanner.plan(
            script: script([EVAProcessingStep(operation: .icaClean)]),
            availability: ReplayPayloadAvailability(hasICAPayload: true),
            skipUnsupportedDecisions: false,
            mode: .fullAuto
        )
        let digest = BatchCheckpointPayloadDigest.ica(payload, prefixStepIndex: 0)
        let identity = BatchCheckpointIdentity.make(
            sourceFingerprint: "source",
            plan: plan,
            payloadDigests: [digest]
        )
        let manifest = BatchCheckpointManifest(plan: plan, identity: identity, auditLogLines: [])

        try await BatchCheckpointStore.publish(manifest: manifest, to: destination) { staging in
            try writePackage(at: staging, prefix: plan.prefix)
            try payload.write(toPackage: staging)
        }
        guard case .reusable = BatchCheckpointStore.reuseStatus(at: destination, expected: identity) else {
            Issue.record("expected ICA checkpoint to be reusable")
            return
        }

        try Data("corrupt".utf8).write(to: destination.appendingPathComponent(ICAReplayPayload.fileName))
        guard case .incomplete(let reason) = BatchCheckpointStore.reuseStatus(
            at: destination,
            expected: identity
        ) else {
            Issue.record("expected corrupt ICA checkpoint to be incomplete")
            return
        }
        #expect(reason.contains("missing the payload"))
    }

    @Test func ICAPrefixCannotPublishWithoutAnIndexedPayloadDigest() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("ica-prepared.mff", isDirectory: true)
        let plan = BatchPrefixPlanner.plan(
            script: script([EVAProcessingStep(operation: .icaClean)]),
            availability: ReplayPayloadAvailability(hasICAPayload: true),
            skipUnsupportedDecisions: false,
            mode: .fullAuto
        )
        let identity = BatchCheckpointIdentity.make(
            sourceFingerprint: "source",
            plan: plan,
            payloadDigests: []
        )
        let manifest = BatchCheckpointManifest(plan: plan, identity: identity, auditLogLines: [])

        await #expect(throws: BatchCheckpointError.self) {
            try await BatchCheckpointStore.publish(manifest: manifest, to: destination) { staging in
                try writePackage(at: staging, prefix: plan.prefix)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func failedReplacementPreservesTheExistingCheckpoint() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("prepared.mff", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("keep-me.txt")
        try Data("old checkpoint".utf8).write(to: marker)

        let plan = basicPlan()
        let identity = BatchCheckpointIdentity.make(
            sourceFingerprint: "source",
            plan: plan,
            payloadDigests: []
        )
        let manifest = BatchCheckpointManifest(plan: plan, identity: identity, auditLogLines: [])

        await #expect(throws: TestFailure.self) {
            try await BatchCheckpointStore.publish(manifest: manifest, to: destination) { staging in
                try writePackage(at: staging, prefix: plan.prefix)
                throw TestFailure.expected
            }
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "old checkpoint")
        #expect(BatchCheckpointStore.readManifest(from: destination) == nil)
    }

    @Test func sourceFingerprintIsStableAndChangesWithPathOrBytes() throws {
        let root = try folder("eva-source-fingerprint")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("source.mff", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let first = package.appendingPathComponent("signal1.bin")
        try Data([1, 2, 3]).write(to: first)

        let original = try BatchCheckpointFingerprint.sourcePackage(at: package)
        #expect(try BatchCheckpointFingerprint.sourcePackage(at: package) == original)

        try Data([1, 2, 4]).write(to: first)
        let changedBytes = try BatchCheckpointFingerprint.sourcePackage(at: package)
        #expect(changedBytes != original)

        try Data([1, 2, 3]).write(to: first)
        try FileManager.default.moveItem(
            at: first,
            to: package.appendingPathComponent("renamed.bin")
        )
        #expect(try BatchCheckpointFingerprint.sourcePackage(at: package) != original)
    }
}
