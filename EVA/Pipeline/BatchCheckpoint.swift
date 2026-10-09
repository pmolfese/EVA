//
//  BatchCheckpoint.swift
//  EVA
//
//  PB-1 Phase C2: durable, content-validated partial MFF checkpoints.
//  The MFF remains an ordinary reopenable package; this small manifest says
//  exactly which source, prefix, payloads, and policy produced its samples.
//


import CryptoKit
import Foundation

nonisolated struct BatchCheckpointPayloadDigest: Codable, Sendable, Equatable, Hashable {
    let prefixStepIndex: Int
    let operation: EVAProcessingStep.Operation
    let sha256: String

    static func ica(_ payload: ICAReplayPayload, prefixStepIndex: Int) -> Self {
        Self(
            prefixStepIndex: prefixStepIndex,
            operation: .icaClean,
            sha256: BatchCheckpointDigest.sha256(payload.replayIdentityBytes)
        )
    }
}

nonisolated struct BatchCheckpointIdentity: Codable, Sendable, Equatable {
    let sourceFingerprint: String
    let prefixDigest: String
    let payloadDigests: [BatchCheckpointPayloadDigest]
    let policyDigest: String

    static func make(
        sourceFingerprint: String,
        plan: BatchPrefixPlan,
        payloadDigests: [BatchCheckpointPayloadDigest]
    ) -> Self {
        Self(
            sourceFingerprint: sourceFingerprint,
            prefixDigest: BatchCheckpointDigest.script(plan.prefix),
            payloadDigests: payloadDigests.sorted(by: BatchCheckpointDigest.payloadOrder),
            policyDigest: BatchCheckpointDigest.policy(plan.prefixDrops)
        )
    }
}

nonisolated struct BatchCheckpointStepRecord: Codable, Sendable, Equatable {
    let id: UUID
    let operation: EVAProcessingStep.Operation
    let parameters: [String: String]

    init(_ step: EVAProcessingStep) {
        id = step.id
        operation = step.operation
        parameters = step.parameters
    }
}

nonisolated struct BatchCheckpointDropRecord: Codable, Sendable, Equatable {
    let stepIndex: Int
    let operation: EVAProcessingStep.Operation
    let reason: String

    init(_ drop: BatchDecisionDrop) {
        stepIndex = drop.stepIndex
        operation = drop.operation
        reason = drop.reason
    }
}

nonisolated struct BatchCheckpointManifest: Codable, Sendable, Equatable {
    static let schema = "org.nih.eva.batch-checkpoint"
    static let currentSchemaVersion = 1
    static let fileName = "eva_batch_checkpoint.json"

    let schema: String
    let schemaVersion: Int
    let createdAt: Date
    let appVersion: String
    let identity: BatchCheckpointIdentity
    let prefixScriptVersion: Int
    let completedSteps: [BatchCheckpointStepRecord]
    let remainingStepIDs: [UUID]
    let policyDrops: [BatchCheckpointDropRecord]
    let auditLogLines: [String]

    init(
        plan: BatchPrefixPlan,
        identity: BatchCheckpointIdentity,
        auditLogLines: [String],
        createdAt: Date = Date(),
        appVersion: String = EVAProcessingScriptXML.currentAppVersion
    ) {
        schema = Self.schema
        schemaVersion = Self.currentSchemaVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.identity = identity
        prefixScriptVersion = plan.prefix.version
        completedSteps = plan.prefix.steps.map(BatchCheckpointStepRecord.init)
        remainingStepIDs = plan.remainder.steps.map(\.id)
        policyDrops = plan.prefixDrops.map(BatchCheckpointDropRecord.init)
        self.auditLogLines = auditLogLines
    }
}

nonisolated enum BatchCheckpointMismatch: String, Codable, Sendable, Equatable, CaseIterable {
    case schema
    case sourceFingerprint
    case prefix
    case payload
    case policy
}

nonisolated enum BatchCheckpointReuseStatus: Sendable, Equatable {
    case reusable(BatchCheckpointManifest)
    case missing
    case incomplete(String)
    case incompatible([BatchCheckpointMismatch])
}

