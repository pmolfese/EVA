//
//  UpdateChecker.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import AppKit
import Foundation

/// A version parsed from EVA's marketing version or a GitHub release tag.
///
/// EVA historically used suffixes such as `0.1.2b`, so this deliberately
/// accepts both those versions and conventional tags such as `v0.1.2-beta.1`.
struct AppVersion: Comparable, Equatable {
    let source: String
    private let components: [Int]
    private let prerelease: String?

    init?(_ source: String) {
        var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }

        let numericPrefix = value.prefix { $0.isNumber || $0 == "." }
        guard !numericPrefix.isEmpty else { return nil }

        let componentStrings = numericPrefix.split(separator: ".", omittingEmptySubsequences: false)
        guard !componentStrings.contains(where: \.isEmpty) else { return nil }

        let parsedComponents = componentStrings.compactMap { Int($0) }
        guard parsedComponents.count == componentStrings.count else { return nil }

        let remainder = value.dropFirst(numericPrefix.count)
        let versionSuffix = remainder
            .trimmingCharacters(in: CharacterSet(charactersIn: "-+._ "))

        self.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        self.components = parsedComponents
        self.prerelease = versionSuffix.isEmpty ? nil : versionSuffix.lowercased()
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let componentCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<componentCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case let (.some(left), .some(right)):
            return left.compare(right, options: [.caseInsensitive, .numeric]) == .orderedAscending
        }
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

struct GitHubRelease: Decodable, Equatable {
    let tagName: String
    let name: String?
    let pageURL: URL
    let isDraft: Bool
    let isPrerelease: Bool
    let publishedAt: String?

    var version: AppVersion? { AppVersion(tagName) }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case pageURL = "html_url"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case publishedAt = "published_at"
    }
}

enum UpdateCheckResult: Equatable {
    case updateAvailable(currentVersion: String, release: GitHubRelease)
    case upToDate(currentVersion: String, release: GitHubRelease)
    case currentIsNewer(currentVersion: String, release: GitHubRelease)
}

enum UpdateCheckError: LocalizedError {
    case invalidCurrentVersion(String)
    case invalidReleaseTag(String)
    case invalidResponse
    case noPublishedRelease
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case let .invalidCurrentVersion(version):
            return "EVA's current version (\(version)) could not be compared."
        case let .invalidReleaseTag(tag):
            return "The latest GitHub release tag (\(tag)) is not a recognizable version."
        case .invalidResponse:
            return "GitHub returned an unexpected response."
        case .noPublishedRelease:
            return "GitHub does not have a published EVA release yet."
        case let .serverError(statusCode):
            return "GitHub returned an error (HTTP \(statusCode))."
        }
    }
}

struct UpdateChecker {
    static let releasesPageURL = URL(string: "https://github.com/pmolfese/EVA/releases")!
    private static let releasesURL = URL(
        string: "https://api.github.com/repos/pmolfese/EVA/releases?per_page=20"
    )!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func check(currentVersion: String) async throws -> UpdateCheckResult {
        guard let installedVersion = AppVersion(currentVersion) else {
            throw UpdateCheckError.invalidCurrentVersion(currentVersion)
        }

        let request = Self.releasesRequest(currentVersion: currentVersion)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        guard httpResponse.statusCode != 404 else {
            throw UpdateCheckError.noPublishedRelease
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateCheckError.serverError(httpResponse.statusCode)
        }

        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        guard let release = Self.latestPublishedRelease(in: releases) else {
            throw UpdateCheckError.noPublishedRelease
        }
        guard let releaseVersion = release.version else {
            throw UpdateCheckError.invalidReleaseTag(release.tagName)
        }

        if installedVersion < releaseVersion {
            return .updateAvailable(currentVersion: currentVersion, release: release)
        }
        if installedVersion == releaseVersion {
            return .upToDate(currentVersion: currentVersion, release: release)
        }
        return .currentIsNewer(currentVersion: currentVersion, release: release)
    }

    /// GitHub's `releases/latest` endpoint excludes prereleases. EVA currently
    /// publishes prereleases, so choose the newest published, non-draft release
    /// from the releases collection instead.
    static func latestPublishedRelease(in releases: [GitHubRelease]) -> GitHubRelease? {
        releases
            .filter { !$0.isDraft && $0.publishedAt != nil }
            .max { ($0.publishedAt ?? "") < ($1.publishedAt ?? "") }
    }

    static func releasesRequest(currentVersion: String) -> URLRequest {
        var request = URLRequest(
            url: Self.releasesURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 20
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("EVA/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }
}

@MainActor
enum UpdateAlertPresenter {
    static func present(_ result: UpdateCheckResult) {
        let alert = NSAlert()
        alert.alertStyle = .informational

        switch result {
        case let .updateAvailable(currentVersion, release):
            alert.messageText = release.isPrerelease
                ? "A New EVA Prerelease Is Available"
                : "A New Version of EVA Is Available"
            let releaseKind = release.isPrerelease ? " prerelease" : ""
            alert.informativeText = "EVA \(release.tagName)\(releaseKind) is available. You are currently using EVA \(currentVersion)."
            alert.addButton(withTitle: "View Release")
            alert.addButton(withTitle: "Not Now")

            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.pageURL)
            }

        case let .upToDate(currentVersion, _):
            alert.messageText = "EVA Is Up to Date"
            alert.informativeText = "You are using the latest version of EVA (\(currentVersion))."
            alert.addButton(withTitle: "OK")
            alert.runModal()

        case let .currentIsNewer(currentVersion, release):
            alert.messageText = "This Version Is Newer Than the Latest Release"
            alert.informativeText = "You are using EVA \(currentVersion). The latest public GitHub release is \(release.tagName)."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    static func present(error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Unable to Check for Updates"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
