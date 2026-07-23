//
//  InspectBIDS.swift
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
//  Verifies a BIDS-EEG recording (or every recording under a directory) has
//  the sidecars EVA's from-bids conversion expects, and flags anything that
//  looks off. Not a full BIDS validator — focused on what round-trips through
//  eva-bids matter for.
//

import Foundation

struct InspectBIDSOptions {
    var inputURL: URL
    var subject: String?
    var session: String?
    var task: String?
    var run: Int?
    var verbose: Bool
}

private enum Severity: String {
    case pass = "PASS"
    case warn = "WARN"
    case fail = "FAIL"
}

private struct Finding {
    let severity: Severity
    let message: String
}

enum InspectBIDS {
    static func run(_ options: InspectBIDSOptions) throws -> Bool {
        let edfFiles = try resolveEDFFiles(options)
        writeStdoutLine("Inspecting \(edfFiles.count) recording\(edfFiles.count == 1 ? "" : "s")")

        var anyFailure = false
        for edfURL in edfFiles {
            writeStdoutLine("")
            writeStdoutLine(edfURL.path)
            let findings = inspect(edfURL: edfURL)
            for finding in findings {
                writeStdoutLine("  [\(finding.severity.rawValue)] \(finding.message)")
                if finding.severity == .fail { anyFailure = true }
            }
        }
        writeStdoutLine("")
        writeStdoutLine(anyFailure ? "Result: FAIL" : "Result: PASS")
        return !anyFailure
    }

