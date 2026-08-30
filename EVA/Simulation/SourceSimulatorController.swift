//
//  SourceSimulatorController.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-2/SIM-3 — the Source Simulator's state and its live forward field.
//
//  Unlike the Simulator Studio (which shells out to the bundled CLI to write
//  files), this window calls the in-module forward solver directly, in-process:
//  `SphericalForwardModel.leadField(...)` returns a µV/(nA·m) operator, and the
//  scalp field is that operator times each source's moment series. Dragging a
//  dipole recomputes the field with no file round-trip — the interactive payoff
//  SIM-0 unlocked by moving the forward core into the app module.
//
//  Stage 3a — time is authored as a list of *activations* per dipole rather than a
//  single course: a dipole is silent except during its activations, and can have
//  any number of them at any times. "New time, new and/or old dipoles" is then
//  just later activations on new or existing dipoles. A dipole's moment series is
//  the sum of its activations' waveforms placed at their start times.
//
//  Frame: +x right, +y anterior (nose), +z vertex — the same convention `Montage`
//  and `SimulatedSource` use.
//

import Foundation
import Observation

@MainActor
@Observable
final class SourceSimulatorController {

    /// A dipole the user places and drags. Its strength over time is the sum of
    /// its `activations`.
    struct Source: Identifiable {
        let id = UUID()
        var name: String
        var positionMeters: SIMD3<Double>
        var orientationUnit: SIMD3<Double>
        var activations: [Activation] = []

        var orientationNormalized: SIMD3<Double> {
            let n = (orientationUnit.x * orientationUnit.x
                + orientationUnit.y * orientationUnit.y
                + orientationUnit.z * orientationUnit.z).squareRoot()
            return n > 1e-9 ? orientationUnit / n : SIMD3(0, 0, 1)
        }
    }

    /// One timed firing of a dipole: a windowed waveform at a given start, length,
    /// and (variable) amplitude. Overlapping activations on one dipole sum.
    struct Activation: Identifiable, Equatable {
        let id = UUID()
        var startSeconds: Double
        var lengthSeconds: Double
        var amplitudeNanoampereMeters: Double
        var waveform: Waveform

        /// Unit-scale value at local time `tau` within `[0, lengthSeconds]`; noise
        /// is filled from a sampled series instead.
        func value(atLocal tau: Double) -> Double {
            switch waveform {
            case .hold:
                return 1
            case .sine(let frequencyHz):
                return sin(2 * .pi * frequencyHz * tau)
            case .erp(let widthSeconds):
                let w = max(widthSeconds, 1e-3)
                let z = (tau - lengthSeconds / 2) / w
                return exp(-z * z)
            case .noise:
                return 0
            }
        }
    }

    /// The shape of an activation's window.
    enum Waveform: Equatable, Hashable {
        /// A steady level across the window (rectangular).
        case hold
        case sine(frequencyHz: Double)
        /// A Gaussian bump centred in the window (an ERP-like transient).
        case erp(widthSeconds: Double)
        /// Seeded 1/f-ish coloured noise, peak-normalized, across the window.
        case noise(seed: UInt64)

        var label: String {
            switch self {
            case .hold: return "Hold"
            case .sine: return "Sine"
            case .erp: return "ERP bump"
            case .noise: return "Noise"
            }
        }
    }

    var headModel: SphericalHeadModel = .classicThreeShell
    var channelCount: Int = 32
    var reference: EEGReference = .average

    /// Glass-brain surface layers in the projections, toggled independently.
    var showWireframe = true
    var showOutlineCircle = true
    /// Spherical-harmonic terms for the live solve. Fewer than the generation
    /// default (100) keeps dragging responsive while staying visually exact.
    var harmonicTerms: Int = 60

    var sources: [Source] = [
        Source(
            name: "Source 1",
            positionMeters: SIMD3(0, 0.03, 0.04),
            orientationUnit: SIMD3(0, 0.6, 0.8),
            activations: [Activation(startSeconds: 0, lengthSeconds: 4,
                                     amplitudeNanoampereMeters: 20, waveform: .hold)]
        )
    ]
    var selectedID: Source.ID?
    var selectedActivationID: Activation.ID?

