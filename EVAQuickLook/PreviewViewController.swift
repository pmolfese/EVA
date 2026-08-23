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
//  QuickLook preview for .mff packages. Reads only the XML sidecars and one binary
//  block header -- see MFFQuickLookSummary -- so the panel appears well inside the
//  few seconds QuickLook allows, even for a package with a 300 MB signal1.bin.
//

import AppKit
import QuickLookUI
import SwiftUI

final class PreviewViewController: NSViewController, QLPreviewingController {

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 560))
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let summary = try MFFQuickLookSummary.read(from: url, options: .preview)
        let hosting = NSHostingView(rootView: MFFPreviewView(summary: summary))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}
