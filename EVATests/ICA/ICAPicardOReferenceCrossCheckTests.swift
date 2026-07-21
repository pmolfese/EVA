//
//  ICAPicardOReferenceCrossCheckTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Off-line cross-check harness: runs EVA's Picard-O on an externally supplied
//  dataset and dumps the result, so an external reference (python-picard,
//  ortho=True) can be compared against it component-for-component. It is a no-op
//  during normal test runs and only does work when the enable flag is set:
//
//    TEST_RUNNER_EVA_XCHECK=1   → run the cross-check
//
//  (xcodebuild forwards TEST_RUNNER_-prefixed variables into the test process
//  environment with the prefix stripped.)
//
//  The EVA app is sandboxed, so the exchange files live in the app's sandbox
//  temp dir (NSTemporaryDirectory(), i.e. the container's Data/tmp), which the
//  unsandboxed Python driver reaches at
//  ~/Library/Containers/gov.nih.nimh.cmn.eva/Data/tmp:
//
//    xcheck_input.json   (written by Python) → { "samplingRate": Double,
//                                                "data": [[Double]] }
//    xcheck_eva_output.json (written here)   → { iterations, unmixing, sources, ... }
//

import Testing
import Foundation
@testable import EVA

struct ICAPicardOReferenceCrossCheckTests {

    private struct Input: Decodable {
        var samplingRate: Double
        var data: [[Double]]
    }

    private struct Output: Encodable {
        var iterations: Int
        var finalChange: Double
        var componentCount: Int
        var unmixing: [[Double]]   // components × channels
        var sources: [[Double]]    // components × samples
    }

    @Test func crossCheckPicardOAgainstReference() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["EVA_XCHECK"] == "1" else {
            return  // not a cross-check run — skip silently
        }
        let tmp = NSTemporaryDirectory()
        let inputPath = tmp + "xcheck_input.json"
        let outputPath = tmp + "xcheck_eva_output.json"

        let inputData = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        let input = try JSONDecoder().decode(Input.self, from: inputData)

        let channels = input.data.map { $0.map(Float.init) }
        let signal = SyntheticSignal.make(channels, samplingRate: input.samplingRate)

        let configuration = ICAConfiguration(
            method: .picardO,
            componentCount: channels.count,        // square: no rank reduction
            varianceThreshold: 0.999999,
            averageReference: false,
            downsampleRate: input.samplingRate,    // factor 1: no decimation
            maxIterations: 500,
            learningRate: nil,
            fitFilter: nil,
            convergenceTolerance: 1e-9,
            minimumIterations: 1
        )

        let d = try ICAArtifactDetector.fit(signal: signal, configuration: configuration)

        let output = Output(
            iterations: d.iterations,
            finalChange: d.finalChange,
            componentCount: d.componentCount,
            unmixing: d.unmixingMatrix,
            sources: d.componentSources
        )
        let encoded = try JSONEncoder().encode(output)
        try encoded.write(to: URL(fileURLWithPath: outputPath))

        #expect(d.componentCount == channels.count)
    }
}
