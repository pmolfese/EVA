//
//  NIfTIVolume.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  A whole NIfTI volume in memory: the first 3-D volume of the file, scaled by
//  slope/intercept, stored x-fastest as `Float`, with its voxel→world affine.
//
//  ## Frames and units
//
//  NIfTI world coordinates are RAS+ (x→right, y→anterior, z→superior) in the
//  header's spatial unit — almost always millimetres. `affine` is kept in the
//  file's native unit converted to **millimetres** so it composes with other
//  imaging tools; `voxelToWorldMeters` is the same map in metres, which is what
//  EVA's forward models and `HeadTransform` use.
//
//  `canonicalized()` reorders and flips the voxel axes so the *voxel* grid is
//  also RAS+ (i→R, j→A, k→S) without resampling — the affine is updated so every
//  voxel keeps its world position. Anything that reasons about "left" from voxel
//  indices must go through this first; it is the guard against the classic
//  silently-mirrored head.
//
//  Writing produces single-file NIfTI-1 (`.nii`, or gzip when the path ends in
//  `.gz`), little-endian, with the affine in the sform (code 2, "aligned") and
//  pixdim from the voxel size. Round-trips through nibabel / MNE.
//

import Compression
import Foundation
import simd

nonisolated struct NIfTIVolume: Sendable {
    /// Header the volume was read from; `nil` for volumes built in memory.
    let header: NIfTIHeader?
    /// Voxel counts along i, j, k.
    let dimensions: SIMD3<Int>
    /// Voxel edge lengths in millimetres (always positive).
    let voxelSizeMillimeters: SIMD3<Double>
    /// Voxel index (i, j, k, 1) → world RAS+ millimetres. Column-major simd.
    let affine: simd_double4x4
    /// Free-text description carried to disk (NIfTI `descrip`, 79 bytes max).
    var descriptionText: String
    /// Voxel values, x-fastest: index = i + nx * (j + ny * k).
    var data: [Float]

    init(
        dimensions: SIMD3<Int>,
        affine: simd_double4x4,
        data: [Float],
        header: NIfTIHeader? = nil,
        descriptionText: String = ""
    ) {
        precondition(data.count == dimensions.x * dimensions.y * dimensions.z, "voxel count mismatch")
        self.dimensions = dimensions
        self.affine = affine
        self.data = data
        self.header = header
        self.descriptionText = descriptionText
        self.voxelSizeMillimeters = SIMD3(
            simd_length(SIMD3(affine.columns.0.x, affine.columns.0.y, affine.columns.0.z)),
            simd_length(SIMD3(affine.columns.1.x, affine.columns.1.y, affine.columns.1.z)),
            simd_length(SIMD3(affine.columns.2.x, affine.columns.2.y, affine.columns.2.z))
        )
    }

    /// An all-zero volume on the given grid.
    static func zeros(dimensions: SIMD3<Int>, affine: simd_double4x4) -> NIfTIVolume {
        NIfTIVolume(
            dimensions: dimensions, affine: affine,
            data: [Float](repeating: 0, count: dimensions.x * dimensions.y * dimensions.z))
    }

    /// A grid centred on the world origin with isotropic voxels (RAS+ axes).
    static func isotropicAffine(voxelSizeMillimeters s: Double, dimensions n: SIMD3<Int>) -> simd_double4x4 {
        var m = matrix_identity_double4x4
        m.columns.0 = SIMD4(s, 0, 0, 0)
        m.columns.1 = SIMD4(0, s, 0, 0)
        m.columns.2 = SIMD4(0, 0, s, 0)
        m.columns.3 = SIMD4(-s * Double(n.x - 1) / 2, -s * Double(n.y - 1) / 2, -s * Double(n.z - 1) / 2, 1)
        return m
    }

    var voxelCount: Int { data.count }
    var nx: Int { dimensions.x }
    var ny: Int { dimensions.y }
    var nz: Int { dimensions.z }

    @inline(__always) func index(_ i: Int, _ j: Int, _ k: Int) -> Int {
        i + nx * (j + ny * k)
    }

    subscript(i: Int, j: Int, k: Int) -> Float {
        get { data[index(i, j, k)] }
        set { data[index(i, j, k)] = newValue }
    }

    func contains(_ i: Int, _ j: Int, _ k: Int) -> Bool {
        i >= 0 && j >= 0 && k >= 0 && i < nx && j < ny && k < nz
    }

    // MARK: Frames

    /// The affine in metres (world) per voxel — what forward models consume.
    var voxelToWorldMeters: simd_double4x4 {
        var m = affine
        m.columns.0 = SIMD4(affine.columns.0.x / 1000, affine.columns.0.y / 1000, affine.columns.0.z / 1000, 0)
        m.columns.1 = SIMD4(affine.columns.1.x / 1000, affine.columns.1.y / 1000, affine.columns.1.z / 1000, 0)
        m.columns.2 = SIMD4(affine.columns.2.x / 1000, affine.columns.2.y / 1000, affine.columns.2.z / 1000, 0)
        m.columns.3 = SIMD4(affine.columns.3.x / 1000, affine.columns.3.y / 1000, affine.columns.3.z / 1000, 1)
        return m
    }

    /// World RAS+ millimetres → continuous voxel coordinates.
    var worldToVoxel: simd_double4x4 { affine.inverse }

    func voxelToWorld(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let p = affine * SIMD4(v.x, v.y, v.z, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    func worldToVoxel(_ w: SIMD3<Double>) -> SIMD3<Double> {
        let p = affine.inverse * SIMD4(w.x, w.y, w.z, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    /// World position of voxel centre (i, j, k), millimetres.
    func worldPosition(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Double> {
        voxelToWorld(SIMD3(Double(i), Double(j), Double(k)))
    }

    /// Trilinear sample at continuous voxel coordinates; 0 outside the grid.
    func sample(atVoxel v: SIMD3<Double>) -> Float {
        let i0 = Int(floor(v.x)), j0 = Int(floor(v.y)), k0 = Int(floor(v.z))
        let fx = Float(v.x - Double(i0)), fy = Float(v.y - Double(j0)), fz = Float(v.z - Double(k0))
        @inline(__always) func at(_ i: Int, _ j: Int, _ k: Int) -> Float {
            contains(i, j, k) ? data[index(i, j, k)] : 0
        }
        let c00 = at(i0, j0, k0) * (1 - fx) + at(i0 + 1, j0, k0) * fx
        let c10 = at(i0, j0 + 1, k0) * (1 - fx) + at(i0 + 1, j0 + 1, k0) * fx
        let c01 = at(i0, j0, k0 + 1) * (1 - fx) + at(i0 + 1, j0, k0 + 1) * fx
        let c11 = at(i0, j0 + 1, k0 + 1) * (1 - fx) + at(i0 + 1, j0 + 1, k0 + 1) * fx
        let c0 = c00 * (1 - fy) + c10 * fy
        let c1 = c01 * (1 - fy) + c11 * fy
        return c0 * (1 - fz) + c1 * fz
    }

    /// Trilinear sample at a world RAS+ millimetre position.
    func sample(atWorld w: SIMD3<Double>) -> Float {
        sample(atVoxel: worldToVoxel(w))
    }

    // MARK: Orientation

    /// Per voxel axis: which world axis it mostly runs along, and whether it
    /// increases with that axis. Greedy over the strongest components, so it is
    /// always a permutation even for oblique grids.
    var axisOrientations: [(worldAxis: Int, isPositive: Bool)] {
        let cols = [affine.columns.0, affine.columns.1, affine.columns.2]
        var result = [(worldAxis: Int, isPositive: Bool)](repeating: (0, true), count: 3)
        var usedWorld = Set<Int>(), usedVoxel = Set<Int>()
        for _ in 0..<3 {
            var best = (voxel: -1, world: -1, value: -1.0)
            for v in 0..<3 where !usedVoxel.contains(v) {
                for w in 0..<3 where !usedWorld.contains(w) {
                    let value = abs(cols[v][w] / voxelSizeMillimeters[v])
                    if value > best.value { best = (v, w, value) }
                }
            }
            result[best.voxel] = (best.world, cols[best.voxel][best.world] >= 0)
            usedVoxel.insert(best.voxel); usedWorld.insert(best.world)
        }
        return result
    }

    /// True when voxel axes already run i→R, j→A, k→S.
    var isCanonical: Bool {
        let o = axisOrientations
        return (0..<3).allSatisfy { o[$0].worldAxis == $0 && o[$0].isPositive }
    }

    /// The same voxels re-indexed so that i→R, j→A, k→S, with the affine updated
    /// so every voxel keeps its world position. No interpolation.
    func canonicalized() -> NIfTIVolume {
        if isCanonical { return self }
        let o = axisOrientations
        // newAxis w takes old voxel axis v where o[v].worldAxis == w.
        var oldAxisForNew = [0, 0, 0]
        for v in 0..<3 { oldAxisForNew[o[v].worldAxis] = v }
        let flips = (0..<3).map { !o[oldAxisForNew[$0]].isPositive }
        let oldDims = [nx, ny, nz]
        let newDims = SIMD3(oldDims[oldAxisForNew[0]], oldDims[oldAxisForNew[1]], oldDims[oldAxisForNew[2]])
        var out = [Float](repeating: 0, count: data.count)
        var oldIndex = [0, 0, 0]
        for k in 0..<newDims.z {
            for j in 0..<newDims.y {
                for i in 0..<newDims.x {
                    let newIndex = [i, j, k]
                    for w in 0..<3 {
                        let v = oldAxisForNew[w]
                        oldIndex[v] = flips[w] ? (oldDims[v] - 1 - newIndex[w]) : newIndex[w]
                    }
                    out[i + newDims.x * (j + newDims.y * k)] = data[index(oldIndex[0], oldIndex[1], oldIndex[2])]
                }
            }
        }
        // old voxel = M * new voxel (homogeneous); newAffine = affine * M.
        var m = matrix_identity_double4x4
        m.columns.0 = .zero; m.columns.1 = .zero; m.columns.2 = .zero; m.columns.3 = SIMD4(0, 0, 0, 1)
        for w in 0..<3 {
            let v = oldAxisForNew[w]
            var col = SIMD4<Double>(repeating: 0)
            col[v] = flips[w] ? -1 : 1
            switch w {
            case 0: m.columns.0 = col
            case 1: m.columns.1 = col
            default: m.columns.2 = col
            }
            if flips[w] { m.columns.3[v] = Double(oldDims[v] - 1) }
        }
        return NIfTIVolume(
            dimensions: newDims, affine: affine * m, data: out,
            header: header, descriptionText: descriptionText)
    }

    // MARK: Statistics

    func minMax() -> (min: Float, max: Float) {
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for v in data where v.isFinite {
            if v < lo { lo = v }
            if v > hi { hi = v }
        }
        return lo <= hi ? (lo, hi) : (0, 0)
    }

    /// Per-voxel map. Keeps grid and affine.
    func mapped(_ f: (Float) -> Float) -> NIfTIVolume {
        NIfTIVolume(dimensions: dimensions, affine: affine, data: data.map(f), header: header, descriptionText: descriptionText)
    }
}

// MARK: - Reading

extension NIfTIVolume {
    /// Reads the first 3-D volume of a `.nii` / `.nii.gz` file.
    static func read(from url: URL) throws -> NIfTIVolume {
        let lowerName = url.lastPathComponent.lowercased()
        guard lowerName.hasSuffix(".nii") || lowerName.hasSuffix(".nii.gz") else {
            throw NIfTIReadError.unsupportedFile(url)
        }
        let source: any NIfTIByteSource = lowerName.hasSuffix(".gz")
            ? try NIfTIGzipByteSource(url: url)
            : try NIfTIFileByteSource(url: url)

        let firstFour: Data
        do { firstFour = try source.readExactly(4) } catch { throw NIfTIReadError.truncatedHeader }
        let (version, byteOrder) = try NIfTIHeader.versionAndByteOrder(from: firstFour)
        let rest: Data
        do { rest = try source.readExactly(version.byteCount - 4) } catch { throw NIfTIReadError.truncatedHeader }
        var headerData = firstFour
        headerData.append(rest)
        let header = try NIfTIHeader.decode(headerData, version: version, byteOrder: byteOrder)
        try validate(header)
        try source.skip(header.voxelOffset - Int64(version.byteCount))

        let nx = header.width, ny = header.height, nz = header.depth
        let count = nx * ny * nz
        let bytesPerVoxel = header.bytesPerVoxel
        let slope = Float(header.effectiveSlope), intercept = Float(header.effectiveIntercept)
        var data = [Float](repeating: 0, count: count)
        let slabCount = nx * ny
        let slabBytes = slabCount * bytesPerVoxel
        for k in 0..<nz {
            let slab: Data
            do { slab = try source.readExactly(slabBytes) } catch { throw NIfTIReadError.truncatedVoxelData }
            let base = k * slabCount
            slab.withUnsafeBytes { bytes in
                decodeSlab(bytes, into: &data, at: base, count: slabCount, header: header, slope: slope, intercept: intercept)
            }
        }

        // Affine: header rows are in the file's spatial unit; normalize to mm.
        let unitScale: Double
        switch header.spatialUnit {
        case "m": unitScale = 1000
        case "µm": unitScale = 0.001
        default: unitScale = 1
        }
        let affine: simd_double4x4
        if let rows = header.affine?.rows, rows.count == 3, rows.allSatisfy({ $0.count == 4 }) {
            affine = simd_double4x4(rows: [
                SIMD4(rows[0].map { $0 * unitScale }),
                SIMD4(rows[1].map { $0 * unitScale }),
                SIMD4(rows[2].map { $0 * unitScale }),
                SIMD4(0, 0, 0, 1)
            ])
        } else {
            // No orientation information: voxel size only, origin at voxel 0.
            let px = header.pixelDimensions
            affine = simd_double4x4(diagonal: SIMD4(
                abs(px[safe: 1] ?? 1) * unitScale, abs(px[safe: 2] ?? 1) * unitScale,
                abs(px[safe: 3] ?? 1) * unitScale, 1))
        }
        return NIfTIVolume(
            dimensions: SIMD3(nx, ny, nz), affine: affine, data: data,
            header: header, descriptionText: header.description ?? "")
    }

    private static func validate(_ header: NIfTIHeader) throws {
        guard header.magic.hasPrefix("n+1") || header.magic.hasPrefix("ni1")
                || header.magic.hasPrefix("n+2") || header.magic.hasPrefix("ni2") else {
            throw NIfTIReadError.invalidMagic(header.magic)
        }
        guard header.isSingleFile else { throw NIfTIReadError.pairedFileUnsupported }
        guard (1...7).contains(header.dimensionCount), header.dimensions.count == 8,
              header.width > 0, header.height > 0, header.depth > 0 else {
            throw NIfTIReadError.invalidDimensions(header.dimensions)
        }
        guard let expectedBits = header.dataType.supportedScalarBitCount else {
            throw NIfTIReadError.unsupportedScalarType(header.dataType.displayName)
        }
        guard header.bitpix == expectedBits else {
            throw NIfTIReadError.invalidBitpix(expected: expectedBits, actual: header.bitpix)
        }
        guard header.voxelOffset >= Int64(header.version.byteCount) else {
            throw NIfTIReadError.invalidVoxelOffset(header.voxelOffset)
        }
    }

    private static func decodeSlab(
        _ bytes: UnsafeRawBufferPointer, into data: inout [Float], at base: Int, count: Int,
        header: NIfTIHeader, slope: Float, intercept: Float
    ) {
        let little = header.byteOrder == .littleEndian
        switch (header.dataType, little) {
        case (.float32, true):
            for n in 0..<count {
                let bits = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: n * 4, as: UInt32.self))
                data[base + n] = Float(bitPattern: bits) * slope + intercept
            }
        case (.int16, true):
            for n in 0..<count {
                let v = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: n * 2, as: Int16.self))
                data[base + n] = Float(v) * slope + intercept
            }
        case (.uint16, true):
            for n in 0..<count {
                let v = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: n * 2, as: UInt16.self))
                data[base + n] = Float(v) * slope + intercept
            }
        case (.uint8, _):
            for n in 0..<count { data[base + n] = Float(bytes[n]) * slope + intercept }
        default:
            let bpv = header.bytesPerVoxel
            for n in 0..<count {
                let v = NIfTIScalarDecoder.value(from: bytes, at: n * bpv, type: header.dataType, byteOrder: header.byteOrder)
                data[base + n] = Float(v) * slope + intercept
            }
        }
    }
}

