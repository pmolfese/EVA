//
//  PhysioImportViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  File → Import Physio: drag/drop (or choose) plain-text physio exports that
//  didn't come from an MFF (GE scanner PPG/RESP logs, Biopac text exports),
//  ask for the sampling rate and start/end trim per channel, preview the
//  trace, and check the trimmed duration against the open recording (or a
//  chosen event code, e.g. TREV) before merging into `recording.pnsSignal`.
//

import SwiftUI
import UniformTypeIdentifiers

/// One imported channel, mid-edit in the sheet: still-raw samples plus the
/// user-editable rate/trim fields needed to interpret them.
private struct PhysioImportDraft: Identifiable {
    let id = UUID()
    var sourceFileName: String
    var name: String
    var rawSamples: [Float]
    var samplingRateText: String
    var trimStartText: String = "0"
    var trimEndText: String = "0"

    var samplingRate: Double? {
        guard let rate = Double(samplingRateText), rate > 0 else { return nil }
        return rate
    }
    var trimStart: Double { max(0, Double(trimStartText) ?? 0) }
    var trimEnd: Double { max(0, Double(trimEndText) ?? 0) }

    var totalDuration: Double? {
        guard let rate = samplingRate, !rawSamples.isEmpty else { return nil }
        return Double(rawSamples.count) / rate
    }

    var trimmedDuration: Double? {
        guard let total = totalDuration else { return nil }
        let d = total - trimStart - trimEnd
        return d > 0 ? d : nil
    }

    /// The sample range after trim, or `nil` if the fields don't resolve to a
    /// valid (rate known, non-empty) range.
    var trimmedSamples: [Float]? {
        guard let rate = samplingRate else { return nil }
        let startIdx = Int((trimStart * rate).rounded())
        let endIdx = rawSamples.count - Int((trimEnd * rate).rounded())
        guard startIdx >= 0, endIdx > startIdx, endIdx <= rawSamples.count else { return nil }
        return Array(rawSamples[startIdx..<endIdx])
    }
}

/// What each draft's trimmed duration is checked against.
private enum PhysioAlignmentTarget: Hashable {
    case recordingDuration
    case eventCode(String)
}