    private static func resolveEDFFiles(_ options: InspectBIDSOptions) throws -> [URL] {
        let inputURL = options.inputURL
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw EVABIDSError.notFound(inputURL)
        }
        if fileExists(inputURL) {
            guard inputURL.lastPathComponent.hasSuffix("_eeg.edf") else {
                throw EVABIDSError.usage("\(inputURL.lastPathComponent) is not a *_eeg.edf file.")
            }
            return [inputURL]
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
            guard let entities = BIDSEntities.parse(fromFileName: url.lastPathComponent) else { continue }
            if let subject = options.subject, entities.subject != subject { continue }
            if let session = options.session, entities.session != session { continue }
            if let task = options.task, entities.task != task { continue }
            if let run = options.run, entities.run != run { continue }
            matches.append(url)
        }
        guard !matches.isEmpty else {
            throw EVABIDSError.usage("No *_eeg.edf recordings matched under \(inputURL.path).")
        }
        return matches.sorted { $0.path < $1.path }
    }

    private static func inspect(edfURL: URL) -> [Finding] {
        var findings: [Finding] = []
        let eegDirURL = edfURL.deletingLastPathComponent()
        let stem = String(edfURL.lastPathComponent.dropLast("_eeg.edf".count))

        let edf: EDFRecording
        do {
            edf = try EDFReader.load(from: edfURL)
            findings.append(Finding(severity: .pass, message: "EDF header parses (\(edf.channels.count) channels)"))
        } catch {
            findings.append(Finding(severity: .fail, message: "EDF file failed to parse: \(error.localizedDescription)"))
            return findings
        }

        let channelsURL = eegDirURL.appendingPathComponent("\(stem)_channels.tsv")
        if fileExists(channelsURL) {
            if let (headers, rows) = try? TSV.readWithHeaders(channelsURL) {
                let requiredColumns = ["name", "type", "units"]
                let missingColumns = requiredColumns.filter { !headers.contains($0) }
                if missingColumns.isEmpty {
                    findings.append(Finding(severity: .pass, message: "\(stem)_channels.tsv has required columns"))
                } else {
                    findings.append(Finding(severity: .fail, message: "\(stem)_channels.tsv is missing column(s): \(missingColumns.joined(separator: ", "))"))
                }
                if rows.count != edf.channels.count {
                    findings.append(Finding(severity: .fail, message: "\(stem)_channels.tsv has \(rows.count) rows but EDF has \(edf.channels.count) signals"))
                } else {
                    findings.append(Finding(severity: .pass, message: "\(stem)_channels.tsv row count matches EDF signal count"))
                }
                let tsvNames = Set(rows.compactMap { $0["name"] })
                let edfNames = Set(edf.channels.map(\.label))
                let missingFromTSV = edfNames.subtracting(tsvNames)
                if !missingFromTSV.isEmpty {
                    findings.append(Finding(severity: .warn, message: "EDF channel(s) not listed in channels.tsv: \(missingFromTSV.sorted().joined(separator: ", "))"))
                }
            } else {
                findings.append(Finding(severity: .fail, message: "\(stem)_channels.tsv could not be read"))
            }
        } else {
            findings.append(Finding(severity: .fail, message: "\(stem)_channels.tsv is missing"))
        }

        let eventsURL = eegDirURL.appendingPathComponent("\(stem)_events.tsv")
        if fileExists(eventsURL) {
            if let (headers, rows) = try? TSV.readWithHeaders(eventsURL) {
                let missingColumns = ["onset", "duration"].filter { !headers.contains($0) }
                if missingColumns.isEmpty {
                    findings.append(Finding(severity: .pass, message: "\(stem)_events.tsv has required columns (\(rows.count) events)"))
                } else {
                    findings.append(Finding(severity: .fail, message: "\(stem)_events.tsv is missing column(s): \(missingColumns.joined(separator: ", "))"))
                }
            } else {
                findings.append(Finding(severity: .fail, message: "\(stem)_events.tsv could not be read"))
            }
        } else {
            findings.append(Finding(severity: .warn, message: "\(stem)_events.tsv is missing"))
        }

        let eegJSONURL = eegDirURL.appendingPathComponent("\(stem)_eeg.json")
        if fileExists(eegJSONURL) {
            if let json = try? BIDSJSON.read(eegJSONURL) {
                let requiredFields = ["TaskName", "SamplingFrequency", "EEGReference", "PowerLineFrequency", "SoftwareFilters"]
                let missingFields = requiredFields.filter { json[$0] == nil }
                if missingFields.isEmpty {
                    findings.append(Finding(severity: .pass, message: "\(stem)_eeg.json has required fields"))
                } else {
                    findings.append(Finding(severity: .fail, message: "\(stem)_eeg.json is missing field(s): \(missingFields.joined(separator: ", "))"))
                }
                if let declaredRate = json["SamplingFrequency"] as? Double {
                    let actualRates = Set(edf.channels.map { ($0.samplingRate).rounded() })
                    if !actualRates.contains(declaredRate.rounded()) {
                        findings.append(Finding(severity: .warn, message: "\(stem)_eeg.json SamplingFrequency \(declaredRate) Hz does not match any EDF signal rate (\(actualRates.sorted()))"))
                    }
                }
            } else {
                findings.append(Finding(severity: .fail, message: "\(stem)_eeg.json could not be parsed as JSON"))
            }
        } else {
            findings.append(Finding(severity: .fail, message: "\(stem)_eeg.json is missing"))
        }

        let electrodesURL = eegDirURL.appendingPathComponent("\(stem)_electrodes.tsv")
        let coordsystemURL = eegDirURL.appendingPathComponent("\(stem)_coordsystem.json")
        switch (fileExists(electrodesURL), fileExists(coordsystemURL)) {
        case (true, true):
            findings.append(Finding(severity: .pass, message: "\(stem)_electrodes.tsv and \(stem)_coordsystem.json both present"))
        case (true, false):
            findings.append(Finding(severity: .warn, message: "\(stem)_electrodes.tsv present without \(stem)_coordsystem.json"))
        case (false, true):
            findings.append(Finding(severity: .warn, message: "\(stem)_coordsystem.json present without \(stem)_electrodes.tsv"))
        case (false, false):
            findings.append(Finding(severity: .warn, message: "No electrode position sidecars found"))
        }

        if let bidsRootURL = findBIDSRoot(from: edfURL) {
            let datasetDescriptionURL = bidsRootURL.appendingPathComponent("dataset_description.json")
            if fileExists(datasetDescriptionURL) {
                findings.append(Finding(severity: .pass, message: "dataset_description.json present at \(bidsRootURL.path)"))
            } else {
                findings.append(Finding(severity: .warn, message: "dataset_description.json missing at \(bidsRootURL.path)"))
            }

            let participantsURL = bidsRootURL.appendingPathComponent("participants.tsv")
            if let entities = BIDSEntities.parse(fromFileName: edfURL.lastPathComponent) {
                if let rows = try? TSV.read(participantsURL) {
                    let participantID = "sub-\(entities.subject)"
                    if rows.contains(where: { $0["participant_id"] == participantID }) {
                        findings.append(Finding(severity: .pass, message: "participants.tsv lists \(participantID)"))
                    } else {
                        findings.append(Finding(severity: .warn, message: "participants.tsv does not list \(participantID)"))
                    }
                } else {
                    findings.append(Finding(severity: .warn, message: "participants.tsv missing at \(bidsRootURL.path)"))
                }
            }
        } else {
            findings.append(Finding(severity: .warn, message: "Could not locate dataset_description.json above this recording"))
        }

        return findings
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
}