// MARK: - Writing

extension NIfTIVolume {
    enum WriteDataType: Sendable {
        case float32, int16, uint8

        var code: Int16 {
            switch self {
            case .float32: return 16
            case .int16: return 4
            case .uint8: return 2
            }
        }
        var bitpix: Int16 {
            switch self {
            case .float32: return 32
            case .int16: return 16
            case .uint8: return 8
            }
        }
    }

    /// Writes single-file NIfTI-1, gzip-compressed when the name ends in `.gz`.
    /// The affine goes in the sform (code 2) and, when its rotation part is
    /// orthogonal, in the qform (code 1) too so strict readers agree.
    func write(to url: URL, dataType: WriteDataType = .float32) throws {
        var bytes = [UInt8](repeating: 0, count: 352)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { for (n, b) in $0.enumerated() { bytes[offset + n] = b } }
        }
        func putFloat(_ value: Float, at offset: Int) { put(value.bitPattern, at: offset) }
        func putString(_ s: String, at offset: Int, count: Int) {
            for (n, b) in s.utf8.prefix(count - 1).enumerated() { bytes[offset + n] = b }
        }
        put(Int32(348), at: 0)
        // dim
        put(Int16(3), at: 40)
        put(Int16(nx), at: 42); put(Int16(ny), at: 44); put(Int16(nz), at: 46)
        put(Int16(1), at: 48); put(Int16(1), at: 50); put(Int16(1), at: 52); put(Int16(1), at: 54)
        put(dataType.code, at: 70)
        put(dataType.bitpix, at: 72)
        // pixdim
        let q = qformParameters()
        putFloat(Float(q.qfac), at: 76)
        putFloat(Float(voxelSizeMillimeters.x), at: 80)
        putFloat(Float(voxelSizeMillimeters.y), at: 84)
        putFloat(Float(voxelSizeMillimeters.z), at: 88)
        putFloat(1, at: 92)
        putFloat(Float(352), at: 108)               // vox_offset
        putFloat(1, at: 112); putFloat(0, at: 116)  // scl_slope / scl_inter
        bytes[123] = 2 | 8                          // mm, s
        putString(descriptionText, at: 148, count: 80)
        // qform / sform
        put(Int16(q.valid ? 1 : 0), at: 252)
        put(Int16(2), at: 254)
        if q.valid {
            putFloat(Float(q.b), at: 256); putFloat(Float(q.c), at: 260); putFloat(Float(q.d), at: 264)
            putFloat(Float(affine.columns.3.x), at: 268)
            putFloat(Float(affine.columns.3.y), at: 272)
            putFloat(Float(affine.columns.3.z), at: 276)
        }
        let rows = [
            [affine.columns.0.x, affine.columns.1.x, affine.columns.2.x, affine.columns.3.x],
            [affine.columns.0.y, affine.columns.1.y, affine.columns.2.y, affine.columns.3.y],
            [affine.columns.0.z, affine.columns.1.z, affine.columns.2.z, affine.columns.3.z]
        ]
        for (r, row) in rows.enumerated() {
            for (c, value) in row.enumerated() { putFloat(Float(value), at: 280 + r * 16 + c * 4) }
        }
        putString("n+1", at: 344, count: 4)

