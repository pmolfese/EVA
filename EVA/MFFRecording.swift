//
//  MFFRecording.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Non-document app model for opening and viewing EEG recordings.
//

import Combine
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// EGI MFF recording package. EGI/Philips owns the format; EVA reads it.
    static var mff: UTType {
        UTType(importedAs: "com.egi.mff")
    }
}

/// A loaded or loading EEG recording used by EVA's normal WindowGroup app flow.
final class MFFRecording: ObservableObject, Identifiable {
    nonisolated let objectWillChange = ObservableObjectPublisher()

    let id = UUID()
    let packageURL: URL
    let packageName: String

    private(set) var signal: MFFSignalData?
    /// Peripheral/physiological channels (ECG, EMG, …), shown alongside the EEG.
    private(set) var pnsSignal: MFFSignalData?
    private(set) var sensorLayout: SensorLayout?
    private(set) var electrodeGeometry: ElectrodeGeometry?
    private(set) var loadError: String?
    private(set) var isLoading = true
    private(set) var loadProgress: Double?
    private(set) var loadStatusMessage = "Preparing to read recording"

    init(packageURL: URL) {
        self.packageURL = packageURL
        self.packageName = packageURL.lastPathComponent
    }

    @MainActor
    func loadIfNeeded() async {
        guard isLoading, signal == nil, loadError == nil else { return }

        let url = packageURL
        objectWillChange.send()
        loadProgress = 0
        loadStatusMessage = "Opening \(packageName)"

        let (progressContinuation, progressTask) = ProgressBridge.make { (update: LoadProgressUpdate) in
            guard self.isLoading else { return }
            self.objectWillChange.send()
            self.loadProgress = update.fraction
            self.loadStatusMessage = update.message
        }

        let progressHandler: @Sendable (Double, String) -> Void = { fraction, message in
            let clamped = min(max(fraction, 0), 1)
            progressContinuation.yield(LoadProgressUpdate(fraction: clamped, message: message))
        }

        let result = await Task.detached(priority: .userInitiated) {
            Self.load(packageURL: url, progress: progressHandler)
        }.value
        progressContinuation.finish()
        progressTask.cancel()

        objectWillChange.send()
        signal = result.signal
        pnsSignal = result.pnsSignal
        sensorLayout = result.layout
        electrodeGeometry = result.geometry
        loadError = result.error
        loadProgress = nil
        loadStatusMessage = result.error == nil ? "Loaded" : "Load failed"
        isLoading = false
    }

    private struct LoadProgressUpdate: Sendable {
        var fraction: Double
        var message: String
    }

    private struct LoadResult: Sendable {
        var signal: MFFSignalData?
        var pnsSignal: MFFSignalData?
        var layout: SensorLayout?
        var geometry: ElectrodeGeometry?
        var error: String?
    }

    nonisolated private static func load(
        packageURL: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) -> LoadResult {
        let didStartAccessing = packageURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                packageURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let imported = try SignalImportReader.load(from: packageURL, progress: progress)
            return LoadResult(
                signal: imported.signal,
                pnsSignal: imported.pnsSignal,
                layout: imported.layout,
                geometry: imported.geometry,
                error: nil
            )
        } catch {
            return LoadResult(signal: nil, layout: nil, geometry: nil, error: error.localizedDescription)
        }
    }
}
