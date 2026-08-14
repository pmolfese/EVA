//
//  MFFExportWriter.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  View-independent MFF package writer: signal + eva.xml provenance + process
//  log, in one panel-free call. Shared by the interactive Save panel, replay
//  finish-and-export, and the headless batch processor — one code path.
//

import Foundation

enum MFFExportWriter {
    static func write(
        snapshot: MFFExportSnapshot,
        pnsSignal: MFFSignalData?,
        script: EVAProcessingScript,
        to url: URL,
        auditLogLines: [String] = [],
        icaPayload: ICAReplayPayload? = nil,
        artifactPayload: ArtifactReplayPayload? = nil
    ) async -> Result<URL, Error> {
        // Stamp what we are actually writing, so re-opening this package does not
        // have to infer it from the EGI structure. The writer is the one place
        // that knows for certain, and it serves the interactive and headless
        // paths alike. A grand average is still detected on read (it depends on
        // the segments' subjects), so only the three authored kinds are stamped.
        var script = script
        script.fileType = {
            switch snapshot.kind {
            case .continuous: return .continuous
            case .epoched: return .segmented
            case .averaged: return .averaged
            }
        }()

        let worker = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                try MFFWriter.write(
                    signal: snapshot.signal,
                    pnsSignal: pnsSignal,
                    segments: snapshot.segments,
                    kind: snapshot.kind,
                    to: url
                )
                try? EVAProcessingScriptXML.write(script, toPackage: url)
                // The subject-specific half of the `icaClean` step. `eva.xml`
                // records that ICA ran and with which portable settings; this
                // carries the operator and the exclusion decision, which is what
                // makes the step re-applicable without a refit. See
                // `ICAReplayPayload`.
                try? icaPayload?.write(toPackage: url)
                // The drawn-artifact definitions. Same split as ICA: `eva.xml`
                // records that cleaning happened and with which portable
                // settings, this carries the subject-specific definitions that
                // make it re-appliable.
                try? artifactPayload?.write(toPackage: url)
                let log = EVAProcessLog(
                    header: "EVA \(EVAProcessingScriptXML.currentAppVersion) export — \(url.lastPathComponent)"
                )
                for step in script.steps {
                    let params = step.parameters.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
                    log.append("\(step.operation.rawValue)\(params.isEmpty ? "" : ": \(params)")")
                }
                for line in auditLogLines {
                    log.append(line)
                }
                try? log.write(toPackage: url)
                try Task.checkCancellation()
                return Result<URL, Error>.success(url)
            } catch {
                return Result<URL, Error>.failure(error)
            }
        }
        return await withTaskCancellationHandler(
            operation: { await worker.value },
            onCancel: { worker.cancel() }
        )
    }
}
