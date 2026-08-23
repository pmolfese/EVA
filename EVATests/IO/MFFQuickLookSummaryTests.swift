//
//  MFFQuickLookSummaryTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  MFFQuickLookSummary duplicates a slice of MFFReader so the QuickLook and
//  thumbnail extensions can read a package without linking the app. These tests
//  are what keeps the duplicate honest: every fixture is read both ways and the
//  answers must agree.
//

import Testing
import Foundation
@testable import EVA

struct MFFQuickLookSummaryTests {

    /// example_1.mff is deliberately absent: its samples were stripped for the
    /// test suite, and the two readers legitimately disagree about it. See
    /// `truncatedPackageIsClassifiedFromMetadata` below.
    private static let fixtures = [
        "example_2.mff",
        "example_3.mff",
        "example_4.mff",
        "example_5.mff"
    ]

    private static let allFixtures = ["example_1.mff"] + fixtures

    @Test(arguments: fixtures)
    func summaryAgreesWithReaderOnFileType(_ name: String) throws {
        let url = Fixtures.url(name)
        let signal = try MFFReader().loadSignal(from: url)
        let summary = try MFFQuickLookSummary.read(from: url)

        #expect(
            summary.fileType.rawValue == signal.detectedFileType.rawValue,
            "\(name): QuickLook said \(summary.fileType.rawValue), MFFReader said \(signal.detectedFileType.rawValue)"
        )
    }

    @Test(arguments: allFixtures)
    func summaryAgreesWithReaderOnSignalShape(_ name: String) throws {
        let url = Fixtures.url(name)
        let signal = try MFFReader().loadSignal(from: url)
        let summary = try MFFQuickLookSummary.read(from: url)

        #expect(summary.channelCount == signal.numberOfChannels)
        #expect(summary.samplingRate == signal.samplingRate)

        // Both walk the same block headers, so the durations should be exact
        // to within a sample.
        let duration = try #require(summary.durationSeconds)
        #expect(abs(duration - signal.duration) < 0.05, "\(name): duration drift")
    }

    @Test func truncatedPackageIsClassifiedFromMetadata() throws {
        // example_1.mff keeps a full categories.xml and epochs.xml but only
        // 16.6 s of the 2424 s of samples they describe. MFFReader maps segments
        // onto real blocks, finds almost none, and falls back to continuous;
        // the summary reads categories.xml directly and reports what the package
        // says it is. For a preview that is the better answer -- the file really
        // does describe 69 segments across 2 conditions -- but the divergence is
        // deliberate and worth pinning down so it is not mistaken for drift.
        let url = Fixtures.url("example_1.mff")
        let signal = try MFFReader().loadSignal(from: url)
        let summary = try MFFQuickLookSummary.read(from: url)

        #expect(signal.detectedFileType == .continuous)
        #expect(summary.fileType == .segmented)

        // The signal shape still agrees, because both read the block headers.
        #expect(summary.channelCount == signal.numberOfChannels)
        #expect(abs((summary.durationSeconds ?? 0) - signal.duration) < 0.05)
    }

    @Test func categoriesAndSubjectsMatchTheReader() throws {
        let url = Fixtures.url("example_4.mff")
        let signal = try MFFReader().loadSignal(from: url)
        let summary = try MFFQuickLookSummary.read(from: url)

        let detail = try #require(summary.averagedDetail)
        #expect(detail.conditions == signal.categories)
        #expect(detail.subjects == signal.subjects)
    }

    @Test func illegalXMLCharactersStillParse() throws {
        // example_5.mff carries a U+FFFF inside its category names, which is not
        // a legal XML character. Both readers tidy rather than give up; without
        // that the file silently degrades to "continuous".
        let summary = try MFFQuickLookSummary.read(from: Fixtures.url("example_5.mff"))
        #expect(summary.fileType == .grandAverage)
        #expect(summary.averagedDetail?.conditions.count == 3)
    }

    @Test func segmentedFixtureTalliesKeptAndRejectedSegments() throws {
        let summary = try MFFQuickLookSummary.read(from: Fixtures.url("example_1.mff"))
        #expect(summary.fileType == .segmented)

        let detail = try #require(summary.segmentedDetail)
        #expect(detail.kept + detail.rejected == 69)
        #expect(detail.rejected > 0)
        #expect(detail.faultHistogram["eyem"] == 48)
        // Bad-channel exclusions are unioned across every segment.
        #expect(!summary.badChannels.isEmpty)
    }

    @Test func continuousFixtureReadsEventTracks() throws {
        let summary = try MFFQuickLookSummary.read(from: Fixtures.url("example_2.mff"))
        #expect(summary.fileType == .continuous)

        let detail = try #require(summary.continuousDetail)
        #expect(detail.totalEventCount == 1)
        #expect(detail.tracks.first?.codes.first?.code == "CLIP")
    }

    @Test func sensorPositionsAreFlippedForScreenDrawing() throws {
        // sensorLayout.xml stores y increasing toward the back of the head, so
        // the summary negates it -- the same flip SensorLayout applies in the app.
        let summary = try MFFQuickLookSummary.read(from: Fixtures.url("example_1.mff"))
        #expect(summary.sensors.count == 256)

        let raw = try #require(
            try XMLDocument(
                data: Data(contentsOf: Fixtures.url("example_1.mff").appendingPathComponent("sensorLayout.xml")),
                options: [.documentTidyXML]
            ).rootElement()
        )
        let firstRawY = try #require(
            raw.descendants("sensor").first?.firstText("y").flatMap(Double.init)
        )
        #expect(summary.sensors.first?.y == -firstRawY)
    }

    @Test func thumbnailOptionsSkipEventParsing() throws {
        let summary = try MFFQuickLookSummary.read(
            from: Fixtures.url("example_2.mff"),
            options: .thumbnail
        )
        #expect(summary.fileType == .continuous)
        #expect(summary.continuousDetail?.tracks.isEmpty == true)
    }

    @Test func rejectsANonMFFDirectory() throws {
        #expect(throws: (any Error).self) {
            try MFFQuickLookSummary.read(from: Fixtures.url("example_2.json"))
        }
    }

    // MARK: - Impedance

    @Test func impedanceMatchesTheReadersICALValues() throws {
        // Both read the ICAL calibration in info1.xml; MFFReader returns a
        // channel-indexed array with NaN for unmeasured channels, the summary a
        // sparse dictionary keyed by channel number.
        let url = Fixtures.url("example_1.mff")
        let signal = try MFFReader().loadSignal(from: url)
        let summary = try MFFQuickLookSummary.read(from: url)

        let readerValues = try #require(signal.impedancesKOhm)
        let impedance = try #require(summary.impedance)

        for (index, value) in readerValues.enumerated() where value.isFinite {
            let mine = try #require(
                impedance.valuesKOhm[index + 1],
                "channel \(index + 1) missing from the summary"
            )
            #expect(abs(mine - Double(value)) < 0.001)
        }
        #expect(impedance.measuredCount == readerValues.filter(\.isFinite).count)
    }

    @Test func impedanceBandsMatchEVAsDefaults() {
        // EVA's ChannelImpedanceSettings defaults put the "good" edge at 60 kΩ
        // and the "fair" edge at 100; the preview colours on those same edges.
        let settings = ChannelImpedanceSettings.defaults
        #expect(MFFQuickLookSummary.Impedance.cautionKOhm == settings.goodMaxKOhm)
        #expect(MFFQuickLookSummary.Impedance.poorKOhm == settings.fairMaxKOhm)

        #expect(MFFQuickLookSummary.Impedance.band(forKOhm: 12) == .ok)
        #expect(MFFQuickLookSummary.Impedance.band(forKOhm: 60) == .ok)
        #expect(MFFQuickLookSummary.Impedance.band(forKOhm: 60.5) == .caution)
        #expect(MFFQuickLookSummary.Impedance.band(forKOhm: 70) == .caution)
        #expect(MFFQuickLookSummary.Impedance.band(forKOhm: 100) == .caution)
        #expect(MFFQuickLookSummary.Impedance.band(forKOhm: 100.5) == .poor)
        #expect(MFFQuickLookSummary.Impedance.band(forKOhm: 2111) == .poor)
    }

    @Test func impedanceTalliesTheFixtureBands() throws {
        let impedance = try #require(
            try MFFQuickLookSummary.read(from: Fixtures.url("example_1.mff")).impedance
        )
        #expect(impedance.measuredCount == 257)
        #expect(impedance.cautionCount == 9)
        #expect(impedance.poorCount == 2)
        let median = try #require(impedance.medianKOhm)
        #expect(abs(median - 14.6) < 0.1)
    }

    @Test func packagesWithoutICALReportNoImpedance() throws {
        // The mffpy fixtures carry no ICAL block; the panel says so rather than
        // colouring every electrode as if it measured well.
        #expect(try MFFQuickLookSummary.read(from: Fixtures.url("example_2.mff")).impedance == nil)
        #expect(try MFFQuickLookSummary.read(from: Fixtures.url("example_4.mff")).impedance == nil)
    }

    @Test func thumbnailModelReflectsTheSummary() throws {
        let segmented = MFFThumbnailRenderer.Model(
            summary: try MFFQuickLookSummary.read(from: Fixtures.url("example_1.mff"), options: .thumbnail)
        )
        #expect(segmented.fileType == .segmented)
        #expect(segmented.conditionCount == 2)
        #expect(segmented.hasRejectedSegments)

        let averaged = MFFThumbnailRenderer.Model(
            summary: try MFFQuickLookSummary.read(from: Fixtures.url("example_4.mff"), options: .thumbnail)
        )
        #expect(averaged.fileType == .grandAverage)
        #expect(averaged.hasRejectedSegments == false)
    }
}
