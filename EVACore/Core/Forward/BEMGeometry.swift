//
//  BEMGeometry.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  An *imported* BEM head model: nested triangulated shells with conductivities,
//  in one coordinate frame, with provenance saying where it came from and who
//  solved it (EVA_RESOLVE2.md R3.1).
//
//  EVA Resolve does not build BEMs. It reads a finished model from MNE-Python or
//  OpenMEEG and owns everything downstream — coregistration, the forward
//  operator, fitting, inverse imaging. This type is the single shape every
//  downstream consumer sees, whichever file the model arrived in.
//
//  Two conventions are worth stating once, because both have already cost time:
//
//  * **Shells are stored inner → outer here**, matching `ForwardHeadModel` and
//    the rest of EVA. `mne.make_bem_model` and the FIF files it writes are the
//    opposite way round (head, outer skull, inner skull), so the reader sorts on
//    import and nothing else ever indexes by position.
//  * **The geometry is solver-independent and always present.** `-bem.fif`,
//    `-bem-sol.fif` written by MNE, and `-bem-sol.fif` written through OpenMEEG
//    all carry the same surface blocks, vertex for vertex. Only the solution
//    matrix differs, so an OpenMEEG file is a perfectly good geometry import
//    even though `BEMSolution` cannot evaluate its solution.
//

import Foundation
import simd

