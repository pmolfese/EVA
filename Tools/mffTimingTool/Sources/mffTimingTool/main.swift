//
//  main.swift
//  MFF Timing Tool
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation

struct MFFTimingEvent {
    let index: Int
    let sourceFile: String
    let beginDate: Date
    let rawBeginTime: String
    let durationMicroseconds: Int?
    let code: String
    let label: String?
    let eventDescription: String?
    let sourceDevice: String?
    let keys: [String: String]
}

enum PairMode: String {
    case nearest
    case next
    case previous
}

enum ToolError: LocalizedError {
    case helpRequested
    case usage(String)
    case invalidMFF(URL)
    case noEventFiles(URL)
    case unreadableXML(URL, String)
    case noEvents
    case missingEvents(String)

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            return nil
        case .usage(let message):
            return message
        case .invalidMFF(let url):
            return "Input is not a readable MFF directory: \(url.path)"
        case .noEventFiles(let url):
            return "No Events*.xml files found in \(url.path)"
        case .unreadableXML(let url, let message):
            return "Could not parse \(url.lastPathComponent): \(message)"
        case .noEvents:
            return "No events were parsed from the Events*.xml files."
        case .missingEvents(let code):
            return "No events found for code '\(code)'."
        }
    }
}

final class EventXMLParser: NSObject, XMLParserDelegate {
    private let sourceFile: String
    private var events: [MFFTimingEvent] = []
    private var currentEvent: PartialEvent?
    private var currentText = ""
    private var currentKeyCode: String?
    private var parseError: Error?

    private struct PartialEvent {
        var beginTime: String?
        var duration: Int?
        var code: String?
        var label: String?
        var eventDescription: String?
        var sourceDevice: String?
        var keys: [String: String] = [:]
    }

    init(sourceFile: String) {
        self.sourceFile = sourceFile
    }

    func parse(url: URL, startingIndex: Int) throws -> [MFFTimingEvent] {
        guard let parser = XMLParser(contentsOf: url) else {
            throw ToolError.unreadableXML(url, "XMLParser could not open the file.")
        }
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false

        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription
                ?? parseError?.localizedDescription
                ?? "Unknown XML parser error."
            throw ToolError.unreadableXML(url, message)
        }

        return events.enumerated().map { offset, event in
            MFFTimingEvent(
                index: startingIndex + offset,
                sourceFile: event.sourceFile,
                beginDate: event.beginDate,
                rawBeginTime: event.rawBeginTime,
                durationMicroseconds: event.durationMicroseconds,
                code: event.code,
                label: event.label,
                eventDescription: event.eventDescription,
                sourceDevice: event.sourceDevice,
                keys: event.keys
            )
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        currentText = ""
        if name == "event" {
            currentEvent = PartialEvent()
            currentKeyCode = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard currentEvent != nil else {
            currentText = ""
            return
        }

        switch name {
        case "beginTime":
            currentEvent?.beginTime = text
        case "duration":
            currentEvent?.duration = Int(text)
        case "code":
            currentEvent?.code = text
        case "label":
            currentEvent?.label = nonEmpty(text)
        case "description":
            currentEvent?.eventDescription = nonEmpty(text)
        case "sourceDevice":
            currentEvent?.sourceDevice = nonEmpty(text)
        case "keyCode":
            currentKeyCode = text
        case "data":
            if let currentKeyCode, !currentKeyCode.isEmpty {
                currentEvent?.keys[currentKeyCode] = text
            }
        case "key":
            currentKeyCode = nil
        case "event":
            do {
                if let event = try buildEvent() {
                    events.append(event)
                }
            } catch {
                parseError = error
                parser.abortParsing()
            }
            currentEvent = nil
            currentKeyCode = nil
        default:
            break
        }

        currentText = ""
    }

    private func buildEvent() throws -> MFFTimingEvent? {
        guard let currentEvent else { return nil }
        guard let rawBeginTime = nonEmpty(currentEvent.beginTime),
              let beginDate = parseMFFDate(rawBeginTime),
              let code = nonEmpty(currentEvent.code) else {
            return nil
        }

        return MFFTimingEvent(
            index: events.count + 1,
            sourceFile: sourceFile,
            beginDate: beginDate,
            rawBeginTime: rawBeginTime,
            durationMicroseconds: currentEvent.duration,
            code: code,
            label: currentEvent.label,
            eventDescription: currentEvent.eventDescription,
            sourceDevice: currentEvent.sourceDevice,
            keys: currentEvent.keys
        )
    }
}

struct Options {
    var inputURL: URL?
    var list = false
    var code: String?
    var din: String?
    var pairMode: PairMode = .nearest
}

func usage() -> String {
    """
    Usage:
      mff-timing-tool --list <input.mff>
      mff-timing-tool <input.mff> --code <event-code> --din <din-code> [--pair nearest|next|previous]

    Options:
      --list                 Print unique event codes from all Events*.xml files.
      --code <event-code>    Primary stimulus event code.
      --din <din-code>       Comparison/DIN event code.
      --pair <mode>          Pairing rule: nearest, next, previous. Default: nearest.
      -h, --help             Show this help.

    Matching is case-sensitive and uses the MFF <code> field.
    """
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-h", "--help":
            throw ToolError.helpRequested
        case "--list":
            options.list = true
        case "--code":
            index += 1
            options.code = try value(at: index, in: arguments, flag: argument)
        case "--din":
            index += 1
            options.din = try value(at: index, in: arguments, flag: argument)
        case "--pair":
            index += 1
            let rawValue = try value(at: index, in: arguments, flag: argument)
            guard let mode = PairMode(rawValue: rawValue) else {
                throw ToolError.usage("Unknown --pair mode '\(rawValue)'. Expected nearest, next, or previous.")
            }
            options.pairMode = mode
        default:
            if argument.hasPrefix("-") {
                throw ToolError.usage("Unknown flag: \(argument)")
            }
            guard options.inputURL == nil else {
                throw ToolError.usage("Unexpected extra argument: \(argument)")
            }
            options.inputURL = absoluteFileURL(argument)
        }
        index += 1
    }

    guard options.inputURL != nil else {
        throw ToolError.usage("Missing input .mff path.\n\n\(usage())")
    }

    if options.list {
        if options.code != nil || options.din != nil {
            throw ToolError.usage("--list cannot be combined with --code or --din.")
        }
    } else if options.code == nil || options.din == nil {
        throw ToolError.usage("Missing required --code and --din.\n\n\(usage())")
    }

    return options
}

