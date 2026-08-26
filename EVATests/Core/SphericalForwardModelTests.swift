//
//  SphericalForwardModelTests.swift
//  EVATests
//
//  Shared forward-model ownership and boundary tests for SI-1.
//

import Foundation
import Testing
@testable import EVA

struct SphericalForwardModelTests {
    private let homogeneousHead = ForwardHeadModel(
        name: "homogeneous test sphere",
        centerMeters: SIMD3<Double>(repeating: 0),
        shells: [
            ForwardHeadShell(
                name: "conductor",
                radiusMeters: 0.085,
                conductivitySiemensPerMeter: 0.33
            )
        ]
    )

    private let electrodes = OrderedElectrodes(
        names: ["front", "right", "vertex", "left"],
        positionsMeters: [
            SIMD3<Double>(0, 0.085, 0),
            SIMD3<Double>(0.085, 0, 0),
            SIMD3<Double>(0, 0, 0.085),
            SIMD3<Double>(-0.085, 0, 0)
        ]
    )

    @Test func centeredDipoleMatchesClosedFormAndPreservesIdentity() throws {
        let dipole = ForwardDipole(
            id: "center",
            positionMeters: SIMD3<Double>(repeating: 0),
            orientationUnit: SIMD3<Double>(0, 0, 1)
        )
        let field = try SphericalForwardModel.leadField(
            head: homogeneousHead,
            electrodes: electrodes,
            dipoles: [dipole],
            reference: .infinity,
            harmonicTerms: 8
        )

        #expect(field.electrodeNames == electrodes.names)
        #expect(field.dipoleIDs == [dipole.id])
        #expect(field.freeMicrovoltsPerNanoampereMeter.count == 4)
        #expect(field.freeMicrovoltsPerNanoampereMeter.allSatisfy { $0.count == 3 })
        #expect(field.orientedMicrovoltsPerNanoampereMeter.allSatisfy { $0.count == 1 })

        let expected = 1e-3 * 3 / (4 * Double.pi * 0.33 * 0.085 * 0.085)
        let measured = field.orientedMicrovoltsPerNanoampereMeter[2][0]
        #expect(abs(measured - expected) / expected < 1e-12)
    }

    @Test func averageReferenceAppliesToEveryFreeColumn() throws {
        let dipole = ForwardDipole(
            id: "off-center",
            positionMeters: SIMD3<Double>(0.011, -0.008, 0.029),
            orientationUnit: SIMD3<Double>(0, 1, 0)
        )
        let field = try SphericalForwardModel.leadField(
            head: homogeneousHead,
            electrodes: electrodes,
            dipoles: [dipole],
            reference: .average,
            harmonicTerms: 100
        )

        for column in 0..<3 {
            let mean = field.freeMicrovoltsPerNanoampereMeter.reduce(0.0) {
                $0 + $1[column]
            } / 4
            #expect(abs(mean) < 1e-14)
        }
    }

    @Test func typedValidationRejectsMalformedInputs() {
        let dipole = ForwardDipole(
            id: "center",
            positionMeters: SIMD3<Double>(repeating: 0),
            orientationUnit: SIMD3<Double>(0, 0, 1)
        )
        #expect(throws: SphericalForwardError.emptyElectrodes) {
            _ = try SphericalForwardModel.leadField(
                head: homogeneousHead,
                electrodes: OrderedElectrodes(names: [], positionsMeters: []),
                dipoles: [dipole],
                reference: .average,
                harmonicTerms: 10
            )
        }
        #expect(throws: SphericalForwardError.invalidHarmonicTermCount(0)) {
            _ = try SphericalForwardModel.leadField(
                head: homogeneousHead,
                electrodes: electrodes,
                dipoles: [dipole],
                reference: .average,
                harmonicTerms: 0
            )
        }
    }

    @Test func electrodeGeometryAdapterPreservesRowOrderAndPhysicalScale() throws {
        let geometry = ElectrodeGeometry(
            name: "fixture",
            positions: [
                0: SIMD3<Double>(0, 1, 0),
                1: SIMD3<Double>(1, 0, 0),
                2: SIMD3<Double>(0, 0, 1)
            ],
            channelNames: [0: "xml-front", 1: "xml-right", 2: "xml-vertex"]
        )
        let ordered = try geometry.orderedForwardElectrodes(
            channelCount: 3,
            signalChannelNames: ["F", "R", "V"],
            head: homogeneousHead
        )

        #expect(ordered.names == ["F", "R", "V"])
        #expect(ordered.positionsMeters == [
            SIMD3<Double>(0, 0.085, 0),
            SIMD3<Double>(0.085, 0, 0),
            SIMD3<Double>(0, 0, 0.085)
        ])
    }

    @Test func electrodeGeometryAdapterRejectsMissingRows() {
        let geometry = ElectrodeGeometry(
            name: "incomplete",
            positions: [0: SIMD3<Double>(0, 1, 0)]
        )
        #expect(throws: ElectrodeGeometryForwardError.incomplete(
            expected: 2,
            found: 1,
            missingOneBased: [2]
        )) {
            _ = try geometry.orderedForwardElectrodes(
                channelCount: 2,
                head: homogeneousHead
            )
        }
    }
}
