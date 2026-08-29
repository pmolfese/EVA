//
//  BCGSurrogateCorrection.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Broadband BCG correction by surrogate-source separation — PCA-S (ROADMAP
//  SI-3). One UI-free entry point shared by the BCG sheet, `ProcessingCore`,
//  batch, replay, and the pipeline regression corpus.
//
//  ## Method and provenance
//
//  Implements the PCA-S surrogate method of Rusiniak et al. (2022), which
//  applies the Berg–Scherg source-informed spatial filtering (multiple-source
//  correction) framework of Berg & Scherg (1994) to the ballistocardiogram.
//  This is a native Swift reconstruction written from the published
//  manuscripts to the best of our ability; no reference implementation was
//  ported or consulted.
//
//    * Rusiniak, M., Bornfleth, H., Cho, J.-H., Wolak, T., Ille, N., Berg, P.,
//      & Scherg, M. (2022). EEG-fMRI: Ballistocardiogram artifact reduction by
//      surrogate method for improved source localization. Frontiers in
//      Neuroscience, 16, 842420. https://doi.org/10.3389/fnins.2022.842420
//    * Berg, P., & Scherg, M. (1994). A multiple source approach to the
//      correction of eye artifacts. Electroencephalography and Clinical
//      Neurophysiology, 90(3), 229–241.
//      https://doi.org/10.1016/0013-4694(94)90094-9
//
//  ## What it does
//
//  The recording is written as a simultaneous mixture of a fixed brain model and
//  a small artifact dictionary,
//
//      X ≈ B·S + A·U
//
//  where `B` is the surrogate brain basis (`SurrogateBrainModel`) and `A` the BCG
//  topographies found from this recording's own beats
//  (`BCGSurrogateTopographies`). Both blocks are fitted at once; only `B·S` is
//  reconstructed. The brain block is regularized and the artifact block is not,
//  and that asymmetry — not any dimension deficit — is what separates them: any
//  variance the artifact topographies can explain is cheaper to put there.
//
//  Template subtraction removes an *average* artifact and takes evoked signal
//  with it; this removes only what the brain model cannot explain.
//
//  ## Three contracts this type enforces rather than assumes
//
//  **Geometry.** The basis is a physical model, so it needs real electrode
//  positions. Missing or incomplete geometry is a refusal
//  (`BCGSurrogateError.missingGeometry`), never a silent fall back to a standard
//  montage: a filter built on someone else's head shape removes something other
//  than this subject's artifact, and it would do it without saying so. The head
//  model itself *is* an assumption, and every report names it.
//
//  **Channels.** The operator is built and applied over exactly the good EEG
//  subset the caller supplies. Bad channels are excluded from the fit — a
//  flatlined or bridged row would otherwise contribute a topography the model
//  then treats as brain-or-artifact — and are returned untouched. PNS never
//  enters: it is a separate signal object and is not passed in.
//
//  **Reference.** The operator is built in average reference over the same
//  electrode set, and the correction is expressed as a *removal*:
//
//      corrected = X − (X_avg − Op·X_avg),   X_avg = X − mean over the subset
//
//  When the recording is already average-referenced this reduces exactly to
//  `Op·X`. When it is not, the removed term has zero mean across the subset by
//  construction, so subtracting it leaves the recording's own reference
//  untouched. Either way the operator and the data it is applied to are in the
//  same reference, which is the thing that must never be fudged.
//

import Foundation