func value(at index: Int, in arguments: [String], flag: String) throws -> String {
    guard arguments.indices.contains(index) else {
        throw ToolError.usage("Missing value for \(flag).")
    }
    return arguments[index]
}

func absoluteFileURL(_ path: String) -> URL {
    let url = URL(fileURLWithPath: path)
    return url.path.hasPrefix("/") ? url : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
}

func eventFiles(in mffURL: URL) throws -> [URL] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: mffURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw ToolError.invalidMFF(mffURL)
    }

    let contents = try FileManager.default.contentsOfDirectory(
        at: mffURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )

    let files = contents
        .filter { $0.lastPathComponent.hasPrefix("Events") && $0.pathExtension.lowercased() == "xml" }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

    guard !files.isEmpty else {
        throw ToolError.noEventFiles(mffURL)
    }
    return files
}

func loadEvents(from mffURL: URL) throws -> [MFFTimingEvent] {
    var allEvents: [MFFTimingEvent] = []
    for fileURL in try eventFiles(in: mffURL) {
        let parser = EventXMLParser(sourceFile: fileURL.lastPathComponent)
        let parsed = try parser.parse(url: fileURL, startingIndex: allEvents.count + 1)
        allEvents.append(contentsOf: parsed)
    }

    let sorted = allEvents.sorted { left, right in
        if left.beginDate == right.beginDate {
            return left.sourceFile.localizedStandardCompare(right.sourceFile) == .orderedAscending
        }
        return left.beginDate < right.beginDate
    }

    return sorted.enumerated().map { offset, event in
        MFFTimingEvent(
            index: offset + 1,
            sourceFile: event.sourceFile,
            beginDate: event.beginDate,
            rawBeginTime: event.rawBeginTime,
            durationMicroseconds: event.durationMicroseconds,
            code: event.code,
            label: event.label,
            eventDescription: event.eventDescription,
            sourceDevice: event.sourceDevice,
            keys: event.keys
        )
    }
}

func listEvents(_ events: [MFFTimingEvent]) {
    print("code\tcount\tsource_xml\tlabels\tdescriptions\tsource_devices\tkey_names")
    let grouped = Dictionary(grouping: events, by: \.code)

    for code in grouped.keys.sorted(by: localizedLessThan) {
        guard let matchingEvents = grouped[code] else { continue }
        print([
            code,
            String(matchingEvents.count),
            uniqueJoined(matchingEvents.map(\.sourceFile)),
            uniqueJoined(matchingEvents.compactMap(\.label)),
            uniqueJoined(matchingEvents.compactMap(\.eventDescription)),
            uniqueJoined(matchingEvents.compactMap(\.sourceDevice)),
            uniqueJoined(matchingEvents.flatMap { $0.keys.keys })
        ].joined(separator: "\t"))
    }
}

