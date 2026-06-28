//
//  MotionParametersTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//

import Testing
import Foundation
@testable import EVA

struct MotionParametersTests {

    // MARK: - Parsing

    @Test func parsesSixColumnFile() throws {
        let text = """
        0 0 0 0 0 0
        0.1 -0.2 0.3 0.4 -0.5 0.6
        """
        let mp = try MotionParameters.parse(text: text, sourceName: "x.1D")
        #expect(mp.count == 2)
        let s = mp.samples[1]
        #expect(abs(s.roll - 0.1) < 1e-9)
        #expect(abs(s.pitch + 0.2) < 1e-9)
        #expect(abs(s.yaw - 0.3) < 1e-9)
        #expect(abs(s.dS - 0.4) < 1e-9)
        #expect(abs(s.dL + 0.5) < 1e-9)
        #expect(abs(s.dP - 0.6) < 1e-9)
    }

    @Test func parsesNineColumnDfileDroppingIndexAndRMS() throws {
        // n roll pitch yaw dS dL dP rmsold rmsnew
        let text = """
        0   0 0 0 0 0 0   0 0
        1   0.1 0.2 0.3 0.4 0.5 0.6   88.46 87.39
        """
        let mp = try MotionParameters.parse(text: text, sourceName: "d.1D")
        #expect(mp.count == 2)
        let s = mp.samples[1]
        // Columns 1..6 are the motion params; index and the two RMS columns drop.
        #expect(abs(s.roll - 0.1) < 1e-9)
        #expect(abs(s.dP - 0.6) < 1e-9)
    }

    @Test func skipsCommentAndBlankLines() throws {
        let text = """
        # 3dvolreg matrices header
        0 0 0 0 0 0

        0.1 0 0 0 0 0
        """
        let mp = try MotionParameters.parse(text: text, sourceName: "x.1D")
        #expect(mp.count == 2)
    }

    @Test func throwsOnUnexpectedColumnCount() {
        let text = "0 0 0 0\n0 0 0 0"   // 4 columns, neither 6 nor 9
        #expect(throws: MotionParametersError.self) {
            _ = try MotionParameters.parse(text: text, sourceName: "bad.1D")
        }
    }

    @Test func throwsOnNoData() {
        #expect(throws: MotionParametersError.self) {
            _ = try MotionParameters.parse(text: "# only a comment\n\n", sourceName: "empty.1D")
        }
    }

    // MARK: - Framewise displacement

    @Test func framewiseDisplacementFirstSampleIsZero() throws {
        let mp = try MotionParameters.parse(text: "0 0 0 0 0 0\n1 0 0 0 0 0", sourceName: "x")
        let fd = mp.framewiseDisplacement()
        #expect(fd.count == 2)
        #expect(fd[0] == 0)
    }

    @Test func framewiseDisplacementMatchesHandComputation() throws {
        // s0: origin; s1: +1 deg roll; s2: same roll, +2 mm dS.
        let text = """
        0 0 0 0 0 0
        1 0 0 0 0 0
        1 0 0 2 0 0
        """
        let mp = try MotionParameters.parse(text: text, sourceName: "x")
        let fd = mp.framewiseDisplacement(radiusMm: 50)
        let k = Double.pi / 180 * 50            // deg -> mm on 50 mm sphere
        #expect(abs(fd[1] - k) < 1e-9)          // 1 deg of roll
        #expect(abs(fd[2] - 2.0) < 1e-9)        // 2 mm of translation only
    }

    @Test func volumesExceedingThreshold() throws {
        let text = """
        0 0 0 0 0 0
        1 0 0 0 0 0
        1 0 0 2 0 0
        """
        let mp = try MotionParameters.parse(text: text, sourceName: "x")
        // FD ~ [0, 0.87, 2.0]
        #expect(mp.volumesExceeding(threshold: 1.0) == [2])
        #expect(mp.volumesExceeding(threshold: 0.5) == [1, 2])
        #expect(mp.volumesExceeding(threshold: 5.0).isEmpty)
    }

    // MARK: - Golden test against the real AFNI fixtures

    /// The repository's resources/ directory, derived from this test file's path.
    private var resourcesURL: URL {
        URL(filePath: #filePath)              // .../EVATests/MotionParametersTests.swift
            .deletingLastPathComponent()       // .../EVATests
            .deletingLastPathComponent()       // repo root
            .appending(path: "resources")
    }

    @Test func realFixturesParseAndTheTwoFormatsAgree() throws {
        let oneD = resourcesURL.appending(path: "test.1D")       // -1Dfile (6 col)
        let dfile = resourcesURL.appending(path: "testD.1D")     // -dfile  (9 col)
        // Skip cleanly if the fixtures aren't present in this checkout.
        try #require(FileManager.default.fileExists(atPath: oneD.path),
                     "missing fixture \(oneD.path)")

        let a = try MotionParameters.parse(text: String(contentsOf: oneD, encoding: .utf8),
                                           sourceName: "test.1D")
        let b = try MotionParameters.parse(text: String(contentsOf: dfile, encoding: .utf8),
                                           sourceName: "testD.1D")

        #expect(a.count > 100)                    // sanity: a real run's worth
        #expect(a.count == b.count)
        // The -1Dfile and -dfile encode the same motion; they must agree. Reduce
        // to a single max-difference so we don't pay per-#expect overhead 1000s
        // of times in a loop.
        var maxDiff = 0.0
        for i in 0..<min(a.count, b.count) {
            let x = a.samples[i], y = b.samples[i]
            maxDiff = max(maxDiff, abs(x.roll - y.roll), abs(x.pitch - y.pitch),
                          abs(x.yaw - y.yaw), abs(x.dS - y.dS),
                          abs(x.dL - y.dL), abs(x.dP - y.dP))
        }
        #expect(maxDiff < 1e-4, "formats diverge by \(maxDiff)")
    }
}
