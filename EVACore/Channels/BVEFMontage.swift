//
//  BVEFMontage.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
// BrainVision Electrode File: signed polar Theta, azimuth Phi (degrees), Radius.
// +x is right, +y anterior, +z superior. Conversion checked against MNE-Python's
// read_custom_montage (BSD-3-Clause); see THIRD_PARTY_NOTICES.md.

import Foundation
import simd

nonisolated enum BVEFError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

nonisolated enum ElectrodeLocationMatching: String, CaseIterable, Identifiable, Sendable {
    case names = "Electrode names"
    case numbers = "Channel numbers"
    var id: String { rawValue }
}

nonisolated struct BVEFMontage: Sendable {
    struct Electrode: Sendable {
        let name: String
        let number: Int?
        /// Nil for Radius=0: the file explicitly provides no spatial location.
        let position: SIMD3<Double>?
    }
    struct Match: Identifiable, Sendable {
        let channelIndex: Int
        let recordingName: String
        let electrode: Electrode?
        var id: Int { channelIndex }
    }

    let sourceName: String
    let electrodes: [Electrode]

    static func read(from url: URL) throws -> BVEFMontage {
        try parse(Data(contentsOf: url), sourceName: url.lastPathComponent)
    }

    static func parse(_ data: Data, sourceName: String) throws -> BVEFMontage {
        // Coordinate files need no DTD/entities. Disable external resolution,
        // and reject declarations rather than accepting entity-expanded names.
        let declarationScan = String(decoding: data, as: UTF8.self).uppercased()
        guard !declarationScan.contains("<!DOCTYPE"), !declarationScan.contains("<!ENTITY") else {
            throw BVEFError.invalid("Electrode files with DTD or entity declarations are not supported.")
        }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let delegate = BVEFParser()
        parser.delegate = delegate
        guard parser.parse(), delegate.validRoot, delegate.failure == nil, !delegate.electrodes.isEmpty else {
            throw BVEFError.invalid(delegate.failure ?? "This is not a valid BrainVision electrode (.bvef) file.")
        }
        var names = Set<String>(), numbers = Set<Int>()
        for electrode in delegate.electrodes {
            guard names.insert(key(electrode.name)).inserted else {
                throw BVEFError.invalid("The electrode file contains duplicate names: \(electrode.name).")
            }
            if let number = electrode.number, !numbers.insert(number).inserted {
                throw BVEFError.invalid("The electrode file contains duplicate channel number \(number).")
            }
        }
        return BVEFMontage(sourceName: sourceName, electrodes: delegate.electrodes)
    }

    func matches(channelNames: [String], using matching: ElectrodeLocationMatching) throws -> [Match] {
        if matching == .names {
            let keys = channelNames.map(Self.key)
            guard Set(keys).count == keys.count else {
                throw BVEFError.invalid("Recording channel names are ambiguous. Match by channel numbers instead.")
            }
        }
        return channelNames.enumerated().map { index, name in
            let electrode = electrodes.first {
                matching == .names ? Self.key($0.name) == Self.key(name) : $0.number == index + 1
            }
            return Match(channelIndex: index, recordingName: name, electrode: electrode)
        }
    }

    func resolved(channelNames: [String], using matching: ElectrodeLocationMatching,
                  reference: ElectrodeGeometry.Reference? = nil) throws -> EEGLocationOverride {
        let matches = try matches(channelNames: channelNames, using: matching)
        var positions = Dictionary(uniqueKeysWithValues: matches.compactMap { match in
            match.electrode?.position.map { (match.channelIndex, $0) }
        })
        guard !positions.isEmpty else {
            throw BVEFError.invalid("No recording channels match electrodes with valid locations.")
        }
        // Retain existing acquisition-reference identity, without adding a
        // sample row or inventing a reference when the recording has none.
        let updatedReference = reference.map { existing in
            ElectrodeGeometry.Reference(
                channelIndex: existing.channelIndex, name: existing.name,
                position: electrodes.first { Self.key($0.name) == "REF" }?.position ?? existing.position
            )
        }
        if let reference = updatedReference, channelNames.indices.contains(reference.channelIndex) {
            positions[reference.channelIndex] = reference.position
        }
        let geometry = ElectrodeGeometry(name: sourceName, positions: positions,
                                         channelNames: Dictionary(uniqueKeysWithValues: channelNames.enumerated().map { ($0.offset, $0.element) }),
                                         reference: updatedReference)
        return EEGLocationOverride(sourceName: sourceName, matching: matching,
                                   channelNames: channelNames, geometry: geometry)
    }

    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .replacingOccurrences(of: "^EEG[ _-]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "-REF$", with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "")
    }
}

