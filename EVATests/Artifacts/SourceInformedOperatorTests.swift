//
//  SourceInformedOperatorTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation
import Testing
@testable import EVA

struct SourceInformedOperatorTests {
    private let brainBasis = [
        [1.0, 0.2],
        [0.0, 1.0],
        [-1.0, 0.1],
        [0.0, -1.0],
    ]
    private let artifact = [1.0, 1.0, 1.0, 1.0]

    @Test func operatorIsFiniteSquareDeterministicAndDiagnosed() throws {
        let first = try SourceInformedSeparation.makeOperator(
            brainBasis: brainBasis,
            artifactTopographies: [artifact, artifact],
            brainRegularization: 0.02
        )
        let second = try SourceInformedSeparation.makeOperator(
            brainBasis: brainBasis,
            artifactTopographies: [artifact, artifact],
            brainRegularization: 0.02
        )

        #expect(first == second)
        #expect(first.matrix.count == 4)
        #expect(first.matrix.allSatisfy { $0.count == 4 && $0.allSatisfy(\.isFinite) })
        #expect(first.diagnostics.artifactInputCount == 2)
        #expect(first.diagnostics.artifactRetainedCount == 1)
        #expect(first.diagnostics.artifactDroppedCount == 1)
        #expect(first.diagnostics.effectiveRidge > 0)
        #expect(first.diagnostics.minimumCholeskyDiagonal > 0)
    }

    @Test func operatorAttenuatesItsUnpenalizedArtifactSubspace() throws {
        let sourceInformedOperator = try SourceInformedSeparation.makeOperator(
            brainBasis: brainBasis,
            artifactTopographies: [artifact],
            brainRegularization: 0.02
        )
        let output = try SourceInformedSeparation.apply(
            sourceInformedOperator, to: artifact.map { [$0] }
        )
        let outputNorm = output.reduce(0.0) { $0 + $1[0] * $1[0] }.squareRoot()
        #expect(outputNorm < 1e-12)
    }

    @Test func operatorPreservesReachableBrainShapeWithoutArtifacts() throws {
        let sourceInformedOperator = try SourceInformedSeparation.makeOperator(
            brainBasis: brainBasis,
            artifactTopographies: [],
            brainRegularization: 0
        )
        let probe = brainBasis.map { [$0[0], $0[1]] }
        let output = try SourceInformedSeparation.apply(sourceInformedOperator, to: probe)

        for sample in 0..<2 {
            let inputColumn = probe.map { $0[sample] }
            let outputColumn = output.map { $0[sample] }
            let residual = zip(inputColumn, outputColumn).reduce(0.0) {
                $0 + ($1.0 - $1.1) * ($1.0 - $1.1)
            }.squareRoot()
            #expect(residual < 1e-10)
        }
    }

    @Test func constructionRejectsMalformedAndDegenerateInputs() {
        #expect(throws: SourceInformedOperatorError.emptyBrainBasis) {
            _ = try SourceInformedSeparation.makeOperator(
                brainBasis: [], artifactTopographies: [], brainRegularization: 0.02
            )
        }
        #expect(throws: SourceInformedOperatorError.raggedBrainBasis) {
            _ = try SourceInformedSeparation.makeOperator(
                brainBasis: [[1, 2], [3]], artifactTopographies: [], brainRegularization: 0.02
            )
        }
        #expect(throws: SourceInformedOperatorError.zeroNormBrainColumn(index: 1)) {
            _ = try SourceInformedSeparation.makeOperator(
                brainBasis: [[1, 0], [-1, 0]], artifactTopographies: [],
                brainRegularization: 0.02
            )
        }
        #expect(throws: SourceInformedOperatorError.artifactChannelMismatch(expected: 4, found: 2)) {
            _ = try SourceInformedSeparation.makeOperator(
                brainBasis: brainBasis, artifactTopographies: [[1, 2]],
                brainRegularization: 0.02
            )
        }
        #expect(throws: SourceInformedOperatorError.invalidRegularization(-0.1)) {
            _ = try SourceInformedSeparation.makeOperator(
                brainBasis: brainBasis, artifactTopographies: [], brainRegularization: -0.1
            )
        }
        #expect(throws: SourceInformedOperatorError.noProjectedBrainEnergy) {
            _ = try SourceInformedSeparation.makeOperator(
                brainBasis: [[1.0], [0.0]], artifactTopographies: [[1.0, 0.0]],
                brainRegularization: 0.02
            )
        }
    }

    @Test func applicationRejectsChannelRaggedAndNonFiniteSignals() throws {
        let sourceInformedOperator = try SourceInformedSeparation.makeOperator(
            brainBasis: brainBasis, artifactTopographies: [], brainRegularization: 0.02
        )
        #expect(throws: SourceInformedOperatorError.signalChannelMismatch(expected: 4, found: 2)) {
            _ = try SourceInformedSeparation.apply(sourceInformedOperator, to: [[1], [2]])
        }
        #expect(throws: SourceInformedOperatorError.raggedSignal) {
            _ = try SourceInformedSeparation.apply(
                sourceInformedOperator, to: [[1, 2], [1], [1, 2], [1, 2]]
            )
        }
        #expect(throws: SourceInformedOperatorError.nonFiniteSignal) {
            _ = try SourceInformedSeparation.apply(
                sourceInformedOperator, to: [[1], [2], [.nan], [4]]
            )
        }
    }
}
