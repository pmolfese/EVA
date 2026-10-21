//
//  BDFSignalReader.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
// App policy on top of the byte-level BDF reader: units, channel roles, and
// mixed sampling rates. EXG channels stay in EEG because their role is unknown;
// the existing channel-role UI can move them once the user knows their wiring.

import Foundation

nonisolated enum BDFSignalReader {
    static func load(
        from url: URL,
        progress: (@Sendable (SignalImportProgress) -> Void)? = nil
    ) throws -> ImportedRecording {
        let recording: BDFRecording
        do {
            recording = try BDFRecording.read(from: url) { fraction in
                progress?(SignalImportProgress(fraction: 0.03 + fraction * 0.74,
                                               message: "Reading BDF channels and events", detail: nil))
            }
        } catch BDFReadError.unsupported(let detail) {
            throw SignalImportError.unsupportedVariant(url, detail)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SignalImportError.malformedFile(url, error.localizedDescription)
        }
        let eeg = recording.channels.indices.filter { !isPeripheral(recording.channels[$0]) }
        let peripheral = recording.channels.indices.filter { isPeripheral(recording.channels[$0]) }
        guard !eeg.isEmpty else {
            throw SignalImportError.unsupportedVariant(url, "the BDF contains no EEG channels")
        }
        let kind = recording.isPlus ? "BDF+" : "BDF"
        var preparedChannels = 0
        func signal(_ indices: [Int], pns: Bool) throws -> MFFSignalData {
            let targetRate = indices.map { recording.channels[$0].samplingRate }.max() ?? 0
            let targetCount = indices.map { recording.channels[$0].samples.count }.max() ?? 0
            var data = [[Float]]()
            for index in indices {
                try Task.checkCancellation()
                let channel = recording.channels[index]
                var samples = try BDFImportResampling.upsample(
                    channel.samples, toCount: targetCount, discrete: channel.isStatus
                )
                // Voltage channels enter EVA in microvolts. Other physiological
                // units (e.g. temperature) and raw Status words remain native.
                if !channel.isStatus, let scale = microvoltsPerUnit(channel.unit), scale != 1 {
                    for sample in samples.indices {
                        samples[sample] *= scale
                        guard samples[sample].isFinite else {
                            throw SignalImportError.malformedFile(url, "BDF unit conversion overflows sample values")
                        }
                    }
                }
                data.append(samples)
                preparedChannels += 1
                progress?(SignalImportProgress(fraction: 0.78 + 0.18 * Double(preparedChannels) / Double(recording.channels.count),
                                               message: "Preparing BDF \(pns ? "physiological" : "EEG") channels", detail: nil))
            }
            return MFFSignalData(
                signalURL: url, signalType: pns ? "\(kind) PNS" : kind,
                numberOfChannels: indices.count, samplingRate: targetRate,
                duration: recording.duration, recordingStartTime: recording.startTime,
                events: recording.events, data: data,
                channelNames: indices.map { recording.channels[$0].label }
            )
        }
        return ImportedRecording(signal: try signal(eeg, pns: false), layout: nil, geometry: nil,
                                 pnsSignal: peripheral.isEmpty ? nil : try signal(peripheral, pns: true))
    }

    static func microvoltsPerUnit(_ unit: String) -> Float? {
        switch unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "v": return 1_000_000
        case "mv": return 1_000
        case "uv", "µv", "μv": return 1
        case "nv": return 0.001
        default: return nil
        }
    }

    private static func isPeripheral(_ channel: BDFRecording.Channel) -> Bool {
        if channel.isStatus { return true }
        let label = channel.label.uppercased().trimmingCharacters(in: .whitespaces)
        if ["ECG", "EKG", "EOG", "HEOG", "VEOG", "EMG", "GSR", "RESP", "PULSE",
            "ERG", "AUX", "TEMP", "BIP", "CMS", "DRL"].contains(where: { label.hasPrefix($0) }) {
            return true
        }
        // BDF permits arbitrary sensor units. Do not feed degrees/ohms/etc into
        // scalp EEG processing; blank units are tolerated for legacy electrodes.
        return !channel.unit.isEmpty && microvoltsPerUnit(channel.unit) == nil
    }
}

/// BDF allows each channel its own sample rate. Each EVA signal group has a
/// common rate, so upsample lower-rate analog channels to its highest native
/// rate using a normalized Lanczos-windowed sinc. Never downsample or alter
/// native-rate samples. Status uses sample-and-hold, preserving bit patterns.
/// Work across the whole channel, not per record, to avoid record-edge seams.
nonisolated enum BDFImportResampling {
    static func upsample(_ source: [Float], toCount count: Int, discrete: Bool) throws -> [Float] {
        guard source.count != count else { return source }
        guard !source.isEmpty, count >= source.count else {
            throw BDFReadError.malformed("Invalid BDF resampling dimensions.")
        }
        var output = [Float](repeating: 0, count: count)
        let ratio = Double(source.count) / Double(count)
        let radius = 16
        func sinc(_ x: Double) -> Double {
            abs(x) < 1e-12 ? 1 : sin(.pi * x) / (.pi * x)
        }
        for index in output.indices {
            if index & 0x3fff == 0 { try Task.checkCancellation() }
            let position = Double(index) * ratio
            if discrete {
                // Integer arithmetic avoids holding a sample late at an exact
                // boundary because of floating-point division rounding.
                let sourceIndex = count.dividingFullWidth(index.multipliedFullWidth(by: source.count)).quotient
                output[index] = source[sourceIndex]
                continue
            }
            let nearest = position.rounded()
            if abs(position - nearest) < 1e-10 {
                output[index] = source[min(source.count - 1, Int(nearest))]
                continue
            }
            let center = Int(position.rounded(.down))
            var sum = 0.0, weight = 0.0
            for tap in (center - radius + 1)...(center + radius) {
                let distance = position - Double(tap)
                let coefficient = sinc(distance) * sinc(distance / Double(radius))
                // Constant extension avoids zero-padding a DC electrode offset.
                sum += Double(source[min(source.count - 1, max(0, tap))]) * coefficient
                weight += coefficient
            }
            output[index] = Float(sum / weight)
            guard output[index].isFinite else {
                throw BDFReadError.malformed("BDF resampling overflows sample values.")
            }
        }
        return output
    }
}
