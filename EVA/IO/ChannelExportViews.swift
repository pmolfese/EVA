//
//  ChannelExportViews.swift
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
//  Right-click "Export Channel" on a channel label (see ChannelsPanelViews.swift):
//  saves one channel's data as JSON or as a whitespace-delimited AFNI 1D text
//  file, for sharing a channel example or using it as a regressor elsewhere.
//  Continuous recordings export a single column; averaged/grand-average
//  recordings (which carry per-condition `epochSegments`) export one column
//  per condition.
//
//  This is an extension of WaveformView (not a standalone type), following the
//  same pattern as the other L5 slices -- a file split, not a state extraction.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

private struct ChannelExportSeries: Codable {
    var label: String
    var values: [Double]
}

private struct ChannelExportPayload: Codable {
    var channel: String
    var samplingRate: Double
    var recording: String
    var series: [ChannelExportSeries]
}

extension WaveformView {
    // MARK: - Single-channel export (JSON / AFNI 1D)

    func exportChannelAsJSON(index: Int, signal: MFFSignalData) {
        guard let series = channelExportSeries(index: index, signal: signal) else { return }
        let payload = ChannelExportPayload(
            channel: channelExportName(index: index, signal: signal),
            samplingRate: signal.samplingRate,
            recording: recording.packageName,
            series: series
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(payload.channel).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    func exportChannelAs1D(index: Int, signal: MFFSignalData) {
        guard let series = channelExportSeries(index: index, signal: signal) else { return }
        let text = channelExport1DText(series: series)
        guard let data = text.data(using: .utf8) else { return }

        let panel = NSSavePanel()
        // .1D has no registered system UTI. Listing generic fallback types
        // (.plainText/.data/.text) instead of a type that actually declares
        // the "1D" extension makes NSSavePanel guess at — and append — its
        // own extension on top of the one already in nameFieldStringValue,
        // reproducibly doubling up ("Ch 3.1D.1d.1d"). A one-off UTType that
        // explicitly owns the "1D" extension fixes it: NSSavePanel then
        // recognizes the name field's extension as already correct.
        let oneDType = UTType(filenameExtension: "1D", conformingTo: .plainText) ?? .plainText
        panel.allowedContentTypes = [oneDType]
        panel.allowsOtherFileTypes = true
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(channelExportName(index: index, signal: signal)).1D"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    /// Same channel-name resolution `channelLabel` uses, so the exported
    /// file's default name matches what's shown on the trace.
    private func channelExportName(index: Int, signal: MFFSignalData) -> String {
        signal.channelNames?.indices.contains(index) == true
            ? signal.channelNames?[index].nilIfEmpty ?? "Ch \(index + 1)"
            : "Ch \(index + 1)"
    }

    /// One series for a continuous recording (the whole channel), or one
    /// series per condition (`epochSegments.category`) for an averaged/
    /// grand-average recording. Averaged conditions are truncated to the
    /// shortest segment's length rather than padded, so every exported
    /// sample is real data.
    private func channelExportSeries(index: Int, signal: MFFSignalData) -> [ChannelExportSeries]? {
        guard signal.data.indices.contains(index) else { return nil }
        let channelData = signal.data[index]

        guard signal.isAveraged, !signal.epochSegments.isEmpty else {
            return [ChannelExportSeries(label: "Continuous", values: channelData.map(Double.init))]
        }

        let series = signal.epochSegments.compactMap { segment -> ChannelExportSeries? in
            guard segment.startSample >= 0,
                  segment.endSample < channelData.count,
                  segment.startSample <= segment.endSample else { return nil }
            let values = channelData[segment.startSample...segment.endSample].map(Double.init)
            return ChannelExportSeries(label: segment.category, values: values)
        }
        guard !series.isEmpty else { return nil }
        return series
    }

    /// Whitespace-delimited columns with a leading `#`-prefixed comment row
    /// naming each column, so AFNI (and a human) can tell which condition is
    /// which — AFNI's 1D reader ignores `#` lines, but by convention many
    /// pipelines put column labels there for readability.
    private func channelExport1DText(series: [ChannelExportSeries]) -> String {
        var lines = ["# " + series.map(\.label).joined(separator: "\t")]
        let rowCount = series.map(\.values.count).min() ?? 0
        for row in 0..<rowCount {
            lines.append(series.map { String(format: "%.6f", $0.values[row]) }.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
