//
//  EVAProcessLog.swift
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
//  Append-only, chronological audit trail of the computational steps EVA
//  performed on a recording. Written as `log_eva_<date>_<time>.txt` into any
//  exported / combined MFF package. Complements the declarative `eva.xml`
//  (see [[EVAProcessingScript]]): the log is history, eva.xml is current state.
//

import Foundation

nonisolated final class EVAProcessLog: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()

    init(header: String? = nil) {
        if let header {
            append(header)
        }
    }

    /// Records a timestamped line.
    func append(_ message: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        lock.lock()
        lines.append("[\(stamp)] \(message)")
        lock.unlock()
    }

    /// Records a processing step both here and (optionally) in a script.
    func record(_ message: String) {
        append(message)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the log into an MFF package using the `log_eva_<date>_<time>.txt`
    /// naming convention.
    func write(toPackage packageURL: URL) throws {
        let name = "log_eva_\(Self.fileStamp.string(from: Date())).txt"
        let url = packageURL.appendingPathComponent(name)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()
}