        var payload = Data(bytes)
        switch dataType {
        case .float32:
            var buffer = [UInt32](repeating: 0, count: data.count)
            for (n, v) in data.enumerated() { buffer[n] = v.bitPattern.littleEndian }
            buffer.withUnsafeBytes { payload.append(contentsOf: $0) }
        case .int16:
            var buffer = [Int16](repeating: 0, count: data.count)
            for (n, v) in data.enumerated() { buffer[n] = Int16(max(-32768, min(32767, v.rounded()))).littleEndian }
            buffer.withUnsafeBytes { payload.append(contentsOf: $0) }
        case .uint8:
            payload.append(contentsOf: data.map { UInt8(max(0, min(255, $0.rounded()))) })
        }

        if url.lastPathComponent.lowercased().hasSuffix(".gz") {
            try GzipEncoder.gzip(payload).write(to: url)
        } else {
            try payload.write(to: url)
        }
    }

    /// Quaternion form of the affine's rotation, when it is a proper rotation
    /// times the voxel sizes (possibly with a flipped k axis via qfac).
    private func qformParameters() -> (valid: Bool, qfac: Double, b: Double, c: Double, d: Double) {
        var r = simd_double3x3(
            SIMD3(affine.columns.0.x, affine.columns.0.y, affine.columns.0.z) / voxelSizeMillimeters.x,
            SIMD3(affine.columns.1.x, affine.columns.1.y, affine.columns.1.z) / voxelSizeMillimeters.y,
            SIMD3(affine.columns.2.x, affine.columns.2.y, affine.columns.2.z) / voxelSizeMillimeters.z)
        let orthogonal = simd_almost_equal_elements(r.transpose * r, matrix_identity_double3x3, 1e-4)
        guard orthogonal else { return (false, 1, 0, 0, 0) }
        var qfac = 1.0
        if r.determinant < 0 {
            qfac = -1
            r.columns.2 = -r.columns.2
        }
        let quaternion = simd_quatd(r)
        let a = quaternion.real, v = quaternion.imag
        let sign: Double = a < 0 ? -1 : 1
        return (true, qfac, sign * v.x, sign * v.y, sign * v.z)
    }
}

