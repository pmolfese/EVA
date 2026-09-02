//
//  FIFFile.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Minimal reader/writer for the FIF ("Functional Image File", Neuromag / MNE)
//  tag format — enough to exchange transforms, digitizations and BEM surfaces
//  with MNE-Python. A FIF file is a flat sequence of tags, each a big-endian
//  header (kind, type, size, next) followed by `size` bytes; block-start / block-
//  end tags nest them. Dense matrices carry their dimensions *after* the data:
//  `dims[last…first], ndim`. Reference: MNE-Python `mne/_fiff/{tag,write}.py`
//  (BSD-3), re-implemented here rather than copied.
//

import Foundation

nonisolated enum FIF {
    // Tag kinds
    static let fileID: Int32 = 100
    static let dirPointer: Int32 = 101
    static let blockStart: Int32 = 104
    static let blockEnd: Int32 = 105
    static let freeList: Int32 = 106
    static let nop: Int32 = 110
    static let digPoint: Int32 = 213
    static let coordTrans: Int32 = 222
    static let bemSurfID: Int32 = 3101
    static let bemSurfName: Int32 = 3102
    static let bemSurfNNode: Int32 = 3103
    static let bemSurfNTri: Int32 = 3104
    static let bemSurfNodes: Int32 = 3105
    static let bemSurfTriangles: Int32 = 3106
    static let bemSurfNormals: Int32 = 3107
    static let bemApprox: Int32 = 3108
    static let bemPotSolution: Int32 = 3110
    static let bemCoordFrame: Int32 = 3112
    static let bemSigma: Int32 = 3113
    static let mneCoordFrame: Int32 = 3506

    // Block kinds
    static let blockIsotrak: Int32 = 107
    static let blockBEM: Int32 = 310
    static let blockBEMSurf: Int32 = 311

    // Data types
    static let typeVoid: Int32 = 0
    static let typeInt: Int32 = 3
    static let typeFloat: Int32 = 4
    static let typeDouble: Int32 = 5
    static let typeString: Int32 = 10
    static let typeIDStruct: Int32 = 31
    static let typeDigPointStruct: Int32 = 33
    static let typeCoordTransStruct: Int32 = 35
    static let typeMatrixFlag: Int32 = 0x40000000

    // Dig point kinds / idents
    static let pointCardinal: Int32 = 1
    static let pointHPI: Int32 = 2
    static let pointEEG: Int32 = 3
    static let pointExtra: Int32 = 4
    static let identLPA: Int32 = 1
    static let identNasion: Int32 = 2
    static let identRPA: Int32 = 3

    // BEM surface ids
    static let surfBrain: Int32 = 1
    static let surfSkull: Int32 = 3
    static let surfHead: Int32 = 4

    static let version: Int32 = (1 << 16) | 3

    enum Error: LocalizedError {
        case truncated
        case notFIF
        case missing(String)
        case unexpected(String)

        var errorDescription: String? {
            switch self {
            case .truncated: return "The FIF file is truncated."
            case .notFIF: return "Not a FIF file (no file-id tag)."
            case .missing(let what): return "The FIF file has no \(what)."
            case .unexpected(let what): return "Unexpected FIF content: \(what)"
            }
        }
    }
}

nonisolated struct FIFTag: Sendable {
    let kind: Int32
    let type: Int32
    let data: Data
    /// Nesting depth and the innermost enclosing block kind at this tag.
    let blockPath: [Int32]

    var isMatrix: Bool { (type & FIF.typeMatrixFlag) != 0 }
    var baseType: Int32 { type & ~FIF.typeMatrixFlag }

    func int32(at offset: Int = 0) -> Int32 {
        Int32(bitPattern: UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }))
    }
    func float32(at offset: Int = 0) -> Float {
        Float(bitPattern: UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }))
    }
    func float64(at offset: Int = 0) -> Double {
        Double(bitPattern: UInt64(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }))
    }
    var intValue: Int { Int(int32()) }
    var floatValue: Double { baseType == FIF.typeDouble ? float64() : Double(float32()) }
    var stringValue: String { String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "" }

    /// Dense matrix: (rows, cols, row-major values as Double).
    func matrix() throws -> (rows: Int, cols: Int, values: [Double]) {
        guard isMatrix, data.count >= 4 else { throw FIF.Error.unexpected("tag \(kind) is not a matrix") }
        let ndim = Int(int32(at: data.count - 4))
        guard ndim == 2, data.count >= 4 * (ndim + 1) else { throw FIF.Error.unexpected("matrix tag \(kind) has \(ndim) dims") }
        // dims stored last-to-first: [cols, rows] just before ndim.
        let cols = Int(int32(at: data.count - 12))
        let rows = Int(int32(at: data.count - 8))
        let count = rows * cols
        var values = [Double](repeating: 0, count: count)
        switch baseType {
        case FIF.typeFloat:
            guard data.count >= count * 4 + 12 else { throw FIF.Error.truncated }
            for n in 0..<count { values[n] = Double(float32(at: n * 4)) }
        case FIF.typeDouble:
            guard data.count >= count * 8 + 12 else { throw FIF.Error.truncated }
            for n in 0..<count { values[n] = float64(at: n * 8) }
        case FIF.typeInt:
            guard data.count >= count * 4 + 12 else { throw FIF.Error.truncated }
            for n in 0..<count { values[n] = Double(int32(at: n * 4)) }
        default:
            throw FIF.Error.unexpected("matrix base type \(baseType)")
        }
        return (rows, cols, values)
    }
}

