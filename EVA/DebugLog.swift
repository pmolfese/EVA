//
//  DebugLog.swift
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
//  A lightweight, app-wide debug log. Anything can append lines via
//  `DebugLog.shared.log(...)`, and the `DebugLogView` window (opened from the
//  Window menu) shows them live with copy-to-clipboard for easy sharing.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    @Published private(set) var entries: [String] = []

    private let maxEntries = 5000
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    func log(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)"
        entries.append(line)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    var joinedText: String {
        entries.joined(separator: "\n")
    }
}

/// Non-isolated convenience so call sites don't need to await. Hops to the main
/// actor to mutate the published store.
func debugLog(_ message: String) {
    Task { @MainActor in
        DebugLog.shared.log(message)
    }
}

struct DebugLogView: View {
    @ObservedObject private var log = DebugLog.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Debug Log")
                    .font(.headline)
                Text("\(log.entries.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    log.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.joinedText, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.clipboard")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(log.entries.isEmpty)
            }
            .padding(10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if log.entries.isEmpty {
                            Text("No log entries yet.")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(Array(log.entries.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Color.clear.frame(height: 1).id("logBottom")
                    }
                    .padding(10)
                }
                .onChange(of: log.entries.count) { _, _ in
                    proxy.scrollTo("logBottom", anchor: .bottom)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}