func printOffsets(events: [MFFTimingEvent], code: String, din: String, pairMode: PairMode) throws {
    let codeEvents = events.filter { $0.code == code }
    let dinEvents = events.filter { $0.code == din }

    guard !codeEvents.isEmpty else { throw ToolError.missingEvents(code) }
    guard !dinEvents.isEmpty else { throw ToolError.missingEvents(din) }

    print("code_index\tcode_time\tcode_xml\tdin_index\tdin_time\tdin_xml\tdelta_ms")
    var deltas: [Double] = []

    for event in codeEvents {
        guard let matched = match(event: event, candidates: dinEvents, mode: pairMode) else {
            continue
        }
        let deltaMilliseconds = matched.beginDate.timeIntervalSince(event.beginDate) * 1000.0
        deltas.append(deltaMilliseconds)
        print([
            String(event.index),
            event.rawBeginTime,
            event.sourceFile,
            String(matched.index),
            matched.rawBeginTime,
            matched.sourceFile,
            format(deltaMilliseconds, digits: 3)
        ].joined(separator: "\t"))
    }

    if deltas.isEmpty {
        print("\nNo pairings found for --pair \(pairMode.rawValue).")
        return
    }

    let mean = deltas.reduce(0, +) / Double(deltas.count)
    let median = median(deltas)
    let mode = modeValue(deltas)

    print("")
    print("summary")
    print("code\t\(code)")
    print("din\t\(din)")
    print("pair\t\(pairMode.rawValue)")
    print("pairs\t\(deltas.count)")
    print("mean_ms\t\(format(mean, digits: 3))")
    print("median_ms\t\(format(median, digits: 3))")
    print("mode_ms\t\(mode ?? "n/a")")
    print("")
    printFrequencyTable(deltas)
}

func match(event: MFFTimingEvent, candidates: [MFFTimingEvent], mode: PairMode) -> MFFTimingEvent? {
    switch mode {
    case .nearest:
        return candidates.min {
            abs($0.beginDate.timeIntervalSince(event.beginDate)) < abs($1.beginDate.timeIntervalSince(event.beginDate))
        }
    case .next:
        return candidates
            .filter { $0.beginDate >= event.beginDate }
            .min { $0.beginDate < $1.beginDate }
    case .previous:
        return candidates
            .filter { $0.beginDate <= event.beginDate }
            .max { $0.beginDate < $1.beginDate }
    }
}

func parseMFFDate(_ text: String) -> Date? {
    let formatterWithFraction = ISO8601DateFormatter()
    formatterWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatterWithFraction.date(from: text) {
        return date
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
}

func formatKeys(_ keys: [String: String]) -> String {
    keys.keys.sorted().map { "\($0)=\(keys[$0] ?? "")" }.joined(separator: ";")
}

func uniqueJoined<S: Sequence>(_ values: S) -> String where S.Element == String {
    Array(Set(values.filter { !$0.isEmpty }))
        .sorted(by: localizedLessThan)
        .joined(separator: ";")
}

func localizedLessThan(_ left: String, _ right: String) -> Bool {
    left.localizedStandardCompare(right) == .orderedAscending
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2.0
    }
    return sorted[middle]
}

func modeValue(_ values: [Double]) -> String? {
    frequencyRows(values).first?.value
}

func printFrequencyTable(_ values: [Double]) {
    let rows = frequencyRows(values)
    let topRows = Array(rows.prefix(5))
    let otherCount = rows.dropFirst(5).reduce(0) { $0 + $1.count }

    print("frequency_table")
    print("delta_ms\tcount\tpercent")
    for row in topRows {
        print("\(row.value)\t\(row.count)\t\(format(percent(row.count, total: values.count), digits: 1))")
    }
    if otherCount > 0 {
        print("other\t\(otherCount)\t\(format(percent(otherCount, total: values.count), digits: 1))")
    }
}

func frequencyRows(_ values: [Double]) -> [(value: String, count: Int)] {
    let counts = Dictionary(grouping: values.map { format($0, digits: 3) }, by: { $0 })
        .mapValues(\.count)

    return counts.sorted { left, right in
        if left.value == right.value {
            return (Double(left.key) ?? 0) < (Double(right.key) ?? 0)
        }
        return left.value > right.value
    }
    .map { (value: $0.key, count: $0.value) }
}

func percent(_ count: Int, total: Int) -> Double {
    guard total > 0 else { return 0 }
    return Double(count) / Double(total) * 100.0
}

func format(_ value: Double, digits: Int) -> String {
    String(format: "%.\(digits)f", value)
}

func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

func localName(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init) ?? name
}

func run() throws -> Int32 {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    let events = try loadEvents(from: options.inputURL!)
    guard !events.isEmpty else { throw ToolError.noEvents }

    if options.list {
        listEvents(events)
    } else {
        try printOffsets(events: events, code: options.code!, din: options.din!, pairMode: options.pairMode)
    }

    return 0
}

do {
    exit(try run())
} catch ToolError.helpRequested {
    print(usage())
    exit(0)
} catch ToolError.usage(let message) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data(("Error: \(error.localizedDescription)\n").utf8))
    exit(1)
}