/// Whole-file tag list with block structure resolved.
nonisolated struct FIFReader: Sendable {
    let tags: [FIFTag]

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        var tags: [FIFTag] = []
        var path: [Int32] = []
        var position = 0
        var first = true
        while position + 16 <= data.count {
            func i32(_ o: Int) -> Int32 {
                Int32(bitPattern: UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }))
            }
            let kind = i32(position), type = i32(position + 4), size = Int(i32(position + 8)), next = Int(i32(position + 12))
            if first {
                guard kind == FIF.fileID else { throw FIF.Error.notFIF }
                first = false
            }
            guard size >= 0, position + 16 + size <= data.count else { throw FIF.Error.truncated }
            let payload = data.subdata(in: (position + 16)..<(position + 16 + size))
            let tag = FIFTag(kind: kind, type: type, data: payload, blockPath: path)
            if kind == FIF.blockStart { path.append(tag.int32()) }
            tags.append(tag)
            if kind == FIF.blockEnd, !path.isEmpty { path.removeLast() }
            if next == -1 { break }
            position = next > 0 ? next : position + 16 + size
        }
        guard !tags.isEmpty else { throw FIF.Error.notFIF }
        self.tags = tags
    }

    func first(kind: Int32) -> FIFTag? { tags.first { $0.kind == kind } }
    func all(kind: Int32) -> [FIFTag] { tags.filter { $0.kind == kind } }

    /// Top-level slices of tags for each block of the given kind (nested blocks included).
    func blocks(kind: Int32) -> [[FIFTag]] {
        var result: [[FIFTag]] = []
        var current: [FIFTag]? = nil
        var depth = 0
        for tag in tags {
            if current == nil {
                if tag.kind == FIF.blockStart, tag.int32() == kind { current = []; depth = 1 }
                continue
            }
            if tag.kind == FIF.blockStart { depth += 1 }
            if tag.kind == FIF.blockEnd {
                depth -= 1
                if depth == 0 { result.append(current!); current = nil; continue }
            }
            current!.append(tag)
        }
        return result
    }
}

/// Sequential FIF writer (no directory; `next` = 0 everywhere, NOP terminator).
nonisolated struct FIFWriter {
    private(set) var data = Data()

    mutating func write(kind: Int32, type: Int32, payload: Data, next: Int32 = 0) {
        for v in [kind, type, Int32(payload.count), next] {
            var be = v.bigEndian
            withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
        }
        data.append(payload)
    }

    static func bytes(_ values: [Int32]) -> Data {
        var d = Data(capacity: values.count * 4)
        for v in values { var be = v.bigEndian; withUnsafeBytes(of: &be) { d.append(contentsOf: $0) } }
        return d
    }

    static func bytes(_ values: [Float]) -> Data {
        var d = Data(capacity: values.count * 4)
        for v in values { var be = v.bitPattern.bigEndian; withUnsafeBytes(of: &be) { d.append(contentsOf: $0) } }
        return d
    }

    mutating func writeInt(_ kind: Int32, _ value: Int32) { write(kind: kind, type: FIF.typeInt, payload: Self.bytes([value])) }
    mutating func writeFloat(_ kind: Int32, _ value: Float) { write(kind: kind, type: FIF.typeFloat, payload: Self.bytes([value])) }
    mutating func writeString(_ kind: Int32, _ value: String) { write(kind: kind, type: FIF.typeString, payload: Data(value.utf8)) }

    /// Row-major float matrix.
    mutating func writeFloatMatrix(_ kind: Int32, rows: Int, cols: Int, values: [Float]) {
        precondition(values.count == rows * cols)
        var payload = Self.bytes(values)
        payload.append(Self.bytes([Int32(cols), Int32(rows), 2]))
        write(kind: kind, type: FIF.typeMatrixFlag | FIF.typeFloat, payload: payload)
    }

    mutating func writeIntMatrix(_ kind: Int32, rows: Int, cols: Int, values: [Int32]) {
        precondition(values.count == rows * cols)
        var payload = Self.bytes(values)
        payload.append(Self.bytes([Int32(cols), Int32(rows), 2]))
        write(kind: kind, type: FIF.typeMatrixFlag | FIF.typeInt, payload: payload)
    }

    mutating func startBlock(_ kind: Int32) { writeInt(FIF.blockStart, kind) }
    mutating func endBlock(_ kind: Int32) { writeInt(FIF.blockEnd, kind) }

    mutating func startFile() {
        let now = Date().timeIntervalSince1970
        let id: [Int32] = [FIF.version, Int32(truncatingIfNeeded: 0x45564120), Int32(truncatingIfNeeded: UInt32.random(in: 0...UInt32.max)), Int32(now), Int32((now - floor(now)) * 1e6)]
        write(kind: FIF.fileID, type: FIF.typeIDStruct, payload: Self.bytes(id))
        writeInt(FIF.dirPointer, -1)
        writeInt(FIF.freeList, -1)
    }

    mutating func endFile() {
        write(kind: FIF.nop, type: FIF.typeVoid, payload: Data(), next: -1)
    }

    func save(to url: URL) throws { try data.write(to: url) }
}
