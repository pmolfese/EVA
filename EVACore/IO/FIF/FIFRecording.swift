//
//  FIFRecording.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Native reading of the three shapes EEG data takes in a FIF file:
//
//  * **continuous** (`*_raw.fif`): `FIFF_DATA_BUFFER` tags inside `FIFFB_RAW_DATA`,
//    each holding `samples × channels` values in acquisition order.
//  * **epoched** (`*-epo.fif`): one `FIFF_EPOCH` matrix, `epochs × channels ×
//    samples`, with an event list and an event-name mapping.
//  * **averaged** (`*-ave.fif`): one `FIFFB_EVOKED` block per condition, each
//    with a `FIFF_EPOCH` matrix of `channels × samples`, a comment and `nave`.
//
//  All three share the measurement info in `FIFMeasurementInfo`, and all three
//  come out of here in the channel's own physical unit (volts, for EEG) with the
//  `range × cal` scaling applied — the same numbers `mne.io.read_raw_fif` and
//  friends produce. Conversion to EVA's microvolts happens at the import
//  boundary, not here.
//
//  Layout and scaling conventions follow MNE-Python (BSD-3): `mne/io/fiff/raw.py`
//  (buffers reshape as `(nsamp, nchan)` then transpose; `cals = range × cal`),
//  `mne/epochs.py` and `mne/evoked.py` (epoch matrices scale by `cal` alone).
//  Re-implemented, not copied.
//

import Foundation

