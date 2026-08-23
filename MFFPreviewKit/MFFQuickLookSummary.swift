//
//  MFFQuickLookSummary.swift
//  MFFPreviewKit
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  A cheap, self-contained read of an MFF package for QuickLook previews and
//  thumbnails. Parses only the small XML sidecars plus the first block header of
//  signal1.bin -- it never touches sample data, because a QuickLook extension has
//  a few seconds and a tight memory ceiling, and signal1.bin routinely runs to
//  hundreds of megabytes.
//
//  This deliberately does NOT depend on MFFReader. The QuickLook and thumbnail
//  extensions cannot link the app, and duplicating ~250 lines of small XML reads
//  is cheaper than restructuring MFFReader into a shared framework. The one piece
//  of logic that must not drift -- the continuous/segmented/averaged/grandAverage
//  classification -- mirrors MFFReader.parseOnDiskEpochs, and
//  MFFQuickLookSummaryTests asserts the two agree across every fixture.
//

import Foundation

nonisolated struct MFFQuickLookSummary: Sendable {

    // MARK: - Nested types

    /// Mirrors `MFFFileType` in the app target. Kept nested so both can be in
    /// scope in the test target without a name collision.
    enum FileType: String, Sendable {
        case continuous
        case segmented
        case averaged
        case grandAverage

        var displayName: String {
            switch self {
            case .continuous: return "Continuous"
            case .segmented: return "Segmented"
            case .averaged: return "Averaged"
            case .grandAverage: return "Grand average"
            }
        }
    }

    struct CodeTally: Sendable, Identifiable {
        let code: String
        /// Seconds from the recording start. Capped -- see `Options.maxEventsPerTrack`.
        let times: [Double]
        let count: Int
        var id: String { code }
    }

    struct EventTrack: Sendable, Identifiable {
        let name: String
        let trackType: String?
        let codes: [CodeTally]
        let truncated: Bool
        var totalCount: Int { codes.reduce(0) { $0 + $1.count } }
        var id: String { name }
    }

    struct ConditionTally: Sendable, Identifiable {
        let name: String
        let kept: Int
        let rejected: Int
        /// Total contributing trials, from the `#seg` keys. Averaged files only.
        let contributingTrials: Int
        var total: Int { kept + rejected }
        var id: String { name }
    }

    struct Sensor: Sendable {
        let number: Int
        let x: Double
        let y: Double
    }

    /// Per-channel electrode impedance from the `ICAL` calibration in info1.xml,
    /// recorded at acquisition start. Bands mirror `ChannelImpedanceSettings`
    /// defaults in the app so the preview and the Channel Health panel agree
    /// about the same file. Those settings are user-configurable in EVA, but an
    /// extension cannot read the app's container, so these are the defaults.
    struct Impedance: Sendable {
        enum Band: Sendable {
            case ok        // <= 60 kOhm, EVA's `goodMaxKOhm`
            case caution   // 60...100 kOhm, up to EVA's `fairMaxKOhm`
            case poor      // > 100 kOhm
        }

        static let cautionKOhm: Double = 60
        static let poorKOhm: Double = 100

        /// 1-based channel number -> kOhm. Channels the file did not measure are
        /// simply absent.
        let valuesKOhm: [Int: Double]

        static func band(forKOhm kOhm: Double) -> Band {
            if kOhm > poorKOhm { return .poor }
            if kOhm > cautionKOhm { return .caution }
            return .ok
        }

        func band(forChannel channel: Int) -> Band? {
            valuesKOhm[channel].map(Self.band(forKOhm:))
        }

        var measuredCount: Int { valuesKOhm.count }
        var cautionCount: Int { valuesKOhm.values.filter { Self.band(forKOhm: $0) == .caution }.count }
        var poorCount: Int { valuesKOhm.values.filter { Self.band(forKOhm: $0) == .poor }.count }

        var medianKOhm: Double? {
            let sorted = valuesKOhm.values.sorted()
            guard !sorted.isEmpty else { return nil }
            return sorted[sorted.count / 2]
        }
    }

    struct Manifest: Sendable {
        let hasCategories: Bool
        let hasHistory: Bool
        let hasCoordinates: Bool
        let hasPNS: Bool
        let hasMRInfo: Bool
        let hasEVAScript: Bool
        let signalFileNames: [String]
    }

    struct ContinuousDetail: Sendable {
        let tracks: [EventTrack]
        var totalEventCount: Int { tracks.reduce(0) { $0 + $1.totalCount } }
        var hasMRPulseTrack: Bool {
            tracks.contains { $0.name.localizedCaseInsensitiveContains("MR_Pulse") }
        }
    }

    struct SegmentedDetail: Sendable {
        let epochLengthSeconds: Double?
        let baselineSeconds: Double?
        let conditions: [ConditionTally]
        let faultHistogram: [String: Int]
        var kept: Int { conditions.reduce(0) { $0 + $1.kept } }
        var rejected: Int { conditions.reduce(0) { $0 + $1.rejected } }
        var retention: Double {
            let total = kept + rejected
            return total > 0 ? Double(kept) / Double(total) : 0
        }
    }

    struct AveragedDetail: Sendable {
        let conditions: [String]
        let subjects: [String]
        /// condition -> subject -> contributing trial count. Single-subject
        /// averages use `""` as the subject key.
        let trialsPerCell: [String: [String: Int]]
        let sourceFiles: [String]
        let epochLengthSeconds: Double?
        let baselineSeconds: Double?
    }

    struct Options: Sendable {
        /// Thumbnails need only the type and the condition count, so they skip
        /// the event tracks -- by far the largest XML in a long recording.
        var includeEvents: Bool = true
        /// A long MR-pulse track can carry tens of thousands of events. The
        /// timeline is a few hundred points wide, so anything past this cap
        /// cannot change the picture.
        var maxEventsPerTrack: Int = 5_000

        static let thumbnail = Options(includeEvents: false)
        static let preview = Options()
    }

    // MARK: - Identity

    let url: URL
    let displayName: String
    let fileType: FileType
    let mffVersion: Int?
    let recordTime: Date?
    let amplifier: String?
    let acquisitionVersion: String?
    let subjectID: String?
    let sessionNumber: String?
    let byteSize: Int64

    // MARK: - Signal shape

    let samplingRate: Double?
    let channelCount: Int?
    let pnsChannelCount: Int?
    let durationSeconds: Double?
    let epochCount: Int

    // MARK: - Layout and manifest

    let layoutName: String?
    let sensors: [Sensor]
    let badChannels: Set<Int>
    let impedance: Impedance?
    let manifest: Manifest
    let hardwareFilterShiftMicroseconds: Int?
    let trsPerVolume: Int?

    // MARK: - Type-specific

    let continuousDetail: ContinuousDetail?
    let segmentedDetail: SegmentedDetail?
    let averagedDetail: AveragedDetail?
}
