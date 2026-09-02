//
//  MFFReader.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation

nonisolated struct MFFPackage: Sendable {
    let sourceURL: URL
    let xmlFiles: [String]
    let binFiles: [String]
    let selectedXMLFile: String
    let metrics: [String: String]
}

nonisolated struct MFFAntiAliasTimingCorrection: Sendable, Equatable {
    enum Evidence: Hashable, Sendable {
        case acquisitionVersion
        case hardwareFilterAdjusted
    }

    let shiftMicroseconds: Int?
    let acquisitionVersion: String?
    let evidence: Set<Evidence>

    var loadingMessage: String {
        "Corrected for anti-alias timing bug at recording"
    }
}

/// The physical reference declared by the acquisition metadata. `isRecorded`
/// distinguishes a real sample row from the common EGI convention where the
/// reference exists in `sensorLayout.xml` but was omitted from `signal1.bin`.
nonisolated struct EEGAcquisitionReference: Sendable, Equatable {
    let channelIndex: Int
    let name: String
    let isRecorded: Bool
}

/// The voltage convention of the samples currently carried by a signal.
nonisolated enum EEGReferenceState: String, Sendable, Equatable {
    case unknown
    case acquisition
    case average
}

nonisolated struct MFFSignalData: Sendable {
    /// Identity of this exact sample-data version. Copies preserve the revision;
    /// constructing/replacing sample data creates a new one. Derived-signal
    /// caches use this instead of the package URL because raw, filtered, and
    /// artifact-corrected signals all originate from the same file.
    let dataRevision: UUID
    let signalURL: URL
    let signalType: String
    let numberOfChannels: Int
    let samplingRate: Double
    let duration: TimeInterval
    let recordingStartTime: Date?
    let events: [MFFEvent]
    let data: [[Float]]
    let channelNames: [String]?
    /// Pre-segmented epochs declared on disk (`epochs.xml` + `categories.xml`),
    /// e.g. when the file was segmented or category-averaged by other software.
    /// Empty for ordinary continuous recordings.
    let epochSegments: [EpochSegment]
    /// True when the file is segmented into discrete epochs on disk.
    let isSegmented: Bool
    /// True when each epoch is a category *average* (one segment per category,
    /// each built from multiple trials), i.e. an ERP/averaged file.
    let isAveraged: Bool
    /// True when the file is a *grand* average — categories are contributed by
    /// more than one subject/group (EGI marks each seg `<name>Average</name>`
    /// with `#seg == 1` plus a `subj` key).
    let isGrandAverage: Bool
    /// Per-channel electrode impedance in kΩ from the MFF `ICAL` calibration
    /// (info1.xml), indexed by channel. `nil` when the file records no impedance
    /// measurement; individual entries are `NaN` for channels with no value.
    let impedancesKOhm: [Float]?
    /// Per-channel `<positiveUp>` convention from `pnsSet.xml` (PNS signals only),
    /// indexed by channel. `true` means a positive sample value is drawn upward
    /// (the EEG convention); `false` means the sensor's own convention is
    /// negative-up. `nil` when the signal has no PNS sensor metadata (e.g. EEG,
    /// or PNS imported from a non-MFF source).
    let positiveUpFlags: [Bool]?
    /// Immutable provenance for the physical acquisition reference, when the
    /// source format declares it.
    let acquisitionReference: EEGAcquisitionReference?
    /// Reference convention of this exact sample-data version.
    let referenceState: EEGReferenceState

    init(
        dataRevision: UUID = UUID(),
        signalURL: URL,
        signalType: String,
        numberOfChannels: Int,
        samplingRate: Double,
        duration: TimeInterval,
        recordingStartTime: Date?,
        events: [MFFEvent],
        data: [[Float]],
        channelNames: [String]? = nil,
        epochSegments: [EpochSegment] = [],
        isSegmented: Bool = false,
        isAveraged: Bool = false,
        isGrandAverage: Bool = false,
        impedancesKOhm: [Float]? = nil,
        positiveUpFlags: [Bool]? = nil,
        acquisitionReference: EEGAcquisitionReference? = nil,
        referenceState: EEGReferenceState = .unknown
    ) {
        self.dataRevision = dataRevision
        self.signalURL = signalURL
        self.signalType = signalType
        self.numberOfChannels = numberOfChannels
        self.samplingRate = samplingRate
        self.duration = duration
        self.recordingStartTime = recordingStartTime
        self.events = events
        self.data = data
        self.channelNames = channelNames
        self.epochSegments = epochSegments
        self.isSegmented = isSegmented
        self.isAveraged = isAveraged
        self.isGrandAverage = isGrandAverage
        self.impedancesKOhm = impedancesKOhm
        self.positiveUpFlags = positiveUpFlags
        self.acquisitionReference = acquisitionReference
        self.referenceState = referenceState
    }

    /// Replaces samples on the same timeline. Shape changes are programming
    /// errors because the preserved events and epoch metadata would become stale.
    func replacingSamples(
        _ newData: [[Float]],
        signalTypeSuffix: String? = nil
    ) -> MFFSignalData {
        precondition(newData.count == numberOfChannels, "replacingSamples requires the same channel count")
        let oldSampleCount = data.first?.count ?? 0
        precondition(
            newData.allSatisfy { $0.count == oldSampleCount },
            "replacingSamples requires the same sample count"
        )
        return MFFSignalData(
            signalURL: signalURL,
            signalType: signalTypeSuffix.map { "\(signalType) \($0)" } ?? signalType,
            numberOfChannels: numberOfChannels,
            samplingRate: samplingRate,
            duration: duration,
            recordingStartTime: recordingStartTime,
            events: events,
            data: newData,
            channelNames: channelNames,
            epochSegments: epochSegments,
            isSegmented: isSegmented,
            isAveraged: isAveraged,
            isGrandAverage: isGrandAverage,
            impedancesKOhm: impedancesKOhm,
            positiveUpFlags: positiveUpFlags,
            acquisitionReference: acquisitionReference,
            referenceState: referenceState
        )
    }

    /// Replaces the event list on an unchanged timeline.
    ///
    /// For re-stamping events without touching samples — applying the user's
    /// event-anchor rules at load, or reapplying them after the rules change.
    func replacingEvents(_ newEvents: [MFFEvent]) -> MFFSignalData {
        MFFSignalData(
            dataRevision: dataRevision,
            signalURL: signalURL,
            signalType: signalType,
            numberOfChannels: numberOfChannels,
            samplingRate: samplingRate,
            duration: duration,
            recordingStartTime: recordingStartTime,
            events: newEvents,
            data: data,
            channelNames: channelNames,
            epochSegments: epochSegments,
            isSegmented: isSegmented,
            isAveraged: isAveraged,
            isGrandAverage: isGrandAverage,
            impedancesKOhm: impedancesKOhm,
            positiveUpFlags: positiveUpFlags,
            acquisitionReference: acquisitionReference,
            referenceState: referenceState
        )
    }

    /// Builds a new timeline while retaining only source/channel metadata. Every
    /// time-dependent field must be supplied explicitly by the caller.
    func reconstructingTimeline(
        data newData: [[Float]],
        samplingRate newSamplingRate: Double? = nil,
        events newEvents: [MFFEvent],
        epochSegments newEpochSegments: [EpochSegment],
        isSegmented newIsSegmented: Bool,
        isAveraged newIsAveraged: Bool,
        isGrandAverage newIsGrandAverage: Bool,
        signalTypeSuffix: String? = nil
    ) -> MFFSignalData {
        precondition(newData.count == numberOfChannels, "timeline reconstruction requires the same channel count")
        let sampleCount = newData.first?.count ?? 0
        precondition(newData.allSatisfy { $0.count == sampleCount }, "timeline reconstruction requires rectangular data")
        precondition(newEpochSegments.allSatisfy {
            $0.startSample >= 0 && $0.endSample >= $0.startSample && $0.endSample < sampleCount
        }, "timeline reconstruction received out-of-bounds epoch segments")
        let resolvedRate = newSamplingRate ?? samplingRate
        precondition(resolvedRate.isFinite && resolvedRate > 0, "timeline reconstruction requires a valid sampling rate")
        return MFFSignalData(
            signalURL: signalURL,
            signalType: signalTypeSuffix.map { "\(signalType) \($0)" } ?? signalType,
            numberOfChannels: numberOfChannels,
            samplingRate: resolvedRate,
            duration: Double(sampleCount) / resolvedRate,
            recordingStartTime: recordingStartTime,
            events: newEvents,
            data: newData,
            channelNames: channelNames,
            epochSegments: newEpochSegments,
            isSegmented: newIsSegmented,
            isAveraged: newIsAveraged,
            isGrandAverage: newIsGrandAverage,
            impedancesKOhm: impedancesKOhm,
            positiveUpFlags: positiveUpFlags,
            acquisitionReference: acquisitionReference,
            referenceState: referenceState
        )
    }

    /// Restores an acquisition-reference channel that the source metadata
    /// declares immediately after the recorded rows. In the original-reference
    /// voltage space that electrode is identically zero; adding the row before
    /// common-average subtraction reconstructs its average-referenced waveform.
    func restoringOmittedAcquisitionReference() -> MFFSignalData {
        guard let reference = acquisitionReference,
              !reference.isRecorded,
              reference.channelIndex == data.count,
              let sampleCount = data.first?.count,
              data.allSatisfy({ $0.count == sampleCount }) else {
            return self
        }

        var restoredData = data
        restoredData.append([Float](repeating: 0, count: sampleCount))
        var restoredNames = channelNames ?? data.indices.map { "E\($0 + 1)" }
        restoredNames.append(reference.name)
        var restoredImpedances = impedancesKOhm
        restoredImpedances?.append(.nan)
        var restoredPositiveUp = positiveUpFlags
        restoredPositiveUp?.append(true)

        return MFFSignalData(
            signalURL: signalURL,
            signalType: signalType,
            numberOfChannels: restoredData.count,
            samplingRate: samplingRate,
            duration: duration,
            recordingStartTime: recordingStartTime,
            events: events,
            data: restoredData,
            channelNames: restoredNames,
            epochSegments: epochSegments,
            isSegmented: isSegmented,
            isAveraged: isAveraged,
            isGrandAverage: isGrandAverage,
            impedancesKOhm: restoredImpedances,
            positiveUpFlags: restoredPositiveUp,
            acquisitionReference: EEGAcquisitionReference(
                channelIndex: reference.channelIndex,
                name: reference.name,
                isRecorded: false
            ),
            referenceState: referenceState
        )
    }

    func markingReference(_ state: EEGReferenceState) -> MFFSignalData {
        MFFSignalData(
            dataRevision: dataRevision,
            signalURL: signalURL,
            signalType: signalType,
            numberOfChannels: numberOfChannels,
            samplingRate: samplingRate,
            duration: duration,
            recordingStartTime: recordingStartTime,
            events: events,
            data: data,
            channelNames: channelNames,
            epochSegments: epochSegments,
            isSegmented: isSegmented,
            isAveraged: isAveraged,
            isGrandAverage: isGrandAverage,
            impedancesKOhm: impedancesKOhm,
            positiveUpFlags: positiveUpFlags,
            acquisitionReference: acquisitionReference,
            referenceState: state
        )
    }
}

