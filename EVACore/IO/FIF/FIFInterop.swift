//
//  FIFInterop.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  MNE-Python file interop on top of `FIFFile`:
//    -trans.fif        `HeadTransform` (head ↔ MRI), read and write
//    -fiducials.fif /  digitization points: fiducials, EEG, head shape, read and
//    -dig.fif          write (`ElectrodePositions` ↔ Isotrak block)
//    -bem.fif /        BEM / head surfaces, read and write (`BEMSurface`)
//    -head.fif
//

import Foundation
import simd

// MARK: - Transforms

extension HeadTransform {
    /// Reads the first coordinate-transform tag of an MNE `-trans.fif`.
    nonisolated static func readFIF(from url: URL) throws -> HeadTransform {
        let reader = try FIFReader(url: url)
        guard let tag = reader.first(kind: FIF.coordTrans) else { throw FIF.Error.missing("coordinate transform") }
        return try decode(tag)
    }

    nonisolated static func decode(_ tag: FIFTag) throws -> HeadTransform {
        guard tag.data.count >= 8 + 36 + 12 else { throw FIF.Error.truncated }
        let from = CoordinateFrame(rawValue: tag.intValue) ?? .unknown
        let to = CoordinateFrame(rawValue: Int(tag.int32(at: 4))) ?? .unknown
        var rows: [SIMD4<Double>] = []
        for r in 0..<3 {
            let base = 8 + r * 12
            rows.append(SIMD4(Double(tag.float32(at: base)), Double(tag.float32(at: base + 4)), Double(tag.float32(at: base + 8)), Double(tag.float32(at: 44 + r * 4))))
        }
        rows.append(SIMD4(0, 0, 0, 1))
        return HeadTransform(from: from, to: to, matrix: simd_double4x4(rows: rows))
    }

    /// The 104-byte FIFFT_COORD_TRANS_STRUCT payload: from, to, rot, move, invrot, invmove.
    func fifPayload() -> Data {
        var d = FIFWriter.bytes([Int32(from.rawValue), Int32(to.rawValue)])
        func block(_ m: simd_double4x4) -> Data {
            var rot: [Float] = []
            for r in 0..<3 { for c in 0..<3 { rot.append(Float(m[c][r])) } }
            var out = FIFWriter.bytes(rot)
            out.append(FIFWriter.bytes([Float(m.columns.3.x), Float(m.columns.3.y), Float(m.columns.3.z)]))
            return out
        }
        d.append(block(matrix))
        d.append(block(matrix.inverse))
        return d
    }

    /// Writes an MNE-compatible `-trans.fif` (one coordinate-transform tag).
    func writeFIF(to url: URL) throws {
        var w = FIFWriter()
        w.startFile()
        w.write(kind: FIF.coordTrans, type: FIF.typeCoordTransStruct, payload: fifPayload())
        w.endFile()
        try w.save(to: url)
    }
}

// MARK: - Digitization

nonisolated struct DigPoint: Sendable, Equatable {
    enum Kind: Int32, Sendable { case cardinal = 1, hpi = 2, eeg = 3, extra = 4 }
    var kind: Kind
    /// Cardinal: 1 LPA, 2 nasion, 3 RPA. EEG: 1-based channel number.
    var ident: Int32
    /// Metres.
    var r: SIMD3<Double>
}

nonisolated struct Digitization: Sendable, Equatable {
    var frame: CoordinateFrame
    var points: [DigPoint]

    /// Reads the Isotrak block of a `-fiducials.fif` / `-dig.fif` / raw file.
    static func readFIF(from url: URL) throws -> Digitization {
        try read(FIFReader(url: url))
    }

    /// Same, from an already-open reader — a raw recording carries its
    /// digitization inside the measurement info, and re-reading the file to get
    /// at it would be silly.
    static func read(_ reader: FIFReader) throws -> Digitization {
        let block = reader.blocks(kind: FIF.blockIsotrak).first ?? reader.tags
        var frame = CoordinateFrame.unknown
        var points: [DigPoint] = []
        for tag in block {
            if tag.kind == FIF.mneCoordFrame { frame = CoordinateFrame(rawValue: tag.intValue) ?? .unknown }
            if tag.kind == FIF.digPoint, tag.data.count >= 20 {
                let kind = DigPoint.Kind(rawValue: tag.int32()) ?? .extra
                points.append(DigPoint(kind: kind, ident: tag.int32(at: 4),
                                       r: SIMD3(Double(tag.float32(at: 8)), Double(tag.float32(at: 12)), Double(tag.float32(at: 16)))))
            }
        }
        guard !points.isEmpty else { throw FIF.Error.missing("digitization points") }
        // An Isotrak block inside a recording's measurement info carries no
        // frame tag: FIF defines those points to be in head coordinates, and
        // that is what MNE assumes when it reads one. A standalone
        // `-fiducials.fif` / `-dig.fif` states its frame and keeps it.
        return Digitization(frame: frame == .unknown ? .head : frame, points: points)
    }

    func writeFIF(to url: URL) throws {
        var w = FIFWriter()
        w.startFile()
        append(to: &w)
        w.endFile()
        try w.save(to: url)
    }

    func append(to w: inout FIFWriter) {
        w.startBlock(FIF.blockIsotrak)
        w.writeInt(FIF.mneCoordFrame, Int32(frame.rawValue))
        for p in points {
            var payload = FIFWriter.bytes([p.kind.rawValue, p.ident])
            payload.append(FIFWriter.bytes([Float(p.r.x), Float(p.r.y), Float(p.r.z)]))
            w.write(kind: FIF.digPoint, type: FIF.typeDigPointStruct, payload: payload)
        }
        w.endBlock(FIF.blockIsotrak)
    }

    var nasion: SIMD3<Double>? { points.first { $0.kind == .cardinal && $0.ident == FIF.identNasion }?.r }
    var lpa: SIMD3<Double>? { points.first { $0.kind == .cardinal && $0.ident == FIF.identLPA }?.r }
    var rpa: SIMD3<Double>? { points.first { $0.kind == .cardinal && $0.ident == FIF.identRPA }?.r }
}

