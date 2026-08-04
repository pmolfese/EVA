//
//  ToBIDS.swift
//  EVA BIDS
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
//  Converts an MFF recording into a BIDS-EEG dataset: EDF signal file plus
//  channels.tsv / events.tsv / electrodes.tsv / coordsystem.json / eeg.json,
//  with EVA's own eva.xml + log_eva_*.txt stashed under code/eva/ so batch
//  tooling can still find them.
//

import Foundation

struct ToBIDSOptions {
    var inputURL: URL
    var bidsRootURL: URL
    var entities: BIDSEntities
    var powerLineFrequency: Double
    var eegReference: String
    var overwrite: Bool
    var verbose: Bool
}

enum ToBIDS {
    static func run(_ options: ToBIDSOptions) throws {
        let verboseLog: (String) -> Void = { message in
            if options.verbose { writeStdoutLine("[verbose] \(message)") }
        }

        guard directoryExists(options.inputURL) else { throw EVABIDSError.notFound(options.inputURL) }

        let eegDirURL = options.bidsRootURL.appendingPathComponent(
            options.entities.eegDirectoryComponents.joined(separator: "/")
        )
        let stem = options.entities.stem

        try FileManager.default.createDirectory(at: eegDirURL, withIntermediateDirectories: true)

        let edfURL = eegDirURL.appendingPathComponent("\(stem)_eeg.edf")
        if fileExists(edfURL), !options.overwrite {
            throw EVABIDSError.outputExists(edfURL)
        }

        verboseLog("Loading MFF signal from \(options.inputURL.path)")
        let reader = MFFReader()
        let signal = try reader.loadSignal(from: options.inputURL)
        let pns = try reader.loadPNSSignal(from: options.inputURL)

        writeStdoutLine("Loaded \(signal.numberOfChannels) EEG channels, \(pns?.numberOfChannels ?? 0) PNS channels, \(String(format: "%.1f", signal.duration))s at \(signal.samplingRate) Hz.")

        var channelRows: [[String]] = []
        var edfChannels: [EDFWriter.ChannelSpec] = []

        let eegNames = channelNames(for: signal, fallbackPrefix: "E")
        for (index, name) in eegNames.enumerated() {
            channelRows.append([name, "EEG", "uV", formatHz(signal.samplingRate), "n/a"])
            edfChannels.append(EDFWriter.ChannelSpec(
                label: sanitizeEDFLabel(name),
                physicalDimension: "uV",
                samplingRate: signal.samplingRate,
                data: signal.data[index]
            ))
        }

        var eogCount = 0, ecgCount = 0, emgCount = 0, miscCount = 0
        if let pns {
            let pnsNames = channelNames(for: pns, fallbackPrefix: "PNS")
            for (index, name) in pnsNames.enumerated() {
                let type = ChannelType.infer(fromPNSName: name)
                switch type {
                case "EOG": eogCount += 1
                case "ECG": ecgCount += 1
                case "EMG": emgCount += 1
                default: miscCount += 1
                }
                channelRows.append([name, type, "uV", formatHz(pns.samplingRate), "n/a"])
                edfChannels.append(EDFWriter.ChannelSpec(
                    label: sanitizeEDFLabel(name),
                    physicalDimension: "uV",
                    samplingRate: pns.samplingRate,
                    data: pns.data[index]
                ))
            }
        }

        verboseLog("Writing \(edfURL.lastPathComponent) (\(edfChannels.count) channels)")
        try EDFWriter.write(
            channels: edfChannels,
            startDate: signal.recordingStartTime,
            patientID: options.entities.subject,
            recordingID: options.entities.stem,
            to: edfURL
        )

        try TSV.write(
            headers: ["name", "type", "units", "sampling_frequency", "status"],
            rows: channelRows,
            to: eegDirURL.appendingPathComponent("\(stem)_channels.tsv")
        )
        verboseLog("Wrote \(stem)_channels.tsv")

        var eventRows: [[String]] = []
        for event in signal.events.sorted(by: { $0.beginTimeSeconds < $1.beginTimeSeconds }) {
            eventRows.append([
                String(format: "%.6f", event.beginTimeSeconds),
                event.durationSeconds.map { String(format: "%.6f", $0) } ?? "n/a",
                event.code,
            ])
        }
        try TSV.write(
            headers: ["onset", "duration", "trial_type"],
            rows: eventRows,
            to: eegDirURL.appendingPathComponent("\(stem)_events.tsv")
        )
        verboseLog("Wrote \(stem)_events.tsv (\(eventRows.count) events)")

        try writeElectrodesAndCoordsystem(
            signal: signal,
            eegNames: eegNames,
            eegDirURL: eegDirURL,
            stem: stem,
            verboseLog: verboseLog
        )

        let eegJSON: [String: Any] = [
            "TaskName": options.entities.task,
            "SamplingFrequency": signal.samplingRate,
            "EEGReference": options.eegReference,
            "PowerLineFrequency": options.powerLineFrequency,
            "SoftwareFilters": "n/a",
            "EEGChannelCount": eegNames.count,
            "EOGChannelCount": eogCount,
            "ECGChannelCount": ecgCount,
            "EMGChannelCount": emgCount,
            "MiscChannelCount": miscCount,
            "RecordingDuration": signal.duration,
            "RecordingType": "continuous",
            "Manufacturer": "EGI",
        ]
        try BIDSJSON.write(eegJSON, to: eegDirURL.appendingPathComponent("\(stem)_eeg.json"))
        verboseLog("Wrote \(stem)_eeg.json")

        try writeDatasetDescriptionIfMissing(bidsRootURL: options.bidsRootURL)
        try appendParticipantIfMissing(subject: options.entities.subject, bidsRootURL: options.bidsRootURL)

        try stashProcessingHistory(
            inputURL: options.inputURL,
            bidsRootURL: options.bidsRootURL,
            entities: options.entities,
            verboseLog: verboseLog
        )

        writeStdoutLine("Wrote BIDS EEG recording to \(eegDirURL.path)")
    }

