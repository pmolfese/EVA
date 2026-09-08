//
//  VolumeMorphology.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Binary-volume morphology and the few scalar-volume operations head-model
//  segmentation needs: thresholds (fixed and Otsu), ball erosion/dilation,
//  connected components, hole filling, separable Gaussian smoothing, and
//  trilinear resampling to an isotropic grid. Plain loops over `[Float]` /
//  `[UInt8]`; volumes are a few million voxels, which these handle in well under
//  a second each. Nothing here knows about anatomy.
//

import Foundation
import simd

/// A 0/1 mask on the same grid as a `NIfTIVolume`.
nonisolated struct BinaryVolume: Sendable, Equatable {
    let dimensions: SIMD3<Int>
    var data: [UInt8]

    init(dimensions: SIMD3<Int>, data: [UInt8]) {
        precondition(data.count == dimensions.x * dimensions.y * dimensions.z)
        self.dimensions = dimensions
        self.data = data
    }

    static func empty(dimensions: SIMD3<Int>) -> BinaryVolume {
        BinaryVolume(dimensions: dimensions, data: [UInt8](repeating: 0, count: dimensions.x * dimensions.y * dimensions.z))
    }

    var nx: Int { dimensions.x }
    var ny: Int { dimensions.y }
    var nz: Int { dimensions.z }
    var voxelCount: Int { data.count }

    @inline(__always) func index(_ i: Int, _ j: Int, _ k: Int) -> Int { i + nx * (j + ny * k) }

    subscript(i: Int, j: Int, k: Int) -> Bool {
        get { data[index(i, j, k)] != 0 }
        set { data[index(i, j, k)] = newValue ? 1 : 0 }
    }

    func contains(_ i: Int, _ j: Int, _ k: Int) -> Bool {
        i >= 0 && j >= 0 && k >= 0 && i < nx && j < ny && k < nz
    }

    var count: Int { data.reduce(0) { $0 + Int($1) } }

    /// Voxel-index bounding box of the set voxels, or nil when empty.
    var boundingBox: (min: SIMD3<Int>, max: SIMD3<Int>)? {
        var lo = SIMD3(Int.max, Int.max, Int.max), hi = SIMD3(-1, -1, -1)
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where data[index(i, j, k)] != 0 {
            lo = pointwiseMin(lo, SIMD3(i, j, k)); hi = pointwiseMax(hi, SIMD3(i, j, k))
        } } }
        return hi.x >= 0 ? (lo, hi) : nil
    }

    /// Centre of mass in voxel coordinates.
    var centroid: SIMD3<Double>? {
        var sum = SIMD3<Double>(0, 0, 0); var n = 0
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where data[index(i, j, k)] != 0 {
            sum += SIMD3(Double(i), Double(j), Double(k)); n += 1
        } } }
        return n > 0 ? sum / Double(n) : nil
    }

    func inverted() -> BinaryVolume {
        BinaryVolume(dimensions: dimensions, data: data.map { $0 == 0 ? 1 : 0 })
    }

    func union(_ other: BinaryVolume) -> BinaryVolume {
        BinaryVolume(dimensions: dimensions, data: zip(data, other.data).map { $0 | $1 })
    }

    func intersection(_ other: BinaryVolume) -> BinaryVolume {
        BinaryVolume(dimensions: dimensions, data: zip(data, other.data).map { $0 & $1 })
    }

    func subtracting(_ other: BinaryVolume) -> BinaryVolume {
        BinaryVolume(dimensions: dimensions, data: zip(data, other.data).map { $0 & ($1 == 0 ? 1 : 0) })
    }

    /// As a float volume (1.0 inside) on `reference`'s grid.
    func asVolume(like reference: NIfTIVolume) -> NIfTIVolume {
        NIfTIVolume(dimensions: dimensions, affine: reference.affine, data: data.map { Float($0) })
    }

    // MARK: Morphology

    /// Offsets of a discrete ball of the given radius (voxels), origin excluded.
    static func ballOffsets(radius: Double) -> [SIMD3<Int>] {
        let r = Int(radius.rounded(.up))
        var out: [SIMD3<Int>] = []
        for k in -r...r { for j in -r...r { for i in -r...r {
            if i == 0 && j == 0 && k == 0 { continue }
            if Double(i * i + j * j + k * k) <= radius * radius + 1e-9 { out.append(SIMD3(i, j, k)) }
        } } }
        return out
    }

    /// Ball dilation with anisotropic voxels: the radius is in **voxels of each
    /// axis**, so pass `radiusMillimeters / voxelSize` per axis when the grid is
    /// not isotropic. Uses a boundary-only pass: only voxels on the mask's edge
    /// stamp the ball, which keeps large masks cheap.
    func dilated(radiusVoxels: SIMD3<Double>) -> BinaryVolume {
        let offsets = BinaryVolume.ellipsoidOffsets(radiusVoxels: radiusVoxels)
        var out = self
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where data[index(i, j, k)] != 0 {
            guard isBoundary(i, j, k) else { continue }
            for o in offsets {
                let x = i + o.x, y = j + o.y, z = k + o.z
                if contains(x, y, z) { out.data[index(x, y, z)] = 1 }
            }
        } } }
        return out
    }

    func dilated(radiusVoxels r: Double) -> BinaryVolume {
        dilated(radiusVoxels: SIMD3(r, r, r))
    }

    /// Ball erosion = dilation of the complement, with the grid edge counted as
    /// outside (mask voxels on the border are boundary voxels too).
    func eroded(radiusVoxels: SIMD3<Double>) -> BinaryVolume {
        let offsets = BinaryVolume.ellipsoidOffsets(radiusVoxels: radiusVoxels)
        var out = self
        // Stamp the ball from every background voxel adjacent to the mask …
        let complement = inverted()
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where complement.data[index(i, j, k)] != 0 {
            guard complement.isBoundary(i, j, k) else { continue }
            for o in offsets {
                let x = i + o.x, y = j + o.y, z = k + o.z
                if contains(x, y, z) { out.data[index(x, y, z)] = 0 }
            }
        } } }
        // … and from just outside the grid, for mask voxels on the border.
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where data[index(i, j, k)] != 0 {
            guard i == 0 || j == 0 || k == 0 || i == nx - 1 || j == ny - 1 || k == nz - 1 else { continue }
            for o in offsets {
                let x = i + o.x, y = j + o.y, z = k + o.z
                if !contains(x, y, z) { out.data[index(i, j, k)] = 0; break }
            }
        } } }
        return out
    }

    func eroded(radiusVoxels r: Double) -> BinaryVolume {
        eroded(radiusVoxels: SIMD3(r, r, r))
    }

    func opened(radiusVoxels r: Double) -> BinaryVolume { eroded(radiusVoxels: r).dilated(radiusVoxels: r) }
    func closed(radiusVoxels r: Double) -> BinaryVolume { dilated(radiusVoxels: r).eroded(radiusVoxels: r) }

    static func ellipsoidOffsets(radiusVoxels r: SIMD3<Double>) -> [SIMD3<Int>] {
        let ri = Int(r.x.rounded(.up)), rj = Int(r.y.rounded(.up)), rk = Int(r.z.rounded(.up))
        var out: [SIMD3<Int>] = []
        for k in -rk...rk { for j in -rj...rj { for i in -ri...ri {
            if i == 0 && j == 0 && k == 0 { continue }
            let d = pow(Double(i) / max(r.x, 1e-9), 2) + pow(Double(j) / max(r.y, 1e-9), 2) + pow(Double(k) / max(r.z, 1e-9), 2)
            if d <= 1 + 1e-9 { out.append(SIMD3(i, j, k)) }
        } } }
        return out
    }

    /// A set voxel with at least one 6-neighbour that is clear or off-grid.
    func isBoundary(_ i: Int, _ j: Int, _ k: Int) -> Bool {
        for o in BinaryVolume.sixNeighbours {
            let x = i + o.x, y = j + o.y, z = k + o.z
            if !contains(x, y, z) || data[index(x, y, z)] == 0 { return true }
        }
        return false
    }

    static let sixNeighbours: [SIMD3<Int>] = [
        SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)
    ]

    static let twentySixNeighbours: [SIMD3<Int>] = ballOffsets(radius: 1.75)

    enum Connectivity: Sendable { case six, twentySix }

    /// Connected-component labels (0 = background), component sizes sorted by
    /// label.
    func components(connectivity: Connectivity = .six) -> (labels: [Int32], sizes: [Int]) {
        let neighbours = connectivity == .six ? BinaryVolume.sixNeighbours : BinaryVolume.twentySixNeighbours
        var labels = [Int32](repeating: 0, count: voxelCount)
        var sizes: [Int] = [0]
        var stack: [Int] = []
        for start in 0..<voxelCount where data[start] != 0 && labels[start] == 0 {
            let label = Int32(sizes.count)
            var size = 0
            stack.append(start); labels[start] = label
            while let n = stack.popLast() {
                size += 1
                let i = n % nx, j = (n / nx) % ny, k = n / (nx * ny)
                for o in neighbours {
                    let x = i + o.x, y = j + o.y, z = k + o.z
                    guard contains(x, y, z) else { continue }
                    let m = index(x, y, z)
                    if data[m] != 0 && labels[m] == 0 { labels[m] = label; stack.append(m) }
                }
            }
            sizes.append(size)
        }
        return (labels, sizes)
    }

    /// Only the largest connected component.
    func largestComponent(connectivity: Connectivity = .six) -> BinaryVolume {
        let (labels, sizes) = components(connectivity: connectivity)
        guard sizes.count > 1 else { return self }
        var best = 1
        for l in 1..<sizes.count where sizes[l] > sizes[best] { best = l }
        return BinaryVolume(dimensions: dimensions, data: labels.map { $0 == Int32(best) ? 1 : 0 })
    }

    /// Fills cavities: background not reachable (6-connected) from the grid
    /// border becomes foreground.
    func holesFilled() -> BinaryVolume {
        var reachable = [UInt8](repeating: 0, count: voxelCount)
        var stack: [Int] = []
        func push(_ i: Int, _ j: Int, _ k: Int) {
            let m = index(i, j, k)
            if data[m] == 0 && reachable[m] == 0 { reachable[m] = 1; stack.append(m) }
        }
        for j in 0..<ny { for i in 0..<nx { push(i, j, 0); push(i, j, nz - 1) } }
        for k in 0..<nz { for i in 0..<nx { push(i, 0, k); push(i, ny - 1, k) } }
        for k in 0..<nz { for j in 0..<ny { push(0, j, k); push(nx - 1, j, k) } }
        while let n = stack.popLast() {
            let i = n % nx, j = (n / nx) % ny, k = n / (nx * ny)
            for o in BinaryVolume.sixNeighbours {
                let x = i + o.x, y = j + o.y, z = k + o.z
                if contains(x, y, z) { push(x, y, z) }
            }
        }
        return BinaryVolume(dimensions: dimensions, data: reachable.map { $0 == 0 ? 1 : 0 })
    }

    /// Voxels of the mask that touch background (6-connectivity).
    func surfaceVoxels() -> [SIMD3<Int>] {
        var out: [SIMD3<Int>] = []
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx where data[index(i, j, k)] != 0 && isBoundary(i, j, k) {
            out.append(SIMD3(i, j, k))
        } } }
        return out
    }
}

