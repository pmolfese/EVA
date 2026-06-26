//
//  MFFRecording.swift
//  EVA
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
    private(set) var sensorLayout: SensorLayout?
    private(set) var electrodeGeometry: ElectrodeGeometry?
    private(set) var loadError: String?
    private(set) var isLoading = true

    init(packageURL: URL) {
        self.packageURL = packageURL
        self.packageName = packageURL.lastPathComponent
    }

    @MainActor
    func loadIfNeeded() async {
        guard isLoading, signal == nil, loadError == nil else { return }

        let url = packageURL
        let result = await Task.detached(priority: .userInitiated) {
            Self.load(packageURL: url)
        }.value

        objectWillChange.send()
        signal = result.signal
        sensorLayout = result.layout
        electrodeGeometry = result.geometry
        loadError = result.error
        isLoading = false
    }

    private struct LoadResult: Sendable {
        var signal: MFFSignalData?
        var layout: SensorLayout?
        var geometry: ElectrodeGeometry?
        var error: String?
    }

    nonisolated private static func load(packageURL: URL) -> LoadResult {
        let didStartAccessing = packageURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                packageURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let imported = try SignalImportReader.load(from: packageURL)
            return LoadResult(
                signal: imported.signal,
                layout: imported.layout,
                geometry: imported.geometry,
                error: nil
            )
        } catch {
            return LoadResult(signal: nil, layout: nil, geometry: nil, error: error.localizedDescription)
        }
    }
}
