//
//  ICAComponentAutoLabeler.swift
//  SummerEEGDemo
//
//  Lightweight ICLabel-inspired component labeling heuristics for classroom
//  artifact exploration. This is not the ICLabel trained classifier; it uses
//  transparent scalp-map and time-course rules to suggest editable labels.
//

import Accelerate
import Foundation

nonisolated enum ICAComponentAutoLabeler {
    static func suggestions(
        for decomposition: ICADecomposition,
        layout: SensorLayout?
    ) -> [Int: ICAComponentSuggestion] {
        var suggestions: [Int: ICAComponentSuggestion] = [:]

        for component in 0..<decomposition.componentCount {
            let map = decomposition.componentMaps.indices.contains(component)
                ? normalizedTopography(decomposition.componentMaps[component])
                : []
            let source = decomposition.componentSources.indices.contains(component)
                ? decomposition.componentSources[component]
                : []
            suggestions[component] = suggestion(
                map: map,
                source: source,
                samplingRate: decomposition.analysisSamplingRate,
                layout: layout
            )
        }

        return suggestions
    }

    private static func suggestion(
        map: [Double],
        source: [Double],
        samplingRate: Double,
        layout: SensorLayout?
    ) -> ICAComponentSuggestion {
        let mapFeatures = scalpFeatures(map: map, layout: layout)
        let timeFeatures = timeFeatures(source: source, samplingRate: samplingRate)

        let ocularBias = max(mapFeatures.anteriorBias, mapFeatures.posteriorBias)
        // Eye: frontal topography + low-frequency-dominated spectrum (slow drift).
        let eyeScore = 0.46 * ocularBias
            + 0.30 * timeFeatures.lowFrequencyFraction
            + 0.14 * mapFeatures.smoothness
            + 0.10 * timeFeatures.slowness
        // Muscle: lateral/edge topography + power rising into the high band.
        let muscleMapBias = max(mapFeatures.lateralBias, mapFeatures.edgeBias)
        let muscleScore = (timeFeatures.highFrequencyFraction > 0.5 && muscleMapBias > 0.5)
            ? 0.50 * timeFeatures.highFrequencyFraction + 0.34 * muscleMapBias + 0.16 * timeFeatures.spikiness
            : 0.18 * min(timeFeatures.highFrequencyFraction, muscleMapBias)
        // Heart: rhythmic (~1 Hz) source, broad/smooth scalp pattern.
        let heartScore = timeFeatures.rhythmicity > 0.32
            ? 0.62 * timeFeatures.rhythmicity + 0.20 * timeFeatures.spikiness + 0.18 * mapFeatures.smoothness
            : 0.14 * timeFeatures.rhythmicity
        // Line noise: a sharp peak near the mains frequency (only visible when the
        // analysis Nyquist is above it, i.e. higher Search Hz).
        let lineNoiseScore = timeFeatures.lineNoise > 0.5
            ? 0.80 * timeFeatures.lineNoise + 0.20 * mapFeatures.focality
            : 0.10 * timeFeatures.lineNoise
        // Channel noise: a single-sensor-dominated, very focal map.
        let channelNoiseScore = mapFeatures.focality > 0.68
            ? 0.78 * mapFeatures.focality + 0.12 * timeFeatures.spikiness + 0.10 * (1 - mapFeatures.dipolarity)
            : 0.16 * mapFeatures.focality
        // Brain: dipolar (low-order spatial) map, a 1/f spectrum, and ideally an
        // alpha peak — the strongest physiological cue ICLabel relies on.
        let brainScore = 0.34 * mapFeatures.dipolarity
            + 0.24 * timeFeatures.oneOverFShape
            + 0.20 * timeFeatures.alphaPeak
            + 0.12 * mapFeatures.smoothness
            + 0.10 * (1 - max(mapFeatures.focality, timeFeatures.spikiness))

        let candidates: [(String, Double, String)] = [
            ("Eye", eyeScore, "frontal map with low-frequency-dominated activity"),
            ("Muscle", muscleScore, "high-frequency power with lateral/edge topography"),
            ("Heart", heartScore, "rhythmic ~1 Hz source with broad scalp pattern"),
            ("Line Noise", lineNoiseScore, "sharp spectral peak near the mains frequency"),
            ("Channel Noise", channelNoiseScore, "very focal, non-dipolar map"),
            ("Brain", brainScore, "dipolar map with a 1/f spectrum and alpha activity")
        ]

        guard let best = candidates.max(by: { $0.1 < $1.1 }) else {
            return ICAComponentSuggestion(label: "Other", confidence: 0, reason: "No component features available")
        }

        if best.1 < 0.48 {
            return ICAComponentSuggestion(label: "Other", confidence: best.1, reason: "No artifact class strongly matched")
        }

        return ICAComponentSuggestion(
            label: "\(best.0) \(Int((min(max(best.1, 0), 1) * 100).rounded()))%",
            confidence: min(max(best.1, 0), 1),
            reason: best.2
        )
    }

    private static func scalpFeatures(map: [Double], layout: SensorLayout?) -> ScalpFeatures {
        guard !map.isEmpty else { return ScalpFeatures() }
        let finite = map.map { $0.isFinite ? $0 : 0 }
        let absValues = finite.map(abs)
        let meanAbs = max(absValues.reduce(0, +) / Double(absValues.count), 1e-9)
        let focality = focalityScore(absValues)

        guard let layout else {
            return ScalpFeatures(focality: focality, smoothness: 1 - focality)
        }

        let dipolarity = dipolarityScore(map: finite, layout: layout)

        var anterior = 0.0
        var posterior = 0.0
        var lateral = 0.0
        var edge = 0.0
        var center = 0.0
        var anteriorCount = 0.0
        var posteriorCount = 0.0
        var lateralCount = 0.0
        var edgeCount = 0.0
        var centerCount = 0.0

        for position in layout.positions where position.channelIndex < absValues.count {
            let value = absValues[position.channelIndex]
            let radius = hypot(position.x, position.y)
            if position.y > 0.32 {
                anterior += value
                anteriorCount += 1
            }
            if position.y < -0.20 {
                posterior += value
                posteriorCount += 1
            }
            if abs(position.x) > 0.55 {
                lateral += value
                lateralCount += 1
            }
            if radius > 0.72 {
                edge += value
                edgeCount += 1
            }
            if radius < 0.45 {
                center += value
                centerCount += 1
            }
        }

        let anteriorMean = anterior / max(anteriorCount, 1)
        let posteriorMean = posterior / max(posteriorCount, 1)
        let lateralMean = lateral / max(lateralCount, 1)
        let edgeMean = edge / max(edgeCount, 1)
        let centerMean = center / max(centerCount, 1)

        let anteriorBias = clamp01((anteriorMean - posteriorMean) / (meanAbs * 1.8) + 0.35)
        let posteriorBias = clamp01((posteriorMean - anteriorMean) / (meanAbs * 1.8) + 0.35)
        let lateralBias = clamp01((lateralMean - centerMean) / (meanAbs * 1.7) + 0.25)
        let edgeBias = clamp01((edgeMean - centerMean) / (meanAbs * 1.6) + 0.25)
        let smoothness = clamp01(1 - focality + min(centerMean / max(edgeMean, 1e-9), 1) * 0.25)

        return ScalpFeatures(
            anteriorBias: anteriorBias,
            posteriorBias: posteriorBias,
            lateralBias: lateralBias,
            edgeBias: edgeBias,
            focality: focality,
            smoothness: smoothness,
            dipolarity: dipolarity
        )
    }

    /// Proxy for ICLabel-style dipolarity: how much of the topography's variance
    /// is explained by a smooth low-order spatial surface over the sensor
    /// positions. Physiological/dipolar maps fit well (high R²); fragmented
    /// channel-noise or muscle maps do not.
    private static func dipolarityScore(map: [Double], layout: SensorLayout) -> Double {
        // Basis: [1, x, y, x², y², xy] evaluated at each sensor position.
        var xs: [Double] = []
        var ys: [Double] = []
        var values: [Double] = []
        for position in layout.positions where position.channelIndex < map.count {
            xs.append(position.x)
            ys.append(position.y)
            values.append(map[position.channelIndex])
        }
        let count = values.count
        guard count >= 12 else { return 0 }

        let basisSize = 6
        var basis = [[Double]](repeating: [Double](repeating: 0, count: basisSize), count: count)
        for index in 0..<count {
            let x = xs[index], y = ys[index]
            basis[index] = [1, x, y, x * x, y * y, x * y]
        }

        // Normal equations: (BᵀB) c = Bᵀv, solved with Gaussian elimination.
        var ata = [[Double]](repeating: [Double](repeating: 0, count: basisSize), count: basisSize)
        var atv = [Double](repeating: 0, count: basisSize)
        for index in 0..<count {
            let row = basis[index]
            let value = values[index]
            for i in 0..<basisSize {
                atv[i] += row[i] * value
                for j in 0..<basisSize {
                    ata[i][j] += row[i] * row[j]
                }
            }
        }
        guard let coefficients = solveLinearSystem(ata, atv) else { return 0 }

        let mean = values.reduce(0, +) / Double(count)
        var residual = 0.0
        var totalVariance = 0.0
        for index in 0..<count {
            var fitted = 0.0
            for k in 0..<basisSize { fitted += coefficients[k] * basis[index][k] }
            residual += (values[index] - fitted) * (values[index] - fitted)
            totalVariance += (values[index] - mean) * (values[index] - mean)
        }
        guard totalVariance > 1e-12 else { return 0 }
        return clamp01(1 - residual / totalVariance)
    }

    private static func solveLinearSystem(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        var a = matrix
        var b = rhs
        for column in 0..<n {
            var pivot = column
            var pivotValue = abs(a[column][column])
            for row in (column + 1)..<n where abs(a[row][column]) > pivotValue {
                pivot = row
                pivotValue = abs(a[row][column])
            }
            if pivotValue < 1e-12 { return nil }
            if pivot != column { a.swapAt(pivot, column); b.swapAt(pivot, column) }
            let diagonal = a[column][column]
            for row in 0..<n where row != column {
                let factor = a[row][column] / diagonal
                if factor == 0 { continue }
                for c in column..<n { a[row][c] -= factor * a[column][c] }
                b[row] -= factor * b[column]
            }
        }
        return (0..<n).map { b[$0] / a[$0][$0] }
    }

    private static func timeFeatures(source: [Double], samplingRate: Double) -> TimeFeatures {
        let finite = source.filter(\.isFinite)
        guard finite.count > 4 else { return TimeFeatures() }

        let mean = finite.reduce(0, +) / Double(finite.count)
        let centered = finite.map { $0 - mean }
        let variance = centered.reduce(0) { $0 + $1 * $1 } / Double(centered.count)
        let sd = sqrt(max(variance, 1e-12))
        let fourth = centered.reduce(0) { $0 + pow($1 / sd, 4) } / Double(centered.count)
        let spikiness = clamp01((fourth - 3) / 12)

        let stride = max(centered.count / 10_000, 1)
        var signChanges = 0
        var comparisons = 0
        var previous = centered[0]
        for index in Swift.stride(from: stride, to: centered.count, by: stride) {
            let value = centered[index]
            if (previous < 0 && value >= 0) || (previous >= 0 && value < 0) {
                signChanges += 1
            }
            previous = value
            comparisons += 1
        }
        let signChangeRate = Double(signChanges) / Double(max(comparisons, 1))
        let slowness = clamp01((0.22 - signChangeRate) / 0.22)

        let spectrum = powerSpectrum(centered, samplingRate: samplingRate)
        let rhythmicity = autocorrelationRhythmicity(centered, samplingRate: samplingRate)

        return TimeFeatures(
            slowness: slowness,
            spikiness: spikiness,
            rhythmicity: rhythmicity,
            lowFrequencyFraction: spectrum.lowFraction,
            highFrequencyFraction: spectrum.highFraction,
            alphaPeak: spectrum.alphaPeak,
            oneOverFShape: spectrum.oneOverFShape,
            lineNoise: spectrum.lineNoise
        )
    }

    /// Welch power spectral density and derived band features. Returns fractions
    /// of total power in low (<3 Hz) and high (>20 Hz) bands, an alpha-peak (8–12
    /// Hz) prominence, a 1/f-decay score, and a mains-frequency peak score.
    private static func powerSpectrum(_ values: [Double], samplingRate: Double) -> SpectralFeatures {
        guard samplingRate > 0, values.count >= 64 else { return SpectralFeatures() }

        let log2n: vDSP_Length = 8           // 256-point segments
        let length = 1 << log2n              // 256
        let half = length / 2
        guard values.count >= length, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return SpectralFeatures()
        }
        defer { vDSP_destroy_fftsetup(setup) }

        // Hann window, up to 40 overlapping segments spread across the signal.
        var window = [Float](repeating: 0, count: length)
        vDSP_hann_window(&window, vDSP_Length(length), Int32(vDSP_HANN_NORM))

        let maxSegments = 40
        let span = values.count - length
        let segmentCount = max(1, min(maxSegments, span / (length / 2) + 1))
        let step = segmentCount > 1 ? span / (segmentCount - 1) : 0

        var averaged = [Float](repeating: 0, count: half)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var actualSegments = 0

        for segment in 0..<segmentCount {
            let start = segment * step
            guard start + length <= values.count else { break }
            var windowed = [Float](repeating: 0, count: length)
            for index in 0..<length {
                windowed[index] = Float(values[start + index]) * window[index]
            }
            real.withUnsafeMutableBufferPointer { realPtr in
                imaginary.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    windowed.withUnsafeBytes { raw in
                        let complex = raw.bindMemory(to: DSPComplex.self)
                        vDSP_ctoz(complex.baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    var magnitudes = [Float](repeating: 0, count: half)
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
                    vDSP_vadd(averaged, 1, magnitudes, 1, &averaged, 1, vDSP_Length(half))
                }
            }
            actualSegments += 1
        }

        guard actualSegments > 0 else { return SpectralFeatures() }
        let power = averaged.map { Double($0) / Double(actualSegments) }
        let binHz = samplingRate / Double(length)
        let nyquist = samplingRate / 2

        func bandPower(_ low: Double, _ high: Double) -> Double {
            let lowBin = max(Int((low / binHz).rounded()), 1)
            let highBin = min(Int((high / binHz).rounded()), half - 1)
            guard highBin >= lowBin else { return 0 }
            return power[lowBin...highBin].reduce(0, +)
        }

        let total = power[1..<half].reduce(0, +)
        guard total > 1e-12 else { return SpectralFeatures() }

        let lowFraction = bandPower(0.5, 3) / total
        let highFraction = bandPower(20, min(nyquist, 90)) / total

        // Alpha prominence: 8–12 Hz peak relative to the 5–7 / 13–16 shoulders.
        let alphaBand = bandPower(8, 12) / max(1, (12 - 8) / binHz)
        let shoulder = (bandPower(5, 7) + bandPower(13, 16)) / max(1, (2 + 3) / binHz)
        let alphaPeak = clamp01((alphaBand / max(shoulder, 1e-12) - 1.1) / 1.4)

        // 1/f decay: negative slope of log power vs log frequency over 2–40 Hz.
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, count = 0.0
        let lowBin = max(Int((2 / binHz).rounded()), 1)
        let highBin = min(Int((min(40, nyquist) / binHz).rounded()), half - 1)
        if highBin > lowBin {
            for bin in lowBin...highBin {
                let x = log(Double(bin) * binHz)
                let y = log(max(power[bin], 1e-20))
                sx += x; sy += y; sxx += x * x; sxy += x * y; count += 1
            }
            let denominator = count * sxx - sx * sx
            let slope = abs(denominator) > 1e-12 ? (count * sxy - sx * sy) / denominator : 0
            // Brain spectra fall off with roughly slope −1 to −2.
            let oneOverFShape = clamp01((-slope - 0.3) / 1.6)
            // Mains peak (50/60 Hz) prominence, only meaningful below Nyquist.
            var lineNoise = 0.0
            for mains in [50.0, 60.0] where mains + 2 < nyquist {
                let peak = bandPower(mains - 1.5, mains + 1.5)
                let around = (bandPower(mains - 6, mains - 3) + bandPower(mains + 3, mains + 6))
                if around > 1e-12 {
                    lineNoise = max(lineNoise, clamp01((peak / around - 1.5) / 4))
                }
            }
            return SpectralFeatures(
                lowFraction: clamp01(lowFraction),
                highFraction: clamp01(highFraction),
                alphaPeak: alphaPeak,
                oneOverFShape: oneOverFShape,
                lineNoise: lineNoise
            )
        }

        return SpectralFeatures(
            lowFraction: clamp01(lowFraction),
            highFraction: clamp01(highFraction),
            alphaPeak: alphaPeak,
            oneOverFShape: 0,
            lineNoise: 0
        )
    }

    private static func focalityScore(_ absValues: [Double]) -> Double {
        guard absValues.count > 6 else { return 0 }

        let sortedDescending = absValues.sorted(by: >)
        let topCount = min(5, sortedDescending.count)
        let topMean = sortedDescending.prefix(topCount).reduce(0, +) / Double(topCount)
        let rest = sortedDescending.dropFirst(topCount)
        let restMean = max(rest.reduce(0, +) / Double(max(rest.count, 1)), 1e-9)
        let dominance = topMean / restMean

        // Channel-noise ICs usually have a small sensor neighborhood dominating
        // the rest of the map. A simple max/mean ratio over-fires on normalized
        // topographies, so use a top-neighborhood-to-rest contrast instead.
        return clamp01((dominance - 2.4) / 4.0)
    }

    private static func autocorrelationRhythmicity(_ values: [Double], samplingRate: Double) -> Double {
        guard samplingRate > 0, values.count > Int(samplingRate) else { return 0 }
        let sampleStride = max(values.count / 8_000, 1)
        let sampled = stride(from: 0, to: values.count, by: sampleStride).map { values[$0] }
        let effectiveRate = samplingRate / Double(sampleStride)
        let minLag = max(Int((0.45 * effectiveRate).rounded()), 1)
        let maxLag = min(Int((1.35 * effectiveRate).rounded()), sampled.count / 2)
        guard maxLag > minLag else { return 0 }

        let energy = sampled.reduce(0) { $0 + $1 * $1 }
        guard energy > 0 else { return 0 }

        var best = 0.0
        for lag in minLag...maxLag {
            var total = 0.0
            for index in lag..<sampled.count {
                total += sampled[index] * sampled[index - lag]
            }
            best = max(best, total / energy)
        }
        return clamp01((best - 0.08) / 0.35)
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

nonisolated private struct ScalpFeatures {
    var anteriorBias = 0.0
    var posteriorBias = 0.0
    var lateralBias = 0.0
    var edgeBias = 0.0
    var focality = 0.0
    var smoothness = 0.0
    var dipolarity = 0.0
}

nonisolated private struct TimeFeatures {
    var slowness = 0.0
    var spikiness = 0.0
    var rhythmicity = 0.0
    var lowFrequencyFraction = 0.0
    var highFrequencyFraction = 0.0
    var alphaPeak = 0.0
    var oneOverFShape = 0.0
    var lineNoise = 0.0
}

nonisolated private struct SpectralFeatures {
    var lowFraction = 0.0
    var highFraction = 0.0
    var alphaPeak = 0.0
    var oneOverFShape = 0.0
    var lineNoise = 0.0
}
