//
//  ThumbnailProvider.swift
//  EVAThumbnail
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Finder thumbnails for .mff packages. Reads the XML sidecars only -- events are
//  skipped entirely, since the icon needs the file type and the condition count
//  and nothing else.
//

import Foundation
import OSLog
import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {

    private static let log = Logger(subsystem: "gov.nih.nimh.cmn.eva.thumbnail", category: "thumbnail")

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        Self.log.debug("provideThumbnail for \(request.fileURL.lastPathComponent, privacy: .public)")
        let model: MFFThumbnailRenderer.Model
        do {
            let summary = try MFFQuickLookSummary.read(from: request.fileURL, options: .thumbnail)
            model = MFFThumbnailRenderer.Model(summary: summary)
        } catch {
            Self.log.error("summary read failed: \(error.localizedDescription, privacy: .public)")
            handler(nil, error)
            return
        }

        // A thumbnail extension runs headless, so there is no window whose
        // appearance we could consult. Read the global setting directly and fall
        // back to light, which is also what the opaque backing is tuned for.
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let renderer = MFFThumbnailRenderer(model: model, palette: isDark ? .dark : .light)

        let side = min(request.maximumSize.width, request.maximumSize.height)
        let contextSize = CGSize(width: side, height: side)

        handler(
            QLThumbnailReply(contextSize: contextSize) { context in
                renderer.draw(in: context, size: contextSize)
                return true
            },
            nil
        )
    }
}
