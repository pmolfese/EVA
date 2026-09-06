//
//  FIFMeasurementInfo.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  The measurement-info half of a FIF recording: sampling rate, the per-channel
//  `FIFF_CH_INFO` structs, bad channels, filter settings, acquisition date, and
//  the SSP projectors declared on the file.
//
//  `FIFF_CH_INFO` is the keystone of reading FIF data. It carries the channel's
//  name and kind (EEG vs. EOG vs. STIM vs. MEG), its position, and — most
//  importantly — `range` and `cal`, without which the samples in the data
//  buffers are in arbitrary units. Everything else in a FIF recording is
//  readable with the generic tag reader already in `FIFFile.swift`.
//
//  Field layout and semantics from the FIF specification as implemented in
//  MNE-Python (BSD-3, `mne/_fiff/tag.py`, `meas_info.py`), re-implemented here.
//

import Foundation
import simd

extension FIF {
    // Measurement info tags
    nonisolated static let nchan: Int32 = 200
    nonisolated static let sfreq: Int32 = 201
    nonisolated static let chInfo: Int32 = 203
    nonisolated static let measDate: Int32 = 204
    nonisolated static let comment: Int32 = 206
    nonisolated static let nave: Int32 = 207
    nonisolated static let firstSample: Int32 = 208
    nonisolated static let lastSample: Int32 = 209
    nonisolated static let aspectKind: Int32 = 210
    nonisolated static let lowpass: Int32 = 219
    nonisolated static let highpass: Int32 = 223
    nonisolated static let noSamples: Int32 = 228
    nonisolated static let firstTime: Int32 = 229
    nonisolated static let dataBuffer: Int32 = 300
    nonisolated static let dataSkip: Int32 = 301
    nonisolated static let epochData: Int32 = 302
    nonisolated static let dataSkipSamples: Int32 = 303
    nonisolated static let refFileName: Int32 = 118
    nonisolated static let subjectID: Int32 = 400
    nonisolated static let subjectFirstName: Int32 = 401
    nonisolated static let subjectLastName: Int32 = 403
    nonisolated static let mneRowNames: Int32 = 3502
    nonisolated static let mneChNameList: Int32 = 3507
    nonisolated static let mneEventList: Int32 = 3561
    nonisolated static let mneAnnotationOnset: Int32 = 3568        // FIFF_MNE_BASELINE_MIN, reused
    nonisolated static let mneAnnotationEnd: Int32 = 3569          // FIFF_MNE_BASELINE_MAX, reused
    nonisolated static let mneEpochsSelection: Int32 = 3800
    nonisolated static let mneEpochsDropLog: Int32 = 3801
    nonisolated static let mneEpochsRawSfreq: Int32 = 3803
    nonisolated static let projItemVectors: Int32 = 3417
    nonisolated static let projItemKind: Int32 = 3411
    nonisolated static let projItemNVec: Int32 = 3415
    nonisolated static let projItemActive: Int32 = 3416

    // Block kinds
    nonisolated static let blockMeas: Int32 = 100
    nonisolated static let blockMeasInfo: Int32 = 101
    nonisolated static let blockRawData: Int32 = 102
    nonisolated static let blockProcessedData: Int32 = 103
    nonisolated static let blockEvoked: Int32 = 104
    nonisolated static let blockAspect: Int32 = 105
    nonisolated static let blockSubject: Int32 = 106
    nonisolated static let blockContinuousData: Int32 = 112
    nonisolated static let blockIASRawData: Int32 = 119
    nonisolated static let blockProj: Int32 = 313
    nonisolated static let blockProjItem: Int32 = 314
    nonisolated static let blockBadChannels: Int32 = 359
    nonisolated static let blockMNEEvents: Int32 = 361
    nonisolated static let blockMNEEpochs: Int32 = 373
    nonisolated static let blockMNEAnnotations: Int32 = 3810

    // Data types
    nonisolated static let typeShort: Int32 = 2
    nonisolated static let typeDAUPack16: Int32 = 16
    nonisolated static let typeComplexFloat: Int32 = 20
    nonisolated static let typeChInfoStruct: Int32 = 30

    // Aspect kinds
    nonisolated static let aspectAverage: Int32 = 100
    nonisolated static let aspectStdErr: Int32 = 101

    // Units
    nonisolated static let unitVolts: Int32 = 107
    nonisolated static let unitTesla: Int32 = 112
}

