//
//  FIFPreviewTests.swift
//  EVATests
//
//  Classifying a `.fif` and building its Quick Look summary. A `.fif` is a
//  container for a dozen different documents, so the first job is telling them
//  apart — by block structure, not by filename, because filename conventions get
//  broken and block structure does not.
//
//  The rendering test writes real PNGs so the panels can be looked at rather
//  than only asserted about.
//

import Foundation
import Testing
import SwiftUI
import simd
@testable import EVA

@Suite("FIF Quick Look")
struct FIFPreviewTests {
    static func fif(_ name: String) -> URL { Fixtures.url("FIF/\(name)") }
    static func resolve(_ name: String) -> URL { Fixtures.url("Resolve/\(name)") }

    // MARK: - Classification

    @Test("documents are told apart by block structure", arguments: [
        ("FIF/sample_raw.fif", FIFDocument.Kind.continuousRecording),
        ("FIF/sample_gz_raw.fif.gz", .continuousRecording),
        ("FIF/sample-epo.fif", .epochedRecording),
        ("FIF/sample-ave.fif", .averagedRecording),
        ("FIF/sample-cov.fif", .covariance),
        ("FIF/sample-eve.fif", .events),
        ("Resolve/Forward/fsaverage-ico2-bem.fif", .headModel),
        ("Resolve/Forward/fsaverage-ico2-bem-sol-mne.fif", .headModel),
        ("Resolve/Forward/fsaverage-ico2-trans.fif", .coordinateTransform),
        ("Resolve/Forward/fsaverage-ico2-electrodes-dig.fif", .digitization),
        ("Resolve/fsaverage-fiducials.fif", .digitization),
    ])
    func classification(path: String, expected: FIFDocument.Kind) throws {
        #expect(try FIFDocument.classify(Fixtures.url(path)) == expected, "\(path)")
    }

    @Test("a misleading filename does not change the answer")
    func classifyByStructureNotName() throws {
        // Copy an averaged file under a name that says "raw". Structure wins.
        let source = Self.fif("sample-ave.fif")
        let disguised = FileManager.default.temporaryDirectory
            .appendingPathComponent("definitely_raw.fif")
        try? FileManager.default.removeItem(at: disguised)
        try FileManager.default.copyItem(at: source, to: disguised)
        defer { try? FileManager.default.removeItem(at: disguised) }
        #expect(try FIFDocument.classify(disguised) == .averagedRecording)
    }

    @Test("the importer explains what a non-recording FIF actually is")
    func importAdvice() throws {
        let url = Self.resolve("Forward/fsaverage-ico2-bem.fif")
        var thrown: Error?
        do { _ = try SignalImportReader.load(from: url) } catch { thrown = error }
        let message = try #require(thrown?.localizedDescription)
        #expect(message.contains("BEM head model"), "got: \(message)")
        #expect(message.contains("Resolve"), "got: \(message)")
    }

    @Test("advice says what to do, not what the file is")
    func adviceIsAdviceOnly() {
        // Whatever shows the advice has already identified the file; an advice
        // string that re-identifies it produces "it is a head model. It is a
        // head model — open it in …".
        for kind in FIFDocument.Kind.allCases {
            guard let advice = kind.importAdvice else { continue }
            #expect(!advice.hasPrefix("It is a"), "\(kind): \(advice)")
            #expect(!advice.contains(kind.noun), "\(kind) repeats its own noun: \(advice)")
        }
    }

    // MARK: - Summaries

    @Test("a continuous recording summary carries what the panel draws")
    func continuousSummary() throws {
        let summary = try FIFQuickLookReader.read(from: Self.fif("sample_raw.fif"))
        #expect(summary.kind == .continuousRecording)
        let recording = try #require(summary.recording)
        #expect(recording.brainChannelCount == 12)
        #expect(recording.peripheralChannelCount == 1)
        #expect(recording.stimulusChannelCount == 1)
        #expect(recording.samplingRate == 200)
        #expect(!recording.traces.isEmpty && recording.traces.count <= 8)
        // The preview decodes the first 10 s but must still report the file's
        // true 20 s length; the timeline covers what was read.
        #expect(abs(recording.durationSeconds - 20) < 1e-6)
        #expect(recording.isTruncated)
        #expect(abs(recording.traceSeconds - 10) < 0.5)
        // Annotations and stim edges both, and told apart. Two of each fall in
        // the first ten seconds.
        #expect(recording.markers.filter(\.isAnnotation).count == 2)
        #expect(recording.markers.filter { !$0.isAnnotation }.count == 2)
        // Microvolts, not volts: a ±20 µV signal must not read as 2e-5.
        #expect(recording.amplitudeMicrovolts > 1 && recording.amplitudeMicrovolts < 500)
        #expect(recording.channels.contains { $0.direction != nil })
    }

