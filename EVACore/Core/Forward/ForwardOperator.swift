//
//  ForwardOperator.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  One contract for every EEG forward model (ROADMAP R3.4 / AF-1). Consumers —
//  the simulator today, dipole fitting and inverse imaging later — ask an
//  operator for a `ForwardLeadField` and never name the solver behind it.
//
//  ## Two kinds of operator
//
//  A **continuous** operator (the analytic sphere and ellipsoid, EVA's own
//  concentric BEM, and later an imported MNE BEM *solution*) can evaluate any
//  valid dipole. A **fixed-catalog** operator is a lead field somebody else
//  already computed (an MNE `-fwd.fif`, a DUNEuro or OpenMEEG export): its source
//  positions were frozen at export time, so it answers only for those positions
//  and refuses anything else by name. It never interpolates between grid nodes.
//  Sliding silently to the nearest node would turn a mismatched source space
//  into plausible-looking but wrong data.
//
//  Electrode *placement* is not part of this contract. The caller supplies
//  physical electrode positions in the operator's frame. The simulator places a
//  unit montage on each analytic scalp itself; an imported model arrives with
//  coregistered electrodes.
//

import Foundation
import simd

/// Whether an operator can evaluate an arbitrary dipole or only its own catalog.
nonisolated enum ForwardSourceDomain: String, Codable, Sendable, Equatable {
    case continuous
    case fixedCatalog
}

/// What produced a lead field, carried into every result so a BEM or FEM result
/// is never mistaken for a sphere result.
nonisolated struct ForwardModelProvenance: Codable, Sendable, Hashable {
    nonisolated enum Kind: String, Codable, Sendable, Hashable {
        case analyticSphere
        case affineEllipsoid
        case concentricBEM
        case importedBEMSolution
        case importedLeadField
    }

    var kind: Kind
    var name: String
    /// Solver settings and external metadata. EVA does not interpret every
    /// field, but it must not discard them.
    var details: [String: String] = [:]
}

nonisolated protocol ForwardOperator: Sendable {
    var provenance: ForwardModelProvenance { get }
    var sourceDomain: ForwardSourceDomain { get }
    /// Frame that electrode and dipole positions must be expressed in.
    var frame: CoordinateFrame { get }

    /// Lead field in µV/(nA·m), preserving input electrode and dipole order.
    func leadField(
        electrodes: OrderedElectrodes,
        dipoles: [ForwardDipole],
        reference: ForwardEEGReference
    ) throws -> ForwardLeadField
}

nonisolated enum ForwardOperatorError: LocalizedError, Sendable, Equatable {
    case dipoleNotInCatalog(id: String)
    case catalogPositionMismatch(id: String, distanceMeters: Double)
    case electrodeSetMismatch(missing: [String], unexpected: [String])
    case referenceUnavailable(native: ForwardEEGReference, requested: ForwardEEGReference)
    case malformedCatalog(String)

    var errorDescription: String? {
        switch self {
        case .dipoleNotInCatalog(let id):
            return "Dipole '\(id)' is not in this lead field's source space. An imported lead field only covers the sources it was exported with; it cannot place a dipole anywhere else."
        case .catalogPositionMismatch(let id, let distance):
            return String(
                format: "Dipole '%@' is %.3g mm from the catalog source with that ID. An imported lead field cannot move a source; it does not interpolate between grid nodes.",
                id, distance * 1000
            )
        case .electrodeSetMismatch(let missing, let unexpected):
            var parts: [String] = []
            if !missing.isEmpty { parts.append("not in the lead field: \(missing.joined(separator: ", "))") }
            if !unexpected.isEmpty { parts.append("in the lead field but not requested: \(unexpected.joined(separator: ", "))") }
            return "The requested electrodes do not match this lead field's montage (\(parts.joined(separator: "; "))). Channels are matched by exact name only."
        case .referenceUnavailable(let native, let requested):
            return "This lead field is \(native.rawValue)-referenced and cannot be expressed with a \(requested.rawValue) reference."
        case .malformedCatalog(let detail):
            return "Malformed lead-field catalog: \(detail)"
        }
    }
}

// MARK: - Continuous operators

