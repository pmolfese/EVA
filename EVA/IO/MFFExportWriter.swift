//
//  MFFExportWriter.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
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
        to url: URL
    ) async -> Result<URL, Error> {
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
                let log = EVAProcessLog(header: "EVA export — \(url.lastPathComponent)")
                for step in script.steps {
                    let params = step.parameters.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
                    log.append("\(step.operation.rawValue)\(params.isEmpty ? "" : ": \(params)")")
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
