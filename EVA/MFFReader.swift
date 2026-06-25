//
//  MFFReader.swift
//  EEGView
//
//  Created by PJM on 3/19/26.
//  Heavily influenced by Codex on 3/19/26.
//

import Foundation

struct MFFPackage {
    let sourceURL: URL
    let xmlFiles: [String]
    let binFiles: [String]
    let selectedXMLFile: String
    let metrics: [String: String]
}

struct MFFSignalData {
    let signalURL: URL
    let signalType: String
    let numberOfChannels: Int
    let samplingRate: Double
    let duration: TimeInterval
    let recordingStartTime: Date?
    let events: [MFFEvent]
    let data: [[Float]]
}

struct MFFEvent: Identifiable, Hashable {
    let id: String
    let code: String
    let beginTimeSeconds: Double
    let rawBeginTime: String
    let sourceFile: String
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

    func loadSignal(from packageURL: URL, signalFileName: String? = nil) throws -> MFFSignalData {
        let packageURL = try validatedPackageURL(from: packageURL)
        let signalDescriptor = try selectSignal(in: packageURL, preferredSignalFile: signalFileName)
        let signalData = try parseSignal(from: signalDescriptor.signalURL)

        guard signalData.numberOfChannels > 0, signalData.totalSamples > 0 else {
            throw MFFReaderError.emptySignal
        }

        return MFFSignalData(
            signalURL: signalDescriptor.signalURL,
            signalType: signalDescriptor.signalType,
            numberOfChannels: signalData.numberOfChannels,
            samplingRate: signalData.samplingRate,
            duration: Double(signalData.totalSamples) / signalData.samplingRate,
            recordingStartTime: try parseRecordingStartTime(in: packageURL),
            events: try parseEvents(in: packageURL),
            data: signalData.samples
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

    private func selectSignal(in packageURL: URL, preferredSignalFile: String?) throws -> (signalURL: URL, signalType: String) {
        let signalFiles = try binFiles(in: packageURL)

        if let preferredSignalFile {
            let signalURL = packageURL.appendingPathComponent(preferredSignalFile)
            guard FileManager.default.fileExists(atPath: signalURL.path) else {
                throw MFFReaderError.missingSignalFile(signalURL)
            }
            let signalType = try parseSignalType(for: signalURL, in: packageURL) ?? "Unknown"
            return (signalURL, signalType)
        }

        let descriptors = try signalFiles.map { fileName in
            let signalURL = packageURL.appendingPathComponent(fileName)
            let signalType = try parseSignalType(for: signalURL, in: packageURL) ?? "Unknown"
            return (signalURL: signalURL, signalType: signalType)
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
        let signalName = signalURL.deletingPathExtension().lastPathComponent
        let signalNumber = signalName.replacingOccurrences(of: "signal", with: "")
        let infoURL = packageURL.appendingPathComponent("info\(signalNumber).xml")
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

    private func parseSignal(from signalURL: URL) throws -> ParsedSignal {
        let handle = try FileHandle(forReadingFrom: signalURL)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)

        var lastHeader: SignalHeader?
        var allChannels: [[Float]] = []
        var totalSamples = 0
        var expectedChannelCount: Int?
        var expectedSamplingRate: Double?

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
        }

        guard let numberOfChannels = expectedChannelCount, let samplingRate = expectedSamplingRate else {
            throw MFFReaderError.emptySignal
        }

        return ParsedSignal(
            numberOfChannels: numberOfChannels,
            samplingRate: samplingRate,
            totalSamples: totalSamples,
            samples: allChannels
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
}