/// The head model PCA-S builds its surrogate brain basis on. Only the analytic
/// sphere family is offered here: those are exact for concentric geometry, fast,
/// and what the operator is validated against — the right choice for building a
/// brain basis. The affine ellipsoid and the (now multi-shell-validated) BEM
/// exist (`EllipsoidalForwardModel`, `BEMForwardModel`) but aren't wired into
/// the basis: the ellipsoid needs a basis overload, and BEM's dense solve buys
/// nothing over the exact analytic sphere for a concentric basis (its value is
/// generation-side, in EVASimulate). Every case names an assumption, never a
/// measurement of this subject; the choice travels in `eva.xml` and the audit log.
nonisolated enum BCGSurrogateHeadModel: String, Codable, Sendable, CaseIterable, Identifiable {
    case classicThreeShell
    case standardThreeShell
    case rushDriscollThreeShell
    case highSkullConductivityThreeShell
    case classicFourShell

    nonisolated var id: String { rawValue }

    nonisolated var forwardHeadModel: ForwardHeadModel {
        switch self {
        case .classicThreeShell:              return .classicThreeShell
        case .standardThreeShell:             return .standardThreeShell
        case .rushDriscollThreeShell:         return .rushDriscollThreeShell
        case .highSkullConductivityThreeShell: return .highSkullConductivityThreeShell
        case .classicFourShell:               return .classicFourShell
        }
    }

    nonisolated var displayName: String {
        switch self {
        case .classicThreeShell:              return "Classic 3-shell (1:80)"
        case .standardThreeShell:             return "Standard 3-shell (1:40)"
        case .rushDriscollThreeShell:         return "Rush–Driscoll 3-shell (1:80)"
        case .highSkullConductivityThreeShell: return "High-conductivity skull 3-shell (1:20)"
        case .classicFourShell:               return "4-shell + CSF"
        }
    }

    /// One-line reminder of what the choice changes, for the picker help.
    nonisolated var summary: String {
        switch self {
        case .classicThreeShell:
            return "Brain/skull/scalp with the classic highly-insulating 1:80 skull — EVA's long-standing default."
        case .standardThreeShell:
            return "The modern consensus skull conductivity (~1:40), less insulating than the classic value."
        case .rushDriscollThreeShell:
            return "Rush & Driscoll (1968) proportions with the classic 1:80 skull."
        case .highSkullConductivityThreeShell:
            return "The low end of the credible skull range (~1:20); the most conductive skull offered."
        case .classicFourShell:
            return "Adds a cerebrospinal-fluid layer between brain and skull — the geometry the PCA-S paper used."
        }
    }
}

/// Portable PCA-S settings. Everything here travels in `eva.xml`; nothing here
/// is fitted to a particular recording.
nonisolated struct BCGSurrogateSettings: Codable, Sendable, Equatable {
    /// The surrogate brain basis's head model. Portable and replayable.
    var headModel: BCGSurrogateHeadModel = .classicThreeShell
    var patternSearch: BCGArtifactPatternSearch = .iterative
    /// Beat-locked template window, relative to each detected beat.
    var windowStartSeconds: Double = -0.1
    var windowEndSeconds: Double = 0.6
    /// Band the template search runs in. The correction itself is broadband.
    var bandLowHz: Double = 1
    var bandHighHz: Double = 20
    /// Spatio-temporal correlation a beat must reach to join the template.
    var correlationThreshold: Double = 0.6
    /// Share of template variance a principal component must carry to be kept.
    /// The paper uses 0.5% and reports 4–8 components per subject.
    var varianceThreshold: Double = 0.005
    var regionalSourceCount: Int = SurrogateBrainModel.defaultRegionalSourceCount
    /// The published 2%. Not a tuning knob to be optimized away: halve it and
    /// the method removes less, raise it and it starts eating brain signal.
    var brainRegularization: Double = 0.02
    var harmonicTerms: Int = 60
    /// Minimum beats that must survive the pattern search. Below this the
    /// template is an average of too few beats to be a topography estimate.
    var minimumAcceptedBeats: Int = 10
    /// Split-half correlation a template component must reach to be treated as
    /// artifact rather than as residual EEG. See
    /// `BCGSurrogateTopographies.componentReliability` for why this exists and
    /// what it measured before it did.
    var minimumComponentReliability: Double = 0.9

    static let `default` = BCGSurrogateSettings()

    // MARK: eva.xml bridge

    var parameters: [String: String] {
        [
            "surrogateHeadModel": headModel.rawValue,
            "surrogatePatternSearch": patternSearch.rawValue,
            "surrogateWindowStartSeconds": String(format: "%.6f", windowStartSeconds),
            "surrogateWindowEndSeconds": String(format: "%.6f", windowEndSeconds),
            "surrogateBandLowHz": String(format: "%.6f", bandLowHz),
            "surrogateBandHighHz": String(format: "%.6f", bandHighHz),
            "surrogateCorrelationThreshold": String(format: "%.6f", correlationThreshold),
            "surrogateVarianceThreshold": String(format: "%.6f", varianceThreshold),
            "surrogateRegionalSourceCount": "\(regionalSourceCount)",
            "surrogateBrainRegularization": String(format: "%.6f", brainRegularization),
            "surrogateHarmonicTerms": "\(harmonicTerms)",
            "surrogateMinimumAcceptedBeats": "\(minimumAcceptedBeats)",
            "surrogateMinimumComponentReliability": String(format: "%.6f", minimumComponentReliability)
        ]
    }

    init() {}

    /// Restores settings from a recorded step. Absent keys keep their defaults,
    /// so a script written by an older build still replays with the values that
    /// build used.
    init(parameters p: [String: String]) {
        self.init()
        if let value = p["surrogateHeadModel"].flatMap(BCGSurrogateHeadModel.init(rawValue:)) {
            headModel = value
        }
        if let value = p["surrogatePatternSearch"].flatMap(BCGArtifactPatternSearch.init(rawValue:)) {
            patternSearch = value
        }
        if let value = p["surrogateWindowStartSeconds"].flatMap(Double.init) { windowStartSeconds = value }
        if let value = p["surrogateWindowEndSeconds"].flatMap(Double.init) { windowEndSeconds = value }
        if let value = p["surrogateBandLowHz"].flatMap(Double.init) { bandLowHz = value }
        if let value = p["surrogateBandHighHz"].flatMap(Double.init) { bandHighHz = value }
        if let value = p["surrogateCorrelationThreshold"].flatMap(Double.init) { correlationThreshold = value }
        if let value = p["surrogateVarianceThreshold"].flatMap(Double.init) { varianceThreshold = value }
        if let value = p["surrogateRegionalSourceCount"].flatMap(Int.init) { regionalSourceCount = value }
        if let value = p["surrogateBrainRegularization"].flatMap(Double.init) { brainRegularization = value }
        if let value = p["surrogateHarmonicTerms"].flatMap(Int.init) { harmonicTerms = value }
        if let value = p["surrogateMinimumAcceptedBeats"].flatMap(Int.init) { minimumAcceptedBeats = value }
        if let value = p["surrogateMinimumComponentReliability"].flatMap(Double.init) {
            minimumComponentReliability = value
        }
    }
}

