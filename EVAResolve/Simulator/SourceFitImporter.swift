//
//  SourceFitImporter.swift
//  EVA Resolve
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Turns an averaged `.mff` package on disk into a `FitDataset` for the Source
//  window's Fit mode. This is the Resolve side of the EVA → Resolve handoff, and
//  also what File ▸ Open uses; both paths are the same function.
//
//  Geometry preference matches what EVA did in-process: the true 3-D
//  `coordinates.xml` when present, otherwise the 2-D `sensorLayout.xml` inverted
//  from its azimuthal projection (many averaged EGI files ship only the latter).
//
//  EVA may leave a small sidecar (`SourceFitImporter.sidecarName`) inside the
//  package naming the sample the user was looking at; when present the fit is
//  pre-highlighted around it.
//

import Foundation

@MainActor
enum SourceFitImporter {
    /// Written by EVA next to `signal1.bin` when it hands a recording over.
    static let sidecarName = "eva-resolve-fit.json"

    struct Sidecar: Codable, Sendable {
        /// Sample (relative to the epoch) to center the pre-highlight on.
        var centerSample: Int?
    }

    enum ImportError: LocalizedError {
        case notAveraged
        case noGeometry
        case noConditions

        var errorDescription: String? {
            switch self {
            case .notAveraged: return "This recording is not averaged — Resolve fits averaged conditions."
            case .noGeometry: return "The recording has no electrode positions (coordinates.xml or sensorLayout.xml)."
            case .noConditions: return "No averaged conditions of uniform length were found."
            }
        }
    }

    /// Reads the package off the main actor, then queues the dataset for the
    /// Source window (opening it if needed happens at the call site's scene).
    static func importAndQueue(_ url: URL) {
        Task {
            do {
                let (dataset, selection) = try await Task.detached(priority: .userInitiated) {
                    try load(url)
                }.value
                PendingSourceFit.shared.push(.init(dataset: dataset, selection: selection))
            } catch {
                PendingSourceFit.shared.report(error.localizedDescription)
            }
        }
    }

    /// Synchronous load; safe to call from any thread.
    nonisolated static func load(_ url: URL) throws -> (SourceSimulatorController.FitDataset, ClosedRange<Int>?) {
        let signal = try MFFReader().loadSignal(from: url)
        guard signal.isAveraged, !signal.epochSegments.isEmpty else { throw ImportError.notAveraged }
        let dataset = try makeDataset(signal: signal, packageURL: url)
        let sidecarURL = url.appendingPathComponent(sidecarName)
        var selection: ClosedRange<Int>?
        if let data = try? Data(contentsOf: sidecarURL),
           let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) {
            selection = preHighlight(
                relative: sidecar.centerSample, length: dataset.sampleCount, rate: dataset.sampleRate)
        }
        return (dataset, selection)
    }

    /// A ~±30 ms window around the given latency, clamped to the epoch.
    nonisolated static func preHighlight(relative: Int?, length: Int, rate: Double) -> ClosedRange<Int>? {
        guard let relative, length > 1, rate > 0 else { return nil }
        let half = max(1, Int((0.03 * rate).rounded()))
        let lower = max(0, relative - half)
        let upper = min(length - 1, relative + half)
        return lower <= upper ? lower...upper : nil
    }

    nonisolated static func makeDataset(
        signal: MFFSignalData, packageURL: URL
    ) throws -> SourceSimulatorController.FitDataset {
        let dataChannels = signal.data.count
        let montage: Montage
        let channelCount: Int
        if let geometry = ElectrodeGeometry.load(from: packageURL) {
            var count = 0
            while count < dataChannels, geometry.positions[count] != nil { count += 1 }
            guard count >= 3 else { throw ImportError.noGeometry }
            let names = signal.channelNames.map { Array($0.prefix(count)) }
            guard let m = try? Montage.fromGeometry(geometry, channelCount: count, signalChannelNames: names)
            else { throw ImportError.noGeometry }
            montage = m
            channelCount = count
        } else if let layout = SensorLayout.load(fromPackageContaining: signal.signalURL)?
                    .includingReference(forChannelCount: dataChannels) {
            var byIndex: [Int: SensorPosition] = [:]
            for position in layout.positions { byIndex[position.channelIndex] = position }
            var count = 0
            while count < dataChannels, byIndex[count] != nil { count += 1 }
            guard count >= 3 else { throw ImportError.noGeometry }
            let names = signal.channelNames.map { Array($0.prefix(count)) }
            guard let m = montageFromSensorLayout(layout, channelCount: count, names: names)
            else { throw ImportError.noGeometry }
            montage = m
            channelCount = count
        } else {
            throw ImportError.noGeometry
        }

        let totalSamples = signal.data.first?.count ?? 0
        var conditions: [SourceSimulatorController.FitDataset.ConditionData] = []
        var expectedLength: Int?
        for segment in signal.epochSegments {
            guard segment.startSample >= 0, segment.endSample >= segment.startSample,
                  segment.endSample < totalSamples else { continue }
            let length = segment.endSample - segment.startSample + 1
            if let expectedLength, expectedLength != length { continue }  // keep uniform length
            expectedLength = length
            var data = (0..<channelCount).map { channel in
                (segment.startSample...segment.endSample).map { Double(signal.data[channel][$0]) }
            }
            // Match the average-reference forward the fit solves against.
            EEGReferencing.apply(.average, to: &data)
            conditions.append(.init(name: segment.category, data: data))
        }
        guard !conditions.isEmpty else { throw ImportError.noConditions }

        return SourceSimulatorController.FitDataset(
            label: "\(conditions.count) condition\(conditions.count == 1 ? "" : "s") · \(montage.name)",
            conditions: conditions,
            montage: montage,
            headModel: .standardThreeShell,
            reference: .average,
            sampleRate: signal.samplingRate,
            startSample: 0,
            truth: nil
        )
    }

    /// Builds an angular montage from the 2-D sensor layout by inverting its
    /// azimuthal projection: disc radius → arc angle from the vertex, disc angle →
    /// azimuth. An approximation (the layout is a flat projection, not true 3-D),
    /// used only when `coordinates.xml` is absent.
    nonisolated static func montageFromSensorLayout(
        _ layout: SensorLayout, channelCount: Int, names: [String]?
    ) -> Montage? {
        var byIndex: [Int: SensorPosition] = [:]
        for position in layout.positions { byIndex[position.channelIndex] = position }
        var electrodes: [Electrode] = []
        for index in 0..<channelCount {
            guard let position = byIndex[index] else { return nil }
            let radius = (position.x * position.x + position.y * position.y).squareRoot()
            let theta = min(120.0, radius * 90.0)          // r = 1 → equator (90°)
            let phi = atan2(position.x, position.y) * 180.0 / .pi
            let name = (names?.indices.contains(index) == true) ? names![index] : "E\(index + 1)"
            electrodes.append(Electrode(name: name, thetaDegrees: theta, phiDegrees: phi))
        }
        guard !electrodes.isEmpty else { return nil }
        return Montage(name: layout.name.isEmpty ? "Sensor layout" : layout.name, electrodes: electrodes)
    }
}
