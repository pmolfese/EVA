//
//  CorneoRetinalCorrection.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  MAAC-2 corneo-retinal dipole (CRD) correction. This is the regression
//  method described by Dien (2024), section 1.7, and implemented in the EP
//  Toolkit's ep_fixSaccade.m: rough HEOG/VEOG difference waves weight scalp
//  templates, those templates are projected back into continuous time courses,
//  and horizontal correction precedes vertical correction.
//
//  Dien, J. (2024). Multi-Algorithm Artifact Correction (MAAC) procedure part
//  one: Algorithm and example. Biological Psychology, 188, 108775.
//  https://doi.org/10.1016/j.biopsycho.2024.108775
//

import Foundation

nonisolated struct CorneoRetinalConfiguration: Codable, Sendable, Equatable {
    /// Horizontal eye position must be near its center before samples may
    /// contribute to the vertical template. The EP Toolkit uses one eighth.
    var verticalTemplateHorizontalFraction: Double = 0.125
    /// Extends detected blink spans slightly so the lids' onset and recovery do
    /// not leak into the CRD templates. The predictor is linearly interpolated
    /// across the resulting gap before whole-recording correction.
    var blinkPaddingSeconds: Double = 0.040
    /// The dedicated MAAC preliminary blink scan. This is intentionally not
    /// the app-wide ocular threshold configuration: MAAC needs explicit
    /// upper-minus-lower VEOG roles and rapid rise/fall morphology.
    var preliminaryBlink = MAACPreliminaryBlinkConfiguration.default

    static let `default` = CorneoRetinalConfiguration()

    private enum CodingKeys: String, CodingKey {
        case verticalTemplateHorizontalFraction
        case blinkPaddingSeconds
        case preliminaryBlink
    }

    init(
        verticalTemplateHorizontalFraction: Double = 0.125,
        blinkPaddingSeconds: Double = 0.040,
        preliminaryBlink: MAACPreliminaryBlinkConfiguration = .default
    ) {
        self.verticalTemplateHorizontalFraction = verticalTemplateHorizontalFraction
        self.blinkPaddingSeconds = blinkPaddingSeconds
        self.preliminaryBlink = preliminaryBlink
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        verticalTemplateHorizontalFraction = try container.decodeIfPresent(
            Double.self, forKey: .verticalTemplateHorizontalFraction
        ) ?? 0.125
        blinkPaddingSeconds = try container.decodeIfPresent(
            Double.self, forKey: .blinkPaddingSeconds
        ) ?? 0.040
        preliminaryBlink = try container.decodeIfPresent(
            MAACPreliminaryBlinkConfiguration.self, forKey: .preliminaryBlink
        ) ?? .default
    }
}

nonisolated struct CorneoRetinalChannelSelection: Codable, Sendable, Equatable {
    var leftHEOGIndices: [Int]
    var rightHEOGIndices: [Int]
    var upperVEOGIndices: [Int]
    var lowerVEOGIndices: [Int]
    var analysisIndices: [Int]

    func validated(channelCount: Int) throws -> CorneoRetinalChannelSelection {
        guard channelCount >= 4 else { throw CorneoRetinalError.insufficientChannels }

        func validUnique(_ indices: [Int]) -> [Int] {
            Array(Set(indices.filter { (0..<channelCount).contains($0) })).sorted()
        }

        let left = validUnique(leftHEOGIndices)
        let right = validUnique(rightHEOGIndices)
        let upper = validUnique(upperVEOGIndices)
        let lower = validUnique(lowerVEOGIndices)
        let analysis = validUnique(analysisIndices)
        guard !left.isEmpty, !right.isEmpty else { throw CorneoRetinalError.missingHEOGPair }
        guard !upper.isEmpty, !lower.isEmpty else { throw CorneoRetinalError.missingVEOGPair }
        guard analysis.count >= 2 else { throw CorneoRetinalError.insufficientAnalysisChannels }
        return CorneoRetinalChannelSelection(
            leftHEOGIndices: left,
            rightHEOGIndices: right,
            upperVEOGIndices: upper,
            lowerVEOGIndices: lower,
            analysisIndices: analysis
        )
    }
}