/// What one PCA-S run actually did to this recording. Fitted and
/// recording-specific: the counterpart to `BCGSurrogateSettings`, and
/// deliberately not the same thing (RW-1's payload rule).
nonisolated struct BCGSurrogateReport: Codable, Sendable, Equatable {
    var correctedChannelCount: Int
    var excludedChannelCount: Int
    var candidateBeatCount: Int
    var acceptedBeatCount: Int
    var artifactComponentCount: Int
    var artifactVarianceFractions: [Double]
    /// Split-half reliability of each retained component, and how many
    /// candidates the reliability gate rejected. Both belong in the record: a
    /// correction that kept two of six components did something different from
    /// one that kept all six.
    var artifactComponentReliabilities: [Double]
    var reliabilityRejectedComponentCount: Int
    var patternSearch: String
    var representativeBeatIndex: Int?
    var regionalSourceCount: Int
    var brainColumnCount: Int
    var brainRegularization: Double
    var operatorDiagnostics: SourceInformedOperatorDiagnostics
    var headModelName: String
    var headShellRadiiMeters: [Double]
    var harmonicTerms: Int
    var geometryName: String
    var reference: String
    /// Fraction of the corrected subset's variance the filter removed. A
    /// sanity number, not a quality score: near zero means it did nothing, near
    /// one means it removed the recording.
    var removedVarianceFraction: Double

    /// One line per fact, for `log_eva_*.txt` and the export audit log.
    var auditLogLines: [String] {
        var lines: [String] = [
            "bcgCorrection method: surrogate PCA-S (Berg-Scherg family)",
            "bcgCorrection channels: \(correctedChannelCount) corrected, \(excludedChannelCount) excluded",
            "bcgCorrection beats: \(acceptedBeatCount) accepted of \(candidateBeatCount) candidates (\(patternSearch) pattern search)",
            "bcgCorrection artifactComponents: \(artifactComponentCount)"
                + (reliabilityRejectedComponentCount > 0
                   ? " (\(reliabilityRejectedComponentCount) rejected as unreliable)"
                   : "")
                + (artifactVarianceFractions.isEmpty
                   ? ""
                   : " (variance " + artifactVarianceFractions
                        .map { String(format: "%.3f", $0) }.joined(separator: ", ") + ")"),
            "bcgCorrection brainModel: \(regionalSourceCount) regional sources, "
                + "\(brainColumnCount) columns, regularization "
                + String(format: "%.4f", brainRegularization),
            "bcgCorrection headModel: \(headModelName) radii "
                + headShellRadiiMeters.map { String(format: "%.3f", $0) }.joined(separator: "/")
                + " m, \(harmonicTerms) harmonic terms",
            "bcgCorrection geometry: \(geometryName), reference \(reference)",
            "bcgCorrection removedVarianceFraction: " + String(format: "%.4f", removedVarianceFraction)
        ]
        if let representativeBeatIndex {
            lines.append("bcgCorrection representativeBeat: candidate \(representativeBeatIndex)")
        }
        return lines
    }

    /// Short status for the sheet and the history rail.
    var summary: String {
        "\(artifactComponentCount) component\(artifactComponentCount == 1 ? "" : "s") · "
            + "\(acceptedBeatCount)/\(candidateBeatCount) beats · "
            + String(format: "%.1f%% variance removed", removedVarianceFraction * 100)
    }
}

