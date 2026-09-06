//
//  BEMImportTests.swift
//  EVATests
//
//  Importing a finished BEM head model (EVA_RESOLVE2.md R3.1/R3.2): geometry
//  from any file MNE or OpenMEEG writes, the quality gates that stand between an
//  imported model and a lead field, and the solution matrix itself.
//
//  Fixtures come from Tools/forward-compare/make_forward_fixtures.py.
//

import Foundation
import Testing
import simd
@testable import EVA

@Suite("BEM import")
struct BEMImportTests {
    static func url(_ name: String) -> URL { Fixtures.url("Resolve/Forward/\(name)") }

    /// Files written here are left in place for
    /// `Tools/forward-compare/check_swift_openmeeg.py` to load with OpenMEEG
    /// itself — the same arrangement `FIFInteropTests` has with MNE.
    static let validationDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EVAResolveValidation/openmeeg")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - R3.1 geometry

    @Test("geometry reads from every file MNE writes it into",
          arguments: ["fsaverage-ico2-bem.fif", "fsaverage-ico2-bem-sol-mne.fif", "fsaverage-ico2-bem-sol-openmeeg.fif"])
    func geometryFromAnyFile(file: String) throws {
        let geometry = try BEMGeometry.readFIF(from: Self.url(file), subject: "fsaverage")
        // Stored inner → outer, whatever order the file used (MNE writes outer first).
        #expect(geometry.shells.map(\.kind) == [.brain, .skull, .head])
        #expect(geometry.frame == .mri)
        #expect(geometry.vertexCount == 486)
        #expect(geometry.triangleCount == 960)
        #expect(geometry.provenance.subject == "fsaverage")
        let sigmas = geometry.conductivities
        #expect(abs(sigmas[0] - 0.3) < 1e-6 && abs(sigmas[1] - 0.006) < 1e-6 && abs(sigmas[2] - 0.3) < 1e-6)
    }

    @Test("provenance names the solver, and says when there is no solution")
    func provenance() throws {
        let geometryOnly = try BEMGeometry.readFIF(from: Self.url("fsaverage-ico2-bem.fif"))
        #expect(geometryOnly.provenance.solver == .unknown)
        #expect(geometryOnly.provenance.note?.contains("Geometry only") == true)

        let mne = try BEMGeometry.readFIF(from: Self.url("fsaverage-ico2-bem-sol-mne.fif"))
        #expect(mne.provenance.solver == .mne)
        #expect(mne.provenance.approximation == 2)          // linear collocation
        #expect(mne.provenance.summary.contains("linear collocation"))

        let openmeeg = try BEMGeometry.readFIF(from: Self.url("fsaverage-ico2-bem-sol-openmeeg.fif"))
        #expect(openmeeg.provenance.solver == .openmeeg)
    }

    @Test("a real head model passes every quality gate", arguments: ["fsaverage-ico2", "sphere-ico2"])
    func qualityPasses(name: String) throws {
        let geometry = try BEMGeometry.readFIF(from: Self.url("\(name)-bem.fif"))
        let report = geometry.quality()
        #expect(report.isUsable, "failures: \(report.failures.map { "\($0.name): \($0.detail)" }.joined(separator: "; "))")
        // fsaverage at ico2 legitimately warns: downsampling to 320 triangles per
        // shell brings the outer skull within 1.5 mm of the scalp. Warnings are
        // information, not a veto — but the model must still be usable.
        if name == "sphere-ico2" {
            #expect(report.warnings.isEmpty, "warnings: \(report.warnings.map(\.detail).joined(separator: "; "))")
        } else {
            let names = report.warnings.map(\.name)
            #expect(names == ["outer skull inside scalp"], "unexpected warnings: \(names)")
        }
        // The gates that matter are actually present, not just absent failures.
        // `contains(where:)` is rethrows, which #expect cannot wrap; hoist the Bools.
        let names = report.checks.map(\.name)
        let hasClosed = names.contains(where: { $0.contains("closed") })
        let hasNormals = names.contains(where: { $0.contains("outward normals") })
        let hasIntersection = names.contains(where: { $0.contains("self-intersection") })
        #expect(hasClosed)
        #expect(hasNormals)
        #expect(hasIntersection)
        #expect(names.contains("inner skull inside outer skull"))
        #expect(names.contains("outer skull inside scalp"))
    }