nonisolated struct CorneoRetinalDiagnostics: Sendable {
    var horizontalTopography: [Float]
    var verticalTopography: [Float]
    var horizontalTimeCourse: [Float]
    var verticalTimeCourse: [Float]
    var blinkSampleCount: Int
    var templateSampleCount: Int
    var verticalTemplateSampleCount: Int
    var correctedChannelCount: Int

    var horizontalRMS: Double { Self.rms(horizontalTimeCourse) }
    var verticalRMS: Double { Self.rms(verticalTimeCourse) }

    private static func rms(_ values: [Float]) -> Double {
        guard !values.isEmpty else { return 0 }
        return sqrt(values.reduce(0) { $0 + Double($1) * Double($1) } / Double(values.count))
    }
}

nonisolated struct CorneoRetinalCorrectionResult: Sendable {
    var correctedData: [[Float]]
    var diagnostics: CorneoRetinalDiagnostics
}

nonisolated enum CorneoRetinalError: LocalizedError, Equatable {
    case invalidSignal
    case insufficientChannels
    case missingHEOGPair
    case missingVEOGPair
    case insufficientAnalysisChannels
    case insufficientCleanSamples
    case degenerateHorizontalTemplate
    case degenerateVerticalTemplate

    var errorDescription: String? {
        switch self {
        case .invalidSignal:
            return "The recording has no rectangular EEG sample grid to correct."
        case .insufficientChannels:
            return "MAAC-2 needs at least four channels."
        case .missingHEOGPair:
            return "Choose at least one left and one right HEOG channel."
        case .missingVEOGPair:
            return "Choose at least one upper and one lower VEOG channel."
        case .insufficientAnalysisChannels:
            return "Choose at least two good channels for the scalp regression."
        case .insufficientCleanSamples:
            return "Too few non-blink samples remain to estimate the CRD templates."
        case .degenerateHorizontalTemplate:
            return "The horizontal CRD template has no usable HEOG contrast. Check the left/right channel assignments."
        case .degenerateVerticalTemplate:
            return "The vertical CRD template has no usable VEOG contrast. Check the upper/lower channel assignments."
        }
    }
}