struct PhysioImportSheet: View {
    let recording: MFFRecording
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var drafts: [PhysioImportDraft] = []
    @State private var isDropTargeted = false
    @State private var loadError: String?
    @State private var alignmentTarget: PhysioAlignmentTarget = .recordingDuration
    @State private var showsFileImporter = false
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if drafts.isEmpty {
                        dropZone
                    } else {
                        alignmentSection
                        Divider()
                        ForEach($drafts) { $draft in
                            draftRow($draft)
                            Divider()
                        }
                        addMoreButton
                    }
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 560)
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.plainText, .commaSeparatedText, .data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { load(urls: urls) }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import Physio")
                .font(.title3.weight(.semibold))
            Text("Drag in physio logs recorded outside EVA (GE scanner PPG/RESP, Biopac exports, …). Each file becomes one or more physio channels alongside the recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                          style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(isDropTargeted ? Color.accentColor.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .frame(height: 160)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Drop physio files here")
                        .foregroundStyle(.secondary)
                    Button("Choose Files…") { showsFileImporter = true }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                load(urls: urls)
                return true
            } isTargeted: { isDropTargeted = $0 }
    }

    private var addMoreButton: some View {
        HStack {
            Button("Add More Files…") { showsFileImporter = true }
                .font(.caption)
            Spacer()
        }
        .dropDestination(for: URL.self) { urls, _ in
            load(urls: urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var alignmentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Check duration against")
                .font(.caption.weight(.semibold))
            Picker("Check duration against", selection: $alignmentTarget) {
                Text("Recording duration").tag(PhysioAlignmentTarget.recordingDuration)
                ForEach(eventCodesWithMultipleOccurrences, id: \.self) { code in
                    Text("First/last \"\(code)\" event").tag(PhysioAlignmentTarget.eventCode(code))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 320)
            if let expected = expectedDuration {
                Text("Expected duration: \(formatted(expected)) s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func draftRow(_ draft: Binding<PhysioImportDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Channel name", text: draft.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Text(draft.wrappedValue.sourceFileName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(role: .destructive) {
                    drafts.removeAll { $0.id == draft.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 16) {
                labeledField("Rate (Hz)", text: draft.samplingRateText, width: 70)
                labeledField("Trim start (s)", text: draft.trimStartText, width: 70)
                labeledField("Trim end (s)", text: draft.trimEndText, width: 70)
                durationStatus(for: draft.wrappedValue)
                Spacer()
            }

            PhysioImportSparkline(samples: draft.wrappedValue.trimmedSamples ?? draft.wrappedValue.rawSamples)
                .frame(height: 44)
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }

    @ViewBuilder
    private func durationStatus(for draft: PhysioImportDraft) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Duration").font(.caption2).foregroundStyle(.secondary)
            if draft.samplingRate == nil {
                Label("Enter a rate", systemImage: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let trimmed = draft.trimmedDuration {
                let expected = expectedDuration
                let mismatch = expected.map { abs($0 - trimmed) > max(0.5, $0 * 0.01) } ?? false
                Label(formatted(trimmed) + " s", systemImage: mismatch ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(mismatch ? .orange : .green)
                    .help(mismatch && expected != nil
                          ? "Off by \(formatted(abs(expected! - trimmed)))s from the expected duration."
                          : "Matches the expected duration.")
            } else {
                Label("Trim exceeds file length", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var footer: some View {
        HStack {
            if isImporting { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
            Button("Import") { importDrafts() }
                .keyboardShortcut(.defaultAction)
                .disabled(drafts.isEmpty || !allDraftsReady || isImporting)
        }
        .padding(20)
    }

    // MARK: - Derived state

    private var allDraftsReady: Bool {
        drafts.allSatisfy { $0.samplingRate != nil && $0.trimmedSamples != nil }
    }

    /// Event codes that occur at least twice, so "first/last" spans a
    /// non-zero interval (e.g. repeated TREV scanner-volume triggers).
    private var eventCodesWithMultipleOccurrences: [String] {
        guard let events = recording.signal?.events else { return [] }
        var counts: [String: Int] = [:]
        for e in events { counts[e.code, default: 0] += 1 }
        return counts.filter { $0.value > 1 }.keys.sorted()
    }

    private var expectedDuration: Double? {
        switch alignmentTarget {
        case .recordingDuration:
            return recording.signal?.duration
        case .eventCode(let code):
            let matches = (recording.signal?.events ?? []).filter { $0.code == code }
            guard let first = matches.map(\.beginTimeSeconds).min(),
                  let last = matches.map(\.beginTimeSeconds).max(), last > first else { return nil }
            return last - first
        }
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: - Loading & importing

    private func load(urls: [URL]) {
        loadError = nil
        var failedNames: [String] = []
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let parsed = try PhysioTextImporter.parse(contentsOf: url)
                for channel in parsed.channels {
                    drafts.append(PhysioImportDraft(
                        sourceFileName: url.lastPathComponent,
                        name: channel.name,
                        rawSamples: channel.samples,
                        samplingRateText: parsed.detectedSamplingRateHz.map { String(format: "%.4f", $0) } ?? ""
                    ))
                }
            } catch {
                failedNames.append(url.lastPathComponent)
            }
        }
        if !failedNames.isEmpty {
            loadError = "Couldn't read: \(failedNames.joined(separator: ", "))"
        }
    }

    private func importDrafts() {
        guard allDraftsReady else { return }
        isImporting = true

        let targetRate = recording.pnsSignal?.samplingRate ?? recording.signal?.samplingRate ?? drafts.first?.samplingRate ?? 1
        let channels: [(name: String, samples: [Float])] = drafts.compactMap { draft in
            guard let trimmed = draft.trimmedSamples, let rate = draft.samplingRate else { return nil }
            let resampled = resampleLinear(trimmed, from: rate, to: targetRate)
            return (draft.name, resampled)
        }

        let ok = recording.appendImportedPhysioChannels(channels, samplingRate: targetRate)
        isImporting = false
        if ok {
            onComplete()
        } else {
            loadError = "Couldn't merge — the existing physio signal has a different sampling rate."
        }
    }

    /// Linear resample from `srcRate` to `dstRate`, in either direction.
    private func resampleLinear(_ samples: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        guard srcRate > 0, dstRate > 0, !samples.isEmpty else { return samples }
        let ratio = dstRate / srcRate
        guard abs(ratio - 1) > 1e-6 else { return samples }
        let outCount = max(1, Int((Double(samples.count) * ratio).rounded()))
        var out = [Float]()
        out.reserveCapacity(outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) / ratio
            let lo = Int(srcPos)
            let hi = min(lo + 1, samples.count - 1)
            let frac = Float(srcPos - Double(lo))
            out.append(samples[min(lo, samples.count - 1)] * (1 - frac) + samples[hi] * frac)
        }
        return out
    }
}

/// A lightweight decimated waveform preview for one imported channel.
private struct PhysioImportSparkline: View {
    let samples: [Float]

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1, size.width > 0, size.height > 0 else { return }
            let stride = max(1, samples.count / 800)
            var lo = Float.greatestFiniteMagnitude
            var hi = -Float.greatestFiniteMagnitude
            var i = 0
            while i < samples.count {
                let v = samples[i]
                if v.isFinite { lo = min(lo, v); hi = max(hi, v) }
                i += stride
            }
            guard lo < hi else { return }
            let span = hi - lo

            var path = Path()
            var started = false
            var x: CGFloat = 0
            let dx = size.width / CGFloat((samples.count - 1) / stride + 1)
            i = 0
            while i < samples.count {
                let normalized = (samples[i] - lo) / span
                let y = size.height - CGFloat(normalized) * size.height
                if started { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)); started = true }
                x += dx
                i += stride
            }
            context.stroke(path, with: .color(.pink), lineWidth: 1)
        }
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
    }
}
