//
//  ICAArtifactDetectorTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//

import Testing
import Foundation
@testable import EVA

struct ICAArtifactDetectorTests {

    private let samplingRate = 200.0
    private let count = 2000

    /// Three independent non-Gaussian sources.
    private func sources() -> [[Double]] {
        let s0 = (0..<count).map { sin(2 * .pi * 7 * Double($0) / samplingRate) }            // sine
        let s1 = (0..<count).map { 2 * (Double($0 % 50) / 50.0) - 1 }                          // sawtooth
        let s2 = (0..<count).map { Double(($0 / 31) % 2) * 2 - 1 }                              // square wave
        return [s0, s1, s2]
    }

    /// Mix sources into `channelCount` channels with a fixed mixing matrix.
    private func mixedChannels(channelCount: Int) -> [[Float]] {
        let src = sources()
        let mixing: [[Double]] = [
            [0.8, 0.3, -0.4],
            [-0.5, 0.9, 0.2],
            [0.2, -0.7, 0.8],
            [0.6, 0.4, 0.5]
        ]
        return (0..<channelCount).map { c in
            (0..<count).map { t -> Float in
                let a = mixing[c][0] * src[0][t]
                let b = mixing[c][1] * src[1][t]
                let d = mixing[c][2] * src[2][t]
                return Float(a + b + d)
            }
        }
    }

    private func config() -> ICAConfiguration {
        ICAConfiguration(
            method: .picard,
            componentCount: 3,
            varianceThreshold: 0.99999,
            averageReference: false,
            downsampleRate: samplingRate,   // factor 1: no decimation
            maxIterations: 300,
            learningRate: nil,
            fitFilter: nil,
            convergenceTolerance: 1e-7,
            minimumIterations: 1
        )
    }

    @Test func decompositionShapeIsConsistent() throws {
        let signal = SyntheticSignal.make(mixedChannels(channelCount: 4), samplingRate: samplingRate)
        let decomposition = try ICAArtifactDetector.fit(signal: signal, configuration: config())

        #expect(decomposition.channelCount == 4)
        #expect(decomposition.componentCount == 3)        // true mixture rank
        #expect(decomposition.unmixingMatrix.count == 3)  // components × channels
        #expect(decomposition.mixingMatrix.count == 4)    // channels × components
        #expect(decomposition.componentSources.count == 3)
        #expect(decomposition.explainedVariance.count == 3)
    }

    @Test func mixingReconstructsCenteredData() throws {
        // 3 sources mixed into 4 channels live in a rank-3 subspace, so the rank-3
        // decomposition must reconstruct the (mean-centered) input almost exactly:
        //   data[c][t] ≈ Σ_k mixing[c][k]·sources[k][t] + mean[c]
        let channels = mixedChannels(channelCount: 4)
        let signal = SyntheticSignal.make(channels, samplingRate: samplingRate)
        let d = try ICAArtifactDetector.fit(signal: signal, configuration: config())

        var maxError = 0.0
        for c in 0..<4 {
            for t in stride(from: 0, to: count, by: 17) { // sample the timeline
                var recon = d.channelMeans[c]
                for k in 0..<d.componentCount {
                    recon += d.mixingMatrix[c][k] * d.componentSources[k][t]
                }
                maxError = max(maxError, abs(recon - Double(channels[c][t])))
            }
        }
        #expect(maxError < 1e-3, "reconstruction error \(maxError)")
    }

    @Test func recoveredComponentsAreMutuallyDecorrelated() throws {
        // ICA components are (at least) uncorrelated with one another.
        let signal = SyntheticSignal.make(mixedChannels(channelCount: 4), samplingRate: samplingRate)
        let d = try ICAArtifactDetector.fit(signal: signal, configuration: config())

        for i in 0..<d.componentCount {
            for j in (i + 1)..<d.componentCount {
                let r = SyntheticSignal.absCorrelation(d.componentSources[i], d.componentSources[j])
                #expect(r < 0.1, "components \(i),\(j) correlated: |r| = \(r)")
            }
        }
    }

    @Test func isDeterministicAcrossRuns() throws {
        let signal = SyntheticSignal.make(mixedChannels(channelCount: 4), samplingRate: samplingRate)
        let a = try ICAArtifactDetector.fit(signal: signal, configuration: config())
        let b = try ICAArtifactDetector.fit(signal: signal, configuration: config())
        #expect(a.iterations == b.iterations)
        #expect(a.unmixingMatrix == b.unmixingMatrix)
    }

    @Test func emptySignalThrows() {
        let empty = SyntheticSignal.make([], samplingRate: samplingRate)
        #expect(throws: ICAError.self) {
            _ = try ICAArtifactDetector.fit(signal: empty, configuration: config())
        }
    }
}
