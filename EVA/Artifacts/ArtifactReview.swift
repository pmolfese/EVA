import Foundation

/// Shared destinations for the review arrows and keyboard, including partial final sets.
nonisolated struct ArtifactReviewNavigation {
    let count: Int
    let selectedIndex: Int
    static let pageSize = 18

    var page: Int { min(max(selectedIndex, 0), max(count - 1, 0)) / Self.pageSize }
    var pageCount: Int { (max(count, 0) + Self.pageSize - 1) / Self.pageSize }
    var visibleRange: Range<Int> {
        let start = page * Self.pageSize
        return start..<min(start + Self.pageSize, max(count, 0))
    }

    func destination(_ direction: Int, byPage: Bool? = nil) -> Int? {
        guard count > 0, direction != 0 else { return nil }
        let delta = direction < 0 ? -1 : 1
        if byPage ?? (pageCount > 1) {
            let nextPage = page + delta
            guard (0..<pageCount).contains(nextPage) else { return nil }
            return nextPage * Self.pageSize
        }
        let next = min(max(selectedIndex, 0), count - 1) + delta
        return (0..<count).contains(next) ? next : nil
    }
}

nonisolated enum ArtifactReviewDecision: String, Codable, Sendable, CaseIterable {
    case include, hold, exclude
}

nonisolated struct ArtifactReviewChoice: Codable, Sendable, Equatable {
    var decision: ArtifactReviewDecision
    var isManual: Bool
}

nonisolated struct ArtifactReviewRules: Codable, Sendable, Equatable {
    var includeCorrelation = 0.90
    var excludeCorrelation = 0.75
    var limitsPeak = false
    var maximumPeakMicrovolts = 300.0
    var limitsDuration = false
    var maximumDurationSeconds = 1.0
    var requiresCompleteWindow = true
    var requiresSpanInsideCore = false
    var preservesManualChoices = true
}

/// Definitions and review decisions only. Waveforms and scores are always derived
/// from the signal entering cleaning, and are never frozen into a replay payload.
nonisolated struct ArtifactReviewState: Codable, Sendable {
    var candidates: [MFFEvent]
    var referenceEventIDs: [String]
    var choices: [String: ArtifactReviewChoice] = [:]
    var rules = ArtifactReviewRules()
    /// Split descendants point at the original detector/definition, not a sibling.
    var sourceArtifactID: UUID? = nil
    var sourceThresholdKind: EyeArtifactKind? = nil
    var partitionsSource: Bool? = nil
    /// Keeps detector provenance while presenting an extracted family as an
    /// independent top-level artifact in Review. Optional preserves decoding
    /// of sidecars written before drag-to-extract existed.
    var displaysAsStandaloneArtifact: Bool? = nil
    /// Cross-definition moves retain the detector/definition that originally
    /// produced each imported candidate. Optional for old sidecar compatibility.
    var importedCandidateSourceIDs: [String: UUID]? = nil
}

nonisolated enum ArtifactReviewBand: String, CaseIterable, Identifiable, Sendable {
    case close = "Close match", variation = "Shape variation", low = "Low similarity"
    var id: String { rawValue }
    static func forCorrelation(_ r: Double?) -> Self? {
        guard let r else { return nil }
        return r >= 0.90 ? .close : r >= 0.75 ? .variation : .low
    }
}

nonisolated enum ArtifactReviewDisplayMode: String, CaseIterable, Identifiable {
    case single = "Single", top3 = "Top 3", top5 = "Top 5"
    var id: String { rawValue }
    var channelLimit: Int { switch self { case .single: 1; case .top3: 3; case .top5: 5 } }
}

nonisolated struct ArtifactReviewChannelImpact: Sendable, Equatable {
    let channelIndex: Int
    let peakToPeakMicrovolts: Double
}

nonisolated struct ArtifactReviewContextWindow: Sendable {
    let core: Range<Int>
    let padded: Range<Int>
    let displayed: Range<Int>
}

nonisolated enum ArtifactReviewTilePreview: String, CaseIterable, Identifiable {
    case waveforms = "Waveforms", topomaps = "Topomaps"
    var id: String { rawValue }
}

