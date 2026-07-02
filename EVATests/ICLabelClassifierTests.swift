//
//  ICLabelClassifierTests.swift
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
//  ICLabelClassifier's real inference path depends on a bundled Core ML model
//  and produces model-dependent (not source-controlled) output, so it isn't a
//  good fit for pinned unit assertions. What IS deterministic and worth
//  locking down is the early-exit contract that `ICAComponentAutoLabeler`
//  depends on: no layout means no attempt to run the model.

import Testing
import Foundation
@testable import EVA

struct ICLabelClassifierTests {

    private func decomposition(componentCount: Int, sampleCount: Int) -> ICADecomposition {
        ICADecomposition(
            sourceSignalPath: "/tmp/synthetic.bin",
            sourceSamplingRate: 250,
            analysisSamplingRate: 250,
            decimation: 1,
            fitFilter: nil,
            convergenceTolerance: 1e-7,
            minimumIterations: 1,
            finalChange: 0,
            varianceThreshold: 0,
            pcaVarianceRetained: 1,
            averageReference: false,
            channelCount: 32,
            sampleCount: sampleCount,
            componentCount: componentCount,
            iterations: 1,
            channelMeans: [Double](repeating: 0, count: 32),
            mixingMatrix: [],
            unmixingMatrix: [],
            componentMaps: Array(repeating: [Double](repeating: 0, count: 32), count: componentCount),
            componentSources: Array(repeating: [Double](repeating: 0, count: sampleCount), count: componentCount),
            explainedVariance: Array(repeating: 1, count: componentCount),
            pcaExplainedVariance: Array(repeating: 1, count: componentCount)
        )
    }

    @Test func returnsEmptyWithoutALayout() {
        let suggestions = ICLabelClassifier.suggestions(
            for: decomposition(componentCount: 3, sampleCount: 1000),
            layout: nil
        )
        #expect(suggestions.isEmpty)
    }

    @Test func returnsEmptyForZeroComponents() {
        let layout = SensorLayout(name: "empty", positions: [])
        let suggestions = ICLabelClassifier.suggestions(
            for: decomposition(componentCount: 0, sampleCount: 1000),
            layout: layout
        )
        #expect(suggestions.isEmpty)
    }
}
