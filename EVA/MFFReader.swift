//
//  MFFReader.swift
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

import Foundation

nonisolated struct MFFPackage: Sendable {
    let sourceURL: URL
    let xmlFiles: [String]
    let binFiles: [String]
    let selectedXMLFile: String
    let metrics: [String: String]
}

nonisolated struct MFFAntiAliasTimingCorrection: Sendable, Equatable {
    enum Evidence: Hashable, Sendable {
        case acquisitionVersion
        case hardwareFilterAdjusted
    }

    let shiftMicroseconds: Int?
    let acquisitionVersion: String?
    let evidence: Set<Evidence>

    var loadingMessage: String {
        "Corrected for anti-alias timing bug at recording"
    }
}

nonisolated struct MFFSignalData: Sendable {
    let signalURL: URL
    let signalType: String
    let numberOfChannels: Int
    let samplingRate: Double
    let duration: TimeInterval
    let recordingStartTime: Date?
    let events: [MFFEvent]
    let data: [[Float]]
    let channelNames: [String]?
    /// Pre-segmented epochs declared on disk (`epochs.xml` + `categories.xml`),
    /// e.g. when the file was segmented or category-averaged by other software.
    /// Empty for ordinary continuous recordings.
    let epochSegments: [EpochSegment]
    /// True when the file is segmented into discrete epochs on disk.
    let isSegmented: Bool
    /// True when each epoch is a category *average* (one segment per category,
    /// each built from multiple trials), i.e. an ERP/averaged file.
    let isAveraged: Bool

    init(
        signalURL: URL,
        signalType: String,
        numberOfChannels: Int,
        samplingRate: Double,
        duration: TimeInterval,
        recordingStartTime: Date?,
        events: [MFFEvent],
        data: [[Float]],
        channelNames: [String]? = nil,
        epochSegments: [EpochSegment] = [],
        isSegmented: Bool = false,
        isAveraged: Bool = false
    ) {
        self.signalURL = signalURL
        self.signalType = signalType
        self.numberOfChannels = numberOfChannels
        self.samplingRate = samplingRate
        self.duration = duration
        self.recordingStartTime = recordingStartTime
        self.events = events
        self.data = data
        self.channelNames = channelNames
        self.epochSegments = epochSegments
        self.isSegmented = isSegmented
        self.isAveraged = isAveraged
    }

    /// Returns a copy with the sample data replaced, preserving all metadata.
    /// Optionally annotates the signal type to record the transform applied.
    func replacingData(_ newData: [[Float]], signalTypeSuffix: String? = nil) -> MFFSignalData {
        MFFSignalData(
            signalURL: signalURL,
            signalType: signalTypeSuffix.map { "\(signalType) \($0)" } ?? signalType,
            numberOfChannels: numberOfChannels,
            samplingRate: samplingRate,
            duration: duration,
            recordingStartTime: recordingStartTime,
            events: events,
            data: newData,
            channelNames: channelNames,
            epochSegments: epochSegments,
            isSegmented: isSegmented,
            isAveraged: isAveraged
        )
    }
}

nonisolated struct MFFEvent: Identifiable, Hashable, Sendable {
    let id: String
    let code: String
    let label: String?
    let eventDescription: String?
    let cell: String?
    let beginTimeSeconds: Double
    let rawBeginTime: String
    let sourceFile: String

    init(
        id: String,
        code: String,
        label: String? = nil,
        eventDescription: String? = nil,
        cell: String? = nil,
        beginTimeSeconds: Double,
        rawBeginTime: String,
        sourceFile: String
    ) {
        self.id = id
        self.code = code
        self.label = Self.nonEmpty(label)
        self.eventDescription = Self.nonEmpty(eventDescription)
        self.cell = Self.nonEmpty(cell)
        self.beginTimeSeconds = beginTimeSeconds
        self.rawBeginTime = rawBeginTime
        self.sourceFile = sourceFile
    }

    private static func nonEmpty(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? value?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
    }
}

enum MFFReaderError: LocalizedError {
    case invalidContainer
    case missingSignalFiles
    case missingXMLFiles
    case missingXMLFile(URL)
    case missingSignalFile(URL)
    case invalidXML(URL, String)
    case invalidBinaryData(URL, String)
    case unsupportedSampleDepth(Int)
    case inconsistentBlockConfiguration
    case emptySignal

    var errorDescription: String? {
        switch self {
        case .invalidContainer:
            return "The selected item is not a readable MFF package."
        case .missingSignalFiles:
            return "The MFF package does not contain any signal*.bin files."
        case .missingXMLFiles:
            return "The MFF package does not contain any .xml files."
        case .missingXMLFile(let url):
            return "The MFF package does not contain \(url.lastPathComponent)."
        case .missingSignalFile(let url):
            return "The MFF package does not contain \(url.lastPathComponent)."
        case .invalidXML(let url, let details):
            return "Unable to parse \(url.lastPathComponent): \(details)"
        case .invalidBinaryData(let url, let details):
            return "Unable to parse binary signal data in \(url.lastPathComponent): \(details)"
        case .unsupportedSampleDepth(let depth):
            return "Unsupported sample depth \(depth). Only 32-bit float samples are supported."
        case .inconsistentBlockConfiguration:
            return "The MFF signal blocks have inconsistent channel counts or sample rates."
        case .emptySignal:
            return "The MFF signal did not contain any samples."
        }
    }
}

