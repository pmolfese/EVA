//
//  SurfaceRegistration.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Coregistration of electrode / head-shape points to a scalp surface:
//
//    1. Fiducials → `HeadTransform.fit` (closed form, R2.3 step 1).
//    2. `icp` refines that against the surface: each iteration pairs every point
//       with its closest surface point and re-solves the rigid (or similarity)
//       transform in closed form, with optional trimming of the worst pairs so
//       a few badly digitized points cannot drag the fit.
//    3. `project` snaps electrodes onto the surface along the local normal, which
//       a BEM needs (electrodes must lie on the outer boundary).
//    4. `fitTemplateScalp` is the no-MRI path: scale + rigid fit of a template
//       scalp mesh to a digitized electrode cloud.
//
//  All in metres. Returned transforms map the *original* points' frame to the
//  surface's frame.
//

import Foundation
import simd

nonisolated enum SurfaceRegistration {
    struct ICPResult: Sendable {
        var transform: HeadTransform
        var scale: Double
        var iterations: Int
        /// Final unsigned distance of every input point to the surface, metres.
        var distances: [Double]
        var rms: Double {
            var sum = 0.0
            for d in distances { sum += d * d }
            return (sum / Double(Swift.max(distances.count, 1))).squareRoot()
        }
        var median: Double { let s = distances.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        var maximum: Double { distances.max() ?? 0 }
        var converged: Bool
    }

    struct ICPOptions: Sendable {
        var maxIterations = 60
        /// Stop when the RMS distance improves by less than this (metres).
        var tolerance = 1e-6
        var allowScale = false
        /// Fraction of pairs (worst distances) ignored when re-solving, 0…0.5.
        var trimFraction = 0.0
        /// Pairs farther than this (metres) are ignored when re-solving; nil = no cap.
        var maximumPairDistance: Double? = nil

        init() {}
    }

    /// Iterative closest point of `points` onto `surface`, starting from
    /// `initial` (points' frame → surface frame).
    static func icp(
        points: [SIMD3<Double>], surface: SurfaceIndex,
        initial: HeadTransform, options: ICPOptions = ICPOptions()
    ) -> ICPResult {
        var current = initial
        var scale = initial.scale
        var lastRMS = Double.greatestFiniteMagnitude
        var iterations = 0
        var converged = false
        var distances = [Double](repeating: 0, count: points.count)
        guard points.count >= 3 else {
            return ICPResult(transform: initial, scale: scale, iterations: 0, distances: distances, converged: false)
        }
        while iterations < options.maxIterations {
            iterations += 1
            let moved = current.apply(points)
            let closest = moved.map { surface.closestPoint(to: $0) }
            for (n, c) in closest.enumerated() { distances[n] = c.distance }
            var sumSquares = 0.0
            for d in distances { sumSquares += d * d }
            let rms = (sumSquares / Double(points.count)).squareRoot()
            if abs(lastRMS - rms) < options.tolerance { converged = true; break }
            lastRMS = rms
            // Select pairs to use.
            var order = Array(points.indices)
            if options.trimFraction > 0 {
                order.sort { distances[$0] < distances[$1] }
                let keep = max(3, Int(Double(points.count) * (1 - min(options.trimFraction, 0.5))))
                order = Array(order.prefix(keep))
            }
            if let cap = options.maximumPairDistance {
                let capped = order.filter { distances[$0] <= cap }
                if capped.count >= 3 { order = capped }
            }
            let src = order.map { points[$0] }
            let dst = order.map { closest[$0].point }
            guard let fit = try? HeadTransform.fit(source: src, target: dst, allowScale: options.allowScale, from: initial.from, to: initial.to) else { break }
            current = fit.transform
            scale = fit.scale
        }
        // Final distances under the returned transform.
        let moved = current.apply(points)
        for (n, p) in moved.enumerated() { distances[n] = surface.closestPoint(to: p).distance }
        return ICPResult(transform: current, scale: scale, iterations: iterations, distances: distances, converged: converged)
    }

    /// Fiducial alignment followed by ICP, the standard two-step coregistration.
    static func coregister(
        electrodes: ElectrodePositions, surface: SurfaceIndex,
        surfaceFiducials: (nasion: SIMD3<Double>, lpa: SIMD3<Double>, rpa: SIMD3<Double>)?,
        options: ICPOptions = ICPOptions(), surfaceFrame: CoordinateFrame = .mri
    ) throws -> ICPResult {
        let initial: HeadTransform
        if let f = surfaceFiducials, let n = electrodes.nasion, let l = electrodes.lpa, let r = electrodes.rpa {
            initial = try HeadTransform.fit(source: [n, l, r], target: [f.nasion, f.lpa, f.rpa], from: electrodes.frame, to: surfaceFrame).transform
        } else {
            // No fiducials on one side: start by matching centroids.
            let e = electrodes.eegPositions
            let ce = e.reduce(.zero, +) / Double(max(e.count, 1))
            initial = HeadTransform.rotation(matrix_identity_double3x3, translation: surface.mesh.centroid - ce, from: electrodes.frame, to: surfaceFrame)
        }
        let points = electrodes.eegPositions + electrodes.headShape
        return icp(points: points, surface: surface, initial: initial, options: options)
    }

    /// Snaps each point to the closest surface point. `alongNormal` moves along
    /// the hit triangle's normal instead (equivalent for points already near the
    /// surface; differs at edges).
    static func project(_ points: [SIMD3<Double>], onto surface: SurfaceIndex) -> [SIMD3<Double>] {
        points.map { surface.closestPoint(to: $0).point }
    }

    /// Template path: scale + rigid fit of a template scalp to digitized
    /// electrodes (with fiducials on both sides when available). Returns the
    /// transform from the template's frame to the electrodes' frame, and the
    /// residuals of the electrodes against the fitted scalp.
    static func fitTemplateScalp(
        template: TriangleMesh, templateFiducials: (nasion: SIMD3<Double>, lpa: SIMD3<Double>, rpa: SIMD3<Double>)?,
        electrodes: ElectrodePositions, options: ICPOptions? = nil
    ) throws -> (templateToElectrodes: HeadTransform, scale: Double, result: ICPResult) {
        var opts = options ?? ICPOptions()
        opts.allowScale = true
        opts.trimFraction = max(opts.trimFraction, 0.05)
        let index = SurfaceIndex(mesh: template)
        let result = try coregister(electrodes: electrodes, surface: index, surfaceFiducials: templateFiducials, options: opts, surfaceFrame: .mri)
        return (result.transform.inverted(), 1 / result.scale, result)
    }
}
