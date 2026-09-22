//
//  ForwardOperatorTests.swift
//  EVATests
//
//  AF-1: the common forward-operator contract. Continuous adapters must be
//  sample-identical to the solvers they wrap, and a fixed-catalog operator must
//  refuse anything outside the source space it was exported with.
//

import Foundation
import Testing
@testable import EVA

struct ForwardOperatorTests {
    private let electrodes = OrderedElectrodes(
        names: ["front", "right", "vertex", "left", "back"],
        positionsMeters: [
            SIMD3<Double>(0, 0.085, 0),
            SIMD3<Double>(0.085, 0, 0),
            SIMD3<Double>(0, 0, 0.085),
            SIMD3<Double>(-0.085, 0, 0),
            SIMD3<Double>(0, -0.06, 0.06)
        ]
    )

    private let dipoles = [
        ForwardDipole(id: "a", positionMeters: SIMD3(0.01, 0.02, 0.03), orientationUnit: SIMD3(0, 0, 1)),
        ForwardDipole(id: "b", positionMeters: SIMD3(-0.03, 0.01, 0.02), orientationUnit: SIMD3(1, 0, 0)),
        ForwardDipole(id: "c", positionMeters: SIMD3(0.0, -0.04, 0.01), orientationUnit: SIMD3(0, 0.6, 0.8))
    ]

    // MARK: Continuous adapters are the solvers, unchanged

    @Test(arguments: [ForwardEEGReference.infinity, .average])
    func sphereOperatorIsTheSphericalSolver(reference: ForwardEEGReference) throws {
        let op = SphericalForwardOperator(head: .classicThreeShell, harmonicTerms: 60)
        let direct = try SphericalForwardModel.leadField(
            head: .classicThreeShell, electrodes: electrodes, dipoles: dipoles,
            reference: reference, harmonicTerms: 60
        )
        #expect(try op.leadField(electrodes: electrodes, dipoles: dipoles, reference: reference) == direct)
        #expect(op.sourceDomain == .continuous)
        #expect(op.provenance.kind == .analyticSphere)
        #expect(op.frame == .head)
    }

    @Test func ellipsoidOperatorIsTheEllipsoidalSolver() throws {
        let model = ForwardEllipsoidModel.classicThreeShellEllipsoid
        let op = EllipsoidalForwardOperator(ellipsoid: model, harmonicTerms: 60)
        let direct = try EllipsoidalForwardModel.leadField(
            ellipsoid: model, electrodes: electrodes, dipoles: dipoles,
            reference: .average, harmonicTerms: 60
        )
        #expect(try op.leadField(electrodes: electrodes, dipoles: dipoles, reference: .average) == direct)
        #expect(op.provenance.kind == .affineEllipsoid)
    }

    @Test func concentricBEMOperatorIsTheBEMSolver() throws {
        let op = ConcentricBEMForwardOperator(head: .classicThreeShell, subdivisions: 1)
        let direct = try BEMForwardModel.leadField(
            head: .classicThreeShell, electrodes: electrodes, dipoles: [dipoles[0]],
            reference: .infinity, subdivisions: 1
        )
        #expect(try op.leadField(electrodes: electrodes, dipoles: [dipoles[0]], reference: .infinity) == direct)
        #expect(op.provenance.kind == .concentricBEM)
        #expect(op.provenance.details["subdivisions"] == "1")
    }