nonisolated final class MFFReader {
    func inspectPackage(at url: URL, selectedXMLFile: String? = nil) throws -> MFFPackage {
        let packageURL = try validatedPackageURL(from: url)
        let xmlFiles = try self.xmlFiles(in: packageURL)
        let binFiles = try self.binFiles(in: packageURL)
        let xmlFile = selectedXMLFile ?? preferredXMLFile(from: xmlFiles)
        let metrics = try parseXMLMetrics(in: packageURL, fileName: xmlFile)

        return MFFPackage(
            sourceURL: packageURL,
            xmlFiles: xmlFiles,
            binFiles: binFiles,
            selectedXMLFile: xmlFile,
            metrics: metrics
        )
    }

    func loadSignal(
        from packageURL: URL,
        signalFileName: String? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> MFFSignalData {
        let packageURL = try validatedPackageURL(from: packageURL)
        progress?(0.01)
        let signalDescriptor = try selectSignal(in: packageURL, preferredSignalFile: signalFileName)
        let signalData = try parseSignal(from: signalDescriptor.signalURL) { fraction in
            progress?(0.02 + 0.78 * fraction)
        }

        guard signalData.numberOfChannels > 0, signalData.totalSamples > 0 else {
            throw MFFReaderError.emptySignal
        }

        progress?(0.82)
        var samples = signalData.samples
        if let gcal = try parseCalibrationFactors(
            named: "GCAL",
            in: packageURL,
            infoFileName: signalDescriptor.infoFileName,
            expectedCount: signalData.numberOfChannels
        ) {
            applyCalibrationFactors(gcal, to: &samples)
        }

        progress?(0.88)
        let recordingStartTime = try parseRecordingStartTime(in: packageURL)
        progress?(0.90)
        let events = try parseEvents(in: packageURL)
        progress?(0.96)
        let channelNames = try parseChannelNames(in: packageURL, expectedCount: signalData.numberOfChannels)

        // Detect on-disk segmentation/averaging (epochs.xml + categories.xml).
        // When present, the concatenated blocks are discrete epochs rather than
        // one continuous recording, and the raw event tracks are in the original
        // recording's timeline — useless against the re-segmented data. We replace
        // them with one stimulus-locked marker per epoch.
        let epochInfo = (try? parseOnDiskEpochs(
            in: packageURL,
            blockSampleCounts: signalData.blockSampleCounts,
            samplingRate: signalData.samplingRate
        )) ?? nil
        progress?(1)

        let resolvedEvents = epochInfo.map(\.events) ?? events

        return MFFSignalData(
            signalURL: signalDescriptor.signalURL,
            signalType: signalDescriptor.signalType,
            numberOfChannels: signalData.numberOfChannels,
            samplingRate: signalData.samplingRate,
            duration: Double(signalData.totalSamples) / signalData.samplingRate,
            recordingStartTime: recordingStartTime,
            events: resolvedEvents,
            data: samples,
            channelNames: channelNames,
            epochSegments: epochInfo?.segments ?? [],
            isSegmented: epochInfo != nil,
            isAveraged: epochInfo?.isAveraged ?? false
        )
    }

    func antiAliasTimingCorrection(
        in packageURL: URL,
        signalFileName: String? = nil
    ) throws -> MFFAntiAliasTimingCorrection? {
        let packageURL = try validatedPackageURL(from: packageURL)
        let signalDescriptor = try selectSignal(in: packageURL, preferredSignalFile: signalFileName)
        let acquisitionVersion = try parseAcquisitionVersion(in: packageURL)
        let hardwareAdjustment = try parseHardwareFilterAdjustment(
            in: packageURL,
            infoFileName: signalDescriptor.infoFileName
        )

        var evidence = Set<MFFAntiAliasTimingCorrection.Evidence>()
        if let acquisitionVersion, acquisitionVersionIndicatesAntiAliasCorrection(acquisitionVersion) {
            evidence.insert(.acquisitionVersion)
        }
        if hardwareAdjustment.isAdjusted {
            evidence.insert(.hardwareFilterAdjusted)
        }

        guard !evidence.isEmpty else {
            return nil
        }

        return MFFAntiAliasTimingCorrection(
            shiftMicroseconds: hardwareAdjustment.isAdjusted ? hardwareAdjustment.shiftMicroseconds : nil,
            acquisitionVersion: acquisitionVersion,
            evidence: evidence
        )
    }

    func xmlFiles(in url: URL) throws -> [String] {
        let contents = try packageContents(in: url)
        let xmlFiles = contents
            .filter { $0.pathExtension.lowercased() == "xml" }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        guard !xmlFiles.isEmpty else {
            throw MFFReaderError.missingXMLFiles
        }

        return xmlFiles
    }

    func parseXMLMetrics(in url: URL, fileName: String) throws -> [String: String] {
        let packageURL = try validatedPackageURL(from: url)
        let xmlURL = packageURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: xmlURL.path) else {
            throw MFFReaderError.missingXMLFile(xmlURL)
        }

        let document = try loadXMLDocument(at: xmlURL)
        guard let root = document.rootElement() else {
            throw MFFReaderError.invalidXML(xmlURL, "missing XML root element")
        }

        var metrics: [String: String] = [:]
        collectMetrics(from: root, path: sanitizedTagName(root.name), into: &metrics)
        metrics["rootTag"] = sanitizedTagName(root.name)
        metrics["fileName"] = fileName
        return metrics
    }

    func binFiles(in url: URL) throws -> [String] {
        let contents = try packageContents(in: url)
        let binFiles = contents
            .filter { $0.pathExtension.lowercased() == "bin" && $0.lastPathComponent.hasPrefix("signal") }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        guard !binFiles.isEmpty else {
            throw MFFReaderError.missingSignalFiles
        }

        return binFiles
    }

    private func preferredXMLFile(from xmlFiles: [String]) -> String {
        if let infoXML = xmlFiles.first(where: { $0.caseInsensitiveCompare("info.xml") == .orderedSame }) {
            return infoXML
        }
        return xmlFiles[0]
    }

    private func validatedPackageURL(from url: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MFFReaderError.invalidContainer
        }
        return url
    }

    private func packageContents(in url: URL) throws -> [URL] {
        let packageURL = try validatedPackageURL(from: url)
        return try FileManager.default.contentsOfDirectory(
            at: packageURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    private func collectMetrics(from element: XMLElement, path: String, into metrics: inout [String: String]) {
        let trimmedValue = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let childElements = (element.children ?? []).compactMap { $0 as? XMLElement }

        for attribute in element.attributes ?? [] {
            metrics["\(path).@\(attribute.name ?? "attribute")"] = attribute.stringValue ?? ""
        }

        if childElements.isEmpty, !trimmedValue.isEmpty {
            metrics[path] = trimmedValue
            return
        }

        var siblingOccurrences: [String: Int] = [:]
        let siblingTotals = Dictionary(grouping: childElements, by: { sanitizedTagName($0.name) }).mapValues(\.count)

        for child in childElements {
            let childName = sanitizedTagName(child.name)
            let siblingIndex = siblingOccurrences[childName, default: 0]
            siblingOccurrences[childName] = siblingIndex + 1
            let childPath = (siblingTotals[childName] ?? 0) > 1
                ? "\(path).\(childName)[\(siblingIndex)]"
                : "\(path).\(childName)"
            collectMetrics(from: child, path: childPath, into: &metrics)
        }
    }

    private func selectSignal(
        in packageURL: URL,
        preferredSignalFile: String?
    ) throws -> (signalURL: URL, infoFileName: String, signalType: String) {
        let signalFiles = try binFiles(in: packageURL)

        if let preferredSignalFile {
            let signalURL = packageURL.appendingPathComponent(preferredSignalFile)
            guard FileManager.default.fileExists(atPath: signalURL.path) else {
                throw MFFReaderError.missingSignalFile(signalURL)
            }
            let signalType = try parseSignalType(for: signalURL, in: packageURL) ?? "Unknown"
            return (signalURL, signalInfoFileName(for: signalURL), signalType)
        }

        let descriptors = try signalFiles.map { fileName in
            let signalURL = packageURL.appendingPathComponent(fileName)
            let signalType = try parseSignalType(for: signalURL, in: packageURL) ?? "Unknown"
            return (
                signalURL: signalURL,
                infoFileName: signalInfoFileName(for: signalURL),
                signalType: signalType
            )
        }

        if let eegSignal = descriptors.first(where: { $0.signalType.caseInsensitiveCompare("EEG") == .orderedSame }) {
            return eegSignal
        }

        guard let firstSignal = descriptors.first else {
            throw MFFReaderError.missingSignalFiles
        }
        return firstSignal
    }

    private func parseSignalType(for signalURL: URL, in packageURL: URL) throws -> String? {
        let infoURL = packageURL.appendingPathComponent(signalInfoFileName(for: signalURL))
        guard FileManager.default.fileExists(atPath: infoURL.path) else {
            return nil
        }

        let document = try loadXMLDocument(at: infoURL)
        guard let root = document.rootElement() else {
            throw MFFReaderError.invalidXML(infoURL, "missing XML root element")
        }

        if let generalInformation = firstDescendant(named: "generalInformation", in: root),
           let fileDataType = firstDescendant(named: "fileDataType", in: generalInformation),
           let channelElement = fileDataType.children?.compactMap({ $0 as? XMLElement }).first {
            let signalType = sanitizedTagName(channelElement.name)
            return signalType.isEmpty ? nil : signalType
        }

        return nil
    }

    private func signalInfoFileName(for signalURL: URL) -> String {
        let signalName = signalURL.deletingPathExtension().lastPathComponent
        let signalNumber = signalName.replacingOccurrences(of: "signal", with: "")
        return "info\(signalNumber).xml"
    }

    private func parseCalibrationFactors(
        named calibrationType: String,
        in packageURL: URL,
        infoFileName: String,
        expectedCount: Int
    ) throws -> [Float]? {
        guard expectedCount > 0 else { return nil }

        let infoURL = packageURL.appendingPathComponent(infoFileName)
        guard FileManager.default.fileExists(atPath: infoURL.path) else {
            return nil
        }

        let document = try loadXMLDocument(at: infoURL)
        guard let root = document.rootElement() else {
            throw MFFReaderError.invalidXML(infoURL, "missing XML root element")
        }

        for calibration in descendants(named: "calibration", in: root) {
            let children = (calibration.children ?? []).compactMap { $0 as? XMLElement }
            let type = children
                .first(where: { sanitizedTagName($0.name) == "type" })?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard type?.caseInsensitiveCompare(calibrationType) == .orderedSame else {
                continue
            }

            if let rawBeginTime = children
                .first(where: { sanitizedTagName($0.name) == "beginTime" })?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let beginTime = Double(rawBeginTime),
               abs(beginTime) > 0.000001 {
                continue
            }

            let channelElements = descendants(named: "ch", in: calibration)
            guard !channelElements.isEmpty else {
                continue
            }

            var factors = Array(repeating: Float(1), count: expectedCount)
            var sequentialChannelNumber = 1
            var appliedAnyFactor = false

            for channelElement in channelElements {
                defer { sequentialChannelNumber += 1 }

                guard let rawValue = channelElement.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let value = Float(rawValue),
                      value.isFinite else {
                    continue
                }

                let channelNumber = calibrationChannelNumber(from: channelElement) ?? sequentialChannelNumber
                guard (1...expectedCount).contains(channelNumber) else {
                    continue
                }

                factors[channelNumber - 1] = value
                appliedAnyFactor = true
            }

            if appliedAnyFactor {
                return factors
            }
        }

        return nil
    }

    private func calibrationChannelNumber(from element: XMLElement) -> Int? {
        for attribute in element.attributes ?? [] {
            let name = sanitizedTagName(attribute.name).lowercased()
            guard name == "n" || name == "number" || name == "channel",
                  let rawValue = attribute.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let number = Int(rawValue) else {
                continue
            }
            return number
        }
        return nil
    }

    private func applyCalibrationFactors(_ factors: [Float], to samples: inout [[Float]]) {
        let channelCount = min(samples.count, factors.count)
        guard channelCount > 0 else { return }

        for channel in 0..<channelCount {
            let factor = factors[channel]
            guard factor.isFinite, factor != 1 else { continue }
            for sample in samples[channel].indices {
                samples[channel][sample] *= factor
            }
        }
    }

    private func parseRecordingStartTime(in packageURL: URL) throws -> Date? {
        let infoURL = packageURL.appendingPathComponent("info.xml")
        guard FileManager.default.fileExists(atPath: infoURL.path) else {
            return nil
        }

        let document = try loadXMLDocument(at: infoURL)
        guard let root = document.rootElement(),
              let recordTimeElement = firstDescendant(named: "recordTime", in: root),
              let rawValue = recordTimeElement.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        return parseMFFDate(rawValue)
    }

    private func parseAcquisitionVersion(in packageURL: URL) throws -> String? {
        let infoURL = packageURL.appendingPathComponent("info.xml")
        guard FileManager.default.fileExists(atPath: infoURL.path) else {
            return nil
        }

        let document = try loadXMLDocument(at: infoURL)
        guard let root = document.rootElement(),
              let acquisitionVersionElement = firstDescendant(named: "acquisitionVersion", in: root),
              let rawValue = acquisitionVersionElement.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        return rawValue
    }

    private func parseHardwareFilterAdjustment(
        in packageURL: URL,
        infoFileName: String
    ) throws -> (isAdjusted: Bool, shiftMicroseconds: Int?) {
        let infoURL = packageURL.appendingPathComponent(infoFileName)
        guard FileManager.default.fileExists(atPath: infoURL.path) else {
            return (false, nil)
        }

        let document = try loadXMLDocument(at: infoURL)
        guard let root = document.rootElement(),
              let adjustmentElement = firstDescendant(named: "hardwareFilterAdjusted", in: root) else {
            return (false, nil)
        }

        let rawValue = adjustmentElement.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isAdjusted = parseXMLBoolean(rawValue)
        let shiftText = adjustmentElement.attributes?
            .first(where: { sanitizedTagName($0.name) == "shiftMicroseconds" })?
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shiftMicroseconds = shiftText.flatMap { Int($0) }

        return (isAdjusted, shiftMicroseconds)
    }

    private func acquisitionVersionIndicatesAntiAliasCorrection(_ value: String) -> Bool {
        guard let components = versionComponents(from: value) else {
            return false
        }
        return version(components, isAtLeast: [5, 2])
    }

    private func versionComponents(from value: String) -> [Int]? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(trimmed.prefix { $0.isNumber || $0 == "." })
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !prefix.isEmpty else {
            return nil
        }

        let components = prefix.split(separator: ".").compactMap { Int($0) }
        return components.isEmpty ? nil : components
    }

    private func version(_ lhs: [Int], isAtLeast rhs: [Int]) -> Bool {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let lhsComponent = index < lhs.count ? lhs[index] : 0
            let rhsComponent = index < rhs.count ? rhs[index] : 0
            if lhsComponent != rhsComponent {
                return lhsComponent > rhsComponent
            }
        }
        return true
    }

    private func parseXMLBoolean(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes":
            return true
        default:
            return false
        }
    }

    private func parseChannelNames(in packageURL: URL, expectedCount: Int) throws -> [String]? {
        let layoutURL = packageURL.appendingPathComponent("sensorLayout.xml")
        guard expectedCount > 0, FileManager.default.fileExists(atPath: layoutURL.path) else {
            return nil
        }

        let document = try loadXMLDocument(at: layoutURL)
        guard let root = document.rootElement() else {
            throw MFFReaderError.invalidXML(layoutURL, "missing XML root element")
        }

        var names = Array(repeating: "", count: expectedCount)
        for sensor in descendants(named: "sensor", in: root) {
            let children = (sensor.children ?? []).compactMap { $0 as? XMLElement }
            let number = children
                .first(where: { sanitizedTagName($0.name) == "number" })?
                .stringValue
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let type = children
                .first(where: { sanitizedTagName($0.name) == "type" })?
                .stringValue
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let name = children
                .first(where: { sanitizedTagName($0.name) == "name" || sanitizedTagName($0.name) == "label" })?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard (type == nil || type == 0),
                  let number,
                  (1...expectedCount).contains(number),
                  let name,
                  !name.isEmpty else {
                continue
            }
            names[number - 1] = name
        }

        guard names.contains(where: { !$0.isEmpty }) else {
            return nil
        }
        return names.enumerated().map { index, name in
            name.isEmpty ? "Ch \(index + 1)" : name
        }
    }

    /// Loads the peripheral/physiological (PNS) signal file (e.g. ECG, EMG,
    /// respiration) if the package contains one. These channels live in a
    /// separate `signal*.bin` whose `info*.xml` declares the `PNSData` type, with
    /// channel names in `pnsSet.xml`. Returns nil when there is no PNS signal.
    func loadPNSSignal(
        from packageURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> MFFSignalData? {
        let packageURL = try validatedPackageURL(from: packageURL)
        progress?(0.01)
        let signalFiles = try binFiles(in: packageURL)

        var descriptor: (signalURL: URL, infoFileName: String, signalType: String)?
        for fileName in signalFiles {
            let signalURL = packageURL.appendingPathComponent(fileName)
            let type = (try? parseSignalType(for: signalURL, in: packageURL)) ?? nil
            if let type, type.range(of: "pns", options: .caseInsensitive) != nil {
                descriptor = (signalURL, signalInfoFileName(for: signalURL), type)
                break
            }
        }
        guard let descriptor else { return nil }

        let signalData = try parseSignal(from: descriptor.signalURL) { fraction in
            progress?(0.02 + 0.82 * fraction)
        }
        guard signalData.numberOfChannels > 0, signalData.totalSamples > 0 else { return nil }

        progress?(0.86)
        var samples = signalData.samples
        if let gcal = try parseCalibrationFactors(
            named: "GCAL",
            in: packageURL,
            infoFileName: descriptor.infoFileName,
            expectedCount: signalData.numberOfChannels
        ) {
            applyCalibrationFactors(gcal, to: &samples)
        }

        progress?(0.94)
        let recordingStartTime = try parseRecordingStartTime(in: packageURL)
        let channelNames = parsePNSChannelNames(in: packageURL, expectedCount: signalData.numberOfChannels)
        progress?(1)

        return MFFSignalData(
            signalURL: descriptor.signalURL,
            signalType: descriptor.signalType,
            numberOfChannels: signalData.numberOfChannels,
            samplingRate: signalData.samplingRate,
            duration: Double(signalData.totalSamples) / signalData.samplingRate,
            recordingStartTime: recordingStartTime,
            events: [],   // events belong to the primary (EEG) signal
            data: samples,
            channelNames: channelNames
        )
    }

    /// Parses PNS channel names from `pnsSet.xml`, keyed by the sensor `<number>`
    /// (0-based, matching the data channel order).
    private func parsePNSChannelNames(in packageURL: URL, expectedCount: Int) -> [String]? {
        let url = packageURL.appendingPathComponent("pnsSet.xml")
        guard expectedCount > 0, FileManager.default.fileExists(atPath: url.path),
              let document = try? loadXMLDocument(at: url),
              let root = document.rootElement() else {
            return nil
        }

        var names = Array(repeating: "", count: expectedCount)
        for sensor in descendants(named: "sensor", in: root) {
            let children = (sensor.children ?? []).compactMap { $0 as? XMLElement }
            let number = children
                .first { sanitizedTagName($0.name) == "number" }?
                .stringValue
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let name = children
                .first { sanitizedTagName($0.name) == "name" }?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let number, (0..<expectedCount).contains(number),
                  let name, !name.isEmpty else { continue }
            names[number] = name
        }

        guard names.contains(where: { !$0.isEmpty }) else { return nil }
        return names.enumerated().map { index, name in
            name.isEmpty ? "PNS \(index + 1)" : name
        }
    }

    private func parseEvents(in packageURL: URL) throws -> [MFFEvent] {
        let eventFiles = try xmlFiles(in: packageURL)
            .filter { $0.hasPrefix("Events") }
        let recordingStartTime = try parseRecordingStartTime(in: packageURL)

        var events: [MFFEvent] = []
        var seenIDs = Set<String>()

        for fileName in eventFiles {
            let xmlURL = packageURL.appendingPathComponent(fileName)
            let document = try loadXMLDocument(at: xmlURL)
            guard let root = document.rootElement() else {
                throw MFFReaderError.invalidXML(xmlURL, "missing XML root element")
            }

            collectEvents(
                from: root,
                sourceFile: fileName,
                recordingStartTime: recordingStartTime,
                into: &events,
                seenIDs: &seenIDs
            )
        }

        return events.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
    }

    private func collectEvents(
        from element: XMLElement,
        sourceFile: String,
        recordingStartTime: Date?,
        into events: inout [MFFEvent],
        seenIDs: inout Set<String>
    ) {
        let children = (element.children ?? []).compactMap { $0 as? XMLElement }
        let directCode = children.first(where: { sanitizedTagName($0.name) == "code" })?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directLabel = children.first(where: { sanitizedTagName($0.name) == "label" })?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directDescription = children.first(where: { sanitizedTagName($0.name) == "description" })?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directCell = eventCellValue(from: element)
        let directBeginTime = children.first(where: { sanitizedTagName($0.name) == "beginTime" })?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let directCode, !directCode.isEmpty,
           let directBeginTime, !directBeginTime.isEmpty,
           let beginTimeSeconds = resolveEventBeginTimeSeconds(directBeginTime, recordingStartTime: recordingStartTime) {
            let eventID = "\(sourceFile)|\(directCode)|\(directBeginTime)"
            if seenIDs.insert(eventID).inserted {
                events.append(
                    MFFEvent(
                        id: eventID,
                        code: directCode,
                        label: directLabel,
                        eventDescription: directDescription,
                        cell: directCell,
                        beginTimeSeconds: beginTimeSeconds,
                        rawBeginTime: directBeginTime,
                        sourceFile: sourceFile
                    )
                )
            }
        }

        for child in children {
            collectEvents(
                from: child,
                sourceFile: sourceFile,
                recordingStartTime: recordingStartTime,
                into: &events,
                seenIDs: &seenIDs
            )
        }
    }

    private func eventCellValue(from eventElement: XMLElement) -> String? {
        let keyElements = (eventElement.children ?? [])
            .compactMap { $0 as? XMLElement }
            .filter { sanitizedTagName($0.name) == "keys" }
            .flatMap { keysElement in
                (keysElement.children ?? [])
                    .compactMap { $0 as? XMLElement }
                    .filter { sanitizedTagName($0.name) == "key" }
            }
        for key in keyElements {
            let keyChildren = (key.children ?? []).compactMap { $0 as? XMLElement }
            let keyCode = keyChildren.first { sanitizedTagName($0.name) == "keyCode" }?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard let keyCode, ["cel#", "#cel", "cell"].contains(keyCode) else { continue }
            let value = keyChildren.first { sanitizedTagName($0.name) == "data" }?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func resolveEventBeginTimeSeconds(_ rawValue: String, recordingStartTime: Date?) -> Double? {
        if let numericValue = Double(rawValue) {
            if numericValue > 1_000_000 {
                return numericValue / 1_000_000
            }
            return numericValue
        }

        if let eventDate = parseMFFDate(rawValue), let recordingStartTime {
            return eventDate.timeIntervalSince(recordingStartTime)
        }

        return nil
    }

    // MARK: - On-disk epochs / averaged data

    private struct OnDiskEpochInfo {
        let segments: [EpochSegment]
        let events: [MFFEvent]
        let isAveraged: Bool
    }

    private struct EpochBlockRange {
        let beginTimeMicroseconds: Double
        let endTimeMicroseconds: Double
        let startSample: Int
        let endSampleExclusive: Int
    }

    private struct CategorySegment {
        let category: String
        let beginTimeMicroseconds: Double
        let endTimeMicroseconds: Double
        let eventTimeMicroseconds: Double
        let contributingEpochCount: Int
    }

    /// Reads `epochs.xml` + `categories.xml`. When the package is segmented or
    /// category-averaged, returns the per-epoch `EpochSegment`s mapped onto the
    /// concatenated sample timeline, plus one stimulus-locked marker per epoch.
    /// Returns nil for ordinary continuous recordings.
    private func parseOnDiskEpochs(
        in packageURL: URL,
        blockSampleCounts: [Int],
        samplingRate: Double
    ) throws -> OnDiskEpochInfo? {
        guard samplingRate > 0, !blockSampleCounts.isEmpty else { return nil }

        let categorySegments = try parseCategorySegments(in: packageURL)
        // Continuous recordings have no category segments. A lone segment that
        // spans the whole recording (e.g. a single un-averaged "Category 1") is
        // treated as continuous so we don't draw a spurious epoch boundary.
        guard categorySegments.count >= 2
            || categorySegments.contains(where: { $0.contributingEpochCount > 1 }) else {
            return nil
        }

        let epochs = try parseEpochRanges(in: packageURL, blockSampleCounts: blockSampleCounts)
        guard !epochs.isEmpty else { return nil }

        let colorIndices = categoryColorIndices(for: categorySegments.map(\.category))

        var segments: [EpochSegment] = []
        for segment in categorySegments {
            // Match by the segment midpoint so a segment that starts exactly on an
            // epoch boundary isn't ambiguously assigned to the preceding epoch.
            let midpoint = (segment.beginTimeMicroseconds + segment.endTimeMicroseconds) / 2
            guard let epoch = epochs.first(where: {
                midpoint >= $0.beginTimeMicroseconds && midpoint < $0.endTimeMicroseconds
            }) else { continue }

            let startSample = sampleIndex(
                forMicroseconds: segment.beginTimeMicroseconds,
                in: epoch,
                samplingRate: samplingRate
            )
            let endExclusive = sampleIndex(
                forMicroseconds: segment.endTimeMicroseconds,
                in: epoch,
                samplingRate: samplingRate
            )
            let stimulusSample = sampleIndex(
                forMicroseconds: segment.eventTimeMicroseconds,
                in: epoch,
                samplingRate: samplingRate
            )
            guard endExclusive > startSample else { continue }

            let endSample = endExclusive - 1
            let stimulusOffset = min(max(stimulusSample - startSample, 0), endSample - startSample)
            segments.append(
                EpochSegment(
                    startSample: startSample,
                    endSample: endSample,
                    stimulusOffsetSamples: stimulusOffset,
                    category: segment.category,
                    sourceCode: segment.category,
                    sourceTimeSeconds: Double(startSample + stimulusOffset) / samplingRate,
                    colorIndex: colorIndices[segment.category] ?? 0,
                    contributingEpochCount: segment.contributingEpochCount
                )
            )
        }

        guard !segments.isEmpty else { return nil }
        segments.sort { $0.startSample < $1.startSample }

        let events = segments.enumerated().map { index, segment in
            let stimulusTime = segment.sourceTimeSeconds
            return MFFEvent(
                id: "epoch-\(index)-\(segment.category)",
                code: segment.category,
                beginTimeSeconds: stimulusTime,
                rawBeginTime: String(format: "%.6f", stimulusTime),
                sourceFile: "Epochs"
            )
        }

        let isAveraged = segments.allSatisfy { $0.contributingEpochCount > 1 }
        return OnDiskEpochInfo(segments: segments, events: events, isAveraged: isAveraged)
    }

    /// Assigns a stable color index to each category in first-appearance order.
    private func categoryColorIndices(for categories: [String]) -> [String: Int] {
        var indices: [String: Int] = [:]
        for category in categories where indices[category] == nil {
            indices[category] = indices.count
        }
        return indices
    }

    /// Maps a microsecond timestamp within an epoch to a concatenated sample
    /// index, clamped to the epoch's sample span.
    private func sampleIndex(
        forMicroseconds microseconds: Double,
        in epoch: EpochBlockRange,
        samplingRate: Double
    ) -> Int {
        let offsetSeconds = (microseconds - epoch.beginTimeMicroseconds) / 1_000_000
        let sample = epoch.startSample + Int((offsetSeconds * samplingRate).rounded())
        return min(max(sample, epoch.startSample), epoch.endSampleExclusive)
    }

    private func parseEpochRanges(
        in packageURL: URL,
        blockSampleCounts: [Int]
    ) throws -> [EpochBlockRange] {
        let epochsURL = packageURL.appendingPathComponent("epochs.xml")
        guard FileManager.default.fileExists(atPath: epochsURL.path) else { return [] }

        let document = try loadXMLDocument(at: epochsURL)
        guard let root = document.rootElement() else { return [] }

        // Prefix sums of samples preceding each block boundary (0-based blocks).
        var prefix = [Int](repeating: 0, count: blockSampleCounts.count + 1)
        for index in blockSampleCounts.indices {
            prefix[index + 1] = prefix[index] + blockSampleCounts[index]
        }

        var ranges: [EpochBlockRange] = []
        for epoch in descendants(named: "epoch", in: root) {
            let children = (epoch.children ?? []).compactMap { $0 as? XMLElement }
            func value(_ name: String) -> Double? {
                guard let raw = children.first(where: { sanitizedTagName($0.name) == name })?
                    .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                return Double(raw)
            }
            guard let beginTime = value("beginTime"),
                  let endTime = value("endTime"),
                  let firstBlock = value("firstBlock").map({ Int($0) }) ?? nil,
                  let lastBlock = value("lastBlock").map({ Int($0) }) ?? nil,
                  firstBlock >= 1, lastBlock >= firstBlock,
                  lastBlock <= blockSampleCounts.count else {
                continue
            }
            ranges.append(
                EpochBlockRange(
                    beginTimeMicroseconds: beginTime,
                    endTimeMicroseconds: endTime,
                    startSample: prefix[firstBlock - 1],
                    endSampleExclusive: prefix[lastBlock]
                )
            )
        }
        return ranges
    }

    private func parseCategorySegments(in packageURL: URL) throws -> [CategorySegment] {
        let categoriesURL = packageURL.appendingPathComponent("categories.xml")
        guard FileManager.default.fileExists(atPath: categoriesURL.path) else { return [] }

        let document = try loadXMLDocument(at: categoriesURL)
        guard let root = document.rootElement() else { return [] }

        var segments: [CategorySegment] = []
        for category in descendants(named: "cat", in: root) {
            let categoryChildren = (category.children ?? []).compactMap { $0 as? XMLElement }
            let name = categoryChildren.first { sanitizedTagName($0.name) == "name" }?
                .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let categoryName = (name?.isEmpty == false) ? name! : "Category"

            for seg in descendants(named: "seg", in: category) {
                let children = (seg.children ?? []).compactMap { $0 as? XMLElement }
                func value(_ tag: String) -> Double? {
                    guard let raw = children.first(where: { sanitizedTagName($0.name) == tag })?
                        .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                    return Double(raw)
                }
                guard let beginTime = value("beginTime"),
                      let endTime = value("endTime"), endTime > beginTime else {
                    continue
                }
                let eventTime = value("evtBegin") ?? beginTime
                segments.append(
                    CategorySegment(
                        category: categoryName,
                        beginTimeMicroseconds: beginTime,
                        endTimeMicroseconds: endTime,
                        eventTimeMicroseconds: eventTime,
                        contributingEpochCount: segmentContributingCount(in: seg)
                    )
                )
            }
        }
        return segments
    }

    /// The `#seg` key records how many trials were averaged into a segment;
    /// absent (value 1) for plain segmented (un-averaged) data.
    private func segmentContributingCount(in seg: XMLElement) -> Int {
        for key in descendants(named: "key", in: seg) {
            let keyChildren = (key.children ?? []).compactMap { $0 as? XMLElement }
            let code = keyChildren.first { sanitizedTagName($0.name) == "keyCode" }?
                .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard code == "#seg" else { continue }
            if let raw = keyChildren.first(where: { sanitizedTagName($0.name) == "data" })?
                .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                let count = Int(raw), count > 0 {
                return count
            }
        }
        return 1
    }

    private func parseSignal(
        from signalURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> ParsedSignal {
        let handle = try FileHandle(forReadingFrom: signalURL)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        progress?(0)

        var lastHeader: SignalHeader?
        var allChannels: [[Float]] = []
        var totalSamples = 0
        var blockSampleCounts: [Int] = []
        var expectedChannelCount: Int?
        var expectedSamplingRate: Double?
        var lastReportedProgress = 0.0

        while try handle.offset() < fileSize {
            let flag = try Int(readInt32(from: handle, signalURL: signalURL))

            let header: SignalHeader
            if flag == 0 {
                guard let previousHeader = lastHeader else {
                    throw MFFReaderError.invalidBinaryData(signalURL, "encountered a data block before any header block")
                }
                header = previousHeader
            } else if flag == 1 {
                header = try readHeader(from: handle, signalURL: signalURL)
                lastHeader = header
            } else {
                throw MFFReaderError.invalidBinaryData(signalURL, "unexpected block flag \(flag)")
            }

            if let channelCount = expectedChannelCount, channelCount != header.numberOfChannels {
                throw MFFReaderError.inconsistentBlockConfiguration
            }

            if let samplingRate = expectedSamplingRate, samplingRate != header.samplingRate {
                throw MFFReaderError.inconsistentBlockConfiguration
            }

            expectedChannelCount = header.numberOfChannels
            expectedSamplingRate = header.samplingRate

            if allChannels.isEmpty {
                allChannels = Array(repeating: [], count: header.numberOfChannels)
            }

            let data = try readExactly(from: handle, byteCount: header.blockSize, signalURL: signalURL)
            let sampleMatrix = try decodeSamples(
                from: data,
                numberOfChannels: header.numberOfChannels,
                numberOfSamplesPerChannel: header.numberOfSamples,
                signalURL: signalURL
            )

            for index in sampleMatrix.indices {
                allChannels[index].append(contentsOf: sampleMatrix[index])
            }

            totalSamples += header.numberOfSamples
            blockSampleCounts.append(header.numberOfSamples)

            if fileSize > 0 {
                let fraction = Double(try handle.offset()) / Double(fileSize)
                if fraction - lastReportedProgress >= 0.005 || fraction >= 1 {
                    lastReportedProgress = fraction
                    progress?(min(max(fraction, 0), 1))
                }
            }
        }

        guard let numberOfChannels = expectedChannelCount, let samplingRate = expectedSamplingRate else {
            throw MFFReaderError.emptySignal
        }

        progress?(1)
        return ParsedSignal(
            numberOfChannels: numberOfChannels,
            samplingRate: samplingRate,
            totalSamples: totalSamples,
            samples: allChannels,
            blockSampleCounts: blockSampleCounts
        )
    }

    private func readHeader(from handle: FileHandle, signalURL: URL) throws -> SignalHeader {
        let headerSize = try Int(readInt32(from: handle, signalURL: signalURL))
        let blockSize = try Int(readInt32(from: handle, signalURL: signalURL))
        let numberOfChannels = try Int(readInt32(from: handle, signalURL: signalURL))

        guard headerSize >= 20 else {
            throw MFFReaderError.invalidBinaryData(signalURL, "header size \(headerSize) is too small")
        }
        guard blockSize >= 0 else {
            throw MFFReaderError.invalidBinaryData(signalURL, "negative block size \(blockSize)")
        }
        guard numberOfChannels > 0 else {
            throw MFFReaderError.invalidBinaryData(signalURL, "invalid channel count \(numberOfChannels)")
        }

        _ = try readExactly(from: handle, byteCount: numberOfChannels * 4, signalURL: signalURL)

        let firstRateDepth = try Int(readInt32(from: handle, signalURL: signalURL))
        let (samplingRate, sampleDepth) = decodeRateDepth(firstRateDepth)
        guard sampleDepth == 32 else {
            throw MFFReaderError.unsupportedSampleDepth(sampleDepth)
        }

        if numberOfChannels > 1 {
            _ = try readExactly(from: handle, byteCount: (numberOfChannels - 1) * 4, signalURL: signalURL)
        }

        let consumedHeaderBytes = 16 + (numberOfChannels * 8)
        if headerSize < consumedHeaderBytes {
            throw MFFReaderError.invalidBinaryData(signalURL, "header size \(headerSize) is smaller than required \(consumedHeaderBytes)")
        }

        if consumedHeaderBytes < headerSize {
            _ = try readExactly(from: handle, byteCount: headerSize - consumedHeaderBytes, signalURL: signalURL)
        }

        let bytesPerChannel = numberOfChannels * MemoryLayout<Float>.size
        guard blockSize % bytesPerChannel == 0 else {
            throw MFFReaderError.invalidBinaryData(signalURL, "block size \(blockSize) is not divisible by channel width \(bytesPerChannel)")
        }

        return SignalHeader(
            headerSize: headerSize,
            blockSize: blockSize,
            numberOfChannels: numberOfChannels,
            numberOfSamples: blockSize / bytesPerChannel,
            samplingRate: Double(samplingRate)
        )
    }

    private func decodeSamples(
        from data: Data,
        numberOfChannels: Int,
        numberOfSamplesPerChannel: Int,
        signalURL: URL
    ) throws -> [[Float]] {
        let expectedByteCount = numberOfChannels * numberOfSamplesPerChannel * MemoryLayout<Float>.size
        guard data.count == expectedByteCount else {
            throw MFFReaderError.invalidBinaryData(signalURL, "expected \(expectedByteCount) sample bytes but found \(data.count)")
        }

        var channels = Array(
            repeating: Array(repeating: Float(0), count: numberOfSamplesPerChannel),
            count: numberOfChannels
        )

        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for channel in 0..<numberOfChannels {
                let channelBase = channel * numberOfSamplesPerChannel * 4
                for sample in 0..<numberOfSamplesPerChannel {
                    let offset = channelBase + sample * 4
                    let word = UInt32(bytes[offset])
                        | (UInt32(bytes[offset + 1]) << 8)
                        | (UInt32(bytes[offset + 2]) << 16)
                        | (UInt32(bytes[offset + 3]) << 24)
                    channels[channel][sample] = Float(bitPattern: word)
                }
            }
        }

        return channels
    }

    private func decodeRateDepth(_ value: Int) -> (samplingRate: Int, sampleDepth: Int) {
        let unsigned = UInt32(bitPattern: Int32(value))
        return (Int(unsigned >> 8), Int(unsigned & 0xFF))
    }

    private func readInt32(from handle: FileHandle, signalURL: URL) throws -> Int32 {
        let data = try readExactly(from: handle, byteCount: MemoryLayout<Int32>.size, signalURL: signalURL)
        return data.withUnsafeBytes { rawBuffer in
            let value = rawBuffer.load(as: Int32.self)
            return Int32(littleEndian: value)
        }
    }

    private func readExactly(from handle: FileHandle, byteCount: Int, signalURL: URL) throws -> Data {
        let data = try handle.read(upToCount: byteCount) ?? Data()
        guard data.count == byteCount else {
            throw MFFReaderError.invalidBinaryData(signalURL, "unexpected end of file while reading \(byteCount) bytes")
        }
        return data
    }

    private func loadXMLDocument(at url: URL) throws -> XMLDocument {
        do {
            let data = try Data(contentsOf: url)
            return try XMLDocument(data: data, options: [.documentTidyXML])
        } catch {
            throw MFFReaderError.invalidXML(url, error.localizedDescription)
        }
    }

    private func firstDescendant(named name: String, in element: XMLElement) -> XMLElement? {
        if sanitizedTagName(element.name) == name {
            return element
        }

        for child in element.children ?? [] {
            guard let childElement = child as? XMLElement else {
                continue
            }
            if let match = firstDescendant(named: name, in: childElement) {
                return match
            }
        }

        return nil
    }

    private func descendants(named name: String, in element: XMLElement) -> [XMLElement] {
        var matches: [XMLElement] = []
        if sanitizedTagName(element.name) == name {
            matches.append(element)
        }
        for child in element.children ?? [] {
            guard let childElement = child as? XMLElement else {
                continue
            }
            matches.append(contentsOf: descendants(named: name, in: childElement))
        }
        return matches
    }

    private func sanitizedTagName(_ name: String?) -> String {
        guard let name else {
            return ""
        }
        return name.components(separatedBy: ":").last ?? name
    }

    private func parseMFFDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return date
        }

        if value.count > 6 {
            let normalized = String(value.dropLast(3)) + String(value.suffix(2))
            let fallback = DateFormatter()
            fallback.locale = Locale(identifier: "en_US_POSIX")
            fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ"
            return fallback.date(from: normalized)
        }

        return nil
    }
}

private struct SignalHeader {
    let headerSize: Int
    let blockSize: Int
    let numberOfChannels: Int
    let numberOfSamples: Int
    let samplingRate: Double
}

private struct ParsedSignal {
    let numberOfChannels: Int
    let samplingRate: Double
    let totalSamples: Int
    let samples: [[Float]]
    /// Number of samples contributed by each successive signal block, in order.
    /// One entry per block; the boundaries delimit on-disk epochs.
    let blockSampleCounts: [Int]
}