nonisolated enum CorneoRetinalChannelResolver {
    static func automatic(
        signal: MFFSignalData,
        layout: SensorLayout?,
        excluding excluded: Set<Int> = []
    ) throws -> CorneoRetinalChannelSelection {
        let count = signal.numberOfChannels
        let names = signal.channelNames ?? []
        let canonicalNames = names.map(canonicalName)
        var vertical = canonicalNames.indices.filter {
            canonicalNames[$0].contains("VEOG") || canonicalNames[$0].contains("VEO") || canonicalNames[$0].contains("EOGV")
        }
        var horizontal = canonicalNames.indices.filter {
            canonicalNames[$0].contains("HEOG") || canonicalNames[$0].contains("HEO") || canonicalNames[$0].contains("EOGH")
        }
        if vertical.count < 2 {
            vertical = EyeArtifactThresholdDetector.autoOcularChannelIndices(
                kind: .blink, channelCount: count, sensorLayoutName: layout?.name
            )
        }
        if horizontal.count < 2 {
            horizontal = EyeArtifactThresholdDetector.autoOcularChannelIndices(
                kind: .movement, channelCount: count, sensorLayoutName: layout?.name
            )
        }
        vertical = Array(Set(vertical.filter { !excluded.contains($0) })).sorted()
        horizontal = Array(Set(horizontal.filter { !excluded.contains($0) })).sorted()

        let positions = Dictionary(uniqueKeysWithValues: (layout?.positions ?? []).map { ($0.channelIndex, $0) })
        let horizontalSplit = split(
            horizontal,
            coordinate: { positions[$0]?.x },
            namedFirst: canonicalNames.indices.filter { canonicalNames[$0].contains("LHEOG") || canonicalNames[$0].contains("LEOG") },
            namedSecond: canonicalNames.indices.filter { canonicalNames[$0].contains("RHEOG") || canonicalNames[$0].contains("REOG") }
        )
        // SensorLayout uses +y anterior. On EGI nets the lower periocular
        // electrodes are the more anterior members of the VEOG set.
        let verticalSplit = split(
            vertical,
            coordinate: { positions[$0]?.y },
            namedFirst: canonicalNames.indices.filter { canonicalNames[$0].contains("UVEOG") || canonicalNames[$0].contains("UEOG") },
            namedSecond: canonicalNames.indices.filter { canonicalNames[$0].contains("LVEOG") || canonicalNames[$0].contains("LOWER") }
        )

        let analysis = (0..<count).filter { !excluded.contains($0) }
        return try CorneoRetinalChannelSelection(
            leftHEOGIndices: horizontalSplit.first,
            rightHEOGIndices: horizontalSplit.second,
            upperVEOGIndices: verticalSplit.first,
            lowerVEOGIndices: verticalSplit.second,
            analysisIndices: analysis
        ).validated(channelCount: count)
    }

    private static func split(
        _ candidates: [Int],
        coordinate: (Int) -> Double?,
        namedFirst: [Int],
        namedSecond: [Int]
    ) -> (first: [Int], second: [Int]) {
        let candidateSet = Set(candidates)
        let explicitFirst = namedFirst.filter(candidateSet.contains)
        let explicitSecond = namedSecond.filter(candidateSet.contains)
        if !explicitFirst.isEmpty, !explicitSecond.isEmpty {
            return (explicitFirst.sorted(), explicitSecond.sorted())
        }
        let sorted = candidates.sorted {
            (coordinate($0) ?? Double($0)) < (coordinate($1) ?? Double($1))
        }
        let midpoint = max(1, sorted.count / 2)
        let lower = Array(sorted.prefix(midpoint))
        let upper = Array(sorted.dropFirst(midpoint))
        return (lower, upper)
    }

    private static func canonicalName(_ name: String) -> String {
        name.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}

nonisolated enum CorneoRetinalCorrector {
    private struct ComponentFit {
        var topography: [Float]
        var timeCourse: [Float]
    }

    static func correct(
        data: [[Float]],
        samplingRate: Double,
        selection rawSelection: CorneoRetinalChannelSelection,
        blinkEvents: [MFFEvent],
        configuration: CorneoRetinalConfiguration = .default,
        excluding excluded: Set<Int> = [],
        progress: (@Sendable (CorneoRetinalAnalysisProgress) -> Void)? = nil
    ) throws -> CorneoRetinalCorrectionResult {
        progress?(CorneoRetinalAnalysisProgress(
            fraction: 0.34,
            stage: "Preparing eye-position traces",
            detail: "Validating EOG roles and blink-mask spans"
        ))
        guard samplingRate > 0,
              let sampleCount = data.first?.count,
              sampleCount >= 8,
              !data.isEmpty,
              data.allSatisfy({ $0.count == sampleCount }) else {
            throw CorneoRetinalError.invalidSignal
        }
        var selection = try rawSelection.validated(channelCount: data.count)
        selection.leftHEOGIndices.removeAll(where: excluded.contains)
        selection.rightHEOGIndices.removeAll(where: excluded.contains)
        selection.upperVEOGIndices.removeAll(where: excluded.contains)
        selection.lowerVEOGIndices.removeAll(where: excluded.contains)
        selection.analysisIndices.removeAll(where: excluded.contains)
        selection = try selection.validated(channelCount: data.count)

        var blinkMask = [Bool](repeating: false, count: sampleCount)
        let padding = max(Int((configuration.blinkPaddingSeconds * samplingRate).rounded()), 0)
        for event in blinkEvents {
            let startSeconds = event.spanSeconds?.lowerBound ?? event.onsetTimeSeconds
            let endSeconds = event.spanSeconds?.upperBound ?? event.endTimeSeconds
            let start = max(0, Int(floor(startSeconds * samplingRate)) - padding)
            let end = min(sampleCount - 1, Int(ceil(endSeconds * samplingRate)) + padding)
            guard start <= end else { continue }
            for sample in start...end { blinkMask[sample] = true }
        }

        let rawHorizontal = differenceTrace(
            data: data, positive: selection.leftHEOGIndices, negative: selection.rightHEOGIndices
        )
        let rawVertical = differenceTrace(
            data: data, positive: selection.lowerVEOGIndices, negative: selection.upperVEOGIndices
        )
        var goodSamples = (0..<sampleCount).filter {
            !blinkMask[$0] && rawHorizontal[$0].isFinite && rawVertical[$0].isFinite
        }
        goodSamples = goodSamples.filter { sample in
            selection.analysisIndices.allSatisfy { data[$0][sample].isFinite }
        }
        guard goodSamples.count >= max(8, selection.analysisIndices.count + 2) else {
            throw CorneoRetinalError.insufficientCleanSamples
        }

        progress?(CorneoRetinalAnalysisProgress(
            fraction: 0.45,
            stage: "Fitting horizontal CRD map",
            detail: "(goodSamples.count) usable samples after blink masking",
            blinkSampleCount: blinkMask.filter { $0 }.count,
            usableSampleCount: goodSamples.count,
            totalSampleCount: sampleCount
        ))

        let horizontal = interpolate(rawHorizontal, keeping: Set(goodSamples))
        let vertical = interpolate(rawVertical, keeping: Set(goodSamples))
        let centeredHorizontal = centered(horizontal, over: goodSamples)
        let horizontalTemplate = weightedTopography(
            data: data, predictor: centeredHorizontal, samples: goodSamples, channels: selection.analysisIndices
        )
        let horizontalFit = try fitComponent(
            data: data,
            roughPredictor: horizontal,
            template: horizontalTemplate,
            scalePositive: selection.leftHEOGIndices,
            scaleNegative: selection.rightHEOGIndices,
            fitSamples: goodSamples,
            channels: selection.analysisIndices,
            error: .degenerateHorizontalTemplate
        )
        var corrected = data
        subtract(horizontalFit, from: &corrected, channels: selection.analysisIndices)

        progress?(CorneoRetinalAnalysisProgress(
            fraction: 0.66,
            stage: "Selecting centered-gaze samples",
            detail: String(format: "Horizontal CRD amplitude %.2f µV RMS", horizontalFit.timeCourse.rms),
            blinkSampleCount: blinkMask.filter { $0 }.count,
            usableSampleCount: goodSamples.count,
            totalSampleCount: sampleCount,
            horizontalRMS: horizontalFit.timeCourse.rms
        ))

        let fraction = min(max(configuration.verticalTemplateHorizontalFraction, 0.01), 1)
        let sortedHorizontal = goodSamples.map { abs(centeredHorizontal[$0]) }.sorted()
        let cutoffIndex = min(max(Int((Double(sortedHorizontal.count) * fraction).rounded()), 1) - 1, sortedHorizontal.count - 1)
        let horizontalCutoff = sortedHorizontal[cutoffIndex]
        var verticalTemplateSamples = goodSamples.filter { abs(centeredHorizontal[$0]) <= horizontalCutoff }
        if verticalTemplateSamples.count < 4 {
            verticalTemplateSamples = goodSamples
        }
        progress?(CorneoRetinalAnalysisProgress(
            fraction: 0.76,
            stage: "Fitting vertical CRD map",
            detail: "(verticalTemplateSamples.count) centered-gaze samples",
            blinkSampleCount: blinkMask.filter { $0 }.count,
            usableSampleCount: goodSamples.count,
            totalSampleCount: sampleCount,
            verticalTemplateSampleCount: verticalTemplateSamples.count,
            horizontalRMS: horizontalFit.timeCourse.rms
        ))
        let centeredVertical = centered(vertical, over: verticalTemplateSamples)
        let verticalTemplate = weightedTopography(
            data: corrected, predictor: centeredVertical, samples: verticalTemplateSamples, channels: selection.analysisIndices
        )
        let verticalFit = try fitComponent(
            data: corrected,
            roughPredictor: vertical,
            template: verticalTemplate,
            scalePositive: selection.lowerVEOGIndices,
            scaleNegative: selection.upperVEOGIndices,
            fitSamples: goodSamples,
            channels: selection.analysisIndices,
            error: .degenerateVerticalTemplate
        )
        subtract(verticalFit, from: &corrected, channels: selection.analysisIndices)

        progress?(CorneoRetinalAnalysisProgress(
            fraction: 0.96,
            stage: "Finalizing MAAC-2 analysis",
            detail: "Horizontal and vertical spatial regressions complete",
            blinkSampleCount: blinkMask.filter { $0 }.count,
            usableSampleCount: goodSamples.count,
            totalSampleCount: sampleCount,
            verticalTemplateSampleCount: verticalTemplateSamples.count,
            horizontalRMS: horizontalFit.timeCourse.rms,
            verticalRMS: verticalFit.timeCourse.rms
        ))

        return CorneoRetinalCorrectionResult(
            correctedData: corrected,
            diagnostics: CorneoRetinalDiagnostics(
                horizontalTopography: horizontalFit.topography,
                verticalTopography: verticalFit.topography,
                horizontalTimeCourse: horizontalFit.timeCourse,
                verticalTimeCourse: verticalFit.timeCourse,
                blinkSampleCount: blinkMask.filter { $0 }.count,
                templateSampleCount: goodSamples.count,
                verticalTemplateSampleCount: verticalTemplateSamples.count,
                correctedChannelCount: selection.analysisIndices.count
            )
        )
    }

    private static func differenceTrace(data: [[Float]], positive: [Int], negative: [Int]) -> [Double] {
        let sampleCount = data.first?.count ?? 0
        return (0..<sampleCount).map { sample in
            mean(positive.map { Double(data[$0][sample]) }) - mean(negative.map { Double(data[$0][sample]) })
        }
    }

    private static func centered(_ values: [Double], over samples: [Int]) -> [Double] {
        let center = mean(samples.map { values[$0] })
        return values.map { $0 - center }
    }

    private static func weightedTopography(
        data: [[Float]], predictor: [Double], samples: [Int], channels: [Int]
    ) -> [Double] {
        var result = [Double](repeating: 0, count: data.count)
        guard !samples.isEmpty else { return result }
        for channel in channels {
            result[channel] = samples.reduce(0) {
                $0 + Double(data[channel][$1]) * predictor[$1]
            } / Double(samples.count)
        }
        return result
    }

    private static func fitComponent(
        data: [[Float]],
        roughPredictor: [Double],
        template: [Double],
        scalePositive: [Int],
        scaleNegative: [Int],
        fitSamples: [Int],
        channels: [Int],
        error: CorneoRetinalError
    ) throws -> ComponentFit {
        let scale = abs(mean(scalePositive.map { template[$0] }) - mean(scaleNegative.map { template[$0] }))
        guard scale.isFinite, scale > 1e-12 else { throw error }
        var normalized = template.map { $0 / scale }
        let energy = channels.reduce(0) { $0 + normalized[$1] * normalized[$1] }
        guard energy.isFinite, energy > 1e-12 else { throw error }

        let spatialProjection = roughPredictor.indices.map { sample in
            channels.reduce(0) { $0 + normalized[$1] * Double(data[$1][sample]) }
        }
        let (intercept, slope) = linearRegression(
            x: fitSamples.map { roughPredictor[$0] },
            y: fitSamples.map { spatialProjection[$0] }
        )
        guard intercept.isFinite, slope.isFinite else { throw error }
        let timeCourse = roughPredictor.map { intercept + slope * $0 }
        // The returned map is the actual unit-amplitude scalp pattern used by
        // the pseudoinverse, which is the useful QC quantity.
        normalized = normalized.map { $0 / energy }
        return ComponentFit(
            topography: normalized.map(Float.init),
            timeCourse: timeCourse.map(Float.init)
        )
    }

    private static func linearRegression(x: [Double], y: [Double]) -> (Double, Double) {
        guard x.count == y.count, !x.isEmpty else { return (.nan, .nan) }
        let mx = mean(x)
        let my = mean(y)
        var covariance = 0.0
        var variance = 0.0
        for i in x.indices {
            let dx = x[i] - mx
            covariance += dx * (y[i] - my)
            variance += dx * dx
        }
        guard variance > 1e-12 else { return (.nan, .nan) }
        let slope = covariance / variance
        return (my - slope * mx, slope)
    }

    private static func subtract(_ fit: ComponentFit, from data: inout [[Float]], channels: [Int]) {
        for channel in channels {
            let loading = fit.topography[channel]
            for sample in data[channel].indices {
                data[channel][sample] -= loading * fit.timeCourse[sample]
            }
        }
    }

    private static func interpolate(_ values: [Double], keeping good: Set<Int>) -> [Double] {
        guard let first = good.min(), let last = good.max() else { return values }
        var output = values
        for sample in 0..<first { output[sample] = values[first] }
        var previous = first
        var sample = first + 1
        while sample <= last {
            if good.contains(sample) {
                let gap = sample - previous
                if gap > 1 {
                    for offset in 1..<gap {
                        let fraction = Double(offset) / Double(gap)
                        output[previous + offset] = values[previous] + (values[sample] - values[previous]) * fraction
                    }
                }
                previous = sample
            }
            sample += 1
        }
        if last + 1 < output.count {
            for index in (last + 1)..<output.count { output[index] = values[last] }
        }
        return output
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}

nonisolated private extension Array where Element == Float {
    var rms: Double {
        guard !isEmpty else { return 0 }
        return sqrt(reduce(0) { $0 + Double($1) * Double($1) } / Double(count))
    }
}
