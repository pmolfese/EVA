//
//  ElectrodeLocationFile.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation
import simd

/// The Channels importer's common preview/matching model. MFF flat layouts do
/// not imply a 3D position: their y axis is inverted, unlike coordinates.xml.
nonisolated struct ElectrodeLocationFile: Sendable {
    enum Format: Sendable, Equatable {
        case brainVision, mffCoordinates, mffLayout
    }
    struct Electrode: Sendable {
        let name: String
        let number: Int?
        let position: SIMD3<Double>?
        let plotPosition: SIMD2<Double>?
        let isReference: Bool
        var hasLocation: Bool { position != nil || plotPosition != nil }
    }
    struct Match: Identifiable, Sendable {
        let channelIndex: Int
        let recordingName: String
        let electrode: Electrode?
        var id: Int { channelIndex }
    }

    let sourceName: String
    let format: Format
    let electrodes: [Electrode]
    var layoutName: String? = nil

    var formatDescription: String {
        switch format {
        case .brainVision: return "BrainVision 3D electrode locations"
        case .mffCoordinates: return "MFF 3D electrode coordinates"
        case .mffLayout: return "MFF 2D scalp layout · no 3D coordinates for interpolation"
        }
    }

    static func read(from url: URL) throws -> ElectrodeLocationFile {
        try parse(Data(contentsOf: url), sourceName: url.lastPathComponent)
    }

    static func parse(_ data: Data, sourceName: String) throws -> ElectrodeLocationFile {
        let scan = String(decoding: data, as: UTF8.self).uppercased()
        guard !scan.contains("<!DOCTYPE"), !scan.contains("<!ENTITY") else {
            throw BVEFError.invalid("Electrode files with DTD or entity declarations are not supported.")
        }
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement() else {
            throw BVEFError.invalid("The electrode XML file has no root element.")
        }
        func tag(_ element: XMLElement) -> String { element.localName ?? element.name ?? "" }
        if tag(root) == "Electrodes" {
            let bvef = try BVEFMontage.parse(data, sourceName: sourceName)
            return ElectrodeLocationFile(sourceName: sourceName, format: .brainVision,
                electrodes: bvef.electrodes.map {
                    Electrode(name: $0.name, number: $0.number, position: $0.position,
                              plotPosition: nil, isReference: BVEFMontage.key($0.name) == "REF")
                })
        }
        let format: Format
        switch tag(root) {
        case "coordinates": format = .mffCoordinates
        case "sensorLayout": format = .mffLayout
        default:
            throw BVEFError.invalid("Choose a BrainVision .bvef file, MFF coordinates.xml, or MFF sensorLayout.xml.")
        }
        // Native coordinates.xml nests the layout under <sensorLayout>;
        // older EVA exports also used a direct <sensors> container.
        let layoutElement = format == .mffCoordinates
            ? ((root.children ?? []).compactMap { $0 as? XMLElement }.first { tag($0) == "sensorLayout" } ?? root)
            : root
        let container = (layoutElement.children ?? []).compactMap { $0 as? XMLElement }.first { tag($0) == "sensors" }
        guard let container else { throw BVEFError.invalid("The MFF location file has no sensors section.") }
        var electrodes = [Electrode]()
        var numbers = Set<Int>(), names = Set<String>()
        for sensor in (container.children ?? []).compactMap({ $0 as? XMLElement }) where tag(sensor) == "sensor" {
            var fields = [String: String]()
            for field in (sensor.children ?? []).compactMap({ $0 as? XMLElement }) {
                let key = tag(field)
                guard fields[key] == nil else { throw BVEFError.invalid("Repeated \(key) field in MFF sensor entry.") }
                fields[key] = (field.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let type = fields["type"].flatMap(Int.init), type >= 0 else {
                throw BVEFError.invalid("An MFF sensor has an invalid type.")
            }
            // Fiducials, COM and net landmarks are not recording electrodes.
            guard type == 0 || type == 1 else { continue }
            guard let number = fields["number"].flatMap(Int.init), number > 0, numbers.insert(number).inserted else {
                throw BVEFError.invalid("MFF electrode numbers must be positive and unique.")
            }
            let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? "E\(number)"
            guard names.insert(BVEFMontage.key(name)).inserted else {
                throw BVEFError.invalid("The MFF location file contains duplicate electrode name \(name).")
            }
            func value(_ key: String) throws -> Double? {
                guard let text = fields[key] else { return nil }
                guard let result = Double(text), result.isFinite else {
                    throw BVEFError.invalid("Invalid \(key) coordinate for MFF electrode \(name).")
                }
                return result
            }
            let x = try value("x"), y = try value("y"), z = try value("z")
            var position: SIMD3<Double>?, plotPosition: SIMD2<Double>?
            if x != nil || y != nil || z != nil {
                guard let x, let y else { throw BVEFError.invalid("Missing x/y coordinates for MFF electrode \(name).") }
                if format == .mffCoordinates {
                    guard let z else { throw BVEFError.invalid("Missing z coordinate for MFF electrode \(name).") }
                    let vector = SIMD3(x, y, z)
                    // Normalize robustly even for very large finite coordinates.
                    let scale = max(abs(x), abs(y), abs(z))
                    if scale > 0 { position = simd_normalize(vector / scale) }
                } else {
                    // A flat (0,0) is a valid center electrode, not a missing
                    // location. Ignore layout z rather than inventing 3D data.
                    plotPosition = SIMD2(x, -y)
                }
            }
            electrodes.append(Electrode(name: name, number: number, position: position,
                                         plotPosition: plotPosition, isReference: type == 1))
        }
        guard !electrodes.isEmpty, electrodes.contains(where: \.hasLocation) else {
            throw BVEFError.invalid("The MFF file contains no EEG electrode locations.")
        }
        let netName = (layoutElement.children ?? []).compactMap { $0 as? XMLElement }.first { tag($0) == "name" }?
            .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ElectrodeLocationFile(sourceName: sourceName, format: format, electrodes: electrodes,
                                     layoutName: netName.flatMap { $0.isEmpty ? nil : $0 })
    }

    func matches(channelNames: [String], using matching: ElectrodeLocationMatching) throws -> [Match] {
        if matching == .names, Set(channelNames.map(BVEFMontage.key)).count != channelNames.count {
            throw BVEFError.invalid("Recording channel names are ambiguous. Match by channel numbers instead.")
        }
        return channelNames.enumerated().map { index, name in
            Match(channelIndex: index, recordingName: name, electrode: electrodes.first {
                matching == .names ? BVEFMontage.key($0.name) == BVEFMontage.key(name) : $0.number == index + 1
            })
        }
    }

    func resolved(channelNames: [String], using matching: ElectrodeLocationMatching,
                  reference: ElectrodeGeometry.Reference? = nil,
                  layoutReference: SensorReference? = nil) throws -> EEGLocationOverride {
        let spatialReference = reference ?? layoutReference.flatMap { existing in
            electrodes.first(where: \.isReference)?.position.map {
                ElectrodeGeometry.Reference(channelIndex: existing.channelIndex, name: existing.name, position: $0)
            }
        }
        if format == .brainVision {
            let bvef = BVEFMontage(sourceName: sourceName, electrodes: electrodes.map {
                BVEFMontage.Electrode(name: $0.name, number: $0.number, position: $0.position)
            })
            return try bvef.resolved(channelNames: channelNames, using: matching, reference: spatialReference)
        }
        let matches = try matches(channelNames: channelNames, using: matching)
        guard matches.contains(where: { $0.electrode?.hasLocation == true }) else {
            throw BVEFError.invalid("No recording channels match electrodes with valid locations.")
        }
        let labels = Dictionary(uniqueKeysWithValues: channelNames.enumerated().map { ($0.offset, $0.element) })
        if format == .mffCoordinates {
            var positions = Dictionary(uniqueKeysWithValues: matches.compactMap { match in
                match.electrode?.position.map { (match.channelIndex, $0) }
            })
            let updatedReference = spatialReference.map { existing in
                ElectrodeGeometry.Reference(channelIndex: existing.channelIndex, name: existing.name,
                    position: electrodes.first(where: \.isReference)?.position ?? existing.position)
            }
            if let reference = updatedReference, channelNames.indices.contains(reference.channelIndex) {
                positions[reference.channelIndex] = reference.position
            }
            return EEGLocationOverride(sourceName: sourceName, matching: matching, channelNames: channelNames,
                geometry: ElectrodeGeometry(name: layoutName ?? sourceName, positions: positions, channelNames: labels, reference: updatedReference))
        }
        let rawPoints = matches.compactMap { match -> SensorPosition? in
            guard let point = match.electrode?.plotPosition else { return nil }
            return SensorPosition(channelIndex: match.channelIndex, x: point.x, y: point.y)
        }
        let coordinateScale = rawPoints.map { max(abs($0.x), abs($0.y)) }.max().flatMap { $0 > 0 ? $0 : nil } ?? 1
        let points = rawPoints.map {
            SensorPosition(channelIndex: $0.channelIndex, x: $0.x / coordinateScale, y: $0.y / coordinateScale)
        }
        let centerPoints = points.filter { $0.channelIndex != layoutReference?.channelIndex }
        let divisor = Double(max(1, centerPoints.count))
        let centerX = centerPoints.map(\.x).reduce(0, +) / divisor
        let centerY = centerPoints.map(\.y).reduce(0, +) / divisor
        let radius = centerPoints.map { hypot($0.x - centerX, $0.y - centerY) }.max().flatMap { $0 > 0 ? $0 : nil } ?? 1
        let updatedReference = layoutReference.map { existing in
            let point = electrodes.first(where: \.isReference)?.plotPosition
            return SensorReference(channelIndex: existing.channelIndex, name: existing.name,
                x: point.map { ($0.x / coordinateScale - centerX) / radius } ?? existing.x,
                y: point.map { ($0.y / coordinateScale - centerY) / radius } ?? existing.y)
        }
        let layout = SensorLayout(name: layoutName ?? sourceName, positions: points.filter { $0.channelIndex != layoutReference?.channelIndex }.map {
            SensorPosition(channelIndex: $0.channelIndex, x: ($0.x - centerX) / radius, y: ($0.y - centerY) / radius)
        }, reference: updatedReference)
        return EEGLocationOverride(sourceName: sourceName, matching: matching, channelNames: channelNames,
            geometry: ElectrodeGeometry(name: layoutName ?? sourceName, positions: [:]), layoutOverride: layout)
    }
}
