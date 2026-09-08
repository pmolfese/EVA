//
//  OpenMEEGGeometry.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  OpenMEEG's native head-model description (EVA_RESOLVE2.md R3.1): a `.geom`
//  naming one mesh file per interface, a `.cond` giving each domain's
//  conductivity, and the meshes themselves in `.tri`, `.off` or `.bnd`.
//
//  This exists so a head model built in OpenMEEG can be imported without a
//  round trip through MNE, and so EVA can hand a model it is holding back to
//  `om_assemble`. It is a *file format* reader and writer only — OpenMEEG is
//  GPL-3 and is never linked or copied from; nothing here derives from its
//  source. Formats per the OpenMEEG documentation.
//
//  Two conventions, both established by experiment against OpenMEEG 2.5.15
//  (`Tools/forward-compare/check_swift_openmeeg.py`):
//
//  * **Units.** OpenMEEG files are conventionally in millimetres, EVA is in
//    metres, so the reader auto-detects from the model's extent unless told.
//  * **Triangle winding is the opposite of MNE's.** Handing OpenMEEG a mesh
//    wound the way MNE writes it (outward normals, positive signed volume) makes
//    it announce "Global reorientation of interface …" and assemble a head matrix
//    that differs by ~3e-4; reversing the winding leaves it silent. The per-vertex
//    normals in a `.tri` are ignored — only the winding is read. So the writer
//    reverses on the way out, and the reader normalizes whatever it is given back
//    to EVA's outward convention, which is what every quality gate and forward
//    model here assumes.
//

import Foundation
import simd

