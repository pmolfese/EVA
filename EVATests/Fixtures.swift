//
//  Fixtures.swift
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
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//

import Foundation

/// Resolves read-only test fixtures committed under `EVATests/Fixtures/`.
///
/// Fixtures are located relative to this source file rather than via the app
/// bundle, so the shipping app target does not include the large sample files.
/// The committed `.mff` packages are redistributed from BEL-Public/mffpy under
/// the Apache License 2.0 — see `EVATests/Fixtures/LICENSE-mffpy.txt`.
enum Fixtures {

    /// Absolute URL of the `EVATests/Fixtures/` directory.
    ///
    /// `#filePath` points at this file (`<repo>/EVATests/Fixtures.swift`); the
    /// fixtures live alongside it at `<repo>/EVATests/Fixtures/`.
    static let directory: URL = {
        URL(fileURLWithPath: #filePath)        // <repo>/EVATests/Fixtures.swift
            .deletingLastPathComponent()        // <repo>/EVATests
            .appendingPathComponent("Fixtures")
    }()

    /// Returns the URL of a named fixture (e.g. `"example_3.mff"`), verifying it
    /// exists so tests fail with a clear message rather than an opaque read error.
    static func url(_ name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        precondition(
            FileManager.default.fileExists(atPath: url.path),
            "Missing test fixture \(name) at \(url.path)"
        )
        return url
    }
}