private nonisolated final class BVEFParser: NSObject, XMLParserDelegate {
    var validRoot = false
    var failure: String?
    var electrodes = [BVEFMontage.Electrode]()
    private var stack = [String]()
    private var fields = [String: String]()
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if stack.isEmpty { validRoot = elementName == "Electrodes" }
        stack.append(elementName)
        if stack == ["Electrodes", "Electrode"] { fields = [:] }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { if !stack.isEmpty { stack.removeLast() }; text = "" }
        if stack.count == 3, stack.prefix(2) == ["Electrodes", "Electrode"] {
            if fields[elementName] != nil { failure = "Repeated \(elementName) field in electrode entry." }
            fields[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard stack == ["Electrodes", "Electrode"] else { return }
        guard let name = fields["Name"], !name.isEmpty,
              let theta = fields["Theta"].flatMap(Double.init), theta.isFinite,
              let phi = fields["Phi"].flatMap(Double.init), phi.isFinite,
              let radius = fields["Radius"].flatMap(Double.init), radius.isFinite, radius >= 0,
              abs(theta) <= 180, abs(phi) <= 360 else {
            failure = "An electrode has missing or invalid Name, Theta, Phi, or Radius."
            return
        }
        let number = fields["Number"].flatMap(Int.init)
        if fields["Number"] != nil, number == nil || number! <= 0 {
            failure = "Electrode \(name) has an invalid channel number."
            return
        }
        let polar = theta * .pi / 180, azimuth = phi * .pi / 180
        let position = radius == 0 ? nil : SIMD3<Double>(sin(polar) * cos(azimuth), sin(polar) * sin(azimuth), cos(polar))
        electrodes.append(BVEFMontage.Electrode(name: name, number: number, position: position))
    }
}

/// Recording-local replacement geometry. Labels, order, and samples are never
/// changed. Missing/zero-radius locations remove the old coordinates rather
/// than retaining an unrelated net's positions for unmatched channels.
nonisolated struct EEGLocationOverride: Sendable {
    let sourceName: String
    let matching: ElectrodeLocationMatching
    let channelNames: [String]
    let geometry: ElectrodeGeometry
    var layoutOverride: SensorLayout? = nil

    static let importRecordName = "eva_locations.json"

    static func hasExplicit2DLayout(inPackage url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent(importRecordName)),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return record["version"] as? Int == 1 && record["dimension"] as? Int == 2
    }

    var layout: SensorLayout {
        if let layoutOverride { return layoutOverride }
        let entries = geometry.positions.filter { $0.key != geometry.reference?.channelIndex }.sorted { $0.key < $1.key }
        let centerX = entries.map { $0.value.x }.reduce(0, +) / Double(max(entries.count, 1))
        let centerY = entries.map { $0.value.y }.reduce(0, +) / Double(max(entries.count, 1))
        let scale = entries.map { hypot($0.value.x - centerX, $0.value.y - centerY) }.max().flatMap { $0 > 0 ? $0 : nil } ?? 1
        return SensorLayout(name: sourceName, positions: entries.map {
            SensorPosition(channelIndex: $0.key, x: ($0.value.x - centerX) / scale, y: ($0.value.y - centerY) / scale)
        }, reference: geometry.reference.map {
            SensorReference(channelIndex: $0.channelIndex, name: $0.name,
                            x: ($0.position.x - centerX) / scale, y: ($0.position.y - centerY) / scale)
        })
    }

    var auditLine: String {
        "electrode locations: source=\(sourceName); matching=\(matching.rawValue); dimension=\(layoutOverride == nil ? "3D" : "2D"); located=\(layoutOverride?.positions.count ?? geometry.positions.count)/\(channelNames.count); recording labels and sample order preserved"
    }

    /// The exporter calls this after writing signal data. Every signal channel
    /// remains enumerated for other MFF readers, even if it has no coordinates.
    /// sensorLayout is 2D with EGI's inverted y; coordinates is 3D in head axes.
    func write(toPackage url: URL, signal: MFFSignalData) throws {
        guard signal.numberOfChannels >= channelNames.count,
              signal.channelNames == nil || Array(signal.channelNames!.prefix(channelNames.count)) == channelNames else {
            throw BVEFError.invalid("Channel order changed after importing electrode locations. Import the locations again before exporting.")
        }
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        if let layoutOverride {
            let points = Dictionary(uniqueKeysWithValues: layoutOverride.positions.map { ($0.channelIndex, $0) })
            let reference = layoutOverride.reference
            var sensors = ""
            func sensor(index: Int, name: String, type: Int, x: Double?, y: Double?) -> String {
                let xy = x.flatMap { x in y.map { "<x>\(x)</x><y>\(-$0)</y><z>0</z>" } } ?? ""
                return "<sensor><name>\(escape(name))</name><number>\(index + 1)</number><type>\(type)</type>\(xy)</sensor>\n"
            }
            for index in 0..<signal.numberOfChannels {
                let name = signal.channelNames?.indices.contains(index) == true ? signal.channelNames![index] : "E\(index + 1)"
                if let reference, reference.channelIndex == index {
                    sensors += sensor(index: index, name: name, type: 1, x: reference.x, y: reference.y)
                } else {
                    sensors += sensor(index: index, name: name, type: 0, x: points[index]?.x, y: points[index]?.y)
                }
            }
            if let reference, reference.channelIndex >= signal.numberOfChannels {
                sensors += sensor(index: reference.channelIndex, name: reference.name, type: 1, x: reference.x, y: reference.y)
            }
            let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><sensorLayout xmlns=\"http://www.egi.com/sensorLayout_mff\"><name>\(escape(sourceName))</name><sensors>\(sensors)</sensors></sensorLayout>"
            try xml.write(to: url.appendingPathComponent("sensorLayout.xml"), atomically: true, encoding: .utf8)
            let coordinates = url.appendingPathComponent("coordinates.xml")
            if FileManager.default.fileExists(atPath: coordinates.path) { try FileManager.default.removeItem(at: coordinates) }
            try writeImportRecord(toPackage: url)
            return
        }
        let reference = geometry.reference
        var flat = "", spatial = ""
        for index in 0..<signal.numberOfChannels {
            let name = signal.channelNames?.indices.contains(index) == true ? signal.channelNames![index] : "E\(index + 1)"
            let isReference = reference?.channelIndex == index
            let position = isReference ? reference?.position : geometry.positions[index]
            let start = "<sensor><name>\(escape(name))</name><number>\(index + 1)</number><type>\(isReference ? 1 : 0)</type>"
            let xy = position.map { "<x>\($0.x)</x><y>\(-$0.y)</y><z>0</z>" } ?? ""
            flat += start + xy + "</sensor>\n"
            let vector = position ?? .zero
            // Keep names/numbers for non-spatial channels in coordinates.xml
            // too. A zero vector is deliberately ignored by ElectrodeGeometry.
            spatial += start + "<x>\(vector.x)</x><y>\(vector.y)</y><z>\(vector.z)</z></sensor>\n"
        }
        if let reference, reference.channelIndex >= signal.numberOfChannels {
            let start = "<sensor><name>\(escape(reference.name))</name><number>\(reference.channelIndex + 1)</number><type>1</type>"
            flat += start + "<x>\(reference.position.x)</x><y>\(-reference.position.y)</y><z>0</z></sensor>\n"
            spatial += start + "<x>\(reference.position.x)</x><y>\(reference.position.y)</y><z>\(reference.position.z)</z></sensor>\n"
        }
        let title = "<name>\(escape(sourceName))</name><sensors>"
        let layoutXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><sensorLayout xmlns=\"http://www.egi.com/sensorLayout_mff\">\(title)\(flat)</sensors></sensorLayout>"
        let coordinatesXML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><coordinates xmlns=\"http://www.egi.com/coordinates_mff\">\(title)\(spatial)</sensors></coordinates>"
        try layoutXML.write(to: url.appendingPathComponent("sensorLayout.xml"), atomically: true, encoding: .utf8)
        try coordinatesXML.write(to: url.appendingPathComponent("coordinates.xml"), atomically: true, encoding: .utf8)
        try writeImportRecord(toPackage: url)
    }

    private func writeImportRecord(toPackage url: URL) throws {
        let record: [String: Any] = ["version": 1, "dimension": layoutOverride == nil ? 3 : 2,
                                     "sourceName": sourceName, "matching": matching.rawValue]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            .write(to: url.appendingPathComponent(Self.importRecordName), options: .atomic)
    }
}