/// Which instant of an event `MFFEvent.beginTimeSeconds` actually names.
///
/// EVA's event producers disagree, unavoidably: a file format records an onset,
/// while a matched-filter or peak detector naturally reports the middle of what
/// it found. Rather than have each reader guess from context — which is what
/// EVA used to do, by matching on `sourceFile` prefixes at three separate call
/// sites — every event now carries the answer, stamped once by whoever created
/// it. Read the derived `onsetTimeSeconds` / `centerTimeSeconds` / `spanSeconds`
/// instead of interpreting `beginTimeSeconds` yourself.
nonisolated enum EventTimeAnchor: String, Codable, Sendable, CaseIterable, Hashable {
    /// `beginTimeSeconds` is the event's start; its span runs forward from there.
    /// The convention of every file format EVA reads, and of MFF's own
    /// onset+duration pair.
    case onset
    /// `beginTimeSeconds` is the midpoint of the event's span.
    case center
    /// `beginTimeSeconds` is a measured extremum (an R peak, a blink apex) and
    /// the duration is the deflection's width *around* it. Geometrically
    /// identical to `.center`; kept distinct so the UI can say "Peak" where
    /// that is the truer word, and so a rule that means "this detector found a
    /// peak" is not silently conflated with "this span happens to be centered".
    case peak

    /// Whether `beginTimeSeconds` sits at the middle of the span rather than its
    /// start. The only distinction that affects geometry — `.peak` and
    /// `.center` are the same shape and differ only in what the UI calls them.
    var isCentered: Bool { self != .onset }

    /// How the event detail popover should label `beginTimeSeconds`.
    var timeFieldLabel: String {
        switch self {
        case .onset: return "Onset"
        case .center: return "Center"
        case .peak: return "Peak"
        }
    }

    var displayName: String {
        switch self {
        case .onset: return "Onset"
        case .center: return "Centered"
        case .peak: return "Peak"
        }
    }

    /// A full sentence fragment for the event popover's Anchor row: names the
    /// anchor and says what it means for the marker, since "Centered" alone
    /// does not tell you the flag sits at the middle of the span.
    var detailDescription: String {
        switch self {
        case .onset: return "Onset — marker at the start"
        case .center: return "Centered — marker at the middle"
        case .peak: return "Peak — marker at the measured peak"
        }
    }
}

nonisolated struct MFFEvent: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let code: String
    let label: String?
    let eventDescription: String?
    let cell: String?
    let beginTimeSeconds: Double
    let rawBeginTime: String
    let sourceFile: String
    /// Event duration in seconds, when the source records one (MFF `<duration>`
    /// is stored in microseconds). `nil` for instantaneous / unspecified events.
    let durationSeconds: Double?
    /// Which instant of the event `beginTimeSeconds` names. See
    /// `EventTimeAnchor`. Defaults to `.onset` — the file-format convention —
    /// so a producer that does not think about this gets the safe answer.
    let timeAnchor: EventTimeAnchor

    init(
        id: String,
        code: String,
        label: String? = nil,
        eventDescription: String? = nil,
        cell: String? = nil,
        beginTimeSeconds: Double,
        rawBeginTime: String,
        sourceFile: String,
        durationSeconds: Double? = nil,
        timeAnchor: EventTimeAnchor = .onset
    ) {
        self.id = id
        self.code = code
        self.label = Self.nonEmpty(label)
        self.eventDescription = Self.nonEmpty(eventDescription)
        self.cell = Self.nonEmpty(cell)
        self.beginTimeSeconds = beginTimeSeconds
        self.rawBeginTime = rawBeginTime
        self.sourceFile = sourceFile
        self.durationSeconds = durationSeconds
        self.timeAnchor = timeAnchor
    }

    private static func nonEmpty(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? value?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id
        case code
        case label
        case eventDescription
        case cell
        case beginTimeSeconds
        case rawBeginTime
        case sourceFile
        case durationSeconds
        case timeAnchor
    }

    /// Decodes, filling in `timeAnchor` for files written before it existed.
    ///
    /// The fill-in deliberately is *not* the `.onset` default the initializer
    /// uses. `eva_artifacts.json` payloads written by earlier builds contain
    /// events from center-stamping detectors, and defaulting those to `.onset`
    /// would move every cleaning window half a duration late on reload — a
    /// silent numerical regression in replayed results. Instead the legacy sniff
    /// those builds performed at read time is replayed once here, so an old file
    /// decodes to exactly the geometry it had before.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sourceFile = try container.decode(String.self, forKey: .sourceFile)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            code: try container.decode(String.self, forKey: .code),
            label: try container.decodeIfPresent(String.self, forKey: .label),
            eventDescription: try container.decodeIfPresent(String.self, forKey: .eventDescription),
            cell: try container.decodeIfPresent(String.self, forKey: .cell),
            beginTimeSeconds: try container.decode(Double.self, forKey: .beginTimeSeconds),
            rawBeginTime: try container.decode(String.self, forKey: .rawBeginTime),
            sourceFile: sourceFile,
            durationSeconds: try container.decodeIfPresent(Double.self, forKey: .durationSeconds),
            timeAnchor: try container.decodeIfPresent(EventTimeAnchor.self, forKey: .timeAnchor)
                ?? Self.legacyAnchor(forSourceFile: sourceFile)
        )
    }

    /// The anchor EVA used to infer from `sourceFile` before `timeAnchor` was
    /// stored. Exists solely to read payloads written by those builds and must
    /// never gain a new case — new sources stamp themselves.
    ///
    /// The old rule, from `MFFEvent.centerTimeSeconds`: single-map Topography
    /// and Continuous-scan topography stamped the true onset; every other
    /// detector stamped the center.
    private static func legacyAnchor(forSourceFile sourceFile: String) -> EventTimeAnchor {
        if sourceFile.hasPrefix("Topography") || sourceFile.hasPrefix("Continuous") {
            return .onset
        }
        return .center
    }
}

extension MFFEvent {
    /// The event's start, whatever `beginTimeSeconds` happens to name.
    ///
    /// For an anchor-less event (no duration) every instant coincides, so this
    /// is `beginTimeSeconds` regardless of anchor.
    var onsetTimeSeconds: Double {
        guard timeAnchor.isCentered, let duration = durationSeconds else { return beginTimeSeconds }
        return beginTimeSeconds - duration / 2
    }

