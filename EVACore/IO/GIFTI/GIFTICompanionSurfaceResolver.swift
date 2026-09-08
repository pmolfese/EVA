//
//  GIFTICompanionSurfaceResolver.swift
//  EVAPreviewKit
//
//  Functional, shape, and label GIFTI files normally contain node values but
//  no coordinates or topology. When a matching surface is beside the data
//  file, Quick Look can safely borrow that geometry without coupling parsing
//  or rendering to a particular GIFTI naming convention.
//

import Foundation

nonisolated enum GIFTICompanionSurfaceResolver {
    private static let maximumCandidateCount = 32
    private static let maximumCandidateBytes: Int64 = 512 * 1024 * 1024

    static func attachIfAvailable(to model: GIFTIPreviewModel) -> GIFTIPreviewModel {
        guard !model.hasRenderableGeometry,
              let nodeCount = model.overlays.first?.values.count,
              nodeCount > 0 else {
            return model
        }

        let directory = model.url.deletingLastPathComponent()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return model
        }

        let candidates = contents
            .filter { candidate in
                guard candidate != model.url,
                      candidate.lastPathComponent.lowercased().hasSuffix(".gii") else {
                    return false
                }
                let values = try? candidate.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile != false else { return false }
                return Int64(values?.fileSize ?? 0) <= maximumCandidateBytes
            }
            .sorted { score($0, for: model.url) > score($1, for: model.url) }
            .prefix(maximumCandidateCount)

        for candidate in candidates {
            guard let surface = try? GIFTIQuickLookReader.readDocument(from: candidate),
                  surface.vertices.count == nodeCount,
                  !surface.vertices.isEmpty else {
                continue
            }
            return model.attachingGeometry(from: surface)
        }
        return model
    }

    private static func looksLikeSurface(_ filename: String) -> Bool {
        let name = filename.lowercased()
        let surfaceTerms = [
            ".surf.gii", "pial", "white", "smoothwm", "midthickness",
            "inflated", "inf_", "sphere", "mesh"
        ]
        return surfaceTerms.contains { name.contains($0) }
    }

    private static func score(_ candidate: URL, for dataURL: URL) -> Int {
        let candidateName = candidate.deletingPathExtension().lastPathComponent.lowercased()
        let dataName = dataURL.deletingPathExtension().lastPathComponent.lowercased()
        var result = 0

        let candidateTokens = tokens(candidateName)
        let dataTokens = tokens(dataName)
        result += candidateTokens.intersection(dataTokens).count * 8

        if looksLikeSurface(candidate.lastPathComponent) { result += 20 }

        if hemisphere(candidateName) == hemisphere(dataName), hemisphere(dataName) != nil {
            result += 40
        }
        if candidateName.contains("inflated") || candidateName.contains("inf_") { result += 6 }
        if candidateName.contains("midthickness") { result += 5 }
        if candidateName.contains("pial") { result += 4 }
        if candidateName.contains("white") || candidateName.contains("smoothwm") { result += 3 }
        if candidateName.contains("sphere") { result -= 2 }
        return result
    }

    private static func tokens(_ name: String) -> Set<String> {
        Set(name.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .subtracting(["gii", "func", "shape", "label", "surf"])
    }

    private static func hemisphere(_ name: String) -> String? {
        let nameTokens = tokens(name)
        if nameTokens.contains("lh") || nameTokens.contains("left") || name.contains("cortexleft") {
            return "left"
        }
        if nameTokens.contains("rh") || nameTokens.contains("right") || name.contains("cortexright") {
            return "right"
        }
        return nil
    }
}
