//
//  RegexPatternLibrary.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Free, on-device aids for the PSA regex sub-selection popover
//  (CategoryRegexRule / PSAEpochingViews.swift), so writing a pattern — and
//  turning its capture groups into a category-name template — doesn't
//  require already knowing regex:
//
//  - `RegexPatternPreset.library` — a fixed menu of common shapes ("number
//    after a prefix", "text between delimiters", ...) to pick and tweak.
//  - `RegexPatternSuggester` — infers a starting pattern from the selected
//    code's own descriptions/labels by diffing them (longest common
//    prefix/suffix, generalize the varying middle), not a trained model or a
//    network call.
//  - `captureGroupCount(in:)` — how many `$1`/`$2`/… tokens a pattern
//    actually has, so the popover can offer one insert button per group
//    instead of the user counting parentheses.
//  - `CategoryTemplateSuggester` — once a pattern is chosen, proposes a
//    starting category-name template from what its capture group(s) actually
//    match across the sample data (same diff-the-data approach as the
//    pattern suggester, just one step further down the pipeline).
//

import Foundation

/// A named, ready-to-use pattern shown in the popover's "Examples" menu.
nonisolated struct RegexPatternPreset: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let pattern: String
    let example: String

    static let library: [RegexPatternPreset] = [
        RegexPatternPreset(
            title: "Number after a prefix",
            pattern: "cond=(\\d+)",
            example: "cond=42_correct → captures 42"
        ),
        RegexPatternPreset(
            title: "Text between two delimiters",
            pattern: "\\[(.+?)\\]",
            example: "trial[fam]_02 → captures fam"
        ),
        RegexPatternPreset(
            title: "Everything after the last underscore",
            pattern: "_([^_]+)$",
            example: "face_happy_02 → captures 02"
        ),
        RegexPatternPreset(
            title: "Everything before the first underscore",
            pattern: "^([^_]+)_",
            example: "face_happy_02 → captures face"
        ),
        RegexPatternPreset(
            title: "One of a fixed set of words",
            pattern: "(nov|rep|fam)",
            example: "n2_nov → captures nov (edit the word list to match your data)"
        ),
        RegexPatternPreset(
            title: "Digits at the very start",
            pattern: "^(\\d+)",
            example: "042_trial → captures 042"
        ),
        RegexPatternPreset(
            title: "Digits at the very end",
            pattern: "(\\d+)$",
            example: "trial_042 → captures 042"
        ),
        RegexPatternPreset(
            title: "Contains one of a few marker words",
            pattern: "\\b(target|standard|deviant)\\b",
            example: "matches only if the description contains one of those words"
        )
    ]
}

/// Infers a starting regex from a set of same-source-code sample strings —
/// a lightweight "diff the examples" heuristic (longest common prefix/suffix,
/// then generalize the varying middle into a capture group), not a trained
/// model or program-synthesis search. Deliberately simple: it only proposes a
/// pattern when the samples clearly share a common shape, and says nothing
/// otherwise rather than guessing.
nonisolated enum RegexPatternSuggester {
    struct Suggestion: Sendable, Equatable {
        let pattern: String
        let rationale: String
    }

    /// `rawSamples` are the raw description/label strings for the events of
    /// one selected source code (as shown in the preview list already).
    static func suggest(from rawSamples: [String]) -> Suggestion? {
        let samples = Array(Set(rawSamples.filter { !$0.isEmpty })).sorted()
        guard samples.count >= 2, samples.count <= 2000 else { return nil }

        let prefix = longestCommonPrefix(samples)
        let suffix = longestCommonSuffix(samples, prefixLength: prefix.count)

        let middles: [String] = samples.compactMap { sample in
            guard let start = sample.index(sample.startIndex, offsetBy: prefix.count, limitedBy: sample.endIndex),
                  let end = sample.index(sample.endIndex, offsetBy: -suffix.count, limitedBy: sample.endIndex),
                  start <= end else { return nil }
            return String(sample[start..<end])
        }
        guard middles.count == samples.count, middles.allSatisfy({ !$0.isEmpty }) else { return nil }

        let distinctMiddles = Set(middles)
        guard distinctMiddles.count > 1 else { return nil }

        let escapedPrefix = NSRegularExpression.escapedPattern(for: prefix)
        let escapedSuffix = NSRegularExpression.escapedPattern(for: suffix)
        let boundaryDescription = prefix.isEmpty && suffix.isEmpty
            ? "no shared prefix/suffix"
            : "shared \"\(prefix)\" … \"\(suffix)\""

        let charClass: String
        let rationale: String
        if distinctMiddles.allSatisfy({ value in value.allSatisfy(\.isNumber) }) {
            charClass = "\\d+"
            rationale = "All \(samples.count) values have \(boundaryDescription), varying only by a number in between."
        } else if distinctMiddles.count <= 8 {
            charClass = distinctMiddles.sorted()
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            rationale = "Found \(distinctMiddles.count) distinct values with \(boundaryDescription): \(distinctMiddles.sorted().joined(separator: ", "))."
        } else if distinctMiddles.allSatisfy({ value in value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }) {
            charClass = "\\w+"
            rationale = "All \(samples.count) values have \(boundaryDescription), varying by a word/number in between."
        } else {
            charClass = ".+?"
            rationale = "All \(samples.count) values have \(boundaryDescription); the middle varies freely."
        }

        return Suggestion(pattern: escapedPrefix + "(" + charClass + ")" + escapedSuffix, rationale: rationale)
    }

    private static func longestCommonPrefix(_ strings: [String]) -> String {
        guard var prefix = strings.first else { return "" }
        for value in strings.dropFirst() {
            while !value.hasPrefix(prefix) {
                if prefix.isEmpty { return "" }
                prefix.removeLast()
            }
        }
        return prefix
    }

    /// Longest common suffix, capped so it never eats back into the prefix on
    /// short strings (e.g. two identical short samples shouldn't have the
    /// prefix and suffix both claim the whole string, leaving no middle).
    private static func longestCommonSuffix(_ strings: [String], prefixLength: Int) -> String {
        guard var suffix = strings.first else { return "" }
        for value in strings.dropFirst() {
            while !value.hasSuffix(suffix) {
                if suffix.isEmpty { return "" }
                suffix.removeFirst()
            }
        }
        let shortestSampleLength = strings.map(\.count).min() ?? 0
        let allowedSuffixLength = max(shortestSampleLength - prefixLength, 0)
        if suffix.count > allowedSuffixLength {
            suffix = String(suffix.suffix(allowedSuffixLength))
        }
        return suffix
    }
}

