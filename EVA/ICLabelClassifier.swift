//
//  ICLabelClassifier.swift
//  EVA
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
//  Runs the official ICLabel neural network through Core ML. The network
//  consumes the same three feature families as EEGLAB/MNE-ICALabel: a 32x32
//  scalp map, a 100-bin relative PSD, and a 100-lag autocorrelation trace.
//  ICLabel is attributed to SCCN and Luca Pion-Tonachini, Ken Kreutz-Delgado,
//  and Scott Makeig. No upstream license was found; see THIRD_PARTY_NOTICES.md.
//

import CoreML
import Foundation

nonisolated enum ICLabelClassifier {
    private static let classLabels = [
        "Brain",
        "Muscle",
        "Eye",
        "Heart",
        "Line Noise",
        "Channel Noise",
        "Other"
    ]

    static func suggestions(
        for decomposition: ICADecomposition,
        layout: SensorLayout?
    ) -> [Int: ICAComponentSuggestion] {
        guard let layout else { return [:] }
        guard let model = loadModel() else {
            log("ICLabel Core ML model was not found; using heuristic ICA labels.")
            return [:]
        }

        var suggestions: [Int: ICAComponentSuggestion] = [:]
        for component in 0..<decomposition.componentCount {
            guard let features = features(
                for: component,
                decomposition: decomposition,
                layout: layout
            ),
                let probabilities = predict(features: features, model: model)
            else {
                continue
            }
            suggestions[component] = suggestion(from: probabilities)
        }
        return suggestions
    }

    private static func loadModel() -> MLModel? {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all

        do {
            if let compiledURL = Bundle.main.url(forResource: "ICLabel", withExtension: "mlmodelc") {
                return try MLModel(contentsOf: compiledURL, configuration: configuration)
            }
            if let packageURL = Bundle.main.url(forResource: "ICLabel", withExtension: "mlpackage") {
                let compiledURL = try MLModel.compileModel(at: packageURL)
                return try MLModel(contentsOf: compiledURL, configuration: configuration)
            }
        } catch {
            log("ICLabel Core ML load failed: \(error.localizedDescription)")
        }
        return nil
    }

    private static func features(
        for component: Int,
        decomposition: ICADecomposition,
        layout: SensorLayout
    ) -> ICLabelFeatures? {
        guard decomposition.componentMaps.indices.contains(component),
              decomposition.componentSources.indices.contains(component) else {
            return nil
        }
        let rawMap = decomposition.componentMaps[component]
        let source = decomposition.componentSources[component]
        let map = normalizedTopography(rawMap)
        guard let image = scalpImage(map: map, layout: layout),
              let psd = relativePSD(source: source, samplingRate: decomposition.analysisSamplingRate),
              let autocorr = autocorrelation(source: source, samplingRate: decomposition.analysisSamplingRate) else {
            return nil
        }
        return ICLabelFeatures(image: image, psd: psd, autocorr: autocorr)
    }

    private static func predict(features: ICLabelFeatures, model: MLModel) -> [Double]? {
        // The SCCN ICLabel network expects the topoplot image row order used by
        // its MATLAB training path, where frontal/ocular activity lands in
        // lower image rows. EVA keeps SensorLayout +y anterior for drawing and
        // heuristics, so flip rows only at the Core ML input boundary.
        let orientedImage = verticallyFlipped(features.image)
        let imageVariants = [
            orientedImage,
            orientedImage.map { -$0 },
            horizontallyFlipped(orientedImage),
            horizontallyFlipped(orientedImage).map { -$0 }
        ]

        var averaged = [Double](repeating: 0, count: classLabels.count)
        var predictionCount = 0

        for image in imageVariants {
            guard let probabilities = prediction(
                image: image,
                psd: features.psd,
                autocorr: features.autocorr,
                model: model
            ) else {
                continue
            }
            for index in averaged.indices {
                averaged[index] += probabilities[index]
            }
            predictionCount += 1
        }

        guard predictionCount > 0 else { return nil }
        averaged = averaged.map { max(0, $0 / Double(predictionCount)) }
        let total = averaged.reduce(0, +)
        guard total > 0 else { return nil }
        return averaged.map { $0 / total }
    }

    private static func prediction(
        image: [Float],
        psd: [Float],
        autocorr: [Float],
        model: MLModel
    ) -> [Double]? {
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "image": try multiArray(values: image, shape: [1, 1, 32, 32]),
                "psd": try multiArray(values: psd, shape: [1, 1, 1, 100]),
                "autocorr": try multiArray(values: autocorr, shape: [1, 1, 1, 100])
            ])
            let output = try model.prediction(from: provider)
            guard let probabilities = output.featureValue(for: "probabilities")?.multiArrayValue,
                  probabilities.count >= classLabels.count else {
                return nil
            }
            return (0..<classLabels.count).map { probabilities[$0].doubleValue }
        } catch {
            log("ICLabel prediction failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func log(_ message: String) {
        Task { @MainActor in
            DebugLog.shared.log(message)
        }
    }

    private static func suggestion(from probabilities: [Double]) -> ICAComponentSuggestion {
        let ranked = probabilities.enumerated().sorted { $0.element > $1.element }
        guard let best = ranked.first else {
            return ICAComponentSuggestion(
                label: "Other",
                confidence: 0,
                reason: "ICLabel produced no class probabilities"
            )
        }

        let label = classLabels[best.offset]
        let confidence = min(max(best.element, 0), 1)
        let probabilityDictionary = Dictionary(
            uniqueKeysWithValues: zip(classLabels, probabilities.map { min(max($0, 0), 1) })
        )
        let topProbabilities = ranked.prefix(3).map {
            "\(classLabels[$0.offset]) \(Int(($0.element * 100).rounded()))%"
        }
        .joined(separator: ", ")

        return ICAComponentSuggestion(
            label: "\(label) \(Int((confidence * 100).rounded()))%",
            confidence: confidence,
            reason: "ICLabel (Core ML): \(topProbabilities). Classes: \(classLabels.joined(separator: ", ")).",
            probabilities: probabilityDictionary
        )
    }

    private static func multiArray(values: [Float], shape: [NSNumber]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape, dataType: .float32)
        for (index, value) in values.enumerated() where index < array.count {
            array[index] = NSNumber(value: value)
        }
        return array
    }

    private static func scalpImage(map: [Double], layout: SensorLayout) -> [Float]? {
        let sensors = layout.positions.compactMap { position -> (x: Double, y: Double, value: Double)? in
            guard position.channelIndex < map.count else { return nil }
            return (position.x, position.y, map[position.channelIndex])
        }
        guard sensors.count >= 4 else { return nil }

        let gridSize = 32
        var image = [Double](repeating: 0, count: gridSize * gridSize)
        for row in 0..<gridSize {
            let y = 1.0 - 2.0 * Double(row) / Double(gridSize - 1)
            for column in 0..<gridSize {
                let x = -1.0 + 2.0 * Double(column) / Double(gridSize - 1)
                guard hypot(x, y) <= 1 else { continue }
                image[row * gridSize + column] = interpolatedValue(x: x, y: y, sensors: sensors)
            }
        }

        guard let scale = image.map(abs).max(), scale.isFinite, scale > 1e-12 else {
            return [Float](repeating: 0, count: image.count)
        }
        return image.map { Float(0.99 * $0 / scale) }
    }

    private static func interpolatedValue(
        x: Double,
        y: Double,
        sensors: [(x: Double, y: Double, value: Double)]
    ) -> Double {
        var weightedSum = 0.0
        var weightTotal = 0.0

        for sensor in sensors {
            let dx = x - sensor.x
            let dy = y - sensor.y
            let distanceSquared = dx * dx + dy * dy
            if distanceSquared < 1e-6 {
                return sensor.value
            }
            let weight = 1.0 / pow(distanceSquared, 1.5)
            weightedSum += weight * sensor.value
            weightTotal += weight
        }

        return weightTotal > 0 ? weightedSum / weightTotal : 0
    }

    private static func relativePSD(source: [Double], samplingRate: Double) -> [Float]? {
        let values = centeredFiniteValues(source)
        guard samplingRate > 0, values.count >= 16 else { return nil }

        let nyquist = min(Int(floor(samplingRate / 2)), 100)
        guard nyquist > 0 else { return nil }

        let pointsPerWindow = min(values.count, max(16, Int(floor(samplingRate))))
        let window = hammingWindow(count: pointsPerWindow)
        let denominator = samplingRate * window.reduce(0) { $0 + $1 * $1 }
        guard denominator > 0 else { return nil }

        let starts = sampledWindowStarts(sampleCount: values.count, windowLength: pointsPerWindow, maxWindows: 160)
        guard !starts.isEmpty else { return nil }

        var binPowers = [[Double]](repeating: [], count: nyquist)
        for start in starts {
            for frequencyBin in 1...nyquist {
                var real = 0.0
                var imaginary = 0.0
                for offset in 0..<pointsPerWindow {
                    let phase = -2.0 * .pi * Double(frequencyBin * offset) / Double(pointsPerWindow)
                    let value = values[start + offset] * window[offset]
                    real += value * cos(phase)
                    imaginary += value * sin(phase)
                }
                var power = (real * real + imaginary * imaginary) * 2.0 / denominator
                if frequencyBin == Int(floor(samplingRate / 2)) {
                    power /= 2.0
                }
                binPowers[frequencyBin - 1].append(max(power, 1e-20))
            }
        }

        var psd = binPowers.map { powers in
            20.0 * log10(max(median(powers), 1e-20))
        }
        if let last = psd.last, psd.count < 100 {
            psd.append(contentsOf: Array(repeating: last, count: 100 - psd.count))
        }
        if psd.count > 100 {
            psd = Array(psd.prefix(100))
        }

        for lineIndex in [49, 59] where lineIndex > 0 && lineIndex + 1 < psd.count {
            if psd[lineIndex - 1] - psd[lineIndex] > 5,
               psd[lineIndex + 1] - psd[lineIndex] > 5 {
                psd[lineIndex] = (psd[lineIndex - 1] + psd[lineIndex + 1]) / 2
            }
        }

        guard let scale = psd.map(abs).max(), scale.isFinite, scale > 1e-12 else {
            return [Float](repeating: 0, count: 100)
        }
        return psd.map { Float(0.99 * $0 / scale) }
    }

    private static func autocorrelation(source: [Double], samplingRate: Double) -> [Float]? {
        let values = centeredFiniteValues(source)
        guard samplingRate > 0, values.count >= 4 else { return nil }

        let pointsPerWindow = min(values.count, max(4, Int((samplingRate * 3).rounded())))
        let starts = sampledWindowStarts(sampleCount: values.count, windowLength: pointsPerWindow, maxWindows: 120)
        guard !starts.isEmpty else { return nil }

        var result = [Double](repeating: 0, count: 100)
        for lagIndex in 0..<100 {
            let lag = max(1, Int((Double(lagIndex + 1) * samplingRate / 100.0).rounded()))
            var weightedCorrelation = 0.0
            var weightTotal = 0.0

            for start in starts where lag < pointsPerWindow {
                var numerator = 0.0
                var energy = 0.0
                for offset in lag..<pointsPerWindow {
                    let current = values[start + offset]
                    let previous = values[start + offset - lag]
                    numerator += current * previous
                    energy += current * current
                }
                guard energy > 1e-20 else { continue }
                let count = Double(pointsPerWindow - lag)
                weightedCorrelation += (numerator / energy) * count
                weightTotal += count
            }

            result[lagIndex] = weightTotal > 0 ? weightedCorrelation / weightTotal : 0
        }

        return result.map { Float(0.99 * min(max($0, -1), 1)) }
    }

    private static func horizontallyFlipped(_ image: [Float]) -> [Float] {
        let gridSize = 32
        var flipped = [Float](repeating: 0, count: image.count)
        for row in 0..<gridSize {
            for column in 0..<gridSize {
                flipped[row * gridSize + column] = image[row * gridSize + (gridSize - 1 - column)]
            }
        }
        return flipped
    }

    private static func verticallyFlipped(_ image: [Float]) -> [Float] {
        let gridSize = 32
        var flipped = [Float](repeating: 0, count: image.count)
        for row in 0..<gridSize {
            for column in 0..<gridSize {
                flipped[row * gridSize + column] = image[(gridSize - 1 - row) * gridSize + column]
            }
        }
        return flipped
    }

    private static func centeredFiniteValues(_ source: [Double]) -> [Double] {
        let finite = source.map { $0.isFinite ? $0 : 0 }
        guard !finite.isEmpty else { return [] }
        let mean = finite.reduce(0, +) / Double(finite.count)
        return finite.map { $0 - mean }
    }

    private static func hammingWindow(count: Int) -> [Double] {
        guard count > 1 else { return [1] }
        return (0..<count).map { index in
            0.54 - 0.46 * cos(2.0 * .pi * Double(index) / Double(count - 1))
        }
    }

    private static func sampledWindowStarts(
        sampleCount: Int,
        windowLength: Int,
        maxWindows: Int
    ) -> [Int] {
        guard sampleCount >= windowLength else { return [] }
        let step = max(windowLength / 2, 1)
        let starts = Array(stride(from: 0, through: sampleCount - windowLength, by: step))
        guard starts.count > maxWindows, maxWindows > 1 else { return starts }

        return (0..<maxWindows).map { index in
            let sourceIndex = Int((Double(index) * Double(starts.count - 1) / Double(maxWindows - 1)).rounded())
            return starts[sourceIndex]
        }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

nonisolated private struct ICLabelFeatures {
    var image: [Float]
    var psd: [Float]
    var autocorr: [Float]
}