extension ElectrodePositions {
    /// EEG electrodes, fiducials and head-shape points as an MNE digitization.
    func digitization() -> Digitization {
        var points: [DigPoint] = []
        if let lpa { points.append(DigPoint(kind: .cardinal, ident: FIF.identLPA, r: lpa)) }
        if let nasion { points.append(DigPoint(kind: .cardinal, ident: FIF.identNasion, r: nasion)) }
        if let rpa { points.append(DigPoint(kind: .cardinal, ident: FIF.identRPA, r: rpa)) }
        for (n, e) in eeg.enumerated() { points.append(DigPoint(kind: .eeg, ident: Int32((e.channelIndex ?? n) + 1), r: e.position)) }
        for h in headShape { points.append(DigPoint(kind: .extra, ident: Int32(points.count), r: h)) }
        return Digitization(frame: frame, points: points)
    }

    /// Positions from an MNE digitization; EEG names are `EEG###` unless supplied.
    init(digitization d: Digitization, name: String, eegNames: [String]? = nil) {
        var points: [Point] = []
        for p in d.points {
            switch p.kind {
            case .cardinal:
                let kind: Kind = p.ident == FIF.identNasion ? .nasion : (p.ident == FIF.identLPA ? .lpa : .rpa)
                points.append(Point(name: kind == .nasion ? "Nasion" : (kind == .lpa ? "LPA" : "RPA"), kind: kind, position: p.r, channelIndex: nil))
            case .eeg:
                let index = Int(p.ident) - 1
                let label = eegNames.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? String(format: "EEG%03d", Int(p.ident))
                points.append(Point(name: label, kind: .eeg, position: p.r, channelIndex: index))
            case .extra:
                points.append(Point(name: "HSP\(p.ident)", kind: .headShape, position: p.r, channelIndex: nil))
            case .hpi:
                points.append(Point(name: "HPI\(p.ident)", kind: .other, position: p.r, channelIndex: nil))
            }
        }
        self.init(name: name, points: points, frame: d.frame)
    }

    static func readFIF(from url: URL, eegNames: [String]? = nil) throws -> ElectrodePositions {
        ElectrodePositions(digitization: try Digitization.readFIF(from: url), name: url.deletingPathExtension().lastPathComponent, eegNames: eegNames)
    }

    func writeFIF(to url: URL) throws { try digitization().writeFIF(to: url) }
}

// MARK: - BEM surfaces

