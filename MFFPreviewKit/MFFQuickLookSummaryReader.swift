//
//  MFFQuickLookSummaryReader.swift
//  MFFPreviewKit
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The one-pass read behind MFFQuickLookSummary. Every parse here is small XML or
//  a 32-byte binary header; nothing in this file opens sample data.
//

import Foundation

extension MFFQuickLookSummary {

    enum ReadError: LocalizedError {
        case notAnMFFPackage(URL)

        var errorDescription: String? {
            switch self {
            case .notAnMFFPackage(let url):
                return "\(url.lastPathComponent) is not a readable MFF package."
            }
        }
    }

    static func read(from url: URL, options: Options = .preview) throws -> MFFQuickLookSummary {
        let fileManager = FileManager.default
        let names = Set((try? fileManager.contentsOfDirectory(atPath: url.path)) ?? [])
        guard names.contains("info.xml") else { throw ReadError.notAnMFFPackage(url) }

        func root(_ name: String) -> XMLElement? {
            guard names.contains(name) else { return nil }
            // .documentTidyXML matches MFFReader.loadXMLDocument: some EGI
            // writers emit characters that are illegal in XML (example_5.mff has
            // a U+FFFF inside a category name), and tidying recovers instead of
            // failing the whole parse.
            guard let data = try? Data(contentsOf: url.appendingPathComponent(name)) else { return nil }
            return (try? XMLDocument(data: data, options: [.documentTidyXML]))?.rootElement()
        }

        // MARK: info.xml

        let info = root("info.xml")
        let mffVersion = info?.firstInt("mffVersion")
        let recordTime = info?.firstText("recordTime").flatMap(parseTimestamp)
        let ampType = info?.firstText("ampType")
        let ampSerial = info?.firstText("ampSerialNumber")
        let amplifier = [ampType, ampSerial]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // MARK: subject.xml

        var subjectID: String?
        var sessionNumber: String?
        if let patient = root("subject.xml") {
            for field in patient.descendants("field") {
                guard let name = field.firstText("name"),
                      let value = field.firstText("data"), !value.isEmpty else { continue }
                switch name {
                case "Patient ID": subjectID = value
                case "Session Number": sessionNumber = value
                default: break
                }
            }
        }

        // MARK: info1.xml / info2.xml

        let info1 = root("info1.xml")
        let layoutName = info1?.firstText("sensorLayoutName") ?? info1?.firstText("montageName")
        let hardwareFilterShift = info1?
            .descendants("hardwareFilterAdjusted")
            .first?
            .attribute(forName: "shiftMicroseconds")?
            .stringValue
            .flatMap { Int($0) }

        // MARK: epochs.xml

        var totalMicroseconds = 0
        var epochCount = 0
        if let epochs = root("epochs.xml") {
            for epoch in epochs.descendants("epoch") {
                guard let begin = epoch.firstInt("beginTime"),
                      let end = epoch.firstInt("endTime"), end > begin else { continue }
                totalMicroseconds += end - begin
                epochCount += 1
            }
        }
        let durationFromEpochs = totalMicroseconds > 0 ? Double(totalMicroseconds) / 1_000_000 : nil

        // MARK: signal headers

        let signalNames = names.filter { $0.hasPrefix("signal") && $0.hasSuffix(".bin") }.sorted()
        let eegShape = readSignalShape(at: url.appendingPathComponent("signal1.bin"))
        var pnsChannelCount: Int?
        if names.contains("signal2.bin") {
            pnsChannelCount = readSignalShape(at: url.appendingPathComponent("signal2.bin"))?.channelCount
        }

        // MARK: sensorLayout.xml

        var sensors: [Sensor] = []
        if let layout = root("sensorLayout.xml") {
            for sensor in layout.descendants("sensor") {
                // type 0 is a recording electrode; 1 and 2 are reference and
                // fiducial points, which do not belong on the cap picture.
                guard (sensor.firstInt("type") ?? 0) == 0,
                      let number = sensor.firstInt("number"),
                      let x = sensor.firstDouble("x"),
                      let y = sensor.firstDouble("y") else { continue }
                // EGI stores y increasing toward the back of the head, so the
                // raw values are upside down for screen drawing. Same flip that
                // SensorLayout applies in the app target.
                sensors.append(Sensor(number: number, x: x, y: -y))
            }
        }

        // MARK: impedance (ICAL in info1.xml)

        let impedance = info1.flatMap { parseImpedance(in: $0, channelCount: eegShape?.channelCount) }

        // MARK: categories.xml

        let categories = root("categories.xml")
        let segments = categories.map(parseCategorySegments) ?? []
        var badChannels: Set<Int> = []
        for segment in segments { badChannels.formUnion(segment.badChannels) }

        // MARK: eva.xml

        let declaredType = root("eva.xml")?.firstText("fileType").flatMap(FileType.init(rawValue:))

        // MARK: classification

        let fileType = classify(segments: segments, declaredType: declaredType)

        // MARK: type-specific detail

        var continuousDetail: ContinuousDetail?
        var segmentedDetail: SegmentedDetail?
        var averagedDetail: AveragedDetail?

        switch fileType {
        case .continuous:
            let tracks = options.includeEvents
                ? parseEventTracks(in: url, names: names, recordTime: recordTime, options: options)
                : []
            continuousDetail = ContinuousDetail(tracks: tracks)

        case .segmented:
            var tallies: [String: (kept: Int, rejected: Int, trials: Int)] = [:]
            var order: [String] = []
            var faults: [String: Int] = [:]
            for segment in segments {
                if tallies[segment.category] == nil { order.append(segment.category) }
                var tally = tallies[segment.category] ?? (0, 0, 0)
                if segment.isBad { tally.rejected += 1 } else { tally.kept += 1 }
                tally.trials += segment.contributingTrials
                tallies[segment.category] = tally
                for fault in segment.faults { faults[fault, default: 0] += 1 }
            }
            segmentedDetail = SegmentedDetail(
                epochLengthSeconds: segments.first.map { Double($0.endMicroseconds - $0.beginMicroseconds) / 1_000_000 },
                baselineSeconds: segments.first.map { Double($0.eventMicroseconds - $0.beginMicroseconds) / 1_000_000 },
                conditions: order.map { name in
                    let tally = tallies[name] ?? (0, 0, 0)
                    return ConditionTally(
                        name: name,
                        kept: tally.kept,
                        rejected: tally.rejected,
                        contributingTrials: tally.trials
                    )
                },
                faultHistogram: faults
            )

        case .averaged, .grandAverage:
            var conditions: [String] = []
            var subjects: [String] = []
            var cells: [String: [String: Int]] = [:]
            var sourceFiles: [String] = []
            for segment in segments {
                if !conditions.contains(segment.category) { conditions.append(segment.category) }
                let subject = segment.subject ?? ""
                if !subject.isEmpty, !subjects.contains(subject) { subjects.append(subject) }
                cells[segment.category, default: [:]][subject] = segment.contributingTrials
                if let file = segment.sourceFile, !sourceFiles.contains(file) { sourceFiles.append(file) }
            }
            averagedDetail = AveragedDetail(
                conditions: conditions,
                subjects: subjects,
                trialsPerCell: cells,
                sourceFiles: sourceFiles,
                epochLengthSeconds: segments.first.map { Double($0.endMicroseconds - $0.beginMicroseconds) / 1_000_000 },
                baselineSeconds: segments.first.map { Double($0.eventMicroseconds - $0.beginMicroseconds) / 1_000_000 }
            )
        }

        // MARK: assembly

        return MFFQuickLookSummary(
            url: url,
            displayName: url.lastPathComponent,
            fileType: fileType,
            mffVersion: mffVersion,
            recordTime: recordTime,
            amplifier: amplifier.isEmpty ? nil : amplifier,
            acquisitionVersion: info?.firstText("acquisitionVersion"),
            subjectID: subjectID,
            sessionNumber: sessionNumber,
            byteSize: directorySize(of: url),
            samplingRate: eegShape?.samplingRate,
            channelCount: eegShape?.channelCount,
            pnsChannelCount: pnsChannelCount,
            // The block walk reports what the file actually holds; epochs.xml is
            // only a fallback, and can overstate the length when a package has
            // been trimmed (EVATests' example_1.mff claims 2424 s for 16.6 s of
            // samples).
            durationSeconds: eegShape?.durationSeconds ?? durationFromEpochs,
            epochCount: epochCount,
            layoutName: layoutName,
            sensors: sensors,
            badChannels: badChannels,
            impedance: impedance,
            manifest: Manifest(
                hasCategories: names.contains("categories.xml"),
                hasHistory: names.contains("history.xml"),
                hasCoordinates: names.contains("coordinates.xml"),
                hasPNS: names.contains("pnsSet.xml") || names.contains("signal2.bin"),
                hasMRInfo: names.contains("po_MRIInfo.xml"),
                hasEVAScript: names.contains("eva.xml"),
                signalFileNames: signalNames
            ),
            hardwareFilterShiftMicroseconds: hardwareFilterShift,
            trsPerVolume: root("po_MRIInfo.xml")?.firstInt("trsPerVolume"),
            continuousDetail: continuousDetail,
            segmentedDetail: segmentedDetail,
            averagedDetail: averagedDetail
        )
    }