nonisolated enum BatchCheckpointError: LocalizedError, Sendable {
    case packageWasNotCreated(String)
    case missingPrefixScript
    case prefixScriptMismatch
    case missingPayload(EVAProcessingStep.Operation)
    case payloadMismatch(EVAProcessingStep.Operation)
    case payloadRecordMismatch(EVAProcessingStep.Operation)
    case manifestStepMismatch
    case manifestPolicyMismatch
    case invalidManifest
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .packageWasNotCreated(let path):
            return "Checkpoint builder did not create an MFF package at \(path)."
        case .missingPrefixScript:
            return "Checkpoint package has no readable eva.xml prefix."
        case .prefixScriptMismatch:
            return "Checkpoint eva.xml does not match the planned processing prefix."
        case .missingPayload(let operation):
            return "Checkpoint package is missing the payload for \(operation.rawValue)."
        case .payloadMismatch(let operation):
            return "Checkpoint payload for \(operation.rawValue) does not match the planned payload."
        case .payloadRecordMismatch(let operation):
            return "Checkpoint manifest does not identify the payload for its \(operation.rawValue) step."
        case .manifestStepMismatch:
            return "Checkpoint manifest's completed steps do not match its eva.xml prefix."
        case .manifestPolicyMismatch:
            return "Checkpoint manifest's decision-policy audit does not match its identity."
        case .invalidManifest:
            return "Checkpoint manifest could not be read back after it was written."
        case .rollbackFailed(let path):
            return "Publishing failed and the previous checkpoint could not be restored at \(path)."
        }
    }
}

nonisolated enum BatchCheckpointDigest {
    /// Computation identity for an ordered prefix. UUIDs, dates, notes, and
    /// result summaries are intentionally absent; operations and their sorted
    /// input parameters are what determine the computation.
    static func script(_ script: EVAProcessingScript) -> String {
        var fields = ["batch-prefix-script.v1", "version=\(script.version)"]
        for step in script.steps {
            fields.append("operation=\(step.operation.rawValue)")
            for key in step.parameters.keys.sorted() {
                fields.append("key=\(key)")
                fields.append("value=\(step.parameters[key] ?? "")")
            }
            fields.append("end-step")
        }
        return EVAHistory.digest(fields)
    }

    static func policy(_ drops: [BatchDecisionDrop]) -> String {
        var fields = ["batch-prefix-policy.v1"]
        for drop in drops.sorted(by: { $0.stepIndex < $1.stepIndex }) {
            fields.append("index=\(drop.stepIndex)")
            fields.append("operation=\(drop.operation.rawValue)")
            fields.append("reason=\(drop.reason)")
        }
        return EVAHistory.digest(fields)
    }

    static func policy(_ drops: [BatchCheckpointDropRecord]) -> String {
        var fields = ["batch-prefix-policy.v1"]
        for drop in drops.sorted(by: { $0.stepIndex < $1.stepIndex }) {
            fields.append("index=\(drop.stepIndex)")
            fields.append("operation=\(drop.operation.rawValue)")
            fields.append("reason=\(drop.reason)")
        }
        return EVAHistory.digest(fields)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate static func payloadOrder(
        _ lhs: BatchCheckpointPayloadDigest,
        _ rhs: BatchCheckpointPayloadDigest
    ) -> Bool {
        if lhs.prefixStepIndex != rhs.prefixStepIndex {
            return lhs.prefixStepIndex < rhs.prefixStepIndex
        }
        return lhs.operation.rawValue < rhs.operation.rawValue
    }
}

nonisolated enum BatchCheckpointFingerprint {
    /// SHA-256 over deterministic relative paths and the full bytes of every
    /// regular file in the source package. It is deliberately exact rather
    /// than relying on modification dates, which can survive a copy or change
    /// without the signal bytes changing in lockstep.
    static func sourcePackage(at sourceURL: URL) throws -> String {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let manager = FileManager.default
        let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let files: [(path: String, url: URL)]
        if values.isDirectory == true {
            guard let enumerator = manager.enumerator(
                at: sourceURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            ) else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: sourceURL.path])
            }
            let root = sourceURL.standardizedFileURL.path + "/"
            files = try enumerator.compactMap { item -> (String, URL)? in
                guard let url = item as? URL,
                      try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    return nil
                }
                let fullPath = url.standardizedFileURL.path
                let relative = fullPath.hasPrefix(root) ? String(fullPath.dropFirst(root.count)) : url.lastPathComponent
                return (relative, url)
            }.sorted { $0.0 < $1.0 }
        } else if values.isRegularFile == true {
            files = [(sourceURL.lastPathComponent, sourceURL)]
        } else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSFilePathErrorKey: sourceURL.path])
        }

        var hasher = SHA256()
        updateLengthPrefixed(Data("eva-source-package.v1".utf8), hasher: &hasher)
        for file in files {
            updateLengthPrefixed(Data(file.path.utf8), hasher: &hasher)
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                updateLengthPrefixed(chunk, hasher: &hasher)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func updateLengthPrefixed(_ data: Data, hasher: inout SHA256) {
        var count = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &count) { hasher.update(data: Data($0)) }
        hasher.update(data: data)
    }
}