nonisolated struct FIFRecording: Sendable {

    enum Content: Sendable, Equatable {
        case continuous
        case epoched
        case averaged
    }

    /// One epoch or one condition average, as a `channels × samples` block.
    struct Segment: Sendable {
        /// Condition name: the event-id label for epochs, the evoked comment for
        /// averages, empty when the file names nothing.
        var name: String
        /// Numeric event code, for epochs.
        var code: Int?
        /// Sample of the original continuous recording this segment was cut at,
        /// when the file records one.
        var sourceSample: Int?
        /// Trials contributing to an average (`nave`); 1 for a single epoch.
        var contributingCount: Int
        /// `channels × samples`, in the channel's own unit.
        var data: [[Double]]
    }

    var info: FIFMeasurementInfo
    var content: Content
    /// Continuous recordings only: `channels × samples`, in the channel's unit.
    var samples: [[Double]]
    /// Epoched and averaged recordings.
    var segments: [Segment]
    /// Time of the first sample of each segment relative to its event, seconds.
    /// Negative for the usual pre-stimulus baseline.
    var segmentStartSeconds: Double
    var annotations: [FIFAnnotation]
    /// Notes worth showing the user: unapplied projectors, skipped buffers,
    /// dropped epochs, anything that makes what we loaded differ from what the
    /// file nominally contains.
    var warnings: [String]
    /// True when a `sampleLimit` stopped the read early — a preview reads the
    /// first few seconds of a recording, not all of it.
    var isTruncated: Bool = false
    /// Samples the file actually holds, whether or not they were decoded.
    /// Counted from the buffer tags' sizes, so a truncated read still reports
    /// the recording's true length rather than the length of the peek.
    var totalSampleCount: Int = 0

    var sampleCount: Int {
        content == .continuous ? (samples.first?.count ?? 0) : (segments.first?.data.first?.count ?? 0)
    }

    // MARK: - Reading

    /// - Parameter sampleLimit: stop after this many continuous samples. For
    ///   previews and thumbnails, where reading a two-gigabyte recording to draw
    ///   a five-second sparkline would be absurd. `nil` reads everything.
    static func read(from url: URL, sampleLimit: Int? = nil) throws -> FIFRecording {
        let reader = try FIFReader(url: url)
        let info = try FIFMeasurementInfo.read(reader)
        var warnings: [String] = []

        for projector in info.projectors where projector.isActive {
            warnings.append("The file carries an active SSP projector (\(projector.description)); EVA does not apply projectors, so these samples are the unprojected data.")
        }
        if let odd = info.channels.first(where: { $0.unitMultiplier != 0 }) {
            warnings.append("Channel \(odd.name) declares a unit multiplier of 10^\(odd.unitMultiplier); like MNE, EVA scales by range × cal only, so this channel may be off by that factor.")
        }
        if let next = reader.first(kind: FIF.refFileName)?.stringValue, !next.isEmpty {
            warnings.append("This is one part of a split recording and continues in \(next); EVA has loaded this part only.")
        }

        let annotations = FIFAnnotation.read(reader, samplingRate: info.samplingRate)

        // Averaged first: an -ave.fif also has FIFFB_PROCESSED_DATA, so the more
        // specific block wins.
        if !reader.blocks(kind: FIF.blockEvoked).isEmpty {
            let (segments, tmin) = try readEvoked(reader, info: info, warnings: &warnings)
            return FIFRecording(info: info, content: .averaged, samples: [], segments: segments,
                                segmentStartSeconds: tmin, annotations: annotations, warnings: warnings)
        }
        if !reader.blocks(kind: FIF.blockMNEEpochs).isEmpty {
            let (segments, tmin) = try readEpochs(reader, info: info, warnings: &warnings)
            return FIFRecording(info: info, content: .epoched, samples: [], segments: segments,
                                segmentStartSeconds: tmin, annotations: annotations, warnings: warnings)
        }
        let (samples, total) = try readContinuous(reader, info: info, sampleLimit: sampleLimit, warnings: &warnings)
        let decoded = samples.first?.count ?? 0
        return FIFRecording(info: info, content: .continuous, samples: samples, segments: [],
                            segmentStartSeconds: 0, annotations: annotations, warnings: warnings,
                            isTruncated: decoded < total, totalSampleCount: total)
    }

    // MARK: - Continuous

    private static func readContinuous(_ reader: FIFReader, info: FIFMeasurementInfo,
                                       sampleLimit: Int? = nil,
                                       warnings: inout [String]) throws -> (samples: [[Double]], totalSamples: Int) {
        // Neuromag raw data lives in one of three equivalent blocks.
        let blockKinds = [FIF.blockRawData, FIF.blockContinuousData, FIF.blockIASRawData]
        guard let block = blockKinds.lazy.compactMap({ reader.blocks(kind: $0).first }).first else {
            throw FIF.Error.missing("raw data block")
        }
        let nchan = info.channels.count
        let calibration = info.channels.map(\.calibration)

        var channels = [[Double]](repeating: [], count: nchan)
        var bufferSamples = 0
        var pendingSkipBuffers = 0
        var totalSamples = 0
        var stoppedEarly = false

        for tag in block {
            if tag.kind == FIF.dataSkip {
                pendingSkipBuffers += tag.intValue
                continue
            }
            if tag.kind == FIF.dataSkipSamples {
                let samples = tag.intValue
                for c in 0..<nchan { channels[c].append(contentsOf: repeatElement(0, count: samples)) }
                warnings.append("\(samples) samples were not recorded (an acquisition skip) and are loaded as zeros.")
                continue
            }
            guard tag.kind == FIF.dataBuffer else { continue }
            // Count every buffer, decode only as many as asked for: the length of
            // the recording is knowable from the tag sizes alone, and a preview
            // that reads ten seconds must still say how long the file is.
            totalSamples += bufferSampleCount(tag, channels: nchan)
            if stoppedEarly { continue }
            if let limit = sampleLimit, (channels.first?.count ?? 0) >= limit {
                stoppedEarly = true
                continue
            }

            let values = try bufferValues(tag)
            guard values.count % nchan == 0 else {
                throw FIF.Error.unexpected("a data buffer holds \(values.count) values, which is not a multiple of \(nchan) channels")
            }
            let nsamp = values.count / nchan
            bufferSamples = max(bufferSamples, nsamp)

            if pendingSkipBuffers > 0 {
                let skipped = pendingSkipBuffers * (bufferSamples > 0 ? bufferSamples : nsamp)
                for c in 0..<nchan { channels[c].append(contentsOf: repeatElement(0, count: skipped)) }
                warnings.append("\(skipped) samples were not recorded (an acquisition skip) and are loaded as zeros.")
                pendingSkipBuffers = 0
            }

            // Buffers are sample-major: all channels of sample 0, then sample 1…
            for c in 0..<nchan {
                let cal = calibration[c]
                var column = [Double](repeating: 0, count: nsamp)
                for s in 0..<nsamp { column[s] = values[s * nchan + c] * cal }
                channels[c].append(contentsOf: column)
            }
        }
        guard channels.first?.isEmpty == false else { throw FIF.Error.missing("sample data") }
        return (channels, max(totalSamples, channels[0].count))
    }

    /// How many samples a buffer holds, from its size — no decoding.
    private static func bufferSampleCount(_ tag: FIFTag, channels: Int) -> Int {
        guard channels > 0 else { return 0 }
        let bytesPerValue: Int
        switch tag.baseType {
        case FIF.typeShort, FIF.typeDAUPack16: bytesPerValue = 2
        case FIF.typeDouble: bytesPerValue = 8
        default: bytesPerValue = 4
        }
        return tag.data.count / bytesPerValue / channels
    }

    /// A data buffer in any of the types Neuromag hardware writes.
    private static func bufferValues(_ tag: FIFTag) throws -> [Double] {
        switch tag.baseType {
        case FIF.typeFloat:
            let count = tag.data.count / 4
            return (0..<count).map { Double(tag.float32(at: $0 * 4)) }
        case FIF.typeInt:
            let count = tag.data.count / 4
            return (0..<count).map { Double(tag.int32(at: $0 * 4)) }
        case FIF.typeShort, FIF.typeDAUPack16:
            let count = tag.data.count / 2
            return (0..<count).map { Double(tag.int16(at: $0 * 2)) }
        case FIF.typeDouble:
            let count = tag.data.count / 8
            return (0..<count).map { tag.float64(at: $0 * 8) }
        default:
            throw FIF.Error.unexpected("data buffer of type \(tag.baseType); EVA reads float, int, short, DAU-pack16 and double")
        }
    }

    // MARK: - Epochs

    private static func readEpochs(_ reader: FIFReader, info: FIFMeasurementInfo,
                                   warnings: inout [String]) throws -> ([Segment], Double) {
        guard let block = reader.blocks(kind: FIF.blockMNEEpochs).first else {
            throw FIF.Error.missing("epochs block")
        }
        guard let dataTag = block.first(where: { $0.kind == FIF.epochData }) else {
            throw FIF.Error.missing("epoch data")
        }
        let dims = try dataTag.matrixDimensions()
        guard dims.count == 3 else {
            throw FIF.Error.unexpected("an epochs matrix should be 3-dimensional, this one is \(dims.map(String.init).joined(separator: "×"))")
        }
        let (nEpochs, nchan, nsamp) = (dims[0], dims[1], dims[2])
        guard nchan == info.channels.count else {
            throw FIF.Error.unexpected("the epochs matrix has \(nchan) channels but the file describes \(info.channels.count)")
        }
        let values = try dataTag.floatValues()
        guard values.count == nEpochs * nchan * nsamp else { throw FIF.Error.truncated }

        // Epochs and evoked scale by `cal` alone — MNE's `range` belongs to the
        // raw acquisition path and is already folded in by the time data is
        // epoched.
        let calibration = info.channels.map(\.cal)

        // Event list: sample, previous value, code — one triplet per epoch.
        var events: [(sample: Int, code: Int)] = []
        if let eventBlock = reader.blocks(kind: FIF.blockMNEEvents).first,
           let listTag = eventBlock.first(where: { $0.kind == FIF.mneEventList }) {
            let count = listTag.data.count / 4
            let ints = (0..<count).map { Int(listTag.int32(at: $0 * 4)) }
            for triplet in stride(from: 0, to: ints.count - 2, by: 3) {
                events.append((ints[triplet], ints[triplet + 2]))
            }
        }
        // Code → name, from the `code:name;code:name` description string.
        var names: [Int: String] = [:]
        if let eventBlock = reader.blocks(kind: FIF.blockMNEEvents).first,
           let mapping = eventBlock.first(where: { $0.kind == FIF.description })?.stringValue {
            for entry in mapping.split(separator: ";") {
                // Split on the *last* colon: MNE writes `name:code`, and a name
                // may contain colons (it reverses the string to do this).
                guard let separator = entry.lastIndex(of: ":") else { continue }
                let name = String(entry[entry.startIndex..<separator])
                if let code = Int(entry[entry.index(after: separator)...]) { names[code] = name }
            }
        }

        if let dropLog = block.first(where: { $0.kind == FIF.mneEpochsDropLog })?.stringValue,
           dropLog.contains("\"") || dropLog.contains("[") {
            let dropped = dropLog.components(separatedBy: "],").filter { $0.contains("\"") }.count
            if dropped > 0 {
                warnings.append("\(dropped) epoch(s) were dropped when this file was written and are not in it.")
            }
        }

        var segments: [Segment] = []
        segments.reserveCapacity(nEpochs)
        for e in 0..<nEpochs {
            var data = [[Double]](repeating: [], count: nchan)
            for c in 0..<nchan {
                let base = (e * nchan + c) * nsamp
                let cal = calibration[c]
                data[c] = (0..<nsamp).map { Double(values[base + $0]) * cal }
            }
            let event = e < events.count ? events[e] : nil
            segments.append(Segment(
                name: event.flatMap { names[$0.code] } ?? (event.map { "code \($0.code)" } ?? "epoch \(e + 1)"),
                code: event?.code,
                sourceSample: event?.sample,
                contributingCount: 1,
                data: data))
        }
        let first = block.first { $0.kind == FIF.firstSample }?.intValue ?? 0
        return (segments, Double(first) / info.samplingRate)
    }

    // MARK: - Evoked

    private static func readEvoked(_ reader: FIFReader, info: FIFMeasurementInfo,
                                   warnings: inout [String]) throws -> ([Segment], Double) {
        let calibration = info.channels.map(\.cal)
        var segments: [Segment] = []
        var tmin = 0.0
        var sampleCount: Int?

        for block in reader.blocks(kind: FIF.blockEvoked) {
            let comment = block.first { $0.kind == FIF.comment }?.stringValue ?? ""
            let first = block.first { $0.kind == FIF.firstSample }?.intValue
            let firstTime = block.first { $0.kind == FIF.firstTime }?.floatValue

            // Each aspect is one average (or standard error) of this condition.
            guard let dataTag = block.first(where: { $0.kind == FIF.epochData }) else {
                warnings.append("Skipped an evoked block with no data (\(comment.isEmpty ? "unnamed" : comment)).")
                continue
            }
            let aspectKind = block.first { $0.kind == FIF.aspectKind }?.intValue
            if let aspectKind, Int32(aspectKind) == FIF.aspectStdErr {
                warnings.append("\(comment.isEmpty ? "A condition" : comment) is a standard-error aspect, not an average; loaded as-is.")
            }
            let dims = try dataTag.matrixDimensions()
            guard dims.count == 2 else {
                throw FIF.Error.unexpected("an evoked matrix should be 2-dimensional, this one is \(dims.map(String.init).joined(separator: "×"))")
            }
            let (nchan, nsamp) = (dims[0], dims[1])
            guard nchan == info.channels.count else {
                throw FIF.Error.unexpected("an evoked matrix has \(nchan) channels but the file describes \(info.channels.count)")
            }
            if let known = sampleCount, known != nsamp {
                throw FIF.Error.unexpected("conditions disagree on length (\(known) vs \(nsamp) samples)")
            }
            sampleCount = nsamp

            let values = try dataTag.floatValues()
            guard values.count == nchan * nsamp else { throw FIF.Error.truncated }
            var data = [[Double]](repeating: [], count: nchan)
            for c in 0..<nchan {
                let cal = calibration[c]
                data[c] = (0..<nsamp).map { Double(values[c * nsamp + $0]) * cal }
            }
            segments.append(Segment(
                name: comment.isEmpty ? "condition \(segments.count + 1)" : comment,
                code: nil,
                sourceSample: nil,
                contributingCount: block.first { $0.kind == FIF.nave }?.intValue ?? 1,
                data: data))
            tmin = firstTime ?? first.map { Double($0) / info.samplingRate } ?? tmin
        }
        guard !segments.isEmpty else { throw FIF.Error.missing("evoked data") }
        return (segments, tmin)
    }
}