/// Concentric-sphere operator over `SphericalForwardModel`.
nonisolated struct SphericalForwardOperator: ForwardOperator, Hashable {
    var head: ForwardHeadModel
    var harmonicTerms: Int
    /// Throw instead of returning a lead field whose truncated series has not
    /// converged. See `SphericalForwardModel.leadField`.
    var verifyConvergence = false

    var sourceDomain: ForwardSourceDomain { .continuous }
    var frame: CoordinateFrame { .head }
    var provenance: ForwardModelProvenance {
        ForwardModelProvenance(
            kind: .analyticSphere,
            name: head.name,
            details: ["harmonicTerms": String(harmonicTerms), "shells": String(head.shells.count)]
        )
    }

    func leadField(
        electrodes: OrderedElectrodes,
        dipoles: [ForwardDipole],
        reference: ForwardEEGReference
    ) throws -> ForwardLeadField {
        try SphericalForwardModel.leadField(
            head: head,
            electrodes: electrodes,
            dipoles: dipoles,
            reference: reference,
            harmonicTerms: harmonicTerms,
            verifyConvergence: verifyConvergence
        )
    }
}

/// Affine-ellipsoid operator over `EllipsoidalForwardModel`.
nonisolated struct EllipsoidalForwardOperator: ForwardOperator, Hashable {
    var ellipsoid: ForwardEllipsoidModel
    var harmonicTerms: Int
    var verifyConvergence = false

    var sourceDomain: ForwardSourceDomain { .continuous }
    var frame: CoordinateFrame { .head }
    var provenance: ForwardModelProvenance {
        let s = ellipsoid.axisScale
        return ForwardModelProvenance(
            kind: .affineEllipsoid,
            name: ellipsoid.name,
            details: [
                "harmonicTerms": String(harmonicTerms),
                "shells": String(ellipsoid.sphere.shells.count),
                "axisScale": "\(s.x),\(s.y),\(s.z)"
            ]
        )
    }

    func leadField(
        electrodes: OrderedElectrodes,
        dipoles: [ForwardDipole],
        reference: ForwardEEGReference
    ) throws -> ForwardLeadField {
        try EllipsoidalForwardModel.leadField(
            ellipsoid: ellipsoid,
            electrodes: electrodes,
            dipoles: dipoles,
            reference: reference,
            harmonicTerms: harmonicTerms,
            verifyConvergence: verifyConvergence
        )
    }
}

/// EVA's own constant-element BEM on icosphere-meshed concentric shells. It is
/// a generation-side operator for sphere-mismatch studies, not an anatomical
/// head model: it cannot take imported surfaces yet (ROADMAP R3.7).
nonisolated struct ConcentricBEMForwardOperator: ForwardOperator, Hashable {
    var head: ForwardHeadModel
    var subdivisions: Int = BEMForwardModel.defaultSubdivisions

    var sourceDomain: ForwardSourceDomain { .continuous }
    var frame: CoordinateFrame { .head }
    var provenance: ForwardModelProvenance {
        ForwardModelProvenance(
            kind: .concentricBEM,
            name: head.name,
            details: [
                "solver": "EVA constant-element double-layer BEM",
                "subdivisions": String(subdivisions),
                "shells": String(head.shells.count)
            ]
        )
    }

    func leadField(
        electrodes: OrderedElectrodes,
        dipoles: [ForwardDipole],
        reference: ForwardEEGReference
    ) throws -> ForwardLeadField {
        try BEMForwardModel.leadField(
            head: head,
            electrodes: electrodes,
            dipoles: dipoles,
            reference: reference,
            subdivisions: subdivisions
        )
    }
}

// MARK: - Fixed-catalog operator