nonisolated struct BEMGeometry: Sendable {

    /// Which program produced the model, and how it was solved. Carried into
    /// every result computed under this head model — a number from an OpenMEEG
    /// model and a number from an MNE model are not the same measurement, and
    /// the coarse-mesh difference between the two engines is not small
    /// (Tools/forward-compare/README.md).
    struct Provenance: Sendable, Codable, Equatable {
        enum Solver: String, Sendable, Codable {
            case mne
            case openmeeg
            /// Geometry with no solution attached, or a format that does not say.
            case unknown
        }

        var sourceFile: String
        var format: String
        var solver: Solver = .unknown
        /// FIFF_BEM_APPROX, when the file carried one: 1 constant, 2 linear collocation.
        var approximation: Int? = nil
        var subject: String? = nil
        var importedAt: Date = Date()
        var note: String? = nil

        var summary: String {
            var parts = ["\(format) — \(sourceFile)"]
            if solver != .unknown { parts.append("solved by \(solver.rawValue)") }
            if approximation == 2 { parts.append("linear collocation") }
            if approximation == 1 { parts.append("constant collocation") }
            if let subject { parts.append("subject \(subject)") }
            return parts.joined(separator: ", ")
        }
    }

    /// Innermost first. One `BEMSurface` per compartment boundary, each carrying
    /// the conductivity *inside* it, which is how FIF stores sigma.
    var shells: [BEMSurface]
    var frame: CoordinateFrame
    var provenance: Provenance

    var innerSkull: BEMSurface? { shells.first }
    var scalp: BEMSurface? { shells.last }
    var vertexCount: Int { shells.reduce(0) { $0 + $1.mesh.vertices.count } }
    var triangleCount: Int { shells.reduce(0) { $0 + $1.mesh.triangles.count } }
    var conductivities: [Double] { shells.map(\.sigma) }

    /// Sorts whatever order the file used into EVA's inner → outer order.
    /// `BEMSurface.Kind` is the FIFF surface id, and its numbering happens to be
    /// inner-to-outer already (brain 1 < skull 3 < head 4).
    init(surfaces: [BEMSurface], provenance: Provenance) throws {
        guard !surfaces.isEmpty else { throw BEMImportError.noSurfaces }
        let ids = surfaces.map(\.kind.rawValue)
        guard Set(ids).count == ids.count else {
            throw BEMImportError.duplicateSurface(ids.sorted().map(Int.init))
        }
        self.shells = surfaces.sorted { $0.kind.rawValue < $1.kind.rawValue }
        self.frame = shells[0].frame
        self.provenance = provenance
    }

    // MARK: - Quality gates

    /// One check the user can be shown. Import never silently accepts a model:
    /// the report is the thing the UI puts on screen next to the shells.
    struct Check: Sendable, Identifiable {
        enum Severity: String, Sendable { case pass, warning, failure }
        var id: String { name }
        var name: String
        var severity: Severity
        var detail: String
    }

    struct QualityReport: Sendable {
        var checks: [Check]
        var isUsable: Bool { !checks.contains { $0.severity == .failure } }
        var failures: [Check] { checks.filter { $0.severity == .failure } }
        var warnings: [Check] { checks.filter { $0.severity == .warning } }

        var summary: String {
            isUsable
                ? (warnings.isEmpty ? "All checks passed." : "\(warnings.count) warning(s): " + warnings.map(\.name).joined(separator: ", "))
                : "\(failures.count) failure(s): " + failures.map(\.name).joined(separator: ", ")
        }
    }

    /// Runs every structural check. `checkSelfIntersection` is the expensive one
    /// (a grid-accelerated triangle-triangle test); it is on by default because a
    /// self-intersecting shell produces a plausible-looking, wrong lead field.
    func quality(checkSelfIntersection: Bool = true) -> QualityReport {
        var checks: [Check] = []

        for shell in shells {
            let name = shell.kind.displayName
            let mesh = shell.mesh

            // Closed and genus 0: every edge shared by exactly two triangles, and
            // V - E + F = 2.
            var edges: [Int64: Int] = [:]
            edges.reserveCapacity(mesh.triangles.count * 3)
            for t in mesh.triangles {
                for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                    let lo = Int64(min(a, b)), hi = Int64(max(a, b))
                    edges[lo << 32 | hi, default: 0] += 1
                }
            }
            let unshared = edges.values.filter { $0 != 2 }.count
            let euler = mesh.vertices.count - edges.count + mesh.triangles.count
            if unshared > 0 {
                checks.append(Check(name: "\(name): closed surface", severity: .failure,
                                    detail: "\(unshared) edge(s) are not shared by exactly two triangles — the surface is open or non-manifold."))
            } else if euler != 2 {
                checks.append(Check(name: "\(name): genus 0", severity: .failure,
                                    detail: "Euler characteristic \(euler) (expected 2); the surface has \((2 - euler) / 2) handle(s)."))
            } else {
                checks.append(Check(name: "\(name): closed, genus 0", severity: .pass,
                                    detail: "\(mesh.vertices.count) vertices, \(mesh.triangles.count) triangles."))
            }

            // Outward orientation: the divergence-theorem volume is positive when
            // the winding is consistently counter-clockwise seen from outside.
            let (area, volume) = mesh.areaAndVolume
            if volume <= 0 {
                checks.append(Check(name: "\(name): outward normals", severity: .failure,
                                    detail: String(format: "Signed volume %.1f cm³ is not positive — triangle winding is inward or inconsistent.", volume * 1e6)))
            } else {
                checks.append(Check(name: "\(name): outward normals", severity: .pass,
                                    detail: String(format: "Signed volume %.0f cm³, area %.0f cm².", volume * 1e6, area * 1e4)))
            }

            // Volume sanity. Generous: this catches metres-vs-millimetres and a
            // truncated field of view, not an unusual head.
            let litres = volume * 1000
            let (lo, hi): (Double, Double) = shell.kind == .head ? (2.0, 12.0) : (shell.kind == .skull ? (1.5, 10.0) : (0.8, 3.0))
            if volume > 0 && !(lo...hi).contains(litres) {
                checks.append(Check(name: "\(name): plausible size", severity: .warning,
                                    detail: String(format: "%.2f L is outside the expected %.1f–%.1f L. Check the units — geometry in EVA is metres.", litres, lo, hi)))
            }

            if checkSelfIntersection {
                let hits = mesh.selfIntersectingTriangles(limit: 8)
                if hits.isEmpty {
                    checks.append(Check(name: "\(name): no self-intersection", severity: .pass, detail: "No intersecting triangle pairs."))
                } else {
                    checks.append(Check(name: "\(name): no self-intersection", severity: .failure,
                                        detail: "Triangles intersect each other (e.g. \(hits.prefix(3).map { "\($0.0)/\($0.1)" }.joined(separator: ", "))\(hits.count >= 8 ? ", and more" : "")). The surface folds through itself."))
                }
            }

            if shell.sigma <= 0 {
                checks.append(Check(name: "\(name): conductivity", severity: .failure,
                                    detail: "Conductivity \(shell.sigma) S/m is not positive."))
            }
        }

        // One frame for the whole model.
        let frames = Set(shells.map(\.frame))
        if frames.count > 1 {
            checks.append(Check(name: "Single coordinate frame", severity: .failure,
                                detail: "Shells disagree: \(frames.map(\.displayName).sorted().joined(separator: ", "))."))
        }

        // Nesting: every vertex of a shell is inside the next one out, by at
        // least a tolerance. A BEM whose shells touch is not solvable.
        for i in 0..<max(shells.count - 1, 0) {
            let inner = shells[i], outer = shells[i + 1]
            let index = SurfaceIndex(mesh: outer.mesh)
            var worst = Double.greatestFiniteMagnitude
            var outsideCount = 0
            for v in inner.mesh.vertices {
                let closest = index.closestPoint(to: v)
                let gap = closest.signedDistance <= 0 ? closest.distance : -closest.distance
                if gap < 0 { outsideCount += 1 }
                worst = min(worst, gap)
            }
            let label = "\(inner.kind.displayName) inside \(outer.kind.displayName)"
            if outsideCount > 0 {
                checks.append(Check(name: label, severity: .failure,
                                    detail: String(format: "%d vertices lie outside, worst by %.1f mm.", outsideCount, -worst * 1000)))
            } else if worst < Self.minimumShellSeparationMeters {
                checks.append(Check(name: label, severity: .warning,
                                    detail: String(format: "Nested, but they come within %.2f mm; below %.1f mm the solve is poorly conditioned.", worst * 1000, Self.minimumShellSeparationMeters * 1000)))
            } else {
                checks.append(Check(name: label, severity: .pass,
                                    detail: String(format: "Nested with at least %.1f mm to spare.", worst * 1000)))
            }
        }

        // Conductivity ordering: the skull is the insulator. Stated as a warning,
        // not a failure — someone may be importing a deliberately odd model.
        if shells.count >= 3, let skull = shells.first(where: { $0.kind == .skull }) {
            let others = shells.filter { $0.kind != .skull }.map(\.sigma)
            if let minOther = others.min(), skull.sigma >= minOther {
                checks.append(Check(name: "Skull is the insulating layer", severity: .warning,
                                    detail: String(format: "Skull σ %.4f S/m is not below the other compartments (min %.4f S/m).", skull.sigma, minOther)))
            } else if let minOther = others.min() {
                checks.append(Check(name: "Skull is the insulating layer", severity: .pass,
                                    detail: String(format: "Skull σ %.4f S/m, ratio 1:%.0f.", skull.sigma, minOther / skull.sigma)))
            }
        }

        return QualityReport(checks: checks)
    }

    /// Shells closer than this are reported; the double-layer system becomes
    /// ill-conditioned as two boundaries approach each other.
    static let minimumShellSeparationMeters = 0.002

    // MARK: - Import

    /// Reads the BEM surfaces out of any file MNE writes them into — a
    /// geometry-only `-bem.fif`, a `-head.fif`, or a `-bem-sol.fif` from either
    /// solver — and records where they came from.
    static func readFIF(from url: URL, subject: String? = nil) throws -> BEMGeometry {
        let surfaces = try BEMSurface.readFIF(from: url)
        let reader = try FIFReader(url: url)
        var provenance = Provenance(sourceFile: url.lastPathComponent, format: "MNE FIF", subject: subject)
        let bemTags = reader.blocks(kind: FIF.blockBEM).first ?? reader.tags
        if let approx = bemTags.first(where: { $0.kind == FIF.bemApprox }) {
            provenance.approximation = Int(approx.int32())
            provenance.solver = .mne
        }
        // MNE records a non-default solver in a JSON description tag.
        if let description = bemTags.first(where: { $0.kind == FIF.description }),
           let data = description.stringValue.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let solver = object["solver"] as? String {
            provenance.solver = Provenance.Solver(rawValue: solver) ?? .unknown
        }
        if bemTags.first(where: { $0.kind == FIF.bemPotSolution }) == nil {
            provenance.solver = .unknown
            provenance.note = "Geometry only; the file carries no BEM solution."
        }
        return try BEMGeometry(surfaces: surfaces, provenance: provenance)
    }

    /// Writes the shells the way MNE writes them, so anything EVA imports can go
    /// straight back out to `mne.read_bem_surfaces`.
    func writeFIF(to url: URL) throws {
        try BEMSurface.writeFIF(shells.reversed(), to: url)      // outer first, MNE's order
    }
}