/// Derived display data at peak spatial field strength within an event's core.
nonisolated struct ArtifactReviewTopography: Sendable {
    let values: [Double]
    let channelIndices: [Int]
    let sampleIndex: Int
    let timeSeconds: Double
    let globalFieldPower: Double
    var maximumAbsoluteAmplitude: Double { channelIndices.map { abs(values[$0]) }.max() ?? 0 }
}

nonisolated struct ArtifactReviewExample: Identifiable, Sendable {
    var event: MFFEvent
    /// Channel-major, baseline-centered resampling over the fixed core window.
    var samples: [Float]
    var correlation: Double?
    var peakMicrovolts: Double?
    var durationSeconds: Double?
    var hasCompleteWindow: Bool
    var spanInsideCore: Bool?
    /// Number of usable reference windows used for this event's comparison.
    /// Reference members exclude themselves; other candidates use the full reference.
    var referencePeerCount = 0
    /// Display-only ranking across good recording channels, independently of scoring scope.
    var impactedChannels: [ArtifactReviewChannelImpact] = []
    var topography: ArtifactReviewTopography? = nil
    var matchConfidence: ArtifactReviewMatchConfidence { ArtifactReviewMatchConfidence(example: self) }
    var id: String { event.id }
    var band: ArtifactReviewBand? { .forCorrelation(correlation) }
}

/// A transparent shape-match score, not a calibrated artifact probability.
/// Quality problems withhold the score rather than applying arbitrary penalties.
nonisolated struct ArtifactReviewMatchConfidence: Equatable, Sendable {
    let score: Int?
    let explanation: String
    let referenceCount: Int
    var hasLimitedReference: Bool { referenceCount > 0 && referenceCount < 3 }

    init(example: ArtifactReviewExample) {
        referenceCount = example.referencePeerCount
        if !example.hasCompleteWindow {
            score = nil
            explanation = "Incomplete correction window; the cleaner skips this event."
        } else if example.samples.isEmpty {
            score = nil
            explanation = "No usable waveform on the definition channels; check channel selection and nonfinite samples."
        } else if referenceCount == 0 {
            score = nil
            explanation = "No other reference example. Include another usable event to compare shapes."
        } else if let r = example.correlation, r.isFinite {
            score = Int((min(max(r, 0), 1) * 100).rounded())
            if r < 0 {
                explanation = "Opposite polarity to the class reference."
            } else if r < 0.75 {
                explanation = "Shape differs from the class reference."
            } else if r < 0.90 {
                explanation = "Similar shape with some variation."
            } else {
                explanation = "Shape closely matches the class reference."
            }
        } else {
            score = nil
            explanation = "No usable shape correlation; the event or reference may be flat or cancel out."
        }
    }
}

nonisolated struct ArtifactReviewAnalysis: Sendable {
    var examples: [ArtifactReviewExample]
    var reference: [Float]
    var channelIndices: [Int]
    var pointsPerChannel: Int
    var referenceCount: Int
    var sourceRevision: UUID
    var artifactID: UUID

    func meanWaveform(of examples: [ArtifactReviewExample], channel: Int) -> [Float] {
        let rows = examples.map { waveform($0.samples, channel: channel) }.filter { !$0.isEmpty }
        guard let first = rows.first else { return [] }
        var mean = [Float](repeating: 0, count: first.count)
        for row in rows { for index in mean.indices { mean[index] += row[index] / Float(rows.count) } }
        return mean
    }

    func waveform(_ samples: [Float], channel: Int) -> [Float] {
        guard let offset = channelIndices.firstIndex(of: channel), pointsPerChannel > 0,
              samples.count >= (offset + 1) * pointsPerChannel else { return [] }
        return Array(samples[(offset * pointsPerChannel)..<((offset + 1) * pointsPerChannel)])
    }
}

