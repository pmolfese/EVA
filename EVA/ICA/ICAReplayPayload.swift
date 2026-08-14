//
//  ICAReplayPayload.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Everything needed to re-apply an ICA component removal **exactly**, without
//  refitting. `REWIND.md` work item 4 (payload persistence) and `REPORTS.md`
//  upstream item 1 (ICA sidecar) are the same object, so it is built once here.
//
//  ## What the apply path actually reads
//
//  `ICAArtifactDetector.cleanedSignal(from:activationSignal:decomposition:excluding:)`
//  reads exactly six things off the decomposition:
//
//    - `channelCount` and `componentCount`  (bounds)
//    - `unmixingMatrix`   (k × n) — projects the signal onto the excluded sources
//    - `mixingMatrix`     (n × k) — projects those sources back onto the scalp
//    - `averageReference`         — selects the centring convention
//    - `channelMeans.count`       — a length clamp; the *values* are never read
//
//  plus the excluded index set. Everything else on `ICADecomposition`
//  (`componentSources`, `componentMaps`, `explainedVariance`, the labels) is for
//  display, labelling, and reports — not for reconstruction.
//
//  Two consequences that the design docs had backwards, and that are expensive
//  to get wrong:
//
//  1. **`mixingMatrix` is required.** It is mathematically `pinv(unmixingMatrix)`
//     — with `unmixing = R·W` and `mixing = dewhitening·R⁻¹`, the identity holds
//     exactly — but recomputing a pseudo-inverse from the unmixing matrix would
//     not reproduce the same floating-point bytes. Persisting both costs
//     `2·k·n` doubles (≈ 41 KB at 128 ch / 20 components) and removes the doubt.
//  2. **`channelMeans` is not the payload it looks like.** `cleanedSignal`
//     recomputes the means from the *activation* data it is handed, so the fitted
//     means never enter the arithmetic. They are kept here because the fit-time
//     means are genuinely useful for reports and for full source reconstruction,
//     not because replay needs them.
//
//  ## Why persist at all, given the fit is deterministic
//
//  EVA's solvers are seeded (identity start for Infomax/FastICA, a fixed-constant
//  LCG for the orthonormal Picard start) and `ICAArtifactDetectorTests
//  .isDeterministicAcrossRuns` asserts bit-identical unmixing matrices across two
//  fits of the same input. So — unlike the general ICA case the design assumed —
//  a missing payload can be *recovered* by refitting rather than being an
//  unrecoverable loss. The payload earns its place for three other reasons:
//
//    - **Cost.** Re-applying is two skinny matmuls; refitting is a full
//      eigendecomposition plus an iterative solve.
//    - **Reproducibility across builds and machines.** The fit runs through
//      Accelerate in `Float`; determinism is guaranteed for a given binary on a
//      given machine, not across Accelerate versions or microarchitectures.
//      A stored operator has no such caveat.
//    - **The exclusion set is a human decision**, and no amount of refitting
//      recovers it.
//
//  ## Encoding
//
//  Matrices are stored as base64 little-endian `Float64`, not as JSON number
//  literals: "exactly reproducible" should not depend on a decimal round-trip.
//  Everything a human would want to read (parameters, excluded components,
//  labels, topographies) stays as plain JSON.
//

import Foundation

