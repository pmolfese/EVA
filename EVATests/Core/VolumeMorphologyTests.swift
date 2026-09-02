//
//  VolumeMorphologyTests.swift
//  EVATests
//

import Foundation
import Testing
import simd
@testable import EVA

@Suite("Volume morphology")
struct VolumeMorphologyTests {
    /// A 24³ volume with a bright sphere (radius 7) at the centre, a hollow
    /// cavity (radius 2) inside it, a small speck away from it, and Gaussian-ish
    /// noise-free background.
    private func phantom() -> NIfTIVolume {
        let n = 24
        var v = NIfTIVolume.zeros(dimensions: SIMD3(n, n, n), affine: NIfTIVolume.isotropicAffine(voxelSizeMillimeters: 1, dimensions: SIMD3(n, n, n)))
        let c = 11.5
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let d = ((Double(i) - c) * (Double(i) - c) + (Double(j) - c) * (Double(j) - c) + (Double(k) - c) * (Double(k) - c)).squareRoot()
            if d <= 7 && d > 2 { v[i, j, k] = 100 }
        } } }
        v[2, 2, 2] = 100  // speck
        return v
    }

    @Test("otsu separates the two-level phantom")
    func otsu() {
        let t = VolumeOps.otsuThreshold(phantom())
        #expect(t > 0 && t < 100)
    }

    @Test("largest component drops the speck; hole fill closes the cavity")
    func componentsAndHoles() {
        let v = phantom()
        let mask = VolumeOps.threshold(v, above: 50)
        let (_, sizes) = mask.components()
        #expect(sizes.count == 3)  // background slot + sphere + speck
        let big = mask.largestComponent()
        #expect(big[2, 2, 2] == false)
        #expect(big.count == mask.count - 1)
        #expect(big[12, 12, 12] == false)
        let filled = big.holesFilled()
        #expect(filled[12, 12, 12] == true)
        #expect(filled.count > big.count)
    }

    @Test("dilate then erode returns a convex mask; erosion shrinks by the radius")
    func dilateErode() {
        let v = phantom()
        let ball = VolumeOps.threshold(v, above: 50).largestComponent().holesFilled()
        let grown = ball.dilated(radiusVoxels: 2)
        #expect(grown.count > ball.count)
        #expect(grown.eroded(radiusVoxels: 2).count == ball.count)
        let shrunk = ball.eroded(radiusVoxels: 3)
        // Radius 7 ball → radius ~4 ball: volume ratio ≈ (4/7)³
        let ratio = Double(shrunk.count) / Double(ball.count)
        #expect(ratio > 0.12 && ratio < 0.30, "ratio \(ratio)")
        #expect(shrunk[12, 12, 12] == true)
    }

    @Test("gaussian smoothing keeps the mean and lowers the peak")
    func gaussian() {
        let v = phantom()
        let s = VolumeOps.gaussianSmoothed(v, sigmaVoxels: SIMD3(1.5, 1.5, 1.5))
        let mean = v.data.reduce(0, +) / Float(v.voxelCount)
        let meanS = s.data.reduce(0, +) / Float(s.voxelCount)
        #expect(abs(mean - meanS) < 1.5, "mean \(mean) vs \(meanS)")
        #expect(s.minMax().max < 100)
        #expect(s.minMax().max > 60)
    }

    @Test("centroid and bounding box of the sphere")
    func centroidBox() {
        let ball = VolumeOps.threshold(phantom(), above: 50).largestComponent().holesFilled()
        let c = ball.centroid!
        #expect(simd_length(c - SIMD3(11.5, 11.5, 11.5)) < 0.05)
        let box = ball.boundingBox!
        #expect(box.min == SIMD3(5, 5, 5) && box.max == SIMD3(18, 18, 18))
    }
}
