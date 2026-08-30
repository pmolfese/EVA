//
//  SourceSimulatorControllerTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-2/SIM-3 Stage 1 — the Source Simulator's live forward field. These exercise
//  the in-process path (no CLI): the controller building a lead field from placed
//  dipoles and turning it into scalp potentials, which is what makes dragging a
//  dipole update the topomap in real time.
//

import Foundation
import Testing
@testable import EVA

@MainActor
@Suite("Source Simulator")
struct SourceSimulatorControllerTests {

    @Test("produces a scalp field for the default dipole")
    func producesField() {
        let controller = SourceSimulatorController()
        let potentials = controller.scalpPotentials()
        #expect(potentials != nil)
        #expect(potentials?.count == controller.montage.electrodes.count)
        // A real dipole makes a spatially varying field, not a flat one.
        if let potentials {
            let spread = (potentials.max() ?? 0) - (potentials.min() ?? 0)
            #expect(spread > 0.1, "expected a non-trivial topography, got spread \(spread)")
        }
    }

    @Test("average reference zero-sums across channels")
    func averageReferenceZeroSums() throws {
        let controller = SourceSimulatorController()
        controller.reference = .average
        let potentials = try #require(controller.scalpPotentials())
        let mean = potentials.reduce(0, +) / Double(potentials.count)
        let peak = potentials.map(abs).max() ?? 1
        #expect(abs(mean) < peak * 1e-6, "average reference should make the channel mean ~0")
    }

    @Test("moving a dipole changes the field")
    func movingChangesField() {
        let controller = SourceSimulatorController()
        let before = try? #require(controller.scalpPotentials())
        controller.sources[0].positionMeters = controller.clampInsideBrain(SIMD3(0.04, -0.02, 0.0))
        let after = try? #require(controller.scalpPotentials())
        #expect(before != after, "the topography should differ after the source moves")
    }

    @Test("keeps sources inside the brain shell")
    func clampsInsideBrain() {
        let controller = SourceSimulatorController()
        let clamped = controller.clampInsideBrain(SIMD3(1, 1, 1)) // far outside
        let radius = (clamped.x * clamped.x + clamped.y * clamped.y + clamped.z * clamped.z).squareRoot()
        #expect(radius <= controller.brainRadiusMeters)
        // And the solver accepts the clamped position.
        controller.sources[0].positionMeters = clamped
        #expect(controller.scalpPotentials() != nil)
    }

    @Test("high-density montages solve", arguments: [19, 32, 64, 128, 256])
    func highDensitySolves(count: Int) {
        let controller = SourceSimulatorController()
        controller.channelCount = count
        let potentials = controller.scalpPotentials()
        #expect(potentials?.count == count)
        #expect(controller.electrodeDisc().count == count)
    }

    @Test("option-drag rotation aims the arrow while staying a unit vector")
    func rotationAimsInPlane() {
        // Axial plane rotates about z: aim toward +x should give orientation ≈ +x,
        // and the z (out-of-plane) component is preserved.
        let start = SIMD3<Double>(0, 0, 0.6) // 0.6 tilt out of the axial plane
        let rotated = HeadProjectionView.Plane.axial.rotatedOrientation(towards: 1, 0, from: start)
        let norm = (rotated.x * rotated.x + rotated.y * rotated.y + rotated.z * rotated.z).squareRoot()
        #expect(abs(norm - 1) < 1e-9, "orientation must stay a unit vector")
        #expect(abs(rotated.z - 0.6) < 1e-9, "out-of-plane tilt is preserved")
        #expect(rotated.x > 0 && abs(rotated.y) < 1e-9, "in-plane heading points toward +x")
        // In-plane magnitude fills the rest of the unit length.
        #expect(abs(rotated.x - (1 - 0.36).squareRoot()) < 1e-9)
    }

