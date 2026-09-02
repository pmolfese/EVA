//
//  WaveformSourceFit.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  "Fit Source Model" — the bridge from a recording's averaged butterfly /
//  topography into EVA Resolve's Fit mode. Source analysis lives in Resolve (a
//  separate, sandboxed app), so the handoff is a file: every averaged condition
//  is written as an averaged `.mff` (with the recording's coordinates.xml /
//  sensorLayout.xml carried across by `MFFWriter`), a small sidecar names the
//  latency the user was viewing, and Launch Services opens the package in
//  Resolve — which is what grants Resolve access to it. Resolve's
//  `SourceFitImporter` rebuilds the fit dataset from the package.
//

import AppKit
import SwiftUI

extension WaveformView {
    static let resolveBundleIdentifier = "gov.nih.nimh.cmn.eva.resolve"
    /// Must match `SourceFitImporter.sidecarName` in EVA Resolve.
    static let resolveSidecarName = "eva-resolve-fit.json"

    /// A source-model fit needs averaged categories and some electrode geometry —
    /// the true 3-D `coordinates.xml` if present, otherwise the 2-D `sensorLayout`
    /// (many averaged EGI files ship only the latter). Resolve applies the same
    /// rule when it reads the package back.
    func canFitSourceModel() -> Bool {
        (electrodeGeometry != nil || recording.sensorLayout != nil)
            && epoching.isAveraged
            && epoching.epochedSignal != nil
            && !epoching.epochSegments.isEmpty
    }

    /// Writes the averaged conditions to a temporary `.mff` and opens it in EVA
    /// Resolve, pre-highlighted around `relativeSample` (e.g. the latency the
    /// user was viewing). Reports through `statusMessage` when Resolve is not
    /// installed or the write fails.
    func fitSourceModel(centeredOnRelativeSample relativeSample: Int?) {
        guard let signal = epoching.epochedSignal, epoching.isAveraged,
              !epoching.epochSegments.isEmpty else { return }
        let workspace = NSWorkspace.shared
        guard let resolveURL = workspace.urlForApplication(withBundleIdentifier: Self.resolveBundleIdentifier) else {
            mffExportStatusMessage = "EVA Resolve is not installed — source fitting lives in EVA Resolve."
            return
        }
        let segments = epoching.epochSegments
        let baseName = recording.packageURL.deletingPathExtension().lastPathComponent
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("EVAResolveHandoff", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent("\(baseName)-averaged.mff")
                    try MFFWriter.write(signal: signal, segments: segments, kind: .averaged, to: url)
                    let sidecar = try JSONEncoder().encode(ResolveFitSidecar(centerSample: relativeSample))
                    try sidecar.write(to: url.appendingPathComponent(Self.resolveSidecarName))
                    return url
                }.value
                workspace.open([url], withApplicationAt: resolveURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            } catch {
                mffExportStatusMessage = "Could not hand off to EVA Resolve: \(error.localizedDescription)"
            }
        }
    }

    /// Mirrors `SourceFitImporter.Sidecar` in EVA Resolve.
    struct ResolveFitSidecar: Codable, Sendable {
        var centerSample: Int?
    }
}
