//
//  TimeFrequencyExport.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Export for the time-frequency view (PART TF-3):
//   • Full maps `channel × freq × time` per condition as dependency-free NPY
//     (numpy v1.0 header + little-endian float32), for a clean round-trip into
//     MNE / Python / R, with a JSON sidecar carrying the axes and parameters.
//   • Tidy scalar CSV — mean ERSP / ITPC per condition × channel × band × window
//     — in the long "summary + rows" convention `EEGAnalysisEngine.csvRows`
//     uses, so it drops straight into a mixed model / JASP.
//

import Foundation

nonisolated enum TimeFrequencyExport {

    /// An a-priori band × window region of interest for the scalar reduction.
    struct Window: Sendable, Equatable {
        var label: String
        var startMs: Double
        var endMs: Double
    }

    /// Everything needed to compute and label an export, captured from the view.
    struct Context: Sendable {
        var plan: TFFrequencyPlan
        var method: TFMethod
        var timeBandwidth: Double
        var baselineMethod: TFBaselineMethod
        var bands: [EEGFrequencyBand]
        var windows: [Window]
    }

    /// Per-channel maps for one condition, plus the shared axes.
    struct ConditionMaps: Sendable {
        var condition: String
        var channelNames: [String]
        /// `ersp[channel][freq][time]` — baseline-normalized power.
        var ersp: [[[Double]]]
        /// `itpc[channel][freq][time]`.
        var itpc: [[[Double]]]
        var frequenciesHz: [Double]
        var timesMs: [Double]
    }

    // MARK: Per-channel computation

    /// Computes ERSP + ITPC for every channel of one condition. Heavy (loops the
    /// engine over channels) — intended for an explicit export action.
    static func conditionMaps(
        signal: MFFSignalData,
        segments: [EpochSegment],
        condition: String,
        channelIndices: [Int],
        channelNames: [String],
        context: Context
    ) -> ConditionMaps? {
        var ersp: [[[Double]]] = []
        var itpc: [[[Double]]] = []
        var frequenciesHz = context.plan.frequenciesHz
        var timesMs: [Double] = []
        var names: [String] = []

        for channel in channelIndices {
            let stack = TimeFrequencyTrials.stack(signal: signal, segments: segments, category: condition, channelIndices: [channel])
            guard !stack.isEmpty else { continue }
            let baseline = baselineSpec(for: stack, method: context.baselineMethod)
            guard let result = TimeFrequencyEngine.ersp(
                trials: stack.trials, samplingRate: stack.samplingRate, plan: context.plan,
                baseline: baseline, method: context.method, timeBandwidth: context.timeBandwidth
            ) else { continue }

            ersp.append(result.ersp)
            itpc.append(result.itpc)
            frequenciesHz = result.frequenciesHz
            if timesMs.isEmpty {
                timesMs = (0..<stack.timeCount).map { Double($0 - stack.stimulusOffsetSamples) / stack.samplingRate * 1000.0 }
            }
            names.append(channelNames.indices.contains(channel) ? channelNames[channel] : "Ch \(channel + 1)")
        }
        guard !ersp.isEmpty else { return nil }
        return ConditionMaps(condition: condition, channelNames: names, ersp: ersp, itpc: itpc, frequenciesHz: frequenciesHz, timesMs: timesMs)
    }

    private static func baselineSpec(for stack: TimeFrequencyTrials.Stack, method: TFBaselineMethod) -> TFBaselineSpec {
        let n = stack.timeCount
        let end = stack.stimulusOffsetSamples > 1 ? stack.stimulusOffsetSamples - 1 : max(1, n / 10)
        return TFBaselineSpec(startSample: 0, endSample: min(end, n - 1), method: method)
    }

    // MARK: NPY writer

    /// Serializes a `channel × freq × time` map as a numpy `.npy` (v1.0,
    /// little-endian float32, C order). Dependency-free: header dict + raw buffer.
    static func npy(_ map: [[[Double]]]) -> Data {
        let c = map.count
        let f = map.first?.count ?? 0
        let t = map.first?.first?.count ?? 0
        var values = [Float](repeating: 0, count: c * f * t)
        var i = 0
        for ch in map {
            for row in ch {
                for v in row { values[i] = Float(v); i += 1 }
            }
        }
        return npyFloat32(shape: [c, f, t], cOrderValues: values)
    }

    /// numpy `.npy` v1.0 for a float32 array in C order.
    static func npyFloat32(shape: [Int], cOrderValues: [Float]) -> Data {
        let shapeText: String
        if shape.count == 1 {
            shapeText = "(\(shape[0]),)"
        } else {
            shapeText = "(" + shape.map(String.init).joined(separator: ", ") + ")"
        }
        let dict = "{'descr': '<f4', 'fortran_order': False, 'shape': \(shapeText), }"

        // The total of magic(6) + version(2) + headerLen(2) + header must be a
        // multiple of 64; the header ends with '\n'.
        let prefix = 10
        let raw = prefix + dict.count + 1
        let pad = (64 - (raw % 64)) % 64
        let header = dict + String(repeating: " ", count: pad) + "\n"
        let headerLen = header.count

        var data = Data()
        data.append(contentsOf: [0x93])
        data.append(contentsOf: Array("NUMPY".utf8))
        data.append(contentsOf: [0x01, 0x00])                       // version 1.0
        data.append(UInt8(headerLen & 0xFF))
        data.append(UInt8((headerLen >> 8) & 0xFF))
        data.append(contentsOf: Array(header.utf8))
        cOrderValues.withUnsafeBytes { data.append(contentsOf: $0) } // LE on Apple platforms
        return data
    }

    /// JSON sidecar with axes and parameters (NPY carries no metadata).
    static func sidecarJSON(_ maps: ConditionMaps, measure: EpochingViewModel.TFMeasure, context: Context) -> Data {
        let object: [String: Any] = [
            "measure": measure == .power ? "ersp" : "itpc",
            "unit": measure == .power ? context.baselineMethod.rawValue : "itpc",
            "condition": maps.condition,
            "method": context.method.rawValue,
            "timeBandwidth": context.timeBandwidth,
            "baselineMethod": context.baselineMethod.rawValue,
            "cyclesLow": context.plan.nCycles.first ?? 0,
            "cyclesHigh": context.plan.nCycles.last ?? 0,
            "shape": ["channel": maps.channelNames.count, "freq": maps.frequenciesHz.count, "time": maps.timesMs.count],
            "channelNames": maps.channelNames,
            "frequenciesHz": maps.frequenciesHz,
            "timesMs": maps.timesMs,
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    // MARK: Scalar CSV

    /// Rows for the tidy scalar CSV: `summary` parameter rows followed by
    /// `tf_scalar` rows (one per condition × channel × band × window × measure).
    static func scalarCSVRows(_ conditions: [ConditionMaps], context: Context) -> [[String]] {
        var rows: [[String]] = [[
            "row_type", "scope", "condition", "channel_index", "channel_name",
            "band", "window", "measure", "value",
        ]]

        func summary(_ metric: String, _ value: CustomStringConvertible) {
            rows.append(["summary", "recording", "", "", "", "", "", metric, "\(value)"])
        }
        summary("method", context.method.rawValue)
        summary("baseline_method", context.baselineMethod.rawValue)
        summary("cycles_low", clean(context.plan.nCycles.first ?? 0))
        summary("cycles_high", clean(context.plan.nCycles.last ?? 0))
        if context.method == .multitaper { summary("time_bandwidth", clean(context.timeBandwidth)) }
        summary("freq_min_hz", clean(context.plan.frequenciesHz.first ?? 0))
        summary("freq_max_hz", clean(context.plan.frequenciesHz.last ?? 0))
        summary("freq_bins", context.plan.frequenciesHz.count)

        for maps in conditions {
            for band in context.bands {
                let freqIdx = maps.frequenciesHz.indices.filter { maps.frequenciesHz[$0] >= band.lowHz && maps.frequenciesHz[$0] <= band.highHz }
                guard !freqIdx.isEmpty else { continue }
                for window in context.windows {
                    let timeIdx = maps.timesMs.indices.filter { maps.timesMs[$0] >= window.startMs && maps.timesMs[$0] <= window.endMs }
                    guard !timeIdx.isEmpty else { continue }
                    for ch in maps.channelNames.indices {
                        let erspMean = meanOver(maps.ersp[ch], freqIdx: freqIdx, timeIdx: timeIdx)
                        let itpcMean = meanOver(maps.itpc[ch], freqIdx: freqIdx, timeIdx: timeIdx)
                        for (measure, value) in [("ersp", erspMean), ("itpc", itpcMean)] {
                            rows.append([
                                "tf_scalar", "channel", maps.condition,
                                "\(ch + 1)", maps.channelNames[ch],
                                band.name, window.label, measure, clean(value),
                            ])
                        }
                    }
                }
            }
        }
        return rows
    }

    static func csvData(_ rows: [[String]]) -> Data {
        let text = rows.map { $0.map(escapeCSV).joined(separator: ",") }.joined(separator: "\n") + "\n"
        return Data(text.utf8)
    }

    // MARK: Helpers

    private static func meanOver(_ grid: [[Double]], freqIdx: [Int], timeIdx: [Int]) -> Double {
        var sum = 0.0, count = 0
        for fi in freqIdx where grid.indices.contains(fi) {
            let row = grid[fi]
            for ti in timeIdx where row.indices.contains(ti) { sum += row[ti]; count += 1 }
        }
        return count > 0 ? sum / Double(count) : .nan
    }

    private static func clean(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value == value.rounded() && abs(value) < 1e15 { return String(format: "%.0f", value) }
        return String(format: "%.6g", value)
    }

    private static func escapeCSV(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// Default ROI windows for the scalar CSV, clipped to the available range.
    static func defaultWindows(maxTimeMs: Double) -> [Window] {
        let candidates = [
            Window(label: "0-200ms", startMs: 0, endMs: 200),
            Window(label: "200-500ms", startMs: 200, endMs: 500),
            Window(label: "500-800ms", startMs: 500, endMs: 800),
        ]
        var windows = candidates.filter { $0.startMs < maxTimeMs }
        windows.append(Window(label: "0-\(Int(maxTimeMs))ms", startMs: 0, endMs: maxTimeMs))
        return windows
    }
}