    @Test("rotating with a zero direction leaves orientation unchanged")
    func rotationNoOpOnZero() {
        let start = SIMD3<Double>(0, 0.6, 0.8)
        let rotated = HeadProjectionView.Plane.coronal.rotatedOrientation(towards: 0, 0, from: start)
        #expect(rotated == start)
    }

    @Test("a time course makes the field vary over the epoch")
    func timeCourseVariesField() {
        let controller = SourceSimulatorController()
        controller.sources[0].activations = [
            .init(startSeconds: 0, lengthSeconds: controller.durationSeconds,
                  amplitudeNanoampereMeters: 20, waveform: .sine(frequencyHz: 5))
        ]
        // Quarter period of a 5 Hz sine (0.05 s) swings from 0 to peak.
        let atZero = controller.fieldPotentials(atSample: 0)
        let atPeak = controller.fieldPotentials(atSample: Int(0.05 * controller.sampleRate))
        #expect(atZero != atPeak)
        // At t=0 a sine is 0, so the field should be ~flat there.
        if let atZero { #expect((atZero.map(abs).max() ?? 0) < 1e-6) }
    }

    @Test("erp bump peaks at the window centre")
    func erpPeaks() {
        let controller = SourceSimulatorController()
        controller.sources[0].activations = [
            .init(startSeconds: 0.2, lengthSeconds: 0.2,
                  amplitudeNanoampereMeters: 20, waveform: .erp(widthSeconds: 0.02))
        ]
        let rate = controller.sampleRate
        let atCentre = controller.fieldPotentials(atSample: Int(0.30 * rate)) // window centre
        let early = controller.fieldPotentials(atSample: Int(0.05 * rate))    // before the window
        let peakC = atCentre?.map(abs).max() ?? 0
        let peakE = early?.map(abs).max() ?? 0
        #expect(peakC > peakE, "the transient should be strongest at the window centre")
    }

    @Test("activations fire only inside their window")
    func activationsAreWindowed() {
        let controller = SourceSimulatorController()
        controller.durationSeconds = 2
        controller.sources[0].activations = [
            .init(startSeconds: 0.5, lengthSeconds: 0.5,
                  amplitudeNanoampereMeters: 30, waveform: .hold)
        ]
        let before = controller.fieldPotentials(atSample: Int(0.1 * controller.sampleRate))
        #expect((before?.map(abs).max() ?? 1) < 1e-9, "silent before the window")
        let inside = controller.fieldPotentials(atSample: Int(0.7 * controller.sampleRate))
        #expect((inside?.map(abs).max() ?? 0) > 1e-3, "active inside the window")
    }

    @Test("generate scalp EEG writes a readable MFF")
    func generatesReadableRecording() throws {
        let controller = SourceSimulatorController()
        controller.channelCount = 32
        controller.durationSeconds = 2
        controller.sampleRate = 256
        controller.sources[0].activations = [
            .init(startSeconds: 0, lengthSeconds: 2,
                  amplitudeNanoampereMeters: 20, waveform: .sine(frequencyHz: 8))
        ]

        let url = try controller.writeRecording()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(FileManager.default.fileExists(atPath: url.path))
        let signal = try MFFReader().loadSignal(from: url)
        #expect(signal.numberOfChannels == 32)
        #expect(signal.data.first?.count == controller.sampleCount)
        // The layout sidecars were written, so a topomap-capable layout loads.
        #expect(SensorLayout.load(fromPackageContaining: signal.signalURL) != nil)
    }

    @Test("electrode disc has one point per channel within the unit range")
    func electrodeDisc() {
        let controller = SourceSimulatorController()
        controller.channelCount = 32
        let disc = controller.electrodeDisc()
        #expect(disc.count == 32)
        // Azimuthal layout: 10-20 electrodes sit at or inside the equator (r≈1),
        // with a little headroom for below-equator sites.
        for entry in disc {
            let r = (entry.point.x * entry.point.x + entry.point.y * entry.point.y).squareRoot()
            #expect(r < 1.6)
        }
    }
}
