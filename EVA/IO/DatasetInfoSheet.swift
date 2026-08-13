//
//  DatasetInfoSheet.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  File ▸ Dataset Info: reports the recording's metadata and detected file type,
//  and lets the user relabel category names (session-only) for cleaner
//  publication-figure legends. Renames live in EpochingViewModel.categoryRenames
//  and never mutate EpochSegment.category.
//

import SwiftUI

struct DatasetInfoSheet: View {
    var recording: MFFRecording
    var epoching: EpochingViewModel
    /// The kind EVA is working with — the override if one is set, else detected.
    let effectiveType: MFFFileType?
    /// Whether the user has overridden detection for this session.
    let isTypeOverridden: Bool
    /// Applies (or clears, with `nil`) the session override.
    let onChangeType: (MFFFileType?) -> Void
    let onClose: () -> Void

    @State private var ampType: String?
    @State private var ampSerial: String?
    @State private var acquisitionVersion: String?
    @State private var hasProcessingRecord = false

    // XML browser
    @State private var xmlFiles: [String] = []
    @State private var selectedXML = ""
    @State private var xmlMetrics: [String: String] = [:]

    private var signal: MFFSignalData? { recording.signal }

    /// File type, with a session-only override.
    ///
    /// EVA detects the kind from the package's epoch/category structure, and
    /// records it authoritatively in `eva.xml` for packages it wrote itself. This
    /// control exists for everything else: an unusual import, a hand-edited
    /// package, or a file from another tool that EVA reads wrongly. Changing it
    /// re-interprets the recording immediately — it enables the averaged
    /// workspace and butterfly plots, not just the label — so a bad detection can
    /// never block the work.
    @ViewBuilder
    private func typeRow(detected: MFFFileType) -> some View {
        let selection = Binding<MFFFileType>(
            get: { effectiveType ?? detected },
            set: { onChangeType($0) }
        )

        Picker("Type", selection: selection) {
            ForEach(MFFFileType.allCases) { type in
                Text(type.displayName).tag(type)
            }
        }

        if isTypeOverridden {
            HStack(spacing: 8) {
                Text("Overridden for this session — EVA detected \(detected.displayName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { onChangeType(nil) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Dataset") {
                    LabeledContent("Name", value: recording.packageName)
                    if let signal {
                        typeRow(detected: signal.detectedFileType)
                        LabeledContent("Channels", value: "\(signal.numberOfChannels)")
                        LabeledContent("Sampling rate", value: String(format: "%.0f Hz", signal.samplingRate))
                        LabeledContent("Duration", value: String(format: "%.2f s", signal.duration))
                        if let start = signal.recordingStartTime {
                            LabeledContent("Recorded", value: start.formatted(date: .abbreviated, time: .standard))
                        }
                    }
                }

                if let signal, !signal.epochSegments.isEmpty {
                    Section(signal.isAveraged ? "Averaged categories" : "Epochs") {
                        LabeledContent("Segments", value: "\(signal.epochSegments.count)")
                        LabeledContent("Categories", value: "\(signal.categories.count)")
                        if signal.hasMultipleSubjects {
                            LabeledContent("Groups", value: signal.subjects.joined(separator: ", "))
                        }
                    }

                    Section {
                        ForEach(signal.categories, id: \.self) { category in
                            HStack {
                                Text(category)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 120, alignment: .leading)
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                                TextField("Display name", text: renameBinding(category))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    } header: {
                        Text("Rename for figures")
                    } footer: {
                        Text("Session-only labels used in legends and exported figures. The underlying category codes are unchanged.")
                            .font(.caption)
                    }
                }

                Section("Acquisition") {
                    metadataRow("Amplifier", ampType)
                    metadataRow("Serial", ampSerial)
                    metadataRow("Acquisition version", acquisitionVersion)
                    LabeledContent("Physio (PNS)", value: recording.pnsSignal != nil ? "Yes" : "No")
                    LabeledContent("Impedance", value: (signal?.impedancesKOhm?.isEmpty == false) ? "Recorded" : "None")
                    LabeledContent("EVA processing record", value: hasProcessingRecord ? "eva.xml present" : "None")
                }

                if !xmlFiles.isEmpty {
                    Section("Browse package XML") {
                        Picker("File", selection: $selectedXML) {
                            ForEach(xmlFiles, id: \.self) { Text($0).tag($0) }
                        }
                        xmlMetricsList
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 620)
        .task { loadPackageMetadata() }
        .task(id: selectedXML) { parseSelectedXML() }
    }

    /// Scrollable key → value dump of the selected XML file's parsed metrics.
    @ViewBuilder
    private var xmlMetricsList: some View {
        let keys = xmlMetrics.keys.filter { $0 != "fileName" }.sorted()
        if keys.isEmpty {
            Text("No parsable values.").font(.caption).foregroundStyle(.secondary)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(keys, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(key)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(xmlMetrics[key] ?? "")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 200)
        }
    }

    private func renameBinding(_ category: String) -> Binding<String> {
        Binding(
            get: { epoching.categoryRenames[category] ?? category },
            set: { epoching.categoryRenames[category] = $0 }
        )
    }

    @ViewBuilder
    private func metadataRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label, value: value)
        }
    }

    private func loadPackageMetadata() {
        let url = recording.packageURL
        hasProcessingRecord = EVAProcessingScriptXML.read(fromPackage: url) != nil
        xmlFiles = (try? MFFReader().xmlFiles(in: url)) ?? []
        if selectedXML.isEmpty {
            selectedXML = xmlFiles.first { $0.caseInsensitiveCompare("info.xml") == .orderedSame } ?? (xmlFiles.first ?? "")
        }
        guard let package = try? MFFReader().inspectPackage(at: url) else { return }
        ampType = metricValue(package.metrics, suffix: ".ampType")
        ampSerial = metricValue(package.metrics, suffix: ".ampSerialNumber")
        acquisitionVersion = metricValue(package.metrics, suffix: ".acquisitionVersion")
    }

    private func parseSelectedXML() {
        guard !selectedXML.isEmpty else { xmlMetrics = [:]; return }
        xmlMetrics = (try? MFFReader().parseXMLMetrics(in: recording.packageURL, fileName: selectedXML)) ?? [:]
    }

    private func metricValue(_ metrics: [String: String], suffix: String) -> String? {
        metrics.first { $0.key.hasSuffix(suffix) }?.value
    }
}