nonisolated enum BEMImportError: LocalizedError, Sendable, Equatable {
    case noSurfaces
    case duplicateSurface([Int])
    case unsupportedSolver(String, vertices: Int, solutionEntries: Int)
    case solutionShapeMismatch(expected: Int, found: [Int])
    case unsupportedApproximation(Int)
    case solutionTooLarge(bytes: Int, limit: Int)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .noSurfaces:
            return "The file contains no BEM surfaces."
        case .duplicateSurface(let ids):
            return "The head model repeats a surface id (\(ids.map(String.init).joined(separator: ", "))); each compartment boundary must appear once."
        case .unsupportedSolver(let solver, let vertices, let entries):
            return """
                This head model was solved by \(solver), whose solution EVA cannot evaluate. \
                It holds \(entries) packed entries over potentials *and* normal currents, not the \
                \(vertices)×\(vertices) vertex-potential matrix an MNE solution holds, and only \
                libOpenMEEG can turn it into a field. The geometry imported fine, so: re-solve these \
                surfaces with mne.make_bem_solution(solver='mne'), solve them with EVA's own BEM, or \
                export a forward solution (-fwd.fif) and import that lead field instead.
                """
        case .solutionShapeMismatch(let expected, let found):
            return "The solution matrix is \(found.map(String.init).joined(separator: "×")) but these surfaces have \(expected) vertices; the solution and the geometry are not from the same model."
        case .unsupportedApproximation(let method):
            return "Unsupported BEM approximation method \(method); EVA reads linear collocation (2), which is what MNE writes."
        case .solutionTooLarge(let bytes, let limit):
            return String(format: "The BEM solution needs %.1f GB of memory, over the %.1f GB limit. Import a coarser head model, or raise the limit if this machine can take it.", Double(bytes) / 1e9, Double(limit) / 1e9)
        case .malformed(let what):
            return "The head model file is malformed: \(what)"
        }
    }
}
