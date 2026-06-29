//
//  SignalImportReader.swift
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
//  Native importers for common EEG exchange formats.
//
//  Attribution: the BrainVision, EDF/EDF+, EEGLAB, Persyst, and BESA reader
//  behavior in this file was implemented with reference to the corresponding
//  MNE-Python readers by the MNE contributors (BSD-3-Clause): mne/io/
//  brainvision/brainvision.py, mne/io/edf/edf.py, mne/io/eeglab/eeglab.py,
//  mne/io/persyst/persyst.py, mne/io/besa/besa.py, and the montage helpers in
//  mne/channels/_standard_montage_utils.py. BESA .avr/.mul/.generic structure
//  was also checked against the public BESA "Working With Additional Files"
//  documentation. See THIRD_PARTY_NOTICES.md for the MNE-Python BSD-3-Clause
//  notice.
//

import Foundation
import simd

nonisolated struct SignalImportProgress: Sendable {
    var fraction: Double
    var message: String
    var detail: String?
}

nonisolated struct ImportedRecording: Sendable {
    var signal: MFFSignalData
    var layout: SensorLayout?
    var geometry: ElectrodeGeometry?
    /// Peripheral/physiological channels (ECG, EMG, …) shown alongside the EEG,
    /// when the source provides them. Display-only; not part of `signal`.
    var pnsSignal: MFFSignalData?
    var antiAliasTimingCorrection: MFFAntiAliasTimingCorrection? = nil
}

nonisolated enum SignalImportError: LocalizedError {
    case unsupportedFormat(URL)
    case unsupportedVariant(URL, String)
    case missingSidecar(URL, String)
    case malformedFile(URL, String)
    case emptySignal(URL)
    case mneBridgeUnavailable(URL, String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let url):
            return "EVA cannot read \(url.lastPathComponent) yet."
        case .unsupportedVariant(let url, let details):
            return "EVA cannot read this variant of \(url.lastPathComponent): \(details)"
        case .missingSidecar(let url, let sidecar):
            return "\(url.lastPathComponent) requires \(sidecar), but that file was not found."
        case .malformedFile(let url, let details):
            return "Unable to parse \(url.lastPathComponent): \(details)"
        case .emptySignal(let url):
            return "\(url.lastPathComponent) did not contain any readable samples."
        case .mneBridgeUnavailable(let url, let details):
            return "Unable to read \(url.lastPathComponent) through MNE-Python: \(details)"
        }
    }
}

nonisolated enum SignalImportReader {
    static let supportedRecordingExtensions: Set<String> = [
        "mff",
        "vhdr", "vmrk", "eeg",
        "edf",
        "lay", "dat",
        "avr", "mul"
    ]

    static let supportedLocationExtensions: Set<String> = ["sfp", "elp", "loc"]

    static func isSupportedRecordingURL(_ url: URL) -> Bool {
        supportedRecordingExtensions.contains(url.pathExtension.lowercased())
    }

    static func load(
        from url: URL,
        progress: (@Sendable (SignalImportProgress) -> Void)? = nil
    ) throws -> ImportedRecording {
        let ext = url.pathExtension.lowercased()
        let imported: ImportedRecording

        switch ext {
        case "mff":
            let reader = MFFReader()
            let antiAliasTimingCorrection = try? reader.antiAliasTimingCorrection(in: url)
            let loadDetail = antiAliasTimingCorrection?.loadingMessage
            let report: (Double, String) -> Void = { fraction, message in
                progress?(SignalImportProgress(
                    fraction: fraction,
                    message: message,
                    detail: loadDetail
                ))
            }

            report(0.01, "Inspecting MFF package")
            let signal = try reader.loadSignal(from: url) { fraction in
                report(0.02 + 0.76 * fraction, "Reading EEG channels")
            }
            report(0.80, "Loading sensor layout")
            let pnsSignal = try? reader.loadPNSSignal(from: url) { fraction in
                report(0.82 + 0.14 * fraction, "Reading PNS channels")
            }
            report(0.96, "Loading electrode locations")
            imported = ImportedRecording(
                signal: signal,
                layout: SensorLayout.load(fromPackageContaining: signal.signalURL),
                geometry: ElectrodeGeometry.load(fromPackageContaining: signal.signalURL),
                pnsSignal: pnsSignal,
                antiAliasTimingCorrection: antiAliasTimingCorrection
            )
        case "vhdr", "vmrk", "eeg":
            progress?(SignalImportProgress(fraction: 0.05, message: "Reading BrainVision recording", detail: nil))
            imported = try BrainVisionSignalReader.load(from: url)
        case "edf":
            progress?(SignalImportProgress(fraction: 0.05, message: "Reading EDF recording", detail: nil))
            imported = try EDFSignalReader.load(from: url)
        case "lay", "dat":
            progress?(SignalImportProgress(fraction: 0.05, message: "Reading Persyst recording", detail: nil))
            imported = try PersystSignalReader.load(from: url)
        case "set", "fdt":
            throw SignalImportError.unsupportedVariant(
                url,
                "EEGLAB import is scaffolded through MNE-Python, but it is disabled until we have representative .set/.fdt files to validate it."
            )
        case "avr", "mul":
            progress?(SignalImportProgress(fraction: 0.05, message: "Reading BESA recording", detail: nil))
            imported = try BESAASCIIReader.load(from: url)
        case "generic":
            throw SignalImportError.unsupportedVariant(
                url,
                "BESA .generic import is scaffolded, but it is disabled until we have representative files to validate the header variants and data ordering."
            )
        case "foc", "fsg":
            throw SignalImportError.unsupportedVariant(
                url,
                "BESA .foc/.fsg are binary export formats; the public BESA page identifies them but does not define enough byte-level structure for a safe native reader."
            )
        default:
            throw SignalImportError.unsupportedFormat(url)
        }

        progress?(SignalImportProgress(
            fraction: 0.98,
            message: "Checking electrode sidecars",
            detail: imported.antiAliasTimingCorrection?.loadingMessage
        ))
        let withLocations = attachLocationSidecar(to: imported)
        progress?(SignalImportProgress(
            fraction: 1,
            message: "Loaded",
            detail: withLocations.antiAliasTimingCorrection?.loadingMessage
        ))
        return withLocations
    }

    private static func attachLocationSidecar(to imported: ImportedRecording) -> ImportedRecording {
        guard imported.layout == nil || imported.geometry == nil else {
            return imported
        }

        guard let locations = ElectrodeLocationReader.loadSidecar(
            near: imported.signal.signalURL,
            channelNames: imported.signal.channelNames
        ) else {
            return imported
        }

        return ImportedRecording(
            signal: imported.signal,
            layout: imported.layout ?? locations.layout,
            geometry: imported.geometry ?? locations.geometry,
            pnsSignal: imported.pnsSignal,
            antiAliasTimingCorrection: imported.antiAliasTimingCorrection
        )
    }
}

