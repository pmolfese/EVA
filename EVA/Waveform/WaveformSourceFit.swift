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
//  SIM-3 Stage 4 — the "Fit Source Model" bridge from a recording's averaged
//  butterfly / topography into the Source window's Fit mode. Packages every
//  averaged condition (channels × samples) plus the recording's real electrode
//  geometry, hands them over, and opens the Source window pre-highlighted.
//

import SwiftUI

extension WaveformView {
    /// A source-model fit needs averaged categories and some electrode geometry —
    /// the true 3-D `coordinates.xml` if present, otherwise the 2-D `sensorLayout`
    /// (many averaged EGI files ship only the latter).
    func canFitSourceModel() -> Bool {
        (electrodeGeometry != nil || recording.sensorLayout != nil)
            && epoching.isAveraged
            && epoching.epochedSignal != nil
            && !epoching.epochSegments.isEmpty
    }

    /// Hands every averaged condition to the Source window's Fit mode, pre-
    /// highlighting a window centered on `relativeSample` (e.g. the latency the
    /// user was viewing). Opens (or fronts) the Source window.
    func fitSourceModel(centeredOnRelativeSample relativeSample: Int?) {
        guard let dataset = makeSourceFitDataset() else { return }
        let selection = preHighlight(
            relative: relativeSample, length: dataset.sampleCount, rate: dataset.sampleRate)
        PendingSourceFit.shared.push(.init(dataset: dataset, selection: selection))
        openWindow(id: EVAApp.sourceSimulatorWindowID)
    }

    /// A ~±30 ms window around the given latency, clamped to the epoch.
    private func preHighlight(relative: Int?, length: Int, rate: Double) -> ClosedRange<Int>? {
        guard let relative, length > 1, rate > 0 else { return nil }
        let half = max(1, Int((0.03 * rate).rounded()))
        let lower = max(0, relative - half)
        let upper = min(length - 1, relative + half)
        return lower <= upper ? lower...upper : nil
    }

    /// Builds a Fit dataset from the averaged categories and the real montage.
    /// One condition per averaged segment; each condition is average-referenced so
    /// it matches the average-reference forward the fit uses. `nil` when there is
    /// no averaged data or no electrode geometry.
    private func makeSourceFitDataset() -> SourceSimulatorController.FitDataset? {
        guard epoching.isAveraged,
              let signal = epoching.epochedSignal,
              !epoching.epochSegments.isEmpty else { return nil }
        let dataChannels = signal.data.count

        // Prefer true 3-D coordinates; fall back to the 2-D sensor layout.
        let montage: Montage
        let channelCount: Int
        if let geometry = electrodeGeometry {
            var count = 0
            while count < dataChannels, geometry.positions[count] != nil { count += 1 }
            guard count >= 3 else { return nil }
            let names = signal.channelNames.map { Array($0.prefix(count)) }
            guard let m = try? Montage.fromGeometry(geometry, channelCount: count, signalChannelNames: names)
            else { return nil }
            montage = m
            channelCount = count
        } else if let layout = recording.sensorLayout?.includingReference(forChannelCount: dataChannels) {
            var byIndex: [Int: SensorPosition] = [:]
            for position in layout.positions { byIndex[position.channelIndex] = position }
            var count = 0
            while count < dataChannels, byIndex[count] != nil { count += 1 }
            guard count >= 3 else { return nil }
            let names = signal.channelNames.map { Array($0.prefix(count)) }
            guard let m = montageFromSensorLayout(layout, channelCount: count, names: names) else { return nil }
            montage = m
            channelCount = count
        } else {
            return nil
        }

        let totalSamples = signal.data.first?.count ?? 0
        var conditions: [SourceSimulatorController.FitDataset.ConditionData] = []
        var expectedLength: Int?
        for segment in epoching.epochSegments {
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
            conditions.append(.init(name: epoching.displayCategory(segment.category), data: data))
        }
        guard !conditions.isEmpty else { return nil }

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
    private func montageFromSensorLayout(
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
