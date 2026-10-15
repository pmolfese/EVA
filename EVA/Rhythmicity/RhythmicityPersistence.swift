//
//  RhythmicityPersistence.swift
//  EVA
//
//  Compact, recording-scoped persistence for LAVI/ABBA results. Source samples
//  and surrogate waveforms are intentionally never retained.
//

import CryptoKit
import Foundation

nonisolated enum RhythmicityPersistedStatus: Sendable, Equatable {
    case current
    case stale(String)

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    var explanation: String? {
        if case let .stale(reason) = self { return reason }
        return nil
    }
}

nonisolated struct RhythmicityPersistedResult: Sendable, Equatable {
    var result: LAVIAnalysisResult
    var selection: RhythmicitySelectionDescriptor
    var savedAt: Date
    var status: RhythmicityPersistedStatus
}

nonisolated enum RhythmicityPersistenceError: Error, Sendable, Equatable, LocalizedError {
    case checksumMismatch
    case recordingIdentityMismatch
    case cacheKeyMismatch

    var errorDescription: String? {
        switch self {
        case .checksumMismatch:
            return "The saved Rhythmicity result failed its content checksum."
        case .recordingIdentityMismatch:
            return "The saved Rhythmicity result belongs to a different recording."
        case .cacheKeyMismatch:
            return "The saved Rhythmicity significance entry does not match the requested analysis."
        }
    }
}

nonisolated struct RhythmicityPersistenceStore: Sendable {
    static let schema = "org.nih.eva.rhythmicity.persisted-result"
    static let schemaVersion = 1

    private struct Body: Codable, Equatable {
        var schema: String
        var schemaVersion: Int
        var methodVersion: String
        var upstreamReferenceCommit: String
        var recordingPath: String
        var sourceRevision: String
        var savedAt: Date
        var selection: RhythmicitySelectionDescriptor
        var result: LAVIAnalysisResult
    }

    private struct Envelope: Codable {
        var body: Body
        var contentSHA256: String
    }

    let rootURL: URL

    init(rootURL: URL = Self.defaultRootURL()) {
        self.rootURL = rootURL
    }

    @discardableResult
    func save(
        result: LAVIAnalysisResult,
        selection: RhythmicitySelectionDescriptor,
        recordingURL: URL,
        savedAt: Date = Date()
    ) throws -> URL {
        let recordingPath = Self.recordingPath(recordingURL)
        let body = Body(
            schema: Self.schema,
            schemaVersion: Self.schemaVersion,
            methodVersion: RhythmicityExport.methodVersion,
            upstreamReferenceCommit: RhythmicityExport.referenceCommit,
            recordingPath: recordingPath,
            sourceRevision: result.processingProvenance.sourceRevision,
            savedAt: savedAt,
            selection: selection,
            result: result
        )
        let envelope = Envelope(body: body, contentSHA256: Self.checksum(body))
        let destination = fileURL(forRecordingPath: recordingPath)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try Self.encoder().encode(envelope).write(to: destination, options: .atomic)
        return destination
    }

    func load(
        recordingURL: URL,
        currentSourceRevision: String,
        currentMethodVersion: String = RhythmicityExport.methodVersion,
        currentUpstreamReferenceCommit: String = RhythmicityExport.referenceCommit
    ) throws -> RhythmicityPersistedResult? {
        let recordingPath = Self.recordingPath(recordingURL)
        let url = fileURL(forRecordingPath: recordingPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let envelope = try Self.decoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.body.recordingPath == recordingPath else {
            throw RhythmicityPersistenceError.recordingIdentityMismatch
        }
        guard envelope.contentSHA256 == Self.checksum(envelope.body) else {
            throw RhythmicityPersistenceError.checksumMismatch
        }

        let status: RhythmicityPersistedStatus
        if envelope.body.schema != Self.schema || envelope.body.schemaVersion != Self.schemaVersion {
            status = .stale("The persisted-result schema has changed; recompute before use.")
        } else if envelope.body.methodVersion != currentMethodVersion {
            status = .stale("The EVA LAVI/ABBA method revision has changed; recompute before use.")
        } else if envelope.body.upstreamReferenceCommit != currentUpstreamReferenceCommit {
            status = .stale("The pinned upstream LAVI reference has changed; recompute before use.")
        } else if envelope.body.sourceRevision != currentSourceRevision {
            status = .stale("The processed signal revision differs from the saved result; recompute before use.")
        } else {
            status = .current
        }
        return RhythmicityPersistedResult(
            result: envelope.body.result,
            selection: envelope.body.selection,
            savedAt: envelope.body.savedAt,
            status: status
        )
    }

    func fileURL(for recordingURL: URL) -> URL {
        fileURL(forRecordingPath: Self.recordingPath(recordingURL))
    }

    func significanceCache(for recordingURL: URL) -> LAVISignificanceCacheStore {
        LAVISignificanceCacheStore(
            rootURL: rootURL.appendingPathComponent("SignificanceCache", isDirectory: true),
            recordingURL: recordingURL
        )
    }

    private func fileURL(forRecordingPath recordingPath: String) -> URL {
        rootURL.appendingPathComponent(Self.sha256(recordingPath), isDirectory: false)
            .appendingPathExtension("json")
    }

    private static func recordingPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func checksum(_ body: Body) -> String {
        guard let data = try? encoder().encode(body) else { return "encoding-failed" }
        return sha256(data)
    }

    private static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return decoder
    }

    private static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("EVA", isDirectory: true)
            .appendingPathComponent("RhythmicityResults", isDirectory: true)
    }
}

