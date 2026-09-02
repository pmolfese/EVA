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
//  Format-neutral Finder thumbnail entry point. The renderer for each format is
//  shared with the preview extension and test target.
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
        let startedAt = ContinuousClock.now
        Self.log.debug("provideThumbnail for \(request.fileURL.lastPathComponent, privacy: .public)")
        enum Renderer {
            case mff(MFFThumbnailRenderer)
            case cifti(CIFTIThumbnailRenderer)
            case nifti(NIfTIThumbnailRenderer)
            case gifti(GIFTIThumbnailRenderer)
            case mgh(MGHThumbnailRenderer)

            func draw(in context: CGContext, size: CGSize) {
                switch self {
                case .mff(let renderer): renderer.draw(in: context, size: size)
                case .cifti(let renderer): renderer.draw(in: context, size: size)
                case .nifti(let renderer): renderer.draw(in: context, size: size)
                case .gifti(let renderer): renderer.draw(in: context, size: size)
                case .mgh(let renderer): renderer.draw(in: context, size: size)
                }
            }
        }

        let renderer: Renderer
        do {
            guard let format = EVAPreviewFormat.identify(request.fileURL) else {
                throw EVAPreviewError.unsupportedFile(request.fileURL)
            }
            switch format {
            case .mff:
                let summary = try MFFQuickLookSummary.read(from: request.fileURL, options: .thumbnail)
                let model = MFFThumbnailRenderer.Model(summary: summary)
                let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
                renderer = .mff(MFFThumbnailRenderer(model: model, palette: isDark ? .dark : .light))
            case .cifti:
                let model = try CIFTIQuickLookReader.read(from: request.fileURL)
                renderer = .cifti(CIFTIThumbnailRenderer(model: model))
            case .nifti:
                let model = try NIfTIQuickLookReader.read(from: request.fileURL)
                renderer = .nifti(NIfTIThumbnailRenderer(model: model))
            case .gifti:
                let model = try GIFTIQuickLookReader.read(from: request.fileURL)
                renderer = .gifti(GIFTIThumbnailRenderer(model: model))
            case .mgh:
                let model = try MGHQuickLookReader.read(from: request.fileURL)
                renderer = .mgh(MGHThumbnailRenderer(model: model))
            }
        } catch {
            Self.log.error("summary read failed: \(error.localizedDescription, privacy: .public)")
            handler(nil, error)
            return
        }

        let side = min(request.maximumSize.width, request.maximumSize.height)
        let contextSize = CGSize(width: side, height: side)

        handler(
            QLThumbnailReply(contextSize: contextSize) { context in
                renderer.draw(in: context, size: contextSize)
                return true
            },
            nil
        )
        let elapsed = startedAt.duration(to: .now)
        Self.log.notice("Prepared thumbnail in \(elapsed, privacy: .public)")
    }
}
