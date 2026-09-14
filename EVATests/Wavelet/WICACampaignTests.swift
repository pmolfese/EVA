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

    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["EVA_WICA_CAMPAIGN"] == "1"
    }

    private static var algorithmComparisonIsEnabled: Bool {
        ProcessInfo.processInfo.environment["EVA_WICA_ICA_CAMPAIGN"] == "1"
    }

    @Test func simulatorCampaign() async throws {
        guard Self.isEnabled else {
            print("WICACampaignTests: set EVA_WICA_CAMPAIGN=1 to run. Skipping.")
            return
        }

        let environment = ProcessInfo.processInfo.environment
        let seedCount = max(1, Int(environment["EVA_WICA_CAMPAIGN_SEEDS"] ?? "10") ?? 10)
        let severities = [("low", 0.5), ("medium", 1.0), ("high", 2.0)]
        let baseSeed: UInt64 = 20_260_821
        var rows: [Row] = []

        print("=== W-ICA simulator campaign: \(seedCount) seeds × 3 artifacts × 3 severities ===")
        for artifact in Artifact.allCases {
            for (severity, scale) in severities {
                for seedOffset in 0..<seedCount {
                    let seed = baseSeed + UInt64(seedOffset)
                    let command = Self.simulatorCommand(
                        artifact: artifact, severity: severity, scale: scale, seed: seed
                    )
                    print("\n+ \(command)")
                    rows += try Self.runCell(
                        artifact: artifact, severity: severity, scale: scale, seed: seed
                    )
                }
            }
        }

        let csv = Self.csv(rows)
        let report = Self.report(rows, seedCount: seedCount)
        let temporary = FileManager.default.temporaryDirectory
        try csv.write(
            to: temporary.appendingPathComponent("eva-wica-campaign.csv"),
            atomically: true, encoding: .utf8
        )
        try report.write(
            to: temporary.appendingPathComponent("eva-wica-campaign.md"),
            atomically: true, encoding: .utf8
        )
        print("\n\(report)")
    }

    @Test func compareICAAlgorithms() async throws {
        guard Self.algorithmComparisonIsEnabled else {
            print("WICACampaignTests: set EVA_WICA_ICA_CAMPAIGN=1 to compare ICA algorithms. Skipping.")
            return
        }

        let environment = ProcessInfo.processInfo.environment
        let seedCount = max(
            1, Int(environment["EVA_WICA_ICA_CAMPAIGN_SEEDS"] ?? "10") ?? 10
        )
        let algorithms: [ICAMethod] = [.picard, .picardO, .fastICA]
        let baseSeed: UInt64 = 20_260_821
        var rows: [Row] = []
        var failures: [String] = []

        print("=== Paired ICA comparison: \(seedCount) seeds × 3 artifacts × 3 algorithms ===")
        for artifact in Artifact.allCases {
            for seedOffset in 0..<seedCount {
                let seed = baseSeed + UInt64(seedOffset)
                let command = Self.simulatorCommand(
                    artifact: artifact, severity: "medium", scale: 1, seed: seed
                )
                print("\n+ \(command)")
                for algorithm in algorithms {
                    print("+ EVA ICA --method \(algorithm.rawValue) --components 20 --fit-rate 100 --max-iterations 250")
                    do {
                        rows += try Self.runCell(
                            artifact: artifact,
                            severity: "medium",
                            scale: 1,
                            seed: seed,
                            icaMethod: algorithm
                        )
                    } catch {
                        let failure = "\(artifact.rawValue),\(seed),\(algorithm.rawValue): \(error)"
                        failures.append(failure)
                        print("!! \(failure)")
                    }
                }
            }
        }

        let temporary = FileManager.default.temporaryDirectory
        try Self.csv(rows).write(
            to: temporary.appendingPathComponent("eva-wica-ica-algorithms.csv"),
            atomically: true,
            encoding: .utf8
        )
        let report = Self.algorithmReport(
            rows, failures: failures, seedCount: seedCount
        )
        try report.write(
            to: temporary.appendingPathComponent("eva-wica-ica-algorithms.md"),
            atomically: true,
            encoding: .utf8
        )
        print("\n\(report)")
    }

    private static func runCell(
        artifact: Artifact,
        severity: String,
        scale: Double,
        seed: UInt64,
        icaMethod: ICAMethod = .fastICA
    ) throws -> [Row] {
        let rate = 200.0
        var config = SimulationConfig.default
        config.seed = seed
        config.eegGenerationModel = .dipole
        config.nonGaussianSources = .default
        config.recordingReference = .average
        config.gradientEnabled = false
        config.bcgEnabled = false
        config.channelCount = 20
        config.samplingRate = rate
        config.durationSeconds = 24
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
                    contaminated[channel][sample] += scale * (standard[channel][sample] - clean[channel][sample])
                }
            }
        }

        let artifactLayer = zip(contaminated, clean).map { noisy, reference in
            zip(noisy, reference).map { Float($0 - $1) }
        }
        let signal = SyntheticSignal.make(
            contaminated.map { $0.map(Float.init) }, samplingRate: rate
        )

        let fitStart = Date()
        let decomposition = try ICAArtifactDetector.fit(
            signal: signal,
            configuration: ICAConfiguration(
                method: icaMethod,
                componentCount: config.channelCount,
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
        let topArtifactEnergyFraction = totalArtifactEnergy > 1e-12
            ? (energy.artifactContribution.max() ?? 0) / totalArtifactEnergy
            : 0
        let labelRecall = totalArtifactEnergy > 1e-12
            ? labelSelected.reduce(0) { $0 + energy.artifactContribution[$1] } / totalArtifactEnergy
            : 0

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
            ("uncorrected", signal, []),
            ("channel-wavelet", WaveletReducer.reduce(
                signal: signal,
                channelIndices: Array(0..<signal.numberOfChannels),
                configuration: wavelet
            ).cleaned, [])
        ]
        if !labelSelected.isEmpty {
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
        for thresholdScale in [0.25, 0.50, 1.00] {
            var configuration = wica
            configuration.wavelet.thresholdScale = thresholdScale
            let suffix = String(format: "t%03d", Int((100 * thresholdScale).rounded()))
            if !labelSelected.isEmpty {
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

        let noisyMSE = Self.mse(signal.data, clean)
        let cellRows = outputs.map { name, output, selected -> Row in
            let correctedMSE = Self.mse(output.data, clean)
            return Row(
                artifact: artifact.rawValue,
                severity: severity,
                seed: seed,
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
        return cellRows
    }

    private static func componentArtifactEnergy(
        _ artifact: [[Float]], decomposition: ICADecomposition
    ) -> (artifactContribution: [Double], purity: [Int: Double]) {
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
            purity[component] = min(1, artifactVariance / max(sourceVariance, 1e-12))
        }
        return (contributions, purity)
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

    private static func simulatorCommand(
        artifact: Artifact, severity: String, scale: Double, seed: UInt64
    ) -> String {
        let common = "Tools/EVASimulate/.build/eva-simulate generate --output $OUT "
            + "--prefix \(artifact.rawValue)-\(severity)-\(seed) --seed \(seed) "
            + "--channels 20 --rate 200 --duration 24 --eeg-model dipole "
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
        let header = "artifact,severity,seed,ica_method,method,artifact_reduction,rmse_uv,transient_preservation,components,label_artifact_energy_recall,ica_seconds,ica_iterations,ica_final_change,decomposition_components,oracle_components,top_artifact_energy_fraction"
        let body = rows.map {
            String(format: "%@,%@,%llu,%@,%@,%.8f,%.8f,%.8f,%@,%.8f,%.5f,%d,%.12g,%d,%d,%.8f",
                   $0.artifact, $0.severity, $0.seed, $0.icaMethod, $0.method,
                   $0.artifactReduction, $0.rmse, $0.transientPreservation,
                   $0.components, $0.labelArtifactEnergyRecall,
                   $0.icaSeconds, $0.icaIterations, $0.icaFinalChange,
                   $0.decompositionComponentCount, $0.oracleComponentCount,
                   $0.topArtifactEnergyFraction)
        }
        return ([header] + body).joined(separator: "\n") + "\n"
    }

    private static func report(_ rows: [Row], seedCount: Int) -> String {
        var lines = [
            "# W-ICA simulator campaign",
            "",
            "\(seedCount) seeds per artifact × severity cell. Higher artifact reduction and transient preservation are better; lower RMSE is better.",
            "",
            "| Artifact | Severity | Method | Reduction | RMSE µV | Transient preservation |",
            "| --- | --- | --- | ---: | ---: | ---: |"
        ]
        let groups = Dictionary(grouping: rows) { "\($0.artifact)|\($0.severity)|\($0.method)" }
        for key in groups.keys.sorted() {
            guard let group = groups[key], let first = group.first else { continue }
            func mean(_ value: (Row) -> Double) -> Double {
                group.reduce(0) { $0 + value($1) } / Double(group.count)
            }
            lines.append(String(
                format: "| %@ | %@ | %@ | %+.3f | %.3f | %.3f |",
                first.artifact, first.severity, first.method,
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
            "Paired medium-severity fixtures: \(seedCount) seeds × blink/EMG/pop. Values are mean ± sample SD across successful fits.",
            "",
            "| Artifact | ICA | Fits | Seconds | Iterations | At cap | Final change | ICs | Top-IC artifact energy | Oracle ICs | ICLabel recall | Oracle reject reduction | W-ICA .25 reduction |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
        ]
        let representative = rows.filter { $0.method == "ica-reject-oracle" }
        let groups = Dictionary(grouping: representative) { "\($0.artifact)|\($0.icaMethod)" }
        for key in groups.keys.sorted() {
            guard let group = groups[key], let first = group.first else { continue }
            let rowLookup = Dictionary(grouping: rows.filter {
                $0.artifact == first.artifact && $0.icaMethod == first.icaMethod
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
                format: "| %@ | %@ | %d | %@ | %@ | %d (%.0f%%) | %@ | %@ | %@ | %@ | %@ | %+.3f | %+.3f |",
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
}