    /// The event's midpoint.
    ///
    /// Every place that needs "the middle of this event" — cleaning windows,
    /// OBS alignment search, averaged-template previews, the waveform highlight
    /// band — should read this rather than `beginTimeSeconds`, or it will centre
    /// on the wrong sample for onset-stamped sources.
    var centerTimeSeconds: Double {
        guard !timeAnchor.isCentered, let duration = durationSeconds else { return beginTimeSeconds }
        return beginTimeSeconds + duration / 2
    }

    /// The event's end.
    var endTimeSeconds: Double {
        onsetTimeSeconds + (durationSeconds ?? 0)
    }

    /// The interval the event covers, or `nil` when it records no duration and
    /// is therefore a point in time rather than a span.
    var spanSeconds: ClosedRange<Double>? {
        guard let duration = durationSeconds, duration > 0 else { return nil }
        let start = onsetTimeSeconds
        return start...(start + duration)
    }

    /// A copy of this event re-anchored, keeping `beginTimeSeconds` where it is.
    ///
    /// This *reinterprets* the stored instant rather than moving it, which is
    /// what applying a user rule means: the sample never changed, only EVA's
    /// understanding of which part of the event it marks.
    func reanchored(to anchor: EventTimeAnchor, durationSeconds newDuration: Double? = nil) -> MFFEvent {
        MFFEvent(
            id: id,
            code: code,
            label: label,
            eventDescription: eventDescription,
            cell: cell,
            beginTimeSeconds: beginTimeSeconds,
            rawBeginTime: rawBeginTime,
            sourceFile: sourceFile,
            durationSeconds: newDuration ?? durationSeconds,
            timeAnchor: anchor
        )
    }
}

enum MFFReaderError: LocalizedError {
    case invalidContainer
    case missingSignalFiles
    case missingXMLFiles
    case missingXMLFile(URL)
    case missingSignalFile(URL)
    case invalidXML(URL, String)
    case invalidBinaryData(URL, String)
    case unsupportedSampleDepth(Int)
    case inconsistentBlockConfiguration
    case emptySignal

    var errorDescription: String? {
        switch self {
        case .invalidContainer:
            return "The selected item is not a readable MFF package."
        case .missingSignalFiles:
            return "The MFF package does not contain any signal*.bin files."
        case .missingXMLFiles:
            return "The MFF package does not contain any .xml files."
        case .missingXMLFile(let url):
            return "The MFF package does not contain \(url.lastPathComponent)."
        case .missingSignalFile(let url):
            return "The MFF package does not contain \(url.lastPathComponent)."
        case .invalidXML(let url, let details):
            return "Unable to parse \(url.lastPathComponent): \(details)"
        case .invalidBinaryData(let url, let details):
            return "Unable to parse binary signal data in \(url.lastPathComponent): \(details)"
        case .unsupportedSampleDepth(let depth):
            return "Unsupported sample depth \(depth). Only 32-bit float samples are supported."
        case .inconsistentBlockConfiguration:
            return "The MFF signal blocks have inconsistent channel counts or sample rates."
        case .emptySignal:
            return "The MFF signal did not contain any samples."
        }
    }
}