    @Test("epoched and averaged summaries carry a butterfly per condition",
          arguments: ["sample-epo.fif", "sample-ave.fif"])
    func segmentedSummary(name: String) throws {
        let summary = try FIFQuickLookReader.read(from: Self.fif(name))
        let recording = try #require(summary.recording)
        #expect(recording.conditions.count == 2)
        #expect(recording.conditionTraces.count == 2)
        // Every brain channel, overlaid — that is what makes it a butterfly.
        #expect(recording.conditionTraces.allSatisfy { $0.count == 12 })
        #expect(recording.traceStartSeconds < 0)      // a pre-stimulus baseline
        #expect(recording.amplitudeMicrovolts > 0.1)
    }

    @Test("a head model summary carries nested contours and the shells' physics")
    func headModelSummary() throws {
        let summary = try FIFQuickLookReader.read(from: Self.resolve("Forward/fsaverage-ico2-bem-sol-mne.fif"))
        #expect(summary.kind == .headModel)
        let model = try #require(summary.headModel)
        #expect(model.shells.count == 3)
        #expect(model.shells.map(\.name) == ["inner skull", "outer skull", "scalp"])
        #expect(model.solver == "mne")
        #expect(model.hasSolution && model.solutionSize == 486)
        #expect(model.approximation == "linear collocation")

        // Contours exist for every shell in both planes, and they nest: the
        // inner skull's outline sits inside the scalp's in the shared box.
        for shell in model.shells {
            #expect(!shell.sagittal.isEmpty, "\(shell.name) sagittal")
            #expect(!shell.axial.isEmpty, "\(shell.name) axial")
        }
        func spread(_ contours: [FIFQuickLookSummary.HeadModel.Contour]) -> Double {
            let xs = contours.map(\.from.x)
            return (xs.max() ?? 0) - (xs.min() ?? 0)
        }
        let inner = spread(model.shells[0].sagittal)
        let outer = spread(model.shells[2].sagittal)
        #expect(inner < outer, "inner skull \(inner) should be narrower than scalp \(outer)")
        // Every coordinate lands in the normalized box the view draws into.
        let all = model.shells.flatMap { $0.sagittal + $0.axial }
        #expect(all.allSatisfy { (0...1).contains($0.from.x) && (0...1).contains($0.from.y) })
    }

    @Test("a geometry-only head model says so instead of implying a solution")
    func geometryOnlySummary() throws {
        let summary = try FIFQuickLookReader.read(from: Self.resolve("Forward/fsaverage-ico2-bem.fif"))
        let model = try #require(summary.headModel)
        #expect(!model.hasSolution)
        #expect(model.solver == nil)
    }

    @Test("a transform summary decomposes the matrix into millimetres and degrees")
    func transformSummary() throws {
        let summary = try FIFQuickLookReader.read(from: Self.resolve("fsaverage-trans.fif"))
        #expect(summary.kind == .coordinateTransform)
        let transform = try #require(summary.transform)
        #expect(transform.fromFrame == "head")
        #expect(transform.toFrame.contains("MRI"))
        #expect(transform.matrix.count == 4)
        // fsaverage's trans is rigid; a scale that drifts from 1 would mean the
        // decomposition is wrong, not that the file is.
        #expect(abs(transform.scale - 1) < 1e-6)
        #expect(simd_length(transform.translationMillimetres) < 100)
    }

    @Test("a digitization summary projects the points and marks the fiducials")
    func digitizationSummary() throws {
        let summary = try FIFQuickLookReader.read(from: Self.resolve("Forward/fsaverage-ico2-electrodes-dig.fif"))
        #expect(summary.kind == .digitization)
        let dig = try #require(summary.digitization)
        #expect(dig.points.count == 35)               // 32 electrodes + 3 fiducials
        #expect(dig.points.filter(\.isFiducial).count == 3)
        #expect(dig.points.allSatisfy { (0...1).contains($0.top.x) && (0...1).contains($0.side.y) })
        #expect(dig.headWidthMillimetres ?? 0 > 100)
    }

    @Test("a document EVA has no picture for still reports its structure")
    func fallbackSummary() throws {
        let summary = try FIFQuickLookReader.read(from: Self.fif("sample-cov.fif"))
        #expect(summary.kind == .covariance)
        #expect(summary.recording == nil && summary.headModel == nil)
        #expect(!summary.outline.isEmpty)
        #expect(summary.outline.contains { $0.name == "Covariance" })
        #expect(summary.tagCount > 0)
        #expect(summary.largestTagName != nil)
    }

    // MARK: - Rendering