    // MARK: - Impedance

    /// Reads the `ICAL` calibration block, which records electrode impedance in
    /// kOhm at recording start. Mirrors `MFFReader.parseCalibrationFactors`:
    /// keyed by the `n` attribute, falling back to document order, and skipping
    /// any calibration whose `beginTime` is not zero.
    static func parseImpedance(in info1: XMLElement, channelCount: Int?) -> Impedance? {
        for calibration in info1.descendants("calibration") {
            guard calibration.firstText("type")?.caseInsensitiveCompare("ICAL") == .orderedSame else { continue }
            if let raw = calibration.firstText("beginTime"), let begin = Double(raw), abs(begin) > 0.000001 {
                continue
            }

            var values: [Int: Double] = [:]
            var sequentialNumber = 1
            for channel in calibration.descendants("ch") {
                defer { sequentialNumber += 1 }
                let number = channel.attribute(forName: "n")?.stringValue.flatMap { Int($0) } ?? sequentialNumber
                // ICAL often carries one entry more than the signal has channels
                // (the reference), which has no sensor to colour.
                if let channelCount, !(1 ... channelCount).contains(number) { continue }
                guard let text = channel.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let value = Double(text), value.isFinite, value >= 0 else { continue }
                values[number] = value
            }

            if !values.isEmpty { return Impedance(valuesKOhm: values) }
        }
        return nil
    }

