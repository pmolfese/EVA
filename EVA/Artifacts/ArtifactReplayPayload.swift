//
//  ArtifactReplayPayload.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Everything needed to re-apply a drawn-artifact cleaning — the last piece of
//  `REWIND.md` work item 4, and the companion to `ICAReplayPayload`.
//
//  ## Definitions, not waveforms
//
//  An artifact is stored as **what it was defined from**, never as the averaged
//  template it produced: the event times, the channels, the window, the cleaning
//  method and its parameters. The template is re-derived from the signal at apply
//  time.
//
//  That is not a size optimisation dressed up as a principle — it is already how
//  five of the six cleaning methods work. OBS, SSP/PCA, and the local-template
//  family never read a stored average; they build what they need from the signal
//  and `events` each time. Only `applyTemplateRegression` read
//  `artifact.average.allChannelSamples`, and it is the odd one out rather than
//  the norm.
//
//  ## Why re-deriving is also more correct
//
//  A stored average is frozen at the moment the artifact was drawn, and
//  `PipelineInvalidation.appliedArtifactCleaning` clears the *applied* state on a
//  signal change while keeping the drawn `average`. So a template drawn before a
//  filter was applied would be subtracted from post-filter data — a template
//  describing samples that are no longer there. Re-deriving ties the template to
//  the signal it is being subtracted from, which is what regression means.
//
//  **This changes results** for that case, and only that case. It is the one part
//  of this payload that is not purely additive, and it wants a paired run.
//
//  ## Determinism
//
//  Re-derivation must use the *same* averaging function that built the original,
//  or regression's output moves for reasons that have nothing to do with the
//  signal. There are two averagers in the codebase — the detector's plain mean
//  over `beginTimeSeconds`-centred windows, and the preview's baseline-detrended
//  mean over `centerTimeSeconds`-centred windows. They do not agree, and the
//  detector's is the one that built `DefinedArtifact.average`. That is the one
//  `ArtifactTemplateDetector.templateAverage` exposes and the one used here.
//

import Foundation

/// The persisted form of a recording's drawn artifacts.
///
/// Written into the MFF package as `eva_artifacts.json`, beside `eva_ica.json`
/// and `eva.xml`. One file per domain rather than a shared payload file: each is
/// independently readable, independently skippable, and a corrupt one does not
/// take the others down with it.
nonisolated struct ArtifactReplayPayload: Codable, Sendable {
    static let fileName = "eva_artifacts.json"
    static let currentSchemaVersion = 1

    var schemaVersion: Int = ArtifactReplayPayload.currentSchemaVersion
    var createdAt: Date = Date()
    /// Definitions only — `average` and `topography` are stripped on the way in.
    var artifacts: [DefinedArtifact]

    /// Strips the derived fields from `artifacts` and keeps the rest.
    ///
    /// `DefinedArtifact` is `Codable` by **synthesis**, deliberately: an explicit
    /// `CodingKeys` list would silently drop any parameter added later, which is
    /// exactly the failure the determinism audit found four times over. So every
    /// field is carried and the two derived ones are cleared by value instead —
    /// a new cleaning parameter is persisted automatically, and cannot be
    /// forgotten.
    init(artifacts: [DefinedArtifact]) {
        self.artifacts = artifacts.map { artifact in
            var stripped = artifact
            stripped.average = nil
            stripped.topography = nil
            // Applied-state stamps describe a run, not a definition. The commit
            // re-stamps them from the summaries it actually produces.
            stripped.appliedMethod = nil
            stripped.cleanedAt = nil
            return stripped
        }
    }

    /// Artifacts with their templates re-derived against `signal`, ready to hand
    /// to `ArtifactCleaner.cleanedSignal`.
    ///
    /// An artifact whose events all fall outside the signal yields no average and
    /// is returned as-is; `applyTemplateRegression` already guards on a missing
    /// average and contributes nothing, which is the right outcome — cleaning
    /// with a template built from no events would be worse than not cleaning.
    func artifacts(rederivedAgainst signal: MFFSignalData) -> [DefinedArtifact] {
        artifacts.map { artifact in
            var resolved = artifact
            resolved.average = ArtifactTemplateDetector.templateAverage(
                signal: signal,
                events: artifact.events,
                selectedChannelIndices: artifact.selectedChannelIndices,
                windowSizeSeconds: artifact.windowSizeSeconds
            )
            return resolved
        }
    }

    /// Canonical bytes of what changes the samples, for content-addressed node
    /// IDs. Excludes `createdAt` and the per-artifact `id` — two payloads that
    /// would clean identically must hash identically, or the history tree stops
    /// de-duplicating and recomputes work it already has.
    var replayIdentityBytes: Data {
        var out = Data()
        func put(_ string: String) {
            out.append(contentsOf: string.utf8)
            out.append(0x1F)
        }
        put("artifacts.v\(schemaVersion)")
        for artifact in artifacts.sorted(by: { $0.name < $1.name }) {
            put("name=\(artifact.name)")
            put("type=\(artifact.type.rawValue)")
            put("method=\(artifact.cleaningMethod.rawValue)")
            put("window=\(artifact.windowSizeSeconds)")
            put("channels=\(artifact.selectedChannelIndices.sorted().map(String.init).joined(separator: ","))")
            // Anchored, not raw: two artifacts whose events sit on the same
            // samples but read them as onsets in one case and centers in the
            // other clean different windows, so a fingerprint over
            // `beginTimeSeconds` alone would call them identical.
            put("events=\(artifact.events.map { String(format: "%.6f@\($0.timeAnchor.rawValue)", $0.beginTimeSeconds) }.sorted().joined(separator: ","))")
            // The method's own parameters, via the encoding `eva.xml` already
            // uses — one source of truth for "what defines this cleaning".
            let parameters = artifact.processingParameters(prefix: "a")
            for key in parameters.keys.sorted() {
                put("\(key)=\(parameters[key] ?? "")")
            }
        }
        return out
    }
}

// MARK: - Package I/O

extension ArtifactReplayPayload {
    nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    nonisolated func write(toPackage packageURL: URL) throws {
        let data = try ArtifactReplayPayload.encoder().encode(self)
        try data.write(to: packageURL.appendingPathComponent(ArtifactReplayPayload.fileName), options: .atomic)
    }

    /// `nil` when absent, undecodable, or written by a newer schema. A payload
    /// that cannot be trusted must not be *partly* trusted — the caller falls
    /// back to leaving the step for a human, which is what it did before this
    /// file existed.
    nonisolated static func read(fromPackage packageURL: URL) -> ArtifactReplayPayload? {
        let url = packageURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder().decode(ArtifactReplayPayload.self, from: data),
              payload.schemaVersion <= currentSchemaVersion,
              !payload.artifacts.isEmpty else { return nil }
        return payload
    }
}