nonisolated enum BCGSurrogateError: LocalizedError, Equatable, Sendable {
    case missingGeometry(missingChannelNumbers: [Int])
    case noBeats
    case tooFewAcceptedBeats(accepted: Int, required: Int)
    case noArtifactComponents
    case tooFewChannels(found: Int, required: Int)
    case operatorFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingGeometry(let missing):
            let preview = missing.prefix(8).map(String.init).joined(separator: ", ")
            let suffix = missing.count > 8 ? ", …" : ""
            return missing.isEmpty
                ? "PCA-S needs 3D electrode coordinates for this recording; none are loaded."
                : "PCA-S needs 3D electrode coordinates for every corrected channel; "
                    + "channel\(missing.count == 1 ? "" : "s") \(preview)\(suffix) "
                    + "\(missing.count == 1 ? "has" : "have") none."
        case .noBeats:
            return "PCA-S needs detected beats. Run BCG (or ECG/QRS) detection first."
        case .tooFewAcceptedBeats(let accepted, let required):
            return "Only \(accepted) beat\(accepted == 1 ? "" : "s") matched the artifact pattern; "
                + "\(required) are required. Check the detected beats or lower the correlation threshold."
        case .noArtifactComponents:
            return "No artifact component carried enough of the beat template's variance to be used."
        case .tooFewChannels(let found, let required):
            return "PCA-S needs at least \(required) good EEG channels; \(found) are available."
        case .operatorFailed(let message):
            return "The source-informed operator could not be built: \(message)"
        }
    }
}

