//
//  ChannelGoodnessSettings.swift
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
//  Sticky, app-wide configuration for the channel-goodness fit metrics. The
//  spectral and neighbor-prediction detectors run as part of the default health
//  pass; the wavelet burden detector is run on demand. All knobs are grouped in
//  Channels -> "Channel Goodness Settings..." and persisted to user defaults.
//

import SwiftUI

/// Configuration for the on-demand wavelet channel-burden detector.
struct ChannelWaveletGoodnessSettings: Codable, Sendable {
    var family: WaveletCleaningFamily = .bior44
    var levelCount: Int = 8
    var thresholdModel: WaveletCleaningThresholdModel = .bayesShrink
    var thresholdRule: WaveletCleaningThresholdRule = .hard
    var downsampleRate: Double = 250
    var cleaningMode: WaveletCleaningMode = .conservativeLocal
    var intensity: Double = WaveletCleaningMode.conservativeLocal.defaultIntensity

    static let defaults = ChannelWaveletGoodnessSettings()
}

@MainActor
@Observable
final class ChannelGoodnessSettings {
    var base: ChannelBaseMetricSettings { didSet { save() } }
    var spectral: ChannelSpectralConfiguration { didSet { save() } }
    var ransac: ChannelRansacConfiguration { didSet { save() } }
    var wavelet: ChannelWaveletGoodnessSettings { didSet { save() } }