    private static func channelNames(for signal: MFFSignalData, fallbackPrefix: String) -> [String] {
        (0..<signal.numberOfChannels).map { index in
            if let names = signal.channelNames, index < names.count, !names[index].isEmpty {
                return names[index]
            }
            return "\(fallbackPrefix)\(index + 1)"
        }
    }

    private static func sanitizeEDFLabel(_ name: String) -> String {
        // EDF labels are ASCII, <=16 chars, no leading/trailing space.
        let ascii = name.unicodeScalars.filter { $0.isASCII }.map(Character.init)
        return String(String(ascii).prefix(16))
    }

    private static func formatHz(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.3f", value)
    }

    private static func writeElectrodesAndCoordsystem(
        signal: MFFSignalData,
        eegNames: [String],
        eegDirURL: URL,
        stem: String,
        verboseLog: (String) -> Void
    ) throws {
        guard let geometry = ElectrodeGeometry.load(fromPackageContaining: signal.signalURL) else {
            verboseLog("No coordinates.xml found; skipping electrodes.tsv/coordsystem.json")
            return
        }

        var rows: [[String]] = []
        for (index, name) in eegNames.enumerated() {
            guard let position = geometry.positions[index] else {
                rows.append([name, "n/a", "n/a", "n/a"])
                continue
            }
            rows.append([
                name,
                String(format: "%.6f", position.x),
                String(format: "%.6f", position.y),
                String(format: "%.6f", position.z),
            ])
        }
        try TSV.write(
            headers: ["name", "x", "y", "z"],
            rows: rows,
            to: eegDirURL.appendingPathComponent("\(stem)_electrodes.tsv")
        )

        let coordsystemJSON: [String: Any] = [
            "EEGCoordinateSystem": "Other",
            "EEGCoordinateUnits": "n/a",
            "EEGCoordinateSystemDescription": "Unit-sphere sensor positions from the source MFF coordinates.xml (\(geometry.name)); not scaled to a physical head radius.",
        ]
        try BIDSJSON.write(coordsystemJSON, to: eegDirURL.appendingPathComponent("\(stem)_coordsystem.json"))
        verboseLog("Wrote \(stem)_electrodes.tsv and \(stem)_coordsystem.json from \(geometry.name)")
    }

    private static func writeDatasetDescriptionIfMissing(bidsRootURL: URL) throws {
        let url = bidsRootURL.appendingPathComponent("dataset_description.json")
        guard !fileExists(url) else { return }
        try FileManager.default.createDirectory(at: bidsRootURL, withIntermediateDirectories: true)
        let description: [String: Any] = [
            "Name": bidsRootURL.lastPathComponent,
            "BIDSVersion": "1.9.0",
            "DatasetType": "raw",
            "GeneratedBy": [["Name": "eva-bids"]],
        ]
        try BIDSJSON.write(description, to: url)
    }

    private static func appendParticipantIfMissing(subject: String, bidsRootURL: URL) throws {
        let url = bidsRootURL.appendingPathComponent("participants.tsv")
        let participantID = "sub-\(subject)"
        if fileExists(url) {
            let existing = try TSV.read(url)
            if existing.contains(where: { $0["participant_id"] == participantID }) { return }
            var text = try String(contentsOf: url, encoding: .utf8)
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\(participantID)\n"
            try text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try TSV.write(headers: ["participant_id"], rows: [[participantID]], to: url)
        }
    }

    /// Copies eva.xml + log_eva_*.txt from the source MFF package (if present)
    /// into `code/eva/<eeg-dir>/` — outside the BIDS-validated tree, so batch
    /// tooling can recover EVA's processing history for a recording that
    /// round-trips through BIDS.
    private static func stashProcessingHistory(
        inputURL: URL,
        bidsRootURL: URL,
        entities: BIDSEntities,
        verboseLog: (String) -> Void
    ) throws {
        let evaXMLURL = inputURL.appendingPathComponent("eva.xml")
        let logFiles = (try? FileManager.default.contentsOfDirectory(at: inputURL, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("log_eva_") && $0.pathExtension == "txt" } ?? []

        guard fileExists(evaXMLURL) || !logFiles.isEmpty else {
            verboseLog("No eva.xml or log_eva_*.txt found in source MFF; nothing to stash")
            return
        }

        let stashDirURL = bidsRootURL
            .appendingPathComponent("code")
            .appendingPathComponent("eva")
            .appendingPathComponent(entities.eegDirectoryComponents.joined(separator: "/"))
        try FileManager.default.createDirectory(at: stashDirURL, withIntermediateDirectories: true)

        if fileExists(evaXMLURL) {
            let destination = stashDirURL.appendingPathComponent("\(entities.stem)_eva.xml")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: evaXMLURL, to: destination)
            verboseLog("Stashed eva.xml to \(destination.path)")
        }
        for logFile in logFiles {
            let destination = stashDirURL.appendingPathComponent("\(entities.stem)_\(logFile.lastPathComponent)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: logFile, to: destination)
            verboseLog("Stashed \(logFile.lastPathComponent) to \(destination.path)")
        }
    }
}