    // MARK: - Category segments

    struct CategorySegment: Sendable {
        let category: String
        let isBad: Bool
        let isAverage: Bool
        let contributingTrials: Int
        let subject: String?
        let sourceFile: String?
        let faults: [String]
        let badChannels: Set<Int>
        let beginMicroseconds: Int
        let endMicroseconds: Int
        let eventMicroseconds: Int
    }

    static func parseCategorySegments(in categories: XMLElement) -> [CategorySegment] {
        var result: [CategorySegment] = []
        for category in categories.descendants("cat") {
            let name = category.firstText("name") ?? "Category"
            for segment in category.descendants("seg") {
                var trials = 1
                var subject: String?
                var sourceFile: String?
                for key in segment.descendants("key") {
                    guard let code = key.firstText("keyCode"),
                          let value = key.firstText("data") else { continue }
                    switch code {
                    case "#seg": trials = Int(value) ?? 1
                    case "subj": subject = value.isEmpty ? nil : value
                    case "FILE": sourceFile = value.isEmpty ? nil : value
                    default: break
                    }
                }
                var bad: Set<Int> = []
                for channels in segment.descendants("channels")
                where channels.attribute(forName: "exclusion")?.stringValue == "badChannels" {
                    for token in (channels.stringValue ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" }) {
                        if let number = Int(token) { bad.insert(number) }
                    }
                }
                let begin = segment.firstInt("beginTime") ?? 0
                result.append(
                    CategorySegment(
                        category: name,
                        isBad: segment.attribute(forName: "status")?.stringValue == "bad",
                        // EGI marks a segment that is itself an average with this
                        // name. Grand averages and singleton category averages
                        // both use #seg == 1, so the name is the reliable marker.
                        isAverage: segment.firstText("name") == "Average",
                        contributingTrials: trials,
                        subject: subject,
                        sourceFile: sourceFile,
                        faults: segment.descendants("fault").compactMap { $0.stringValue },
                        badChannels: bad,
                        beginMicroseconds: begin,
                        endMicroseconds: segment.firstInt("endTime") ?? begin,
                        eventMicroseconds: segment.firstInt("evtBegin") ?? begin
                    )
                )
            }
        }
        return result
    }

