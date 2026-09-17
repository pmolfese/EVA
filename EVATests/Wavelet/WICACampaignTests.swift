//
//  WICACampaignTests.swift
//  EVATests
//
//  Gated simulator campaign for choosing which ICA components should be
//  rejected, wavelet-cleaned, or retained. This is intentionally not part of
//  the ordinary test suite: it performs one real ICA fit per campaign cell.
//

import Foundation
import Testing
@testable import EVA

struct WICACampaignTests {
    private enum Artifact: String, CaseIterable {
        case blink, emg, pop
    }

    private struct Row {
        var artifact: String
        var severity: String
        var seed: UInt64
        var channelCount: Int
        var durationSeconds: Double
        var mixingFraction: Double
        var icaMethod: String
        var method: String
        var artifactReduction: Double
        var rmse: Double
        var transientPreservation: Double
        var components: String
        var labelArtifactEnergyRecall: Double
        var icaSeconds: Double
        var icaIterations: Int
        var icaFinalChange: Double
        var decompositionComponentCount: Int
        var oracleComponentCount: Int
        var topArtifactEnergyFraction: Double
    }

    private struct RoutingRow {
        var artifact: String
        var severity: String
        var seed: UInt64
        var channelCount: Int
        var mixingFraction: Double
        var component: Int
        var predictedLabel: String
        var confidence: Double
        var brainProbability: Double
        var muscleProbability: Double
        var eyeProbability: Double
        var heartProbability: Double
        var lineNoiseProbability: Double
        var channelNoiseProbability: Double
        var otherProbability: Double
        var artifactEnergyFraction: Double
        var sourceEnergyFraction: Double
        var artifactPurity: Double
    }

    private struct CellResult {
        var rows: [Row]
        var routing: [RoutingRow]
    }

    private struct Fixture {
        var artifact: Artifact
        var severity: String
        var seed: UInt64
        var channelCount: Int
        var durationSeconds: Double
        var sourceCount: Int
        var mixingFraction: Double
        var rate: Double
        var clean: [[Double]]
        var artifactLayer: [[Float]]
        var signal: MFFSignalData
        var transientTruth: BrainTransientInjection
        var montage: Montage
    }

    private struct CampaignSettings {
        var seedCount: Int
        var channelCounts: [Int]
        var durationSeconds: Double
        var sourceCount: Int

