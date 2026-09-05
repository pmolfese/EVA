//
//  PreviewViewController.swift
//  EVAQuickLook
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Format-neutral Quick Look entry point. Format readers and views live in
//  shared source groups so adding another neuroimaging format (such as GIFTI)
//  requires one routing case rather than another extension target.
//

import AppKit
import OSLog
import QuickLookUI
import SwiftUI

final class PreviewViewController: NSViewController, QLPreviewingController {

    private static let log = Logger(subsystem: "gov.nih.nimh.cmn.eva.quicklook", category: "preview")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let startedAt = ContinuousClock.now
        Self.log.debug("Preparing preview for \(url.lastPathComponent, privacy: .public)")
        guard let format = EVAPreviewFormat.identify(url) else {
            throw EVAPreviewError.unsupportedFile(url)
        }
        guard EVAQuickLookPreferences.isEnabled(format) else {
            throw EVAPreviewError.disabledFormat(format)
        }
        let content: AnyView
        switch format {
        case .mff:
            let summary = try MFFQuickLookSummary.read(from: url, options: .preview)
            content = AnyView(MFFPreviewView(summary: summary))
        case .cifti:
            let model = try await Task.detached(priority: .userInitiated) {
                try CIFTIQuickLookReader.read(from: url)
            }.value
            content = AnyView(CIFTIPreviewView(model: model))
        case .nifti:
            let model = try await Task.detached(priority: .userInitiated) {
                try NIfTIQuickLookReader.read(from: url)
            }.value
            content = AnyView(NIfTIPreviewView(model: model))
        case .gifti:
            let model = try await Task.detached(priority: .userInitiated) {
                try GIFTIQuickLookReader.read(from: url)
            }.value
            content = AnyView(GIFTIPreviewView(model: model))
        case .mgh:
            let model = try await Task.detached(priority: .userInitiated) {
                try MGHQuickLookReader.read(from: url)
            }.value
            content = AnyView(MGHPreviewView(model: model))
        case .dicom:
            let model = try await Task.detached(priority: .userInitiated) {
                try DICOMQuickLookReader.read(from: url)
            }.value
            content = AnyView(DICOMPreviewView(model: model))
        }
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        preferredContentSize = NSSize(width: 800, height: 600)
        let elapsed = startedAt.duration(to: .now)
        Self.log.notice("Installed \(format.rawValue, privacy: .public) preview view in \(elapsed, privacy: .public)")
    }
}