// MARK: - BrainVision

private nonisolated enum BrainVisionSignalReader {
    static func load(from url: URL) throws -> ImportedRecording {
        let headerURL = try headerURL(for: url)
        let text = try ImportText.read(headerURL)
        let ini = ImportINI.parse(text)
        let common = ini.section("common infos") ?? [:]

        guard let numberText = common["numberofchannels"], let numberOfChannels = Int(numberText) else {
            throw SignalImportError.malformedFile(headerURL, "missing NumberOfChannels")
        }
        guard let samplingIntervalText = common["samplinginterval"],
              let samplingInterval = Double(samplingIntervalText),
              samplingInterval > 0 else {
            throw SignalImportError.malformedFile(headerURL, "missing SamplingInterval")
        }
        let samplingRate = 1_000_000.0 / samplingInterval
        let dataFormat = (common["dataformat"] ?? "BINARY").uppercased()
        let orientation = (common["dataorientation"] ?? "MULTIPLEXED").uppercased()

        guard let dataFileName = common["datafile"], !dataFileName.isEmpty else {
            throw SignalImportError.malformedFile(headerURL, "missing DataFile")
        }
        let dataURL = headerURL.deletingLastPathComponent().appendingPathComponent(dataFileName)
        guard FileManager.default.fileExists(atPath: dataURL.path) else {
            throw SignalImportError.missingSidecar(headerURL, dataFileName)
        }

        let channelInfos = ini.section("channel infos") ?? [:]
        let channels = parseChannelInfos(channelInfos, count: numberOfChannels)
        let channelNames = channels.map(\.name)
        let data: [[Float]]
        if dataFormat == "BINARY" {
            let binaryInfos = ini.section("binary infos") ?? [:]
            let binaryFormat = (binaryInfos["binaryformat"] ?? "INT_16").uppercased()
            data = try readBinaryData(
                dataURL,
                channelCount: numberOfChannels,
                format: binaryFormat,
                orientation: orientation,
                scales: channels.map(\.scaleToMicrovolts),
                dataPoints: Int(common["datapoints"] ?? "")
            )
        } else if dataFormat == "ASCII" {
            data = try readASCIIData(
                dataURL,
                channelCount: numberOfChannels,
                orientation: orientation,
                scales: channels.map(\.scaleToMicrovolts)
            )
        } else {
            throw SignalImportError.unsupportedVariant(headerURL, "DataFormat \(dataFormat)")
        }

        guard let sampleCount = data.first?.count, sampleCount > 0 else {
            throw SignalImportError.emptySignal(headerURL)
        }
        let markerURL = common["markerfile"].map {
            headerURL.deletingLastPathComponent().appendingPathComponent($0)
        }
        let events = markerURL.flatMap { try? parseMarkers($0, samplingRate: samplingRate) } ?? []
        let coordinates = parseCoordinates(ini.section("coordinates"), channelNames: channelNames)

        let signal = MFFSignalData(
            signalURL: headerURL,
            signalType: "BrainVision",
            numberOfChannels: numberOfChannels,
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            recordingStartTime: nil,
            events: events,
            data: data,
            channelNames: channelNames
        )
        return ImportedRecording(
            signal: signal,
            layout: coordinates.layout,
            geometry: coordinates.geometry
        )
    }

    private struct ChannelInfo {
        var name: String
        var scaleToMicrovolts: Double
    }

    private static func headerURL(for url: URL) throws -> URL {
        switch url.pathExtension.lowercased() {
        case "vhdr":
            return url
        case "vmrk", "eeg":
            let sibling = url.deletingPathExtension().appendingPathExtension("vhdr")
            guard FileManager.default.fileExists(atPath: sibling.path) else {
                throw SignalImportError.missingSidecar(url, sibling.lastPathComponent)
            }
            return sibling
        default:
            throw SignalImportError.unsupportedFormat(url)
        }
    }

    private static func parseChannelInfos(_ infos: [String: String], count: Int) -> [ChannelInfo] {
        (0..<count).map { index in
            let key = "ch\(index + 1)"
            let parts = (infos[key] ?? "Ch\(index + 1),,1,µV")
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            let name = parts.first?.replacingOccurrences(of: #"\\1"#, with: ",").nonEmpty
                ?? "Ch\(index + 1)"
            let resolution = parts.count > 2 ? Double(parts[2]) ?? 1 : 1
            let unit = parts.count > 3 ? parts[3].nonEmpty ?? "µV" : "µV"
            return ChannelInfo(
                name: name,
                scaleToMicrovolts: resolution * UnitScale.microvoltsPerUnit(unit)
            )
        }
    }

    private static func readBinaryData(
        _ url: URL,
        channelCount: Int,
        format: String,
        orientation: String,
        scales: [Double],
        dataPoints: Int?
    ) throws -> [[Float]] {
        let bytes = try Data(contentsOf: url)
        let valueByteCount: Int
        let valueAt: (Data, Int) throws -> Double
        switch format {
        case "INT_16":
            valueByteCount = 2
            valueAt = { Double(try BinaryImport.int16LE($0, at: $1)) }
        case "INT_32":
            valueByteCount = 4
            valueAt = { Double(try BinaryImport.int32LE($0, at: $1)) }
        case "IEEE_FLOAT_32":
            valueByteCount = 4
            valueAt = { Double(try BinaryImport.float32LE($0, at: $1)) }
        default:
            throw SignalImportError.unsupportedVariant(url, "BrainVision BinaryFormat \(format)")
        }

        let inferredSamples = bytes.count / max(valueByteCount * channelCount, 1)
        let sampleCount = dataPoints ?? inferredSamples
        guard sampleCount > 0, bytes.count >= sampleCount * channelCount * valueByteCount else {
            throw SignalImportError.emptySignal(url)
        }

        var data = Array(repeating: [Float](repeating: 0, count: sampleCount), count: channelCount)
        var offset = 0
        switch orientation {
        case "MULTIPLEXED":
            for sample in 0..<sampleCount {
                for channel in 0..<channelCount {
                    data[channel][sample] = Float(try valueAt(bytes, offset) * scales[channel])
                    offset += valueByteCount
                }
            }
        case "VECTORIZED":
            for channel in 0..<channelCount {
                for sample in 0..<sampleCount {
                    data[channel][sample] = Float(try valueAt(bytes, offset) * scales[channel])
                    offset += valueByteCount
                }
            }
        default:
            throw SignalImportError.unsupportedVariant(url, "DataOrientation \(orientation)")
        }
        return data
    }

    private static func readASCIIData(
        _ url: URL,
        channelCount: Int,
        orientation: String,
        scales: [Double]
    ) throws -> [[Float]] {
        guard orientation == "MULTIPLEXED" else {
            throw SignalImportError.unsupportedVariant(url, "ASCII vectorized BrainVision data")
        }
        let values = ImportText.numericTokens(try ImportText.read(url))
        guard values.count >= channelCount else {
            throw SignalImportError.emptySignal(url)
        }
        let sampleCount = values.count / channelCount
        var data = Array(repeating: [Float](repeating: 0, count: sampleCount), count: channelCount)
        for sample in 0..<sampleCount {
            for channel in 0..<channelCount {
                data[channel][sample] = Float(values[sample * channelCount + channel] * scales[channel])
            }
        }
        return data
    }

    private static func parseMarkers(_ url: URL, samplingRate: Double) throws -> [MFFEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let ini = ImportINI.parse(try ImportText.read(url))
        let markers = ini.section("marker infos") ?? [:]
        return markers.keys.sorted(by: ImportText.naturalKeySort).compactMap { key in
            guard key.lowercased().hasPrefix("mk") else { return nil }
            let parts = (markers[key] ?? "")
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count >= 3,
                  !parts[0].localizedCaseInsensitiveContains("new segment"),
                  let sample = Int(parts[2]) else {
                return nil
            }
            let description = parts.count > 1 ? parts[1].nonEmpty ?? parts[0] : parts[0]
            let onset = Double(max(sample - 1, 0)) / samplingRate
            return MFFEvent(
                id: "\(url.lastPathComponent)-\(key)",
                code: description,
                beginTimeSeconds: onset,
                rawBeginTime: "\(sample)",
                sourceFile: url.lastPathComponent
            )
        }
    }

    private static func parseCoordinates(
        _ section: [String: String]?,
        channelNames: [String]
    ) -> ImportedElectrodeLocations {
        guard let section else { return ImportedElectrodeLocations(layout: nil, geometry: nil) }
        var coordinates: [(label: String, vector: SIMD3<Double>)] = []
        for (key, value) in section {
            guard let index = Int(key.lowercased().replacingOccurrences(of: "ch", with: "")),
                  index > 0,
                  index <= channelNames.count else {
                continue
            }
            let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard parts.count >= 3 else { continue }
            let radius = parts[0] == 1 ? 95.0 : parts[0]
            let theta = parts[1] * .pi / 180
            let phi = parts[2] * .pi / 180
            let x = radius * sin(theta) * cos(phi)
            let y = radius * sin(theta) * sin(phi)
            let z = radius * cos(theta)
            coordinates.append((channelNames[index - 1], SIMD3<Double>(x, y, z)))
        }
        return ElectrodeLocationReader.locations(from: coordinates, channelNames: channelNames, name: "BrainVision Coordinates")
    }
}

// MARK: - EDF

private nonisolated enum EDFSignalReader {
    static func load(from url: URL) throws -> ImportedRecording {
        let bytes = try Data(contentsOf: url)
        guard bytes.count >= 256 else {
            throw SignalImportError.malformedFile(url, "header is too short")
        }

        let headerByteCount = try Int(field(bytes, offset: 184, length: 8)) ?? 0
        let recordCountField = try field(bytes, offset: 236, length: 8)
        let recordCount = Int(recordCountField) ?? -1
        let recordDuration = Double(try field(bytes, offset: 244, length: 8)) ?? 0
        let signalCount = Int(try field(bytes, offset: 252, length: 4)) ?? 0
        guard headerByteCount >= 256, signalCount > 0, recordDuration > 0 else {
            throw SignalImportError.malformedFile(url, "invalid fixed header")
        }

        var cursor = 256
        let labels = try readStringArray(bytes, cursor: &cursor, count: signalCount, width: 16)
        _ = try readStringArray(bytes, cursor: &cursor, count: signalCount, width: 80)
        let physicalDimensions = try readStringArray(bytes, cursor: &cursor, count: signalCount, width: 8)
        let physicalMin = try readDoubleArray(bytes, cursor: &cursor, count: signalCount, width: 8)
        let physicalMax = try readDoubleArray(bytes, cursor: &cursor, count: signalCount, width: 8)
        let digitalMin = try readDoubleArray(bytes, cursor: &cursor, count: signalCount, width: 8)
        let digitalMax = try readDoubleArray(bytes, cursor: &cursor, count: signalCount, width: 8)
        _ = try readStringArray(bytes, cursor: &cursor, count: signalCount, width: 80)
        let samplesPerRecord = try readIntArray(bytes, cursor: &cursor, count: signalCount, width: 8)
        _ = try readStringArray(bytes, cursor: &cursor, count: signalCount, width: 32)

        let annotationChannels = Set(labels.indices.filter {
            labels[$0].lowercased().contains("edf annotations")
        })
        let dataChannels = labels.indices.filter { !annotationChannels.contains($0) }
        guard let samplesPerDataRecord = dataChannels.map({ samplesPerRecord[$0] }).first,
              dataChannels.allSatisfy({ samplesPerRecord[$0] == samplesPerDataRecord }) else {
            throw SignalImportError.unsupportedVariant(url, "mixed EDF sample rates")
        }
        let recordByteCount = samplesPerRecord.reduce(0, +) * 2
        let actualRecordCount = recordCount >= 0
            ? recordCount
            : max((bytes.count - headerByteCount) / max(recordByteCount, 1), 0)
        let sampleCount = actualRecordCount * samplesPerDataRecord
        let samplingRate = Double(samplesPerDataRecord) / recordDuration
        guard sampleCount > 0, samplingRate > 0 else {
            throw SignalImportError.emptySignal(url)
        }

        var data = Array(repeating: [Float](repeating: 0, count: sampleCount), count: dataChannels.count)
        var dataOffset = headerByteCount
        for record in 0..<actualRecordCount {
            for signalIndex in 0..<signalCount {
                let count = samplesPerRecord[signalIndex]
                let outIndex = dataChannels.firstIndex(of: signalIndex)
                let scale = UnitScale.microvoltsPerUnit(physicalDimensions[signalIndex])
                let slope = (physicalMax[signalIndex] - physicalMin[signalIndex]) / (digitalMax[signalIndex] - digitalMin[signalIndex])
                for localSample in 0..<count {
                    let digital = Double(try BinaryImport.int16LE(bytes, at: dataOffset))
                    dataOffset += 2
                    guard let outIndex else { continue }
                    let physical = (digital - digitalMin[signalIndex]) * slope + physicalMin[signalIndex]
                    data[outIndex][record * samplesPerDataRecord + localSample] = Float(physical * scale)
                }
            }
        }

        let channelNames = dataChannels.map { labels[$0].nonEmpty ?? "Ch\($0 + 1)" }
        let signal = MFFSignalData(
            signalURL: url,
            signalType: "EDF",
            numberOfChannels: channelNames.count,
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            recordingStartTime: nil,
            events: [],
            data: data,
            channelNames: channelNames
        )
        return ImportedRecording(signal: signal, layout: nil, geometry: nil)
    }

    private static func field(_ data: Data, offset: Int, length: Int) throws -> String {
        guard offset >= 0, offset + length <= data.count else {
            throw SignalImportError.malformedFile(URL(fileURLWithPath: "EDF"), "unexpected end of header")
        }
        return String(data: data[offset..<offset + length], encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func readStringArray(_ data: Data, cursor: inout Int, count: Int, width: Int) throws -> [String] {
        try (0..<count).map { _ in
            let value = try field(data, offset: cursor, length: width)
            cursor += width
            return value
        }
    }

    private static func readDoubleArray(_ data: Data, cursor: inout Int, count: Int, width: Int) throws -> [Double] {
        try readStringArray(data, cursor: &cursor, count: count, width: width).map { Double($0) ?? 0 }
    }

    private static func readIntArray(_ data: Data, cursor: inout Int, count: Int, width: Int) throws -> [Int] {
        try readStringArray(data, cursor: &cursor, count: count, width: width).map { Int($0) ?? 0 }
    }
}

// MARK: - Persyst

private nonisolated enum PersystSignalReader {
    static func load(from url: URL) throws -> ImportedRecording {
        let layURL: URL
        if url.pathExtension.lowercased() == "lay" {
            layURL = url
        } else {
            let sibling = url.deletingPathExtension().appendingPathExtension("lay")
            guard FileManager.default.fileExists(atPath: sibling.path) else {
                throw SignalImportError.missingSidecar(url, sibling.lastPathComponent)
            }
            layURL = sibling
        }

        let sections = parseLAY(try ImportText.read(layURL))
        let fileInfo = sections["fileinfo"] ?? [:]
        let channelMap = sections["channelmap"] ?? [:]
        guard let datName = fileInfo["file"]?.nonEmpty else {
            throw SignalImportError.malformedFile(layURL, "missing FileInfo/File")
        }
        let datURL = layURL.deletingLastPathComponent().appendingPathComponent(URL(fileURLWithPath: datName).lastPathComponent)
        guard FileManager.default.fileExists(atPath: datURL.path) else {
            throw SignalImportError.missingSidecar(layURL, datURL.lastPathComponent)
        }

        let channelCount = Int(fileInfo["waveformcount"] ?? "") ?? channelMap.count
        let samplingRate = Double(fileInfo["samplingrate"] ?? "") ?? 0
        let calibration = Double(fileInfo["calibration"] ?? "") ?? 1
        let dataType = Int(fileInfo["datatype"] ?? "") ?? 0
        let byteCount = dataType == 7 ? 4 : 2
        guard channelCount > 0, samplingRate > 0 else {
            throw SignalImportError.malformedFile(layURL, "invalid waveform count or sampling rate")
        }

        let bytes = try Data(contentsOf: datURL)
        let sampleCount = bytes.count / max(channelCount * byteCount, 1)
        guard sampleCount > 0 else { throw SignalImportError.emptySignal(datURL) }
        var data = Array(repeating: [Float](repeating: 0, count: sampleCount), count: channelCount)
        var offset = 0
        for sample in 0..<sampleCount {
            for channel in 0..<channelCount {
                let raw: Double
                if dataType == 7 {
                    raw = Double(try BinaryImport.int32LE(bytes, at: offset))
                } else if dataType == 0 {
                    raw = Double(try BinaryImport.int16LE(bytes, at: offset))
                } else {
                    throw SignalImportError.unsupportedVariant(layURL, "Persyst DataType \(dataType)")
                }
                data[channel][sample] = Float(raw * calibration)
                offset += byteCount
            }
        }

        let channelNames = channelMap.keys.sorted(by: ImportText.naturalKeySort).map {
            $0.uppercased().replacingOccurrences(of: "-REF", with: "")
        }
        let names = channelNames.count == channelCount
            ? channelNames
            : (0..<channelCount).map { "Ch\($0 + 1)" }
        let events = parseComments(sections["comments"] ?? [:], source: layURL)
        let signal = MFFSignalData(
            signalURL: layURL,
            signalType: "Persyst",
            numberOfChannels: channelCount,
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            recordingStartTime: nil,
            events: events,
            data: data,
            channelNames: names
        )
        return ImportedRecording(signal: signal, layout: nil, geometry: nil)
    }

    private static func parseLAY(_ text: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).lowercased()
                sections[current, default: [:]] = [:]
            } else if current == "comments" {
                let parts = line.split(separator: ",", maxSplits: 4, omittingEmptySubsequences: false)
                guard parts.count == 5 else { continue }
                let text = String(parts[4]).trimmingCharacters(in: .whitespacesAndNewlines)
                sections[current, default: [:]]["comment-\(sections[current]?.count ?? 0)-\(text)"] = line
            } else if let equals = line.firstIndex(of: "=") {
                let key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                sections[current, default: [:]][key] = value
            }
        }
        return sections
    }

    private static func parseComments(_ comments: [String: String], source: URL) -> [MFFEvent] {
        comments.values.enumerated().compactMap { index, line in
            let parts = line.split(separator: ",", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, let onset = Double(parts[0]) else { return nil }
            let text = String(parts[4]).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Comment"
            return MFFEvent(
                id: "\(source.lastPathComponent)-comment-\(index)",
                code: text,
                beginTimeSeconds: onset,
                rawBeginTime: String(parts[0]),
                sourceFile: source.lastPathComponent
            )
        }
    }
}

// MARK: - BESA ASCII and Generic

private nonisolated enum BESAASCIIReader {
    static func load(from url: URL) throws -> ImportedRecording {
        switch url.pathExtension.lowercased() {
        case "avr":
            return try readAVR(url)
        case "mul":
            return try readMUL(url)
        default:
            throw SignalImportError.unsupportedFormat(url)
        }
    }

    private static func readAVR(_ url: URL) throws -> ImportedRecording {
        let lines = ImportText.lines(try ImportText.read(url))
        guard let header = lines.first else {
            throw SignalImportError.malformedFile(url, "missing header")
        }
        let fields = ImportText.parseHeaderAssignments(header)
        let newStyle = fields.keys.contains("Nchan")
        let channelNames: [String]
        let dataLines: [String]
        if newStyle {
            guard lines.count >= 3 else {
                throw SignalImportError.malformedFile(url, "missing channel labels or data")
            }
            channelNames = lines[1].split(whereSeparator: \.isWhitespace).map(String.init)
            dataLines = Array(lines.dropFirst(2))
        } else {
            dataLines = Array(lines.dropFirst())
            channelNames = (0..<dataLines.count).map { "CH\(String(format: "%02d", $0 + 1))" }
        }
        let matrix = dataLines.map { ImportText.numericTokens($0) }.filter { !$0.isEmpty }
        guard let sampleCount = matrix.first?.count, sampleCount > 0 else {
            throw SignalImportError.emptySignal(url)
        }
        let scale = Double(fields["SB"] ?? "") ?? 1
        let samplingInterval = Double(fields["DI"] ?? "") ?? 0
        guard samplingInterval > 0 else {
            throw SignalImportError.malformedFile(url, "missing DI sampling interval")
        }
        let data = matrix.map { row in row.map { Float($0 / scale) } }
        let names = channelNames.count == data.count ? channelNames : (0..<data.count).map { "Ch\($0 + 1)" }
        let signal = MFFSignalData(
            signalURL: url,
            signalType: "BESA AVR",
            numberOfChannels: data.count,
            samplingRate: 1000.0 / samplingInterval,
            duration: Double(sampleCount) / (1000.0 / samplingInterval),
            recordingStartTime: nil,
            events: [],
            data: data,
            channelNames: names
        )
        return ImportedRecording(signal: signal, layout: nil, geometry: nil)
    }

    private static func readMUL(_ url: URL) throws -> ImportedRecording {
        let lines = ImportText.lines(try ImportText.read(url))
        guard lines.count >= 3 else {
            throw SignalImportError.malformedFile(url, "missing header, channel labels, or data")
        }
        let fields = ImportText.parseHeaderAssignments(lines[0])
        let channelNames = lines[1].split(whereSeparator: \.isWhitespace).map(String.init)
        let rows = lines.dropFirst(2).map { ImportText.numericTokens($0) }.filter { !$0.isEmpty }
        guard let sampleCount = rows.count.nonZero, let channelCount = rows.first?.count, channelCount > 0 else {
            throw SignalImportError.emptySignal(url)
        }
        let samplingInterval = Double(fields["SamplingInterval[ms]"] ?? "") ?? 0
        guard samplingInterval > 0 else {
            throw SignalImportError.malformedFile(url, "missing SamplingInterval[ms]")
        }
        let scale = Double(fields["Bins/uV"] ?? "") ?? 1
        var data = Array(repeating: [Float](repeating: 0, count: sampleCount), count: channelCount)
        for sample in rows.indices {
            for channel in 0..<min(channelCount, rows[sample].count) {
                data[channel][sample] = Float(rows[sample][channel] / scale)
            }
        }
        let names = channelNames.count == channelCount ? channelNames : (0..<channelCount).map { "Ch\($0 + 1)" }
        let signal = MFFSignalData(
            signalURL: url,
            signalType: "BESA MUL",
            numberOfChannels: channelCount,
            samplingRate: 1000.0 / samplingInterval,
            duration: Double(sampleCount) / (1000.0 / samplingInterval),
            recordingStartTime: nil,
            events: [],
            data: data,
            channelNames: names
        )
        return ImportedRecording(signal: signal, layout: nil, geometry: nil)
    }
}

private nonisolated enum BESAGenericReader {
    static func load(from url: URL) throws -> ImportedRecording {
        let headerURL = try genericHeaderURL(for: url)
        let parameters = try parseHeader(headerURL)
        guard let channelCount = Int(parameters["nchannels"] ?? ""),
              let samplingRate = Double(parameters["srate"] ?? ""),
              let format = parameters["format"]?.lowercased() else {
            throw SignalImportError.malformedFile(headerURL, "missing nChannels, sRate, or format")
        }
        let dataURL: URL
        if let file = parameters["file"]?.nonEmpty {
            dataURL = headerURL.deletingLastPathComponent().appendingPathComponent(file)
        } else if headerURL == url {
            throw SignalImportError.malformedFile(headerURL, "missing file= data path")
        } else {
            dataURL = url
        }
        let order = (parameters["order"] ?? parameters["orientation"] ?? parameters["arrangement"] ?? "multiplexed").lowercased()
        let offset = Int(parameters["dataoffset"] ?? "") ?? 0
        let factor = Double(parameters["factor"]?.split(whereSeparator: \.isWhitespace).first ?? "1") ?? 1
        let data: [[Float]]
        if format == "ascii" {
            var lines = ImportText.lines(try ImportText.read(dataURL))
            if offset > 0, offset < lines.count {
                lines.removeFirst(offset)
            }
            let values = ImportText.numericTokens(lines.joined(separator: "\n")).map { $0 * factor }
            data = try reshape(values: values, channelCount: channelCount, order: order, explicitSamples: Int(parameters["nsamples"] ?? ""))
        } else {
            let bytes = try Data(contentsOf: dataURL)
            let swap = (parameters["swapbytes"] ?? "off").lowercased() == "on"
            let values = try readBinaryValues(bytes, format: format, offset: offset, swapBytes: swap).map { $0 * factor }
            data = try reshape(values: values, channelCount: channelCount, order: order, explicitSamples: Int(parameters["nsamples"] ?? ""))
        }
        guard let sampleCount = data.first?.count, sampleCount > 0 else {
            throw SignalImportError.emptySignal(dataURL)
        }
        let channelNames = (0..<channelCount).map { "E\($0 + 1)" }
        let signal = MFFSignalData(
            signalURL: headerURL,
            signalType: "BESA Generic",
            numberOfChannels: channelCount,
            samplingRate: samplingRate,
            duration: Double(sampleCount) / samplingRate,
            recordingStartTime: nil,
            events: [],
            data: data,
            channelNames: channelNames
        )
        return ImportedRecording(signal: signal, layout: nil, geometry: nil)
    }

    private static func genericHeaderURL(for url: URL) throws -> URL {
        if url.pathExtension.lowercased() == "generic" { return url }
        let sibling = url.deletingPathExtension().appendingPathExtension("generic")
        if FileManager.default.fileExists(atPath: sibling.path) { return sibling }
        let general = url.deletingLastPathComponent().appendingPathComponent("BESA.generic")
        if FileManager.default.fileExists(atPath: general.path) { return general }
        throw SignalImportError.missingSidecar(url, sibling.lastPathComponent)
    }

    private static func parseHeader(_ url: URL) throws -> [String: String] {
        let lines = ImportText.lines(try ImportText.read(url))
        guard lines.first?.localizedCaseInsensitiveContains("BESA Generic Data") == true else {
            throw SignalImportError.malformedFile(url, "first line must be BESA Generic Data")
        }
        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "factor", values[key] != nil {
                continue
            }
            values[key] = value
        }
        return values
    }

    private static func readBinaryValues(_ bytes: Data, format: String, offset: Int, swapBytes: Bool) throws -> [Double] {
        let start = max(offset, 0)
        guard start < bytes.count else { return [] }
        let byteCount: Int
        let read: (Data, Int, Bool) throws -> Double
        switch format {
        case "short":
            byteCount = 2
            read = { Double(try BinaryImport.int16($0, at: $1, bigEndian: $2)) }
        case "int":
            byteCount = 4
            read = { Double(try BinaryImport.int32($0, at: $1, bigEndian: $2)) }
        case "float":
            byteCount = 4
            read = { Double(try BinaryImport.float32($0, at: $1, bigEndian: $2)) }
        case "double":
            byteCount = 8
            read = { try BinaryImport.double($0, at: $1, bigEndian: $2) }
        default:
            throw SignalImportError.unsupportedVariant(URL(fileURLWithPath: "BESA.generic"), "format \(format)")
        }
        let count = (bytes.count - start) / byteCount
        return try (0..<count).map { try read(bytes, start + $0 * byteCount, swapBytes) }
    }

    private static func reshape(values: [Double], channelCount: Int, order: String, explicitSamples: Int?) throws -> [[Float]] {
        let sampleCount = explicitSamples ?? values.count / max(channelCount, 1)
        var data = Array(repeating: [Float](repeating: 0, count: sampleCount), count: channelCount)
        switch order {
        case "multiplexed":
            for sample in 0..<sampleCount {
                for channel in 0..<channelCount {
                    let index = sample * channelCount + channel
                    guard index < values.count else { continue }
                    data[channel][sample] = Float(values[index])
                }
            }
        case "vectorized":
            for channel in 0..<channelCount {
                for sample in 0..<sampleCount {
                    let index = channel * sampleCount + sample
                    guard index < values.count else { continue }
                    data[channel][sample] = Float(values[index])
                }
            }
        default:
            throw SignalImportError.unsupportedVariant(URL(fileURLWithPath: "BESA.generic"), "order \(order)")
        }
        return data
    }
}