nonisolated enum OpenMEEGGeometry {

    enum Error: LocalizedError, Sendable, Equatable {
        case unreadable(String)
        case unsupportedMesh(String)
        case missingMesh(String)
        case noInterfaces
        case conductivityMissing(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let what): return "The OpenMEEG file could not be read: \(what)"
            case .unsupportedMesh(let ext): return "Unsupported OpenMEEG mesh format \".\(ext)\"; EVA reads .tri, .off and .bnd."
            case .missingMesh(let name): return "The .geom refers to a mesh file that is not next to it: \(name)"
            case .noInterfaces: return "The .geom declares no interfaces."
            case .conductivityMissing(let name): return "The .cond gives no conductivity for domain \"\(name)\"."
            }
        }
    }

    /// A mesh plus the name the `.geom` gave its interface, in file order.
    struct Interface: Sendable {
        var name: String
        var mesh: TriangleMesh
        var file: String
    }

    // MARK: - Reading

    /// Reads a `.geom` (and, when it sits alongside, the matching `.cond`) into
    /// an EVA head model.
    ///
    /// Interfaces are matched to EVA's compartment ids by *name* where OpenMEEG's
    /// conventional names are used (cortex/brain, skull, scalp/head/skin), and by
    /// size otherwise: the interfaces nest, so ordering them by enclosed volume
    /// is unambiguous.
    static func readGeometry(at url: URL, conductivities condURL: URL? = nil,
                             unit: ElectrodePositions.Unit = .auto) throws -> BEMGeometry {
        let interfaces = try readInterfaces(at: url, unit: unit)
        guard !interfaces.isEmpty else { throw Error.noInterfaces }

        let condFile = condURL ?? url.deletingPathExtension().appendingPathExtension("cond")
        let domains = try readDomains(at: url)
        let sigmas = FileManager.default.fileExists(atPath: condFile.path)
            ? try readConductivities(at: condFile) : [:]

        // Order inner → outer by enclosed volume; nested shells make this exact.
        let ordered = interfaces.enumerated().sorted { $0.element.mesh.areaAndVolume.volume < $1.element.mesh.areaAndVolume.volume }
        var surfaces: [BEMSurface] = []
        for (position, entry) in ordered.enumerated() {
            let kind = compartment(named: entry.element.name, position: position, of: ordered.count)
            let sigma = try conductivity(forInterface: entry.element.name, kind: kind,
                                         domains: domains, conductivities: sigmas)
            surfaces.append(BEMSurface(kind: kind, sigma: sigma, frame: .mri, mesh: entry.element.mesh))
        }
        var provenance = BEMGeometry.Provenance(sourceFile: url.lastPathComponent, format: "OpenMEEG .geom")
        provenance.note = sigmas.isEmpty
            ? "No .cond file found next to the .geom; conductivities defaulted to the standard 0.33 / 0.0042 / 0.33 S/m."
            : nil
        return try BEMGeometry(surfaces: surfaces, provenance: provenance)
    }

    /// The meshes a `.geom` names, in declaration order, in metres.
    static func readInterfaces(at url: URL, unit: ElectrodePositions.Unit = .auto) throws -> [Interface] {
        let text = try string(at: url)
        let directory = url.deletingLastPathComponent()
        var interfaces: [Interface] = []
        var inInterfaces = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("interfaces") { inInterfaces = true; continue }
            if lower.hasPrefix("domains") { inInterfaces = false; continue }
            if lower.hasPrefix("meshfile") || lower.hasPrefix("meshes") { inInterfaces = true; continue }
            guard inInterfaces else { continue }

            // "Interface Cortex: cortex.tri", "Interface: cortex.tri", or a bare
            // "cortex.tri" (the 1.0 format).
            var name = ""
            var fileToken = line
            if lower.hasPrefix("interface") {
                let body = line.dropFirst("interface".count).trimmingCharacters(in: .whitespaces)
                if let colon = body.firstIndex(of: ":") {
                    name = String(body[body.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                    fileToken = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    fileToken = body
                }
            }
            fileToken = fileToken.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            // A shared-vertices geometry lists mesh *names*, not paths; skip a
            // token with no recognizable mesh extension rather than guessing.
            let ext = (fileToken as NSString).pathExtension.lowercased()
            guard ["tri", "off", "bnd"].contains(ext) else { continue }
            let meshURL = directory.appendingPathComponent(fileToken)
            guard FileManager.default.fileExists(atPath: meshURL.path) else { throw Error.missingMesh(fileToken) }
            if name.isEmpty { name = (fileToken as NSString).deletingPathExtension }
            interfaces.append(Interface(name: name, mesh: try readMesh(at: meshURL, unit: unit), file: fileToken))
        }
        return interfaces
    }

    /// How a domain sits against one of its bounding interfaces. OpenMEEG's sign
    /// convention: `-Interface` means the domain is *inside* that interface,
    /// `+Interface` that it is outside. Keeping the sign is what makes the
    /// conductivity lookup unambiguous — "Cortex" bounds both the brain (inside)
    /// and the skull compartment (outside), and only one of them is the sigma FIF
    /// wants.
    struct DomainBound: Sendable, Equatable {
        var interface: String
        var inside: Bool
    }

    /// Domain name → the interfaces bounding it, with their signs.
    static func readDomains(at url: URL) throws -> [String: [DomainBound]] {
        let text = try string(at: url)
        var domains: [String: [DomainBound]] = [:]
        var inDomains = false
        var current: String? = nil
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("domains") { inDomains = true; continue }
            if lower.hasPrefix("interfaces") { inDomains = false; continue }
            guard inDomains else { continue }
            if lower.hasPrefix("domain") {
                let body = line.dropFirst("domain".count).trimmingCharacters(in: .whitespaces)
                let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                current = name
                domains[name] = bounds(in: parts.count > 1 ? String(parts[1]) : "")
            } else if let name = current {
                domains[name, default: []] += bounds(in: line)
            }
        }
        return domains
    }

    private static func bounds(in text: String) -> [DomainBound] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { token in
            let inside = token.hasPrefix("-")
            let name = token.trimmingCharacters(in: CharacterSet(charactersIn: "+-\"'"))
            return name.isEmpty ? nil : DomainBound(interface: name, inside: inside)
        }
    }

    /// Domain name → conductivity, from a `.cond`.
    static func readConductivities(at url: URL) throws -> [String: Double] {
        let text = try string(at: url)
        var result: [String: Double] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.lowercased().hasPrefix("air") { result["Air"] = 0; continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let value = Double(parts[parts.count - 1]) else { continue }
            let name = parts.dropLast().joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ": \t"))
            result[name] = value
        }
        return result
    }

    // MARK: - Meshes

    static func readMesh(at url: URL, unit: ElectrodePositions.Unit = .auto) throws -> TriangleMesh {
        let ext = url.pathExtension.lowercased()
        let mesh: TriangleMesh
        switch ext {
        case "tri": mesh = try readTRI(at: url)
        case "off": mesh = try readOFF(at: url)
        case "bnd": mesh = try readBND(at: url)
        default: throw Error.unsupportedMesh(ext)
        }
        return outwardOriented(scaled(mesh, unit: unit))
    }

    /// EVA's convention is outward normals (positive signed volume). OpenMEEG's
    /// `.tri` winding is the other way round, and `.off` / `.bnd` files in the
    /// wild go both ways, so normalize rather than guess from the extension.
    static func outwardOriented(_ mesh: TriangleMesh) -> TriangleMesh {
        guard mesh.areaAndVolume.volume < 0 else { return mesh }
        var flipped = mesh
        flipped.triangles = mesh.triangles.map { SIMD3($0.x, $0.z, $0.y) }
        flipped.vertexNormals = nil
        return flipped
    }

    /// OpenMEEG `.tri`: `- np`, then np lines of `x y z [nx ny nz]`, then
    /// `- nt nt nt`, then nt lines of vertex indices.
    static func readTRI(at url: URL) throws -> TriangleMesh {
        let lines = try string(at: url).components(separatedBy: .newlines)
        var vertices: [SIMD3<Double>] = []
        var triangles: [SIMD3<Int32>] = []
        var expecting = 0        // 0 = header, 1 = vertices, 2 = triangles
        var remaining = 0
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // A section header is "- 642"; a vertex line can also start with a
            // minus sign ("-44.687 72.305 0.0 ..."), so require the rest of the
            // line to be whole numbers before treating it as a header.
            let afterDash = line.hasPrefix("-") ? line.dropFirst().trimmingCharacters(in: .whitespaces) : ""
            let headerCounts = afterDash.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { Int($0) }
            if line.hasPrefix("-"), !headerCounts.isEmpty, !headerCounts.contains(where: { $0 == nil }) {
                let counts = headerCounts.compactMap { $0 }
                guard let count = counts.first else { throw Error.unreadable("bad count line \"\(line)\" in \(url.lastPathComponent)") }
                expecting += 1
                remaining = count
                if expecting == 1 { vertices.reserveCapacity(count) } else { triangles.reserveCapacity(count) }
                continue
            }
            guard remaining > 0 else { continue }
            let values = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
            if expecting == 1 {
                guard values.count >= 3 else { throw Error.unreadable("vertex line \"\(line)\"") }
                vertices.append(SIMD3(values[0], values[1], values[2]))
            } else if expecting == 2 {
                guard values.count >= 3 else { throw Error.unreadable("triangle line \"\(line)\"") }
                triangles.append(SIMD3(Int32(values[0]), Int32(values[1]), Int32(values[2])))
            }
            remaining -= 1
        }
        guard !vertices.isEmpty, !triangles.isEmpty else { throw Error.unreadable("no mesh in \(url.lastPathComponent)") }
        return TriangleMesh(vertices: vertices, triangles: triangles)
    }

    /// Geomview OFF: `OFF`, then `nv nf ne`, then vertices, then `3 i j k` faces.
    static func readOFF(at url: URL) throws -> TriangleMesh {
        var tokens = try string(at: url).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !tokens.isEmpty else { throw Error.unreadable("empty OFF file") }
        if tokens[0].uppercased().hasPrefix("OFF") {
            let rest = tokens[0].dropFirst(3).trimmingCharacters(in: .whitespaces)
            tokens[0] = rest
            if rest.isEmpty { tokens.removeFirst() }
        }
        let counts = tokens[0].split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Int($0) }
        guard counts.count >= 2 else { throw Error.unreadable("OFF header \"\(tokens[0])\"") }
        let nv = counts[0], nf = counts[1]
        guard tokens.count >= 1 + nv + nf else { throw Error.unreadable("OFF file is short") }
        var vertices: [SIMD3<Double>] = []
        vertices.reserveCapacity(nv)
        for i in 0..<nv {
            let v = tokens[1 + i].split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
            guard v.count >= 3 else { throw Error.unreadable("OFF vertex \(i)") }
            vertices.append(SIMD3(v[0], v[1], v[2]))
        }
        var triangles: [SIMD3<Int32>] = []
        triangles.reserveCapacity(nf)
        for i in 0..<nf {
            let f = tokens[1 + nv + i].split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Int($0) }
            guard f.count >= 4, f[0] == 3 else { throw Error.unreadable("OFF face \(i) is not a triangle") }
            triangles.append(SIMD3(Int32(f[1]), Int32(f[2]), Int32(f[3])))
        }
        return TriangleMesh(vertices: vertices, triangles: triangles)
    }

    /// ASA `.bnd`: `NumberPositions=`, `Positions`, `NumberPolygons=`, `Polygons`
    /// (1-based indices).
    static func readBND(at url: URL) throws -> TriangleMesh {
        let lines = try string(at: url).components(separatedBy: .newlines)
        var vertices: [SIMD3<Double>] = []
        var triangles: [SIMD3<Int32>] = []
        var section = 0          // 1 = positions, 2 = polygons
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("positions") { section = 1; continue }
            if lower.hasPrefix("polygons") { section = 2; continue }
            if lower.contains("=") || lower.hasPrefix("type") { continue }
            let values = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
            if section == 1, values.count >= 3 {
                vertices.append(SIMD3(values[0], values[1], values[2]))
            } else if section == 2, values.count >= 3 {
                triangles.append(SIMD3(Int32(values[0]) - 1, Int32(values[1]) - 1, Int32(values[2]) - 1))
            }
        }
        guard !vertices.isEmpty, !triangles.isEmpty else { throw Error.unreadable("no mesh in \(url.lastPathComponent)") }
        return TriangleMesh(vertices: vertices, triangles: triangles)
    }

    // MARK: - Writing

    /// Writes `<name>.geom`, `<name>.cond` and one `.tri` per shell into
    /// `directory`, in millimetres — what `om_assemble` expects. Returns the
    /// `.geom` URL.
    @discardableResult
    static func write(_ geometry: BEMGeometry, to directory: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // OpenMEEG's own convention is outer first in the domain listing; the
        // interfaces themselves may be declared in any order, so keep EVA's
        // inner → outer and let the domains express the nesting.
        var interfaceNames: [String] = []
        for shell in geometry.shells {
            let interfaceName = shell.kind.openMEEGName
            interfaceNames.append(interfaceName)
            let meshURL = directory.appendingPathComponent("\(name)-\(interfaceName).tri")
            try writeTRI(shell.mesh, to: meshURL, scale: 1000)
        }

        var geom = "# Domain Description 1.1\n\nInterfaces \(interfaceNames.count)\n\n"
        for interfaceName in interfaceNames {
            geom += "Interface \(interfaceName): \"\(name)-\(interfaceName).tri\"\n"
        }
        geom += "\nDomains \(interfaceNames.count + 1)\n\n"
        // Innermost domain is bounded only by its own interface; each subsequent
        // domain sits between two; the outside is everything beyond the scalp.
        for (i, interfaceName) in interfaceNames.enumerated() {
            let domain = geometry.shells[i].kind.openMEEGDomain
            if i == 0 {
                geom += "Domain \(domain): -\(interfaceName)\n"
            } else {
                geom += "Domain \(domain): +\(interfaceNames[i - 1]) -\(interfaceName)\n"
            }
        }
        geom += "Domain Air: +\(interfaceNames.last ?? "")\n"

        var cond = "# Properties Description 1.0 (Conductivities)\n\nAir         0.0\n"
        for shell in geometry.shells {
            let domain = shell.kind.openMEEGDomain.padding(toLength: 12, withPad: " ", startingAt: 0)
            cond += domain + String(format: "%.6f\n", shell.sigma)
        }

        let geomURL = directory.appendingPathComponent("\(name).geom")
        try geom.write(to: geomURL, atomically: true, encoding: .utf8)
        try cond.write(to: directory.appendingPathComponent("\(name).cond"), atomically: true, encoding: .utf8)
        return geomURL
    }

    /// Writes a `.tri`. `reverseWinding` emits OpenMEEG's convention (the reverse
    /// of MNE's), which is what stops it reorienting the interface on load.
    static func writeTRI(_ mesh: TriangleMesh, to url: URL, scale: Double = 1,
                         reverseWinding: Bool = true) throws {
        var text = "- \(mesh.vertices.count)\n"
        let normals = mesh.normals
        for (i, v) in mesh.vertices.enumerated() {
            let n = normals[i]
            text += String(format: "%.6f %.6f %.6f %.6f %.6f %.6f\n", v.x * scale, v.y * scale, v.z * scale, n.x, n.y, n.z)
        }
        text += "- \(mesh.triangles.count) \(mesh.triangles.count) \(mesh.triangles.count)\n"
        for t in mesh.triangles {
            text += reverseWinding ? "\(t.x) \(t.z) \(t.y)\n" : "\(t.x) \(t.y) \(t.z)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private static func string(at url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        if let text = try? String(contentsOf: url, encoding: .isoLatin1) { return text }
        throw Error.unreadable(url.lastPathComponent)
    }

    /// OpenMEEG files are conventionally millimetres; a head in metres is ~0.1
    /// across and one in millimetres ~100, so the two are never ambiguous.
    private static func scaled(_ mesh: TriangleMesh, unit: ElectrodePositions.Unit) -> TriangleMesh {
        let factor: Double
        switch unit {
        case .meters: factor = 1
        case .centimeters: factor = 0.01
        case .millimeters: factor = 0.001
        case .auto:
            let (lo, hi) = mesh.boundingBox
            let extent = (hi - lo).max()
            factor = extent > 5 ? 0.001 : (extent > 0.5 ? 0.01 : 1)
        }
        guard factor != 1 else { return mesh }
        var scaledMesh = mesh
        scaledMesh.vertices = mesh.vertices.map { $0 * factor }
        scaledMesh.vertexNormals = nil
        return scaledMesh
    }

    private static func compartment(named name: String, position: Int, of count: Int) -> BEMSurface.Kind {
        let lower = name.lowercased()
        if lower.contains("scalp") || lower.contains("skin") || lower.contains("head") { return .head }
        if lower.contains("skull") || lower.contains("bone") { return .skull }
        if lower.contains("cortex") || lower.contains("brain") || lower.contains("inner") { return .brain }
        // Fall back on the nesting order.
        if position == count - 1 { return .head }
        return position == 0 ? .brain : .skull
    }

    /// The conductivity of the compartment *inside* an interface, which is what
    /// FIF's sigma means. OpenMEEG states conductivities per domain, so this
    /// looks for the domain bounded by this interface from the inside.
    private static func conductivity(forInterface name: String, kind: BEMSurface.Kind,
                                     domains: [String: [DomainBound]],
                                     conductivities: [String: Double]) throws -> Double {
        // The domain *inside* this interface, which is what FIF's sigma means.
        for (domain, bounds) in domains
        where bounds.contains(DomainBound(interface: name, inside: true)) {
            if let sigma = conductivities[domain], sigma > 0 { return sigma }
        }
        if let exact = conductivities[name], exact > 0 { return exact }
        for (domain, sigma) in conductivities where domain.lowercased() == kind.openMEEGDomain.lowercased() {
            return sigma
        }
        // Standard three-shell values, flagged in the provenance note.
        switch kind {
        case .brain: return 0.33
        case .skull: return 0.0042
        case .head: return 0.33
        }
    }
}

extension BEMSurface.Kind {
    /// OpenMEEG's conventional interface name for this boundary.
    nonisolated var openMEEGName: String {
        switch self {
        case .brain: return "Cortex"
        case .skull: return "Skull"
        case .head: return "Head"
        }
    }

    /// OpenMEEG's conventional name for the compartment *inside* this boundary.
    nonisolated var openMEEGDomain: String {
        switch self {
        case .brain: return "Brain"
        case .skull: return "Skull"
        case .head: return "Scalp"
        }
    }
}