// MARK: - Scalar volume operations

nonisolated enum VolumeOps {
    static func threshold(_ volume: NIfTIVolume, above level: Float) -> BinaryVolume {
        BinaryVolume(dimensions: volume.dimensions, data: volume.data.map { $0 > level ? 1 : 0 })
    }

    static func threshold(_ volume: NIfTIVolume, in range: ClosedRange<Float>) -> BinaryVolume {
        BinaryVolume(dimensions: volume.dimensions, data: volume.data.map { range.contains($0) ? 1 : 0 })
    }

    /// Otsu's threshold over a 256-bin histogram of the finite values (optionally
    /// restricted to a mask).
    static func otsuThreshold(_ volume: NIfTIVolume, mask: BinaryVolume? = nil, bins: Int = 256) -> Float {
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for (n, v) in volume.data.enumerated() where v.isFinite && (mask?.data[n] ?? 1) != 0 {
            lo = min(lo, v); hi = max(hi, v)
        }
        guard hi > lo else { return lo }
        var histogram = [Double](repeating: 0, count: bins)
        let scale = Float(bins - 1) / (hi - lo)
        for (n, v) in volume.data.enumerated() where v.isFinite && (mask?.data[n] ?? 1) != 0 {
            histogram[Int((v - lo) * scale)] += 1
        }
        let total = histogram.reduce(0, +)
        var sumAll = 0.0
        for (b, h) in histogram.enumerated() { sumAll += Double(b) * h }
        // Between-class variance per candidate split; on plateaus (e.g. two-valued
        // data) take the middle of the maximal run so the threshold sits between
        // the classes rather than hugging one of them.
        var sumB = 0.0, weightB = 0.0, best = 0.0, firstBest = 0, lastBest = 0
        for b in 0..<bins {
            weightB += histogram[b]
            if weightB == 0 { continue }
            let weightF = total - weightB
            if weightF == 0 { break }
            sumB += Double(b) * histogram[b]
            let meanB = sumB / weightB, meanF = (sumAll - sumB) / weightF
            let between = weightB * weightF * (meanB - meanF) * (meanB - meanF)
            if between > best * (1 + 1e-12) { best = between; firstBest = b; lastBest = b }
            else if abs(between - best) <= best * 1e-12 { lastBest = b }
        }
        let bin = Double(firstBest + lastBest) / 2 + 0.5
        return lo + Float(bin) / scale
    }

    /// Separable Gaussian blur, sigma per axis in voxels, truncated at 3σ,
    /// edges renormalized.
    static func gaussianSmoothed(_ volume: NIfTIVolume, sigmaVoxels: SIMD3<Double>) -> NIfTIVolume {
        var data = volume.data
        let dims = [volume.nx, volume.ny, volume.nz]
        let strides = [1, volume.nx, volume.nx * volume.ny]
        for axis in 0..<3 {
            let sigma = sigmaVoxels[axis]
            guard sigma > 0 else { continue }
            let radius = max(1, Int((3 * sigma).rounded(.up)))
            let kernel = (-radius...radius).map { exp(-0.5 * pow(Double($0) / sigma, 2)) }
            let n = dims[axis], stride = strides[axis]
            var out = data
            let lineCount = volume.voxelCount / n
            let otherAxes = (0..<3).filter { $0 != axis }
            for line in 0..<lineCount {
                // Decompose `line` into the two other axis indices.
                let a = line % dims[otherAxes[0]], b = line / dims[otherAxes[0]]
                let base = a * strides[otherAxes[0]] + b * strides[otherAxes[1]]
                for p in 0..<n {
                    var acc = 0.0, weight = 0.0
                    for (q, w) in kernel.enumerated() {
                        let idx = p + q - radius
                        guard idx >= 0 && idx < n else { continue }
                        acc += w * Double(data[base + idx * stride]); weight += w
                    }
                    out[base + p * stride] = Float(acc / weight)
                }
            }
            data = out
        }
        return NIfTIVolume(dimensions: volume.dimensions, affine: volume.affine, data: data, header: volume.header, descriptionText: volume.descriptionText)
    }

    /// Resamples onto an isotropic RAS+ grid covering the same world box, by
    /// trilinear interpolation. The result is canonical.
    static func resampledIsotropic(_ volume: NIfTIVolume, voxelSizeMillimeters s: Double) -> NIfTIVolume {
        // World bounding box of the source grid's voxel centres.
        var lo = SIMD3<Double>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
        for corner in 0..<8 {
            let v = SIMD3(Double((corner & 1) != 0 ? volume.nx - 1 : 0), Double((corner & 2) != 0 ? volume.ny - 1 : 0), Double((corner & 4) != 0 ? volume.nz - 1 : 0))
            let w = volume.voxelToWorld(v)
            lo = pointwiseMin(lo, w); hi = pointwiseMax(hi, w)
        }
        let n = SIMD3(Int(((hi.x - lo.x) / s).rounded()) + 1, Int(((hi.y - lo.y) / s).rounded()) + 1, Int(((hi.z - lo.z) / s).rounded()) + 1)
        var affine = matrix_identity_double4x4
        affine.columns.0 = SIMD4(s, 0, 0, 0); affine.columns.1 = SIMD4(0, s, 0, 0); affine.columns.2 = SIMD4(0, 0, s, 0)
        affine.columns.3 = SIMD4(lo.x, lo.y, lo.z, 1)
        var out = NIfTIVolume.zeros(dimensions: n, affine: affine)
        let toSource = volume.affine.inverse * affine
        for k in 0..<n.z { for j in 0..<n.y { for i in 0..<n.x {
            let p = toSource * SIMD4(Double(i), Double(j), Double(k), 1)
            out.data[out.index(i, j, k)] = volume.sample(atVoxel: SIMD3(p.x, p.y, p.z))
        } } }
        out.descriptionText = volume.descriptionText
        return out
    }
}
