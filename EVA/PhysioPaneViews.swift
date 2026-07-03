//
//  PhysioPaneViews.swift
//  EVA
//
//  Physio (PNS) pane: pinned time-synced physio channel display, renaming, and ICA-component synthesis wiring,
//  This is an extension of WaveformView (not a standalone type), following the
//  same pattern as the other L5 slices -- a file split, not a state extraction.
//

import SwiftUI

extension WaveformView {
    // MARK: - Physio (PNS) pane

    func pnsFilterBaseSignal() -> MFFSignalData? {
        guard let raw = recording.pnsSignal else { return nil }
        if gradient.appliesToPNS, let correctedPNS = gradient.correctedPNSSignal {
            return correctedPNS
        }
        return raw
    }

    func displayedPhysioSignal() -> MFFSignalData? {
        let base: MFFSignalData?
        if let pnsBase = pnsFilterBaseSignal() {
            if filter.filterPNS,
                      let filteredPNS = filter.pnsOutput,
                      filter.pnsInputSignalType == pnsBase.signalType {
                base = filteredPNS
            } else {
                base = pnsBase
            }
        } else {
            base = nil
        }
        guard !syntheticPNSChannels.isEmpty || base != nil else { return nil }
        return mergingWithSynthetic(base: base)
    }

    /// Builds a single `MFFSignalData` that contains the real PNS channels (if any)
    /// followed by any synthesized ICA channels. All synthetic samples are stored at
    /// EEG sampling rate (linearly upsampled from the ICA analysis rate).
    func mergingWithSynthetic(base: MFFSignalData?) -> MFFSignalData? {
        guard let signal = recording.signal else { return base }
        guard !syntheticPNSChannels.isEmpty else { return base }

        let targetRate = base?.samplingRate ?? signal.samplingRate
        let realData   = base?.data ?? []
        let realNames  = base?.channelNames ?? []

        // Pin synthetic channels to exactly this many samples so all channels in
        // the merged signal have identical length (required by ecgDetectionSources
        // and other per-channel length checks). Use the real PNS length when
        // available; otherwise derive from EEG duration at the target rate.
        let targetSampleCount: Int? = realData.first?.count
            ?? { Int((signal.duration * targetRate).rounded()) }()

        var mergedData  = realData
        var mergedNames = realNames

        for synth in syntheticPNSChannels {
            var upsampled = upsampleLinear(synth.samples,
                                           from: synth.samplingRate,
                                           to: targetRate)
            if let target = targetSampleCount {
                if upsampled.count > target {
                    upsampled.removeLast(upsampled.count - target)
                } else if upsampled.count < target {
                    let pad = upsampled.last ?? 0
                    upsampled.append(contentsOf: repeatElement(pad, count: target - upsampled.count))
                }
            }
            mergedData.append(upsampled)
            mergedNames.append(synth.name)
        }

        let anchor = base ?? MFFSignalData(
            signalURL: recording.packageURL,
            signalType: "SyntheticPNS",
            numberOfChannels: 0,
            samplingRate: targetRate,
            duration: signal.duration,
            recordingStartTime: signal.recordingStartTime,
            events: [],
            data: [],
            channelNames: []
        )

        return MFFSignalData(
            signalURL: anchor.signalURL,
            signalType: anchor.signalType,
            numberOfChannels: mergedData.count,
            samplingRate: targetRate,
            duration: anchor.duration,
            recordingStartTime: anchor.recordingStartTime,
            events: anchor.events,
            data: mergedData,
            channelNames: mergedNames.isEmpty ? nil : mergedNames
        )
    }

