//
//  SI0ContractFixtures.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Compact characterization fixtures for ROADMAP SI-0. The larger self-test
//  proves scientific behavior over generated recordings; these fixtures pin the
//  matrix boundary that SI-1 and SI-2 will extract. Exact invariants use equality
//  or structural checks. Eigensolver-sensitive scientific metrics use explicit
//  quality floors recorded in `SI0_CONTRACTS.md`.
//

import Foundation

nonisolated enum SI0ContractFixtures {
    static func run() -> [SelfTest.Outcome] {
        var outcomes: [SelfTest.Outcome] = []

        let montage = Montage.standard(count: 16)
        let sources = [
            SimulatedSource(
                id: "fixture-left",
                positionMeters: Vector3D(x: -0.021, y: 0.013, z: 0.037),
                orientation: Vector3D(x: 0.31, y: -0.42, z: 0.85).normalized(),
                bandName: "fixture", seed: 1, rmsMomentNanoampereMeters: 1
            ),
            SimulatedSource(
                id: "fixture-right",
                positionMeters: Vector3D(x: 0.024, y: -0.009, z: 0.034),
                orientation: Vector3D(x: -0.27, y: 0.73, z: 0.41).normalized(),
                bandName: "fixture", seed: 2, rmsMomentNanoampereMeters: 1
            )
        ]

        do {
            let field = try SphericalForwardModel.leadField(
                head: .classicThreeShell, montage: montage, sources: sources,
                reference: .average, terms: 100
            )
            let repeated = try SphericalForwardModel.leadField(
                head: .classicThreeShell, montage: montage, sources: sources,
                reference: .average, terms: 100
            )
            let finite = field.matrixMicrovoltsPerNanoampereMeter
                .allSatisfy { $0.allSatisfy(\.isFinite) }
                && field.freeOrientationMatrixMicrovoltsPerNanoampereMeter
                    .allSatisfy { $0.allSatisfy(\.isFinite) }
            let shapeIsExact = field.matrixMicrovoltsPerNanoampereMeter.count == 16
                && field.matrixMicrovoltsPerNanoampereMeter.allSatisfy { $0.count == 2 }
                && field.freeOrientationMatrixMicrovoltsPerNanoampereMeter.count == 16
                && field.freeOrientationMatrixMicrovoltsPerNanoampereMeter
                    .allSatisfy { $0.count == 6 }
            let identityIsExact = field.channelNames == montage.channelNames
                && field.sourceIDs == sources.map(\.id)
                && field.reference == .average
                && field.matrixMicrovoltsPerNanoampereMeter
                    == repeated.matrixMicrovoltsPerNanoampereMeter
                && field.freeOrientationMatrixMicrovoltsPerNanoampereMeter
                    == repeated.freeOrientationMatrixMicrovoltsPerNanoampereMeter
            outcomes.append(SelfTest.Outcome(
                name: "SI-0 lead-field fixture pins dimensions, finiteness, identity and determinism",
                snr: shapeIsExact && finite && identityIsExact ? 0 : 1,
                passed: shapeIsExact && finite && identityIsExact,
                expectation: "16x2 oriented and 16x6 free matrices, finite, ordered, and exactly repeatable"
            ))

            var maximumReferenceMean = 0.0
            for column in 0..<6 {
                let mean = field.freeOrientationMatrixMicrovoltsPerNanoampereMeter
                    .reduce(0.0) { $0 + $1[column] } / 16
                maximumReferenceMean = max(maximumReferenceMean, abs(mean))
            }
            outcomes.append(SelfTest.Outcome(
                name: "SI-0 lead-field fixture pins average-reference semantics",
                snr: maximumReferenceMean,
                passed: maximumReferenceMean < 1e-14,
                expectation: "every free-orientation column has absolute channel mean below 1e-14"
            ))

            let reversedMontage = Montage(
                name: "SI-0 reversed fixture",
                electrodes: Array(montage.electrodes.reversed())
            )
            let infinityField = try SphericalForwardModel.leadField(
                head: .classicThreeShell, montage: montage, sources: sources,
                reference: .infinity, terms: 100
            )
            let reversed = try SphericalForwardModel.leadField(
                head: .classicThreeShell, montage: reversedMontage, sources: sources,
                reference: .infinity, terms: 100
            )
            var orderingError = 0.0
            for row in 0..<16 {
                let originalRow = 15 - row
                for column in 0..<6 {
                    orderingError = max(
                        orderingError,
                        abs(reversed.freeOrientationMatrixMicrovoltsPerNanoampereMeter[row][column]
                            - infinityField.freeOrientationMatrixMicrovoltsPerNanoampereMeter[originalRow][column])
                    )
                }
            }
            outcomes.append(SelfTest.Outcome(
                name: "SI-0 electrode order is a row-order contract",
                snr: orderingError,
                passed: reversed.channelNames == Array(montage.channelNames.reversed())
                    && orderingError == 0,
                expectation: "reversing ordered electrodes reverses matrix rows exactly"
            ))

            func rejects(_ operation: () throws -> Void) -> Bool {
                do {
                    try operation()
                    return false
                } catch {
                    return true
                }
            }
            var invalidForwardRejections = 0
            if rejects({
                _ = try SphericalForwardModel.leadField(
                    head: SphericalHeadModel(name: "empty", centerMeters: .zero, shells: []),
                    montage: montage, sources: sources, reference: .average, terms: 100
                )
            }) { invalidForwardRejections += 1 }
            if rejects({
                _ = try SphericalForwardModel.leadField(
                    head: .classicThreeShell, montage: montage, sources: sources,
                    reference: .average, terms: 0
                )
            }) { invalidForwardRejections += 1 }
            var outside = sources[0]
            outside.positionMeters = Vector3D(x: 0, y: 0, z: 0.08)
            if rejects({
                _ = try SphericalForwardModel.leadField(
                    head: .classicThreeShell, montage: montage, sources: [outside],
                    reference: .average, terms: 100
                )
            }) { invalidForwardRejections += 1 }
            var nonUnit = sources[0]
            nonUnit.orientation = Vector3D(x: 1, y: 1, z: 1)
            if rejects({
                _ = try SphericalForwardModel.leadField(
                    head: .classicThreeShell, montage: montage, sources: [nonUnit],
                    reference: .average, terms: 100
                )
            }) { invalidForwardRejections += 1 }
            outcomes.append(SelfTest.Outcome(
                name: "SI-0 forward fixture rejects invalid head, terms, position and orientation",
                snr: Double(invalidForwardRejections),
                passed: invalidForwardRejections == 4,
                expectation: "all four invalid inputs fail explicitly"
            ))

            let brain = try SurrogateSeparation.brainModel(
                head: .classicThreeShell, montage: montage, count: 5,
                reference: .average, terms: 100
            )
            var artifact = montage.positions.map { $0.x + 0.35 * $0.y - 0.1 * $0.z }
            let artifactMean = artifact.reduce(0, +) / Double(artifact.count)
            for index in artifact.indices { artifact[index] -= artifactMean }
            let artifactNorm = artifact.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
            for index in artifact.indices { artifact[index] /= artifactNorm }

            let filter = try SurrogateSeparation.spatialFilter(
                brain: brain, artifactTopographies: [artifact], brainRegularization: 0.02
            )
            let filterRepeat = try SurrogateSeparation.spatialFilter(
                brain: brain, artifactTopographies: [artifact], brainRegularization: 0.02
            )
            var maximumOperatorColumnMean = 0.0
            for column in 0..<16 {
                let mean = filter.reduce(0.0) { $0 + $1[column] } / 16
                maximumOperatorColumnMean = max(maximumOperatorColumnMean, abs(mean))
            }
            let operatorContract = brain.matrix.count == 16
                && brain.matrix.allSatisfy { $0.count == 15 && $0.allSatisfy(\.isFinite) }
                && filter.count == 16
                && filter.allSatisfy { $0.count == 16 && $0.allSatisfy(\.isFinite) }
                && filter == filterRepeat
                && maximumOperatorColumnMean < 1e-12
            outcomes.append(SelfTest.Outcome(
                name: "SI-0 PCA-S fixture pins basis/operator dimensions, finiteness and determinism",
                snr: maximumOperatorColumnMean,
                passed: operatorContract,
                expectation: "16x15 basis and 16x16 finite, repeatable, average-referenced operator"
            ))

            let artifactOutput = try SurrogateSeparation.apply(
                filter: filter, to: artifact.map { [$0] }
            )
            let artifactOutputNorm = artifactOutput
                .reduce(0.0) { $0 + $1[0] * $1[0] }.squareRoot()
            let artifactGain = artifactOutputNorm // Input was normalized to unit norm above.
            outcomes.append(SelfTest.Outcome(
                name: "SI-0 PCA-S fixture attenuates a known artifact topography",
                snr: artifactGain,
                passed: artifactGain < 1e-8,
                expectation: "output/input norm below 1e-8 for the unpenalized artifact column"
            ))

            let noArtifactFilter = try SurrogateSeparation.spatialFilter(
                brain: brain, artifactTopographies: [], brainRegularization: 0.02
            )
            let cleanProbe = field.matrixMicrovoltsPerNanoampereMeter
            let cleanOutput = try SurrogateSeparation.apply(
                filter: noArtifactFilter, to: cleanProbe
            )
            var signalSquares = 0.0
            var residualSquares = 0.0
            var worstCorrelation = 1.0
            for source in sources.indices {
                let input = cleanProbe.map { $0[source] }
                let output = cleanOutput.map { $0[source] }
                worstCorrelation = min(worstCorrelation, DipoleEEGGenerator.pearson(input, output))
                for channel in input.indices {
                    signalSquares += input[channel] * input[channel]
                    let residual = input[channel] - output[channel]
                    residualSquares += residual * residual
                }
            }
            let cleanResidualSNR = (signalSquares / max(residualSquares, 1e-300)).squareRoot()
            outcomes.append(SelfTest.Outcome(
                name: "SI-0 PCA-S fixture is near-identity on artifact-free brain topographies",
                snr: cleanResidualSNR,
                passed: cleanResidualSNR > 5 && worstCorrelation > 0.97,
                expectation: "residual SNR above 5 and worst topographic correlation above 0.97"
            ))

            let brainOutput = try SurrogateSeparation.apply(filter: filter, to: cleanProbe)
            var worstArtifactAwareCorrelation = 1.0
            for source in sources.indices {
                worstArtifactAwareCorrelation = min(
                    worstArtifactAwareCorrelation,
                    DipoleEEGGenerator.pearson(
                        cleanProbe.map { $0[source] }, brainOutput.map { $0[source] }
                    )
                )
            }
            outcomes.append(SelfTest.Outcome(
                name: "SI-0 PCA-S fixture preserves brain topographies while removing artifact",
                snr: worstArtifactAwareCorrelation,
                passed: worstArtifactAwareCorrelation > 0.93,
                expectation: "worst dipole-topography correlation remains above 0.93 (0.947 baseline)"
            ))

            var invalidSurrogateRejections = 0
            if rejects({
                _ = try SurrogateSeparation.spatialFilter(
                    brain: SurrogateBrainModel(sources: [], matrix: []),
                    artifactTopographies: [], brainRegularization: 0.02
                )
            }) { invalidSurrogateRejections += 1 }
            if rejects({
                _ = try SurrogateSeparation.spatialFilter(
                    brain: SurrogateBrainModel(sources: [], matrix: [[1, 2], [3]]),
                    artifactTopographies: [], brainRegularization: 0.02
                )
            }) { invalidSurrogateRejections += 1 }
            if rejects({
                _ = try SurrogateSeparation.spatialFilter(
                    brain: brain, artifactTopographies: [[1, 2]], brainRegularization: 0.02
                )
            }) { invalidSurrogateRejections += 1 }
            if rejects({
                _ = try SurrogateSeparation.spatialFilter(
                    brain: brain,
                    artifactTopographies: [[Double](repeating: .nan, count: 16)],
                    brainRegularization: 0.02
                )
            }) { invalidSurrogateRejections += 1 }
            if rejects({
                _ = try SurrogateSeparation.spatialFilter(
                    brain: brain, artifactTopographies: [], brainRegularization: -0.01
                )
            }) { invalidSurrogateRejections += 1 }
            outcomes.append(SelfTest.Outcome(
                name: "SI-0 PCA-S fixture rejects empty, ragged, mismatched and non-finite inputs",
                snr: Double(invalidSurrogateRejections),
                passed: invalidSurrogateRejections == 5,
                expectation: "all five invalid matrix/regularization inputs fail explicitly"
            ))
        } catch {
            outcomes.append(SelfTest.Outcome(
                name: "SI-0 extraction-boundary fixtures",
                snr: .infinity, passed: false,
                expectation: "valid fixed lead-field and PCA-S fixtures (\(error.localizedDescription))"
            ))
        }

        return outcomes
    }
}
