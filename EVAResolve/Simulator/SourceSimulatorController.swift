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

    /// The window's top-level mode: author a simulated scene, or fit dipoles to a
    /// real (or handed-over) averaged dataset across conditions.
    enum WindowMode: String, CaseIterable, Identifiable, Sendable {
        case simulate, fit
        var id: String { rawValue }
        var label: String { self == .simulate ? "Simulate" : "Fit" }
    }
    var windowMode: WindowMode = .simulate

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

    // MARK: Noise + artifacts (Stage 3b)

    /// Add background noise to the field the topomap shows and to what Generate
    /// writes. The clean field remains the truth for scoring.
    var noiseEnabled = false
    var noiseModel: SourceSimulatorNoise.Model = .pink
    var noiseTargetSNRdB: Double = 10
    var noiseSeed: UInt64 = 1
    /// Physiological artifacts injected on top of the clean field.
    var artifacts = SourceSimulatorArtifacts.Options()
    /// When true, the topomap/scoring show the contaminated field; the clean
    /// field is still what's scored against.
    var showNoisyField = true

    // MARK: Localization diagnostic (Stage 3c)

    /// Fit equivalent dipoles to the field and report error against the true
    /// sources. A validation diagnostic, not source imaging — see `SingleDipoleFit`.
    var showDipoleFit = false

    /// Whether to fit a single playhead sample or a whole time interval.
    enum FitMode: String, CaseIterable, Identifiable, Sendable {
        /// One topography at the playhead. Can't separate simultaneous sources.
        case instant
        /// A time interval (Scherg/Berg spatiotemporal). Separates sources with
        /// distinct time courses and reports an SVD model-order spectrum.
        case interval
        var id: String { rawValue }
        var label: String { self == .instant ? "Instant" : "Interval" }
    }
    var fitMode: FitMode = .interval
    /// The butterfly interval to fit, in samples. `nil` fits the whole epoch.
    var fitSelection: ClosedRange<Int>?

    /// Whether any contamination (noise or an artifact) is active.
    var hasContamination: Bool { noiseEnabled || artifacts.anyEnabled }

    @ObservationIgnored private var cachedMatrix: [[Double]]?
    @ObservationIgnored private var cachedGeometrySignature: [Double] = []
    @ObservationIgnored private var cachedSeries: [[Double]]?
    @ObservationIgnored private var cachedSeriesSignature: [Double] = []
    @ObservationIgnored private var cachedClean: [[Double]]?
    @ObservationIgnored private var cachedCleanSignature: [Double] = []
    @ObservationIgnored private var cachedContamination: [[Double]]?
    @ObservationIgnored private var cachedContaminationSignature: [Double] = []
    @ObservationIgnored private var cachedArtifactTruth = SourceSimulatorArtifacts.Truth()
    @ObservationIgnored private var cachedLocalization: SingleDipoleFit.Localization?
    @ObservationIgnored private var cachedLocalizationSignature: [Double] = []

    // MARK: - Fit mode (real / handed-over averaged data)

    /// An averaged dataset to fit: one field matrix per condition, plus the
    /// geometry it was recorded on. `truth` is set only when the data came from
    /// the simulator (so the readout can still show mm/deg); real data leaves it
    /// nil and the readout reports GOF / residual / per-condition moment instead.
    struct FitDataset: Sendable {
        struct ConditionData: Sendable, Identifiable {
            var name: String
            /// channels × samples.
            var data: [[Double]]
            var id: String { name }
        }
        struct TruthDipole: Sendable {
            var name: String
            var position: Vector3D
            var orientation: Vector3D
        }
        var label: String
        var conditions: [ConditionData]
        var montage: Montage
        var headModel: SphericalHeadModel
        var reference: EEGReference
        var sampleRate: Double
        /// Sample index of the first column (for absolute-time labels when the
        /// dataset is a slice of a longer epoch). 0 when it starts at t=0.
        var startSample: Int = 0
        var truth: [TruthDipole]?
        var sampleCount: Int { conditions.first?.data.first?.count ?? 0 }
        var channelCount: Int { conditions.first?.data.count ?? 0 }
    }

    var fitDataset: FitDataset?
    /// Interval (samples, relative to the dataset) to fit; nil = whole dataset.
    var fitDatasetSelection: ClosedRange<Int>?
    /// How many dipoles to fit (defaults to the dataset's known source count).
    var fitDipoleCount: Int = 2
    /// One condition's source waveforms + residual PCA, computed after a fit.
    struct ConditionDecomposition: Sendable, Identifiable {
        var name: String
        var decomposition: SingleDipoleFit.SourceDecomposition
        var id: String { name }
    }

    var sharedFitResult: SingleDipoleFit.SharedGeometryResult?
    /// Per-condition source waveforms and residual components for the last fit.
    var sharedFitDecompositions: [ConditionDecomposition] = []
    var isFittingShared = false
    /// 0…1 progress of the running shared fit, and a verbose description of the
    /// phase. The fit is slow (forward solves over candidate grids), so it is
    /// started explicitly from the Fit button and reports what it is doing.
    var fitProgress: Double = 0
    var fitProgressMessage: String = ""
    /// True when the inputs changed (interval, dipole count, dataset, a dragged
    /// dipole) since the last fit, so the Fit button can invite a re-run instead
    /// of the app silently launching a slow solve.
    var fitIsStale = false
    @ObservationIgnored private var sharedFitTask: Task<Void, Never>?
    @ObservationIgnored private var sharedFitGeneration = 0
    /// Positions the user has dragged, used to seed the next shared fit so it
    /// refines from where they placed the dipoles instead of the deflation seed.
    /// Cleared whenever the interval or dipole count changes (a fresh fit).
    @ObservationIgnored private var fitSeedPositions: [Vector3D]?
    @ObservationIgnored private var fitCancellation = CancellationFlag()

    /// A thread-safe cancel flag the (detached) solver polls between chunks.
    final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func reset() { lock.lock(); cancelled = false; lock.unlock() }
    }

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

    /// Three well-separated sources with *distinct* time courses (an ERP bump, a
    /// sine, and a later burst). Distinct time courses make the data full-rank over
    /// time, so the butterfly fans out and the interval fit can actually separate
    /// them — unlike three identical holds, which are rank-1 and unseparable.
    func loadDemoScene() {
        durationSeconds = 1.0
        currentTime = 0
        fitSelection = nil
        sources = [
            Source(
                name: "Source 1",
                positionMeters: clampInsideBrain(SIMD3(0.035, 0.02, 0.04)),
                orientationUnit: SIMD3(0, 0.5, 0.87),
                activations: [Activation(startSeconds: 0.15, lengthSeconds: 0.3,
                                         amplitudeNanoampereMeters: 30, waveform: .erp(widthSeconds: 0.05))]
            ),
            Source(
                name: "Source 2",
                positionMeters: clampInsideBrain(SIMD3(-0.04, -0.02, 0.03)),
                orientationUnit: SIMD3(1, 0, 0),
                activations: [Activation(startSeconds: 0, lengthSeconds: 1.0,
                                         amplitudeNanoampereMeters: 18, waveform: .sine(frequencyHz: 10))]
            ),
            Source(
                name: "Source 3",
                positionMeters: clampInsideBrain(SIMD3(0.0, -0.045, 0.03)),
                orientationUnit: SIMD3(0, 0, 1),
                activations: [Activation(startSeconds: 0.55, lengthSeconds: 0.3,
                                         amplitudeNanoampereMeters: 25, waveform: .hold)]
            ),
        ]
        selectedID = sources.first?.id
        selectedActivationID = sources.first?.activations.first?.id
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

    /// The clean field at the scrubber position (the truth topomap).
    func cleanPotentials() -> [Double]? { fieldPotentials(atSample: currentSample) }

    /// The field the topomap shows — noisy when contamination is on and
    /// `showNoisyField` is set, otherwise the clean field.
    func scalpPotentials() -> [Double]? {
        guard hasContamination, showNoisyField else { return fieldPotentials(atSample: currentSample) }
        return noisyPotentials(atSample: currentSample)
    }

    // MARK: - Clean / noisy matrices (Stage 3b)

    /// The full clean field, `channels × samples` (lead field × source series),
    /// cached until the geometry or the source series changes.
    func cleanMatrix() -> [[Double]] {
        let signature = geometrySignature() + seriesSignature()
        if let cached = cachedClean, signature == cachedCleanSignature { return cached }
        guard let matrix = leadMatrix(), !matrix.isEmpty else { return [] }
        let series = sourceSeries()
        let n = sampleCount
        var channels = [[Double]](repeating: [Double](repeating: 0, count: n), count: matrix.count)
        for channel in matrix.indices {
            let row = matrix[channel]
            for sample in 0..<n {
                var sum = 0.0
                for source in series.indices where source < row.count {
                    sum += row[source] * series[source][sample]
                }
                channels[channel][sample] = sum
            }
        }
        cachedClean = channels
        cachedCleanSignature = signature
        return channels
    }

    /// The contamination (noise + artifacts), `channels × samples`, cached until
    /// the clean field or a noise/artifact setting changes. Also refreshes the
    /// artifact truth used by the sidecar.
    func contaminationMatrix() -> [[Double]] {
        let clean = cleanMatrix()
        guard hasContamination, !clean.isEmpty else {
            cachedArtifactTruth = SourceSimulatorArtifacts.Truth()
            return []
        }
        let signature = cachedCleanSignature + contaminationSignature()
        if let cached = cachedContamination, signature == cachedContaminationSignature { return cached }

        let channelCount = clean.count
        let n = clean.first?.count ?? 0
        var total = [[Double]](repeating: [Double](repeating: 0, count: n), count: channelCount)

        if artifacts.anyEnabled {
            let (artifactChannels, truth) = SourceSimulatorArtifacts.inject(
                montage: montage, channelCount: channelCount, samplingRate: sampleRate,
                durationSeconds: durationSeconds, options: artifacts
            )
            cachedArtifactTruth = truth
            for c in 0..<channelCount where c < artifactChannels.count {
                for t in 0..<min(n, artifactChannels[c].count) { total[c][t] += artifactChannels[c][t] }
            }
        } else {
            cachedArtifactTruth = SourceSimulatorArtifacts.Truth()
        }

        if noiseEnabled {
            // Scale the background to the target SNR against the clean field plus
            // whatever artifacts were just added (so SNR is versus the full signal
            // the user sees).
            let reference = artifacts.anyEnabled ? addMatrices(clean, total) : clean
            let noise = SourceSimulatorNoise.noiseMatrix(
                clean: reference, model: noiseModel, targetSNRdB: noiseTargetSNRdB, seed: noiseSeed
            )
            for c in 0..<channelCount where c < noise.count {
                for t in 0..<min(n, noise[c].count) { total[c][t] += noise[c][t] }
            }
        }

        cachedContamination = total
        cachedContaminationSignature = signature
        return total
    }

    /// Clean + contamination, `channels × samples`.
    func noisyMatrix() -> [[Double]] {
        let clean = cleanMatrix()
        let contamination = contaminationMatrix()
        guard !contamination.isEmpty else { return clean }
        return addMatrices(clean, contamination)
    }

    /// The noisy field at one sample (clean column + contamination column).
    func noisyPotentials(atSample sample: Int) -> [Double]? {
        let clean = cleanMatrix()
        guard !clean.isEmpty else { return nil }
        let contamination = contaminationMatrix()
        let n = clean.first?.count ?? 0
        guard n > 0 else { return nil }
        let index = min(max(sample, 0), n - 1)
        return clean.indices.map { c in
            let base = clean[c][index]
            let extra = (contamination.indices.contains(c) && index < contamination[c].count) ? contamination[c][index] : 0
            return base + extra
        }
    }

    // MARK: Scoring (Stage 3b)

    /// SNR / correlation of the noisy field against the clean truth at the
    /// scrubber position — the live scrub readout.
    func liveScore() -> SourceSimulatorNoise.Score? {
        guard hasContamination else { return nil }
        let clean = cleanMatrix()
        guard !clean.isEmpty else { return nil }
        let sample = currentSample
        let n = clean.first?.count ?? 0
        guard n > 0 else { return nil }
        let index = min(max(sample, 0), n - 1)
        let cleanColumn = clean.map { $0[index] }
        guard let noisyColumn = noisyPotentials(atSample: index) else { return nil }
        return SourceSimulatorNoise.instantaneousScore(cleanColumn: cleanColumn, noisyColumn: noisyColumn)
    }

    /// Whole-recording SNR / correlation of the noisy field against the clean
    /// truth.
    func overallScore() -> SourceSimulatorNoise.Score? {
        guard hasContamination else { return nil }
        let clean = cleanMatrix()
        guard !clean.isEmpty else { return nil }
        return SourceSimulatorNoise.score(clean: clean, noisy: noisyMatrix())
    }

    // MARK: Localization diagnostic (Stage 3c)

    /// The latest fit — one dipole per source the user has placed — with each
    /// paired to its nearest true generator. Stored and observed so the glass-brain
    /// overlay and the inspector readout redraw when a (background) fit finishes.
    /// `nil` when there is nothing to show.
    var fitResult: SingleDipoleFit.MultiLocalization?
    /// True while a fit is running off the main thread, so the UI can show a
    /// "thinking" indicator instead of appearing to do nothing on a big montage.
    var isFitting = false
    @ObservationIgnored private var fitTask: Task<Void, Never>?
    /// Only the most recently scheduled fit is allowed to write `fitResult`, so a
    /// fast scrub that outruns the solver never lands a stale result.
    @ObservationIgnored private var fitGeneration = 0

    /// Turns the fitted-dipole overlay on and kicks off a fit — the right-click /
    /// button entry point. The overlay then re-fits as the playhead or geometry
    /// changes (the view watches `localizationSignature()` and calls `scheduleFit`).
    func fitDipoleAtPlayhead() {
        showDipoleFit = true
        scheduleFit()
    }

    /// Fits one dipole per placed source to the displayed field, off the main
    /// thread, and stores the result. In `.instant` mode it fits the topography at
    /// the playhead; in `.interval` mode it fits the whole selected interval
    /// (spatiotemporal). "Show noisy field" drives whether the clean or
    /// contaminated field is used. A no-op unless the overlay is on.
    func scheduleFit() {
        guard showDipoleFit, !sources.isEmpty else { fitResult = nil; return }
        let usedNoisy = hasContamination && showNoisyField
        let head = headModel
        let montage = self.montage
        let reference = self.reference
        let terms = harmonicTerms
        let count = sources.count
        let mode = fitMode

        // Snapshot the field inputs on the main actor; the solve is pure.
        let potentials = scalpPotentials()
        let intervalData = mode == .interval ? displayedMatrix(over: fitSelection) : nil
        let sampleCount = intervalData?.first?.count ?? 0
        guard mode == .instant ? (potentials != nil) : (sampleCount > 0) else { fitResult = nil; return }

        fitTask?.cancel()
        fitGeneration += 1
        let generation = fitGeneration
        isFitting = true
        fitTask = Task { [weak self] in
            let outcome: (result: SingleDipoleFit.MultiResult, spectrum: [Double])? =
                await Task.detached(priority: .userInitiated) {
                    switch mode {
                    case .instant:
                        guard let potentials,
                              let r = SingleDipoleFit.fitMultiple(
                                potentialsMicrovolts: potentials, count: count, head: head,
                                montage: montage, reference: reference, harmonicTerms: terms)
                        else { return nil }
                        return (r, [])
                    case .interval:
                        guard let intervalData,
                              let r = SingleDipoleFit.fitSpatioTemporal(
                                data: intervalData, count: count, head: head,
                                montage: montage, reference: reference, harmonicTerms: terms)
                        else { return nil }
                        return (r.result, r.varianceSpectrum)
                    }
                }.value
            await MainActor.run {
                guard let self, generation == self.fitGeneration else { return }
                self.fitResult = outcome.map {
                    self.attachTruth(to: $0.result, usedNoisyField: usedNoisy,
                                     spatioTemporal: mode == .interval, spectrum: $0.spectrum)
                }
                self.isFitting = false
            }
        }
    }

    /// Synchronous multi-dipole fit (one per source) for tests / headless callers.
    /// Uses the instantaneous path (single playhead sample).
    func liveMultiLocalization() -> SingleDipoleFit.MultiLocalization? {
        guard !sources.isEmpty else { return nil }
        let usedNoisy = hasContamination && showNoisyField
        guard let potentials = scalpPotentials() else { return nil }
        guard let fit = SingleDipoleFit.fitMultiple(
            potentialsMicrovolts: potentials, count: sources.count, head: headModel,
            montage: montage, reference: reference, harmonicTerms: harmonicTerms
        ) else { return nil }
        return attachTruth(to: fit, usedNoisyField: usedNoisy)
    }

    /// Synchronous spatiotemporal fit over `range` (or the whole epoch) for tests.
    func liveIntervalLocalization(over range: ClosedRange<Int>? = nil) -> SingleDipoleFit.MultiLocalization? {
        guard !sources.isEmpty, let data = displayedMatrix(over: range) else { return nil }
        let usedNoisy = hasContamination && showNoisyField
        guard let outcome = SingleDipoleFit.fitSpatioTemporal(
            data: data, count: sources.count, head: headModel,
            montage: montage, reference: reference, harmonicTerms: harmonicTerms
        ) else { return nil }
        return attachTruth(to: outcome.result, usedNoisyField: usedNoisy,
                           spatioTemporal: true, spectrum: outcome.varianceSpectrum)
    }

    // MARK: - Fit mode: dataset + shared-geometry fit

    /// Builds a two-condition demo dataset from the demo scene (Source 1 fires
    /// twice as strongly in condition B). Truth is known, so the Fit-mode readout
    /// can show mm/deg here — the Stage-4 bridge will hand over real data with no
    /// truth instead.
    func loadFitDemoDataset() {
        loadDemoScene()
        guard let lead = leadMatrix(), !lead.isEmpty else { return }
        let series = sourceSeries()
        let n = sampleCount
        func field(scales: [Double]) -> [[Double]] {
            var out = [[Double]](repeating: [Double](repeating: 0, count: n), count: lead.count)
            for ch in lead.indices {
                let row = lead[ch]
                for t in 0..<n {
                    var s = 0.0
                    for src in series.indices where src < row.count { s += row[src] * scales[src] * series[src][t] }
                    out[ch][t] = s
                }
            }
            return out
        }
        let unit = sources.map { _ in 1.0 }
        var doubled = unit
        if !doubled.isEmpty { doubled[0] = 2.0 }
        let truth = sources.map {
            FitDataset.TruthDipole(
                name: $0.name,
                position: Vector3D(x: $0.positionMeters.x, y: $0.positionMeters.y, z: $0.positionMeters.z),
                orientation: Vector3D(x: $0.orientationNormalized.x, y: $0.orientationNormalized.y, z: $0.orientationNormalized.z))
        }
        fitDataset = FitDataset(
            label: "Demo — 2 conditions",
            conditions: [
                .init(name: "Condition A", data: field(scales: unit)),
                .init(name: "Condition B", data: field(scales: doubled)),
            ],
            montage: montage, headModel: headModel, reference: reference,
            sampleRate: sampleRate, startSample: 0, truth: truth)
        fitDatasetSelection = nil
        fitDipoleCount = max(1, sources.count)
        sharedFitResult = nil
        sharedFitDecompositions = []
        fitSeedPositions = nil
        windowMode = .fit
        markFitStale("Demo dataset loaded — press Fit to localize.")
    }

    /// Installs a dataset handed over from a recording ("Fit Source Model"),
    /// switches to Fit mode, pre-highlights the given interval, and fits.
    func applyPendingFit(dataset: FitDataset, selection: ClosedRange<Int>?) {
        fitDataset = dataset
        fitDatasetSelection = selection
        fitDipoleCount = max(1, dataset.truth?.count ?? fitDipoleCount)
        sharedFitResult = nil
        sharedFitDecompositions = []
        fitSeedPositions = nil
        windowMode = .fit
        // Fitting is slow; wait for the user to press Fit rather than launching
        // a solve the moment a recording is handed over.
        markFitStale("Dataset loaded — press Fit to localize.")
    }

    /// Conditions sliced to the current fit selection (or whole dataset).
    private func slicedConditions() -> [(name: String, data: [[Double]])]? {
        guard let dataset = fitDataset, !dataset.conditions.isEmpty else { return nil }
        let sampleCount = dataset.sampleCount
        guard sampleCount > 0 else { return nil }
        let range: ClosedRange<Int>
        if let selection = fitDatasetSelection {
            let lower = min(max(selection.lowerBound, 0), sampleCount - 1)
            let upper = min(max(selection.upperBound, lower), sampleCount - 1)
            range = lower...upper
        } else {
            range = 0...(sampleCount - 1)
        }
        return dataset.conditions.map { ($0.name, $0.data.map { Array($0[range]) }) }
    }

    /// Runs the shared-geometry fit over the selected interval, off the main
    /// thread, storing `sharedFitResult`. When `seeds` is given (the user dragged
    /// dipoles), the fit refines from those positions instead of the deflation
    /// seed. A bare call is a fresh fit and drops any stale drag seed.
    func scheduleSharedFit(seeds: [Vector3D]? = nil) {
        if seeds == nil { fitSeedPositions = nil }
        guard let dataset = fitDataset, let conditions = slicedConditions() else {
            sharedFitResult = nil; sharedFitDecompositions = []; return
        }
        let count = max(1, fitDipoleCount)
        let head = dataset.headModel
        let montage = dataset.montage
        let reference = dataset.reference
        let terms = harmonicTerms
        // Seeds only apply when their count matches the requested dipole count.
        let usableSeeds = (seeds?.count == count) ? seeds : nil

        sharedFitTask?.cancel()
        fitCancellation.cancel()               // stop any in-flight solve
        fitCancellation = CancellationFlag()   // fresh flag for this run
        let cancellation = fitCancellation
        sharedFitGeneration += 1
        let generation = sharedFitGeneration
        isFittingShared = true
        fitIsStale = false
        fitProgress = 0
        fitProgressMessage = "Starting…"

        // Progress hops back to the main actor; the solve itself stays detached.
        let onProgress: @Sendable (Double, String) -> Void = { [weak self] fraction, message in
            Task { @MainActor in
                guard let self, generation == self.sharedFitGeneration else { return }
                self.fitProgress = fraction
                self.fitProgressMessage = message
            }
        }
        let reporter = SingleDipoleFit.ProgressReporter(
            report: onProgress,
            isCancelled: { cancellation.isCancelled })

        sharedFitTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                () -> (SingleDipoleFit.SharedGeometryResult?, [ConditionDecomposition]) in
                // The fit owns most of the progress budget; the decomposition
                // that follows is comparatively quick.
                guard let fit = SingleDipoleFit.fitSharedGeometry(
                    conditions: conditions, count: count, head: head,
                    montage: montage, reference: reference, harmonicTerms: terms,
                    seeds: usableSeeds, reporter: reporter.scoped(0, 0.92))
                else { return (nil, []) }

                var decompositions: [ConditionDecomposition] = []
                for (index, condition) in conditions.enumerated() {
                    if cancellation.isCancelled { break }
                    onProgress(0.92 + 0.08 * Double(index) / Double(conditions.count),
                               "Source waveforms + residual PCA — \(condition.name) (\(index + 1) of \(conditions.count))")
                    let orientations = index < fit.conditions.count
                        ? fit.conditions[index].dipoles.map(\.orientationUnit) : []
                    if let decomposition = SingleDipoleFit.decompose(
                        data: condition.data, positions: fit.positions, orientations: orientations,
                        head: head, montage: montage, reference: reference, harmonicTerms: terms) {
                        decompositions.append(ConditionDecomposition(
                            name: condition.name, decomposition: decomposition))
                    }
                }
                return (fit, decompositions)
            }.value

            await MainActor.run {
                guard let self, generation == self.sharedFitGeneration else { return }
                self.isFittingShared = false
                if cancellation.isCancelled {
                    self.fitProgressMessage = "Fit cancelled."
                    self.fitIsStale = true
                    return
                }
                self.sharedFitResult = outcome.0
                self.sharedFitDecompositions = outcome.1
                if outcome.0 == nil {
                    self.fitProgressMessage = "Fit failed — check the interval and dipole count."
                    self.fitIsStale = true
                } else {
                    self.fitProgress = 1
                    if let residual = outcome.1.first?.decomposition.residualFraction {
                        self.fitProgressMessage = String(
                            format: "Done — model explains %.1f%% of the variance; %.1f%% left in the residual components.",
                            (1 - residual) * 100, residual * 100)
                    }
                }
            }
        }
    }

    /// The Fit button: runs the shared-geometry fit, refining from any dragged
    /// positions.
    func runSharedFit() { scheduleSharedFit(seeds: fitSeedPositions) }

    /// Cancels an in-flight fit; the partial result is discarded.
    func cancelSharedFit() {
        guard isFittingShared else { return }
        fitCancellation.cancel()
        sharedFitTask?.cancel()
    }

    /// Marks the fit out of date without launching a (slow) solve.
    func markFitStale(_ reason: String? = nil) {
        guard fitDataset != nil else { return }
        fitIsStale = true
        if let reason { fitProgressMessage = reason }
    }

    // MARK: Fit-mode dipole dragging (drag to seed, then refit)

    /// Live-updates the dragged dipole's position so its marker follows the
    /// cursor, and records the drag as the seed set. Call `commitFitDrag()` on
    /// release to refit from the new positions.
    func nudgeFitDipole(index: Int, to position: SIMD3<Double>) {
        guard var result = sharedFitResult, index >= 0, index < result.positions.count else { return }
        let clamped = clampInsideBrain(position)
        let vector = Vector3D(x: clamped.x, y: clamped.y, z: clamped.z)
        if fitSeedPositions == nil { fitSeedPositions = result.positions }
        fitSeedPositions?[index] = vector
        result.positions[index] = vector
        sharedFitResult = result   // immediate visual feedback
    }

    /// Ends a drag. The fit is slow, so this does not re-solve on its own: the
    /// dragged positions are kept as the seed and the fit is marked stale for the
    /// Fit button to pick up.
    func commitFitDrag() {
        guard fitSeedPositions != nil else { return }
        markFitStale("Dipole moved — press Fit to refit from the new position.")
    }

    /// Synchronous shared fit for tests. Pass a `reporter` carrying `PhaseTimings`
    /// to profile where the solve spends its time.
    func runSharedFitNow(
        reporter: SingleDipoleFit.ProgressReporter? = nil
    ) -> SingleDipoleFit.SharedGeometryResult? {
        guard let dataset = fitDataset, let conditions = slicedConditions() else { return nil }
        let result = SingleDipoleFit.fitSharedGeometry(
            conditions: conditions, count: max(1, fitDipoleCount), head: dataset.headModel,
            montage: dataset.montage, reference: dataset.reference, harmonicTerms: harmonicTerms,
            reporter: reporter)
        sharedFitResult = result
        return result
    }

    /// Per shared-dipole error against truth, when the dataset carries it (greedy
    /// nearest pairing). Empty when there is no ground truth (real data).
    func sharedFitTruthErrors() -> [(name: String, positionMillimeters: Double)] {
        guard let dataset = fitDataset, let truth = dataset.truth, let result = sharedFitResult
        else { return [] }
        var remaining = truth
        var out: [(name: String, positionMillimeters: Double)] = []
        for position in result.positions {
            guard !remaining.isEmpty else { break }
            var bestSlot = 0
            var bestDistance = Double.greatestFiniteMagnitude
            for (slot, t) in remaining.enumerated() {
                let d = (position - t.position).norm
                if d < bestDistance { bestDistance = d; bestSlot = slot }
            }
            let matched = remaining.remove(at: bestSlot)
            out.append((matched.name, bestDistance * 1000.0))
        }
        return out
    }

    /// The dataset's per-condition butterfly matrices (whole dataset).
    func fitDatasetConditions() -> [FitDataset.ConditionData] { fitDataset?.conditions ?? [] }

    /// The displayed field (clean, or noisy when contamination is shown) as a
    /// channels × samples matrix, optionally clamped to `range`.
    func displayedMatrix(over range: ClosedRange<Int>?) -> [[Double]]? {
        let full = (hasContamination && showNoisyField) ? noisyMatrix() : cleanMatrix()
        guard let sampleCount = full.first?.count, sampleCount > 0 else { return nil }
        guard let range else { return full }
        let lower = min(max(range.lowerBound, 0), sampleCount - 1)
        let upper = min(max(range.upperBound, lower), sampleCount - 1)
        guard upper >= lower else { return full }
        return full.map { Array($0[lower...upper]) }
    }

    /// Pairs each fitted dipole to its nearest true source (greedy, one-to-one),
    /// and reports per-pair position/orientation error. A silent source at the
    /// playhead still gets a pairing slot — the extra fitted dipole lands
    /// arbitrarily, which is exactly the multi-ECD instability the diagnostic is
    /// there to expose.
    private func attachTruth(
        to result: SingleDipoleFit.MultiResult, usedNoisyField: Bool,
        spatioTemporal: Bool = false, spectrum: [Double] = []
    ) -> SingleDipoleFit.MultiLocalization {
        var remaining = Array(sources.indices)
        var pairs: [SingleDipoleFit.MultiLocalization.Pair] = []
        for dipole in result.dipoles {
            var bestSlot = -1
            var bestDistance = Double.greatestFiniteMagnitude
            for (slot, sourceIndex) in remaining.enumerated() {
                let s = sources[sourceIndex]
                let d = Vector3D(
                    x: dipole.positionMeters.x - s.positionMeters.x,
                    y: dipole.positionMeters.y - s.positionMeters.y,
                    z: dipole.positionMeters.z - s.positionMeters.z
                ).norm
                if d < bestDistance { bestDistance = d; bestSlot = slot }
            }
            if bestSlot >= 0 {
                let sourceIndex = remaining.remove(at: bestSlot)
                let s = sources[sourceIndex]
                let o = s.orientationNormalized
                let trueUnit = Vector3D(x: o.x, y: o.y, z: o.z)
                let alignment = min(1.0, abs(dipole.orientationUnit.dot(trueUnit)))
                pairs.append(SingleDipoleFit.MultiLocalization.Pair(
                    fit: dipole,
                    trueSourceName: s.name,
                    truePositionMeters: Vector3D(
                        x: s.positionMeters.x, y: s.positionMeters.y, z: s.positionMeters.z),
                    positionErrorMillimeters: bestDistance * 1000.0,
                    orientationErrorDegrees: acos(alignment) * 180.0 / .pi
                ))
            } else {
                pairs.append(SingleDipoleFit.MultiLocalization.Pair(
                    fit: dipole, trueSourceName: nil, truePositionMeters: nil,
                    positionErrorMillimeters: nil, orientationErrorDegrees: nil))
            }
        }
        return SingleDipoleFit.MultiLocalization(
            pairs: pairs, usedNoisyField: usedNoisyField,
            goodnessOfFit: result.goodnessOfFit, residualMicrovolts: result.residualMicrovolts,
            spatioTemporal: spatioTemporal, varianceSpectrum: spectrum)
    }

    /// Synchronous fit for tests and headless callers. The UI uses the async
    /// `scheduleFit` / `fitResult` path instead so a large montage never blocks.
    func liveLocalization() -> SingleDipoleFit.Localization? {
        guard !sources.isEmpty else { return nil }
        let signature = localizationSignature()
        if let cached = cachedLocalization, signature == cachedLocalizationSignature { return cached }

        let usedNoisy = hasContamination && showNoisyField
        guard let potentials = scalpPotentials() else { return nil }
        guard let fit = SingleDipoleFit.fit(
            potentialsMicrovolts: potentials, head: headModel, montage: montage,
            reference: reference, harmonicTerms: harmonicTerms
        ) else { return nil }
        let localization = attachTruth(to: fit, usedNoisyField: usedNoisy)
        cachedLocalization = localization
        cachedLocalizationSignature = signature
        return localization
    }

    /// Pairs a bare fit with its error against the dominant true source at the
    /// playhead. The active source is the one carrying the largest moment: a
    /// single ECD genuinely degrades when several fire at once, and comparing to
    /// the dominant one keeps the reported error honest rather than flattering.
    private func attachTruth(
        to fit: SingleDipoleFit.Result, usedNoisyField: Bool
    ) -> SingleDipoleFit.Localization {
        let series = sourceSeries()
        let sample = currentSample
        var activeIndex = -1
        var largestMoment = 0.0
        for index in sources.indices where index < series.count && sample < series[index].count {
            let moment = abs(series[index][sample])
            if moment > largestMoment { largestMoment = moment; activeIndex = index }
        }
        guard activeIndex >= 0, largestMoment > 1e-9 else {
            return SingleDipoleFit.Localization(
                fit: fit, usedNoisyField: usedNoisyField, trueSourceName: nil,
                truePositionMeters: nil, positionErrorMillimeters: nil,
                orientationErrorDegrees: nil
            )
        }
        let source = sources[activeIndex]
        let o = source.orientationNormalized
        return SingleDipoleFit.localization(
            fit: fit,
            trueName: source.name,
            truePositionMeters: Vector3D(
                x: source.positionMeters.x, y: source.positionMeters.y, z: source.positionMeters.z),
            trueOrientationUnit: Vector3D(x: o.x, y: o.y, z: o.z),
            usedNoisyField: usedNoisyField
        )
    }

    /// The inputs that determine a fit: geometry, source time series, contamination
    /// state, and — depending on mode — the playhead sample (instant) or the fit
    /// interval (spatiotemporal). The window view watches this so any change
    /// reschedules the fit. Interval mode deliberately omits the playhead so a
    /// scrub doesn't re-fit a window that hasn't changed.
    func localizationSignature() -> [Double] {
        var signature = geometrySignature() + seriesSignature()
            + [showNoisyField ? 1 : 0, showDipoleFit ? 1 : 0, fitMode == .interval ? 1 : 0]
            + contaminationSignature()
        switch fitMode {
        case .instant:
            signature.append(Double(currentSample))
        case .interval:
            signature.append(Double(fitSelection?.lowerBound ?? -1))
            signature.append(Double(fitSelection?.upperBound ?? -1))
        }
        return signature
    }

    private func addMatrices(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        guard !b.isEmpty else { return a }
        return a.indices.map { c in
            let ra = a[c]
            guard c < b.count else { return ra }
            let rb = b[c]
            let n = min(ra.count, rb.count)
            var out = ra
            for t in 0..<n { out[t] += rb[t] }
            return out
        }
    }

    private func contaminationSignature() -> [Double] {
        var signature: [Double] = [
            noiseEnabled ? 1 : 0,
            noiseModel == .white ? 0 : 1,
            noiseTargetSNRdB,
            Double(noiseSeed),
            artifacts.blink ? 1 : 0, artifacts.blinkAmplitudeMicrovolts, artifacts.blinksPerMinute,
            artifacts.saccade ? 1 : 0, artifacts.saccadesPerMinute, artifacts.eyeMovementAmplitudeMicrovolts,
            artifacts.emg ? 1 : 0, artifacts.emgAmplitudeMicrovolts, artifacts.emgBurstsPerMinute,
            artifacts.bcg ? 1 : 0, artifacts.bcgAmplitudeMicrovolts,
            Double(artifacts.seed),
        ]
        return signature
    }

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

    /// Surfaces a message in the window's status line (import failures, handoffs).
    func showStatus(_ text: String) {
        generationMessage = text
    }

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
        let clean = cleanMatrix()
        guard !clean.isEmpty else { throw GenerateError.solverFailed }
        let n = sampleCount
        let currentMontage = montage

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceSimulator", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Without contamination, write the single clean recording as before.
        guard hasContamination else {
            let url = directory.appendingPathComponent("source_sim.mff")
            try writeMFF(clean, to: url, montage: currentMontage, n: n)
            return url
        }

        // With contamination: write clean (truth) + noisy, plus a truth sidecar.
        let noisy = noisyMatrix()
        let cleanURL = directory.appendingPathComponent("source_sim_clean.mff")
        let noisyURL = directory.appendingPathComponent("source_sim_noisy.mff")
        try writeMFF(clean, to: cleanURL, montage: currentMontage, n: n)
        try writeMFF(noisy, to: noisyURL, montage: currentMontage, n: n)
        try writeTruthSidecar(to: directory.appendingPathComponent("source_sim_truth.json"))
        // The noisy recording is what the user reviews / hands to Score (with the
        // clean one as truth).
        return noisyURL
    }

    private func writeMFF(_ channels: [[Double]], to url: URL, montage: Montage, n: Int) throws {
        let floatChannels = channels.map { row in row.map { Float($0) } }
        let signal = MFFSignalData(
            signalURL: url.appendingPathComponent("signal1.bin"),
            signalType: "EEG Source Simulator",
            numberOfChannels: floatChannels.count,
            samplingRate: sampleRate,
            duration: Double(n) / sampleRate,
            recordingStartTime: Date(),
            events: [],
            data: floatChannels,
            channelNames: montage.channelNames
        )
        try MFFWriter.write(
            signal: signal, segments: [], kind: .continuous,
            to: url, preserveSourceFileInfo: false
        )
        try MontageWriter.writeLayoutFiles(montage: montage, to: url)
    }

    /// The truth sidecar: active dipoles (position / orientation / activations),
    /// the noise settings, the artifact timing truth, and the overall score.
    struct TruthSidecar: Codable, Sendable {
        struct Dipole: Codable, Sendable {
            struct Activation: Codable, Sendable {
                var startSeconds: Double
                var lengthSeconds: Double
                var amplitudeNanoampereMeters: Double
                var waveform: String
            }
            var name: String
            var positionMeters: [Double]
            var orientationUnit: [Double]
            var activations: [Activation]
        }
        var samplingRate: Double
        var durationSeconds: Double
        var channelCount: Int
        var headModel: String
        var dipoles: [Dipole]
        var noiseEnabled: Bool
        var noiseModel: String
        var noiseTargetSNRdB: Double
        var artifactTruth: SourceSimulatorArtifacts.Truth
        var overallSNRdB: Double?
        var overallCorrelation: Double?
    }

    func truthSidecar() -> TruthSidecar {
        _ = contaminationMatrix()   // ensure artifact truth is current
        let score = overallScore()
        return TruthSidecar(
            samplingRate: sampleRate,
            durationSeconds: durationSeconds,
            channelCount: channelCount,
            headModel: headModel == .classicFourShell ? "four-shell" : "three-shell",
            dipoles: sources.map { source in
                let o = source.orientationNormalized
                return TruthSidecar.Dipole(
                    name: source.name,
                    positionMeters: [source.positionMeters.x, source.positionMeters.y, source.positionMeters.z],
                    orientationUnit: [o.x, o.y, o.z],
                    activations: source.activations.map {
                        TruthSidecar.Dipole.Activation(
                            startSeconds: $0.startSeconds,
                            lengthSeconds: $0.lengthSeconds,
                            amplitudeNanoampereMeters: $0.amplitudeNanoampereMeters,
                            waveform: $0.waveform.label
                        )
                    }
                )
            },
            noiseEnabled: noiseEnabled,
            noiseModel: noiseModel.rawValue,
            noiseTargetSNRdB: noiseTargetSNRdB,
            artifactTruth: cachedArtifactTruth,
            overallSNRdB: score?.snrDb,
            overallCorrelation: score?.correlation
        )
    }

    private func writeTruthSidecar(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(truthSidecar()).write(to: url, options: .atomic)
    }
}