/// Minimal gzip framing over Apple's raw-DEFLATE compressor.
nonisolated enum GzipEncoder {
    static func gzip(_ input: Data) throws -> Data {
        let deflated = try deflate(input)
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(deflated)
        var crc = crc32(input).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        var size = UInt32(truncatingIfNeeded: input.count).littleEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    private static func deflate(_ input: Data) throws -> Data {
        let capacity = max(64, input.count + input.count / 8 + 64)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = input.withUnsafeBytes { source -> Int in
            compression_encode_buffer(
                destination, capacity,
                source.bindMemory(to: UInt8.self).baseAddress!, input.count,
                nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else {
            // Incompressible: fall back to a stored deflate stream.
            return stored(input)
        }
        return Data(bytes: destination, count: written)
    }

    /// Raw deflate "stored" blocks (no compression), used only as a fallback.
    private static func stored(_ input: Data) -> Data {
        var out = Data()
        var offset = 0
        repeat {
            let len = min(65535, input.count - offset)
            let final: UInt8 = offset + len >= input.count ? 1 : 0
            out.append(final)
            var l = UInt16(len).littleEndian, n = (~UInt16(len)).littleEndian
            withUnsafeBytes(of: &l) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
            out.append(input.subdata(in: offset..<(offset + len)))
            offset += len
        } while offset < input.count
        return out
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
