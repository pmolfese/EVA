//
//  MFFWriter.swift
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
//  Native MFF export for EVA-processed signals.
//
//  Attribution: the signal block and epoch XML writer structure follows the
//  public mffpy writer implementation by the MFFPy contributors
//  (Apache-2.0; Copyright 2019 Brain Electrophysiology Laboratory Company LLC),
//  especially mffpy/bin_writer.py, mffpy/header_block/header_block.py, and
//  mffpy/epoch.py. See THIRD_PARTY_NOTICES.md.
//

import Foundation

nonisolated enum MFFExportKind: Sendable {
    case continuous
    case epoched
    case averaged

    var statusName: String {
        switch self {
        case .continuous:
            return "continuous"
        case .epoched:
            return "segmented"
        case .averaged:
            return "averaged"
        }
    }
}

nonisolated enum MFFWriterError: LocalizedError {
    case emptySignal
    case invalidSamplingRate(Double)
    case inconsistentChannelLengths
    case invalidSegment(EpochSegment)
    case existingOutput(URL)

    var errorDescription: String? {
        switch self {
        case .emptySignal:
            return "There are no samples to export."
        case .invalidSamplingRate(let rate):
            return "MFF export requires a positive integer sampling rate, but found \(rate)."
        case .inconsistentChannelLengths:
            return "MFF export requires every channel to have the same number of samples."
        case .invalidSegment(let segment):
            return "Cannot export invalid segment \(segment.category)."
        case .existingOutput(let url):
            return "\(url.lastPathComponent) already exists and could not be replaced."
        }
    }
}

