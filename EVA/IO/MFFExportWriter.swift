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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
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
        to url: URL,
        auditLogLines: [String] = []
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