    func upsampleLinear(_ samples: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        guard srcRate > 0, dstRate > 0, !samples.isEmpty else { return samples }
        let ratio = dstRate / srcRate
        guard abs(ratio - 1) > 1e-6 else { return samples }
        let outCount = Int((Double(samples.count) * ratio).rounded())
        var out = [Float]()
        out.reserveCapacity(outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) / ratio
            let lo = Int(srcPos)
            let hi = min(lo + 1, samples.count - 1)
            let frac = Float(srcPos - Double(lo))
            out.append(samples[lo] * (1 - frac) + samples[hi] * frac)
        }
        return out
    }

    /// Per-channel display range (min...max over a strided scan) for the physio
    /// channels, so each trace (ECG, EMG, …) is auto-scaled to its own amplitude.
    nonisolated static func computePhysioRanges(_ signal: MFFSignalData?) -> [ClosedRange<Float>] {
        guard let signal else { return [] }
        return signal.data.map { channel in
            guard !channel.isEmpty else { return Float(-1)...Float(1) }
            let stride = max(1, channel.count / 4000)
            var lo = Float.greatestFiniteMagnitude
            var hi = -Float.greatestFiniteMagnitude
            var i = 0
            while i < channel.count {
                let v = channel[i]
                if v.isFinite { lo = min(lo, v); hi = max(hi, v) }
                i += stride
            }
            if !(lo < hi) { return (hi - 1)...(hi + 1) }   // flat channel
            return lo...hi
        }
    }

    @ViewBuilder
    func physioPane(_ pns: MFFSignalData, eegSamplingRate: Double) -> some View {
        let rowHeight: CGFloat = 36
        let names = pns.channelNames
            ?? (0..<pns.numberOfChannels).map { "PNS \($0 + 1)" }

        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .top, spacing: 12) {
                // Channel labels, aligned to the trace rows.
                VStack(alignment: .leading, spacing: 0) {
                    Text("Physio")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(height: 16, alignment: .leading)
                    ForEach(0..<pns.numberOfChannels, id: \.self) { i in
                        let name = physioChannelName(index: i, names: names)
                        HStack(spacing: 5) {
                            Text(name)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.tail)

                            if let scaleBadge = physioScaleBadge(for: i) {
                                Text(scaleBadge)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            if physioFlippedPolarity.contains(i) {
                                Text("flip")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(height: rowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                        .help("Right-click to adjust physio scaling and polarity.")
                        .contextMenu {
                            physioChannelContextMenu(index: i, name: name)
                        }
                    }
                }
                .frame(width: labelColumnWidth, alignment: .topLeading)

                ZStack(alignment: .topLeading) {
                    PhysioTrackView(
                        signal: pns,
                        ranges: physioRanges,
                        scaleFactors: physioScaleFactors,
                        maxScaledChannels: physioMaxScaledChannels,
                        flippedPolarity: physioFlippedPolarity,
                        rowHeight: rowHeight,
                        eegSamplingRate: eegSamplingRate,
                        sampleStride: displaySampleStride(for: eegSamplingRate),
                        timeScale: timeScale,
                        contentOffset: horizontalOffset,
                        viewportWidth: horizontalViewportWidth
                    )
                    .padding(.top, 16)   // align below the "Physio" header

                    physioContextMenuOverlay(
                        channelCount: pns.numberOfChannels,
                        names: names,
                        rowHeight: rowHeight
                    )
                    .padding(.top, 16)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: physioRangeTaskID(for: pns)) {
            physioRanges = Self.computePhysioRanges(pns)
            physioScaleFactors = physioScaleFactors.filter { $0.key < pns.numberOfChannels }
            physioMaxScaledChannels = physioMaxScaledChannels.filter { $0 < pns.numberOfChannels }
            physioFlippedPolarity = physioFlippedPolarity.filter { $0 < pns.numberOfChannels }
        }
        .alert("Rename Channel", isPresented: Binding(
            get: { physioRenameTarget != nil },
            set: { if !$0 { physioRenameTarget = nil } }
        )) {
            TextField("Channel name", text: $physioRenameText)
            Button("Rename") {
                if let idx = physioRenameTarget, !physioRenameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    applyPhysioRename(index: idx, name: physioRenameText.trimmingCharacters(in: .whitespaces))
                }
                physioRenameTarget = nil
            }
            Button("Cancel", role: .cancel) { physioRenameTarget = nil }
        } message: {
            Text("Enter a new name for this physio channel.")
        }
    }

    func applyPhysioRename(index: Int, name: String) {
        let realCount = recording.pnsSignal?.numberOfChannels ?? 0
        if index < realCount {
            physioChannelRenames[index] = name
        } else {
            let synthIdx = index - realCount
            if synthIdx < syntheticPNSChannels.count {
                syntheticPNSChannels[synthIdx].name = name
            }
        }
    }

    func physioRangeTaskID(for signal: MFFSignalData) -> String {
        [
            signal.signalURL.path,
            signal.signalType,
            "\(signal.numberOfChannels)",
            "\(signal.data.first?.count ?? 0)",
            filter.filterPNS ? "filterPNS" : "rawPNS",
            gradient.appliesToPNS ? "mriPNS" : "rawMRI"
        ].joined(separator: "|")
    }

    func physioChannelName(index: Int, names: [String]) -> String {
        if let renamed = physioChannelRenames[index] { return renamed }
        return index < names.count ? names[index] : "PNS \(index + 1)"
    }

    func physioScaleFactor(for index: Int) -> Double {
        physioScaleFactors[index] ?? 1
    }

    func physioScaleBadge(for index: Int) -> String? {
        if physioMaxScaledChannels.contains(index) {
            return "Max"
        }
        let scale = physioScaleFactor(for: index)
        return scale == 1 ? nil : physioScaleLabel(scale)
    }

    func physioScaleBinding(for index: Int) -> Binding<Double> {
        Binding(
            get: { physioScaleFactor(for: index) },
            set: { setPhysioScale($0, for: index) }
        )
    }

    func setPhysioScale(_ scale: Double, for index: Int) {
        physioMaxScaledChannels.remove(index)
        let clamped = min(max(scale, physioScaleBounds.lowerBound), physioScaleBounds.upperBound)
        if abs(clamped - 1) < 0.0001 {
            physioScaleFactors[index] = nil
        } else {
            physioScaleFactors[index] = clamped
        }
    }

    func setPhysioScaleToMax(for index: Int) {
        physioScaleFactors[index] = nil
        physioMaxScaledChannels.insert(index)
    }

    func togglePhysioPolarity(for index: Int) {
        if physioFlippedPolarity.contains(index) {
            physioFlippedPolarity.remove(index)
        } else {
            physioFlippedPolarity.insert(index)
        }
    }

    func physioScaleLabel(_ scale: Double) -> String {
        let rounded = (scale * 100).rounded() / 100
        if abs(rounded - rounded.rounded()) < 0.0001 {
            return "\(Int(rounded.rounded()))x"
        }
        if abs(rounded * 10 - (rounded * 10).rounded()) < 0.0001 {
            return String(format: "%.1fx", rounded)
        }
        return String(format: "%.2fx", rounded)
    }

    @ViewBuilder
    func physioChannelContextMenu(index: Int, name: String) -> some View {
        let realPhysioCount = recording.pnsSignal?.numberOfChannels ?? 0
        let currentScale = physioScaleFactor(for: index)
        let isMaxScaled = physioMaxScaledChannels.contains(index)
        let isFlipped = physioFlippedPolarity.contains(index)
        Text("\(name): \(isMaxScaled ? "Max" : physioScaleLabel(currentScale))\(isFlipped ? ", flipped" : "")")

        Button("Rename…") {
            physioRenameText = name
            physioRenameTarget = index
        }

        Divider()

        if index < realPhysioCount {
            Button("Move to EEG") {
                movePhysioChannelToEEG(index: index, name: name)
            }

            Divider()
        }

        if !isMaxScaled {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scale \(physioScaleLabel(currentScale))")
                    .font(.caption)
                Slider(value: physioScaleBinding(for: index), in: physioScaleBounds, step: 1)
                    .frame(width: 180)
            }
            .padding(.vertical, 2)

            Divider()
        }

        Button(isFlipped ? "Restore Polarity" : "Flip Polarity") {
            togglePhysioPolarity(for: index)
        }

        Divider()

        Button("Auto") {
            setPhysioScale(1, for: index)
        }
        .disabled(!isMaxScaled && currentScale == 1)

        ForEach(physioScaleOptions, id: \.self) { scale in
            Button(physioScaleLabel(scale)) {
                setPhysioScale(scale, for: index)
            }
        }

        Button("Max") {
            setPhysioScaleToMax(for: index)
        }
        .disabled(isMaxScaled)
    }

    func physioContextMenuOverlay(channelCount: Int, names: [String], rowHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<channelCount, id: \.self) { index in
                let name = physioChannelName(index: index, names: names)
                Color.clear
                    .frame(height: rowHeight)
                    .contentShape(Rectangle())
                    .contextMenu {
                        physioChannelContextMenu(index: index, name: name)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

}