    /// Mirrors the classification in `MFFReader.parseOnDiskEpochs`. Keep the two
    /// in step -- `MFFQuickLookSummaryTests` fails if they diverge on a fixture.
    static func classify(segments: [CategorySegment], declaredType: FileType?) -> FileType {
        // A lone segment spanning the whole recording is not a real epoch
        // structure, so it stays continuous.
        guard segments.count >= 2 || segments.contains(where: { $0.contributingTrials > 1 }) else {
            return .continuous
        }
        // eva.xml is authoritative: EVA stamps what it actually wrote.
        if let declaredType { return declaredType }

        let isAveraged = segments.allSatisfy { $0.contributingTrials > 1 || $0.isAverage }
        guard isAveraged else { return .segmented }

        let distinctCategories = Set(segments.map(\.category)).count
        let categoriesRepeat = distinctCategories < segments.count
        let hasSubjects = segments.contains { $0.subject != nil }
        return (categoriesRepeat || hasSubjects) ? .grandAverage : .averaged
    }

    // MARK: - Events

    static func parseEventTracks(
        in url: URL,
        names: Set<String>,
        recordTime: Date?,
        options: Options
    ) -> [EventTrack] {
        var tracks: [EventTrack] = []
        for name in names.filter({ $0.hasPrefix("Events_") && $0.hasSuffix(".xml") }).sorted() {
            guard let data = try? Data(contentsOf: url.appendingPathComponent(name)),
                  let document = try? XMLDocument(data: data, options: [.documentTidyXML]),
                  let root = document.rootElement() else { continue }

            var times: [String: [Double]] = [:]
            var counts: [String: Int] = [:]
            var order: [String] = []
            var parsed = 0
            var truncated = false

            for event in root.descendants("event") {
                guard let code = event.firstText("code") else { continue }
                if counts[code] == nil { order.append(code) }
                counts[code, default: 0] += 1
                if parsed < options.maxEventsPerTrack {
                    if let raw = event.firstText("beginTime"),
                       let seconds = eventSeconds(raw, recordTime: recordTime) {
                        times[code, default: []].append(seconds)
                    }
                    parsed += 1
                } else {
                    truncated = true
                }
            }
            guard !order.isEmpty else { continue }

            tracks.append(
                EventTrack(
                    name: root.firstText("name") ?? name,
                    trackType: root.firstText("trackType"),
                    codes: order.map {
                        CodeTally(code: $0, times: times[$0] ?? [], count: counts[$0] ?? 0)
                    },
                    truncated: truncated
                )
            )
        }
        return tracks
    }

    static func eventSeconds(_ raw: String, recordTime: Date?) -> Double? {
        // Continuous recordings write absolute timestamps; segmented exports
        // write microseconds from the recording start.
        if let microseconds = Int(raw) { return Double(microseconds) / 1_000_000 }
        guard let date = parseTimestamp(raw), let recordTime else { return nil }
        return date.timeIntervalSince(recordTime)
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoWithFraction.date(from: raw) { return date }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }

        // EGI writes six fractional digits, which ISO8601DateFormatter rejects
        // on some releases.
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        return fallback.date(from: raw)
    }

    // MARK: - Binary header

    struct SignalShape: Sendable {
        let channelCount: Int
        let samplingRate: Double
        let totalSamples: Int
        var durationSeconds: Double {
            samplingRate > 0 ? Double(totalSamples) / samplingRate : 0
        }
    }

    /// Walks the block headers of a signal file without reading a single sample.
    ///
    /// An MFF block is `flag, [header], data`, where a flag of 1 introduces a new
    /// header and 0 means "same shape as the previous block". A header states its
    /// own size (inclusive of the flag word) and the size of the data that
    /// follows, so we can seek from one block to the next and total up the
    /// samples. That is one seek per block -- 133 for a 260 MB recording --
    /// which is far cheaper than the alternative and, unlike epochs.xml, reports
    /// what the file actually contains.
    static func readSignalShape(at url: URL) -> SignalShape? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return nil }

        var offset: UInt64 = 0
        var channelCount = 0
        var samplingRate: Double = 0
        var blockSize = 0
        var totalSamples = 0
        var blocks = 0

        while offset + 4 <= fileSize, blocks < maxBlocksScanned {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let flagData = try? handle.read(upToCount: 4), flagData.count == 4 else { break }
            let flag = Int(littleEndianUInt32(flagData, at: 0))

            if flag == 1 {
                guard let head = try? handle.read(upToCount: 12), head.count == 12 else { break }
                let headerSize = Int(littleEndianUInt32(head, at: 0))
                let dataSize = Int(littleEndianUInt32(head, at: 4))
                let channels = Int(littleEndianUInt32(head, at: 8))
                guard headerSize >= 20, dataSize > 0, channels > 0, channels < 100_000 else { break }

                // Skip the per-channel offset table to reach the first
                // rate/depth word, which packs the rate in the high 24 bits.
                guard (try? handle.seek(toOffset: offset + 16 + UInt64(channels) * 4)) != nil,
                      let rateData = try? handle.read(upToCount: 4), rateData.count == 4 else { break }
                let rate = Double(littleEndianUInt32(rateData, at: 0) >> 8)
                guard rate > 0 else { break }

                channelCount = channels
                samplingRate = rate
                blockSize = dataSize
                // headerSize counts the 4-byte flag word too, so it is the full
                // distance from the start of the block to its sample data.
                offset += UInt64(headerSize)
            } else if flag == 0 {
                guard channelCount > 0 else { break }
                offset += 4
            } else {
                break
            }

            let bytesPerSample = channelCount * MemoryLayout<Float>.size
            guard bytesPerSample > 0, blockSize % bytesPerSample == 0 else { break }
            totalSamples += blockSize / bytesPerSample
            offset += UInt64(blockSize)
            blocks += 1
        }

        guard channelCount > 0, samplingRate > 0 else { return nil }
        return SignalShape(
            channelCount: channelCount,
            samplingRate: samplingRate,
            totalSamples: totalSamples
        )
    }

    /// A guard against a corrupt file turning the walk into an unbounded loop.
    /// At one block per second this is well over a day of recording.
    private static let maxBlocksScanned = 200_000

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { destination in
            data.copyBytes(to: destination, from: (data.startIndex + offset) ..< (data.startIndex + offset + 4))
        }
        return UInt32(littleEndian: value)
    }

    // MARK: - Size

    static func directorySize(of url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}

// MARK: - XML conveniences

extension XMLElement {
    /// MFF sidecars declare a default namespace, so element names carry no
    /// prefix and a plain local-name match is safe.
    func descendants(_ name: String) -> [XMLElement] {
        var found: [XMLElement] = []
        for child in children ?? [] {
            guard let element = child as? XMLElement else { continue }
            if element.localName == name { found.append(element) }
            found.append(contentsOf: element.descendants(name))
        }
        return found
    }

    func firstText(_ name: String) -> String? {
        for child in children ?? [] {
            guard let element = child as? XMLElement, element.localName == name else { continue }
            return element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return descendants(name).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func firstInt(_ name: String) -> Int? { firstText(name).flatMap { Int($0) } }
    func firstDouble(_ name: String) -> Double? { firstText(name).flatMap { Double($0) } }
}