/// Number of *capturing* groups in `pattern` — `(...)`  counts,
/// `(?:...)`/lookaround don't. `NSRegularExpression` already draws that
/// distinction correctly (unlike counting `(` characters by hand), so this
/// just asks it rather than re-implementing regex parsing. `0` for an
/// invalid or group-less pattern.
nonisolated func captureGroupCount(in pattern: String) -> Int {
    (try? NSRegularExpression(pattern: pattern))?.numberOfCaptureGroups ?? 0
}

/// Proposes a starting category-name template from what a pattern's capture
/// group(s) actually match across the sample data — the template-field
/// counterpart to `RegexPatternSuggester`. Diffs real captured values rather
/// than guessing blind: a single group whose captures already read like
/// short category names (letters/digits/underscore, not too many distinct
/// values) is suggested as-is (`$1`); anything else still gets `$1`, just
/// with a plainer rationale. Multiple groups are joined with `_`
/// (`$1_$2_$3`) as a reasonable, editable starting point.
nonisolated enum CategoryTemplateSuggester {
    struct Suggestion: Sendable, Equatable {
        let template: String
        let rationale: String
    }

    /// `samples` are the same raw description/label strings
    /// `RegexPatternSuggester` and the live preview already use.
    static func suggest(pattern: String, samples: [String]) -> Suggestion? {
        guard !pattern.isEmpty, let regex = try? Regex(pattern).ignoresCase() else { return nil }
        let groupCount = captureGroupCount(in: pattern)
        guard groupCount > 0 else { return nil }

        var firstGroupValues = Set<String>()
        var matchCount = 0
        for sample in samples {
            guard let match = sample.firstMatch(of: regex) else { continue }
            matchCount += 1
            if match.output.count > 1, let substring = match.output[1].substring {
                firstGroupValues.insert(String(substring))
            }
        }
        guard matchCount > 0 else { return nil }

        if groupCount == 1 {
            let readableValues = firstGroupValues.allSatisfy { value in
                !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            }
            if readableValues, !firstGroupValues.isEmpty, firstGroupValues.count <= 20 {
                let examples = firstGroupValues.sorted().prefix(3).joined(separator: ", ")
                return Suggestion(
                    template: "$1",
                    rationale: "The capture group already reads like a category name (e.g. \(examples)) — used as-is."
                )
            }
            return Suggestion(
                template: "$1",
                rationale: "One capture group — \"$1\" uses its matched text directly as the category name."
            )
        }

        let template = (1...groupCount).map { "$\($0)" }.joined(separator: "_")
        return Suggestion(
            template: template,
            rationale: "\(groupCount) capture groups — joined as \(template); edit to reorder or drop any of them."
        )
    }
}