    @Test("non-nested shells fail, and the failure names both surfaces")
    func qualityCatchesNesting() throws {
        let geometry = try BEMGeometry.readFIF(from: Self.url("sphere-ico2-bem.fif"))
        // Inflate the inner skull past the outer one.
        var broken = geometry
        broken.shells[0].mesh = broken.shells[0].mesh.scaled(1.5, about: .zero)
        let report = broken.quality(checkSelfIntersection: false)
        #expect(!report.isUsable)
        let failure = try #require(report.failures.first(where: { $0.name == "inner skull inside outer skull" }))
        #expect(failure.detail.contains("outside"))
    }

    @Test("inverted winding and open surfaces fail")
    func qualityCatchesTopology() throws {
        let geometry = try BEMGeometry.readFIF(from: Self.url("sphere-ico2-bem.fif"))

        var flipped = geometry
        flipped.shells[2].mesh.triangles = flipped.shells[2].mesh.triangles.map { SIMD3($0.x, $0.z, $0.y) }
        let flippedFailed = flipped.quality(checkSelfIntersection: false).failures
            .contains(where: { $0.name == "scalp: outward normals" })
        #expect(flippedFailed)

        var open = geometry
        open.shells[2].mesh.triangles.removeLast(4)
        let openFailed = open.quality(checkSelfIntersection: false).failures
            .contains(where: { $0.name.contains("scalp") && $0.name.contains("closed") })
        #expect(openFailed)
    }

    @Test("units in millimetres are caught as an implausible size")
    func qualityCatchesUnits() throws {
        let geometry = try BEMGeometry.readFIF(from: Self.url("sphere-ico2-bem.fif"))
        var millimetres = geometry
        for i in millimetres.shells.indices {
            millimetres.shells[i].mesh = millimetres.shells[i].mesh.scaled(1000, about: .zero)
        }
        let warned = millimetres.quality(checkSelfIntersection: false).warnings
            .contains(where: { $0.name.contains("plausible size") && $0.detail.contains("metres") })
        #expect(warned)
    }

    @Test("self-intersection is detected when a shell folds through itself")
    func selfIntersection() throws {
        let clean = TriangleMesh.icosphere(subdivisions: 2, radius: 0.085)
        #expect(clean.selfIntersectingTriangles().isEmpty)

        // Push one vertex out through the far side, so its triangles have to cross
        // the shell. (Moving it to *inside* the ball would not: a triangle with all
        // three corners in a convex body stays inside it.)
        var folded = clean
        folded.vertices[0] = -folded.vertices[0] * 1.5
        let folds = folded.selfIntersectingTriangles()
        #expect(!folds.isEmpty)
    }