/// A dense row-major matrix serialized as raw little-endian `Float64`.
///
/// `Data` encodes to base64 in JSON, which is both compact and exact — a 256 ×
/// 256 operator is ~700 KB instead of several MB of decimal text, and no value
/// passes through a decimal representation on the way to disk.
nonisolated struct ICAMatrix: Codable, Sendable, Hashable {
    var rows: Int
    var columns: Int
    var storage: Data

    init(rows: Int, columns: Int, storage: Data) {
        self.rows = rows
        self.columns = columns
        self.storage = storage
    }

    /// Flattens a nested array. Short rows are zero-filled and long rows are
    /// truncated so the stored shape always matches `rows × columns` — the
    /// consumer indexes it as a dense buffer.
    init(_ values: [[Double]]) {
        let rows = values.count
        let columns = values.first?.count ?? 0
        var flat = [Double](repeating: 0, count: rows * columns)
        for (row, source) in values.enumerated() {
            for column in 0..<min(columns, source.count) {
                flat[row * columns + column] = source[column]
            }
        }
        self.init(rows: rows, columns: columns, storage: ICAMatrix.encode(flat))
    }

    /// Nested-array view, the shape `ICADecomposition` stores.
    var values: [[Double]] {
        let flat = ICAMatrix.decode(storage, count: rows * columns)
        guard columns > 0 else { return Array(repeating: [], count: rows) }
        return (0..<rows).map { row in
            Array(flat[(row * columns)..<((row + 1) * columns)])
        }
    }

    var isWellFormed: Bool {
        rows >= 0 && columns >= 0 && storage.count == rows * columns * MemoryLayout<Double>.size
    }

    static func encode(_ values: [Double]) -> Data {
        var out = Data(capacity: values.count * MemoryLayout<Double>.size)
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    static func decode(_ data: Data, count: Int) -> [Double] {
        var out = [Double](repeating: 0, count: count)
        let stride = MemoryLayout<Double>.size
        guard data.count >= count * stride else { return out }
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                var bits: UInt64 = 0
                withUnsafeMutableBytes(of: &bits) { destination in
                    destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[(index * stride)..<((index + 1) * stride)]))
                }
                out[index] = Double(bitPattern: UInt64(littleEndian: bits))
            }
        }
        return out
    }
}