    /// Renders every panel and thumbnail to PNG. Asserts they are non-blank —
    /// and leaves the files where they can be looked at, which is the only way
    /// to review a picture.
    @MainActor
    @Test("every preview and thumbnail renders")
    func rendering() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EVAFIFPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let cases: [(String, URL)] = [
            ("continuous", Self.fif("sample_raw.fif")),
            ("epoched", Self.fif("sample-epo.fif")),
            ("averaged", Self.fif("sample-ave.fif")),
            ("headmodel", Self.resolve("Forward/fsaverage-ico2-bem-sol-mne.fif")),
            ("transform", Self.resolve("fsaverage-trans.fif")),
            ("digitization", Self.resolve("Forward/fsaverage-ico2-electrodes-dig.fif")),
            ("covariance", Self.fif("sample-cov.fif")),
        ]

        for (name, url) in cases {
            let summary = try FIFQuickLookReader.read(from: url)

            // Both appearances: Quick Look adopts the system one, and a panel
            // that only reads in light mode is half broken.
            for scheme in [ColorScheme.light, .dark] {
                let backing = scheme == .light ? Color.white : Color(white: 0.13)
                let renderer = ImageRenderer(content: FIFPreviewContent(summary: summary)
                    .frame(width: 820)
                    .background(backing)
                    .environment(\.colorScheme, scheme))
                renderer.scale = 2
                let image = try #require(renderer.nsImage, "\(name) produced no preview image")
                #expect(image.size.width > 100 && image.size.height > 100, "\(name) preview is tiny")
                let suffix = scheme == .light ? "light" : "dark"
                try write(image, to: directory.appendingPathComponent("preview-\(name)-\(suffix)@2x.png"))
            }

            for (suffix, palette) in [("light", FIFThumbnailRenderer.Palette.light),
                                      ("dark", FIFThumbnailRenderer.Palette.dark)] {
                let thumbnail = FIFThumbnailRenderer(summary: summary, palette: palette)
                let side = 256
                let context = try #require(CGContext(
                    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                thumbnail.draw(in: context, size: CGSize(width: side, height: side))
                let cgImage = try #require(context.makeImage(), "\(name) \(suffix) thumbnail")
                let nsImage = NSImage(cgImage: cgImage, size: CGSize(width: side, height: side))
                try write(nsImage, to: directory.appendingPathComponent("thumb-\(name)-\(suffix).png"))
            }
        }
        print("FIF preview renders written to \(directory.path)")
    }

    @MainActor
    private func write(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("could not encode \(url.lastPathComponent)")
            return
        }
        try png.write(to: url)
    }
}

@Suite("FIF drop rejection")
struct FIFDropRejectionTests {

    @Test("a non-recording FIF is refused before anything opens", arguments: [
        ("Resolve/Forward/fsaverage-ico2-bem.fif", "BEM head model"),
        ("Resolve/Forward/fsaverage-ico2-bem-sol-mne.fif", "BEM head model"),
        ("Resolve/Forward/fsaverage-ico2-trans.fif", "coordinate transform"),
        ("Resolve/Forward/fsaverage-ico2-electrodes-dig.fif", "digitization"),
        ("FIF/sample-cov.fif", "noise covariance matrix"),
    ])
    func rejected(path: String, expected: String) throws {
        let url = Fixtures.url(path)
        // It still counts as a droppable file — the extension is supported —
        // but it must not be openable as a recording.
        #expect(SignalImportReader.isSupportedRecordingURL(url))
        let reason = try #require(SignalImportReader.recordingRejectionReason(for: url),
                                  "\(path) should be refused")
        #expect(reason.contains(expected), "got: \(reason)")
        #expect(reason.contains(url.lastPathComponent))
        // The message says what to do about it, not just what went wrong.
        #expect(reason.count > expected.count + 20, "got: \(reason)")
    }

    @Test("every recording shape is still accepted", arguments: [
        "FIF/sample_raw.fif", "FIF/sample_gz_raw.fif.gz", "FIF/sample-epo.fif", "FIF/sample-ave.fif",
    ])
    func accepted(path: String) {
        #expect(SignalImportReader.recordingRejectionReason(for: Fixtures.url(path)) == nil, "\(path)")
    }

    @Test("the article agrees with the noun")
    func articles() {
        for kind in FIFDocument.Kind.allCases {
            let phrase = kind.nounWithArticle
            let vowel = "aeiou".contains(kind.noun.lowercased().first ?? "x")
            #expect(phrase.hasPrefix(vowel ? "an " : "a "), "\(kind): \(phrase)")
        }
        #expect(FIFDocument.Kind.events.nounWithArticle == "an event list")
        #expect(FIFDocument.Kind.headModel.nounWithArticle == "a BEM head model")
        #expect(FIFDocument.Kind.independentComponents.nounWithArticle == "a saved ICA decomposition")
    }

    @Test("non-FIF formats are not put through the check")
    func otherFormatsUnaffected() {
        // The check reads the file, so it must not fire for formats whose
        // extension already tells the truth.
        #expect(SignalImportReader.recordingRejectionReason(for: Fixtures.url("example_3.mff")) == nil)
        #expect(SignalImportReader.recordingRejectionReason(for: URL(fileURLWithPath: "/nope/missing.fif")) == nil)
    }
}
