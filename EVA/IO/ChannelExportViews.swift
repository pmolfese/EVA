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

private struct ChannelExportEvent: Codable {
    var code: String
    var label: String?
    var description: String?
    var cell: String?
    var beginTimeSeconds: Double
    var durationSeconds: Double?
    var sourceFile: String
}

private struct ChannelExportPayload: Codable {
    var channel: String
    var samplingRate: Double
    var recording: String
    var series: [ChannelExportSeries]
    var eventTraces: [ChannelExportSeries]?
    var events: [ChannelExportEvent]?
}

extension WaveformView {
    // MARK: - Single-channel export (JSON / AFNI 1D)

    func exportChannelAsJSON(index: Int, signal: MFFSignalData, includeEvents: Bool = false) {
        guard let series = channelExportSeries(index: index, signal: signal) else { return }
        let events = includeEvents ? channelExportEvents(for: signal) : []
        let eventTraces = includeEvents ? channelExportEventSeries(events: events, signal: signal) : []
        let payload = ChannelExportPayload(
            channel: channelExportName(index: index, signal: signal),
            samplingRate: signal.samplingRate,
            recording: recording.packageName,
            series: series,
            eventTraces: includeEvents ? eventTraces : nil,
            events: includeEvents ? events.map(channelExportEvent) : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(payload.channel)\(includeEvents ? " with Events" : "").json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    func exportChannelAs1D(index: Int, signal: MFFSignalData, includeEvents: Bool = false) {
        guard let series = channelExportSeries(index: index, signal: signal) else { return }
        let events = includeEvents ? channelExportEvents(for: signal) : []
        let eventTraces = includeEvents ? channelExportEventSeries(events: events, signal: signal) : []
        let text = channelExport1DText(series: series + eventTraces)
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
        panel.nameFieldStringValue = "\(channelExportName(index: index, signal: signal))\(includeEvents ? " with Events" : "").1D"
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

    /// The same combined event stream shown in the waveform's Events track:
    /// signal events plus user markers and, for non-averaged views, artifact
    /// overlay events. In epoch views, continuous overlays are mapped into each
    /// displayed epoch so sample indices line up with exported channel values.
    private func channelExportEvents(for signal: MFFSignalData) -> [MFFEvent] {
        displayedEvents(
            for: signal,
            includeContinuousOverlays: true,
            includeArtifactOverlays: !epoching.isAveraged,
            mapContinuousOverlaysIntoEpochs: epoching.epochedSignal != nil
        )
    }

    private func channelExportEvent(_ event: MFFEvent) -> ChannelExportEvent {
        ChannelExportEvent(
            code: event.code,
            label: event.label,
            description: event.eventDescription,
            cell: event.cell,
            beginTimeSeconds: event.beginTimeSeconds,
            durationSeconds: event.durationSeconds,
            sourceFile: event.sourceFile
        )
    }

    /// Converts events into sample-aligned 0/1 traces, one trace per event code.
    /// Averaged conditions are exported as separate per-condition event traces
    /// so they match the existing per-condition channel columns.
    private func channelExportEventSeries(events: [MFFEvent], signal: MFFSignalData) -> [ChannelExportSeries] {
        guard signal.samplingRate > 0,
              let sampleCount = signal.data.first?.count,
              sampleCount > 0,
              !events.isEmpty else { return [] }

        let grouped = Dictionary(grouping: events, by: channelExportEventTraceLabel)
        let sortedGroups = grouped.sorted {
            $0.key.localizedStandardCompare($1.key) == .orderedAscending
        }

        if signal.isAveraged, !signal.epochSegments.isEmpty {
            return signal.epochSegments.flatMap { segment -> [ChannelExportSeries] in
                guard segment.startSample >= 0,
                      segment.endSample >= segment.startSample,
                      segment.endSample < sampleCount else { return [] }
                let length = segment.endSample - segment.startSample + 1
                let startSeconds = Double(segment.startSample) / signal.samplingRate
                return sortedGroups.map { label, groupedEvents in
                    ChannelExportSeries(
                        label: "\(segment.category):event:\(label)",
                        values: channelExportEventTrace(
                            events: groupedEvents,
                            startSeconds: startSeconds,
                            sampleCount: length,
                            samplingRate: signal.samplingRate
                        )
                    )
                }
            }
        }

        return sortedGroups.map { label, groupedEvents in
            ChannelExportSeries(
                label: "event:\(label)",
                values: channelExportEventTrace(
                    events: groupedEvents,
                    startSeconds: 0,
                    sampleCount: sampleCount,
                    samplingRate: signal.samplingRate
                )
            )
        }
    }

    private func channelExportEventTraceLabel(for event: MFFEvent) -> String {
        let label = event.code.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "Event" : label
    }

    private func channelExportEventTrace(
        events: [MFFEvent],
        startSeconds: Double,
        sampleCount: Int,
        samplingRate: Double
    ) -> [Double] {
        guard sampleCount > 0, samplingRate > 0 else { return [] }
        let endSeconds = startSeconds + Double(sampleCount) / samplingRate
        var values = [Double](repeating: 0, count: sampleCount)

        for event in events {
            let eventStart = event.beginTimeSeconds
            let duration = max(event.durationSeconds ?? 0, 0)
            if duration > 0 {
                let eventEnd = eventStart + duration
                guard eventStart < endSeconds, eventEnd >= startSeconds else { continue }
                let startIndex = max(Int(floor((eventStart - startSeconds) * samplingRate)), 0)
                let endIndex = min(Int(ceil((eventEnd - startSeconds) * samplingRate)), sampleCount - 1)
                guard startIndex <= endIndex else { continue }
                for index in startIndex...endIndex {
                    values[index] = 1
                }
            } else {
                guard eventStart >= startSeconds, eventStart < endSeconds else { continue }
                let index = min(max(Int(((eventStart - startSeconds) * samplingRate).rounded()), 0), sampleCount - 1)
                values[index] = 1
            }
        }

        return values
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
