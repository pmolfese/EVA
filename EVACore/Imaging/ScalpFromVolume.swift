//
//  ScalpFromVolume.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  A quick scalp surface from a T1: head mask (Otsu → largest component → holes
//  filled → light closing), then a **star-shaped** mesh — an icosphere whose every
//  vertex is pushed out from the head centroid along its own direction until the
//  ray leaves the mask. Scalps are star-shaped from a point near the head centre
//  to a good approximation, so this gives a closed, well-formed, guaranteed
//  genus-0 mesh with no marching-cubes cleanup, at the cost of missing concavities
//  (under the chin, around the ears). Runs at 2 mm by default. Good enough for coregistration; R3 replaces
//  it with the segmentation + marching-cubes pipeline for BEM shells.
//

import Foundation
import simd

nonisolated enum ScalpFromVolume {
    struct Options: Sendable {
        /// Icosphere subdivisions: 3 → 1280 triangles, 4 → 5120.
        var subdivisions = 4
        /// Closing radius in millimetres applied to the head mask.
        var closingMillimeters = 3.0
        /// Gaussian smoothing (mm) of the T1 before thresholding.
        var smoothingMillimeters = 1.0
        /// Optional explicit threshold; nil → Otsu.
        var threshold: Float? = nil
        /// Volumes finer than this are resampled to it first: a scalp for
        /// coregistration does not need sub-2 mm detail, and the morphology is
        /// 8× cheaper at 2 mm than at 1 mm.
        var workingVoxelMillimeters = 2.0
        init() {}
    }

    struct Result: Sendable {
        /// Scalp mesh in world **metres** (RAS).
        var mesh: TriangleMesh
        var mask: BinaryVolume
        var threshold: Float
        /// Head centroid, metres.
        var centroid: SIMD3<Double>
    }

    /// The volume the mask and scalp are computed on (canonical, possibly coarser).
    static func workingVolume(_ volume: NIfTIVolume, options: Options = Options()) -> NIfTIVolume {
        let v = volume.canonicalized()
        if v.voxelSizeMillimeters.min() < options.workingVoxelMillimeters * 0.9 {
            return VolumeOps.resampledIsotropic(v, voxelSizeMillimeters: options.workingVoxelMillimeters)
        }
        return v
    }

    static func headMask(_ volume: NIfTIVolume, options: Options = Options()) -> (mask: BinaryVolume, threshold: Float) {
        let v = workingVolume(volume, options: options)
        let sigma = options.smoothingMillimeters
        let smoothed = sigma > 0
            ? VolumeOps.gaussianSmoothed(v, sigmaVoxels: SIMD3(sigma / v.voxelSizeMillimeters.x, sigma / v.voxelSizeMillimeters.y, sigma / v.voxelSizeMillimeters.z))
            : v
        let threshold = options.threshold ?? VolumeOps.otsuThreshold(smoothed)
        var mask = VolumeOps.threshold(smoothed, above: threshold).largestComponent().holesFilled()
        if options.closingMillimeters > 0 {
            let r = SIMD3(options.closingMillimeters / v.voxelSizeMillimeters.x, options.closingMillimeters / v.voxelSizeMillimeters.y, options.closingMillimeters / v.voxelSizeMillimeters.z)
            mask = mask.dilated(radiusVoxels: r).eroded(radiusVoxels: r).holesFilled()
        }
        return (mask, threshold)
    }

    static func scalp(from volume: NIfTIVolume, options: Options = Options()) -> Result? {
        let v = workingVolume(volume, options: options)
        let (mask, threshold) = headMask(v, options: options)
        guard let centroidVoxel = mask.centroid else { return nil }
        let unit = BEMForwardModel.icosphere(subdivisions: options.subdivisions)
        // March each ray in world space with a step of half the smallest voxel.
        let step = v.voxelSizeMillimeters.min() * 0.5
        let centreWorld = v.voxelToWorld(centroidVoxel)
        let maxRadius = simd_length(SIMD3(Double(v.nx), Double(v.ny), Double(v.nz)) * v.voxelSizeMillimeters)
        var vertices: [SIMD3<Double>] = []
        vertices.reserveCapacity(unit.vertices.count)
        for dir in unit.vertices {
            var lastInside = 0.0
            var r = 0.0
            while r < maxRadius {
                let w = centreWorld + dir * r
                let vox = v.worldToVoxel(w)
                let i = Int(vox.x.rounded()), j = Int(vox.y.rounded()), k = Int(vox.z.rounded())
                if mask.contains(i, j, k), mask[i, j, k] { lastInside = r }
                else if r - lastInside > 6 * step { break }  // left the head (allow small gaps)
                r += step
            }
            vertices.append((centreWorld + dir * lastInside) / 1000)
        }
        let triangles = unit.faces.map { SIMD3(Int32($0.0), Int32($0.1), Int32($0.2)) }
        let mesh = TriangleMesh(vertices: vertices, triangles: triangles)
        return Result(mesh: mesh, mask: mask, threshold: threshold, centroid: centreWorld / 1000)
    }
}