/// The persisted form of one ICA component-removal step.
///
/// Written into the MFF package as `eva_ica.json` beside `eva.xml`. `eva.xml`
/// records that `icaClean` happened and with which portable settings; this file
/// records the subject-specific operator and decision that make the step
/// reproducible.
nonisolated struct ICAReplayPayload: Codable, Sendable, Hashable {
    static let fileName = "eva_ica.json"
    static let currentSchemaVersion = 1

    var schemaVersion: Int = ICAReplayPayload.currentSchemaVersion
    var createdAt: Date = Date()

    // MARK: Provenance (not read by the apply path)
    /// `ICAMethod.rawValue` of the fit, for reports and for explaining a refit.
    var method: String?
    var sourceSignalPath: String = ""
    var sourceSamplingRate: Double = 0
    var analysisSamplingRate: Double = 0
    var decimation: Int = 1
    var varianceThreshold: Double = 0
    var pcaVarianceRetained: Double = 0
    var iterations: Int = 0
    var finalChange: Double = 0

    // MARK: Exact-replay core — everything below changes the output bytes
    var channelCount: Int
    var componentCount: Int
    var averageReference: Bool
    /// The band-pass applied to a *copy* of the base signal to form the
    /// activation used for source estimation. `nil` means the base signal is its
    /// own activation.
    var fitFilter: ICAFitFilterSettings?
    /// The human decision. Sorted and de-duplicated on construction so two
    /// payloads describing the same removal hash identically.
    var excludedComponents: [Int]
    /// `componentCount × channelCount`.
    var unmixingMatrix: ICAMatrix
    /// `channelCount × componentCount`.
    var mixingMatrix: ICAMatrix

    // MARK: Report payload (REPORTS.md §7)
    /// Fit-time per-channel means. Not read by reconstruction — see the file
    /// header — but the natural companion to the operator for source recovery.
    var channelMeans: [Double]
    /// One entry per *excluded* component: index, label, normalized topography.
    var excludedComponentDetail: [SavedICAComponent]
    /// Per-component share of variance, all components (not just excluded).
    var explainedVariance: [Double]

    init(decomposition: ICADecomposition, method: ICAMethod? = nil) {
        self.method = method?.rawValue
        sourceSignalPath = decomposition.sourceSignalPath
        sourceSamplingRate = decomposition.sourceSamplingRate
        analysisSamplingRate = decomposition.analysisSamplingRate
        decimation = decomposition.decimation
        varianceThreshold = decomposition.varianceThreshold
        pcaVarianceRetained = decomposition.pcaVarianceRetained
        iterations = decomposition.iterations
        finalChange = decomposition.finalChange

        channelCount = decomposition.channelCount
        componentCount = decomposition.componentCount
        averageReference = decomposition.averageReference
        fitFilter = decomposition.fitFilter
        excludedComponents = decomposition.excludedComponents.sorted()
        unmixingMatrix = ICAMatrix(decomposition.unmixingMatrix)
        mixingMatrix = ICAMatrix(decomposition.mixingMatrix)

        channelMeans = decomposition.channelMeans
        excludedComponentDetail = ICAArtifactDetector.savedArtifactSet(from: decomposition).excludedComponents
        explainedVariance = decomposition.explainedVariance
    }

    /// Rebuilds just enough of an `ICADecomposition` to drive
    /// `ICAArtifactDetector.cleanedSignal`. The display-only fields come back
    /// empty on purpose: anything this leaves out is, by construction, something
    /// reconstruction does not read. If a future change to `cleanedSignal` starts
    /// reading one of them, `ICAReplayPayloadTests.rehydratedApplyMatchesFitApply`
    /// fails rather than silently producing different bytes.
    var decomposition: ICADecomposition {
        ICADecomposition(
            sourceSignalPath: sourceSignalPath,
            sourceSamplingRate: sourceSamplingRate,
            analysisSamplingRate: analysisSamplingRate,
            decimation: decimation,
            fitFilter: fitFilter,
            convergenceTolerance: 0,
            minimumIterations: 0,
            finalChange: finalChange,
            varianceThreshold: varianceThreshold,
            pcaVarianceRetained: pcaVarianceRetained,
            averageReference: averageReference,
            channelCount: channelCount,
            sampleCount: 0,
            componentCount: componentCount,
            iterations: iterations,
            channelMeans: channelMeans,
            mixingMatrix: mixingMatrix.values,
            unmixingMatrix: unmixingMatrix.values,
            componentMaps: [],
            componentSources: [],
            explainedVariance: explainedVariance,
            pcaExplainedVariance: [],
            excludedComponents: Set(excludedComponents)
        )
    }

    /// Canonical bytes of the exact-replay core, for content-addressed node IDs.
    ///
    /// Deliberately excludes `createdAt`, the provenance block, and the report
    /// block: two payloads that would produce identical samples must produce
    /// identical digests, or the history tree stops de-duplicating and starts
    /// recomputing work it already has.
    var replayIdentityBytes: Data {
        var out = Data()
        func put(_ string: String) {
            out.append(contentsOf: string.utf8)
            out.append(0x1F)  // unit separator — no field can swallow the next
        }
        put("ica.v\(schemaVersion)")
        put("channels=\(channelCount)")
        put("components=\(componentCount)")
        put("averageReference=\(averageReference)")
        if let fitFilter {
            put("fit=\(fitFilter.lowCutoff),\(fitFilter.highCutoff),\(fitFilter.notch60HzEnabled)")
        } else {
            put("fit=none")
        }
        put("excluded=\(excludedComponents.map(String.init).joined(separator: ","))")
        put("unmixing=\(unmixingMatrix.rows)x\(unmixingMatrix.columns)")
        out.append(unmixingMatrix.storage)
        out.append(0x1F)
        put("mixing=\(mixingMatrix.rows)x\(mixingMatrix.columns)")
        out.append(mixingMatrix.storage)
        return out
    }
}

// MARK: - Package I/O

extension ICAReplayPayload {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func write(toPackage packageURL: URL) throws {
        let data = try ICAReplayPayload.encoder().encode(self)
        try data.write(to: packageURL.appendingPathComponent(ICAReplayPayload.fileName), options: .atomic)
    }

