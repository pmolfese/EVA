//
//  FromBIDS.swift
//  EVA BIDS
//
//  Converts a BIDS-EEG recording (EDF + channels.tsv/events.tsv/eeg.json,
//  optionally electrodes.tsv/coordsystem.json) into an MFF package EVA can
//  open. Restores eva.xml / log_eva_*.txt from the code/eva/ stash written by
//  `to-bids`, when present; otherwise the output MFF simply has none.
//

import Foundation

struct FromBIDSOptions {
    var inputURL: URL
    var outputURL: URL
    var overwrite: Bool
    var verbose: Bool
}

enum FromBIDS {
    static func run(_ options: FromBIDSOptions) throws {
        let verboseLog: (String) -> Void = { message in
            if options.verbose { writeStdoutLine("[verbose] \(message)") }
        }

        let edfURL = try resolveEDFFile(from: options.inputURL)
        guard let entities = BIDSEntities.parse(fromFileName: edfURL.lastPathComponent) else {
            throw EVABIDSError.usage("\(edfURL.lastPathComponent) is not a BIDS-named *_eeg.edf file (expected sub-<label>..._task-<label>_eeg.edf).")
        }
        let eegDirURL = edfURL.deletingLastPathComponent()
        let stem = String(edfURL.lastPathComponent.dropLast("_eeg.edf".count))
        verboseLog("Resolved BIDS entities: \(entities.stem)")

        let outputURL = normalizedMFFURL(options.outputURL)
        if directoryExists(outputURL), !options.overwrite {
            throw EVABIDSError.outputExists(outputURL)
        }

        writeStdoutLine("Reading \(edfURL.path)")
        let edf = try EDFReader.load(from: edfURL)

        let channelsTSVURL = eegDirURL.appendingPathComponent("\(stem)_channels.tsv")
        let channelRows = fileExists(channelsTSVURL) ? try TSV.read(channelsTSVURL) : []
        if channelRows.isEmpty {
            verboseLog("No \(stem)_channels.tsv found; inferring channel type from EDF label only")
        }
        let typeByLabel: [String: String] = Dictionary(
            channelRows.compactMap { row in
                guard let name = row["name"] else { return nil }
                return (name, row["type"] ?? "EEG")
            },
            uniquingKeysWith: { first, _ in first }
        )

        var eegChannels: [(label: String, data: [Float])] = []
        var pnsChannels: [(label: String, data: [Float])] = []
        var eegRate: Double?
        var pnsRate: Double?
        for channel in edf.channels {
            let type = (typeByLabel[channel.label] ?? "EEG").uppercased()
            if type == "EEG" {
                if let eegRate, abs(eegRate - channel.samplingRate) > 0.0001 {
                    writeStderrLine("warning: EEG channel \(channel.label) sampling rate \(channel.samplingRate) Hz differs from \(eegRate) Hz; dropping it.")
                    continue
                }
                eegRate = channel.samplingRate
                eegChannels.append((channel.label, channel.data))
            } else {
                if let pnsRate, abs(pnsRate - channel.samplingRate) > 0.0001 {
                    writeStderrLine("warning: PNS channel \(channel.label) sampling rate \(channel.samplingRate) Hz differs from \(pnsRate) Hz; dropping it.")
                    continue
                }
                pnsRate = channel.samplingRate
                pnsChannels.append((channel.label, channel.data))
            }
        }
        guard !eegChannels.isEmpty, let resolvedEEGRate = eegRate else {
            throw EVABIDSError.usage("No EEG-typed channels found in \(edfURL.lastPathComponent).")
        }

        // EDF pads every channel's data out to whole 1-second records, so a
        // recording shorter than a whole number of seconds picks up trailing
        // zero padding. Trim back to the true sample count using the
        // RecordingDuration written by to-bids, when available.
        let eegJSONURL = eegDirURL.appendingPathComponent("\(stem)_eeg.json")
        if fileExists(eegJSONURL), let eegJSON = try? BIDSJSON.read(eegJSONURL),
           let recordingDuration = eegJSON["RecordingDuration"] as? Double {
            let eegSampleCount = Int((recordingDuration * resolvedEEGRate).rounded())
            eegChannels = eegChannels.map { (label: $0.label, data: Array($0.data.prefix(eegSampleCount))) }
            if let pnsRate {
                let pnsSampleCount = Int((recordingDuration * pnsRate).rounded())
                pnsChannels = pnsChannels.map { (label: $0.label, data: Array($0.data.prefix(pnsSampleCount))) }
            }
            verboseLog("Trimmed EDF record padding using RecordingDuration \(recordingDuration)s")
        } else {
            verboseLog("No \(stem)_eeg.json RecordingDuration found; EDF record-boundary padding may be present in the output")
        }

        let events = try loadEvents(eegDirURL: eegDirURL, stem: stem)
        verboseLog("Loaded \(events.count) events, \(eegChannels.count) EEG channels, \(pnsChannels.count) PNS channels")

        let eegSignal = MFFSignalData(
            signalURL: edfURL,
            signalType: "EEG",
            numberOfChannels: eegChannels.count,
            samplingRate: resolvedEEGRate,
            duration: Double(eegChannels[0].data.count) / resolvedEEGRate,
            recordingStartTime: edf.startDate,
            events: events,
            data: eegChannels.map(\.data),
            channelNames: eegChannels.map(\.label)
        )

        let pnsSignal: MFFSignalData? = pnsChannels.isEmpty ? nil : MFFSignalData(
            signalURL: edfURL,
            signalType: "PNSData",
            numberOfChannels: pnsChannels.count,
            samplingRate: pnsRate ?? resolvedEEGRate,
            duration: Double(pnsChannels[0].data.count) / (pnsRate ?? resolvedEEGRate),
            recordingStartTime: edf.startDate,
            events: [],
            data: pnsChannels.map(\.data),
            channelNames: pnsChannels.map(\.label)
        )

        if directoryExists(outputURL) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try MFFWriter.write(
            signal: eegSignal,
            pnsSignal: pnsSignal,
            segments: [],
            kind: .continuous,
            to: outputURL,
            preserveSourceFileInfo: false
        )
        verboseLog("Wrote MFF signal + events to \(outputURL.path)")

        try writeMontageIfAvailable(
            eegDirURL: eegDirURL,
            stem: stem,
            eegChannelNames: eegChannels.map(\.label),
            outputURL: outputURL,
            verboseLog: verboseLog
        )

        restoreProcessingHistory(
            eegFileURL: edfURL,
            entities: entities,
            stem: stem,
            outputURL: outputURL,
            verboseLog: verboseLog
        )

        writeStdoutLine("Wrote \(outputURL.path)")
    }

