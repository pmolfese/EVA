//
//  ICAComponentAutoLabelerTests.swift
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
//  Note: unit tests run hosted inside the EVA.app process, so `Bundle.main`
//  (and therefore the bundled ICLabel Core ML model) IS available here. To
//  get deterministic coverage of the transparent heuristic rules, most tests
//  below pass `layout: nil`, which makes `ICLabelClassifier.suggestions`
//  bail out immediately (see its `guard let layout`) and guarantees
//  `ICAComponentAutoLabeler` falls through to its own scoring. Tests that
//  pass a real layout only check well-formedness, since the Core ML model's
//  prediction on synthetic (non-physiological) input isn't something this
//  suite should pin down.

import Testing
import Foundation
@testable import EVA

struct ICAComponentAutoLabelerTests {

    /// A grid of sensor positions covering the whole unit disc (anterior,
    /// posterior, lateral, center, and edge regions all represented), enough
    /// for the dipolarity polynomial fit (needs >= 12 sensors).
    private func gridLayout() -> SensorLayout {
        var positions: [SensorPosition] = []
        var index = 0
        for gy in stride(from: -0.9, through: 0.9, by: 0.3) {
            for gx in stride(from: -0.9, through: 0.9, by: 0.3) {
                guard hypot(gx, gy) <= 1.0 else { continue }
                positions.append(SensorPosition(channelIndex: index, x: gx, y: gy))
                index += 1
            }
        }
        return SensorLayout(name: "grid", positions: positions)
    }

    private func decomposition(
        channelCount: Int,
        map: [Double],
        source: [Double],
        samplingRate: Double = 250
    ) -> ICADecomposition {
        ICADecomposition(
            sourceSignalPath: "/tmp/synthetic.bin",
            sourceSamplingRate: samplingRate,
            analysisSamplingRate: samplingRate,
            decimation: 1,
            fitFilter: nil,
            convergenceTolerance: 1e-7,
            minimumIterations: 1,
            finalChange: 0,
            varianceThreshold: 0,
            pcaVarianceRetained: 1,
            averageReference: false,
            channelCount: channelCount,
            sampleCount: source.count,
            componentCount: 1,
            iterations: 1,
            channelMeans: [Double](repeating: 0, count: channelCount),
            mixingMatrix: [],
            unmixingMatrix: [],
            componentMaps: [map],
            componentSources: [source],
            explainedVariance: [1],
            pcaExplainedVariance: [1]
        )
    }

    /// A blink-like source: isolated slow bumps on an otherwise flat baseline,
    /// spaced far enough apart (3 s) that they don't create a short-lag
    /// autocorrelation peak in the ~0.45-1.35 s cardiac window (which even a
    /// smooth slow sinusoid would, just by being locally self-similar). Most
    /// of the signal's power still sits below 3 Hz and sign changes are rare.
    private func slowDriftSource(count: Int, samplingRate: Double) -> [Double] {
        let bump = SyntheticSignal.bump(width: Int(samplingRate * 0.6)) // ~600 ms
        let period = Int(samplingRate * 3) // one blink every 3 s
        var values = [Double](repeating: 0, count: count)
        var start = 0
        while start < count {
            for k in 0..<min(bump.count, count - start) {
                values[start + k] = Double(bump[k])
            }
            start += period
        }
        return values
    }

    /// A ~1 Hz pulse train with a sharp, narrow shape repeated regularly — high
    /// autocorrelation at the cardiac lag.
    private func rhythmicPulseSource(count: Int, samplingRate: Double) -> [Double] {
        let period = Int(samplingRate) // 1 Hz
        var values = [Double](repeating: 0, count: count)
        var t = 0
        while t < count {
            for k in 0..<min(10, count - t) {
                values[t + k] = exp(-Double(k * k) / 8.0)
            }
            t += period
        }
        return values
    }

    // MARK: - Heuristic path (layout: nil forces it deterministically)