// MARK: - EEGLAB bridge

private nonisolated enum EEGLABSignalReader {
    static func load(from url: URL) throws -> ImportedRecording {
        let setURL: URL
        if url.pathExtension.lowercased() == "set" {
            setURL = url
        } else {
            let sibling = url.deletingPathExtension().appendingPathExtension("set")
            guard FileManager.default.fileExists(atPath: sibling.path) else {
                throw SignalImportError.missingSidecar(url, sibling.lastPathComponent)
            }
            setURL = sibling
        }

        let signal = try MNEPythonBridge.loadEEGLAB(setURL)
        let locations = ElectrodeLocationReader.loadSidecar(near: setURL, channelNames: signal.channelNames)
        return ImportedRecording(signal: signal, layout: locations?.layout, geometry: locations?.geometry)
    }
}

private nonisolated enum MNEPythonBridge {
    static func loadEEGLAB(_ url: URL) throws -> MFFSignalData {
        guard let python = pythonExecutableURL() else {
            throw SignalImportError.mneBridgeUnavailable(
                url,
                "set EVA_MNE_PYTHON or install MNE in /Users/molfesepj/micromamba/envs/mne/bin/python"
            )
        }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EVA-MNE-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let script = """
import json
import os
import sys
import numpy as np
import mne

fname = sys.argv[1]
outdir = sys.argv[2]
raw = mne.io.read_raw_eeglab(fname, preload=True, verbose="ERROR")
sfreq = float(raw.info["sfreq"])
data = (raw.get_data() * 1e6).astype("<f4", copy=False)
bin_path = os.path.join(outdir, "data.f32")
data.tofile(bin_path)
events = []
for idx, ann in enumerate(raw.annotations):
    events.append({
        "id": f"annotation-{idx}",
        "code": str(ann["description"]),
        "beginTimeSeconds": float(ann["onset"]),
        "rawBeginTime": str(ann["onset"]),
        "sourceFile": os.path.basename(fname),
    })
meta = {
    "channelNames": list(raw.ch_names),
    "numberOfChannels": int(data.shape[0]),
    "sampleCount": int(data.shape[1]),
    "samplingRate": sfreq,
    "events": events,
}
with open(os.path.join(outdir, "meta.json"), "w", encoding="utf-8") as f:
    json.dump(meta, f)
"""

        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", script, url.path, workDir.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown MNE error"
            throw SignalImportError.mneBridgeUnavailable(url, errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let metadataURL = workDir.appendingPathComponent("meta.json")
        let binaryURL = workDir.appendingPathComponent("data.f32")
        let metadata = try JSONDecoder().decode(MNEBridgeMetadata.self, from: Data(contentsOf: metadataURL))
        let bytes = try Data(contentsOf: binaryURL)
        var data = Array(repeating: [Float](repeating: 0, count: metadata.sampleCount), count: metadata.numberOfChannels)
        var offset = 0
        for channel in 0..<metadata.numberOfChannels {
            for sample in 0..<metadata.sampleCount {
                data[channel][sample] = try BinaryImport.float32LE(bytes, at: offset)
                offset += 4
            }
        }

        let events = metadata.events.map {
            MFFEvent(
                id: $0.id,
                code: $0.code,
                label: $0.label,
                eventDescription: $0.eventDescription,
                cell: $0.cell,
                beginTimeSeconds: $0.beginTimeSeconds,
                rawBeginTime: $0.rawBeginTime,
                sourceFile: $0.sourceFile
            )
        }
        return MFFSignalData(
            signalURL: url,
            signalType: "EEGLAB",
            numberOfChannels: metadata.numberOfChannels,
            samplingRate: metadata.samplingRate,
            duration: Double(metadata.sampleCount) / metadata.samplingRate,
            recordingStartTime: nil,
            events: events,
            data: data,
            channelNames: metadata.channelNames
        )
    }

    private static func pythonExecutableURL() -> URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["EVA_MNE_PYTHON"],
            "/Users/molfesepj/micromamba/envs/mne/bin/python",
            "/Users/molfesepj/micromamba/envs/mne/bin/python3",
            "/usr/bin/python3"
        ].compactMap { $0 }
        return candidates.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private struct MNEBridgeMetadata: Decodable {
        var channelNames: [String]
        var numberOfChannels: Int
        var sampleCount: Int
        var samplingRate: Double
        var events: [MNEBridgeEvent]
    }

    private struct MNEBridgeEvent: Decodable {
        var id: String
        var code: String
        var label: String?
        var eventDescription: String?
        var cell: String?
        var beginTimeSeconds: Double
        var rawBeginTime: String
        var sourceFile: String
    }
}