/// One `FIFF_CH_INFO` struct: 96 bytes, big-endian.
///
/// `scanNo, logNo, kind, range, cal, coilType, r0[3], ex[3], ey[3], ez[3],
/// unit, unitMul, name[16]`.
nonisolated struct FIFChannelInfo: Sendable, Equatable {
    enum Kind: Int32, Sendable, CaseIterable {
        case meg = 1
        case eeg = 2
        case stim = 3
        case bio = 102
        case eog = 202
        case refMEG = 301
        case emg = 302
        case ecg = 402
        case misc = 502
        case resp = 602
        case seeg = 802
        case ecog = 902

        var displayName: String {
            switch self {
            case .meg: return "MEG"
            case .eeg: return "EEG"
            case .stim: return "stimulus"
            case .bio: return "bio"
            case .eog: return "EOG"
            case .refMEG: return "reference MEG"
            case .emg: return "EMG"
            case .ecg: return "ECG"
            case .misc: return "misc"
            case .resp: return "respiration"
            case .seeg: return "sEEG"
            case .ecog: return "ECoG"
            }
        }

        /// Channels EVA treats as brain signal in the main viewer.
        var isBrainSignal: Bool { self == .eeg || self == .seeg || self == .ecog }

        /// Channels EVA shows alongside as peripheral/physiological traces.
        var isPeripheral: Bool {
            switch self {
            case .eog, .ecg, .emg, .bio, .resp, .misc: return true
            default: return false
            }
        }
    }

    var scanNumber: Int
    var logicalNumber: Int
    var rawKind: Int32
    /// Hardware range; the sample scaling is `range * cal` (MNE's `info._cals`).
    var range: Double
    var cal: Double
    var coilType: Int32
    /// The 12 position floats: r0, ex, ey, ez. For EEG, `r0` is the electrode
    /// and `ex` the reference electrode, in head coordinates, metres.
    var loc: [Double]
    var unit: Int32
    /// Power-of-ten multiplier on `unit`. MNE does not apply it when reading FIF
    /// (its `_cals` is `range * cal` alone) and neither do we — but a non-zero
    /// value means the file disagrees with that assumption, so it is surfaced.
    var unitMultiplier: Int32
    var name: String

    var kind: Kind? { Kind(rawValue: rawKind) }
    /// Samples × this = the channel's own unit (volts, for EEG).
    var calibration: Double { range * cal }

    /// Electrode position in head coordinates (metres), when the file has one.
    var positionMeters: SIMD3<Double>? {
        guard loc.count >= 3 else { return nil }
        let r = SIMD3<Double>(loc[0], loc[1], loc[2])
        return simd_length(r) > 1e-9 && r.x.isFinite && r.y.isFinite && r.z.isFinite ? r : nil
    }

    static let byteCount = 96

    init(tag: FIFTag) throws {
        guard tag.data.count >= Self.byteCount else {
            throw FIF.Error.truncated
        }
        scanNumber = Int(tag.int32(at: 0))
        logicalNumber = Int(tag.int32(at: 4))
        rawKind = tag.int32(at: 8)
        range = Double(tag.float32(at: 12))
        cal = Double(tag.float32(at: 16))
        coilType = tag.int32(at: 20)
        loc = (0..<12).map { Double(tag.float32(at: 24 + $0 * 4)) }
        unit = tag.int32(at: 72)
        unitMultiplier = tag.int32(at: 76)
        // 16 bytes, NUL-padded.
        let nameBytes = tag.data.dropFirst(80).prefix(16).prefix { $0 != 0 }
        name = String(decoding: nameBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

/// Everything a FIF recording declares about itself, independent of whether the
/// samples are continuous, epoched or averaged.
nonisolated struct FIFMeasurementInfo: Sendable {
    var channels: [FIFChannelInfo]
    var samplingRate: Double
    var firstSample: Int
    var badChannels: [String]
    var highpassHz: Double?
    var lowpassHz: Double?
    var measurementDate: Date?
    var subject: String?
    /// SSP projectors declared on the file. EVA does not apply them; it reports
    /// them, because an unapplied average-reference projector is the difference
    /// between the data MNE would hand you and the data we do.
    var projectors: [Projector]
    /// Digitization from `FIFFB_ISOTRAK`, when present — the same reader R2.3
    /// already uses for `-dig.fif`.
    var digitization: Digitization?

    struct Projector: Sendable, Equatable {
        var description: String
        var vectorCount: Int
        var isActive: Bool
    }

    var channelNames: [String] { channels.map(\.name) }
    func indices(ofKind kind: FIFChannelInfo.Kind) -> [Int] {
        channels.indices.filter { channels[$0].kind == kind }
    }
    var brainChannelIndices: [Int] {
        channels.indices.filter { channels[$0].kind?.isBrainSignal == true }
    }
    var peripheralChannelIndices: [Int] {
        channels.indices.filter { channels[$0].kind?.isPeripheral == true }
    }
    var stimulusChannelIndices: [Int] { indices(ofKind: .stim) }

    static func read(_ reader: FIFReader) throws -> FIFMeasurementInfo {
        guard let infoBlock = reader.blocks(kind: FIF.blockMeasInfo).first else {
            throw FIF.Error.missing("measurement info block")
        }
        var channels: [FIFChannelInfo] = []
        for tag in infoBlock where tag.kind == FIF.chInfo {
            channels.append(try FIFChannelInfo(tag: tag))
        }
        guard !channels.isEmpty else { throw FIF.Error.missing("channel information") }
        guard let sfreqTag = infoBlock.first(where: { $0.kind == FIF.sfreq }) else {
            throw FIF.Error.missing("sampling rate")
        }
        let sfreq = sfreqTag.floatValue
        guard sfreq > 0 else { throw FIF.Error.unexpected("sampling rate \(sfreq)") }
        if let declared = infoBlock.first(where: { $0.kind == FIF.nchan })?.intValue,
           declared != channels.count {
            throw FIF.Error.unexpected("the file declares \(declared) channels but carries \(channels.count) channel descriptions")
        }

        // Bad channels: a name list in its own block, colon-separated.
        var bads: [String] = []
        if let badBlock = reader.blocks(kind: FIF.blockBadChannels).first,
           let names = badBlock.first(where: { $0.kind == FIF.mneChNameList })?.stringValue {
            bads = FIF.nameList(names)
        }

        var projectors: [FIFMeasurementInfo.Projector] = []
        for item in reader.blocks(kind: FIF.blockProjItem) {
            let description = item.first { $0.kind == FIF.comment }?.stringValue ?? "unnamed projector"
            let vectors = item.first { $0.kind == FIF.projItemNVec }?.intValue ?? 0
            let active = (item.first { $0.kind == FIF.projItemActive }?.intValue ?? 0) != 0
            projectors.append(.init(description: description, vectorCount: vectors, isActive: active))
        }

        return FIFMeasurementInfo(
            channels: channels,
            samplingRate: sfreq,
            firstSample: reader.first(kind: FIF.firstSample)?.intValue ?? 0,
            badChannels: bads,
            highpassHz: infoBlock.first { $0.kind == FIF.highpass }?.floatValue,
            lowpassHz: infoBlock.first { $0.kind == FIF.lowpass }?.floatValue,
            measurementDate: infoBlock.first { $0.kind == FIF.measDate }.flatMap(FIF.date(from:)),
            subject: reader.blocks(kind: FIF.blockSubject).first.flatMap { block in
                let first = block.first { $0.kind == FIF.subjectFirstName }?.stringValue
                let last = block.first { $0.kind == FIF.subjectLastName }?.stringValue
                let combined = [first, last].compactMap { $0 }.joined(separator: " ")
                return combined.isEmpty ? nil : combined
            },
            projectors: projectors,
            digitization: try? Digitization.read(reader)
        )
    }
}

extension FIF {
    /// FIF name lists are colon-separated. MNE escapes a literal colon inside a
    /// name as `{COLON}` when it writes one, so undo that on the way in.
    nonisolated static func nameList(_ text: String) -> [String] {
        text.split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "{COLON}", with: ":") }
            .filter { !$0.isEmpty }
    }

    /// `FIFF_MEAS_DATE` is a pair of ints (seconds, microseconds) in older files
    /// and a double pair in newer ones.
    nonisolated static func date(from tag: FIFTag) -> Date? {
        if tag.baseType == FIF.typeInt, tag.data.count >= 8 {
            return Date(timeIntervalSince1970: Double(tag.int32(at: 0)) + Double(tag.int32(at: 4)) / 1e6)
        }
        if tag.baseType == FIF.typeDouble, tag.data.count >= 16 {
            return Date(timeIntervalSince1970: tag.float64(at: 0) + tag.float64(at: 8) / 1e6)
        }
        return nil
    }
}