    /// Returns `nil` when the package has no sidecar, when it cannot be decoded,
    /// or when it declares a schema this build does not understand. A payload
    /// that cannot be trusted must not be *partly* trusted: the caller falls back
    /// to refitting, which the seeded solvers make a viable recovery.
    static func read(fromPackage packageURL: URL) -> ICAReplayPayload? {
        let url = packageURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder().decode(ICAReplayPayload.self, from: data),
              payload.schemaVersion <= currentSchemaVersion,
              payload.unmixingMatrix.isWellFormed,
              payload.mixingMatrix.isWellFormed else { return nil }
        return payload
    }
}

// MARK: - Replay

nonisolated enum ICAReplayError: LocalizedError {
    case activationFilterFailed(underlying: Error)
    case shapeMismatch(expectedChannels: Int, actualChannels: Int)

    var errorDescription: String? {
        switch self {
        case .activationFilterFailed(let underlying):
            return "Could not rebuild the ICA activation copy: \(underlying.localizedDescription)"
        case .shapeMismatch(let expected, let actual):
            return "Saved ICA operator covers \(expected) channels, but this signal has \(actual)."
        }
    }
}

/// Re-applies a stored ICA component removal with no view, no view model, and no
/// refit — the headless half of `REWIND.md`'s "re-applying ICA is a matrix
/// multiply" claim.
nonisolated enum ICAReplay {
    /// Applies `payload` to `signal`, reproducing the samples the interactive
    /// removal produced from the same base signal.
    ///
    /// Unlike the interactive path, a failure to rebuild the activation copy
    /// **throws** rather than falling back to the unfiltered base. Falling back
    /// would not fail — it would quietly reconstruct from a different activation
    /// and return different samples, which is the exact class of bug the parity
    /// work spent a day chasing.
    static func apply(to signal: MFFSignalData, payload: ICAReplayPayload) async throws -> MFFSignalData {
        guard signal.numberOfChannels == payload.channelCount else {
            throw ICAReplayError.shapeMismatch(
                expectedChannels: payload.channelCount,
                actualChannels: signal.numberOfChannels
            )
        }
        guard !payload.excludedComponents.isEmpty else { return signal }

        let activation = try await activationSignal(for: signal, fitFilter: payload.fitFilter)
        return ICAArtifactDetector.cleanedSignal(
            from: signal,
            activationSignal: activation,
            decomposition: payload.decomposition,
            excluding: Set(payload.excludedComponents)
        )
    }

    /// The band-passed copy used for source estimation. Shared with the
    /// interactive path so the two cannot drift — this is the same filter call
    /// `removeSelectedICAComponents` makes.
    static func activationSignal(
        for signal: MFFSignalData,
        fitFilter: ICAFitFilterSettings?
    ) async throws -> MFFSignalData? {
        guard let fitFilter else { return nil }
        let data: [[Float]]
        do {
            data = try await EEGSignalFilter.bandPass(
                channels: signal.data,
                samplingRate: signal.samplingRate,
                lowCutoff: fitFilter.lowCutoff,
                highCutoff: fitFilter.highCutoff,
                highPassFamily: fitFilter.family,
                lowPassFamily: fitFilter.family,
                notch60HzEnabled: fitFilter.notch60HzEnabled
            )
        } catch {
            throw ICAReplayError.activationFilterFailed(underlying: error)
        }
        return MFFSignalData(
            signalURL: signal.signalURL,
            signalType: "\(signal.signalType) ICA Activation Filtered",
            numberOfChannels: signal.numberOfChannels,
            samplingRate: signal.samplingRate,
            duration: signal.duration,
            recordingStartTime: signal.recordingStartTime,
            events: signal.events,
            data: data,
            channelNames: signal.channelNames
        )
    }
}
