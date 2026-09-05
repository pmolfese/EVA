//
//  EVAPreviewFormat.swift
//  EVAPreviewKit
//
//  Format-neutral routing shared by EVA's Quick Look preview and thumbnail
//  extensions. Format-specific parsing and rendering stay out of the extension
//  entry points so new neuroimaging formats remain small routing additions.
//

import Foundation

nonisolated enum EVAPreviewFormat: String, CaseIterable, Identifiable, Sendable {
    case mff
    case cifti
    case nifti
    case gifti
    case mgh
    case dicom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mff: "EGI MFF"
        case .cifti: "CIFTI"
        case .nifti: "NIfTI"
        case .gifti: "GIFTI"
        case .mgh: "FreeSurfer MGH/MGZ"
        case .dicom: "DICOM"
        }
    }

    var filenameExtensions: String {
        switch self {
        case .mff: ".mff"
        case .cifti: ".dscalar.nii, .dtseries.nii, and related"
        case .nifti: ".nii, .nii.gz"
        case .gifti: ".gii"
        case .mgh: ".mgh, .mgz, .mgh.gz"
        case .dicom: ".dcm, .ima"
        }
    }

    var preferenceKey: String { "quickLook.format.\(rawValue).enabled" }

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
        if name.hasSuffix(".dcm") || name.hasSuffix(".ima") { return .dicom }
        return nil
    }

    static func isCIFTIFileName(_ name: String) -> Bool {
        let uncompressedName = name.hasSuffix(".gz") ? String(name.dropLast(3)) : name
        return ciftiSuffixes.contains { uncompressedName.hasSuffix($0) }
    }
}

nonisolated enum EVAPreviewError: LocalizedError, Sendable {
    case unsupportedFile(URL)
    case disabledFormat(EVAPreviewFormat)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url):
            return "\(url.lastPathComponent) is not supported by EVA Quick Look."
        case .disabledFormat(let format):
            return "\(format.displayName) Quick Look is disabled in EVA Settings."
        }
    }
}