    // MARK: Timeline

    var durationSeconds: Double = 4
    var sampleRate: Double = 256
    /// Scrubber position, seconds. The field is shown at this instant.
    var currentTime: Double = 0
    var isPlaying = false

    var sampleCount: Int { max(1, Int((durationSeconds * sampleRate).rounded())) }
    var currentSample: Int { min(max(Int((currentTime * sampleRate).rounded()), 0), sampleCount - 1) }

    @ObservationIgnored private var cachedMatrix: [[Double]]?
    @ObservationIgnored private var cachedGeometrySignature: [Double] = []
    @ObservationIgnored private var cachedSeries: [[Double]]?
    @ObservationIgnored private var cachedSeriesSignature: [Double] = []

    func advancePlayback(by seconds: Double) {
        guard isPlaying, durationSeconds > 0 else { return }
        var t = currentTime + seconds
        if t >= durationSeconds { t = t.truncatingRemainder(dividingBy: durationSeconds) }
        currentTime = t
    }

    // MARK: Geometry

    var brainRadiusMeters: Double { headModel.brainRadiusMeters }
    var scalpRadiusMeters: Double { headModel.scalpRadiusMeters }

    /// Keeps a source safely inside the innermost shell (the solver requires it).
    func clampInsideBrain(_ position: SIMD3<Double>) -> SIMD3<Double> {
        let limit = brainRadiusMeters * 0.97
        let r = (position.x * position.x + position.y * position.y + position.z * position.z).squareRoot()
        guard r > limit, r > 0 else { return position }
        return position * (limit / r)
    }

    // MARK: Source & activation management

    func addSource() {
        let index = sources.count + 1
        let source = Source(
            name: "Source \(index)",
            positionMeters: clampInsideBrain(SIMD3(0.02, 0.0, 0.03)),
            orientationUnit: SIMD3(0, 0, 1),
            activations: [Activation(startSeconds: 0, lengthSeconds: durationSeconds,
                                     amplitudeNanoampereMeters: 20, waveform: .hold)]
        )
        sources.append(source)
        selectedID = source.id
        selectedActivationID = source.activations.first?.id
    }

    func removeSelected() {
        guard let id = selectedID else { return }
        sources.removeAll { $0.id == id }
        selectedID = sources.first?.id
        selectedActivationID = nil
    }

    /// Adds an activation to a source (defaults to the selected one) starting at a
    /// time (defaults to the playhead), and selects it.
    func addActivation(toSourceID sourceID: Source.ID? = nil, atSeconds time: Double? = nil) {
        let targetID = sourceID ?? selectedID
        guard let targetID, let index = sources.firstIndex(where: { $0.id == targetID }) else { return }
        let start = max(0, min(time ?? currentTime, durationSeconds))
        let length = min(0.5, max(0.05, durationSeconds - start))
        let activation = Activation(
            startSeconds: start, lengthSeconds: length,
            amplitudeNanoampereMeters: 20, waveform: .erp(widthSeconds: 0.05)
        )
        sources[index].activations.append(activation)
        selectedID = targetID
        selectedActivationID = activation.id
    }

    func removeSelectedActivation() {
        guard let activationID = selectedActivationID else { return }
        for index in sources.indices {
            sources[index].activations.removeAll { $0.id == activationID }
        }
        selectedActivationID = nil
    }

    /// Locates an activation by id: (source index, activation index).
    func locate(_ activationID: Activation.ID) -> (source: Int, activation: Int)? {
        for (s, source) in sources.enumerated() {
            if let a = source.activations.firstIndex(where: { $0.id == activationID }) {
                return (s, a)
            }
        }
        return nil
    }

    // MARK: - Live forward field

    /// The electrode montage the field is sampled on.
    var montage: Montage { Montage.standard(count: channelCount) }

