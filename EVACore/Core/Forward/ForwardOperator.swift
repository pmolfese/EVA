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

/// Lightweight identity for lead-field memoization. Analytic operators are
/// identified by the parameters that determine their output; imported matrices
/// receive an instance ID so a cache lookup never hashes the matrix itself.
nonisolated enum ForwardOperatorCacheIdentity: Hashable, Sendable {
    case analyticSphere(
        head: ForwardHeadModel,
        harmonicTerms: Int,
        verifyConvergence: Bool
    )
    case affineEllipsoid(
        ellipsoid: ForwardEllipsoidModel,
        harmonicTerms: Int,
        verifyConvergence: Bool
    )
    case concentricBEM(head: ForwardHeadModel, subdivisions: Int)
    case precomputed(UUID)
}

nonisolated protocol ForwardOperator: Sendable {
    var provenance: ForwardModelProvenance { get }
    var sourceDomain: ForwardSourceDomain { get }
    var cacheIdentity: ForwardOperatorCacheIdentity { get }
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
    case electrodePositionMismatch(name: String, distanceMeters: Double)
    case referenceUnavailable(native: ForwardEEGReference, requested: ForwardEEGReference)
    case malformedCatalog(String)
    case invalidElectrodes(String)
    case invalidDipoles(String)

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
            return "The requested electrodes do not match this lead field's montage (\(parts.joined(separator: "; "))). Channels are matched by exact name and catalog position."
        case .electrodePositionMismatch(let name, let distance):
            return String(
                format: "Electrode '%@' is %.3g mm from its catalog position. An imported lead field cannot be used with moved electrodes.",
                name, distance * 1000
            )
        case .referenceUnavailable(let native, let requested):
            return "This lead field is \(native.rawValue)-referenced and cannot be expressed with a \(requested.rawValue) reference."
        case .malformedCatalog(let detail):
            return "Malformed lead-field catalog: \(detail)"
        case .invalidElectrodes(let detail):
            return "Invalid requested electrodes: \(detail)"
        case .invalidDipoles(let detail):
            return "Invalid requested dipoles: \(detail)"
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
    var cacheIdentity: ForwardOperatorCacheIdentity {
        .analyticSphere(
            head: head,
            harmonicTerms: harmonicTerms,
            verifyConvergence: verifyConvergence
        )
    }
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
    var cacheIdentity: ForwardOperatorCacheIdentity {
        .affineEllipsoid(
            ellipsoid: ellipsoid,
            harmonicTerms: harmonicTerms,
            verifyConvergence: verifyConvergence
        )
    }
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
    var cacheIdentity: ForwardOperatorCacheIdentity {
        .concentricBEM(head: head, subdivisions: subdivisions)
    }
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
nonisolated struct PrecomputedLeadFieldOperator: ForwardOperator {
    let provenance: ForwardModelProvenance
    let frame: CoordinateFrame
    /// Authoritative montage used when the matrix was computed. Names may be
    /// reordered by a caller, but physical positions may not move.
    let catalogElectrodes: OrderedElectrodes
    /// Catalog source positions. Each catalog orientation is ignored, because
    /// the gain is free-orientation and any requested orientation projects exactly.
    let sources: [ForwardDipole]
    /// electrodes × (3 · sources), x/y/z columns per source, in µV/(nA·m).
    let freeMicrovoltsPerNanoampereMeter: [[Double]]
    let nativeReference: ForwardEEGReference
    /// Tolerances absorb float round trips, not placement error.
    let positionToleranceMeters: Double
    let electrodePositionToleranceMeters: Double
    private let cacheID: UUID

    var sourceDomain: ForwardSourceDomain { .fixedCatalog }
    var cacheIdentity: ForwardOperatorCacheIdentity { .precomputed(cacheID) }

    init(
        provenance: ForwardModelProvenance,
        frame: CoordinateFrame,
        electrodes: OrderedElectrodes,
        sources: [ForwardDipole],
        freeMicrovoltsPerNanoampereMeter: [[Double]],
        nativeReference: ForwardEEGReference,
        positionToleranceMeters: Double = 1e-6,
        electrodePositionToleranceMeters: Double = 1e-6
    ) throws {
        try Self.validateCatalogElectrodes(electrodes)
        try Self.validateCatalogSources(sources)
        guard positionToleranceMeters.isFinite, positionToleranceMeters > 0 else {
            throw ForwardOperatorError.malformedCatalog(
                "source-position tolerance must be positive and finite"
            )
        }
        guard electrodePositionToleranceMeters.isFinite,
              electrodePositionToleranceMeters > 0 else {
            throw ForwardOperatorError.malformedCatalog(
                "electrode-position tolerance must be positive and finite"
            )
        }
        guard freeMicrovoltsPerNanoampereMeter.count == electrodes.names.count,
              freeMicrovoltsPerNanoampereMeter.allSatisfy({ $0.count == 3 * sources.count }) else {
            throw ForwardOperatorError.malformedCatalog(
                "gain must be \(electrodes.names.count) × \(3 * sources.count) (electrodes × 3·sources)"
            )
        }
        guard freeMicrovoltsPerNanoampereMeter.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw ForwardOperatorError.malformedCatalog("gain contains a non-finite value")
        }
        self.provenance = provenance
        self.frame = frame
        self.catalogElectrodes = electrodes
        self.sources = sources
        self.freeMicrovoltsPerNanoampereMeter = freeMicrovoltsPerNanoampereMeter
        self.nativeReference = nativeReference
        self.positionToleranceMeters = positionToleranceMeters
        self.electrodePositionToleranceMeters = electrodePositionToleranceMeters
        self.cacheID = UUID()
    }

    func leadField(
        electrodes: OrderedElectrodes,
        dipoles: [ForwardDipole],
        reference: ForwardEEGReference
    ) throws -> ForwardLeadField {
        try Self.validateRequestedElectrodes(electrodes)
        try Self.validateRequestedDipoles(dipoles)
        if reference != nativeReference && reference == .infinity {
            throw ForwardOperatorError.referenceUnavailable(native: nativeReference, requested: reference)
        }

        // Rows: an exact name bijection, in the caller's order, at the physical
        // position where each catalog row was computed.
        let rowByName = Dictionary(
            uniqueKeysWithValues: catalogElectrodes.names.enumerated().map { ($1, $0) }
        )
        let requested = Set(electrodes.names)
        let missing = electrodes.names.filter { rowByName[$0] == nil }
        let unexpected = catalogElectrodes.names.filter { !requested.contains($0) }
        guard missing.isEmpty, unexpected.isEmpty, requested.count == electrodes.names.count else {
            throw ForwardOperatorError.electrodeSetMismatch(missing: missing, unexpected: unexpected)
        }
        let rows = electrodes.names.map { rowByName[$0]! }
        for requestedIndex in electrodes.names.indices {
            let catalogIndex = rows[requestedIndex]
            let distance = simd_distance(
                electrodes.positionsMeters[requestedIndex],
                catalogElectrodes.positionsMeters[catalogIndex]
            )
            guard distance <= electrodePositionToleranceMeters else {
                throw ForwardOperatorError.electrodePositionMismatch(
                    name: electrodes.names[requestedIndex],
                    distanceMeters: distance
                )
            }
        }

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

    private static func validateCatalogElectrodes(_ electrodes: OrderedElectrodes) throws {
        guard !electrodes.names.isEmpty else {
            throw ForwardOperatorError.malformedCatalog("electrode catalog is empty")
        }
        guard electrodes.names.count == electrodes.positionsMeters.count else {
            throw ForwardOperatorError.malformedCatalog(
                "electrode names and positions have different counts"
            )
        }
        var names = Set<String>()
        for (index, pair) in zip(electrodes.names, electrodes.positionsMeters).enumerated() {
            let (name, position) = pair
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ForwardOperatorError.malformedCatalog("electrode \(index) has an empty name")
            }
            guard names.insert(name).inserted else {
                throw ForwardOperatorError.malformedCatalog("duplicate electrode name '\(name)'")
            }
            guard isFinite(position) else {
                throw ForwardOperatorError.malformedCatalog(
                    "electrode '\(name)' has a non-finite position"
                )
            }
        }
    }

    private static func validateCatalogSources(_ sources: [ForwardDipole]) throws {
        guard !sources.isEmpty else {
            throw ForwardOperatorError.malformedCatalog("source catalog is empty")
        }
        var ids = Set<String>()
        for (index, source) in sources.enumerated() {
            guard !source.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ForwardOperatorError.malformedCatalog("source \(index) has an empty ID")
            }
            guard ids.insert(source.id).inserted else {
                throw ForwardOperatorError.malformedCatalog("duplicate source ID '\(source.id)'")
            }
            guard isFinite(source.positionMeters) else {
                throw ForwardOperatorError.malformedCatalog(
                    "source '\(source.id)' has a non-finite position"
                )
            }
            guard isUnit(source.orientationUnit) else {
                throw ForwardOperatorError.malformedCatalog(
                    "source '\(source.id)' orientation must be finite and unit length"
                )
            }
        }
    }

    private static func validateRequestedElectrodes(_ electrodes: OrderedElectrodes) throws {
        guard !electrodes.names.isEmpty else {
            throw ForwardOperatorError.invalidElectrodes("the montage is empty")
        }
        guard electrodes.names.count == electrodes.positionsMeters.count else {
            throw ForwardOperatorError.invalidElectrodes(
                "names and positions have different counts"
            )
        }
        var names = Set<String>()
        for (index, pair) in zip(electrodes.names, electrodes.positionsMeters).enumerated() {
            let (name, position) = pair
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ForwardOperatorError.invalidElectrodes("electrode \(index) has an empty name")
            }
            guard names.insert(name).inserted else {
                throw ForwardOperatorError.invalidElectrodes(
                    "duplicate electrode name '\(name)'"
                )
            }
            guard isFinite(position) else {
                throw ForwardOperatorError.invalidElectrodes(
                    "electrode '\(name)' has a non-finite position"
                )
            }
        }
    }

    private static func validateRequestedDipoles(_ dipoles: [ForwardDipole]) throws {
        guard !dipoles.isEmpty else {
            throw ForwardOperatorError.invalidDipoles("the source request is empty")
        }
        var ids = Set<String>()
        for (index, dipole) in dipoles.enumerated() {
            guard !dipole.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ForwardOperatorError.invalidDipoles("dipole \(index) has an empty ID")
            }
            guard ids.insert(dipole.id).inserted else {
                throw ForwardOperatorError.invalidDipoles("duplicate dipole ID '\(dipole.id)'")
            }
            guard isFinite(dipole.positionMeters) else {
                throw ForwardOperatorError.invalidDipoles(
                    "dipole '\(dipole.id)' has a non-finite position"
                )
            }
            guard isUnit(dipole.orientationUnit) else {
                throw ForwardOperatorError.invalidDipoles(
                    "dipole '\(dipole.id)' orientation must be finite and unit length"
                )
            }
        }
    }

    private static func isFinite(_ value: SIMD3<Double>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static func isUnit(_ value: SIMD3<Double>) -> Bool {
        isFinite(value) && abs(simd_length(value) - 1) < 1e-8
    }
}