/// A lead field computed elsewhere, over a source space fixed at export time.
/// R3.7's `-fwd.fif` and plain-matrix readers build this; nothing here knows
/// which tool produced it beyond `provenance`.
nonisolated struct PrecomputedLeadFieldOperator: ForwardOperator, Hashable {
    var provenance: ForwardModelProvenance
    var frame: CoordinateFrame
    var electrodeNames: [String]
    /// Catalog source positions. Each catalog orientation is ignored, because
    /// the gain is free-orientation and any requested orientation projects exactly.
    var sources: [ForwardDipole]
    /// electrodes × (3 · sources), x/y/z columns per source, in µV/(nA·m).
    var freeMicrovoltsPerNanoampereMeter: [[Double]]
    var nativeReference: ForwardEEGReference
    /// How far a requested dipole may sit from its catalog position and still be
    /// that source. It absorbs float round trips, not placement error.
    var positionToleranceMeters: Double = 1e-6

    var sourceDomain: ForwardSourceDomain { .fixedCatalog }

    init(
        provenance: ForwardModelProvenance,
        frame: CoordinateFrame,
        electrodeNames: [String],
        sources: [ForwardDipole],
        freeMicrovoltsPerNanoampereMeter: [[Double]],
        nativeReference: ForwardEEGReference,
        positionToleranceMeters: Double = 1e-6
    ) throws {
        guard Set(electrodeNames).count == electrodeNames.count else {
            throw ForwardOperatorError.malformedCatalog("duplicate electrode names")
        }
        guard Set(sources.map(\.id)).count == sources.count else {
            throw ForwardOperatorError.malformedCatalog("duplicate source IDs")
        }
        guard freeMicrovoltsPerNanoampereMeter.count == electrodeNames.count,
              freeMicrovoltsPerNanoampereMeter.allSatisfy({ $0.count == 3 * sources.count }) else {
            throw ForwardOperatorError.malformedCatalog(
                "gain must be \(electrodeNames.count) × \(3 * sources.count) (electrodes × 3·sources)"
            )
        }
        self.provenance = provenance
        self.frame = frame
        self.electrodeNames = electrodeNames
        self.sources = sources
        self.freeMicrovoltsPerNanoampereMeter = freeMicrovoltsPerNanoampereMeter
        self.nativeReference = nativeReference
        self.positionToleranceMeters = positionToleranceMeters
    }

    func leadField(
        electrodes: OrderedElectrodes,
        dipoles: [ForwardDipole],
        reference: ForwardEEGReference
    ) throws -> ForwardLeadField {
        if reference != nativeReference && reference == .infinity {
            throw ForwardOperatorError.referenceUnavailable(native: nativeReference, requested: reference)
        }

        // Rows: an exact name bijection, in the caller's order.
        let rowByName = Dictionary(uniqueKeysWithValues: electrodeNames.enumerated().map { ($1, $0) })
        let requested = Set(electrodes.names)
        let missing = electrodes.names.filter { rowByName[$0] == nil }
        let unexpected = electrodeNames.filter { !requested.contains($0) }
        guard missing.isEmpty, unexpected.isEmpty, requested.count == electrodes.names.count else {
            throw ForwardOperatorError.electrodeSetMismatch(missing: missing, unexpected: unexpected)
        }
        let rows = electrodes.names.map { rowByName[$0]! }

        // Columns: each dipole must be a catalog source, at its catalog position.
        let indexByID = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1.id, $0) })
        let columns = try dipoles.map { dipole -> Int in
            guard let index = indexByID[dipole.id] else {
                throw ForwardOperatorError.dipoleNotInCatalog(id: dipole.id)
            }
            let distance = simd_distance(dipole.positionMeters, sources[index].positionMeters)
            guard distance <= positionToleranceMeters else {
                throw ForwardOperatorError.catalogPositionMismatch(id: dipole.id, distanceMeters: distance)
            }
            return index
        }

        var free = rows.map { row in
            columns.flatMap { column in
                freeMicrovoltsPerNanoampereMeter[row][(3 * column)..<(3 * column + 3)]
            }
        }
        if reference == .average && nativeReference == .infinity {
            for column in 0..<(3 * dipoles.count) {
                let mean = free.reduce(0.0) { $0 + $1[column] } / Double(free.count)
                for row in free.indices { free[row][column] -= mean }
            }
        }
        let oriented = free.map { row in
            dipoles.indices.map { k in
                let o = dipoles[k].orientationUnit
                return row[3 * k] * o.x + row[3 * k + 1] * o.y + row[3 * k + 2] * o.z
            }
        }
        return ForwardLeadField(
            electrodeNames: electrodes.names,
            dipoleIDs: dipoles.map(\.id),
            reference: reference,
            freeMicrovoltsPerNanoampereMeter: free,
            orientedMicrovoltsPerNanoampereMeter: oriented
        )
    }
}

// MARK: - Cache

/// Memoizes lead fields by (operator, electrodes, dipoles, reference). Lead
/// fields are pure functions of those inputs, so a hit is exact, never approximate.
nonisolated final class ForwardLeadFieldCache: @unchecked Sendable {
    private struct Key: Hashable {
        var operatorKey: AnyHashable
        var electrodes: OrderedElectrodes
        var dipoles: [ForwardDipole]
        var reference: ForwardEEGReference
    }

    private let lock = NSLock()
    private var entries: [Key: ForwardLeadField] = [:]
    private(set) var hits = 0
    private(set) var misses = 0

    init() {}

    func leadField<Operator: ForwardOperator & Hashable>(
        _ forwardOperator: Operator,
        electrodes: OrderedElectrodes,
        dipoles: [ForwardDipole],
        reference: ForwardEEGReference
    ) throws -> ForwardLeadField {
        let key = Key(
            operatorKey: AnyHashable(forwardOperator),
            electrodes: electrodes,
            dipoles: dipoles,
            reference: reference
        )
        lock.lock()
        if let cached = entries[key] {
            hits += 1
            lock.unlock()
            return cached
        }
        misses += 1
        lock.unlock()

        let field = try forwardOperator.leadField(
            electrodes: electrodes, dipoles: dipoles, reference: reference
        )
        lock.lock()
        entries[key] = field
        lock.unlock()
        return field
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