        static func read(seedVariable: String) -> CampaignSettings {
            let environment = ProcessInfo.processInfo.environment
            let seedCount = max(1, Int(environment[seedVariable] ?? "10") ?? 10)
            let channels = (environment["EVA_WICA_CHANNELS"] ?? "64,128,256")
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .filter { $0 >= 64 }
            return CampaignSettings(
                seedCount: seedCount,
                channelCounts: channels.isEmpty ? [64, 128, 256] : channels,
                durationSeconds: max(
                    60, Double(environment["EVA_WICA_DURATION_SECONDS"] ?? "120") ?? 120
                ),
                sourceCount: max(8, Int(environment["EVA_WICA_SOURCE_COUNT"] ?? "20") ?? 20)
            )
        }
    }

    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["EVA_WICA_CAMPAIGN"] == "1"
    }

    private static var algorithmComparisonIsEnabled: Bool {
        ProcessInfo.processInfo.environment["EVA_WICA_ICA_CAMPAIGN"] == "1"
    }

    private static var mixedCampaignIsEnabled: Bool {
        ProcessInfo.processInfo.environment["EVA_WICA_MIXED_CAMPAIGN"] == "1"
    }

    @Test func simulatorCampaign() async throws {
        guard Self.isEnabled else {
            print("WICACampaignTests: set EVA_WICA_CAMPAIGN=1 to run. Skipping.")
            return
        }

        let settings = CampaignSettings.read(seedVariable: "EVA_WICA_CAMPAIGN_SEEDS")
        let severities = [("low", 0.5), ("medium", 1.0), ("high", 2.0)]
        let baseSeed: UInt64 = 20_260_821
        var rows: [Row] = []
        var routing: [RoutingRow] = []

        print("=== High-density W-ICA baseline: \(settings.seedCount) seeds × 3 artifacts × 3 severities × \(settings.channelCounts) channels ===")
        for channelCount in settings.channelCounts {
            for artifact in Artifact.allCases {
                for (severity, scale) in severities {
                    for seedOffset in 0..<settings.seedCount {
                        let seed = baseSeed + UInt64(seedOffset)
                        let command = Self.simulatorCommand(
                            artifact: artifact, severity: severity, scale: scale, seed: seed,
                            channelCount: channelCount,
                            durationSeconds: settings.durationSeconds,
                            sourceCount: settings.sourceCount
                        )
                        print("\n+ \(command)")
                        let cell = try Self.runCell(
                            artifact: artifact, severity: severity, scale: scale, seed: seed,
                            channelCount: channelCount,
                            durationSeconds: settings.durationSeconds,
                            sourceCount: settings.sourceCount
                        )
                        rows += cell.rows
                        routing += cell.routing
                        try Self.writeBaselineSnapshot(
                            rows: rows, routing: routing, settings: settings
                        )
                    }
                }
            }
        }
        print("\n\(Self.report(rows, seedCount: settings.seedCount))")
    }

    @Test func compareICAAlgorithms() async throws {
        guard Self.algorithmComparisonIsEnabled else {
            print("WICACampaignTests: set EVA_WICA_ICA_CAMPAIGN=1 to compare ICA algorithms. Skipping.")
            return
        }

        let settings = CampaignSettings.read(seedVariable: "EVA_WICA_ICA_CAMPAIGN_SEEDS")
        let algorithms: [ICAMethod] = [.picard, .picardO, .fastICA]
        let baseSeed: UInt64 = 20_260_821
        var rows: [Row] = []
        var failures: [String] = []

        print("=== Paired high-density ICA comparison: \(settings.seedCount) seeds × 3 artifacts × 3 algorithms × \(settings.channelCounts) channels ===")
        for channelCount in settings.channelCounts {
            for artifact in Artifact.allCases {
                for seedOffset in 0..<settings.seedCount {
                    let seed = baseSeed + UInt64(seedOffset)
                    let command = Self.simulatorCommand(
                        artifact: artifact, severity: "medium", scale: 1, seed: seed,
                        channelCount: channelCount,
                        durationSeconds: settings.durationSeconds,
                        sourceCount: settings.sourceCount
                    )
                    print("\n+ \(command)")
                    let fixture = try Self.makeFixture(
                        artifact: artifact,
                        severity: "medium",
                        scale: 1,
                        seed: seed,
                        channelCount: channelCount,
                        durationSeconds: settings.durationSeconds,
                        sourceCount: settings.sourceCount,
                        mixingFraction: 0
                    )
                    for algorithm in algorithms {
                        print("+ EVA ICA --method \(algorithm.rawValue) --components \(channelCount) --fit-rate 100 --max-iterations 250")
                        do {
                            rows += try Self.runCell(
                                artifact: artifact,
                                severity: "medium",
                                scale: 1,
                                seed: seed,
                                channelCount: channelCount,
                                durationSeconds: settings.durationSeconds,
                                sourceCount: settings.sourceCount,
                                comparisonOnly: true,
                                icaMethod: algorithm,
                                preparedFixture: fixture
                            ).rows
                        } catch {
                            let failure = "\(artifact.rawValue),\(channelCount),\(seed),\(algorithm.rawValue): \(error)"
                            failures.append(failure)
                            print("!! \(failure)")
                        }
                        try Self.writeAlgorithmSnapshot(
                            rows: rows, failures: failures, settings: settings
                        )
                    }
                }
            }
        }
        let report = Self.algorithmReport(
            rows, failures: failures, seedCount: settings.seedCount
        )
        print("\n\(report)")
    }

    @Test func mixedComponentCampaign() async throws {
        guard Self.mixedCampaignIsEnabled else {
            print("WICACampaignTests: set EVA_WICA_MIXED_CAMPAIGN=1 to run mixed-component fixtures. Skipping.")
            return
        }
        let settings = CampaignSettings.read(seedVariable: "EVA_WICA_MIXED_CAMPAIGN_SEEDS")
        let fractions = [0.35, 0.65, 0.90]
        let baseSeed: UInt64 = 20_260_821
        var rows: [Row] = []
        var routing: [RoutingRow] = []

        print("=== Mixed-component campaign: \(settings.seedCount) seeds × 3 artifacts × 3 mixing fractions × \(settings.channelCounts) channels ===")
        for channelCount in settings.channelCounts {
            for artifact in Artifact.allCases {
                for mixingFraction in fractions {
                    for seedOffset in 0..<settings.seedCount {
                        let seed = baseSeed + UInt64(seedOffset)
                        print("\n+ " + Self.simulatorCommand(
                            artifact: artifact, severity: "medium", scale: 1, seed: seed,
                            channelCount: channelCount,
                            durationSeconds: settings.durationSeconds,
                            sourceCount: settings.sourceCount
                        ) + " # neural-topography-mix=\(mixingFraction)")
                        let cell = try Self.runCell(
                            artifact: artifact, severity: "medium", scale: 1, seed: seed,
                            channelCount: channelCount,
                            durationSeconds: settings.durationSeconds,
                            sourceCount: settings.sourceCount,
                            mixingFraction: mixingFraction,
                            includeSoftThresholds: true
                        )
                        rows += cell.rows
                        routing += cell.routing
                        try Self.writeMixedSnapshot(
                            rows: rows, routing: routing, settings: settings
                        )
                    }
                }
            }
        }
        print("\n\(Self.mixedReport(rows, seedCount: settings.seedCount))")
    }

    private static func makeFixture(
        artifact: Artifact,
        severity: String,
        scale: Double,
        seed: UInt64,
        channelCount: Int,
        durationSeconds: Double,
        sourceCount: Int,
        mixingFraction: Double
    ) throws -> Fixture {
        let rate = 200.0
        var config = SimulationConfig.default
        config.seed = seed
        config.eegGenerationModel = .dipole
        config.nonGaussianSources = .default
        config.recordingReference = .average
        config.gradientEnabled = false
        config.bcgEnabled = false
        config.channelCount = channelCount
        config.samplingRate = rate
        config.durationSeconds = durationSeconds
        config.dipoleSourceCount = min(sourceCount, max(1, channelCount - 1))
        config.brainTransients = BrainTransientConfig(
            ratePerMinute: 30, amplitudeMicrovolts: 150
        )

        let montage = Montage.standard(count: config.channelCount)
        var eeg = try DipoleEEGGenerator.generate(config: config, montage: montage)
        var transientSource = GaussianSource(seed: seed &+ 0x5851_F42D_4C95_7F2D)
        let transientTruth = try #require(BrainTransientModel.inject(
            into: &eeg.channels, config: config, montage: montage, source: &transientSource
        ))
        let clean = eeg.channels
        var contaminated = clean

        switch artifact {
        case .blink:
            config.blinksPerMinute = 20
            config.blinkAmplitudeMicrovolts = 100 * scale
            var source = GaussianSource(seed: SimulationSeedStreams.ocular(base: seed))
            _ = OcularArtifactModel.inject(
                into: &contaminated, config: config, montage: montage, source: &source
            )
        case .emg:
            config.emg = EMGConfig(
                burstsPerMinute: 15,
                amplitudeMicrovolts: 50 * scale,
                burstDurationSeconds: 0.75,
                lowHz: 20,
                highHz: 90,
                carrierAutocorrelation: nil
            )
            var source = GaussianSource(seed: SimulationSeedStreams.emg(base: seed))
            _ = EMGArtifactModel.inject(
                into: &contaminated, config: config, montage: montage, source: &source
            )
        case .pop:
            config.badChannels = [7: .pop]
            var source = GaussianSource(seed: SimulationSeedStreams.defects(base: seed))
            var standard = clean
            _ = ChannelDefectModel.apply(to: &standard, config: config, source: &source)
            for channel in contaminated.indices {
                for sample in contaminated[channel].indices {
                    contaminated[channel][sample] += scale
                        * (standard[channel][sample] - clean[channel][sample])
                }
            }
        }

        var artifactLayer = zip(contaminated, clean).map { noisy, reference in
            zip(noisy, reference).map { Float($0 - $1) }
        }
        if mixingFraction > 0,
           let neuralMap = eeg.sourceSpace?.leadField.matrixMicrovoltsPerNanoampereMeter
                .map({ $0.first ?? 0 }) {
            artifactLayer = spatiallyMixedArtifactLayer(
                artifactLayer, neuralMap: neuralMap, fraction: mixingFraction
            )
            contaminated = zip(clean, artifactLayer).map { reference, artifact in
                zip(reference, artifact).map { $0 + Double($1) }
            }
        }
        return Fixture(
            artifact: artifact,
            severity: severity,
            seed: seed,
            channelCount: channelCount,
            durationSeconds: durationSeconds,
            sourceCount: config.dipoleSourceCount,
            mixingFraction: mixingFraction,
            rate: rate,
            clean: clean,
            artifactLayer: artifactLayer,
            signal: SyntheticSignal.make(
                contaminated.map { $0.map(Float.init) }, samplingRate: rate
            ),
            transientTruth: transientTruth,
            montage: montage
        )
    }

    private static func runCell(
        artifact: Artifact,
        severity: String,
        scale: Double,
        seed: UInt64,
        channelCount: Int = 64,
        durationSeconds: Double = 120,
        sourceCount: Int = 20,
        mixingFraction: Double = 0,
        includeSoftThresholds: Bool = false,
        comparisonOnly: Bool = false,
        icaMethod: ICAMethod = .fastICA,
        preparedFixture: Fixture? = nil
    ) throws -> CellResult {
        let fixture = try preparedFixture ?? Self.makeFixture(
            artifact: artifact,
            severity: severity,
            scale: scale,
            seed: seed,
            channelCount: channelCount,
            durationSeconds: durationSeconds,
            sourceCount: sourceCount,
            mixingFraction: mixingFraction
        )
        let rate = fixture.rate
        let clean = fixture.clean
        let artifactLayer = fixture.artifactLayer
        let signal = fixture.signal
        let transientTruth = fixture.transientTruth
        let montage = fixture.montage

        let fitStart = Date()
        let decomposition = try ICAArtifactDetector.fit(
            signal: signal,
            configuration: ICAConfiguration(
                method: icaMethod,
                componentCount: channelCount,
                varianceThreshold: 0.99999,
                averageReference: true,
                downsampleRate: 100,
                maxIterations: 250,
                learningRate: nil,
                fitFilter: nil,
                convergenceTolerance: 1e-7,
                minimumIterations: 1
            )
        )
        let fitSeconds = Date().timeIntervalSince(fitStart)
        let layout = Self.layout(for: montage)
        let suggestions = ICAComponentAutoLabeler.suggestions(
            for: decomposition, layout: layout
        )
        let artifactPrefixes = ["Eye", "Muscle", "Heart", "Line Noise", "Channel Noise"]
        let labelSelected = Set(suggestions.compactMap { component, suggestion in
            artifactPrefixes.contains(where: { suggestion.label.hasPrefix($0) })
                ? component : nil
        })

        let energy = Self.componentArtifactEnergy(
            artifactLayer, decomposition: decomposition
        )
        let oracleSelected = Self.componentsAccountingFor(
            0.90, of: energy.artifactContribution
        )
        let pure = Set(oracleSelected.filter { energy.purity[$0, default: 0] >= 0.80 })
        let mixed = oracleSelected.subtracting(pure)
        let totalArtifactEnergy = energy.artifactContribution.reduce(0, +)
        let totalSourceEnergy = energy.sourceContribution.reduce(0, +)
        let topArtifactEnergyFraction = totalArtifactEnergy > 1e-12
            ? (energy.artifactContribution.max() ?? 0) / totalArtifactEnergy
            : 0
        let labelRecall = totalArtifactEnergy > 1e-12
            ? labelSelected.reduce(0) { $0 + energy.artifactContribution[$1] } / totalArtifactEnergy
            : 0
        let routingRows = (0..<decomposition.componentCount).map { component in
            let suggestion = suggestions[component] ?? ICAComponentSuggestion(
                label: "Other", confidence: 0, reason: "No classifier result"
            )
            let probabilities = suggestion.probabilities
            return RoutingRow(
                artifact: artifact.rawValue,
                severity: severity,
                seed: seed,
                channelCount: channelCount,
                mixingFraction: mixingFraction,
                component: component + 1,
                predictedLabel: Self.baseLabel(suggestion.label),
                confidence: suggestion.confidence,
                brainProbability: probabilities["Brain", default: 0],
                muscleProbability: probabilities["Muscle", default: 0],
                eyeProbability: probabilities["Eye", default: 0],
                heartProbability: probabilities["Heart", default: 0],
                lineNoiseProbability: probabilities["Line Noise", default: 0],
                channelNoiseProbability: probabilities["Channel Noise", default: 0],
                otherProbability: probabilities["Other", default: 0],
                artifactEnergyFraction: totalArtifactEnergy > 1e-12
                    ? energy.artifactContribution[component] / totalArtifactEnergy : 0,
                sourceEnergyFraction: totalSourceEnergy > 1e-12
                    ? energy.sourceContribution[component] / totalSourceEnergy : 0,
                artifactPurity: energy.purity[component, default: 0]
            )
        }

        var wavelet = WaveletReductionMode.continuousEEG
            .defaultConfiguration(samplingRate: rate)
        wavelet.thresholdScale = 1
        wavelet.useGPU = false
        let wica = WICAConfiguration(
            wavelet: wavelet,
            coreCount: min(8, WaveletReducer.defaultCoreCount),
            componentBatchSize: 8
        )

        var outputs: [(String, MFFSignalData, Set<Int>)] = [
            ("uncorrected", signal, [])
        ]
        if !comparisonOnly {
            outputs.append(("channel-wavelet", WaveletReducer.reduce(
                signal: signal,
                channelIndices: Array(0..<signal.numberOfChannels),
                configuration: wavelet
            ).cleaned, []))
        }
        if !comparisonOnly, !labelSelected.isEmpty {
            outputs.append((
                "ica-reject-iclabel",
                ICAArtifactDetector.cleanedSignal(
                    from: signal, decomposition: decomposition, excluding: labelSelected
                ),
                labelSelected
            ))
        }
        outputs.append((
            "ica-reject-oracle",
            ICAArtifactDetector.cleanedSignal(
                from: signal, decomposition: decomposition, excluding: oracleSelected
            ),
            oracleSelected
        ))
        let thresholdScales = comparisonOnly ? [0.25] : [0.25, 0.50, 1.00]
        if !comparisonOnly {
            outputs.append((
                "wica-all",
                try WICAProcessor.reduce(
                    signal: signal,
                    decomposition: decomposition,
                    componentIndices: Set(0..<decomposition.componentCount),
                    configuration: wica
                ).cleaned,
                Set(0..<decomposition.componentCount)
            ))
        }
        for thresholdScale in thresholdScales {
            var configuration = wica
            configuration.wavelet.thresholdScale = thresholdScale
            let suffix = String(format: "t%03d", Int((100 * thresholdScale).rounded()))
            if !comparisonOnly, !labelSelected.isEmpty {
                outputs.append((
                    "wica-iclabel-\(suffix)",
                    try WICAProcessor.reduce(
                        signal: signal,
                        decomposition: decomposition,
                        componentIndices: labelSelected,
                        configuration: configuration
                    ).cleaned,
                    labelSelected
                ))
            }
            outputs.append((
                "wica-oracle-\(suffix)",
                try WICAProcessor.reduce(
                    signal: signal,
                    decomposition: decomposition,
                    componentIndices: oracleSelected,
                    configuration: configuration
                ).cleaned,
                oracleSelected
            ))
        }
        if includeSoftThresholds, !comparisonOnly {
            for thresholdScale in [0.25, 0.50, 1.00] {
                var configuration = wica
                configuration.wavelet.thresholdRule = .soft
                configuration.wavelet.thresholdScale = thresholdScale
                let suffix = String(format: "t%03d", Int((100 * thresholdScale).rounded()))
                outputs.append((
                    "wica-oracle-soft-\(suffix)",
                    try WICAProcessor.reduce(
                        signal: signal,
                        decomposition: decomposition,
                        componentIndices: oracleSelected,
                        configuration: configuration
                    ).cleaned,
                    oracleSelected
                ))
            }
        }

        if !comparisonOnly {
            var hybrid = signal
            if !mixed.isEmpty {
                var hybridConfiguration = wica
                hybridConfiguration.wavelet.thresholdScale = 0.50
                hybrid = try WICAProcessor.reduce(
                    signal: hybrid,
                    decomposition: decomposition,
                    componentIndices: mixed,
                    configuration: hybridConfiguration
                ).cleaned
            }
            if !pure.isEmpty {
                hybrid = ICAArtifactDetector.cleanedSignal(
                    from: hybrid,
                    activationSignal: signal,
                    decomposition: decomposition,
                    excluding: pure
                )
            }
            outputs.append(("hybrid-oracle", hybrid, pure.union(mixed)))
        }
        if includeSoftThresholds, !comparisonOnly {
            var softHybrid = signal
            if !mixed.isEmpty {
                var configuration = wica
                configuration.wavelet.thresholdRule = .soft
                configuration.wavelet.thresholdScale = 0.50
                softHybrid = try WICAProcessor.reduce(
                    signal: softHybrid,
                    decomposition: decomposition,
                    componentIndices: mixed,
                    configuration: configuration
                ).cleaned
            }
            if !pure.isEmpty {
                softHybrid = ICAArtifactDetector.cleanedSignal(
                    from: softHybrid,
                    activationSignal: signal,
                    decomposition: decomposition,
                    excluding: pure
                )
            }
            outputs.append(("hybrid-oracle-soft", softHybrid, pure.union(mixed)))
        }

        let noisyMSE = Self.mse(signal.data, clean)
        let cellRows = outputs.map { name, output, selected -> Row in
            let correctedMSE = Self.mse(output.data, clean)
            return Row(
                artifact: artifact.rawValue,
                severity: severity,
                seed: seed,
                channelCount: channelCount,
                durationSeconds: durationSeconds,
                mixingFraction: mixingFraction,
                icaMethod: icaMethod.rawValue,
                method: name,
                artifactReduction: noisyMSE > 1e-12 ? 1 - correctedMSE / noisyMSE : 0,
                rmse: correctedMSE.squareRoot(),
                transientPreservation: Self.transientPreservation(
                    output.data, clean: clean, truth: transientTruth, rate: rate
                ),
                components: Self.componentList(selected),
                labelArtifactEnergyRecall: labelRecall,
                icaSeconds: fitSeconds,
                icaIterations: decomposition.iterations,
                icaFinalChange: decomposition.finalChange,
                decompositionComponentCount: decomposition.componentCount,
                oracleComponentCount: oracleSelected.count,
                topArtifactEnergyFraction: topArtifactEnergyFraction
            )
        }
        let summary = cellRows.map {
            String(format: "%@ reduction=%+.3f RMSE=%.3f preserve=%.3f ICs=%@",
                   $0.method, $0.artifactReduction, $0.rmse,
                   $0.transientPreservation, $0.components)
        }.joined(separator: " | ")
        print(String(
            format: "%@ %.2fs/%d iterations, final change %.3g; top-IC artifact energy %.3f; ICLabel recall %.3f",
            icaMethod.displayName, fitSeconds, decomposition.iterations,
            decomposition.finalChange, topArtifactEnergyFraction, labelRecall
        ))
        print(summary)
        return CellResult(rows: cellRows, routing: routingRows)
    }

    private static func componentArtifactEnergy(
        _ artifact: [[Float]], decomposition: ICADecomposition
    ) -> (artifactContribution: [Double], sourceContribution: [Double], purity: [Int: Double]) {
        let decimation = max(1, decomposition.decimation)
        var downsampled = artifact.map {
            decimation > 1 ? Downsampler.windowedSincDecimated($0, by: decimation) : $0
        }
        let count = min(
            downsampled.first?.count ?? 0,
            decomposition.componentSources.first?.count ?? 0
        )
        if decomposition.averageReference, count > 0 {
            for sample in 0..<count {
                let mean = downsampled.reduce(0.0) { $0 + Double($1[sample]) }
                    / Double(max(1, downsampled.count))
                for channel in downsampled.indices {
                    downsampled[channel][sample] -= Float(mean)
                }
            }
        }
        var contributions = [Double](repeating: 0, count: decomposition.componentCount)
        var sourceContributions = [Double](repeating: 0, count: decomposition.componentCount)
        var purity: [Int: Double] = [:]
        for component in 0..<decomposition.componentCount {
            var projected = [Double](repeating: 0, count: count)
            for channel in downsampled.indices
                where channel < decomposition.unmixingMatrix[component].count {
                let weight = decomposition.unmixingMatrix[component][channel]
                for sample in 0..<count {
                    projected[sample] += weight * Double(downsampled[channel][sample])
                }
            }
            let artifactVariance = Self.variance(projected[...])
            let source = decomposition.componentSources[component].prefix(count)
            let sourceVariance = Self.variance(source[...])
            let mapNorm = decomposition.mixingMatrix.reduce(0.0) { total, row in
                guard component < row.count else { return total }
                return total + row[component] * row[component]
            }
            contributions[component] = artifactVariance * mapNorm
            sourceContributions[component] = sourceVariance * mapNorm
            purity[component] = min(1, artifactVariance / max(sourceVariance, 1e-12))
        }
        return (contributions, sourceContributions, purity)
    }

    private static func componentsAccountingFor(
        _ fraction: Double, of energy: [Double]
    ) -> Set<Int> {
        let ordered = energy.indices.sorted { energy[$0] > energy[$1] }
        let total = energy.reduce(0, +)
        guard total > 1e-12, let first = ordered.first else { return [0] }
        var selected: Set<Int> = []
        var cumulative = 0.0
        for component in ordered {
            selected.insert(component)
            cumulative += energy[component]
            if cumulative / total >= fraction { break }
        }
        return selected.isEmpty ? [first] : selected
    }

    private static func layout(for montage: Montage) -> SensorLayout {
        let radius = montage.positions.map { hypot($0.x, $0.y) }.max() ?? 1
        let scale = max(radius, 1e-12)
        return SensorLayout(
            name: montage.name,
            positions: montage.positions.enumerated().map { index, position in
                SensorPosition(
                    channelIndex: index, x: position.x / scale, y: position.y / scale
                )
            }
        )
    }

    private static func variance(_ values: ArraySlice<Double>) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(values.count)
    }

    private static func mse(_ corrected: [[Float]], _ clean: [[Double]]) -> Double {
        var sum = 0.0
        var count = 0
        for channel in corrected.indices where channel < clean.count {
            for sample in corrected[channel].indices where sample < clean[channel].count {
                let error = Double(corrected[channel][sample]) - clean[channel][sample]
                sum += error * error
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    private static func transientPreservation(
        _ corrected: [[Float]],
        clean: [[Double]],
        truth: BrainTransientInjection,
        rate: Double
    ) -> Double {
        var scores: [Double] = []
        for episode in truth.episodes {
            let channel = episode.strongestChannel
            let start = max(0, Int((episode.onsetSeconds * rate).rounded()))
            let end = min(
                clean[channel].count,
                start + Int((episode.durationSeconds * rate).rounded())
            )
            guard end > start else { continue }
            let reference = clean[channel][start..<end]
            let residual = zip(reference, corrected[channel][start..<end])
                .map { $0 - Double($1) }[...]
            let referenceVariance = variance(reference)
            if referenceVariance > 1e-12 {
                scores.append(1 - variance(residual) / referenceVariance)
            }
        }
        return scores.isEmpty ? 1 : scores.reduce(0, +) / Double(scores.count)
    }

    private static func componentList(_ values: Set<Int>) -> String {
        values.sorted().map { String($0 + 1) }.joined(separator: "+")
    }

    private static func baseLabel(_ label: String) -> String {
        ["Brain", "Muscle", "Eye", "Heart", "Line Noise", "Channel Noise", "Other"]
            .first(where: { label.hasPrefix($0) }) ?? label
    }

    /// Rotates a controlled fraction of the artifact layer onto the first
    /// neural source's scalp map. At high fractions the neural source and the
    /// artifact share a sensor-space direction, so ICA cannot separate them by
    /// a different topography. The layer is rescaled to preserve its original
    /// pooled RMS, holding artifact severity constant across the mixing sweep.
    private static func spatiallyMixedArtifactLayer(
        _ artifact: [[Float]], neuralMap: [Double], fraction: Double
    ) -> [[Float]] {
        guard let sampleCount = artifact.first?.count,
              sampleCount > 0,
              artifact.count == neuralMap.count else { return artifact }
        let clamped = min(max(fraction, 0), 1)
        let anchor = artifact.indices.max { left, right in
            variance(artifact[left].map(Double.init)[...])
                < variance(artifact[right].map(Double.init)[...])
        } ?? 0
        let mapNorm = neuralMap.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard mapNorm > 1e-12 else { return artifact }
        let normalizedMap = neuralMap.map { $0 / mapNorm }
        let carrier = artifact[anchor].map(Double.init)
        var aligned = artifact.indices.map { channel in
            carrier.map { Float($0 * normalizedMap[channel]) }
        }
        func rms(_ matrix: [[Float]]) -> Double {
            let count = matrix.reduce(0) { $0 + $1.count }
            guard count > 0 else { return 0 }
            let squares = matrix.reduce(0.0) { total, row in
                total + row.reduce(0.0) { $0 + Double($1) * Double($1) }
            }
            return (squares / Double(count)).squareRoot()
        }
        let originalRMS = rms(artifact)
        let alignedRMS = rms(aligned)
        guard originalRMS > 1e-12, alignedRMS > 1e-12 else { return artifact }
        let alignedScale = originalRMS / alignedRMS
        for channel in aligned.indices {
            for sample in aligned[channel].indices {
                aligned[channel][sample] *= Float(alignedScale)
            }
        }
        let originalWeight = (1 - clamped).squareRoot()
        let alignedWeight = clamped.squareRoot()
        var result = artifact
        for channel in result.indices {
            for sample in 0..<sampleCount {
                result[channel][sample] = Float(originalWeight) * artifact[channel][sample]
                    + Float(alignedWeight) * aligned[channel][sample]
            }
        }
        let resultRMS = rms(result)
        let finalScale = resultRMS > 1e-12 ? originalRMS / resultRMS : 1
        for channel in result.indices {
            for sample in result[channel].indices {
                result[channel][sample] *= Float(finalScale)
            }
        }
        return result
    }

    private static func simulatorCommand(
        artifact: Artifact,
        severity: String,
        scale: Double,
        seed: UInt64,
        channelCount: Int,
        durationSeconds: Double,
        sourceCount: Int
    ) -> String {
        let common = "Tools/EVASimulate/.build/eva-simulate generate --output $OUT "
            + "--prefix \(artifact.rawValue)-\(severity)-\(seed) --seed \(seed) "
            + "--channels \(channelCount) --rate 200 --duration \(Int(durationSeconds)) "
            + "--eeg-model dipole --sources \(sourceCount) "
            + "--source-burstiness 0.8 --brain-transients 30 "
            + "--brain-transient-amplitude 150 --no-gradient --no-bcg"
        switch artifact {
        case .blink:
            return common + " --blinks 20 --blink-amplitude \(Int(100 * scale))"
        case .emg:
            return common + " --emg 15 --emg-amplitude \(Int(50 * scale))"
                + " --emg-duration 0.75 --emg-low 20 --emg-high 90"
        case .pop:
            return common + " --bad-channels 7:pop # campaign artifact-scale=\(scale)"
        }
    }

    private static func csv(_ rows: [Row]) -> String {
        let header = "artifact,severity,seed,channels,duration_seconds,mixing_fraction,ica_method,method,artifact_reduction,rmse_uv,transient_preservation,components,label_artifact_energy_recall,ica_seconds,ica_iterations,ica_final_change,decomposition_components,oracle_components,top_artifact_energy_fraction"
        let body = rows.map {
            String(format: "%@,%@,%llu,%d,%.3f,%.3f,%@,%@,%.8f,%.8f,%.8f,%@,%.8f,%.5f,%d,%.12g,%d,%d,%.8f",
                   $0.artifact, $0.severity, $0.seed, $0.channelCount,
                   $0.durationSeconds, $0.mixingFraction, $0.icaMethod, $0.method,
                   $0.artifactReduction, $0.rmse, $0.transientPreservation,
                   $0.components, $0.labelArtifactEnergyRecall,
                   $0.icaSeconds, $0.icaIterations, $0.icaFinalChange,
                   $0.decompositionComponentCount, $0.oracleComponentCount,
                   $0.topArtifactEnergyFraction)
        }
        return ([header] + body).joined(separator: "\n") + "\n"
    }

    private static func routingCSV(_ rows: [RoutingRow]) -> String {
        let header = "artifact,severity,seed,channels,mixing_fraction,component,predicted_label,confidence,p_brain,p_muscle,p_eye,p_heart,p_line_noise,p_channel_noise,p_other,artifact_energy_fraction,source_energy_fraction,artifact_purity"
        let body = rows.map {
            String(
                format: "%@,%@,%llu,%d,%.3f,%d,%@,%.8f,%.8f,%.8f,%.8f,%.8f,%.8f,%.8f,%.8f,%.8f,%.8f,%.8f",
                $0.artifact, $0.severity, $0.seed, $0.channelCount,
                $0.mixingFraction, $0.component, $0.predictedLabel, $0.confidence,
                $0.brainProbability, $0.muscleProbability, $0.eyeProbability,
                $0.heartProbability, $0.lineNoiseProbability,
                $0.channelNoiseProbability, $0.otherProbability,
                $0.artifactEnergyFraction, $0.sourceEnergyFraction, $0.artifactPurity
            )
        }
        return ([header] + body).joined(separator: "\n") + "\n"
    }

    private static func report(_ rows: [Row], seedCount: Int) -> String {
        var lines = [
            "# W-ICA simulator campaign",
            "",
            "\(seedCount) seeds per artifact × severity cell. Higher artifact reduction and transient preservation are better; lower RMSE is better.",
            "",
            "| Channels | Artifact | Severity | Method | Reduction | RMSE µV | Transient preservation |",
            "| ---: | --- | --- | --- | ---: | ---: | ---: |"
        ]
        let groups = Dictionary(grouping: rows) {
            "\($0.channelCount)|\($0.artifact)|\($0.severity)|\($0.method)"
        }
        for key in groups.keys.sorted() {
            guard let group = groups[key], let first = group.first else { continue }
            func mean(_ value: (Row) -> Double) -> Double {
                group.reduce(0) { $0 + value($1) } / Double(group.count)
            }
            lines.append(String(
                format: "| %d | %@ | %@ | %@ | %+.3f | %.3f | %.3f |",
                first.channelCount, first.artifact, first.severity, first.method,
                mean { $0.artifactReduction },
                mean { $0.rmse },
                mean { $0.transientPreservation }
            ))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func algorithmReport(
        _ rows: [Row], failures: [String], seedCount: Int
    ) -> String {
        var lines = [
            "# ICA algorithm comparison for W-ICA",
            "",
            "Paired medium-severity fixtures: \(seedCount) seeds × blink/EMG/pop × 64/128/256 channels. Values are mean ± sample SD across successful fits.",
            "",
            "| Channels | Artifact | ICA | Fits | Seconds | Iterations | At cap | Final change | ICs | Top-IC artifact energy | Oracle ICs | ICLabel recall | Oracle reject reduction | W-ICA .25 reduction |",
            "| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
        ]
        let representative = rows.filter { $0.method == "ica-reject-oracle" }
        let groups = Dictionary(grouping: representative) {
            "\($0.channelCount)|\($0.artifact)|\($0.icaMethod)"
        }
        for key in groups.keys.sorted() {
            guard let group = groups[key], let first = group.first else { continue }
            let rowLookup = Dictionary(grouping: rows.filter {
                $0.channelCount == first.channelCount
                    && $0.artifact == first.artifact
                    && $0.icaMethod == first.icaMethod
            }) { "\($0.seed)|\($0.method)" }
            func pairedMean(_ method: String, _ value: (Row) -> Double) -> Double {
                let values = group.compactMap { baseline in
                    rowLookup["\(baseline.seed)|\(method)"]?.first.map(value)
                }
                return values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
            }
            func summary(_ value: (Row) -> Double) -> String {
                let values = group.map(value)
                let mean = values.reduce(0, +) / Double(values.count)
                let variance = values.count > 1
                    ? values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                        / Double(values.count - 1)
                    : 0
                return String(format: "%.3g ± %.3g", mean, variance.squareRoot())
            }
            let atCap = group.filter { $0.icaIterations >= 250 }.count
            lines.append(String(
                format: "| %d | %@ | %@ | %d | %@ | %@ | %d (%.0f%%) | %@ | %@ | %@ | %@ | %@ | %+.3f | %+.3f |",
                first.channelCount,
                first.artifact,
                first.icaMethod,
                group.count,
                summary { $0.icaSeconds },
                summary { Double($0.icaIterations) },
                atCap,
                100 * Double(atCap) / Double(group.count),
                summary { $0.icaFinalChange },
                summary { Double($0.decompositionComponentCount) },
                summary { $0.topArtifactEnergyFraction },
                summary { Double($0.oracleComponentCount) },
                summary { $0.labelArtifactEnergyRecall },
                pairedMean("ica-reject-oracle") { $0.artifactReduction },
                pairedMean("wica-oracle-t025") { $0.artifactReduction }
            ))
        }
        lines += ["", "## Failures", ""]
        if failures.isEmpty {
            lines.append("None.")
        } else {
            lines += failures.map { "- `\($0)`" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func mixedReport(_ rows: [Row], seedCount: Int) -> String {
        let included = Set([
            "uncorrected", "ica-reject-iclabel", "ica-reject-oracle",
            "wica-oracle-t050", "wica-oracle-soft-t050",
            "hybrid-oracle", "hybrid-oracle-soft"
        ])
        var lines = [
            "# High-density mixed-component W-ICA campaign",
            "",
            "\(seedCount) seeds per channel × artifact × mixing cell. Mixing is the fraction of artifact spatial power aligned to a known neural-source topography.",
            "",
            "| Channels | Artifact | Mixing | Method | Reduction | RMSE µV | Transient preservation | ICLabel recall |",
            "| ---: | --- | ---: | --- | ---: | ---: | ---: | ---: |"
        ]
        let filtered = rows.filter { included.contains($0.method) }
        let groups = Dictionary(grouping: filtered) {
            "\($0.channelCount)|\($0.artifact)|\($0.mixingFraction)|\($0.method)"
        }
        for key in groups.keys.sorted() {
            guard let group = groups[key], let first = group.first else { continue }
            func mean(_ value: (Row) -> Double) -> Double {
                group.reduce(0) { $0 + value($1) } / Double(group.count)
            }
            lines.append(String(
                format: "| %d | %@ | %.2f | %@ | %+.3f | %.3f | %.3f | %.3f |",
                first.channelCount, first.artifact, first.mixingFraction, first.method,
                mean { $0.artifactReduction }, mean { $0.rmse },
                mean { $0.transientPreservation }, mean { $0.labelArtifactEnergyRecall }
            ))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func routingReport(_ rows: [RoutingRow], seedCount: Int) -> String {
        var lines = [
            "# ICLabel routing calibration",
            "",
            "Truth-weighted routing over \(seedCount) seeds per cell. Recall is selected artifact energy; selected source energy estimates how broadly the policy acts; selected purity is source-energy-weighted artifact purity.",
            "",
            "| Channels | Artifact | Mixing | Target probability | Gate | Artifact recall | Selected source energy | Selected purity |",
            "| ---: | --- | ---: | --- | ---: | ---: | ---: | ---: |"
        ]
        let groups = Dictionary(grouping: rows) {
            "\($0.channelCount)|\($0.artifact)|\($0.mixingFraction)"
        }
        for key in groups.keys.sorted() {
            guard let group = groups[key], let first = group.first else { continue }
            let target: String
            let probability: (RoutingRow) -> Double
            switch first.artifact {
            case "blink": target = "Eye"; probability = { $0.eyeProbability }
            case "emg": target = "Muscle"; probability = { $0.muscleProbability }
            default: target = "Channel Noise"; probability = { $0.channelNoiseProbability }
            }
            let fitCount = max(1, Set(group.map { "\($0.seed)|\($0.severity)" }).count)
            for threshold in [0.10, 0.25, 0.50, 0.75, 0.90] {
                let selected = group.filter { probability($0) >= threshold }
                let recall = selected.reduce(0) { $0 + $1.artifactEnergyFraction }
                    / Double(fitCount)
                let selectedSource = selected.reduce(0) { $0 + $1.sourceEnergyFraction }
                    / Double(fitCount)
                let purityWeight = selected.reduce(0) { $0 + $1.sourceEnergyFraction }
                let purity = purityWeight > 1e-12
                    ? selected.reduce(0) {
                        $0 + $1.artifactPurity * $1.sourceEnergyFraction
                    } / purityWeight
                    : 0
                lines.append(String(
                    format: "| %d | %@ | %.2f | %@ | %.2f | %.3f | %.3f | %.3f |",
                    first.channelCount, first.artifact, first.mixingFraction,
                    target, threshold, recall, selectedSource, purity
                ))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func writeBaselineSnapshot(
        rows: [Row], routing: [RoutingRow], settings: CampaignSettings
    ) throws {
        let temporary = FileManager.default.temporaryDirectory
        try csv(rows).write(
            to: temporary.appendingPathComponent("eva-wica-density-baseline.csv"),
            atomically: true, encoding: .utf8
        )
        try report(rows, seedCount: settings.seedCount).write(
            to: temporary.appendingPathComponent("eva-wica-density-baseline.md"),
            atomically: true, encoding: .utf8
        )
        try routingCSV(routing).write(
            to: temporary.appendingPathComponent("eva-wica-density-routing.csv"),
            atomically: true, encoding: .utf8
        )
        try routingReport(routing, seedCount: settings.seedCount).write(
            to: temporary.appendingPathComponent("eva-wica-density-routing.md"),
            atomically: true, encoding: .utf8
        )
    }

    private static func writeAlgorithmSnapshot(
        rows: [Row], failures: [String], settings: CampaignSettings
    ) throws {
        let temporary = FileManager.default.temporaryDirectory
        try csv(rows).write(
            to: temporary.appendingPathComponent("eva-wica-density-ica-algorithms.csv"),
            atomically: true, encoding: .utf8
        )
        try algorithmReport(
            rows, failures: failures, seedCount: settings.seedCount
        ).write(
            to: temporary.appendingPathComponent("eva-wica-density-ica-algorithms.md"),
            atomically: true, encoding: .utf8
        )
    }

    private static func writeMixedSnapshot(
        rows: [Row], routing: [RoutingRow], settings: CampaignSettings
    ) throws {
        let temporary = FileManager.default.temporaryDirectory
        try csv(rows).write(
            to: temporary.appendingPathComponent("eva-wica-density-mixed.csv"),
            atomically: true, encoding: .utf8
        )
        try mixedReport(rows, seedCount: settings.seedCount).write(
            to: temporary.appendingPathComponent("eva-wica-density-mixed.md"),
            atomically: true, encoding: .utf8
        )
        try routingCSV(routing).write(
            to: temporary.appendingPathComponent("eva-wica-density-mixed-routing.csv"),
            atomically: true, encoding: .utf8
        )
        try routingReport(routing, seedCount: settings.seedCount).write(
            to: temporary.appendingPathComponent("eva-wica-density-mixed-routing.md"),
            atomically: true, encoding: .utf8
        )
    }
}