    @Test("two triangles: crossing, coplanar-apart, and merely touching")
    func trianglePairs() {
        let a0 = SIMD3<Double>(0, 0, 0), a1 = SIMD3<Double>(1, 0, 0), a2 = SIMD3<Double>(0, 1, 0)
        // Crosses the first triangle's interior.
        #expect(TriangleMesh.trianglesIntersect(a0, a1, a2,
                                                SIMD3(0.25, 0.25, -1), SIMD3(0.25, 0.25, 1), SIMD3(0.9, 0.25, 0)))
        // Same plane, well away.
        #expect(!TriangleMesh.trianglesIntersect(a0, a1, a2,
                                                 SIMD3(5, 5, 0), SIMD3(6, 5, 0), SIMD3(5, 6, 0)))
        // Parallel plane just above.
        #expect(!TriangleMesh.trianglesIntersect(a0, a1, a2,
                                                 SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(0, 1, 1)))
    }

    // MARK: - R3.1 OpenMEEG native geometry

    @Test("OpenMEEG .geom/.cond/.tri round trip")
    func openMEEGRoundTrip() throws {
        let original = try BEMGeometry.readFIF(from: Self.url("sphere-ico2-bem.fif"))
        let directory = Self.validationDirectory
        let geomURL = try OpenMEEGGeometry.write(original, to: directory, name: "sphere")
        // The sandboxed test host has its own temporary directory, so say where the
        // files landed: Tools/forward-compare/check_swift_openmeeg.py takes that path
        // and loads them with OpenMEEG itself.
        print("OpenMEEG model written to \(directory.path)")
        let text = try String(contentsOf: geomURL, encoding: .utf8)
        #expect(text.contains("Interfaces 3"))
        #expect(text.contains("Domain Air:"))

        let reimported = try OpenMEEGGeometry.readGeometry(at: geomURL)
        #expect(reimported.shells.map(\.kind) == [.brain, .skull, .head])
        #expect(reimported.vertexCount == original.vertexCount)
        #expect(reimported.provenance.format == "OpenMEEG .geom")
        for (a, b) in zip(reimported.shells, original.shells) {
            #expect(abs(a.sigma - b.sigma) < 1e-6, "\(a.kind.displayName) sigma")
            // Written in millimetres, read back in metres.
            for (v, w) in zip(a.mesh.vertices, b.mesh.vertices) {
                #expect(simd_length(v - w) < 1e-6, "\(a.kind.displayName) vertex")
            }
            // Written in OpenMEEG's reversed winding, normalized back to EVA's
            // outward convention on the way in.
            #expect(a.mesh.triangles == b.mesh.triangles, "\(a.kind.displayName) winding")
            #expect(a.mesh.areaAndVolume.volume > 0, "\(a.kind.displayName) outward")
        }
        #expect(reimported.quality(checkSelfIntersection: false).isUsable)
    }

    @Test("OFF and BND meshes read the same geometry as .tri")
    func meshFormats() throws {
        let mesh = TriangleMesh.icosphere(subdivisions: 1, radius: 0.085)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EVAOpenMEEGMesh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let triURL = directory.appendingPathComponent("shell.tri")
        try OpenMEEGGeometry.writeTRI(mesh, to: triURL, scale: 1000)

        var off = "OFF\n\(mesh.vertices.count) \(mesh.triangles.count) 0\n"
        for v in mesh.vertices { off += "\(v.x * 1000) \(v.y * 1000) \(v.z * 1000)\n" }
        for t in mesh.triangles { off += "3 \(t.x) \(t.y) \(t.z)\n" }
        let offURL = directory.appendingPathComponent("shell.off")
        try off.write(to: offURL, atomically: true, encoding: .utf8)

        var bnd = "# ASA BND\nType= Unknown\nNumberPositions= \(mesh.vertices.count)\nPositions\n"
        for v in mesh.vertices { bnd += "\(v.x * 1000) \(v.y * 1000) \(v.z * 1000)\n" }
        bnd += "NumberPolygons= \(mesh.triangles.count)\nPolygons\n"
        for t in mesh.triangles { bnd += "\(t.x + 1) \(t.y + 1) \(t.z + 1)\n" }
        let bndURL = directory.appendingPathComponent("shell.bnd")
        try bnd.write(to: bndURL, atomically: true, encoding: .utf8)

        for url in [triURL, offURL, bndURL] {
            let read = try OpenMEEGGeometry.readMesh(at: url)
            #expect(read.vertices.count == mesh.vertices.count, "\(url.lastPathComponent)")
            #expect(read.triangles == mesh.triangles, "\(url.lastPathComponent)")
            for (v, w) in zip(read.vertices, mesh.vertices) {
                #expect(simd_length(v - w) < 1e-6, "\(url.lastPathComponent)")
            }
        }
    }

    @Test("FIF matrix dimensions come back slowest-varying first")
    func matrixDimensions() throws {
        // A non-square matrix, because a square one cannot tell the two orders
        // apart — which is exactly how a transposed reading survived unnoticed.
        var writer = FIFWriter()
        writer.startFile()
        writer.writeFloatMatrix(FIF.bemPotSolution, rows: 3, cols: 5,
                                values: (0..<15).map(Float.init))
        writer.endFile()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eva-fif-matrix-\(UUID().uuidString).fif")
        defer { try? FileManager.default.removeItem(at: url) }
        try writer.save(to: url)

        let tag = try #require(try FIFReader(url: url).first(kind: FIF.bemPotSolution))
        #expect(try tag.matrixDimensions() == [3, 5])
        let matrix = try tag.matrix()
        #expect(matrix.rows == 3 && matrix.cols == 5)
        #expect(try tag.floatValues() == (0..<15).map(Float.init))
    }

    // MARK: - R3.2 solution

    @Test("MNE solution imports with the shape and multipliers MNE derives")
    func mneSolution() throws {
        let solution = try BEMSolution.readFIF(from: Self.url("fsaverage-ico2-bem-sol-mne.fif"))
        #expect(solution.size == 486)
        #expect(solution.solution.count == 486 * 486)
        #expect(solution.approximation == 2)
        #expect(solution.geometry.provenance.solver == .mne)
        let finite = solution.solution.allSatisfy(\.isFinite)     // allSatisfy is rethrows
        #expect(finite)

        // Blocks are outer first, matching the file's surface order.
        #expect(solution.blocks == [0..<162, 162..<324, 324..<486])
        #expect(solution.blockIndex(ofRow: 0) == 0 && solution.blockIndex(ofRow: 485) == 2)

        // _add_gamma_multipliers with sigma = [0, scalp, skull, brain]:
        // source = 2 / (σᵢ + σᵢ₋₁), field = σᵢ − σᵢ₋₁.
        let (source, field) = BEMSolution.multipliers(sigmasOuterFirst: [0.3, 0.006, 0.3])
        #expect(abs(source[0] - 2.0 / 0.3) < 1e-12)
        #expect(abs(source[1] - 2.0 / 0.306) < 1e-12)
        #expect(abs(source[2] - 2.0 / 0.306) < 1e-12)
        #expect(abs(field[0] - 0.3) < 1e-12)
        #expect(abs(field[1] + 0.294) < 1e-12)
        #expect(abs(field[2] - 0.294) < 1e-12)
        #expect(solution.sourceMultipliers.count == 3 && solution.fieldMultipliers.count == 3)
    }

    @Test("an OpenMEEG solution is declined by name, with the routes that work")
    func openMEEGSolutionDeclined() throws {
        // The geometry still imports — that is the point of the message.
        let geometry = try BEMGeometry.readFIF(from: Self.url("fsaverage-ico2-bem-sol-openmeeg.fif"))
        #expect(geometry.quality(checkSelfIntersection: false).isUsable)

        var thrown: Error?
        do { _ = try BEMSolution.readFIF(from: Self.url("fsaverage-ico2-bem-sol-openmeeg.fif")) }
        catch { thrown = error }
        let error = try #require(thrown as? BEMImportError)
        guard case .unsupportedSolver(let solver, let vertices, let entries) = error else {
            Issue.record("expected .unsupportedSolver, got \(error)"); return
        }
        #expect(solver == "OpenMEEG")
        #expect(vertices == 486)
        // nsol = vertices (486) + normal currents on the two inner interfaces
        // (2 × 320), stored packed as the n(n+1)/2 upper triangle.
        let nsol = 486 + 640
        #expect(entries == nsol * (nsol + 1) / 2)
        let message = try #require(error.errorDescription)
        #expect(message.contains("solver='mne'"))
        #expect(message.contains("-fwd.fif"))
        #expect(message.contains("geometry imported fine"))
    }

    @Test("a geometry-only file is not mistaken for a solution")
    func geometryOnlyRejected() throws {
        var thrown: Error?
        do { _ = try BEMSolution.readFIF(from: Self.url("fsaverage-ico2-bem.fif")) }
        catch { thrown = error }
        let error = try #require(thrown as? BEMImportError)
        #expect(error.errorDescription?.contains("geometry-only") == true)
    }

    @Test("an oversized solution is refused before it is read")
    func sizeLimit() throws {
        var thrown: Error?
        do { _ = try BEMSolution.readFIF(from: Self.url("fsaverage-ico2-bem-sol-mne.fif"), sizeLimitBytes: 1000) }
        catch { thrown = error }
        let error = try #require(thrown as? BEMImportError)
        guard case .solutionTooLarge = error else { Issue.record("expected .solutionTooLarge, got \(error)"); return }
    }
}