nonisolated enum MFFWriter {
    static func write(
        signal: MFFSignalData,
        pnsSignal: MFFSignalData? = nil,
        segments: [EpochSegment],
        kind: MFFExportKind,
        to outputURL: URL,
        preserveSourceFileInfo: Bool = true
    ) throws {
        let sampleRate = try integerSamplingRate(signal.samplingRate)
        let sampleCount = try validate(signal: signal)
        let blocks = try exportBlocks(for: signal, sampleCount: sampleCount, segments: segments, kind: kind)

        let packageURL = normalizedMFFURL(outputURL)
        if FileManager.default.fileExists(atPath: packageURL.path) {
            do {
                try FileManager.default.removeItem(at: packageURL)
            } catch {
                throw MFFWriterError.existingOutput(packageURL)
            }
        }
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        do {
            try writeInfoXML(
                signal: signal,
                kind: kind,
                to: packageURL,
                preserveSourceFileInfo: preserveSourceFileInfo
            )
            try writeSignalInfoXML(signal: signal, to: packageURL)
            try writeSignalBinary(
                blocks: blocks.map { $0.withSignalData(signal.data) },
                channelCount: signal.numberOfChannels,
                sampleRate: sampleRate,
                to: packageURL
            )
            try writeEpochsXML(blocks: blocks, sampleRate: sampleRate, to: packageURL)
            try writeEventsXML(signal: signal, blocks: blocks, sampleRate: sampleRate, kind: kind, to: packageURL)
            try writeSensorLayoutXML(signal: signal, to: packageURL)
            copyOriginalFileIfPresent(named: "coordinates.xml", sourceSignalURL: signal.signalURL, to: packageURL)
            try writeSubjectXML(packageURL: packageURL)

            if let pns = pnsSignal,
               pns.numberOfChannels > 0,
               let firstChannel = pns.data.first, !firstChannel.isEmpty {
                let pnsSampleRate = try integerSamplingRate(pns.samplingRate)
                try writePNSBinary(pns: pns, sampleRate: pnsSampleRate, to: packageURL)
                try writePNSInfoXML(pns: pns, to: packageURL)
                try writePNSSetXML(pns: pns, to: packageURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: packageURL)
            throw error
        }
    }

    // MARK: - PNS export

    private static func writePNSBinary(
        pns: MFFSignalData,
        sampleRate: Int,
        to packageURL: URL
    ) throws {
        let channelCount = pns.numberOfChannels
        guard channelCount > 0, !pns.data.isEmpty else {
            throw MFFWriterError.emptySignal
        }
        let sampleCount = pns.data[0].count
        guard sampleCount > 0, pns.data.allSatisfy({ $0.count == sampleCount }) else {
            throw MFFWriterError.inconsistentChannelLengths
        }

        var data = Data()
        let blockSize = channelCount * sampleCount * MemoryLayout<Float>.size
        let headerSize = 20 + channelCount * 8
        appendInt32(1, to: &data)
        appendInt32(headerSize, to: &data)
        appendInt32(blockSize, to: &data)
        appendInt32(channelCount, to: &data)

        for channel in 0..<channelCount {
            appendInt32(channel * sampleCount * MemoryLayout<Float>.size, to: &data)
        }

        let rateDepth = (sampleRate << 8) + 32
        for _ in 0..<channelCount {
            appendInt32(rateDepth, to: &data)
        }

        appendInt32(0, to: &data)

        for channel in 0..<channelCount {
            for sample in 0..<sampleCount {
                appendFloat32(pns.data[channel][sample], to: &data)
            }
        }

        try data.write(to: packageURL.appendingPathComponent("signal2.bin"), options: .atomic)
    }

    private static func writePNSInfoXML(pns: MFFSignalData, to packageURL: URL) throws {
        // Strip calibrations just like writeSignalInfoXML — EVA stores calibrated
        // physical values, so carrying GCAL/ICAL would double-scale on re-import.
        if let original = originalPNSInfoData(sourceSignalURL: pns.signalURL) {
            let destination = packageURL.appendingPathComponent("info2.xml")
            try? FileManager.default.removeItem(at: destination)
            try original.write(to: destination, options: .atomic)
            return
        }

        let xml = """
<?xml version="1.0" encoding="UTF-8"?>
<dataInfo>
  <generalInformation>
    <fileDataType>
      <PNSData/>
    </fileDataType>
  </generalInformation>
</dataInfo>
"""
        try xml.write(to: packageURL.appendingPathComponent("info2.xml"), atomically: true, encoding: .utf8)
    }

    /// Copies and strips calibrations from the source info2.xml when the PNS
    /// signal came from an existing MFF file (round-trip). Returns nil for
    /// synthetic-only signals whose signalURL points at the package root.
    private static func originalPNSInfoData(sourceSignalURL: URL) -> Data? {
        let infoURL = sourceSignalURL.deletingLastPathComponent().appendingPathComponent("info2.xml")
        guard FileManager.default.fileExists(atPath: infoURL.path),
              let data = try? Data(contentsOf: infoURL),
              let document = try? XMLDocument(data: data, options: [.documentTidyXML]),
              let root = document.rootElement() else { return nil }
        removeDescendants(named: "calibrations", from: root)
        return try? document.xmlData(options: [.nodePrettyPrint])
    }

    private static func writePNSSetXML(pns: MFFSignalData, to packageURL: URL) throws {
        let names = pns.channelNames
        var body = ""
        for index in 0..<pns.numberOfChannels {
            let name = (names != nil && index < names!.count) ? names![index] : "PNS \(index + 1)"
            body += """
  <sensor>
    <number>\(index)</number>
    <name>\(xmlEscape(name))</name>
    <type>PNS</type>
  </sensor>
"""
        }
        let xml = """
<?xml version="1.0" encoding="UTF-8"?>
<PNSSet xmlns="http://www.egi.com/pns_mff">
\(body)</PNSSet>
"""
        try xml.write(to: packageURL.appendingPathComponent("pnsSet.xml"), atomically: true, encoding: .utf8)
    }

    private static func normalizedMFFURL(_ url: URL) -> URL {
        url.pathExtension.lowercased() == "mff" ? url : url.appendingPathExtension("mff")
    }

    private static func integerSamplingRate(_ rate: Double) throws -> Int {
        guard rate.isFinite, rate > 0 else {
            throw MFFWriterError.invalidSamplingRate(rate)
        }
        let rounded = rate.rounded()
        guard abs(rounded - rate) < 0.0001, rounded < Double(1 << 24) else {
            throw MFFWriterError.invalidSamplingRate(rate)
        }
        return Int(rounded)
    }

    private static func validate(signal: MFFSignalData) throws -> Int {
        guard signal.numberOfChannels > 0,
              signal.data.count == signal.numberOfChannels,
              let first = signal.data.first,
              !first.isEmpty else {
            throw MFFWriterError.emptySignal
        }
        let count = first.count
        guard signal.data.allSatisfy({ $0.count == count }) else {
            throw MFFWriterError.inconsistentChannelLengths
        }
        return count
    }

    private static func exportBlocks(
        for signal: MFFSignalData,
        sampleCount: Int,
        segments: [EpochSegment],
        kind: MFFExportKind
    ) throws -> [ExportBlock] {
        guard kind != .continuous, !segments.isEmpty else {
            return [
                ExportBlock(
                    startSample: 0,
                    endSample: sampleCount - 1,
                    stimulusOffsetSamples: nil,
                    category: "Continuous",
                    sourceCode: "Continuous",
                    sourceTimeSeconds: 0,
                    contributingEpochCount: 1
                )
            ]
        }

        return try segments.sorted { $0.startSample < $1.startSample }.map { segment in
            guard segment.startSample >= 0,
                  segment.endSample >= segment.startSample,
                  segment.endSample < sampleCount else {
                throw MFFWriterError.invalidSegment(segment)
            }
            return ExportBlock(
                startSample: segment.startSample,
                endSample: segment.endSample,
                stimulusOffsetSamples: segment.stimulusOffsetSamples,
                category: segment.category,
                sourceCode: segment.sourceCode,
                sourceTimeSeconds: segment.sourceTimeSeconds,
                contributingEpochCount: segment.contributingEpochCount
            )
        }
    }

    private static func writeInfoXML(
        signal: MFFSignalData,
        kind: MFFExportKind,
        to packageURL: URL,
        preserveSourceFileInfo: Bool
    ) throws {
        // Carry over the original info.xml verbatim when the source is an MFF
        // package — it holds the real recordTime, amplifier type/serial/firmware,
        // and acquisition version. Only synthesize when there is no source
        // info.xml (e.g. exporting data imported from a non-MFF format).
        if preserveSourceFileInfo,
           copyOriginalFileIfPresent(named: "info.xml", sourceSignalURL: signal.signalURL, to: packageURL) {
            return
        }

        let recordTime = mffDateString(signal.recordingStartTime ?? Date())
        let xml = """
<?xml version="1.0" encoding="UTF-8"?>
<fileInfo>
  <recordTime>\(xmlEscape(recordTime))</recordTime>
  <mffVersion>3</mffVersion>
  <acquisitionVersion>EVA MFF export</acquisitionVersion>
  <appName>EVA</appName>
  <exportKind>\(xmlEscape(kind.statusName))</exportKind>
</fileInfo>
"""
        try xml.write(to: packageURL.appendingPathComponent("info.xml"), atomically: true, encoding: .utf8)
    }

    private static func writeSignalInfoXML(signal: MFFSignalData, to packageURL: URL) throws {
        // Reuse the selected source infoN.xml when available, but strip
        // calibration metadata. EVA stores calibrated physical samples after
        // import, so carrying GCAL/ICAL into the export would make readers such
        // as MNE or mffpy scale the data a second time.
        if writeOriginalSignalInfoWithoutCalibrationsIfPresent(signal: signal, to: packageURL) {
            return
        }

        let xml = """
<?xml version="1.0" encoding="UTF-8"?>
<dataInfo>
  <generalInformation>
    <fileDataType>
      <EEG/>
    </fileDataType>
  </generalInformation>
</dataInfo>
"""
        try xml.write(to: packageURL.appendingPathComponent("info1.xml"), atomically: true, encoding: .utf8)
    }

    /// Synthesizes a minimal EGI subject.xml, seeding the Patient ID from the
    /// export's package name. EGI's subject.xml is a flat list of named fields;
    /// we populate Patient ID and leave the rest blank.
    private static func writeSubjectXML(packageURL: URL) throws {
        let patientID = packageURL.deletingPathExtension().lastPathComponent
        let fieldNames = [
            "Last (Family) Name", "First (Given) Name", "Date of Birth", "Age",
            "Gender", "Handedness", "Session Number", "Comments"
        ]
        var fields = """
    <field>
      <name>Patient ID</name>
      <data dataType="string">\(xmlEscape(patientID))</data>
      <choices></choices>
    </field>
"""
        for name in fieldNames {
            fields += """
    <field>
      <name>\(xmlEscape(name))</name>
      <data dataType="string"></data>
      <choices></choices>
    </field>
"""
        }
        let xml = """
<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>
<patient xmlns="http://www.egi.com/subject_mff" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <fields>
\(fields)  </fields>
</patient>
"""
        try xml.write(to: packageURL.appendingPathComponent("subject.xml"), atomically: true, encoding: .utf8)
    }

    private static func writeSignalBinary(
        blocks: [ExportBlock],
        channelCount: Int,
        sampleRate: Int,
        to packageURL: URL
    ) throws {
        var data = Data()
        for block in blocks {
            let sampleCount = block.sampleCount
            let blockSize = channelCount * sampleCount * MemoryLayout<Float>.size
            let headerSize = 20 + channelCount * 8
            appendInt32(1, to: &data)
            appendInt32(headerSize, to: &data)
            appendInt32(blockSize, to: &data)
            appendInt32(channelCount, to: &data)

            for channel in 0..<channelCount {
                appendInt32(channel * sampleCount * MemoryLayout<Float>.size, to: &data)
            }

            let rateDepth = (sampleRate << 8) + 32
            for _ in 0..<channelCount {
                appendInt32(rateDepth, to: &data)
            }

            appendInt32(0, to: &data)

            for channel in 0..<channelCount {
                for sample in block.startSample...block.endSample {
                    appendFloat32(block.signalData[channel][sample], to: &data)
                }
            }
        }

        try data.write(to: packageURL.appendingPathComponent("signal1.bin"), options: .atomic)
    }

    private static func writeEpochsXML(blocks: [ExportBlock], sampleRate: Int, to packageURL: URL) throws {
        var body = ""
        var cursorMicroseconds = 0
        for (index, block) in blocks.enumerated() {
            let duration = Int((Double(block.sampleCount) / Double(sampleRate) * 1_000_000).rounded())
            let begin = cursorMicroseconds
            let end = begin + duration
            body += """
  <epoch>
    <beginTime>\(begin)</beginTime>
    <endTime>\(end)</endTime>
    <firstBlock>\(index + 1)</firstBlock>
    <lastBlock>\(index + 1)</lastBlock>
  </epoch>
"""
            cursorMicroseconds = end
        }
        let xml = """
<?xml version="1.0" encoding="UTF-8"?>
<epochs>
\(body)</epochs>
"""
        try xml.write(to: packageURL.appendingPathComponent("epochs.xml"), atomically: true, encoding: .utf8)
    }

    private static func writeEventsXML(
        signal: MFFSignalData,
        blocks: [ExportBlock],
        sampleRate: Int,
        kind: MFFExportKind,
        to packageURL: URL
    ) throws {
        let events = exportEvents(signal: signal, blocks: blocks, sampleRate: sampleRate, kind: kind)
        // EGI MFF event <beginTime> is an ABSOLUTE ISO-8601 datetime (same format
        // as info.xml recordTime), not an offset in seconds. MNE parses it as a
        // datetime and computes the sample as round((beginTime - recordTime) *
        // sfreq), so a bare float like "12.500000" breaks the reader. Anchor each
        // event's relative offset to the recording start. (EVA's own reader still
        // accepts both forms — see resolveEventBeginTimeSeconds.)
        let recordStart = signal.recordingStartTime ?? Date()
        var body = ""
        for event in events {
            let beginTime = mffDateString(recordStart.addingTimeInterval(event.beginTimeSeconds))
            body += """
  <event>
    <beginTime>\(xmlEscape(beginTime))</beginTime>
    <duration>0</duration>
    <code>\(xmlEscape(event.code))</code>
    <description>\(xmlEscape(event.description))</description>
  </event>
"""
        }
        let xml = """
<?xml version="1.0" encoding="UTF-8"?>
<eventTrack>
  <name>EVA Export</name>
\(body)</eventTrack>
"""
        try xml.write(to: packageURL.appendingPathComponent("Events_EVA.xml"), atomically: true, encoding: .utf8)
    }

    private static func writeSensorLayoutXML(signal: MFFSignalData, to packageURL: URL) throws {
        let destination = packageURL.appendingPathComponent("sensorLayout.xml")

        // Preferred: re-emit the ORIGINAL sensorLayout.xml verbatim so the real
        // electrode positions, device name and sensor numbering survive a
        // read → process → write round-trip. `signalURL` still points at the
        // source signal even after filtering/averaging (all current processing
        // preserves the channel count), so the original montage still matches.
        // We only reuse it when its EEG (type 0/1) sensor count equals the
        // exported channel count, to avoid emitting a mismatched layout.
        if let original = originalMontageData(
            named: "sensorLayout.xml",
            requiringChannelCount: signal.numberOfChannels,
            sourceSignalURL: signal.signalURL
        ) {
            try original.write(to: destination, options: .atomic)
            return
        }

        // Fallback: synthesize a minimal layout. MNE requires the file and a
        // type-0 <sensor> per channel (mne/io/egi/egimff.py:_read_mff_header),
        // counted against the signal's channel count. Use channel names when
        // available, otherwise generic E{n}.
        let names = signal.channelNames
        var body = ""
        for index in 0..<signal.numberOfChannels {
            let name = (names != nil && index < names!.count) ? names![index] : "E\(index + 1)"
            body += """
  <sensor>
    <number>\(index + 1)</number>
    <name>\(xmlEscape(name))</name>
    <type>0</type>
  </sensor>
"""
        }
        let xml = """
<?xml version="1.0" encoding="UTF-8"?>
<sensorLayout>
  <name>EVA Export</name>
\(body)</sensorLayout>
"""
        try xml.write(to: destination, atomically: true, encoding: .utf8)
    }

    /// Copies a sidecar file verbatim from the source MFF package into the
    /// export when it exists, so original metadata such as info.xml and
    /// coordinates.xml survives a read → process → write round-trip. The
    /// `signalURL` still points at the source package after processing. Returns
    /// whether a file was copied; best-effort (silently skips when absent).
    @discardableResult
    private static func copyOriginalFileIfPresent(
        named fileName: String,
        sourceSignalURL: URL,
        to packageURL: URL
    ) -> Bool {
        let source = sourceSignalURL.deletingLastPathComponent().appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        let destination = packageURL.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private static func writeOriginalSignalInfoWithoutCalibrationsIfPresent(
        signal: MFFSignalData,
        to packageURL: URL
    ) -> Bool {
        let sourceFileName = sourceSignalInfoFileName(for: signal.signalURL)
        let source = signal.signalURL.deletingLastPathComponent().appendingPathComponent(sourceFileName)
        guard FileManager.default.fileExists(atPath: source.path) else { return false }

        let destination = packageURL.appendingPathComponent("info1.xml")
        do {
            let data = try Data(contentsOf: source)
            let document = try XMLDocument(data: data, options: [.documentTidyXML])
            if let root = document.rootElement() {
                // Strip only the gain calibration (GCAL): EVA stores calibrated
                // physical samples, so re-importing with GCAL would double-scale.
                // Keep ICAL — it is electrode-impedance metadata, not a scale
                // factor, and downstream tooling (and EVA itself) reads it back.
                removeCalibrations(ofType: "GCAL", from: root)
            }
            try? FileManager.default.removeItem(at: destination)
            try document.xmlData(options: [.nodePrettyPrint]).write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func sourceSignalInfoFileName(for signalURL: URL) -> String {
        let signalName = signalURL.deletingPathExtension().lastPathComponent
        let signalNumber = signalName.replacingOccurrences(of: "signal", with: "")
        return signalNumber.isEmpty ? "info1.xml" : "info\(signalNumber).xml"
    }

    @discardableResult
    private static func removeDescendants(named name: String, from element: XMLElement) -> Bool {
        var removed = false
        for (index, child) in (element.children ?? []).enumerated().reversed() {
            guard let childElement = child as? XMLElement else { continue }
            if localName(childElement.name) == name {
                element.removeChild(at: index)
                removed = true
            } else if removeDescendants(named: name, from: childElement) {
                removed = true
            }
        }
        return removed
    }

    /// Removes only `<calibration>` elements whose `<type>` matches `type`
    /// (e.g. "GCAL"), leaving any other calibration (e.g. "ICAL" impedance) in
    /// place. If a `<calibrations>` container is left empty it is removed too.
    private static func removeCalibrations(ofType type: String, from element: XMLElement) {
        for (containerIndex, child) in (element.children ?? []).enumerated().reversed() {
            guard let childElement = child as? XMLElement else { continue }
            if localName(childElement.name) == "calibrations" {
                for (index, cal) in (childElement.children ?? []).enumerated().reversed() {
                    guard let calElement = cal as? XMLElement,
                          localName(calElement.name) == "calibration" else { continue }
                    let calType = (calElement.children?.compactMap { $0 as? XMLElement } ?? [])
                        .first { localName($0.name) == "type" }?
                        .stringValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if calType?.caseInsensitiveCompare(type) == .orderedSame {
                        childElement.removeChild(at: index)
                    }
                }
                // Drop an emptied <calibrations> container.
                if (childElement.children?.compactMap { $0 as? XMLElement } ?? []).isEmpty {
                    element.removeChild(at: containerIndex)
                }
            } else {
                removeCalibrations(ofType: type, from: childElement)
            }
        }
    }

    /// Returns the raw bytes of a montage file from the source package only when
    /// its EEG (type 0/1) sensor count matches `requiringChannelCount`.
    private static func originalMontageData(
        named fileName: String,
        requiringChannelCount channelCount: Int,
        sourceSignalURL: URL
    ) -> Data? {
        let url = sourceSignalURL.deletingLastPathComponent().appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let document = try? XMLDocument(data: data),
              let root = document.rootElement(),
              eegSensorCount(in: root) == channelCount else {
            return nil
        }
        return data
    }

    /// Counts <sensor> elements whose <type> is 0 or 1 (EEG / reference), the
    /// same set MNE treats as data channels. Namespace-agnostic.
    private static func eegSensorCount(in root: XMLElement) -> Int {
        var count = 0
        func walk(_ element: XMLElement) {
            if localName(element.name) == "sensor" {
                let type = (element.children?.compactMap { $0 as? XMLElement } ?? [])
                    .first { localName($0.name) == "type" }?
                    .stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = type.flatMap(Int.init), value == 0 || value == 1 {
                    count += 1
                }
            }
            for case let child as XMLElement in element.children ?? [] {
                walk(child)
            }
        }
        walk(root)
        return count
    }

    private static func localName(_ name: String?) -> String {
        (name ?? "").components(separatedBy: ":").last ?? ""
    }

    private static func exportEvents(
        signal: MFFSignalData,
        blocks: [ExportBlock],
        sampleRate: Int,
        kind: MFFExportKind
    ) -> [ExportEvent] {
        if kind == .continuous {
            return signal.events.map {
                ExportEvent(code: $0.code, beginTimeSeconds: $0.beginTimeSeconds, description: $0.sourceFile)
            }
        }

        var cursor = 0
        var output: [ExportEvent] = []
        for block in blocks {
            let eventSample = cursor + (block.stimulusOffsetSamples ?? 0)
            let eventTime = Double(eventSample) / Double(sampleRate)
            let description: String
            if kind == .averaged {
                description = "\(block.contributingEpochCount) contributing epochs"
            } else {
                description = "Source \(block.sourceCode) at \(String(format: "%.6f", block.sourceTimeSeconds)) s"
            }
            output.append(ExportEvent(code: block.category, beginTimeSeconds: eventTime, description: description))
            cursor += block.sampleCount
        }
        return output
    }

    private static func appendInt32(_ value: Int, to data: inout Data) {
        var little = Int32(value).littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func appendFloat32(_ value: Float, to data: inout Data) {
        var little = value.bitPattern.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func mffDateString(_ date: Date) -> String {
        // EGI MFF `recordTime` must use microsecond (6-digit) fractional seconds
        // and a NUMERIC timezone offset. ISO8601DateFormatter only emits 3-digit
        // milliseconds and a "Z" suffix for UTC, which fails strict readers —
        // notably MNE's regex (mne/io/egi/egimff.py) requires
        //   \.\d{6}(?:\d{3})?[+-]\d{2}:\d{2}
        // so ".129Z" is rejected. Use a fixed POSIX formatter with 6 fractional
        // digits and the "xxx" offset token (always numeric, e.g. +00:00/-04:00).
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxx"
        return formatter.string(from: date)
    }
}

private nonisolated struct ExportBlock: Sendable {
    let startSample: Int
    let endSample: Int
    let stimulusOffsetSamples: Int?
    let category: String
    let sourceCode: String
    let sourceTimeSeconds: Double
    let contributingEpochCount: Int
    var signalData: [[Float]] = []

    var sampleCount: Int {
        endSample - startSample + 1
    }

    func withSignalData(_ data: [[Float]]) -> ExportBlock {
        var copy = self
        copy.signalData = data
        return copy
    }
}

private nonisolated struct ExportEvent: Sendable {
    let code: String
    let beginTimeSeconds: Double
    let description: String
}