// MARK: - Electrode locations

nonisolated struct ImportedElectrodeLocations: Sendable {
    var layout: SensorLayout?
    var geometry: ElectrodeGeometry?
}

nonisolated enum ElectrodeLocationReader {
    static func loadSidecar(near signalURL: URL, channelNames: [String]?) -> ImportedElectrodeLocations? {
        let base = signalURL.deletingPathExtension()
        for ext in ["sfp", "elp", "loc"] {
            let url = base.appendingPathExtension(ext)
            guard FileManager.default.fileExists(atPath: url.path),
                  let locations = try? load(url, channelNames: channelNames) else {
                continue
            }
            return locations
        }
        return nil
    }

    static func load(_ url: URL, channelNames: [String]?) throws -> ImportedElectrodeLocations {
        let coordinates: [(label: String, vector: SIMD3<Double>)]
        switch url.pathExtension.lowercased() {
        case "sfp":
            coordinates = try readSFP(url)
        case "elp":
            coordinates = try readELP(url)
        case "loc":
            coordinates = try readLOC(url)
        default:
            throw SignalImportError.unsupportedFormat(url)
        }
        return locations(from: coordinates, channelNames: channelNames, name: url.lastPathComponent)
    }

    static func locations(
        from coordinates: [(label: String, vector: SIMD3<Double>)],
        channelNames: [String]?,
        name: String
    ) -> ImportedElectrodeLocations {
        let aligned = align(coordinates, channelNames: channelNames)
        guard !aligned.isEmpty else {
            return ImportedElectrodeLocations(layout: nil, geometry: nil)
        }
        let vectors = Dictionary(uniqueKeysWithValues: aligned.compactMap { index, vector -> (Int, SIMD3<Double>)? in
            let length = simd_length(vector)
            guard length > 0 else { return nil }
            return (index, vector / length)
        })
        let geometry = vectors.isEmpty ? nil : ElectrodeGeometry(name: name, positions: vectors)
        let layout = SensorLayout.projectedLayout(name: name, vectors: aligned)
        return ImportedElectrodeLocations(layout: layout, geometry: geometry)
    }

    private static func readSFP(_ url: URL) throws -> [(label: String, vector: SIMD3<Double>)] {
        try ImportText.lines(ImportText.read(url)).compactMap { line in
            parseLabelXYZ(line)
        }
    }

    private static func readELP(_ url: URL) throws -> [(label: String, vector: SIMD3<Double>)] {
        try ImportText.lines(ImportText.read(url)).compactMap { line in
            let parts = ImportText.tokens(line)
            if parts.count >= 5,
               let azimuth = Double(parts[2]),
               let horizontal = Double(parts[3]),
               let radiusValue = Double(parts[4]) {
                let label = parts[1]
                let polarRadius = abs(azimuth / 180.0)
                let az = (azimuth >= 0 ? horizontal : 180 + horizontal) * .pi / 180
                let pol = polarRadius * .pi
                let radius = radiusValue / 100
                return (
                    label,
                    SIMD3<Double>(
                        radius * sin(pol) * cos(az),
                        radius * sin(pol) * sin(az),
                        radius * cos(pol)
                    )
                )
            }
            return parseLabelXYZ(line)
        }
    }

    private static func readLOC(_ url: URL) throws -> [(label: String, vector: SIMD3<Double>)] {
        try ImportText.lines(ImportText.read(url)).compactMap { line in
            let parts = ImportText.tokens(line)
            if let xyz = parseLabelXYZ(line) {
                return xyz
            }
            if parts.count >= 4,
               Double(parts[0]) != nil,
               let theta = Double(parts[1]),
               let radius = Double(parts[2]) {
                let label = parts[3]
                let radians = theta * .pi / 180
                let x = radius * sin(radians)
                let y = radius * cos(radians)
                let z = sqrt(max(1 - x * x - y * y, 0))
                return (label, SIMD3<Double>(x, y, z))
            }
            if parts.count >= 3,
               let theta = Double(parts[1]),
               let radius = Double(parts[2]) {
                let label = parts[0]
                let radians = theta * .pi / 180
                let x = radius * sin(radians)
                let y = radius * cos(radians)
                let z = sqrt(max(1 - x * x - y * y, 0))
                return (label, SIMD3<Double>(x, y, z))
            }
            return nil
        }
    }

    private static func parseLabelXYZ(_ line: String) -> (label: String, vector: SIMD3<Double>)? {
        let parts = ImportText.tokens(line)
        guard parts.count >= 4 else { return nil }
        for labelIndex in 0..<parts.count {
            let numeric = parts.indices.filter { $0 != labelIndex }.compactMap { Double(parts[$0]) }
            guard numeric.count >= 3 else { continue }
            return (parts[labelIndex], SIMD3<Double>(numeric[0], numeric[1], numeric[2]))
        }
        return nil
    }

    private static func align(
        _ coordinates: [(label: String, vector: SIMD3<Double>)],
        channelNames: [String]?
    ) -> [(Int, SIMD3<Double>)] {
        guard let channelNames, !channelNames.isEmpty else {
            return coordinates.enumerated().map { ($0.offset, $0.element.vector) }
        }
        var lookup: [String: Int] = [:]
        for (index, name) in channelNames.enumerated() {
            let key = name.normalizedChannelName
            if lookup[key] == nil {
                lookup[key] = index
            }
        }
        var aligned: [(Int, SIMD3<Double>)] = []
        var used = Set<Int>()
        for coordinate in coordinates {
            guard let index = lookup[coordinate.label.normalizedChannelName],
                  !used.contains(index) else {
                continue
            }
            aligned.append((index, coordinate.vector))
            used.insert(index)
        }
        if aligned.isEmpty, coordinates.count == channelNames.count {
            aligned = coordinates.enumerated().map { ($0.offset, $0.element.vector) }
        }
        return aligned
    }
}