    private static let storageKey = "ChannelGoodnessSettings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            base = stored.base
            spectral = stored.spectral
            ransac = stored.ransac
            wavelet = stored.wavelet
        } else {
            base = .defaults
            spectral = .happeStandard
            ransac = .happeStandard
            wavelet = .defaults
        }
    }

    func restoreDefaults() {
        base = .defaults
        spectral = .happeStandard
        ransac = .happeStandard
        wavelet = .defaults
    }

    /// Forward/backward-compatible: any field missing from stored JSON falls
    /// back to its default rather than failing the whole decode.
    private struct Stored: Codable {
        var base: ChannelBaseMetricSettings
        var spectral: ChannelSpectralConfiguration
        var ransac: ChannelRansacConfiguration
        var wavelet: ChannelWaveletGoodnessSettings

        init(
            base: ChannelBaseMetricSettings,
            spectral: ChannelSpectralConfiguration,
            ransac: ChannelRansacConfiguration,
            wavelet: ChannelWaveletGoodnessSettings
        ) {
            self.base = base
            self.spectral = spectral
            self.ransac = ransac
            self.wavelet = wavelet
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            base = try container.decodeIfPresent(ChannelBaseMetricSettings.self, forKey: .base) ?? .defaults
            spectral = try container.decodeIfPresent(ChannelSpectralConfiguration.self, forKey: .spectral) ?? .happeStandard
            ransac = try container.decodeIfPresent(ChannelRansacConfiguration.self, forKey: .ransac) ?? .happeStandard
            wavelet = try container.decodeIfPresent(ChannelWaveletGoodnessSettings.self, forKey: .wavelet) ?? .defaults
        }
    }

    private func save() {
        let stored = Stored(base: base, spectral: spectral, ransac: ransac, wavelet: wavelet)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

private enum GoodnessSettingsTool: String, CaseIterable, Identifiable {
    case base = "Core"
    case spectral = "Spectral"
    case ransac = "Neighbor"
    case wavelet = "Wavelet"

    var id: String { rawValue }

    var caption: String {
        switch self {
        case .base:
            return "Green/red thresholds for the always-on core health metrics. \u{201C}Green\u{201D} scores fully good (1.0); \u{201C}Red\u{201D} scores fully poor (0.0); values between interpolate."
        case .spectral:
            return "Standardizes each channel's mean log power over the band and flags channels outside the z-score range. Runs by default. Mirrors EEGLAB pop_rejchan ('spec')."
        case .ransac:
            return "Reconstructs each channel from its nearest neighbors and flags channels whose median windowed correlation falls below the minimum. Runs by default. Spirit of clean_rawdata's ChannelCriterion."
        case .wavelet:
            return "Scores each channel by its multiscale transient (artifact) burden. Runs on demand from the \u{201C}Wavelet...\u{201D} button in Channel Goodness Details."
        }
    }
}

struct ChannelGoodnessSettingsView: View {
    @Environment(ChannelGoodnessSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var tool = GoodnessSettingsTool.base

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 14) {
            Text("Channel Goodness Settings")
                .font(.title3.weight(.semibold))

            Picker("Tool", selection: $tool) {
                ForEach(GoodnessSettingsTool.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(tool.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 56, alignment: .top)

            Divider()

            Group {
                switch tool {
                case .base: baseSection(settings: settings)
                case .spectral: spectralSection(settings: settings)
                case .ransac: ransacSection(settings: settings)
                case .wavelet: waveletSection(settings: settings)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)

            Spacer(minLength: 0)

            HStack {
                Button("Restore Defaults") { restoreCurrentTool() }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 430, height: 470)
    }

    private func restoreCurrentTool() {
        switch tool {
        case .base: settings.base = .defaults
        case .spectral: settings.spectral = .happeStandard
        case .ransac: settings.ransac = .happeStandard
        case .wavelet: settings.wavelet = .defaults
        }
    }

    @ViewBuilder
    private func baseSection(settings: ChannelGoodnessSettings) -> some View {
        @Bindable var settings = settings
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Metric").gridColumnAlignment(.leading)
                    Text("Good").frame(width: 74)
                    Text("Poor").frame(width: 74)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                baseRow("Finite Samples", help: MetricHelp.finite, green: $settings.base.finiteGreen, red: $settings.base.finiteRed, fraction: 3)
                baseRow("Signal Amplitude", help: MetricHelp.amplitude, green: $settings.base.amplitudeGreen, red: $settings.base.amplitudeRed, fraction: 1)
                baseRow("Burst Peaks", help: MetricHelp.burst, green: $settings.base.burstGreen, red: $settings.base.burstRed, fraction: 1)
                baseRow("Flatline", help: MetricHelp.flatline, green: $settings.base.flatlineGreen, red: $settings.base.flatlineRed, fraction: 3)
                baseRow("Clipping", help: MetricHelp.clipping, green: $settings.base.clippingGreen, red: $settings.base.clippingRed, fraction: 3)
                baseRow("Fast Noise", help: MetricHelp.fastNoise, green: $settings.base.fastNoiseGreen, red: $settings.base.fastNoiseRed, fraction: 1)
                baseRow("Slow Drift", help: MetricHelp.slowDrift, green: $settings.base.slowDriftGreen, red: $settings.base.slowDriftRed, fraction: 1)
            }
        }
    }

    private func baseRow(
        _ name: String,
        help: String,
        green: Binding<Double>,
        red: Binding<Double>,
        fraction: Int
    ) -> some View {
        GridRow {
            MetricHelpLabel(name: name, help: help)
            TextField("", value: green, format: .number.precision(.fractionLength(fraction)))
                .frame(width: 74)
            TextField("", value: red, format: .number.precision(.fractionLength(fraction)))
                .frame(width: 74)
        }
    }

    @ViewBuilder
    private func spectralSection(settings: ChannelGoodnessSettings) -> some View {
        @Bindable var settings = settings
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Low freq (Hz)")
                TextField("Hz", value: $settings.spectral.lowFrequencyHz, format: .number.precision(.fractionLength(1)))
                    .frame(width: 90)
            }
            GridRow {
                Text("High freq (Hz)")
                TextField("Hz", value: $settings.spectral.highFrequencyHz, format: .number.precision(.fractionLength(1)))
                    .frame(width: 90)
            }
            GridRow {
                Text("Upper z")
                TextField("z", value: $settings.spectral.upperZThreshold, format: .number.precision(.fractionLength(2)))
                    .frame(width: 90)
            }
            GridRow {
                Text("Lower z")
                TextField("z", value: $settings.spectral.lowerZThreshold, format: .number.precision(.fractionLength(2)))
                    .frame(width: 90)
            }
        }
    }

    @ViewBuilder
    private func ransacSection(settings: ChannelGoodnessSettings) -> some View {
        @Bindable var settings = settings
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Min correlation")
                TextField("r", value: $settings.ransac.minimumCorrelation, format: .number.precision(.fractionLength(3)))
                    .frame(width: 90)
            }
            GridRow {
                Text("Neighbors")
                Stepper("\(settings.ransac.neighborCount)", value: $settings.ransac.neighborCount, in: 2...12)
                    .frame(width: 120)
            }
            GridRow {
                Text("Window (s)")
                TextField("s", value: $settings.ransac.windowSeconds, format: .number.precision(.fractionLength(1)))
                    .frame(width: 90)
            }
        }
    }

    @ViewBuilder
    private func waveletSection(settings: ChannelGoodnessSettings) -> some View {
        @Bindable var settings = settings
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Wavelet")
                Picker("", selection: $settings.wavelet.family) {
                    ForEach(WaveletCleaningFamily.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            GridRow {
                Text("Cleaning mode")
                Picker("", selection: $settings.wavelet.cleaningMode) {
                    ForEach(WaveletCleaningMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            GridRow {
                Text("Threshold model")
                Picker("", selection: $settings.wavelet.thresholdModel) {
                    ForEach(WaveletCleaningThresholdModel.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            GridRow {
                Text("Threshold rule")
                Picker("", selection: $settings.wavelet.thresholdRule) {
                    ForEach(WaveletCleaningThresholdRule.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            GridRow {
                Text("Levels")
                Stepper("\(settings.wavelet.levelCount)", value: $settings.wavelet.levelCount, in: 1...WaveletArtifactAnalyzer.maximumLevelCount)
                    .frame(width: 120)
            }
            GridRow {
                Text("Intensity")
                TextField("x", value: $settings.wavelet.intensity, format: .number.precision(.fractionLength(2)))
                    .frame(width: 90)
            }
            GridRow {
                Text("Downsample (Hz)")
                TextField("Hz", value: $settings.wavelet.downsampleRate, format: .number.precision(.fractionLength(0)))
                    .frame(width: 90)
            }
        }
    }
}

/// A metric name followed by a "?" button that explains what the metric measures
/// and why it matters for channel goodness.
private struct MetricHelpLabel: View {
    let name: String
    let help: String
    @State private var shows = false

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
            Button {
                shows = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("What is \(name)?")
            .popover(isPresented: $shows, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(name)
                        .font(.headline)
                    Text(help)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(width: 300)
            }
        }
    }
}

private enum MetricHelp {
    static let finite = "Fraction of samples that are valid numbers (not NaN, infinity, or dropped). Low values point to data loss, recording glitches, or a failing connection — a channel missing many samples can't be trusted no matter how clean the rest looks."

    static let amplitude = "The channel's typical signal size (95th-percentile amplitude) compared to the recording's median channel. Values far above or below peers suggest a noisy, mis-scaled, bridged, or disconnected electrode rather than genuine brain activity."

    static let burst = "How large the biggest excursions are versus the channel's own typical peaks (99th percentile). Frequent extreme spikes indicate movement, electrode pops, or transient artifacts that will contaminate averages and analyses."

    static let flatline = "Fraction of samples showing little or no change. A high flatline fraction is the signature of a dead, disconnected, or saturated electrode that is no longer recording real signal."

    static let clipping = "Fraction of samples pinned at the amplifier's maximum (the rail). Clipping means the signal exceeded the recordable range, so its true shape is lost and any features there are distorted."

    static let fastNoise = "Sample-to-sample change relative to what's typical for the recording. Elevated values mean high-frequency noise — muscle (EMG), electrical interference, or a poor connection — riding on top of the channel."

    static let slowDrift = "Low-frequency baseline wander (block-mean drift) relative to typical. High drift comes from poor electrode contact, sweat, or slow movement, and pulls the baseline around even when the fast signal looks fine."
}
