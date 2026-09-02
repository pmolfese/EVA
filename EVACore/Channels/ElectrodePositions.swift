//
//  ElectrodePositions.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Digitized (or template) electrode positions in **metres**, with fiducials and
//  any extra head-shape points, and the readers for the files they come in:
//
//    EGI `coordinates.xml`  type 0 = EEG, 1 = reference, 2 = fiducial (cm)
//    BESA `.sfp`            `name x y z`, fiducials FidNz / FidT9 / FidT10
//    ASA `.elc`             `UnitPosition`, `Positions` block, `Labels` block
//    Cartool `.xyz`         count line, then `[index] x y z name`
//    CSV / TSV / TXT        header with label/name, x, y, z columns
//
//  Where a file states no unit, `Unit.auto` picks one from the head radius
//  (a head is ~0.09 m, ~9 cm, ~90 mm). Fiducial labels are recognized in the
//  conventions of each format plus the obvious aliases.
//
//  This is the raw input to coregistration (R2.3). EVA's older `ElectrodeGeometry`
//  (unit-sphere directions for spherical-spline interpolation) is a projection
//  of this; `toGeometry()` / `toMontage()` produce it, so the spherical forward
//  models keep working from the same source of truth.
//

import Foundation
import simd

nonisolated struct ElectrodePositions: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case eeg
        case reference
        case nasion
        case lpa
        case rpa
        case headShape
        case other
    }

    struct Point: Sendable, Equatable, Identifiable {
        var name: String
        var kind: Kind
        /// Metres, in the file's own frame.
        var position: SIMD3<Double>
        /// Zero-based channel index for EEG/reference sensors when the file
        /// carries one (EGI `number` − 1); nil otherwise.
        var channelIndex: Int?
        var id: String { "\(kind)-\(name)-\(channelIndex ?? -1)" }
    }

    enum Unit: String, Sendable, Codable, CaseIterable {
        case meters = "m"
        case centimeters = "cm"
        case millimeters = "mm"
        case auto

        var scaleToMeters: Double {
            switch self {
            case .meters: return 1
            case .centimeters: return 0.01
            case .millimeters: return 0.001
            case .auto: return 1
            }
        }
    }

    enum ReadError: LocalizedError, Equatable {
        case unsupportedFile(String)
        case cannotRead(String)
        case malformed(String)
        case noPositions

        var errorDescription: String? {
            switch self {
            case .unsupportedFile(let name): return "\(name) is not a supported electrode file (.xml, .sfp, .elc, .xyz, .csv, .tsv, .txt)."
            case .cannotRead(let name): return "Could not read \(name)."
            case .malformed(let why): return "Electrode file is malformed: \(why)"
            case .noPositions: return "No electrode positions were found."
            }
        }
    }

    var name: String
    var points: [Point]
    /// Frame the positions are expressed in; `.unknown` for anything that is not
    /// already in the fiducial-defined head frame.
    var frame: CoordinateFrame = .unknown

    var eeg: [Point] { points.filter { $0.kind == .eeg } }
    var nasion: SIMD3<Double>? { points.first { $0.kind == .nasion }?.position }
    var lpa: SIMD3<Double>? { points.first { $0.kind == .lpa }?.position }
    var rpa: SIMD3<Double>? { points.first { $0.kind == .rpa }?.position }
    var headShape: [SIMD3<Double>] { points.filter { $0.kind == .headShape }.map(\.position) }
    var hasFiducials: Bool { nasion != nil && lpa != nil && rpa != nil }

    var eegNames: [String] { eeg.map(\.name) }
    var eegPositions: [SIMD3<Double>] { eeg.map(\.position) }

    /// Typical head radius: median distance of EEG points from their centroid.
    var medianRadius: Double {
        let e = eegPositions
        guard !e.isEmpty else { return 0 }
        let c = e.reduce(.zero, +) / Double(e.count)
        let d = e.map { simd_length($0 - c) }.sorted()
        return d[d.count / 2]
    }

    /// Positions moved by a transform (frame updated to the transform's target).
    func transformed(by t: HeadTransform) -> ElectrodePositions {
        var out = self
        out.points = points.map { p in var q = p; q.position = t.apply(p.position); return q }
        out.frame = t.to
        return out
    }

    /// Same positions re-expressed in the fiducial-defined head frame (origin
    /// midway between LPA and RPA, +x toward RPA, +y toward the nasion, +z up).
    /// `nil` without all three fiducials.
    func inHeadFrame() -> ElectrodePositions? {
        guard let t = headFrameTransform() else { return nil }
        return transformed(by: t)
    }

    /// The transform from this file's frame to the head frame (MNE's
    /// `get_ras_to_neuromag_trans`), or nil without fiducials.
    func headFrameTransform() -> HeadTransform? {
        guard let nasion, let lpa, let rpa else { return nil }
        return HeadTransform.headFrame(nasion: nasion, lpa: lpa, rpa: rpa, from: frame)
    }

    // MARK: Conversions to EVA's spherical representations

    /// Unit-sphere directions about the EEG centroid, keyed by channel index
    /// (file order when the file has no channel numbers).
    func toGeometry() -> ElectrodeGeometry {
        let e = eeg
        let centre = e.isEmpty ? SIMD3<Double>(0, 0, 0) : e.map(\.position).reduce(.zero, +) / Double(e.count)
        var positions: [Int: SIMD3<Double>] = [:]
        var names: [Int: String] = [:]
        for (order, p) in e.enumerated() {
            let index = p.channelIndex ?? order
            let v = p.position - centre
            let length = simd_length(v)
            guard length > 0 else { continue }
            positions[index] = v / length
            names[index] = p.name
        }
        return ElectrodeGeometry(name: name, positions: positions, channelNames: names)
    }

    func toMontage() throws -> Montage {
        let geometry = toGeometry()
        return try Montage.fromGeometry(geometry, channelCount: geometry.positions.count)
    }

    // MARK: Reading

    static func read(from url: URL, unit: Unit = .auto) throws -> ElectrodePositions {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        if lower.hasSuffix(".mff") {
            return try readEGI(from: url.appendingPathComponent("coordinates.xml"))
        }
        guard let data = try? Data(contentsOf: url) else { throw ReadError.cannotRead(name) }
        if lower.hasSuffix(".xml") { return try readEGI(data: data, name: name) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ReadError.cannotRead(name)
        }
        let base = (name as NSString).deletingPathExtension
        switch (lower as NSString).pathExtension {
        case "sfp": return try readSFP(text, name: base, unit: unit)
        case "elc": return try readELC(text, name: base, unit: unit)
        case "xyz": return try readCartoolXYZ(text, name: base, unit: unit)
        case "csv", "tsv", "txt": return try readDelimited(text, name: base, unit: unit)
        default: throw ReadError.unsupportedFile(name)
        }
    }

    // EGI coordinates.xml — centimetres; type 0 EEG, 1 reference, 2 fiducials.
    static func readEGI(from url: URL) throws -> ElectrodePositions {
        guard let data = try? Data(contentsOf: url) else { throw ReadError.cannotRead(url.lastPathComponent) }
        return try readEGI(data: data, name: url.deletingLastPathComponent().lastPathComponent)
    }

    static func readEGI(data: Data, name: String) throws -> ElectrodePositions {
        guard let parsed = EGISensorXMLParser.parse(data: data, requiresZ: true) else {
            throw ReadError.malformed("not an EGI coordinates.xml")
        }
        var points: [Point] = []
        for s in parsed.sensors {
            guard let z = s.z else { continue }
            let p = SIMD3(s.x, s.y, z) * Unit.centimeters.scaleToMeters
            let label = s.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch s.type {
            case 0:
                points.append(Point(name: label.isEmpty ? "E\(s.number)" : label, kind: .eeg, position: p, channelIndex: s.number - 1))
            case 1:
                points.append(Point(name: label.isEmpty ? "VREF" : label, kind: .reference, position: p, channelIndex: s.number - 1))
            case 2:
                let kind = fiducialKind(forEGI: s) ?? .other
                points.append(Point(name: label.isEmpty ? "fiducial \(s.number)" : label, kind: kind, position: p, channelIndex: nil))
            default:
                points.append(Point(name: label, kind: .other, position: p, channelIndex: nil))
            }
        }
        guard points.contains(where: { $0.kind == .eeg }) else { throw ReadError.noPositions }
        return ElectrodePositions(name: parsed.layoutName.isEmpty ? name : parsed.layoutName, points: points)
    }

    private static func fiducialKind(forEGI s: EGISensorXMLSensor) -> Kind? {
        switch s.identifier {
        case 2002: return .nasion
        case 2011: return .lpa
        case 2010: return .rpa
        default: return fiducialKind(forLabel: s.name ?? "")
        }
    }

    /// Fiducial aliases across formats. Anything else is `nil`.
    static func fiducialKind(forLabel raw: String) -> Kind? {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "_", with: " ")
        switch label {
        case "nz", "nas", "nasion", "fidnz", "fid nz": return .nasion
        case "lpa", "fidt9", "fid t9", "left periauricular point", "left preauricular point", "left pre-auricular point", "leftear", "left ear": return .lpa
        case "rpa", "fidt10", "fid t10", "right periauricular point", "right preauricular point", "right pre-auricular point", "rightear", "right ear": return .rpa
        default: return nil
        }
    }

    // BESA .sfp: "name x y z" per line; comments with #.
    static func readSFP(_ text: String, name: String, unit: Unit) throws -> ElectrodePositions {
        var points: [Point] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
            guard fields.count >= 4, let x = Double(fields[1]), let y = Double(fields[2]), let z = Double(fields[3]) else { continue }
            let label = String(fields[0])
            let kind = fiducialKind(forLabel: label) ?? .eeg
            points.append(Point(name: label, kind: kind, position: SIMD3(x, y, z), channelIndex: nil))
        }
        return try finish(name: name, points: points, unit: unit)
    }

    // ASA .elc
    static func readELC(_ text: String, name: String, unit: Unit) throws -> ElectrodePositions {
        var fileUnit: Unit? = nil
        var positions: [SIMD3<Double>] = []
        var labels: [String] = []
        var section = 0  // 0 header, 1 positions, 2 labels
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("unitposition") {
                let value = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init)?.lowercased()
                fileUnit = value.flatMap { Unit(rawValue: $0) }
                continue
            }
            if lower.hasPrefix("positions") { section = 1; continue }
            if lower.hasPrefix("labels") { section = 2; continue }
            if lower.hasPrefix("numberpositions") || lower.hasPrefix("referencelabel") { continue }
            switch section {
            case 1:
                // "x y z" or "label: x y z"
                var body = line
                if let colon = line.firstIndex(of: ":") { body = String(line[line.index(after: colon)...]) }
                let fields = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
                guard fields.count >= 3 else { continue }
                positions.append(SIMD3(fields[0], fields[1], fields[2]))
            case 2:
                labels += line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            default:
                continue
            }
        }
        guard positions.count == labels.count else {
            throw ReadError.malformed("\(positions.count) positions but \(labels.count) labels")
        }
        let points = zip(labels, positions).map { label, p in
            Point(name: label, kind: fiducialKind(forLabel: label) ?? .eeg, position: p, channelIndex: nil)
        }
        return try finish(name: name, points: points, unit: unit == .auto ? (fileUnit ?? .auto) : unit)
    }

    // Cartool .xyz: first line "<count> [scale]", then "x y z name".
    static func readCartoolXYZ(_ text: String, name: String, unit: Unit) throws -> ElectrodePositions {
        var points: [Point] = []
        var first = true
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if first { first = false; if Double(trimmed.split(separator: " ").first ?? "") != nil && trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).count <= 2 { continue } }
            var fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            // Some writers (and MNE's reader) put a running index first.
            if fields.count >= 5, Double(fields[0]) != nil, Double(fields[1]) != nil, Double(fields[2]) != nil, Double(fields[3]) != nil {
                fields.removeFirst()
            }
            guard fields.count >= 4, let x = Double(fields[0]), let y = Double(fields[1]), let z = Double(fields[2]) else { continue }
            let label = fields[3...].joined(separator: " ")
            points.append(Point(name: label, kind: fiducialKind(forLabel: label) ?? .eeg, position: SIMD3(x, y, z), channelIndex: nil))
        }
        return try finish(name: name, points: points, unit: unit)
    }

    // CSV / TSV / TXT with a header naming label/name, x, y, z columns.
    static func readDelimited(_ text: String, name: String, unit: Unit) throws -> ElectrodePositions {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let header = lines.first else { throw ReadError.noPositions }
        let separator: Character = header.contains("\t") ? "\t" : (header.contains(",") ? "," : " ")
        func split(_ s: String) -> [String] {
            s.split(whereSeparator: { separator == " " ? ($0 == " " || $0 == "\t") : $0 == separator }).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let columns = split(header).map { $0.lowercased() }
        guard let xi = columns.firstIndex(of: "x"), let yi = columns.firstIndex(of: "y"), let zi = columns.firstIndex(of: "z") else {
            throw ReadError.malformed("header must name x, y and z columns")
        }
        let li = columns.firstIndex { ["label", "name", "ch_name", "channel", "electrode", "site"].contains($0) } ?? 0
        var points: [Point] = []
        for line in lines.dropFirst() {
            let f = split(line)
            guard f.count > max(xi, yi, zi, li), let x = Double(f[xi]), let y = Double(f[yi]), let z = Double(f[zi]) else { continue }
            let label = f[li]
            points.append(Point(name: label, kind: fiducialKind(forLabel: label) ?? .eeg, position: SIMD3(x, y, z), channelIndex: nil))
        }
        return try finish(name: name, points: points, unit: unit)
    }

    private static func finish(name: String, points raw: [Point], unit: Unit) throws -> ElectrodePositions {
        guard raw.contains(where: { $0.kind == .eeg }) else { throw ReadError.noPositions }
        var resolved = unit
        if resolved == .auto {
            let e = raw.filter { $0.kind == .eeg }.map(\.position)
            let c = e.reduce(.zero, +) / Double(e.count)
            let d = e.map { simd_length($0 - c) }.sorted()
            let radius = d[d.count / 2]
            resolved = radius > 20 ? .millimeters : (radius > 2 ? .centimeters : .meters)
        }
        let scale = resolved.scaleToMeters
        var points = raw
        var eegIndex = 0
        for n in points.indices {
            points[n].position *= scale
            if points[n].kind == .eeg { points[n].channelIndex = eegIndex; eegIndex += 1 }
        }
        return ElectrodePositions(name: name, points: points)
    }
}

extension HeadTransform {
    /// The fiducial-defined head frame (Neuromag / MNE "head"): origin midway
    /// between LPA and RPA, +x through RPA, +y toward the nasion (orthogonalized),
    /// +z superior. Maps points expressed in `from` into `.head`.
    static func headFrame(nasion: SIMD3<Double>, lpa: SIMD3<Double>, rpa: SIMD3<Double>, from: CoordinateFrame = .unknown) -> HeadTransform {
        let origin = (lpa + rpa) / 2
        let x = simd_normalize(rpa - lpa)
        let yRaw = nasion - origin
        let y = simd_normalize(yRaw - simd_dot(yRaw, x) * x)
        let z = simd_cross(x, y)
        // Rows of the rotation are the new axes: p_head = R (p − origin).
        let r = simd_double3x3(rows: [x, y, z])
        return rotation(r, translation: -(r * origin), from: from, to: .head)
    }
}