extension SensorLayout {
    nonisolated fileprivate static func projectedLayout(
        name: String,
        vectors: [(Int, SIMD3<Double>)]
    ) -> SensorLayout? {
        guard !vectors.isEmpty else { return nil }
        let points = vectors.map { (index: $0.0, x: $0.1.x, y: $0.1.y) }
        let centroidX = points.map(\.x).reduce(0, +) / Double(points.count)
        let centroidY = points.map(\.y).reduce(0, +) / Double(points.count)
        let maxRadius = points.map { hypot($0.x - centroidX, $0.y - centroidY) }.max() ?? 1
        let scale = maxRadius > 0 ? maxRadius : 1
        return SensorLayout(
            name: name,
            positions: points.map {
                SensorPosition(
                    channelIndex: $0.index,
                    x: ($0.x - centroidX) / scale,
                    y: ($0.y - centroidY) / scale
                )
            }.sorted { $0.channelIndex < $1.channelIndex }
        )
    }
}

// MARK: - Shared helpers

private nonisolated enum UnitScale {
    static func microvoltsPerUnit(_ unit: String) -> Double {
        switch unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "v":
            return 1_000_000
        case "mv":
            return 1_000
        case "uv", "µv", "μv", "":
            return 1
        case "nv":
            return 0.001
        default:
            return 1
        }
    }
}