    private static func resolveEDFFile(from inputURL: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw EVABIDSError.notFound(inputURL)
        }
        if fileExists(inputURL) {
            guard inputURL.lastPathComponent.hasSuffix("_eeg.edf") else {
                throw EVABIDSError.usage("\(inputURL.lastPathComponent) is not a *_eeg.edf file.")
            }
            return inputURL
        }

        guard let enumerator = FileManager.default.enumerator(
            at: inputURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            throw EVABIDSError.notFound(inputURL)
        }
        var matches: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix("_eeg.edf") {
            matches.append(url)
        }
        guard !matches.isEmpty else {
            throw EVABIDSError.usage("No *_eeg.edf file found under \(inputURL.path).")
        }
        guard matches.count == 1 else {
            let names = matches.map(\.lastPathComponent).sorted().joined(separator: ", ")
            throw EVABIDSError.ambiguous("Multiple *_eeg.edf files found under \(inputURL.path): \(names). Pass the exact file path instead.")
        }
        return matches[0]
    }

    private static func loadEvents(eegDirURL: URL, stem: String) throws -> [MFFEvent] {
        let url = eegDirURL.appendingPathComponent("\(stem)_events.tsv")
        guard fileExists(url) else { return [] }
        let rows = try TSV.read(url)
        return rows.enumerated().compactMap { index, row -> MFFEvent? in
            guard let onsetString = row["onset"], let onset = Double(onsetString) else { return nil }
            let duration = row["duration"].flatMap { $0 == "n/a" ? nil : Double($0) }
            let code = row["trial_type"].flatMap { $0.isEmpty || $0 == "n/a" ? nil : $0 } ?? "event"
            return MFFEvent(
                id: "bids-\(index)",
                code: code,
                beginTimeSeconds: onset,
                rawBeginTime: onsetString,
                sourceFile: "\(stem)_events.tsv",
                durationSeconds: duration
            )
        }
    }

    private static func writeMontageIfAvailable(
        eegDirURL: URL,
        stem: String,
        eegChannelNames: [String],
        outputURL: URL,
        verboseLog: (String) -> Void
    ) throws {
        let electrodesURL = eegDirURL.appendingPathComponent("\(stem)_electrodes.tsv")
        guard fileExists(electrodesURL) else {
            verboseLog("No \(stem)_electrodes.tsv found; keeping EVA's synthesized sensorLayout.xml")
            return
        }
        let rows = try TSV.read(electrodesURL)
        var positionsByName: [String: (x: Double, y: Double, z: Double?)] = [:]
        for row in rows {
            guard let name = row["name"],
                  let xString = row["x"], let x = Double(xString),
                  let yString = row["y"], let y = Double(yString) else { continue }
            let z = row["z"].flatMap { $0 == "n/a" ? nil : Double($0) }
            positionsByName[name] = (x, y, z)
        }
        guard !positionsByName.isEmpty else {
            verboseLog("\(stem)_electrodes.tsv had no numeric positions; skipping montage")
            return
        }

        var sensorLayoutBody = ""
        var coordinatesBody = ""
        var wroteAnyZ = false
        for (index, name) in eegChannelNames.enumerated() {
            guard let position = positionsByName[name] else { continue }
            sensorLayoutBody += """
  <sensor>
    <number>\(index + 1)</number>
    <name>\(xmlEscape(name))</name>
    <type>0</type>
    <x>\(position.x)</x>
    <y>\(position.y)</y>
  </sensor>

"""
            if let z = position.z {
                wroteAnyZ = true
                coordinatesBody += """
  <sensor>
    <number>\(index + 1)</number>
    <name>\(xmlEscape(name))</name>
    <type>0</type>
    <x>\(position.x)</x>
    <y>\(position.y)</y>
    <z>\(z)</z>
  </sensor>

"""
            }
        }

        let sensorLayoutXML = """
<?xml version="1.0" encoding="UTF-8"?>
<sensorLayout>
  <name>BIDS import</name>
\(sensorLayoutBody)</sensorLayout>
"""
        try sensorLayoutXML.write(
            to: outputURL.appendingPathComponent("sensorLayout.xml"),
            atomically: true,
            encoding: .utf8
        )
        verboseLog("Wrote sensorLayout.xml from \(stem)_electrodes.tsv")

        if wroteAnyZ {
            let coordinatesXML = """
<?xml version="1.0" encoding="UTF-8"?>
<sensorLayout>
  <name>BIDS import</name>
\(coordinatesBody)</sensorLayout>
"""
            try coordinatesXML.write(
                to: outputURL.appendingPathComponent("coordinates.xml"),
                atomically: true,
                encoding: .utf8
            )
            verboseLog("Wrote coordinates.xml from \(stem)_electrodes.tsv")
        }
    }

    /// Looks for `code/eva/<eeg-dir>/<stem>_eva.xml` / `<stem>_log_eva_*.txt`
    /// walking up from the EDF file to find the BIDS root (marked by
    /// dataset_description.json), and copies them back in if found.
    private static func restoreProcessingHistory(
        eegFileURL: URL,
        entities: BIDSEntities,
        stem: String,
        outputURL: URL,
        verboseLog: (String) -> Void
    ) {
        guard let bidsRootURL = findBIDSRoot(from: eegFileURL) else {
            verboseLog("Could not locate dataset_description.json above \(eegFileURL.path); skipping eva.xml/log restore")
            return
        }
        let stashDirURL = bidsRootURL
            .appendingPathComponent("code")
            .appendingPathComponent("eva")
            .appendingPathComponent(entities.eegDirectoryComponents.joined(separator: "/"))
        guard directoryExists(stashDirURL) else { return }

        let contents = (try? FileManager.default.contentsOfDirectory(at: stashDirURL, includingPropertiesForKeys: nil)) ?? []
        for file in contents where file.lastPathComponent.hasPrefix(stem) {
            let restoredName = String(file.lastPathComponent.dropFirst(stem.count + 1))
            let destination = outputURL.appendingPathComponent(restoredName)
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.copyItem(at: file, to: destination)) != nil {
                verboseLog("Restored \(restoredName) from \(file.path)")
            }
        }
    }

    private static func findBIDSRoot(from eegFileURL: URL) -> URL? {
        var directory = eegFileURL.deletingLastPathComponent()
        for _ in 0..<6 {
            if fileExists(directory.appendingPathComponent("dataset_description.json")) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return nil
    }

    private static func normalizedMFFURL(_ url: URL) -> URL {
        url.pathExtension.lowercased() == "mff" ? url : url.appendingPathExtension("mff")
    }

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
