//
//  DifferenceWaveView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Condition A − condition B: a per-channel difference waveform (butterfly +
//  optional GFP) and a difference topomap at a chosen latency. Built as a
//  synthetic single-segment `MFFSignalData`/`EpochSegment` pair so every
//  existing plot (`OverlayButterflyPlot`, `GFPStripView`, `TopomapView`) draws
//  it exactly as if it were a real recorded condition — no new plotting code.
//

import SwiftUI

/// The subtraction result: a synthetic signal whose `data` is `A − B` per
/// channel, decimated to the shorter of the two epochs' lengths, and a
/// synthetic single-segment window over it starting at sample 0.
private struct DifferenceWaveResult {
    let signal: MFFSignalData
    let segment: EpochSegment
}

extension WaveformView {
    @ViewBuilder
    func averagesDifferencePane(signal: MFFSignalData, segments: [EpochSegment]) -> some View {
        averagesPanel {
            let categories = overlayAvailableCategories()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Difference Wave")
                        .font(.headline)
                    Spacer()
                    Picker("A", selection: differenceCategoryABinding(categories: categories)) {
                        Text("Choose A…").tag(Optional<String>.none)
                        ForEach(categories, id: \.self) { category in
                            Text(epoching.displayCategory(category)).tag(Optional(category))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Text("−")
                        .foregroundStyle(.secondary)
                    Picker("B", selection: differenceCategoryBBinding(categories: categories)) {
                        Text("Choose B…").tag(Optional<String>.none)
                        ForEach(categories, id: \.self) { category in
                            Text(epoching.displayCategory(category)).tag(Optional(category))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                if categories.count < 2 {
                    ContentUnavailableView(
                        "Need Two Conditions",
                        systemImage: "plusminus",
                        description: Text("Create at least two averaged categories to compute a difference wave.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else if let result = differenceWaveResult(signal: signal, segments: segments) {
                    DifferenceWaveContent(
                        view: self,
                        result: result,
                        categoryA: epoching.displayCategory(epoching.differenceCategoryA ?? categories.first ?? ""),
                        categoryB: epoching.displayCategory(epoching.differenceCategoryB ?? categories.dropFirst().first ?? "")
                    )
                } else {
                    ContentUnavailableView(
                        "Choose Two Conditions",
                        systemImage: "plusminus",
                        description: Text("Pick condition A and B above to compute A − B.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
        }
    }

    private func differenceCategoryABinding(categories: [String]) -> Binding<String?> {
        Binding(
            get: { epoching.differenceCategoryA ?? categories.first },
            set: { epoching.differenceCategoryA = $0 }
        )
    }

    private func differenceCategoryBBinding(categories: [String]) -> Binding<String?> {
        Binding(
            get: { epoching.differenceCategoryB ?? categories.dropFirst().first },
            set: { epoching.differenceCategoryB = $0 }
        )
    }

    /// `A − B` per channel, over the shorter of the two conditions' epoch
    /// windows. `nil` when either condition isn't chosen/available, or one has
    /// too short an epoch to difference meaningfully.
    private func differenceWaveResult(signal: MFFSignalData, segments: [EpochSegment]) -> DifferenceWaveResult? {
        let categories = overlayAvailableCategories()
        guard let categoryA = epoching.differenceCategoryA ?? categories.first,
              let categoryB = epoching.differenceCategoryB ?? categories.dropFirst().first,
              let segmentA = epoching.epochSegments.first(where: { $0.category == categoryA }),
              let segmentB = epoching.epochSegments.first(where: { $0.category == categoryB })
        else { return nil }

        let lengthA = segmentA.endSample - segmentA.startSample + 1
        let lengthB = segmentB.endSample - segmentB.startSample + 1
        let length = min(lengthA, lengthB)
        guard length > 1 else { return nil }

        var diffChannels: [[Float]] = []
        diffChannels.reserveCapacity(signal.data.count)
        for channel in signal.data {
            var diff = [Float](repeating: 0, count: length)
            for localSample in 0..<length {
                let sampleA = segmentA.startSample + localSample
                let sampleB = segmentB.startSample + localSample
                guard sampleA < channel.count, sampleB < channel.count else { continue }
                diff[localSample] = channel[sampleA] - channel[sampleB]
            }
            diffChannels.append(diff)
        }

        let diffSignal = signal.replacingSamples(diffChannels, signalTypeSuffix: "diff")
        let offset = min(max(segmentA.stimulusOffsetSamples, 0), length - 1)
        let diffSegment = EpochSegment(
            startSample: 0,
            endSample: length - 1,
            stimulusOffsetSamples: offset,
            category: "\(epoching.displayCategory(categoryA)) − \(epoching.displayCategory(categoryB))",
            sourceCode: "diff",
            sourceTimeSeconds: segmentA.sourceTimeSeconds,
            colorIndex: 0,
            contributingEpochCount: min(segmentA.contributingEpochCount, segmentB.contributingEpochCount)
        )
        return DifferenceWaveResult(signal: diffSignal, segment: diffSegment)
    }
}

/// Live pane content — a plain struct (rather than another `@ViewBuilder`
/// method) so it can own the latency-scrubber `@State` for the difference
/// topomap.
private struct DifferenceWaveContent: View {
    let view: WaveformView
    fileprivate let result: DifferenceWaveResult
    let categoryA: String
    let categoryB: String

    private let diffColor = Color.red

    var body: some View {
        let epochLength = max(result.segment.endSample - result.segment.startSample + 1, 1)
        let relativeSample = min(max(view.epoching.differenceRelativeSample ?? result.segment.stimulusOffsetSamples, 0), epochLength - 1)
        let samplingRate = result.signal.samplingRate
        let latencySeconds = samplingRate > 0 ? Double(relativeSample - result.segment.stimulusOffsetSamples) / samplingRate : 0

        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(categoryA) − \(categoryB)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(diffColor)

                VStack(spacing: 0) {
                    GeometryReader { proxy in
                        ZStack(alignment: .topLeading) {
                            OverlayButterflyPlot(
                                data: result.signal.data,
                                segments: [result.segment],
                                colors: [diffColor],
                                hiddenChannels: view.channels.hidden,
                                amplitudeScale: view.amplitudeScale,
                                samplingRate: result.signal.samplingRate,
                                highlightRelativeSample: relativeSample,
                                channelName: { view.eegChannelDisplayName(index: $0, signal: result.signal) },
                                onScrubRelativeSample: { sample in
                                    view.epoching.differenceRelativeSample = min(max(sample, 0), epochLength - 1)
                                }
                            )
                            .overlay(WaveformVoltageAxisOverlay(amplitudeScale: view.amplitudeScale))
                            .frame(width: proxy.size.width, height: view.epoching.showsAveragesGFP ? proxy.size.height - 48 : proxy.size.height)

                            if view.epoching.showsAveragesGFP {
                                GFPStripView(data: result.signal.data, segments: [result.segment], colors: [diffColor])
                                    .frame(width: proxy.size.width, height: 44)
                                    .offset(y: proxy.size.height - 44)
                            }
                        }
                    }
                    .frame(minHeight: 260)
                    WaveformTimeAxisView(segment: result.segment, samplingRate: result.signal.samplingRate)
                        .frame(height: 20)
                }
                .contextMenu {
                    view.figureSaveMenu(
                        title: "Difference Wave (\(categoryA) − \(categoryB))",
                        legend: [(categoryA, diffColor)],
                        size: CGSize(width: 780, height: (view.epoching.showsAveragesGFP ? 354 : 300) + 20),
                        seconds: view.figureSeconds([result.segment], samplingRate: result.signal.samplingRate),
                        scaleSize: CGSize(width: 780, height: 300)
                    ) {
                        VStack(spacing: 4) {
                            OverlayButterflyPlot(
                                data: result.signal.data,
                                segments: [result.segment],
                                colors: [diffColor],
                                hiddenChannels: view.channels.hidden,
                                amplitudeScale: view.amplitudeScale,
                                samplingRate: result.signal.samplingRate
                            )
                            .overlay(WaveformVoltageAxisOverlay(amplitudeScale: view.amplitudeScale))
                            if view.epoching.showsAveragesGFP {
                                GFPStripView(data: result.signal.data, segments: [result.segment], colors: [diffColor])
                                    .frame(height: 44)
                            }
                            WaveformTimeAxisView(segment: result.segment, samplingRate: result.signal.samplingRate)
                                .frame(height: 20)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            if let layout = view.recording.sensorLayout {
                VStack(spacing: 6) {
                    Text(String(format: "%.3f s", latencySeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    TopomapView(
                        layout: layout,
                        values: view.topomapValues(at: result.segment.startSample + relativeSample, in: result.signal),
                        timeSeconds: latencySeconds,
                        fixedScale: nil,
                        showsHeader: false,
                        colorBarPlacement: .trailing,
                        minimumMapHeight: 150
                    )
                    .frame(width: 200, height: 190)
                    Slider(
                        value: Binding(
                            get: { Double(relativeSample) },
                            set: { view.epoching.differenceRelativeSample = Int($0.rounded()) }
                        ),
                        in: 0...Double(max(epochLength - 1, 1))
                    )
                    .frame(width: 190)
                }
                .contextMenu {
                    view.figureSaveMenu(
                        title: "Difference Topomap (\(categoryA) − \(categoryB))",
                        legend: [(categoryA, diffColor)],
                        size: CGSize(width: 260, height: 260)
                    ) {
                        VStack(spacing: 6) {
                            Text(String(format: "%.3f s", latencySeconds))
                                .font(.caption.monospacedDigit())
                            TopomapView(
                                layout: layout,
                                values: view.topomapValues(at: result.segment.startSample + relativeSample, in: result.signal),
                                timeSeconds: latencySeconds,
                                fixedScale: nil,
                                showsHeader: false,
                                colorBarPlacement: .trailing,
                                minimumMapHeight: 200
                            )
                            .frame(width: 240, height: 220)
                        }
                    }
                }
            }
        }
    }
}