nonisolated enum BatchCheckpointStore {
    /// Stable Phase C location: `<output>/partial/<recording>-prepared.mff`.
    static func destination(for sourceURL: URL, outputFolder: URL) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        return outputFolder
            .appendingPathComponent("partial", isDirectory: true)
            .appendingPathComponent("\(baseName)-prepared.mff", isDirectory: true)
    }

    static func readManifest(from packageURL: URL) -> BatchCheckpointManifest? {
        let url = packageURL.appendingPathComponent(BatchCheckpointManifest.fileName)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? decoder().decode(BatchCheckpointManifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    /// A checkpoint is reusable only if its manifest identity matches the plan
    /// and the package still contains the eva.xml/payload bytes that identity
    /// names. Remainder steps are intentionally not part of reuse identity: a
    /// checkpoint's samples depend on its source and prefix, not on what a later
    /// window may choose to do with those samples.
    static func reuseStatus(
        at packageURL: URL,
        expected: BatchCheckpointIdentity
    ) -> BatchCheckpointReuseStatus {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue, let manifest = readManifest(from: packageURL) else {
            return .incomplete("The package or its checkpoint manifest is incomplete.")
        }

        var mismatches: [BatchCheckpointMismatch] = []
        if manifest.schema != BatchCheckpointManifest.schema
            || manifest.schemaVersion != BatchCheckpointManifest.currentSchemaVersion {
            mismatches.append(.schema)
        }
        if manifest.identity.sourceFingerprint != expected.sourceFingerprint {
            mismatches.append(.sourceFingerprint)
        }
        if manifest.identity.prefixDigest != expected.prefixDigest {
            mismatches.append(.prefix)
        }
        if manifest.identity.payloadDigests.sorted(by: BatchCheckpointDigest.payloadOrder)
            != expected.payloadDigests.sorted(by: BatchCheckpointDigest.payloadOrder) {
            mismatches.append(.payload)
        }
        if manifest.identity.policyDigest != expected.policyDigest {
            mismatches.append(.policy)
        }
        guard mismatches.isEmpty else { return .incompatible(mismatches) }

        do {
            try validateManifest(manifest)
            try validatePackage(at: packageURL, against: manifest.identity)
            return .reusable(manifest)
        } catch {
            return .incomplete(error.localizedDescription)
        }
    }

    /// Builds beside the destination, writes the manifest last, validates it,
    /// then publishes with same-filesystem directory moves. If a checkpoint is
    /// already present it is kept until the replacement is complete, and is
    /// restored if publishing the replacement fails.
    static func publish(
        manifest: BatchCheckpointManifest,
        to destination: URL,
        buildPackage: (URL) async throws -> Void
    ) async throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)

        let token = UUID().uuidString
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).staging-\(token)", isDirectory: true)
        let backup = parent.appendingPathComponent(".\(destination.lastPathComponent).previous-\(token)", isDirectory: true)
        var movedExistingAside = false

        defer {
            try? manager.removeItem(at: staging)
            if !movedExistingAside { try? manager.removeItem(at: backup) }
        }

        do {
            try Task.checkCancellation()
            try await buildPackage(staging)
            try Task.checkCancellation()

            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: staging.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw BatchCheckpointError.packageWasNotCreated(staging.path)
            }
            try validateManifest(manifest)
            try validatePackage(at: staging, against: manifest.identity)

            // Completeness marker: deliberately the final write inside staging.
            try encoder().encode(manifest).write(
                to: staging.appendingPathComponent(BatchCheckpointManifest.fileName),
                options: .atomic
            )
            guard let writtenManifest = readManifest(from: staging),
                  writtenManifest.schema == manifest.schema,
                  writtenManifest.schemaVersion == manifest.schemaVersion,
                  writtenManifest.identity == manifest.identity,
                  writtenManifest.prefixScriptVersion == manifest.prefixScriptVersion,
                  writtenManifest.completedSteps == manifest.completedSteps,
                  writtenManifest.remainingStepIDs == manifest.remainingStepIDs,
                  writtenManifest.policyDrops == manifest.policyDrops,
                  writtenManifest.auditLogLines == manifest.auditLogLines else {
                throw BatchCheckpointError.invalidManifest
            }
            try Task.checkCancellation()

            if manager.fileExists(atPath: destination.path) {
                try manager.moveItem(at: destination, to: backup)
                movedExistingAside = true
            }
            do {
                try manager.moveItem(at: staging, to: destination)
            } catch {
                if movedExistingAside {
                    do {
                        try manager.moveItem(at: backup, to: destination)
                        movedExistingAside = false
                    } catch {
                        throw BatchCheckpointError.rollbackFailed(destination.path)
                    }
                }
                throw error
            }

            if movedExistingAside {
                try? manager.removeItem(at: backup)
                movedExistingAside = false
            }
        } catch {
            if movedExistingAside, !manager.fileExists(atPath: destination.path) {
                do {
                    try manager.moveItem(at: backup, to: destination)
                    movedExistingAside = false
                } catch {
                    throw BatchCheckpointError.rollbackFailed(destination.path)
                }
            }
            throw error
        }
    }

    private static func validatePackage(
        at packageURL: URL,
        against identity: BatchCheckpointIdentity
    ) throws {
        guard let script = EVAProcessingScriptXML.read(fromPackage: packageURL) else {
            throw BatchCheckpointError.missingPrefixScript
        }
        guard BatchCheckpointDigest.script(script) == identity.prefixDigest else {
            throw BatchCheckpointError.prefixScriptMismatch
        }

        // Every subject-specific prefix step must name the exact payload that
        // produced its samples, and every named payload must point back to the
        // operation at that index. A bare `hasICAPayload` boolean is not enough
        // to make a checkpoint scientifically reusable.
        for (index, step) in script.steps.enumerated() where step.operation == .icaClean {
            guard identity.payloadDigests.contains(where: {
                $0.prefixStepIndex == index && $0.operation == .icaClean
            }) else {
                throw BatchCheckpointError.payloadRecordMismatch(.icaClean)
            }
        }
        for payload in identity.payloadDigests {
            guard script.steps.indices.contains(payload.prefixStepIndex),
                  script.steps[payload.prefixStepIndex].operation == payload.operation else {
                throw BatchCheckpointError.payloadRecordMismatch(payload.operation)
            }
            switch payload.operation {
            case .icaClean:
                guard let actual = ICAReplayPayload.read(fromPackage: packageURL) else {
                    throw BatchCheckpointError.missingPayload(.icaClean)
                }
                guard BatchCheckpointDigest.sha256(actual.replayIdentityBytes) == payload.sha256 else {
                    throw BatchCheckpointError.payloadMismatch(.icaClean)
                }
            default:
                throw BatchCheckpointError.missingPayload(payload.operation)
            }
        }
    }

    private static func validateManifest(_ manifest: BatchCheckpointManifest) throws {
        guard manifest.identity.policyDigest == BatchCheckpointDigest.policy(manifest.policyDrops) else {
            throw BatchCheckpointError.manifestPolicyMismatch
        }

        // `completedSteps` is the readable form of the same prefix named by the
        // digest. Keep it honest so a person inspecting JSON is never shown a
        // different operation list from the one actually stored in eva.xml.
        var recordedScript = EVAProcessingScript(version: manifest.prefixScriptVersion)
        recordedScript.steps = manifest.completedSteps.map { record in
            var step = EVAProcessingStep(operation: record.operation, parameters: record.parameters)
            step.id = record.id
            return step
        }
        guard BatchCheckpointDigest.script(recordedScript) == manifest.identity.prefixDigest else {
            throw BatchCheckpointError.manifestStepMismatch
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