    @Test func convergenceVerificationTravelsWithTheOperator() {
        // Three terms cannot converge for an eccentric source.
        let deep = ForwardDipole(id: "deep", positionMeters: SIMD3(0.06, 0, 0), orientationUnit: SIMD3(1, 0, 0))
        let op = SphericalForwardOperator(head: .classicThreeShell, harmonicTerms: 3, verifyConvergence: true)
        #expect(throws: SphericalForwardError.self) {
            _ = try op.leadField(electrodes: electrodes, dipoles: [deep], reference: .infinity)
        }
    }

    // MARK: Simulator boundary

    @Test func simulatorEllipsoidPlacesTheMontageOnItsOwnScalp() throws {
        let montage = Montage.standard(count: 19)
        let ellipsoid = SimulatedEllipsoidModel.classicThreeShellEllipsoid
        let placed = SimulationForwardModel.ellipsoid(ellipsoid).electrodes(for: montage)
        let semi = ellipsoid.forwardModel.scalpSemiAxesMeters
        #expect(placed.names == montage.channelNames)
        for (position, unit) in zip(placed.positionsMeters, montage.positions) {
            #expect(position == SIMD3(unit.x * semi.x, unit.y * semi.y, unit.z * semi.z))
        }
    }

    @Test func simulatorSphereOverloadDelegatesToTheForwardModel() throws {
        let montage = Montage.standard(count: 19)
        let source = SimulatedSource(
            id: "S001", positionMeters: Vector3D(x: 0.01, y: 0.02, z: 0.03),
            orientation: Vector3D(x: 0, y: 0, z: 1), bandName: "alpha", seed: 1,
            rmsMomentNanoampereMeters: 1
        )
        let legacy = try SphericalForwardModel.leadField(
            head: .classicThreeShell, montage: montage, sources: [source], reference: .average, terms: 60
        )
        let model = try SimulationForwardModel.sphere(.classicThreeShell).leadField(
            montage: montage, sources: [source], reference: .average, terms: 60
        )
        #expect(legacy.freeOrientationMatrixMicrovoltsPerNanoampereMeter
            == model.freeOrientationMatrixMicrovoltsPerNanoampereMeter)
        #expect(legacy.matrixMicrovoltsPerNanoampereMeter == model.matrixMicrovoltsPerNanoampereMeter)
    }

    // MARK: Fixed-catalog operator

    private func catalog(native: ForwardEEGReference = .infinity) throws -> PrecomputedLeadFieldOperator {
        let exported = try SphericalForwardModel.leadField(
            head: .classicThreeShell, electrodes: electrodes, dipoles: dipoles,
            reference: native, harmonicTerms: 60
        )
        return try PrecomputedLeadFieldOperator(
            provenance: ForwardModelProvenance(kind: .importedLeadField, name: "test export"),
            frame: .head,
            electrodeNames: electrodes.names,
            sources: dipoles,
            freeMicrovoltsPerNanoampereMeter: exported.freeMicrovoltsPerNanoampereMeter,
            nativeReference: native
        )
    }

    @Test func catalogAnswersForItsSourcesInAnyOrderAndOrientation() throws {
        let op = try catalog()
        #expect(op.sourceDomain == .fixedCatalog)

        let reordered = OrderedElectrodes(
            names: electrodes.names.reversed(), positionsMeters: electrodes.positionsMeters.reversed()
        )
        var turned = dipoles[0]
        turned.orientationUnit = SIMD3(0.6, 0, 0.8)
        let requested = [dipoles[2], turned]

        let expected = try SphericalForwardModel.leadField(
            head: .classicThreeShell, electrodes: reordered, dipoles: requested,
            reference: .average, harmonicTerms: 60
        )
        let field = try op.leadField(electrodes: reordered, dipoles: requested, reference: .average)
        #expect(field.electrodeNames == expected.electrodeNames)
        #expect(field.dipoleIDs == ["c", "a"])
        for (row, expectedRow) in zip(field.orientedMicrovoltsPerNanoampereMeter, expected.orientedMicrovoltsPerNanoampereMeter) {
            for (value, reference) in zip(row, expectedRow) {
                #expect(abs(value - reference) < 1e-12)
            }
        }
    }

    @Test func catalogRefusesASourceItDoesNotHave() throws {
        let stranger = ForwardDipole(id: "z", positionMeters: .zero, orientationUnit: SIMD3(0, 0, 1))
        #expect(throws: ForwardOperatorError.dipoleNotInCatalog(id: "z")) {
            _ = try catalog().leadField(electrodes: electrodes, dipoles: [stranger], reference: .infinity)
        }
    }

    @Test func catalogRefusesToMoveASource() throws {
        var moved = dipoles[1]
        moved.positionMeters.x += 0.002
        #expect {
            _ = try catalog().leadField(electrodes: electrodes, dipoles: [moved], reference: .infinity)
        } throws: { error in
            guard case .catalogPositionMismatch(let id, let distance) = error as? ForwardOperatorError else { return false }
            return id == "b" && abs(distance - 0.002) < 1e-12
        }
    }

    @Test func catalogRefusesAChangedMontage() throws {
        let partial = OrderedElectrodes(
            names: ["front", "right", "vertex", "left", "Cz"],
            positionsMeters: electrodes.positionsMeters
        )
        #expect(throws: ForwardOperatorError.electrodeSetMismatch(missing: ["Cz"], unexpected: ["back"])) {
            _ = try catalog().leadField(electrodes: partial, dipoles: dipoles, reference: .infinity)
        }
    }

    @Test func catalogCannotUndoAnAverageReference() throws {
        #expect(throws: ForwardOperatorError.referenceUnavailable(native: .average, requested: .infinity)) {
            _ = try catalog(native: .average).leadField(electrodes: electrodes, dipoles: dipoles, reference: .infinity)
        }
    }

    @Test func malformedCatalogIsRejectedAtConstruction() {
        #expect(throws: ForwardOperatorError.self) {
            _ = try PrecomputedLeadFieldOperator(
                provenance: ForwardModelProvenance(kind: .importedLeadField, name: "bad"),
                frame: .head, electrodeNames: ["a", "b"], sources: dipoles,
                freeMicrovoltsPerNanoampereMeter: [[0, 0, 0]], nativeReference: .infinity
            )
        }
    }

    // MARK: Cache

    @Test func cacheReturnsTheSameFieldAndKeysOnEveryInput() throws {
        let cache = ForwardLeadFieldCache()
        let op = SphericalForwardOperator(head: .classicThreeShell, harmonicTerms: 40)
        let first = try cache.leadField(op, electrodes: electrodes, dipoles: dipoles, reference: .average)
        let second = try cache.leadField(op, electrodes: electrodes, dipoles: dipoles, reference: .average)
        #expect(first == second)
        #expect(cache.hits == 1 && cache.misses == 1)

        _ = try cache.leadField(op, electrodes: electrodes, dipoles: dipoles, reference: .infinity)
        var deeper = op
        deeper.harmonicTerms = 41
        _ = try cache.leadField(deeper, electrodes: electrodes, dipoles: dipoles, reference: .average)
        #expect(cache.hits == 1 && cache.misses == 3)
    }
}