nonisolated enum BCGSurrogateCorrection {

    /// Name of this stage's `CleaningVarianceAccount`, fixed by ROADMAP SI-3 so
    /// the export audit log names the method rather than the domain.
    static let varianceStageName = "surrogateSeparation"

    /// The smallest channel count the brain/artifact split is meaningful at.
    /// Below this the brain basis has almost no room to describe anything the
    /// artifact dictionary cannot.
    static let minimumChannelCount = 8

    struct Output: Sendable {
        /// Full-width corrected data: excluded rows are copied through
        /// unchanged, in the caller's original row order.
        var data: [[Float]]
        var report: BCGSurrogateReport
        /// The fitted operator, for diagnostics and audit. Not persisted as a
        /// replay payload: PCA-S is re-fitted from the file's own beats, which
        /// is cheaper than storing an electrodes × electrodes matrix and cannot
        /// go stale against the signal it is applied to.
        var operatorMatrix: [[Double]]
    }

    /// Corrects `data` in place over `correctedRows`, leaving every other row
    /// untouched.
    ///
    /// - Parameters:
    ///   - correctedRows: the good EEG subset, in signal row order.
    ///   - geometry: 3D coordinates for at least those rows. Missing geometry
    ///     throws; there is no standard-montage fallback.
    ///   - beatSeconds: detected beat times, from EVA's existing detectors.
    static func correct(
        data: [[Float]],
        samplingRate: Double,
        correctedRows: [Int],
        geometry: ElectrodeGeometry?,
        channelNames: [String]?,
        beatSeconds: [Double],
        settings: BCGSurrogateSettings = .default,
        head headOverride: ForwardHeadModel? = nil
    ) async throws -> Output {
        // The head model comes from the replayable settings; an explicit override
        // is honored for tests and callers that need to pin a specific geometry.
        let head = headOverride ?? settings.headModel.forwardHeadModel
        let rows = correctedRows.filter { data.indices.contains($0) }.sorted()
        guard rows.count >= minimumChannelCount else {
            throw BCGSurrogateError.tooFewChannels(found: rows.count, required: minimumChannelCount)
        }
        guard !beatSeconds.isEmpty else { throw BCGSurrogateError.noBeats }

        guard let geometry else {
            throw BCGSurrogateError.missingGeometry(missingChannelNumbers: [])
        }
        let missing = rows.filter { geometry.positions[$0] == nil }.map { $0 + 1 }
        guard missing.isEmpty else {
            throw BCGSurrogateError.missingGeometry(missingChannelNumbers: missing)
        }

        let electrodes = OrderedElectrodes(
            names: rows.map { row in
                let signalName = channelNames.flatMap {
                    $0.indices.contains(row) ? $0[row] : nil
                }?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let signalName, !signalName.isEmpty { return signalName }
                return geometry.channelNames[row] ?? "E\(row + 1)"
            },
            positionsMeters: rows.map { row in
                let direction = geometry.positions[row]!
                return SIMD3<Double>(
                    direction.x * head.scalpRadiusMeters + head.centerMeters.x,
                    direction.y * head.scalpRadiusMeters + head.centerMeters.y,
                    direction.z * head.scalpRadiusMeters + head.centerMeters.z
                )
            }
        )

        let subset = rows.map { data[$0].map(Double.init) }
        guard let components = await BCGSurrogateTopographies.components(
            channels: subset,
            samplingRate: samplingRate,
            beatSeconds: beatSeconds,
            settings: settings
        ) else {
            throw BCGSurrogateError.noArtifactComponents
        }
        guard components.acceptedBeatCount >= settings.minimumAcceptedBeats else {
            throw BCGSurrogateError.tooFewAcceptedBeats(
                accepted: components.acceptedBeatCount,
                required: settings.minimumAcceptedBeats
            )
        }

        let basis: SurrogateBrainBasis
        do {
            basis = try SurrogateBrainModel.basis(
                head: head,
                electrodes: electrodes,
                regionalSourceCount: settings.regionalSourceCount,
                reference: .average,
                harmonicTerms: settings.harmonicTerms
            )
        } catch {
            throw BCGSurrogateError.operatorFailed(error.localizedDescription)
        }

        let separation: SourceInformedOperator
        do {
            separation = try SourceInformedSeparation.makeOperator(
                brainBasis: basis.matrix,
                artifactTopographies: components.topographies,
                brainRegularization: settings.brainRegularization
            )
        } catch {
            throw BCGSurrogateError.operatorFailed(error.localizedDescription)
        }

        // Average reference over the corrected subset, so the operator and the
        // data it multiplies describe the same reference. See the file header.
        let sampleCount = subset.first?.count ?? 0
        var averageReferenced = subset
        var commonMode = [Double](repeating: 0, count: sampleCount)
        for sample in 0..<sampleCount {
            var sum = 0.0
            for channel in subset.indices { sum += subset[channel][sample] }
            let mean = sum / Double(subset.count)
            commonMode[sample] = mean
            for channel in averageReferenced.indices { averageReferenced[channel][sample] -= mean }
        }

        let reconstructed: [[Double]]
        do {
            reconstructed = try SourceInformedSeparation.apply(separation, to: averageReferenced)
        } catch {
            throw BCGSurrogateError.operatorFailed(error.localizedDescription)
        }

        // The removal, not the reconstruction: subtracting what the brain model
        // could not explain preserves whatever reference the recording arrived
        // in, and is identical to `Op·X` when that reference is already average.
        var corrected = data
        var removedSquares = 0.0
        var originalSquares = 0.0
        for (index, row) in rows.enumerated() {
            var channel = data[row]
            for sample in 0..<sampleCount {
                let removed = averageReferenced[index][sample] - reconstructed[index][sample]
                removedSquares += removed * removed
                let original = averageReferenced[index][sample]
                originalSquares += original * original
                channel[sample] = Float(Double(channel[sample]) - removed)
            }
            corrected[row] = channel
        }

        let report = BCGSurrogateReport(
            correctedChannelCount: rows.count,
            excludedChannelCount: data.count - rows.count,
            candidateBeatCount: components.candidateBeatCount,
            acceptedBeatCount: components.acceptedBeatCount,
            artifactComponentCount: components.topographies.count,
            artifactVarianceFractions: components.varianceFractions,
            artifactComponentReliabilities: components.reliabilities,
            reliabilityRejectedComponentCount: components.rejectedForReliability.count,
            patternSearch: components.patternSearch.rawValue,
            representativeBeatIndex: components.representativeBeatIndex,
            regionalSourceCount: settings.regionalSourceCount,
            brainColumnCount: basis.columnCount,
            brainRegularization: settings.brainRegularization,
            operatorDiagnostics: separation.diagnostics,
            headModelName: basis.headModelName,
            headShellRadiiMeters: basis.headShellRadiiMeters,
            harmonicTerms: basis.harmonicTerms,
            geometryName: geometry.name,
            reference: basis.reference.rawValue,
            removedVarianceFraction: originalSquares > 0 ? removedSquares / originalSquares : 0
        )
        return Output(data: corrected, report: report, operatorMatrix: separation.matrix)
    }
}
