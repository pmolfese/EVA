//
//  EVAPreviewFormat.swift
//  EVAPreviewKit
//
//  Format-neutral routing shared by EVA's Quick Look preview and thumbnail
//  extensions. Format-specific parsing and rendering stay out of the extension
//  entry points so new neuroimaging formats remain small routing additions.
//

import Foundation

nonisolated enum EVAPreviewFormat: String, Sendable {
    case mff
    case cifti
    case nifti
    case gifti
    case mgh

    private static let ciftiSuffixes = [
        ".dconn.nii", ".dtseries.nii", ".pconn.nii", ".ptseries.nii",
        ".dscalar.nii", ".dlabel.nii", ".pscalar.nii", ".pdconn.nii",
        ".dpconn.nii", ".pconnseries.nii", ".pconnscalar.nii",
        ".sdseries.nii", ".dfan.nii", ".dfibersamp.nii", ".dfansamp.nii"
    ]

    static func identify(_ url: URL) -> EVAPreviewFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".mff") { return .mff }
        if isCIFTIFileName(name) { return .cifti }
        if name.hasSuffix(".nii") || name.hasSuffix(".nii.gz") { return .nifti }
        if name.hasSuffix(".gii") { return .gifti }
        if name.hasSuffix(".mgh") || name.hasSuffix(".mgz") || name.hasSuffix(".mgh.gz") { return .mgh }
        return nil
    }

    static func isCIFTIFileName(_ name: String) -> Bool {
        let uncompressedName = name.hasSuffix(".gz") ? String(name.dropLast(3)) : name
        return ciftiSuffixes.contains { uncompressedName.hasSuffix($0) }
    }
}

nonisolated enum EVAPreviewError: LocalizedError, Sendable {
    case unsupportedFile(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url):
            return "\(url.lastPathComponent) is not supported by EVA Quick Look."
        }
    }
}