nonisolated enum ArtifactReviewEngine {
    static func isThresholdFamily(_ artifact: DefinedArtifact) -> Bool {
        artifact.thresholdOcularKind != nil || artifact.reviewState?.sourceThresholdKind != nil
    }

    static func canReview(_ artifact: DefinedArtifact) -> Bool {
        !ArtifactCleanRunMetrics.isContinuous(artifact.cleaningMethod)
            && artifact.corneoRetinalConfiguration == nil
            && artifact.movementPCAConfiguration == nil
            && artifact.muscleBSSCCAConfiguration == nil
    }

    static func candidates(for artifact: DefinedArtifact) -> [MFFEvent] {
        artifact.reviewState?.candidates ?? artifact.thresholdOcularCandidates?.map(\.event) ?? artifact.events
    }

    static func prepare(_ artifact: inout DefinedArtifact) {
        guard artifact.reviewState == nil else { return }
        let candidates = candidates(for: artifact)
        let accepted = Set(artifact.events.map(\.id))
        var state = ArtifactReviewState(candidates: candidates, referenceEventIDs: candidates.map(\.id))
        for event in candidates where !accepted.contains(event.id) {
            state.choices[event.id] = ArtifactReviewChoice(decision: .exclude, isManual: true)
        }
        artifact.reviewState = state
    }

    static func choice(for id: String, artifact: DefinedArtifact) -> ArtifactReviewChoice {
        artifact.reviewState?.choices[id] ?? ArtifactReviewChoice(decision: .include, isManual: false)
    }

    static func commitChoices(_ artifact: inout DefinedArtifact) {
        guard let state = artifact.reviewState else { return }
        artifact.events = state.candidates.filter { choice(for: $0.id, artifact: artifact).decision == .include }
        artifact.thresholdOcularExcludedEventIDs = Set(state.candidates.filter {
            choice(for: $0.id, artifact: artifact).decision != .include
        }.map(\.id))
        artifact.average = nil
        // Review chooses exact detected events; a separate R-wave source would
        // bypass those decisions when applying PCA-S.
        if artifact.cleaningMethod == .pcaS {
            var settings = artifact.pcaSSettings ?? .default
            settings.beatSource = .artifactEvents
            artifact.pcaSSettings = settings
        }
    }

    static func setChoice(_ decision: ArtifactReviewDecision, eventID: String, artifact: inout DefinedArtifact) {
        prepare(&artifact)
        guard artifact.reviewState?.candidates.contains(where: { $0.id == eventID }) == true else { return }
        artifact.reviewState?.choices[eventID] = ArtifactReviewChoice(decision: decision, isManual: true)
        commitChoices(&artifact)
    }

    static func proposedChoice(for example: ArtifactReviewExample, artifact: DefinedArtifact,
                               rules: ArtifactReviewRules) -> ArtifactReviewChoice {
        let previous = choice(for: example.id, artifact: artifact)
        if rules.preservesManualChoices, previous.isManual { return previous }
        let result: ArtifactReviewDecision
        if (rules.requiresCompleteWindow && !example.hasCompleteWindow)
            || (rules.requiresSpanInsideCore && example.spanInsideCore == false)
            || (rules.limitsPeak && (example.peakMicrovolts ?? 0) > rules.maximumPeakMicrovolts)
            || (rules.limitsDuration && (example.durationSeconds ?? 0) > rules.maximumDurationSeconds) {
            result = .exclude
        } else if let r = example.correlation {
            result = r >= rules.includeCorrelation ? .include : r < rules.excludeCorrelation ? .exclude : .hold
        } else {
            result = .hold
        }
        return ArtifactReviewChoice(decision: result, isManual: false)
    }

    static func applyRules(_ rules: ArtifactReviewRules, analysis: ArtifactReviewAnalysis,
                           artifact: inout DefinedArtifact) {
        guard analysis.artifactID == artifact.id else { return }
        prepare(&artifact)
        artifact.reviewState?.rules = rules
        for example in analysis.examples {
            let proposed = proposedChoice(for: example, artifact: artifact, rules: rules)
            artifact.reviewState?.choices[example.id] = proposed
        }
        commitChoices(&artifact)
    }

    static func rebuildReference(_ artifact: inout DefinedArtifact) {
        prepare(&artifact)
        guard !artifact.events.isEmpty else { return }
        artifact.reviewState?.referenceEventIDs = artifact.events.map(\.id)
    }

    /// Moves members, rather than copying them: one occurrence cannot train or
    /// receive correction from both its original definition and its split class.
    static func split(eventIDs: Set<String>, name: String, method: ArtifactCleaningMethod,
                      displaysAsStandaloneArtifact: Bool = false,
                      parent: inout DefinedArtifact) -> DefinedArtifact? {
        prepare(&parent)
        guard var parentState = parent.reviewState else { return nil }
        let moved = parentState.candidates.filter { eventIDs.contains($0.id) }
        guard !moved.isEmpty, moved.count < parentState.candidates.count else { return nil }
        var child = parent
        child.id = UUID()
        child.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(parent.name) variation" : name
        child.eventCode = "\(parent.eventCode)-\(child.id.uuidString.prefix(6))"
        child.cleaningMethod = method
        child.thresholdOcularKind = nil // The detector continues to own only the root.
        child.thresholdOcularCandidates = parent.thresholdOcularCandidates?.filter { eventIDs.contains($0.id) }
        child.savedTemplate = nil
        child.topography = nil
        child.obsStrategy = .standard
        child.appliedMethod = nil
        child.cleanedAt = nil
        child.pcaSReport = nil
        var childState = parentState
        childState.candidates = moved
        childState.partitionsSource = true
        childState.sourceArtifactID = parentState.sourceArtifactID ?? parent.id
        childState.sourceThresholdKind = parent.thresholdOcularKind ?? parentState.sourceThresholdKind
        childState.displaysAsStandaloneArtifact = displaysAsStandaloneArtifact ? true : nil
        childState.choices = childState.choices.filter { eventIDs.contains($0.key) }
        childState.referenceEventIDs = moved.map(\.id)
        child.reviewState = childState
        parentState.partitionsSource = true
        parentState.candidates.removeAll { eventIDs.contains($0.id) }
        parentState.choices = parentState.choices.filter { !eventIDs.contains($0.key) }
        parentState.referenceEventIDs = parentState.candidates.map(\.id)
        parent.reviewState = parentState
        commitChoices(&parent)
        commitChoices(&child)
        return child
    }

    /// Moves reviewed candidates into another class. Manual/automatic choices
    /// and source provenance travel with the events.
    static func transfer(eventIDs: Set<String>, source: inout DefinedArtifact,
                         destination: inout DefinedArtifact) -> Bool {
        prepare(&source); prepare(&destination)
        guard var sourceState = source.reviewState, var destinationState = destination.reviewState else { return false }
        let sourceRoot = sourceState.sourceArtifactID ?? source.id
        let destinationRoot = destinationState.sourceArtifactID ?? destination.id
        let moved = sourceState.candidates.filter { eventIDs.contains($0.id) }
        guard !moved.isEmpty, moved.count < sourceState.candidates.count else { return false }
        let movedIDs = Set(moved.map(\.id))
        let movedChoices = sourceState.choices.filter { movedIDs.contains($0.key) }
        let sourceImports = sourceState.importedCandidateSourceIDs ?? [:]
        let movedOrigins = Dictionary(uniqueKeysWithValues: moved.map {
            ($0.id, sourceImports[$0.id] ?? sourceRoot)
        })

        sourceState.candidates.removeAll { movedIDs.contains($0.id) }
        sourceState.choices = sourceState.choices.filter { !movedIDs.contains($0.key) }
        sourceState.referenceEventIDs = sourceState.candidates.map(\.id)
        let remainingSourceImports = sourceImports.filter { !movedIDs.contains($0.key) }
        sourceState.importedCandidateSourceIDs = remainingSourceImports.isEmpty ? nil : remainingSourceImports

        let existing = Set(destinationState.candidates.map(\.id))
        destinationState.candidates.append(contentsOf: moved.filter { !existing.contains($0.id) })
        destinationState.candidates.sort {
            if $0.centerTimeSeconds == $1.centerTimeSeconds { return $0.id < $1.id }
            return $0.centerTimeSeconds < $1.centerTimeSeconds
        }
        for (id, choice) in movedChoices { destinationState.choices[id] = choice }
        var destinationImports = destinationState.importedCandidateSourceIDs ?? [:]
        for (id, origin) in movedOrigins {
            if origin == destinationRoot { destinationImports.removeValue(forKey: id) }
            else { destinationImports[id] = origin }
        }
        destinationState.importedCandidateSourceIDs = destinationImports.isEmpty ? nil : destinationImports
        destinationState.referenceEventIDs = destinationState.candidates.map(\.id)
        destinationState.partitionsSource = true
        // The detector-owned root has no parent. Keeping its source ID nil is
        // important because descendant cleanup identifies children by this ID.
        destinationState.sourceArtifactID = destination.id == destinationRoot ? nil : destinationRoot
        sourceState.partitionsSource = true
        sourceState.sourceArtifactID = source.id == sourceRoot ? nil : sourceRoot

        let movedDetails = source.thresholdOcularCandidates?.filter { movedIDs.contains($0.id) } ?? []
        // The root retains the detector's complete candidate ledger so an
        // identical detector refresh recognizes the partition. Descendants
        // carry only the details for their own members.
        if source.id != sourceRoot {
            source.thresholdOcularCandidates?.removeAll { movedIDs.contains($0.id) }
        }
        if destination.id != destinationRoot, !movedDetails.isEmpty {
            var details = destination.thresholdOcularCandidates ?? []
            let detailIDs = Set(details.map(\.id))
            details.append(contentsOf: movedDetails.filter { !detailIDs.contains($0.id) })
            destination.thresholdOcularCandidates = details.sorted {
                if $0.event.centerTimeSeconds == $1.event.centerTimeSeconds { return $0.id < $1.id }
                return $0.event.centerTimeSeconds < $1.event.centerTimeSeconds
            }
        }

        source.reviewState = sourceState
        destination.reviewState = destinationState
        commitChoices(&source); commitChoices(&destination)
        return true
    }

    static func removeSplitClasses(from artifacts: inout [DefinedArtifact], sourceID: UUID) {
        // If the family being refreshed currently houses events imported from
        // another detector, return them before its review state is replaced.
        // This keeps a refresh of only the destination detector from silently
        // dropping the source detector's still-valid candidates.
        var returns: [(event: MFFEvent, choice: ArtifactReviewChoice?, origin: UUID)] = []
        for artifact in artifacts where artifact.id == sourceID || artifact.reviewState?.sourceArtifactID == sourceID {
            guard let state = artifact.reviewState, let imports = state.importedCandidateSourceIDs else { continue }
            for event in state.candidates {
                guard let origin = imports[event.id] else { continue }
                returns.append((event, state.choices[event.id], origin))
            }
        }
        for item in returns {
            guard let index = artifacts.firstIndex(where: { $0.id == item.origin }) else { continue }
            prepare(&artifacts[index])
            guard var state = artifacts[index].reviewState else { continue }
            if !state.candidates.contains(where: { $0.id == item.event.id }) {
                state.candidates.append(item.event)
                state.candidates.sort {
                    if $0.centerTimeSeconds == $1.centerTimeSeconds { return $0.id < $1.id }
                    return $0.centerTimeSeconds < $1.centerTimeSeconds
                }
            }
            if let choice = item.choice { state.choices[item.event.id] = choice }
            state.referenceEventIDs = state.candidates.map(\.id)
            artifacts[index].reviewState = state
            commitChoices(&artifacts[index])
        }

        if let rootIndex = artifacts.firstIndex(where: { $0.id == sourceID }),
           var rootState = artifacts[rootIndex].reviewState,
           let imports = rootState.importedCandidateSourceIDs, !imports.isEmpty {
            let importedIDs = Set(imports.keys)
            rootState.candidates.removeAll { importedIDs.contains($0.id) }
            rootState.choices = rootState.choices.filter { !importedIDs.contains($0.key) }
            rootState.referenceEventIDs = rootState.candidates.map(\.id)
            rootState.importedCandidateSourceIDs = nil
            artifacts[rootIndex].reviewState = rootState
            commitChoices(&artifacts[rootIndex])
        }

        artifacts.removeAll { $0.reviewState?.sourceArtifactID == sourceID }
        for index in artifacts.indices {
            guard var state = artifacts[index].reviewState,
                  let imports = state.importedCandidateSourceIDs else { continue }
            let removed = Set(imports.compactMap { $0.value == sourceID ? $0.key : nil })
            guard !removed.isEmpty else { continue }
            state.candidates.removeAll { removed.contains($0.id) }
            state.choices = state.choices.filter { !removed.contains($0.key) }
            state.referenceEventIDs = state.candidates.map(\.id)
            let remaining = imports.filter { !removed.contains($0.key) }
            state.importedCandidateSourceIDs = remaining.isEmpty ? nil : remaining
            artifacts[index].reviewState = state
            artifacts[index].thresholdOcularCandidates?.removeAll { removed.contains($0.id) }
            commitChoices(&artifacts[index])
        }
    }

    static func analyze(artifact: DefinedArtifact, signal: MFFSignalData, excluding: Set<Int>,
                        sensorLayoutName: String? = nil,
                        topographyChannelIndices: Set<Int>? = nil) -> ArtifactReviewAnalysis {
        let sampleCount = signal.data.first?.count ?? 0
        let requested: [Int]
        if !artifact.selectedChannelIndices.isEmpty { requested = artifact.selectedChannelIndices }
        else if let kind = artifact.thresholdOcularKind ?? artifact.reviewState?.sourceThresholdKind {
            requested = artifact.thresholdOcularConfiguration?.channelOverride
                ?? EyeArtifactThresholdDetector.autoOcularChannelIndices(kind: kind,
                    channelCount: signal.data.count, sensorLayoutName: sensorLayoutName)
        } else { requested = Array(signal.data.indices) }
        let channels = Array(Set(requested)).sorted().filter {
            signal.data.indices.contains($0) && !excluding.contains($0) && signal.data[$0].count == sampleCount
        }
        let points = min(max(Int((artifact.windowSizeSeconds * max(signal.samplingRate, 0)).rounded()), 3), 128)
        let details = Dictionary((artifact.thresholdOcularCandidates ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var examples: [ArtifactReviewExample] = []
        for event in candidates(for: artifact) {
            if Task.isCancelled { break }
            let padded = ArtifactCleaner.correctionWindow(for: event, artifact: artifact, signal: signal)
            let core = ArtifactCleaner.correctionWindow(for: event, artifact: artifact, signal: signal, includesTaper: false)
            let detail = details[event.id]
            var example = ArtifactReviewExample(event: event, samples: [], correlation: nil,
                peakMicrovolts: nil, durationSeconds: detail.map { $0.endTimeSeconds - $0.startTimeSeconds } ?? event.durationSeconds,
                hasCompleteWindow: padded != nil, spanInsideCore: nil)
            example.impactedChannels = mostImpactedChannels(for: event, artifact: artifact, signal: signal, excluding: excluding)
            example.topography = peakTopography(for: event, artifact: artifact, signal: signal,
                excluding: excluding, mappedChannels: topographyChannelIndices)
            if let detail, let core, signal.samplingRate > 0 {
                example.spanInsideCore = detail.startTimeSeconds >= Double(core.lowerBound) / signal.samplingRate
                    && detail.endTimeSeconds <= Double(core.upperBound) / signal.samplingRate
            }
            if let core, !channels.isEmpty {
                var profile: [Float] = []
                profile.reserveCapacity(channels.count * points)
                var peak = 0.0
                var valid = true
                for channel in channels {
                    let row = signal.data[channel]
                    // Check every sample: downsampling must not hide clipping/NaNs.
                    var sum = 0.0
                    for sample in core {
                        let value = Double(row[sample])
                        if !value.isFinite { valid = false; break }
                        sum += value
                    }
                    guard valid else { break }
                    let baseline = sum / Double(core.count)
                    for sample in core { peak = max(peak, abs(Double(row[sample]) - baseline)) }
                    for point in 0..<points {
                        let position = Double(core.lowerBound) + Double(point) * Double(core.count - 1) / Double(max(points - 1, 1))
                        let lower = Int(position), upper = min(lower + 1, core.upperBound - 1)
                        let fraction = position - Double(lower)
                        let value = Float(Double(row[lower]) * (1 - fraction) + Double(row[upper]) * fraction - baseline)
                        if !value.isFinite { valid = false; break }
                        profile.append(value)
                    }
                }
                if valid { example.samples = profile; example.peakMicrovolts = peak }
            }
            examples.append(example)
        }
        let referenceIDs = Set(artifact.reviewState?.referenceEventIDs ?? candidates(for: artifact).map(\.id))
        let donors = examples.filter { referenceIDs.contains($0.id) && $0.hasCompleteWindow && !$0.samples.isEmpty }
        let dimension = donors.first?.samples.count ?? 0
        var sum = [Double](repeating: 0, count: dimension)
        for donor in donors { for index in sum.indices { sum[index] += Double(donor.samples[index]) } }
        let average = sum.map { Float($0 / Double(max(donors.count, 1))) }
        let donorIDs = Set(donors.map(\.id))
        for index in examples.indices where !examples[index].samples.isEmpty && dimension == examples[index].samples.count {
            let member = donorIDs.contains(examples[index].id)
            let divisor = donors.count - (member ? 1 : 0)
            examples[index].referencePeerCount = divisor
            guard divisor > 0 else { continue }
            let target = sum.indices.map { (sum[$0] - (member ? Double(examples[index].samples[$0]) : 0)) / Double(divisor) }
            examples[index].correlation = correlation(examples[index].samples, target)
        }
        return ArtifactReviewAnalysis(examples: examples, reference: average, channelIndices: channels,
            pointsPerChannel: points, referenceCount: donors.count, sourceRevision: signal.dataRevision, artifactID: artifact.id)
    }

    static func peakTopography(for event: MFFEvent, artifact: DefinedArtifact,
                               signal: MFFSignalData, excluding: Set<Int>,
                               mappedChannels: Set<Int>? = nil) -> ArtifactReviewTopography? {
        guard signal.samplingRate > 0,
              let core = ArtifactCleaner.correctionWindow(for: event, artifact: artifact, signal: signal,
                  includesTaper: false), !core.isEmpty else { return nil }
        var channels: [Int] = [], baselines: [Double] = []
        for channel in signal.data.indices where !excluding.contains(channel)
            && (mappedChannels?.contains(channel) ?? true) {
            if Task.isCancelled { return nil }
            let row = signal.data[channel]
            guard core.lowerBound >= 0, core.upperBound <= row.count else { continue }
            var sum = 0.0, valid = true
            for index in core {
                guard row[index].isFinite else { valid = false; break }
                sum += Double(row[index])
            }
            if valid { channels.append(channel); baselines.append(sum / Double(core.count)) }
        }
        guard channels.count >= 3 else { return nil }
        var bestSample = core.lowerBound, bestVariance = 0.0
        for sample in core {
            if Task.isCancelled { return nil }
            var mean = 0.0, sumSquares = 0.0
            for offset in channels.indices {
                let value = Double(signal.data[channels[offset]][sample]) - baselines[offset]
                let delta = value - mean
                mean += delta / Double(offset + 1)
                sumSquares += delta * (value - mean)
            }
            let variance = sumSquares / Double(channels.count)
            if variance > bestVariance { bestVariance = variance; bestSample = sample }
        }
        guard bestVariance.isFinite, bestVariance > 1e-12 else { return nil }
        var values = [Double](repeating: 0, count: signal.data.count)
        var spatialMean = 0.0
        for offset in channels.indices {
            let value = Double(signal.data[channels[offset]][bestSample]) - baselines[offset]
            values[channels[offset]] = value
            spatialMean += value / Double(channels.count)
        }
        for channel in channels { values[channel] -= spatialMean }
        return ArtifactReviewTopography(values: values, channelIndices: channels,
            sampleIndex: bestSample, timeSeconds: Double(bestSample) / signal.samplingRate,
            globalFieldPower: sqrt(bestVariance))
    }

    static func mostImpactedChannels(for event: MFFEvent, artifact: DefinedArtifact,
                                     signal: MFFSignalData, excluding: Set<Int>) -> [ArtifactReviewChannelImpact] {
        guard let core = ArtifactCleaner.correctionWindow(for: event, artifact: artifact, signal: signal,
            includesTaper: false, requiresCompleteWindow: false) else { return [] }
        var impacts: [ArtifactReviewChannelImpact] = []
        for channel in signal.data.indices where !excluding.contains(channel) {
            if Task.isCancelled { return [] }
            let row = signal.data[channel]
            // Rank only complete, finite cores: DC offsets and context spikes must not drive ranking.
            guard core.lowerBound >= 0, core.upperBound <= row.count, !core.isEmpty else { continue }
            var minimum = Double.infinity, maximum = -Double.infinity
            var valid = true
            for index in core {
                let value = Double(row[index])
                guard value.isFinite else { valid = false; break }
                minimum = min(minimum, value)
                maximum = max(maximum, value)
            }
            let amplitude = maximum - minimum
            if valid, amplitude.isFinite, amplitude > 1e-12 {
                impacts.append(ArtifactReviewChannelImpact(channelIndex: channel, peakToPeakMicrovolts: amplitude))
            }
        }
        return Array(impacts.sorted {
            $0.peakToPeakMicrovolts == $1.peakToPeakMicrovolts
                ? $0.channelIndex < $1.channelIndex : $0.peakToPeakMicrovolts > $1.peakToPeakMicrovolts
        }.prefix(5))
    }

    static func contextWindow(for event: MFFEvent, artifact: DefinedArtifact,
                              signal: MFFSignalData, contextSeconds: Double) -> ArtifactReviewContextWindow? {
        guard signal.samplingRate.isFinite, signal.samplingRate > 0,
              let core = ArtifactCleaner.correctionWindow(for: event, artifact: artifact, signal: signal,
                  includesTaper: false, requiresCompleteWindow: false),
              let padded = ArtifactCleaner.correctionWindow(for: event, artifact: artifact, signal: signal,
                  requiresCompleteWindow: false) else { return nil }
        let seconds = contextSeconds.isFinite ? min(max(contextSeconds, 0), 2) : 0.5
        let extra = Int((signal.samplingRate * seconds).rounded())
        return ArtifactReviewContextWindow(core: core, padded: padded,
            displayed: (padded.lowerBound - extra)..<(padded.upperBound + extra))
    }

    /// One amplitude scale across displayed rows preserves relative channel impact.
    static func displayScale(channels: [Int], window: ArtifactReviewContextWindow,
                             signal: MFFSignalData, analysis: ArtifactReviewAnalysis) -> Double {
        var scale = 1.0
        for channel in channels where signal.data.indices.contains(channel) {
            let row = signal.data[channel]
            let coreStart = max(window.core.lowerBound, 0), coreEnd = min(window.core.upperBound, row.count)
            guard coreEnd > coreStart else { continue }
            let finite = row[coreStart..<coreEnd].filter(\.isFinite)
            let baseline = finite.reduce(0.0) { $0 + Double($1) } / Double(max(finite.count, 1))
            let start = max(window.displayed.lowerBound, 0), end = min(window.displayed.upperBound, row.count)
            if end > start {
                for value in row[start..<end] where value.isFinite { scale = max(scale, abs(Double(value) - baseline)) }
            }
            for value in analysis.waveform(analysis.reference, channel: channel) where value.isFinite {
                scale = max(scale, abs(Double(value)))
            }
        }
        return scale
    }

    /// Preserve narrow peaks and gaps when a wide context contains more samples than screen pixels.
    static func traceIndices(_ row: [Float], range: Range<Int>) -> [Int] {
        guard !range.isEmpty else { return [] }
        let bucketSize = max((range.count + 449) / 450, 1)
        var indices: [Int] = []
        for start in stride(from: range.lowerBound, to: range.upperBound, by: bucketSize) {
            let end = min(start + bucketSize, range.upperBound)
            var minimum = start, maximum = start, gap: Int?
            for index in start..<end {
                if !row[index].isFinite { gap = index; continue }
                if !row[minimum].isFinite || row[index] < row[minimum] { minimum = index }
                if !row[maximum].isFinite || row[index] > row[maximum] { maximum = index }
            }
            if gap != nil {
                // Preserve every gap boundary, including multiple gaps in one bucket.
                indices.append(contentsOf: start..<end)
            } else {
                indices.append(contentsOf: Set([start, end - 1, minimum, maximum]).sorted())
            }
        }
        return indices
    }

    private static func correlation(_ lhs: [Float], _ rhs: [Double]) -> Double? {
        guard lhs.count == rhs.count, lhs.count > 1 else { return nil }
        let meanA = lhs.reduce(0.0) { $0 + Double($1) } / Double(lhs.count)
        let meanB = rhs.reduce(0, +) / Double(rhs.count)
        var dot = 0.0, aa = 0.0, bb = 0.0
        for i in lhs.indices {
            let a = Double(lhs[i]) - meanA, b = rhs[i] - meanB
            dot += a * b; aa += a * a; bb += b * b
        }
        guard aa > 1e-12, bb > 1e-12 else { return nil }
        return min(1, max(-1, dot / sqrt(aa * bb)))
    }
}