nonisolated final class MFFReader {
    func inspectPackage(at url: URL, selectedXMLFile: String? = nil) throws -> MFFPackage {
        let packageURL = try validatedPackageURL(from: url)
        let xmlFiles = try self.xmlFiles(in: packageURL)
        let binFiles = try self.binFiles(in: packageURL)
        let xmlFile = selectedXMLFile ?? preferredXMLFile(from: xmlFiles)
        let metrics = try parseXMLMetrics(in: packageURL, fileName: xmlFile)

        return MFFPackage(
            sourceURL: packageURL,
            xmlFiles: xmlFiles,
            binFiles: binFiles,
            selectedXMLFile: xmlFile,
            metrics: metrics
        )
    }

    func loadSignal(
        from packageURL: URL,
        signalFileName: String? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> MFFSignalData {
        let packageURL = try validatedPackageURL(from: packageURL)
        progress?(0.01)
        let signalDescriptor = try selectSignal(in: packageURL, preferredSignalFile: signalFileName)
        let signalData = try parseSignal(from: signalDescriptor.signalURL) { fraction in
            progress?(0.02 + 0.78 * fraction)
        }

        guard signalData.numberOfChannels > 0, signalData.totalSamples > 0 else {
            throw MFFReaderError.emptySignal
        }

        progress?(0.82)
        var samples = signalData.samples
        if let gcal = try parseCalibrationFactors(
            named: "GCAL",
            in: packageURL,
            infoFileName: signalDescriptor.infoFileName,
            expectedCount: signalData.numberOfChannels
        ) {
            applyCalibrationFactors(gcal, to: &samples)
        }

        // ICAL records per-channel electrode impedance (kΩ) at recording start.
        // Missing channels come back as NaN so health scoring can skip them.
        let impedances = try parseCalibrationFactors(
            named: "ICAL",
            in: packageURL,
            infoFileName: signalDescriptor.infoFileName,
            expectedCount: signalData.numberOfChannels,
            defaultValue: .nan
        )

        progress?(0.88)
        let recordingStartTime = try parseRecordingStartTime(in: packageURL)
        progress?(0.90)
        let events = try parseEvents(in: packageURL)
        progress?(0.96)
        let channelNames = try parseChannelNames(in: packageURL, expectedCount: signalData.numberOfChannels)
        let layout = SensorLayout.load(fromPackageContaining: signalDescriptor.signalURL)
        let acquisitionReference = layout?.reference.map { reference in
            EEGAcquisitionReference(
                channelIndex: reference.channelIndex,
                name: channelNames?.indices.contains(reference.channelIndex) == true
                    ? (channelNames?[reference.channelIndex] ?? reference.name)
                    : reference.name,
                isRecorded: reference.channelIndex < signalData.numberOfChannels
            )
        }

        // Detect on-disk segmentation/averaging (epochs.xml + categories.xml).
        // When present, the concatenated blocks are discrete epochs rather than
        // one continuous recording, and the raw event tracks are in the original
        // recording's timeline — useless against the re-segmented data. We replace
        // them with one stimulus-locked marker per epoch.
        let epochInfo = (try? parseOnDiskEpochs(
            in: packageURL,
            blockSampleCounts: signalData.blockSampleCounts,
            samplingRate: signalData.samplingRate
        )) ?? nil
        progress?(1)

        let resolvedEvents = epochInfo.map(\.events) ?? events

        return MFFSignalData(
            signalURL: signalDescriptor.signalURL,
            signalType: signalDescriptor.signalType,
            numberOfChannels: signalData.numberOfChannels,
            samplingRate: signalData.samplingRate,
            duration: Double(signalData.totalSamples) / signalData.samplingRate,
            recordingStartTime: recordingStartTime,
            events: resolvedEvents,
            data: samples,
            channelNames: channelNames,
            epochSegments: epochInfo?.segments ?? [],
            isSegmented: epochInfo != nil,
            isAveraged: epochInfo?.isAveraged ?? false,
            isGrandAverage: epochInfo?.isGrandAverage ?? false,
            impedancesKOhm: impedances,
            acquisitionReference: acquisitionReference,
            referenceState: acquisitionReference == nil ? .unknown : .acquisition
        )
    }

    func antiAliasTimingCorrection(
        in packageURL: URL,
        signalFileName: String? = nil
    ) throws -> MFFAntiAliasTimingCorrection? {
        let packageURL = try validatedPackageURL(from: packageURL)
        let signalDescriptor = try selectSignal(in: packageURL, preferredSignalFile: signalFileName)
        let acquisitionVersion = try parseAcquisitionVersion(in: packageURL)
        let hardwareAdjustment = try parseHardwareFilterAdjustment(
            in: packageURL,
            infoFileName: signalDescriptor.infoFileName
        )

        var evidence = Set<MFFAntiAliasTimingCorrection.Evidence>()
        if let acquisitionVersion, acquisitionVersionIndicatesAntiAliasCorrection(acquisitionVersion) {
            evidence.insert(.acquisitionVersion)
        }
        if hardwareAdjustment.isAdjusted {
            evidence.insert(.hardwareFilterAdjusted)
        }

        guard !evidence.isEmpty else {
            return nil
        }

        return MFFAntiAliasTimingCorrection(
            shiftMicroseconds: hardwareAdjustment.isAdjusted ? hardwareAdjustment.shiftMicroseconds : nil,
            acquisitionVersion: acquisitionVersion,
            evidence: evidence
        )
    }

    func xmlFiles(in url: URL) throws -> [String] {
        let contents = try packageContents(in: url)
        let xmlFiles = contents
            .filter { $0.pathExtension.lowercased() == "xml" }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        guard !xmlFiles.isEmpty else {
            throw MFFReaderError.missingXMLFiles
        }

        return xmlFiles
    }

    func parseXMLMetrics(in url: URL, fileName: String) throws -> [String: String] {
        let packageURL = try validatedPackageURL(from: url)
        let xmlURL = packageURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: xmlURL.path) else {
            throw MFFReaderError.missingXMLFile(xmlURL)
        }

        let document = try loadXMLDocument(at: xmlURL)
        guard let root = document.rootElement() else {
            throw MFFReaderError.invalidXML(xmlURL, "missing XML root element")
        }

        var metrics: [String: String] = [:]
        collectMetrics(from: root, path: sanitizedTagName(root.name), into: &metrics)
        metrics["rootTag"] = sanitizedTagName(root.name)
        metrics["fileName"] = fileName
        return metrics
    }

    func binFiles(in url: URL) throws -> [String] {
        let contents = try packageContents(in: url)
        let binFiles = contents
            .filter { $0.pathExtension.lowercased() == "bin" && $0.lastPathComponent.hasPrefix("signal") }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        guard !binFiles.isEmpty else {
            throw MFFReaderError.missingSignalFiles
        }

        return binFiles
    }

    private func preferredXMLFile(from xmlFiles: [String]) -> String {
        if let infoXML = xmlFiles.first(where: { $0.caseInsensitiveCompare("info.xml") == .orderedSame }) {
            return infoXML
        }
        return xmlFiles[0]
    }

    private func validatedPackageURL(from url: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MFFReaderError.invalidContainer
        }
        return url
    }

    private func packageContents(in url: URL) throws -> [URL] {
        let packageURL = try validatedPackageURL(from: url)
        return try FileManager.default.contentsOfDirectory(
            at: packageURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    private func collectMetrics(from element: XMLElement, path: String, into metrics: inout [String: String]) {
        let trimmedValue = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let childElements = (element.children ?? []).compactMap { $0 as? XMLElement }

        for attribute in element.attributes ?? [] {
            metrics["\(path).@\(attribute.name ?? "attribute")"] = attribute.stringValue ?? ""
        }

        if childElements.isEmpty, !trimmedValue.isEmpty {
            metrics[path] = trimmedValue
            return
        }

        var siblingOccurrences: [String: Int] = [:]
        let siblingTotals = Dictionary(grouping: childElements, by: { sanitizedTagName($0.name) }).mapValues(\.count)

        for child in childElements {
            let childName = sanitizedTagName(child.name)
            let siblingIndex = siblingOccurrences[childName, default: 0]
            siblingOccurrences[childName] = siblingIndex + 1
            let childPath = (siblingTotals[childName] ?? 0) > 1
                ? "\(path).\(childName)[\(siblingIndex)]"
                : "\(path).\(childName)"
            collectMetrics(from: child, path: childPath, into: &metrics)
        }
    }

    private func selectSignal(
        in packageURL: URL,
        preferredSignalFile: String?
    ) throws -> (signalURL: URL, infoFileName: String, signalType: String) {
        let signalFiles = try binFiles(in: packageURL)

        if let preferredSignalFile {
            let signalURL = packageURL.appendingPathComponent(preferredSignalFile)
            guard FileManager.default.fileExists(atPath: signalURL.path) else {
                throw MFFReaderError.missingSignalFile(signalURL)
            }
            let signalType = try parseSignalType(for: signalURL, in: packageURL) ?? "Unknown"
            return (signalURL, signalInfoFileName(for: signalURL), signalType)
        }

        let descriptors = try signalFiles.map { fileName in
            let signalURL = packageURL.appendingPathComponent(fileName)
            let signalType = try parseSignalType(for: signalURL, in: packageURL) ?? "Unknown"
            return (
                signalURL: signalURL,
                infoFileName: signalInfoFileName(for: signalURL),
                signalType: signalType
            )
        }

        if let eegSignal = descriptors.first(where: { $0.signalType.caseInsensitiveCompare("EEG") == .orderedSame }) {
            return eegSignal
        }

        guard let firstSignal = descriptors.first else {
            throw MFFReaderError.missingSignalFiles
        }
        return firstSignal
    }

    private func parseSignalType(for signalURL: URL, in packageURL: URL) throws -> String? {
        let infoURL = packageURL.appendingPathComponent(signalInfoFileName(for: signalURL))
        guard FileManager.default.fileExists(atPath: infoURL.path) else {
            return nil
        }

        let document = try loadXMLDocument(at: infoURL)
        guard let root = document.rootElement() else {
            throw MFFReaderError.invalidXML(infoURL, "missing XML root element")
        }

        if let generalInformation = firstDescendant(named: "generalInformation", in: root),
           let fileDataType = firstDescendant(named: "fileDataType", in: generalInformation),
           let channelElement = fileDataType.children?.compactMap({ $0 as? XMLElement }).first {
            let signalType = sanitizedTagName(channelElement.name)
            return signalType.isEmpty ? nil : signalType
        }

        return nil
    }

    private func signalInfoFileName(for signalURL: URL) -> String {
        let signalName = signalURL.deletingPathExtension().lastPathComponent
        let signalNumber = signalName.replacingOccurrences(of: "signal", with: "")
        return "info\(signalNumber).xml"
    }

    private func parseCalibrationFactors(
        named calibrationType: String,
        in packageURL: URL,
        infoFileName: String,
        expectedCount: Int,
        defaultValue: Float = 1
    ) throws -> [Float]? {
        guard expectedCount > 0 else { return nil }

        let infoURL = packageURL.appendingPathComponent(infoFileName)
        guard FileManager.default.fileExists(atPath: infoURL.path) else {
            return nil
        }

        let document = try loadXMLDocument(at: infoURL)
        guard let root = document.rootElement() else {
            throw MFFReaderError.invalidXML(infoURL, "missing XML root element")
        }

        for calibration in descendants(named: "calibration", in: root) {
            let children = (calibration.children ?? []).compactMap { $0 as? XMLElement }
            let type = children
                .first(where: { sanitizedTagName($0.name) == "type" })?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard type?.caseInsensitiveCompare(calibrationType) == .orderedSame else {
                continue
            }

            if let rawBeginTime = children
                .first(where: { sanitizedTagName($0.name) == "beginTime" })?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let beginTime = Double(rawBeginTime),
               abs(beginTime) > 0.000001 {
                continue
            }

            let channelElements = descendants(named: "ch", in: calibration)
            guard !channelElements.isEmpty else {
                continue
            }

            var factors = Array(repeating: defaultValue, count: expectedCount)
            var sequentialChannelNumber = 1
            var appliedAnyFactor = false

            for channelElement in channelElements {
                defer { sequentialChannelNumber += 1 }

                guard let rawValue = channelElement.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let value = Float(rawValue),
                      value.isFinite else {
                    continue
                }

                let channelNumber = calibrationChannelNumber(from: channelElement) ?? sequentialChannelNumber
                guard (1...expectedCount).contains(channelNumber) else {
                    continue
                }

                factors[channelNumber - 1] = value
                appliedAnyFactor = true
            }

            if appliedAnyFactor {
                return factors
            }
        }

        return nil
    }

    private func calibrationChannelNumber(from element: XMLElement) -> Int? {
        for attribute in element.attributes ?? [] {
            let name = sanitizedTagName(attribute.name).lowercased()
            guard name == "n" || name == "number" || name == "channel",
                  let rawValue = attribute.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let number = Int(rawValue) else {
                continue
            }
            return number
        }
        return nil
    }

    private func applyCalibrationFactors(_ factors: [Float], to samples: inout [[Float]]) {
        let channelCount = min(samples.count, factors.count)
        guard channelCount > 0 else { return }

        for channel in 0..<channelCount {
            let factor = factors[channel]
            guard factor.isFinite, factor != 1 else { continue }
            for sample in samples[channel].indices {
                samples[channel][sample] *= factor
            }
        }
    }

    private func parseRecordingStartTime(in packageURL: URL) throws -> Date? {
        let infoURL = packageURL.appendingPathComponent("info.xml")
        guard FileManager.default.fileExists(atPath: infoURL.path) else {
            return nil
        }

        let document = try loadXMLDocument(at: infoURL)
        guard let root = document.rootElement(),
              let recordTimeElement = firstDescendant(named: "recordTime", in: root),
              let rawValue = recordTimeElement.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        return parseMFFDate(rawValue)
    }

    private func parseAcquisitionVersion(in packageURL: URL) throws -> String? {
        let infoURL = packageURL.appendingPathComponent("info.xml")
        guard FileManager.default.fileExists(atPath: infoURL.path) else {
            return nil
        }

        let document = try loadXMLDocument(at: infoURL)
        guard let root = document.rootElement(),
              let acquisitionVersionElement = firstDescendant(named: "acquisitionVersion", in: root),
              let rawValue = acquisitionVersionElement.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        return rawValue
    }

    private func parseHardwareFilterAdjustment(
        in packageURL: URL,
        infoFileName: String
    ) throws -> (isAdjusted: Bool, shiftMicroseconds: Int?) {
        let infoURL = packageURL.appendingPathComponent(infoFileName)
        guard FileManager.default.fileExists(atPath: infoURL.path) else {
            return (false, nil)
        }

        let document = try loadXMLDocument(at: infoURL)
        guard let root = document.rootElement(),
              let adjustmentElement = firstDescendant(named: "hardwareFilterAdjusted", in: root) else {
            return (false, nil)
        }

        let rawValue = adjustmentElement.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isAdjusted = parseXMLBoolean(rawValue)
        let shiftText = adjustmentElement.attributes?
            .first(where: { sanitizedTagName($0.name) == "shiftMicroseconds" })?
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shiftMicroseconds = shiftText.flatMap { Int($0) }

        return (isAdjusted, shiftMicroseconds)
    }

    private func acquisitionVersionIndicatesAntiAliasCorrection(_ value: String) -> Bool {
        guard let components = versionComponents(from: value) else {
            return false
        }
        return version(components, isAtLeast: [5, 2])
    }

    private func versionComponents(from value: String) -> [Int]? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(trimmed.prefix { $0.isNumber || $0 == "." })
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !prefix.isEmpty else {
            return nil
        }

        let components = prefix.split(separator: ".").compactMap { Int($0) }
        return components.isEmpty ? nil : components
    }

    private func version(_ lhs: [Int], isAtLeast rhs: [Int]) -> Bool {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let lhsComponent = index < lhs.count ? lhs[index] : 0
            let rhsComponent = index < rhs.count ? rhs[index] : 0
            if lhsComponent != rhsComponent {
                return lhsComponent > rhsComponent
            }
        }
        return true
    }

    private func parseXMLBoolean(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes":
            return true
        default:
            return false
        }
    }

    private func parseChannelNames(in packageURL: URL, expectedCount: Int) throws -> [String]? {
        let layoutURL = packageURL.appendingPathComponent("sensorLayout.xml")
        guard expectedCount > 0, FileManager.default.fileExists(atPath: layoutURL.path) else {
            return nil
        }

        let document = try loadXMLDocument(at: layoutURL)
        guard let root = document.rootElement() else {
            throw MFFReaderError.invalidXML(layoutURL, "missing XML root element")
        }

        var names = Array(repeating: "", count: expectedCount)
        // Sensor numbers the layout enumerates for signal channels, labelled or not.
        var numberedChannels = Set<Int>()
        for sensor in descendants(named: "sensor", in: root) {
            let children = (sensor.children ?? []).compactMap { $0 as? XMLElement }
            let number = children
                .first(where: { sanitizedTagName($0.name) == "number" })?
                .stringValue
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let type = children
                .first(where: { sanitizedTagName($0.name) == "type" })?
                .stringValue
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let name = children
                .first(where: { sanitizedTagName($0.name) == "name" || sanitizedTagName($0.name) == "label" })?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Type 0 is a recording electrode and type 1 the reference (VREF/Cz);
            // both occupy a signal channel. Higher types are fiducials/COM and
            // are not in the signal.
            guard (type == nil || type == 0 || type == 1),
                  let number,
                  (1...expectedCount).contains(number) else {
                continue
            }
            numberedChannels.insert(number)
            if let name, !name.isEmpty {
                names[number - 1] = name
            }
        }

        // EGI HydroCel layouts identify electrodes by number and leave <name>
        // blank (only the reference, VREF, is labelled). When the layout still
        // enumerates every signal channel the identity is well defined, so fill
        // the blanks with the conventional E{n} labels — combining runs of the
        // same net depends on names being present and comparable.
        if numberedChannels.count == expectedCount {
            return names.enumerated().map { index, name in
                name.isEmpty ? "E\(index + 1)" : name
            }
        }

        guard names.contains(where: { !$0.isEmpty }) else {
            return nil
        }
        return names.enumerated().map { index, name in
            name.isEmpty ? "Ch \(index + 1)" : name
        }
    }

    /// Loads the peripheral/physiological (PNS) signal file (e.g. ECG, EMG,
    /// respiration) if the package contains one. These channels live in a
    /// separate `signal*.bin` whose `info*.xml` declares the `PNSData` type, with
    /// channel names in `pnsSet.xml`. Returns nil when there is no PNS signal.
    func loadPNSSignal(
        from packageURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> MFFSignalData? {
        let packageURL = try validatedPackageURL(from: packageURL)
        progress?(0.01)
        let signalFiles = try binFiles(in: packageURL)

        var descriptor: (signalURL: URL, infoFileName: String, signalType: String)?
        for fileName in signalFiles {
            let signalURL = packageURL.appendingPathComponent(fileName)
            let type = (try? parseSignalType(for: signalURL, in: packageURL)) ?? nil
            if let type, type.range(of: "pns", options: .caseInsensitive) != nil {
                descriptor = (signalURL, signalInfoFileName(for: signalURL), type)
                break
            }
        }
        guard let descriptor else { return nil }

        let signalData = try parseSignal(from: descriptor.signalURL) { fraction in
            progress?(0.02 + 0.82 * fraction)
        }
        guard signalData.numberOfChannels > 0, signalData.totalSamples > 0 else { return nil }

        progress?(0.86)
        var samples = signalData.samples
        if let gcal = try parseCalibrationFactors(
            named: "GCAL",
            in: packageURL,
            infoFileName: descriptor.infoFileName,
            expectedCount: signalData.numberOfChannels
        ) {
            applyCalibrationFactors(gcal, to: &samples)
        }

        progress?(0.94)
        let recordingStartTime = try parseRecordingStartTime(in: packageURL)
        let channelNames = parsePNSChannelNames(in: packageURL, expectedCount: signalData.numberOfChannels)
        let positiveUpFlags = parsePNSPositiveUpFlags(in: packageURL, expectedCount: signalData.numberOfChannels)
        progress?(1)

        return MFFSignalData(
            signalURL: descriptor.signalURL,
            signalType: descriptor.signalType,
            numberOfChannels: signalData.numberOfChannels,
            samplingRate: signalData.samplingRate,
            duration: Double(signalData.totalSamples) / signalData.samplingRate,
            recordingStartTime: recordingStartTime,
            events: [],   // events belong to the primary (EEG) signal
            data: samples,
            channelNames: channelNames,
            positiveUpFlags: positiveUpFlags
        )
    }

    /// Parses PNS channel names from `pnsSet.xml`, keyed by the sensor `<number>`
    /// (0-based, matching the data channel order).
    private func parsePNSChannelNames(in packageURL: URL, expectedCount: Int) -> [String]? {
        let url = packageURL.appendingPathComponent("pnsSet.xml")
        guard expectedCount > 0, FileManager.default.fileExists(atPath: url.path),
              let document = try? loadXMLDocument(at: url),
              let root = document.rootElement() else {
            return nil
        }

        var names = Array(repeating: "", count: expectedCount)
        for sensor in descendants(named: "sensor", in: root) {
            let children = (sensor.children ?? []).compactMap { $0 as? XMLElement }
            let number = children
                .first { sanitizedTagName($0.name) == "number" }?
                .stringValue
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let name = children
                .first { sanitizedTagName($0.name) == "name" }?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let number, (0..<expectedCount).contains(number),
                  let name, !name.isEmpty else { continue }
            names[number] = name
        }

        guard names.contains(where: { !$0.isEmpty }) else { return nil }
        return names.enumerated().map { index, name in
            name.isEmpty ? "PNS \(index + 1)" : name
        }
    }

    /// Parses each sensor's `<positiveUp>` convention from `pnsSet.xml`, keyed
    /// by the sensor `<number>` (0-based, matching the data channel order).
    /// Defaults missing entries to `true` (EGI's own convention when the tag
    /// is absent), so callers only need to flip channels explicitly marked
    /// negative-up.
    private func parsePNSPositiveUpFlags(in packageURL: URL, expectedCount: Int) -> [Bool]? {
        let url = packageURL.appendingPathComponent("pnsSet.xml")
        guard expectedCount > 0, FileManager.default.fileExists(atPath: url.path),
              let document = try? loadXMLDocument(at: url),
              let root = document.rootElement() else {
            return nil
        }

        var flags = Array(repeating: true, count: expectedCount)
        var sawAnyFlag = false
        for sensor in descendants(named: "sensor", in: root) {
            let children = (sensor.children ?? []).compactMap { $0 as? XMLElement }
            let number = children
                .first { sanitizedTagName($0.name) == "number" }?
                .stringValue
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard let positiveUpString = children
                .first(where: { sanitizedTagName($0.name) == "positiveUp" })?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                let number, (0..<expectedCount).contains(number)
            else { continue }
            sawAnyFlag = true
            flags[number] = (positiveUpString as NSString).boolValue
        }

        return sawAnyFlag ? flags : nil
    }

    /// Reads only the package's events — no sample data.
    ///
    /// The batch preflight has to know which beat codes a file carries before
    /// deciding whether a recorded PCA-S step can run against it (ROADMAP SI-3),
    /// and loading whole recordings to answer that would make opening the sheet
    /// cost gigabytes.
    func loadEvents(from packageURL: URL) throws -> [MFFEvent] {
        try parseEvents(in: try validatedPackageURL(from: packageURL))
    }

    private func parseEvents(in packageURL: URL) throws -> [MFFEvent] {
        let eventFiles = try xmlFiles(in: packageURL)
            .filter { $0.hasPrefix("Events") }
        let recordingStartTime = try parseRecordingStartTime(in: packageURL)

        var events: [MFFEvent] = []
        var seenIDs = Set<String>()

        for fileName in eventFiles {
            let xmlURL = packageURL.appendingPathComponent(fileName)
            let document = try loadXMLDocument(at: xmlURL)
            guard let root = document.rootElement() else {
                throw MFFReaderError.invalidXML(xmlURL, "missing XML root element")
            }

            collectEvents(
                from: root,
                sourceFile: fileName,
                recordingStartTime: recordingStartTime,
                into: &events,
                seenIDs: &seenIDs
            )
        }

        return events.sorted { $0.beginTimeSeconds < $1.beginTimeSeconds }
    }

    private func collectEvents(
        from element: XMLElement,
        sourceFile: String,
        recordingStartTime: Date?,
        into events: inout [MFFEvent],
        seenIDs: inout Set<String>
    ) {
        let children = (element.children ?? []).compactMap { $0 as? XMLElement }
        let directCode = children.first(where: { sanitizedTagName($0.name) == "code" })?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directLabel = children.first(where: { sanitizedTagName($0.name) == "label" })?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directDescription = children.first(where: { sanitizedTagName($0.name) == "description" })?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directCell = eventCellValue(from: element)
        let directBeginTime = children.first(where: { sanitizedTagName($0.name) == "beginTime" })?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // MFF <duration> is in microseconds; keep only positive values.
        let durationString = children
            .first(where: { sanitizedTagName($0.name) == "duration" })?
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var directDuration: Double? = nil
        if let durationString, let micros = Double(durationString), micros > 0 {
            directDuration = micros / 1_000_000.0
        }

        if let directCode, !directCode.isEmpty,
           let directBeginTime, !directBeginTime.isEmpty,
           let beginTimeSeconds = resolveEventBeginTimeSeconds(directBeginTime, recordingStartTime: recordingStartTime) {
            let eventID = "\(sourceFile)|\(directCode)|\(directBeginTime)"
            if seenIDs.insert(eventID).inserted {
                events.append(
                    MFFEvent(
                        id: eventID,
                        code: directCode,
                        label: directLabel,
                        eventDescription: directDescription,
                        cell: directCell,
                        beginTimeSeconds: beginTimeSeconds,
                        rawBeginTime: directBeginTime,
                        sourceFile: sourceFile,
                        durationSeconds: directDuration
                    )
                )
            }
        }

        for child in children {
            collectEvents(
                from: child,
                sourceFile: sourceFile,
                recordingStartTime: recordingStartTime,
                into: &events,
                seenIDs: &seenIDs
            )
        }
    }

    private func eventCellValue(from eventElement: XMLElement) -> String? {
        let keyElements = (eventElement.children ?? [])
            .compactMap { $0 as? XMLElement }
            .filter { sanitizedTagName($0.name) == "keys" }
            .flatMap { keysElement in
                (keysElement.children ?? [])
                    .compactMap { $0 as? XMLElement }
                    .filter { sanitizedTagName($0.name) == "key" }
            }
        for key in keyElements {
            let keyChildren = (key.children ?? []).compactMap { $0 as? XMLElement }
            let keyCode = keyChildren.first { sanitizedTagName($0.name) == "keyCode" }?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard let keyCode, ["cel#", "#cel", "cell"].contains(keyCode) else { continue }
            let value = keyChildren.first { sanitizedTagName($0.name) == "data" }?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func resolveEventBeginTimeSeconds(_ rawValue: String, recordingStartTime: Date?) -> Double? {
        if let numericValue = Double(rawValue) {
            if numericValue > 1_000_000 {
                return numericValue / 1_000_000
            }
            return numericValue
        }

        if let eventDate = parseMFFDate(rawValue), let recordingStartTime {
            return eventDate.timeIntervalSince(recordingStartTime)
        }

        return nil
    }

    // MARK: - On-disk epochs / averaged data

    private struct OnDiskEpochInfo {
        let segments: [EpochSegment]
        let events: [MFFEvent]
        let isAveraged: Bool
        let isGrandAverage: Bool
    }

    private struct EpochBlockRange {
        let beginTimeMicroseconds: Double
        let endTimeMicroseconds: Double
        let startSample: Int
        let endSampleExclusive: Int
    }

    private struct CategorySegment {
        let category: String
        let beginTimeMicroseconds: Double
        let endTimeMicroseconds: Double
        let eventTimeMicroseconds: Double
        let contributingEpochCount: Int
        /// True when the segment is an EGI `<seg><name>Average</name>`. Grand
        /// averages mark every seg this way with `#seg == 1` (each contributor is
        /// one subject/group average, not N trials).
        let isAverage: Bool
        /// Contributing subject/group id from the `subj` key, when present (grand
        /// averages carry one seg per subject/group under each category).
        let subject: String?
    }

    /// Reads `epochs.xml` + `categories.xml`. When the package is segmented or
    /// category-averaged, returns the per-epoch `EpochSegment`s mapped onto the
    /// concatenated sample timeline, plus one stimulus-locked marker per epoch.
    /// Returns nil for ordinary continuous recordings.
    private func parseOnDiskEpochs(
        in packageURL: URL,
        blockSampleCounts: [Int],
        samplingRate: Double
    ) throws -> OnDiskEpochInfo? {
        guard samplingRate > 0, !blockSampleCounts.isEmpty else { return nil }

        let categorySegments = try parseCategorySegments(in: packageURL)
        // Continuous recordings have no category segments. A lone segment that
        // spans the whole recording (e.g. a single un-averaged "Category 1") is
        // treated as continuous so we don't draw a spurious epoch boundary.
        guard categorySegments.count >= 2
            || categorySegments.contains(where: { $0.contributingEpochCount > 1 }) else {
            return nil
        }

        let epochs = try parseEpochRanges(in: packageURL, blockSampleCounts: blockSampleCounts)
        guard !epochs.isEmpty else { return nil }

        let colorIndices = categoryColorIndices(for: categorySegments.map(\.category))

        var segments: [EpochSegment] = []
        for segment in categorySegments {
            // Match by the segment midpoint so a segment that starts exactly on an
            // epoch boundary isn't ambiguously assigned to the preceding epoch.
            let midpoint = (segment.beginTimeMicroseconds + segment.endTimeMicroseconds) / 2
            guard let epoch = epochs.first(where: {
                midpoint >= $0.beginTimeMicroseconds && midpoint < $0.endTimeMicroseconds
            }) else { continue }

            let startSample = sampleIndex(
                forMicroseconds: segment.beginTimeMicroseconds,
                in: epoch,
                samplingRate: samplingRate
            )
            let endExclusive = sampleIndex(
                forMicroseconds: segment.endTimeMicroseconds,
                in: epoch,
                samplingRate: samplingRate
            )
            let stimulusSample = sampleIndex(
                forMicroseconds: segment.eventTimeMicroseconds,
                in: epoch,
                samplingRate: samplingRate
            )
            guard endExclusive > startSample else { continue }

            let endSample = endExclusive - 1
            let stimulusOffset = min(max(stimulusSample - startSample, 0), endSample - startSample)
            segments.append(
                EpochSegment(
                    startSample: startSample,
                    endSample: endSample,
                    stimulusOffsetSamples: stimulusOffset,
                    category: segment.category,
                    sourceCode: segment.category,
                    sourceTimeSeconds: Double(startSample + stimulusOffset) / samplingRate,
                    colorIndex: colorIndices[segment.category] ?? 0,
                    contributingEpochCount: segment.contributingEpochCount,
                    subject: segment.subject
                )
            )
        }

        guard !segments.isEmpty else { return nil }
        segments.sort { $0.startSample < $1.startSample }

        let events = segments.enumerated().map { index, segment in
            let stimulusTime = segment.sourceTimeSeconds
            return MFFEvent(
                id: "epoch-\(index)-\(segment.category)",
                code: segment.category,
                beginTimeSeconds: stimulusTime,
                rawBeginTime: String(format: "%.6f", stimulusTime),
                sourceFile: "Epochs"
            )
        }

        // A file is averaged when every segment is either a multi-trial average
        // (#seg > 1) OR an EGI `<name>Average</name>` segment (grand averages and
        // singleton category averages use #seg == 1, so the name is the reliable
        // marker). Older EVA exports omitted that name; recover those from the
        // last recorded PSA segment step when its persisted `average` option was on.
        let evaScript = EVAProcessingScriptXML.read(fromPackage: packageURL)
        let legacyEVAAverage = evaScript?
            .steps
            .last(where: { $0.operation == .segment })?
            .parameters["average"] == "true"
        // `eva.xml`'s `fileType` is authoritative when present: EVA stamps what it
        // actually wrote, so there is no need to re-infer it from the EGI
        // structure. Everything below is the fallback for packages written before
        // that field, or by another tool.
        let declaredType = evaScript?.fileType
        let isAveraged = declaredType.map { $0 == .averaged || $0 == .grandAverage }
            ?? (legacyEVAAverage
                || categorySegments.allSatisfy { $0.contributingEpochCount > 1 || $0.isAverage })
        // Grand average = averaged AND the same category is contributed by more
        // than one segment (one per subject/group), or segments carry subject ids.
        let distinctCategories = Set(categorySegments.map(\.category)).count
        let categoriesRepeat = distinctCategories < categorySegments.count
        let hasSubjects = categorySegments.contains { $0.subject != nil }
        let isGrandAverage = declaredType.map { $0 == .grandAverage }
            ?? (isAveraged && (categoriesRepeat || hasSubjects))

        return OnDiskEpochInfo(
            segments: segments,
            events: events,
            isAveraged: isAveraged,
            isGrandAverage: isGrandAverage
        )
    }

    /// Assigns a stable color index to each category in first-appearance order.
    private func categoryColorIndices(for categories: [String]) -> [String: Int] {
        var indices: [String: Int] = [:]
        for category in categories where indices[category] == nil {
            indices[category] = indices.count
        }
        return indices
    }

    /// Maps a microsecond timestamp within an epoch to a concatenated sample
    /// index, clamped to the epoch's sample span.
    private func sampleIndex(
        forMicroseconds microseconds: Double,
        in epoch: EpochBlockRange,
        samplingRate: Double
    ) -> Int {
        let offsetSeconds = (microseconds - epoch.beginTimeMicroseconds) / 1_000_000
        let sample = epoch.startSample + Int((offsetSeconds * samplingRate).rounded())
        return min(max(sample, epoch.startSample), epoch.endSampleExclusive)
    }

    private func parseEpochRanges(
        in packageURL: URL,
        blockSampleCounts: [Int]
    ) throws -> [EpochBlockRange] {
        let epochsURL = packageURL.appendingPathComponent("epochs.xml")
        guard FileManager.default.fileExists(atPath: epochsURL.path) else { return [] }

        let document = try loadXMLDocument(at: epochsURL)
        guard let root = document.rootElement() else { return [] }

        // Prefix sums of samples preceding each block boundary (0-based blocks).
        var prefix = [Int](repeating: 0, count: blockSampleCounts.count + 1)
        for index in blockSampleCounts.indices {
            prefix[index + 1] = prefix[index] + blockSampleCounts[index]
        }

        var ranges: [EpochBlockRange] = []
        for epoch in descendants(named: "epoch", in: root) {
            let children = (epoch.children ?? []).compactMap { $0 as? XMLElement }
            func value(_ name: String) -> Double? {
                guard let raw = children.first(where: { sanitizedTagName($0.name) == name })?
                    .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                return Double(raw)
            }
            guard let beginTime = value("beginTime"),
                  let endTime = value("endTime"),
                  let firstBlock = value("firstBlock").map({ Int($0) }) ?? nil,
                  let lastBlock = value("lastBlock").map({ Int($0) }) ?? nil,
                  firstBlock >= 1, lastBlock >= firstBlock,
                  lastBlock <= blockSampleCounts.count else {
                continue
            }
            ranges.append(
                EpochBlockRange(
                    beginTimeMicroseconds: beginTime,
                    endTimeMicroseconds: endTime,
                    startSample: prefix[firstBlock - 1],
                    endSampleExclusive: prefix[lastBlock]
                )
            )
        }
        return ranges
    }

    private func parseCategorySegments(in packageURL: URL) throws -> [CategorySegment] {
        let categoriesURL = packageURL.appendingPathComponent("categories.xml")
        guard FileManager.default.fileExists(atPath: categoriesURL.path) else { return [] }

        let document = try loadXMLDocument(at: categoriesURL)
        guard let root = document.rootElement() else { return [] }

        var segments: [CategorySegment] = []
        for category in descendants(named: "cat", in: root) {
            let categoryChildren = (category.children ?? []).compactMap { $0 as? XMLElement }
            let name = categoryChildren.first { sanitizedTagName($0.name) == "name" }?
                .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let categoryName = (name?.isEmpty == false) ? name! : "Category"

            for seg in descendants(named: "seg", in: category) {
                let children = (seg.children ?? []).compactMap { $0 as? XMLElement }
                func value(_ tag: String) -> Double? {
                    guard let raw = children.first(where: { sanitizedTagName($0.name) == tag })?
                        .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                    return Double(raw)
                }
                guard let beginTime = value("beginTime"),
                      let endTime = value("endTime"), endTime > beginTime else {
                    continue
                }
                let eventTime = value("evtBegin") ?? beginTime
                let segName = children.first { sanitizedTagName($0.name) == "name" }?
                    .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                segments.append(
                    CategorySegment(
                        category: categoryName,
                        beginTimeMicroseconds: beginTime,
                        endTimeMicroseconds: endTime,
                        eventTimeMicroseconds: eventTime,
                        contributingEpochCount: segmentContributingCount(in: seg),
                        isAverage: segName?.caseInsensitiveCompare("Average") == .orderedSame,
                        subject: segmentKeyData(in: seg, keyCode: "subj")
                    )
                )
            }
        }
        return segments
    }

    /// Returns the `<data>` value of a segment `<key>` with the given `keyCode`
    /// (e.g. `subj`, `FILE`), or nil when absent.
    private func segmentKeyData(in seg: XMLElement, keyCode: String) -> String? {
        for key in descendants(named: "key", in: seg) {
            let keyChildren = (key.children ?? []).compactMap { $0 as? XMLElement }
            let code = keyChildren.first { sanitizedTagName($0.name) == "keyCode" }?
                .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard code == keyCode else { continue }
            let data = keyChildren.first { sanitizedTagName($0.name) == "data" }?
                .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data, !data.isEmpty { return data }
        }
        return nil
    }

    /// The `#seg` key records how many trials were averaged into a segment;
    /// absent (value 1) for plain segmented (un-averaged) data.
    private func segmentContributingCount(in seg: XMLElement) -> Int {
        for key in descendants(named: "key", in: seg) {
            let keyChildren = (key.children ?? []).compactMap { $0 as? XMLElement }
            let code = keyChildren.first { sanitizedTagName($0.name) == "keyCode" }?
                .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard code == "#seg" else { continue }
            if let raw = keyChildren.first(where: { sanitizedTagName($0.name) == "data" })?
                .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                let count = Int(raw), count > 0 {
                return count
            }
        }
        return 1
    }

    private func parseSignal(
        from signalURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> ParsedSignal {
        let handle = try FileHandle(forReadingFrom: signalURL)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        progress?(0)

        var lastHeader: SignalHeader?
        var allChannels: [[Float]] = []
        var totalSamples = 0
        var blockSampleCounts: [Int] = []
        var expectedChannelCount: Int?
        var expectedSamplingRate: Double?
        var lastReportedProgress = 0.0

        while try handle.offset() < fileSize {
            try Task.checkCancellation()
            let flag = try Int(readInt32(from: handle, signalURL: signalURL))

            let header: SignalHeader
            if flag == 0 {
                guard let previousHeader = lastHeader else {
                    throw MFFReaderError.invalidBinaryData(signalURL, "encountered a data block before any header block")
                }
                header = previousHeader
            } else if flag == 1 {
                header = try readHeader(from: handle, signalURL: signalURL)
                lastHeader = header
            } else {
                throw MFFReaderError.invalidBinaryData(signalURL, "unexpected block flag \(flag)")
            }

            if let channelCount = expectedChannelCount, channelCount != header.numberOfChannels {
                throw MFFReaderError.inconsistentBlockConfiguration
            }

            if let samplingRate = expectedSamplingRate, samplingRate != header.samplingRate {
                throw MFFReaderError.inconsistentBlockConfiguration
            }

            expectedChannelCount = header.numberOfChannels
            expectedSamplingRate = header.samplingRate

            if allChannels.isEmpty {
                allChannels = Array(repeating: [], count: header.numberOfChannels)
            }

            let data = try readExactly(from: handle, byteCount: header.blockSize, signalURL: signalURL)
            let sampleMatrix = try decodeSamples(
                from: data,
                numberOfChannels: header.numberOfChannels,
                numberOfSamplesPerChannel: header.numberOfSamples,
                signalURL: signalURL
            )

            for index in sampleMatrix.indices {
                try Task.checkCancellation()
                allChannels[index].append(contentsOf: sampleMatrix[index])
            }

            totalSamples += header.numberOfSamples
            blockSampleCounts.append(header.numberOfSamples)

            if fileSize > 0 {
                let fraction = Double(try handle.offset()) / Double(fileSize)
                if fraction - lastReportedProgress >= 0.005 || fraction >= 1 {
                    lastReportedProgress = fraction
                    progress?(min(max(fraction, 0), 1))
                }
            }
        }

        guard let numberOfChannels = expectedChannelCount, let samplingRate = expectedSamplingRate else {
            throw MFFReaderError.emptySignal
        }

        progress?(1)
        return ParsedSignal(
            numberOfChannels: numberOfChannels,
            samplingRate: samplingRate,
            totalSamples: totalSamples,
            samples: allChannels,
            blockSampleCounts: blockSampleCounts
        )
    }

    private func readHeader(from handle: FileHandle, signalURL: URL) throws -> SignalHeader {
        let headerSize = try Int(readInt32(from: handle, signalURL: signalURL))
        let blockSize = try Int(readInt32(from: handle, signalURL: signalURL))
        let numberOfChannels = try Int(readInt32(from: handle, signalURL: signalURL))

        guard headerSize >= 20 else {
            throw MFFReaderError.invalidBinaryData(signalURL, "header size \(headerSize) is too small")
        }
        guard blockSize >= 0 else {
            throw MFFReaderError.invalidBinaryData(signalURL, "negative block size \(blockSize)")
        }
        guard numberOfChannels > 0 else {
            throw MFFReaderError.invalidBinaryData(signalURL, "invalid channel count \(numberOfChannels)")
        }

        _ = try readExactly(from: handle, byteCount: numberOfChannels * 4, signalURL: signalURL)

        let firstRateDepth = try Int(readInt32(from: handle, signalURL: signalURL))
        let (samplingRate, sampleDepth) = decodeRateDepth(firstRateDepth)
        guard sampleDepth == 32 else {
            throw MFFReaderError.unsupportedSampleDepth(sampleDepth)
        }

        if numberOfChannels > 1 {
            _ = try readExactly(from: handle, byteCount: (numberOfChannels - 1) * 4, signalURL: signalURL)
        }

        let consumedHeaderBytes = 16 + (numberOfChannels * 8)
        if headerSize < consumedHeaderBytes {
            throw MFFReaderError.invalidBinaryData(signalURL, "header size \(headerSize) is smaller than required \(consumedHeaderBytes)")
        }

        if consumedHeaderBytes < headerSize {
            _ = try readExactly(from: handle, byteCount: headerSize - consumedHeaderBytes, signalURL: signalURL)
        }

        let bytesPerChannel = numberOfChannels * MemoryLayout<Float>.size
        guard blockSize % bytesPerChannel == 0 else {
            throw MFFReaderError.invalidBinaryData(signalURL, "block size \(blockSize) is not divisible by channel width \(bytesPerChannel)")
        }

        return SignalHeader(
            headerSize: headerSize,
            blockSize: blockSize,
            numberOfChannels: numberOfChannels,
            numberOfSamples: blockSize / bytesPerChannel,
            samplingRate: Double(samplingRate)
        )
    }

    private func decodeSamples(
        from data: Data,
        numberOfChannels: Int,
        numberOfSamplesPerChannel: Int,
        signalURL: URL
    ) throws -> [[Float]] {
        let expectedByteCount = numberOfChannels * numberOfSamplesPerChannel * MemoryLayout<Float>.size
        guard data.count == expectedByteCount else {
            throw MFFReaderError.invalidBinaryData(signalURL, "expected \(expectedByteCount) sample bytes but found \(data.count)")
        }

        var channels = Array(
            repeating: Array(repeating: Float(0), count: numberOfSamplesPerChannel),
            count: numberOfChannels
        )

        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for channel in 0..<numberOfChannels {
                let channelBase = channel * numberOfSamplesPerChannel * 4
                for sample in 0..<numberOfSamplesPerChannel {
                    let offset = channelBase + sample * 4
                    let word = UInt32(bytes[offset])
                        | (UInt32(bytes[offset + 1]) << 8)
                        | (UInt32(bytes[offset + 2]) << 16)
                        | (UInt32(bytes[offset + 3]) << 24)
                    channels[channel][sample] = Float(bitPattern: word)
                }
            }
        }

        return channels
    }

    private func decodeRateDepth(_ value: Int) -> (samplingRate: Int, sampleDepth: Int) {
        let unsigned = UInt32(bitPattern: Int32(value))
        return (Int(unsigned >> 8), Int(unsigned & 0xFF))
    }

    private func readInt32(from handle: FileHandle, signalURL: URL) throws -> Int32 {
        let data = try readExactly(from: handle, byteCount: MemoryLayout<Int32>.size, signalURL: signalURL)
        return data.withUnsafeBytes { rawBuffer in
            let value = rawBuffer.load(as: Int32.self)
            return Int32(littleEndian: value)
        }
    }

    private func readExactly(from handle: FileHandle, byteCount: Int, signalURL: URL) throws -> Data {
        let data = try handle.read(upToCount: byteCount) ?? Data()
        guard data.count == byteCount else {
            throw MFFReaderError.invalidBinaryData(signalURL, "unexpected end of file while reading \(byteCount) bytes")
        }
        return data
    }

    private func loadXMLDocument(at url: URL) throws -> XMLDocument {
        do {
            let data = try Data(contentsOf: url)
            return try XMLDocument(data: data, options: [.documentTidyXML])
        } catch {
            throw MFFReaderError.invalidXML(url, error.localizedDescription)
        }
    }

    private func firstDescendant(named name: String, in element: XMLElement) -> XMLElement? {
        if sanitizedTagName(element.name) == name {
            return element
        }

        for child in element.children ?? [] {
            guard let childElement = child as? XMLElement else {
                continue
            }
            if let match = firstDescendant(named: name, in: childElement) {
                return match
            }
        }

        return nil
    }

    private func descendants(named name: String, in element: XMLElement) -> [XMLElement] {
        var matches: [XMLElement] = []
        if sanitizedTagName(element.name) == name {
            matches.append(element)
        }
        for child in element.children ?? [] {
            guard let childElement = child as? XMLElement else {
                continue
            }
            matches.append(contentsOf: descendants(named: name, in: childElement))
        }
        return matches
    }

    private func sanitizedTagName(_ name: String?) -> String {
        guard let name else {
            return ""
        }
        return name.components(separatedBy: ":").last ?? name
    }

    private func parseMFFDate(_ value: String) -> Date? {
        // Both fractional-second parsers Foundation offers stop at milliseconds:
        // ISO8601DateFormatter's `.withFractionalSeconds` truncates further
        // digits, and DateFormatter carries millisecond internal precision. At
        // 1024 Hz a sample is 976.5625 µs, so millisecond truncation on the read
        // side alone is enough to displace an event by half a sample and trip
        // EVA's TR-spacing check — the writer's precision cannot rescue it.
        //
        // So split the fraction off, parse only the whole-second instant with
        // Foundation, and add the fraction back as a Double. `Date` resolves to
        // about 0.12 µs at present-day epochs, which is 1e-4 samples at 1024 Hz.
        let (withoutFraction, fractionalSeconds) = Self.splitFractionalSeconds(value)
        guard let whole = parseWholeSecondMFFDate(withoutFraction) else { return nil }
        return fractionalSeconds == 0 ? whole : whole.addingTimeInterval(fractionalSeconds)
    }

    /// Removes `.ffffff` from an ISO-8601 string, returning the remainder and
    /// the fraction it carried. Digit count is not assumed: MFF files in the
    /// wild use three, six, and nine.
    static func splitFractionalSeconds(_ value: String) -> (String, TimeInterval) {
        guard let dot = value.firstIndex(of: ".") else { return (value, 0) }
        var digits = ""
        var index = value.index(after: dot)
        while index < value.endIndex, value[index].isNumber {
            digits.append(value[index])
            index = value.index(after: index)
        }
        guard !digits.isEmpty, let scaled = Double(digits) else { return (value, 0) }
        let fraction = scaled / pow(10, Double(digits.count))
        return (String(value[value.startIndex..<dot]) + String(value[index...]), fraction)
    }

    private func parseWholeSecondMFFDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return date
        }

        // A numeric offset without the colon (`-0400`), which ISO8601DateFormatter
        // rejects. The old code reached this branch by length; match the shape.
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return fallback.date(from: value)
    }
}

private struct SignalHeader {
    let headerSize: Int
    let blockSize: Int
    let numberOfChannels: Int
    let numberOfSamples: Int
    let samplingRate: Double
}

private struct ParsedSignal {
    let numberOfChannels: Int
    let samplingRate: Double
    let totalSamples: Int
    let samples: [[Float]]
    /// Number of samples contributed by each successive signal block, in order.
    /// One entry per block; the boundaries delimit on-disk epochs.
    let blockSampleCounts: [Int]
}