private nonisolated enum ImportText {
    static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        throw SignalImportError.malformedFile(url, "unsupported text encoding")
    }

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix(";") && !$0.hasPrefix("//") }
    }

    static func tokens(_ line: String) -> [String] {
        line.replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    static func numericTokens(_ text: String) -> [Double] {
        tokens(text).compactMap(Double.init)
    }

    static func parseHeaderAssignments(_ line: String) -> [String: String] {
        let parts = line.split(separator: "=")
        guard parts.count > 1 else { return [:] }
        var result: [String: String] = [:]
        var key = parts[0].split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        for rawPart in parts.dropFirst() {
            let tokens = rawPart.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let value = tokens.first else { continue }
            result[key] = value
            key = tokens.dropFirst().last ?? ""
        }
        return result
    }

    static func naturalKeySort(_ left: String, _ right: String) -> Bool {
        left.localizedStandardCompare(right) == .orderedAscending
    }
}

private nonisolated struct ImportINI {
    var sections: [String: [String: String]]

    func section(_ name: String) -> [String: String]? {
        sections[name.lowercased()]
    }

    static func parse(_ text: String) -> ImportINI {
        var sections: [String: [String: String]] = [:]
        var current = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix(";") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).lowercased()
                sections[current, default: [:]] = [:]
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            sections[current, default: [:]][key] = value
        }
        return ImportINI(sections: sections)
    }
}