/// One annotation: an onset, a duration and a label, as MNE stores them.
nonisolated struct FIFAnnotation: Sendable, Equatable {
    var onsetSeconds: Double
    var durationSeconds: Double
    var description: String

    /// MNE writes onset and *end* (onset + duration) as float arrays, plus a
    /// colon-separated description list, inside `FIFFB_MNE_ANNOTATIONS`.
    static func read(_ reader: FIFReader, samplingRate: Double) -> [FIFAnnotation] {
        guard let block = reader.blocks(kind: FIF.blockMNEAnnotations).first else { return [] }
        func floats(_ kind: Int32) -> [Double] {
            guard let tag = block.first(where: { $0.kind == kind }) else { return [] }
            if tag.baseType == FIF.typeDouble {
                return (0..<(tag.data.count / 8)).map { tag.float64(at: $0 * 8) }
            }
            return (0..<(tag.data.count / 4)).map { Double(tag.float32(at: $0 * 4)) }
        }
        let onsets = floats(FIF.mneAnnotationOnset)
        let ends = floats(FIF.mneAnnotationEnd)
        let labels = block.first { $0.kind == FIF.comment }.map { FIF.nameList($0.stringValue) } ?? []
        return onsets.indices.map { i in
            FIFAnnotation(
                onsetSeconds: onsets[i],
                durationSeconds: i < ends.count ? max(ends[i] - onsets[i], 0) : 0,
                description: i < labels.count ? labels[i] : "annotation \(i + 1)")
        }
    }
}