/// Exact, per-channel cache identity. Channel scope is deliberately absent so
/// a current-channel run can be reused when the user later expands to all good
/// channels; the actual channel, finite segments, signal revision, and complete
/// resolved configuration remain part of the key.
nonisolated struct LAVISignificanceCacheKey: Sendable, Codable, Equatable {
    var schemaVersion: Int
    var methodVersion: String
    var upstreamReferenceCommit: String
    var recordingPath: String
    var sourceRecordingIdentity: String
    var sourceRevision: String
    var processingSummary: [String]
    var samplingRateBits: UInt64
    var channelIndex: Int
    var channelSampleCount: Int
    var channelIsInterpolated: Bool
    var segments: [RhythmicitySegment]
    var configuration: RhythmicityConfiguration
}

/// Stores only the completed fit, ribbon, and convergence diagnostics. EEG
/// samples, coefficient tiles, and surrogate waveforms are never serialized.
nonisolated struct LAVISignificanceCacheStore: Sendable {
    static let schema = "org.nih.eva.rhythmicity.significance-cache"
    static let schemaVersion = 1

    private struct Body: Codable, Equatable {
        var schema: String
        var key: LAVISignificanceCacheKey
        var savedAt: Date
        var resolution: LAVISignificanceResolution
    }

    private struct Envelope: Codable {
        var body: Body
        var contentSHA256: String
    }

    let rootURL: URL
    let recordingPath: String

    init(rootURL: URL, recordingURL: URL) {
        self.rootURL = rootURL
        self.recordingPath = recordingURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func key(
        channel: RhythmicityChannelInput,
        input: RhythmicityInput,
        configuration: RhythmicityConfiguration
    ) -> LAVISignificanceCacheKey {
        LAVISignificanceCacheKey(
            schemaVersion: Self.schemaVersion,
            methodVersion: RhythmicityExport.methodVersion,
            upstreamReferenceCommit: RhythmicityExport.referenceCommit,
            recordingPath: recordingPath,
            sourceRecordingIdentity: input.source.recordingIdentity,
            sourceRevision: input.processingProvenance.sourceRevision,
            processingSummary: input.processingProvenance.processingSummary,
            samplingRateBits: input.samplingRate.bitPattern,
            channelIndex: channel.channelIndex,
            channelSampleCount: channel.samples.count,
            channelIsInterpolated: channel.isInterpolated,
            segments: input.segments,
            configuration: configuration
        )
    }

    func load(
        channel: RhythmicityChannelInput,
        input: RhythmicityInput,
        configuration: RhythmicityConfiguration
    ) throws -> LAVISignificanceResolution? {
        let requestedKey = key(channel: channel, input: input, configuration: configuration)
        let url = fileURL(for: requestedKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let envelope = try Self.decoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.contentSHA256 == Self.checksum(envelope.body) else {
            throw RhythmicityPersistenceError.checksumMismatch
        }
        guard envelope.body.schema == Self.schema, envelope.body.key == requestedKey else {
            throw RhythmicityPersistenceError.cacheKeyMismatch
        }
        return envelope.body.resolution
    }

    @discardableResult
    func save(
        _ resolution: LAVISignificanceResolution,
        channel: RhythmicityChannelInput,
        input: RhythmicityInput,
        configuration: RhythmicityConfiguration,
        savedAt: Date = Date()
    ) throws -> URL {
        let cacheKey = key(channel: channel, input: input, configuration: configuration)
        let body = Body(
            schema: Self.schema,
            key: cacheKey,
            savedAt: savedAt,
            resolution: resolution
        )
        let destination = fileURL(for: cacheKey)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let envelope = Envelope(body: body, contentSHA256: Self.checksum(body))
        try Self.encoder().encode(envelope).write(to: destination, options: .atomic)
        return destination
    }

    func fileURL(for key: LAVISignificanceCacheKey) -> URL {
        let recordingDirectory = rootURL.appendingPathComponent(
            Self.sha256(recordingPath),
            isDirectory: true
        )
        let keyData = (try? Self.encoder().encode(key)) ?? Data("encoding-failed".utf8)
        return recordingDirectory
            .appendingPathComponent(Self.sha256(keyData), isDirectory: false)
            .appendingPathExtension("json")
    }

    private static func checksum(_ body: Body) -> String {
        guard let data = try? encoder().encode(body) else { return "encoding-failed" }
        return sha256(data)
    }

    private static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return decoder
    }
}