// MARK: - Cache

/// Memoizes lead fields by (operator, electrodes, dipoles, reference). Lead
/// fields are pure functions of those inputs, so a hit is exact, never approximate.
nonisolated final class ForwardLeadFieldCache: @unchecked Sendable {
    private struct Key: Hashable {
        var operatorIdentity: ForwardOperatorCacheIdentity
        var electrodes: OrderedElectrodes
        var dipoles: [ForwardDipole]
        var reference: ForwardEEGReference
    }

    private let lock = NSLock()
    private var entries: [Key: ForwardLeadField] = [:]
    private var hitCount = 0
    private var missCount = 0

    var hits: Int {
        lock.lock()
        defer { lock.unlock() }
        return hitCount
    }

    var misses: Int {
        lock.lock()
        defer { lock.unlock() }
        return missCount
    }

    init() {}

    func leadField(
        _ forwardOperator: any ForwardOperator,
        electrodes: OrderedElectrodes,
        dipoles: [ForwardDipole],
        reference: ForwardEEGReference
    ) throws -> ForwardLeadField {
        let key = Key(
            operatorIdentity: forwardOperator.cacheIdentity,
            electrodes: electrodes,
            dipoles: dipoles,
            reference: reference
        )
        lock.lock()
        if let cached = entries[key] {
            hitCount += 1
            lock.unlock()
            return cached
        }
        missCount += 1
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