    /// The lead-field operator (channels × sources, µV/(nA·m)), cached and rebuilt
    /// only when the geometry changes — so during playback or an amplitude change
    /// the field is a cheap matrix-vector product rather than a fresh solve.
    func leadMatrix() -> [[Double]]? {
        guard !sources.isEmpty else { return [] }
        let signature = geometrySignature()
        if let cached = cachedMatrix, signature == cachedGeometrySignature { return cached }

        let sims = sources.map { source -> SimulatedSource in
            let orientation = source.orientationNormalized
            return SimulatedSource(
                id: source.id.uuidString,
                positionMeters: Vector3D(x: source.positionMeters.x, y: source.positionMeters.y, z: source.positionMeters.z),
                orientation: Vector3D(x: orientation.x, y: orientation.y, z: orientation.z),
                bandName: "alpha",
                seed: 0,
                rmsMomentNanoampereMeters: 1
            )
        }
        guard let leadField = try? SphericalForwardModel.leadField(
            head: headModel, montage: montage, sources: sims,
            reference: reference, terms: harmonicTerms
        ) else { return nil }
        let matrix = leadField.matrixMicrovoltsPerNanoampereMeter
        cachedMatrix = matrix
        cachedGeometrySignature = signature
        return matrix
    }

    /// Per-source moment series over the epoch (sources × samples): each source is
    /// the sum of its activations' windowed waveforms. Cached until an activation /
    /// duration / rate change.
    func sourceSeries() -> [[Double]] {
        let signature = seriesSignature()
        if let cached = cachedSeries, signature == cachedSeriesSignature { return cached }
        let n = sampleCount
        let series = sources.map { source -> [Double] in
            var out = [Double](repeating: 0, count: n)
            for activation in source.activations {
                let startK = max(0, Int((activation.startSeconds * sampleRate).rounded()))
                let endK = min(n, Int(((activation.startSeconds + activation.lengthSeconds) * sampleRate).rounded()))
                guard endK > startK else { continue }
                if case .noise(let seed) = activation.waveform {
                    let noise = Self.colouredNoise(count: endK - startK, seed: seed)
                    for (i, k) in (startK..<endK).enumerated() {
                        out[k] += activation.amplitudeNanoampereMeters * noise[i]
                    }
                } else {
                    for k in startK..<endK {
                        let tau = Double(k) / sampleRate - activation.startSeconds
                        out[k] += activation.amplitudeNanoampereMeters * activation.value(atLocal: tau)
                    }
                }
            }
            return out
        }
        cachedSeries = series
        cachedSeriesSignature = signature
        return series
    }

    /// Scalp potentials (µV) at a given sample, or `nil` if the solve failed.
    func fieldPotentials(atSample sample: Int) -> [Double]? {
        guard let matrix = leadMatrix() else { return nil }
        guard !matrix.isEmpty else { return Array(repeating: 0, count: montage.electrodes.count) }
        let series = sourceSeries()
        let count = series.first?.count ?? 0
        guard count > 0 else { return Array(repeating: 0, count: matrix.count) }
        let index = min(max(sample, 0), count - 1)
        var potentials = [Double](repeating: 0, count: matrix.count)
        for channel in matrix.indices {
            var sum = 0.0
            for source in series.indices where source < matrix[channel].count {
                sum += matrix[channel][source] * series[source][index]
            }
            potentials[channel] = sum
        }
        return potentials
    }

    /// The field at the scrubber position — what the topomap shows.
    func scalpPotentials() -> [Double]? { fieldPotentials(atSample: currentSample) }

    // MARK: Signatures & noise

    private func geometrySignature() -> [Double] {
        var signature: [Double] = [Double(channelCount), Double(harmonicTerms),
                                   reference == .average ? 0 : 1,
                                   headModel == .classicFourShell ? 1 : 0]
        for source in sources {
            let o = source.orientationNormalized
            signature += [source.positionMeters.x, source.positionMeters.y, source.positionMeters.z, o.x, o.y, o.z]
        }
        return signature
    }

    private func seriesSignature() -> [Double] {
        var signature: [Double] = [durationSeconds, sampleRate]
        for source in sources {
            signature.append(Double(source.activations.count))
            for activation in source.activations {
                signature += [activation.startSeconds, activation.lengthSeconds, activation.amplitudeNanoampereMeters]
                signature += Self.encode(activation.waveform)
            }
        }
        return signature
    }

