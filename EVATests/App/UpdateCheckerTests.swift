//
//  UpdateCheckerTests.swift
//  EVATests
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Foundation
import Testing
@testable import EVA

struct UpdateCheckerTests {
    @Test func parsesGitHubAndBundleVersionFormats() throws {
        #expect(try #require(AppVersion("v0.1.2")) == AppVersion("0.1.2"))
        #expect(try #require(AppVersion("  V2.4.0-beta.1  ")) == AppVersion("2.4-beta.1"))
        #expect(AppVersion("release-1.2.3") == nil)
        #expect(AppVersion("1..2") == nil)
    }

    @Test func comparesNumericComponentsNumerically() throws {
        let older = try #require(AppVersion("0.9.9"))
        let newer = try #require(AppVersion("0.10.0"))
        let equivalent = try #require(AppVersion("0.10"))

        #expect(older < newer)
        #expect(newer == equivalent)
    }

    @Test func stableVersionFollowsPrerelease() throws {
        let beta = try #require(AppVersion("0.1.2b"))
        let releaseCandidate = try #require(AppVersion("0.1.2-rc1"))
        let stable = try #require(AppVersion("0.1.2"))

        #expect(beta < stable)
        #expect(releaseCandidate < stable)
    }

    @Test func decodesGitHubLatestReleaseResponse() throws {
        let data = Data(
            #"{"tag_name":"v0.2.0","name":"EVA 0.2.0","html_url":"https://github.com/pmolfese/EVA/releases/tag/v0.2.0","draft":false,"prerelease":true,"published_at":"2026-07-13T19:58:07Z"}"#.utf8
        )

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        #expect(release.tagName == "v0.2.0")
        #expect(release.name == "EVA 0.2.0")
        #expect(release.isPrerelease)
        #expect(release.pageURL.absoluteString.hasSuffix("/releases/tag/v0.2.0"))
        #expect(release.version == AppVersion("0.2.0"))
    }

    @Test func selectsNewestPublishedReleaseIncludingPrereleases() throws {
        let data = Data(
            #"""
            [
                {"tag_name":"v0.1.0","name":"EVA 0.1.0","html_url":"https://github.com/pmolfese/EVA/releases/tag/v0.1.0","draft":false,"prerelease":true,"published_at":"2026-07-07T03:43:21Z"},
                {"tag_name":"v0.1.1","name":"EVA 0.1.1","html_url":"https://github.com/pmolfese/EVA/releases/tag/v0.1.1","draft":false,"prerelease":true,"published_at":"2026-07-13T19:58:07Z"},
                {"tag_name":"v0.2.0","name":"Draft","html_url":"https://github.com/pmolfese/EVA/releases/tag/v0.2.0","draft":true,"prerelease":false,"published_at":null}
            ]
            """#.utf8
        )
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)

        let latest = try #require(UpdateChecker.latestPublishedRelease(in: releases))

        #expect(latest.tagName == "v0.1.1")
        #expect(latest.isPrerelease)
    }

    @Test func releaseRequestBypassesStaleCachedResponses() {
        let request = UpdateChecker.releasesRequest(currentVersion: "0.1.2b")

        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "EVA/0.1.2b")
    }
}