private nonisolated enum BinaryImport {
    static func int16LE(_ data: Data, at offset: Int) throws -> Int16 {
        try int16(data, at: offset, bigEndian: false)
    }

    static func int16(_ data: Data, at offset: Int, bigEndian: Bool) throws -> Int16 {
        try require(data, offset, 2)
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1])
        let value = bigEndian ? (b0 << 8 | b1) : (b1 << 8 | b0)
        return Int16(bitPattern: value)
    }

    static func int32LE(_ data: Data, at offset: Int) throws -> Int32 {
        try int32(data, at: offset, bigEndian: false)
    }

    static func int32(_ data: Data, at offset: Int, bigEndian: Bool) throws -> Int32 {
        try require(data, offset, 4)
        let bytes = (0..<4).map { UInt32(data[offset + $0]) }
        let value: UInt32
        if bigEndian {
            value = bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]
        } else {
            value = bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0]
        }
        return Int32(bitPattern: value)
    }

    static func float32LE(_ data: Data, at offset: Int) throws -> Float {
        try float32(data, at: offset, bigEndian: false)
    }

    static func float32(_ data: Data, at offset: Int, bigEndian: Bool) throws -> Float {
        Float(bitPattern: UInt32(bitPattern: try int32(data, at: offset, bigEndian: bigEndian)))
    }

    static func double(_ data: Data, at offset: Int, bigEndian: Bool) throws -> Double {
        try require(data, offset, 8)
        var value: UInt64 = 0
        if bigEndian {
            for index in 0..<8 {
                value = (value << 8) | UInt64(data[offset + index])
            }
        } else {
            for index in stride(from: 7, through: 0, by: -1) {
                value = (value << 8) | UInt64(data[offset + index])
            }
        }
        return Double(bitPattern: value)
    }

    private static func require(_ data: Data, _ offset: Int, _ count: Int) throws {
        guard offset >= 0, offset + count <= data.count else {
            throw SignalImportError.malformedFile(URL(fileURLWithPath: "binary"), "unexpected end of file")
        }
    }
}

private extension String {
    nonisolated var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated var normalizedChannelName: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-REF", with: "", options: .caseInsensitive)
            .lowercased()
    }
}

private extension Int {
    nonisolated var nonZero: Int? {
        self > 0 ? self : nil
    }
}