    private static func encode(_ waveform: Waveform) -> [Double] {
        switch waveform {
        case .hold: return [0]
        case .sine(let f): return [1, f]
        case .erp(let w): return [2, w]
        case .noise(let s): return [3, Double(s)]
        }
    }

    /// Seeded 1/f-ish coloured noise (AR(1) low-pass over white noise), peak-
    /// normalized to ~1.
    private static func colouredNoise(count: Int, seed: UInt64) -> [Double] {
        guard count > 0 else { return [] }
        var state = seed &+ 0x9E3779B97F4A7C15
        func next() -> Double {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z = z ^ (z >> 31)
            return Double(z >> 11) * (1.0 / 9007199254740992.0) * 2 - 1
        }
        var series = [Double](repeating: 0, count: count)
        var previous = 0.0
        let alpha = 0.9
        for n in 0..<count {
            previous = alpha * previous + (1 - alpha) * next()
            series[n] = previous
        }
        let peak = series.map(abs).max() ?? 1
        return peak > 1e-12 ? series.map { $0 / peak } : series
    }

    /// Electrode positions in an azimuthal-equidistant unit disc (Cz at centre,
    /// nose up), for both the scalp topomap and electrode dots. x right, y up.
    func electrodeDisc() -> [(name: String, point: CGPoint)] {
        montage.electrodes.map { electrode in
            let r = electrode.thetaDegrees / 90.0
            let phi = electrode.phiDegrees * .pi / 180
            return (electrode.name, CGPoint(x: r * sin(phi), y: r * cos(phi)))
        }
    }

    // MARK: - Generate scalp EEG (in-process)

    enum GenerateError: LocalizedError {
        case solverFailed
        var errorDescription: String? {
            "Could not solve the forward model — check that every source is inside the brain shell."
        }
    }

    private(set) var isGeneratingRecording = false
    private(set) var generationMessage = ""

    /// Assembles the full channels × samples recording (lead field × source
    /// series) and writes it as an MFF entirely in-process, then opens it. Reuses
    /// the app's own `MFFWriter` + `MontageWriter` — no CLI, no scenario file.
    func generateRecording(open: @escaping (URL) -> Void) {
        guard !isGeneratingRecording else { return }
        isGeneratingRecording = true
        generationMessage = "Generating scalp EEG…"
        Task {
            do {
                let url = try writeRecording()
                isGeneratingRecording = false
                generationMessage = "Opened \(url.lastPathComponent)."
                open(url)
            } catch {
                isGeneratingRecording = false
                generationMessage = error.localizedDescription
            }
        }
    }

    func writeRecording() throws -> URL {
        guard let matrix = leadMatrix(), !matrix.isEmpty else { throw GenerateError.solverFailed }
        let series = sourceSeries()
        let n = sampleCount

        var channels = [[Float]](repeating: [Float](repeating: 0, count: n), count: matrix.count)
        for channel in matrix.indices {
            let row = matrix[channel]
            for sample in 0..<n {
                var sum = 0.0
                for source in series.indices where source < row.count {
                    sum += row[source] * series[source][sample]
                }
                channels[channel][sample] = Float(sum)
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceSimulator", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let packageURL = directory.appendingPathComponent("source_sim.mff")

        let currentMontage = montage
        let signal = MFFSignalData(
            signalURL: packageURL.appendingPathComponent("signal1.bin"),
            signalType: "EEG Source Simulator",
            numberOfChannels: channels.count,
            samplingRate: sampleRate,
            duration: Double(n) / sampleRate,
            recordingStartTime: Date(),
            events: [],
            data: channels,
            channelNames: currentMontage.channelNames
        )
        try MFFWriter.write(
            signal: signal, segments: [], kind: .continuous,
            to: packageURL, preserveSourceFileInfo: false
        )
        try MontageWriter.writeLayoutFiles(montage: currentMontage, to: packageURL)
        return packageURL
    }
}