    @Test func suggestsEyeForSlowLowFrequencySourceWithSmoothMap() {
        // With no layout, spatial anterior/posterior cues are unavailable, so
        // this leans entirely on the slow, low-frequency, low-focality cues.
        let map = [Double](repeating: 0.2, count: 32) // uniform -> low focality, high smoothness
        let source = slowDriftSource(count: 2500, samplingRate: 250)
        let decomposition = decomposition(channelCount: 32, map: map, source: source)

        let suggestions = ICAComponentAutoLabeler.suggestions(for: decomposition, layout: nil)
        let suggestion = try! #require(suggestions[0])
        #expect(suggestion.label.hasPrefix("Eye"), "expected an eye label, got \(suggestion.label)")
    }

    @Test func suggestsHeartForRhythmicSource() {
        let map = [Double](repeating: 0.2, count: 32)
        let source = rhythmicPulseSource(count: 3000, samplingRate: 250)
        let decomposition = decomposition(channelCount: 32, map: map, source: source)

        let suggestions = ICAComponentAutoLabeler.suggestions(for: decomposition, layout: nil)
        let suggestion = try! #require(suggestions[0])
        #expect(suggestion.label.hasPrefix("Heart"), "expected a heart label, got \(suggestion.label)")
    }

    @Test func suggestsChannelNoiseForHighlyFocalMap() {
        // A tiny handful of channels dominate; the rest are exactly zero.
        var map = [Double](repeating: 0, count: 32)
        map[0] = 1.0; map[1] = 1.0; map[2] = 1.0
        let source = slowDriftSource(count: 2500, samplingRate: 250) // map dominates this score, not source
        let decomposition = decomposition(channelCount: 32, map: map, source: source)

        let suggestions = ICAComponentAutoLabeler.suggestions(for: decomposition, layout: nil)
        let suggestion = try! #require(suggestions[0])
        #expect(suggestion.label.hasPrefix("Channel Noise"), "expected channel noise, got \(suggestion.label)")
    }

    @Test func fallsBackToOtherWhenNoFeatureIsDistinctive() {
        // A flat map and a flat (zero-variance) source have no distinguishing
        // features at all.
        let map = [Double](repeating: 0, count: 32)
        let source = [Double](repeating: 0, count: 2500)
        let decomposition = decomposition(channelCount: 32, map: map, source: source)

        let suggestions = ICAComponentAutoLabeler.suggestions(for: decomposition, layout: nil)
        let suggestion = try! #require(suggestions[0])
        #expect(suggestion.label == "Other")
    }

    @Test func handlesNilLayoutWithoutCrashing() {
        let source = slowDriftSource(count: 2500, samplingRate: 250)
        let decomposition = decomposition(channelCount: 32, map: [Double](repeating: 0, count: 32), source: source)

        let suggestions = ICAComponentAutoLabeler.suggestions(for: decomposition, layout: nil)
        #expect(suggestions[0] != nil)
    }

    @Test func returnsOneSuggestionPerComponent() {
        let source = slowDriftSource(count: 2500, samplingRate: 250)
        var multi = decomposition(channelCount: 32, map: [Double](repeating: 0, count: 32), source: source)
        multi.componentCount = 3
        multi.componentMaps = Array(repeating: [Double](repeating: 0, count: 32), count: 3)
        multi.componentSources = Array(repeating: source, count: 3)

        let suggestions = ICAComponentAutoLabeler.suggestions(for: multi, layout: nil)
        #expect(suggestions.count == 3)
        #expect(suggestions.keys.sorted() == [0, 1, 2])
    }

    // MARK: - With a real layout (exercises the Core ML path; well-formedness only)

    @Test func suggestionsAreWellFormedWithARealLayout() {
        let layout = gridLayout()
        let source = slowDriftSource(count: 2500, samplingRate: 250)
        let decomposition = decomposition(channelCount: layout.positions.count, map: [Double](repeating: 0.1, count: layout.positions.count), source: source)

        let suggestions = ICAComponentAutoLabeler.suggestions(for: decomposition, layout: layout)
        let suggestion = try! #require(suggestions[0])
        #expect(!suggestion.label.isEmpty)
        #expect((0...1).contains(suggestion.confidence))
        if !suggestion.probabilities.isEmpty {
            let total = suggestion.probabilities.values.reduce(0, +)
            #expect(abs(total - 1) < 0.05)
        }
    }
}