nonisolated struct BEMSurface: Sendable {
    enum Kind: Int32, Sendable, CaseIterable {
        case brain = 1      // inner skull
        case skull = 3      // outer skull
        case head = 4       // outer skin

        var displayName: String {
            switch self {
            case .brain: return "inner skull"
            case .skull: return "outer skull"
            case .head: return "scalp"
            }
        }
    }

    var kind: Kind
    /// Conductivity, S/m.
    var sigma: Double
    var frame: CoordinateFrame
    var mesh: TriangleMesh

    /// Reads every surface of a `-bem.fif` or `-head.fif`, in file order.
    static func readFIF(from url: URL) throws -> [BEMSurface] {
        let reader = try FIFReader(url: url)
        let bemBlocks = reader.blocks(kind: FIF.blockBEM)
        let outer = bemBlocks.first ?? reader.tags
        let defaultFrame = outer.first { $0.kind == FIF.bemCoordFrame }.flatMap { CoordinateFrame(rawValue: $0.intValue) } ?? .unknown
        var surfaces: [BEMSurface] = []
        for block in reader.blocks(kind: FIF.blockBEMSurf) {
            func tag(_ k: Int32) -> FIFTag? { block.first { $0.kind == k } }
            let id = tag(FIF.bemSurfID).flatMap { Kind(rawValue: $0.int32()) } ?? .head
            let sigma = tag(FIF.bemSigma)?.floatValue ?? 1
            let frame = tag(FIF.bemCoordFrame).flatMap { CoordinateFrame(rawValue: $0.intValue) }
                ?? tag(FIF.mneCoordFrame).flatMap { CoordinateFrame(rawValue: $0.intValue) } ?? defaultFrame
            guard let nodesTag = tag(FIF.bemSurfNodes), let trisTag = tag(FIF.bemSurfTriangles) else {
                throw FIF.Error.missing("BEM surface nodes/triangles")
            }
            let nodes = try nodesTag.matrix()
            let tris = try trisTag.matrix()
            guard nodes.cols == 3, tris.cols == 3 else { throw FIF.Error.unexpected("BEM matrix shape \(nodes.cols)/\(tris.cols)") }
            var vertices = [SIMD3<Double>](repeating: .zero, count: nodes.rows)
            for n in 0..<nodes.rows {
                vertices[n] = SIMD3<Double>(nodes.values[n * 3], nodes.values[n * 3 + 1], nodes.values[n * 3 + 2])
            }
            var triangles = [SIMD3<Int32>](repeating: .zero, count: tris.rows)
            for n in 0..<tris.rows {
                let a = Int32(tris.values[n * 3]) - 1
                let b = Int32(tris.values[n * 3 + 1]) - 1
                let c = Int32(tris.values[n * 3 + 2]) - 1
                triangles[n] = SIMD3<Int32>(a, b, c)
            }
            var mesh = TriangleMesh(vertices: vertices, triangles: triangles)
            if let normalsTag = tag(FIF.bemSurfNormals), let n = try? normalsTag.matrix(), n.rows == vertices.count, n.cols == 3 {
                var normals = [SIMD3<Double>](repeating: .zero, count: n.rows)
                for i in 0..<n.rows { normals[i] = SIMD3<Double>(n.values[i * 3], n.values[i * 3 + 1], n.values[i * 3 + 2]) }
                mesh.vertexNormals = normals
            }
            surfaces.append(BEMSurface(kind: id, sigma: sigma, frame: frame, mesh: mesh))
        }
        guard !surfaces.isEmpty else { throw FIF.Error.missing("BEM surfaces") }
        return surfaces
    }

    /// Writes surfaces the way `mne.write_bem_surfaces` does (1-based triangles,
    /// normals included).
    static func writeFIF(_ surfaces: [BEMSurface], to url: URL) throws {
        var w = FIFWriter()
        w.startFile()
        w.startBlock(FIF.blockBEM)
        w.writeInt(FIF.bemCoordFrame, Int32(surfaces.first?.frame.rawValue ?? CoordinateFrame.mri.rawValue))
        for s in surfaces {
            w.startBlock(FIF.blockBEMSurf)
            w.writeInt(FIF.bemSurfID, s.kind.rawValue)
            w.writeFloat(FIF.bemSigma, Float(s.sigma))
            w.writeInt(FIF.bemSurfNNode, Int32(s.mesh.vertices.count))
            w.writeInt(FIF.bemSurfNTri, Int32(s.mesh.triangles.count))
            w.writeInt(FIF.mneCoordFrame, Int32(s.frame.rawValue))
            w.writeInt(FIF.bemCoordFrame, Int32(s.frame.rawValue))
            var nodeValues: [Float] = []
            nodeValues.reserveCapacity(s.mesh.vertices.count * 3)
            for v in s.mesh.vertices { nodeValues.append(Float(v.x)); nodeValues.append(Float(v.y)); nodeValues.append(Float(v.z)) }
            w.writeFloatMatrix(FIF.bemSurfNodes, rows: s.mesh.vertices.count, cols: 3, values: nodeValues)
            let normals = s.mesh.vertexNormals ?? s.mesh.computedVertexNormals()
            var normalValues: [Float] = []
            normalValues.reserveCapacity(normals.count * 3)
            for v in normals { normalValues.append(Float(v.x)); normalValues.append(Float(v.y)); normalValues.append(Float(v.z)) }
            w.writeFloatMatrix(FIF.bemSurfNormals, rows: normals.count, cols: 3, values: normalValues)
            var triValues: [Int32] = []
            triValues.reserveCapacity(s.mesh.triangles.count * 3)
            for t in s.mesh.triangles { triValues.append(t.x + 1); triValues.append(t.y + 1); triValues.append(t.z + 1) }
            w.writeIntMatrix(FIF.bemSurfTriangles, rows: s.mesh.triangles.count, cols: 3, values: triValues)
            w.endBlock(FIF.blockBEMSurf)
        }
        w.endBlock(FIF.blockBEM)
        w.endFile()
        try w.save(to: url)
    }
}
