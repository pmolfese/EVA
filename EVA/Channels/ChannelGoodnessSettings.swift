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
//  Sticky, app-wide configuration for the channel-goodness fit metrics. The
//  spectral and neighbor-prediction detectors run as part of the default health
//  pass; the wavelet burden detector is run on demand. All knobs are grouped in
//  Channels -> "Channel Goodness Settings..." and persisted to user defaults.
//

import SwiftUI

/// Configuration for the on-demand wavelet channel-burden detector.
struct ChannelWaveletGoodnessSettings: Codable, Sendable {
    var family: WaveletReductionFamily = .bior44
    var levelCount: Int = 8
    var thresholdModel: WaveletCleaningThresholdModel = .bayesShrink
    var thresholdRule: WaveletCleaningThresholdRule = .hard
    var downsampleRate: Double = 250
    var cleaningMode: WaveletCleaningMode = .conservativeLocal
    var intensity: Double = WaveletCleaningMode.conservativeLocal.defaultIntensity
    /// Contribution of this metric to the overall channel health score.
    var weight: Double = 1.4

    static let defaults = ChannelWaveletGoodnessSettings()
}

@MainActor
@Observable
final class ChannelGoodnessSettings {
    var base: ChannelBaseMetricSettings { didSet { save() } }
    var impedance: ChannelImpedanceSettings { didSet { save() } }
    var spectral: ChannelSpectralConfiguration { didSet { save() } }
    var ransac: ChannelRansacConfiguration { didSet { save() } }
    var wavelet: ChannelWaveletGoodnessSettings { didSet { save() } }

    private static let storageKey = "ChannelGoodnessSettings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            base = stored.base
            impedance = stored.impedance
            spectral = stored.spectral
            ransac = stored.ransac
            wavelet = stored.wavelet
        } else {
            base = .defaults
            impedance = .defaults
            spectral = .happeStandard
            ransac = .happeStandard
            wavelet = .defaults
        }
    }

    func restoreDefaults() {
        base = .defaults
        impedance = .defaults
        spectral = .happeStandard
        ransac = .happeStandard
        wavelet = .defaults
    }

    /// Forward/backward-compatible: any field missing from stored JSON falls
    /// back to its default rather than failing the whole decode.
    private struct Stored: Codable {
        var base: ChannelBaseMetricSettings
        var impedance: ChannelImpedanceSettings
        var spectral: ChannelSpectralConfiguration
        var ransac: ChannelRansacConfiguration
        var wavelet: ChannelWaveletGoodnessSettings

        init(
            base: ChannelBaseMetricSettings,
            impedance: ChannelImpedanceSettings,
            spectral: ChannelSpectralConfiguration,
            ransac: ChannelRansacConfiguration,
            wavelet: ChannelWaveletGoodnessSettings
        ) {
            self.base = base
            self.impedance = impedance
            self.spectral = spectral
            self.ransac = ransac
            self.wavelet = wavelet
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            base = try container.decodeIfPresent(ChannelBaseMetricSettings.self, forKey: .base) ?? .defaults
            impedance = try container.decodeIfPresent(ChannelImpedanceSettings.self, forKey: .impedance) ?? .defaults
            spectral = try container.decodeIfPresent(ChannelSpectralConfiguration.self, forKey: .spectral) ?? .happeStandard
            ransac = try container.decodeIfPresent(ChannelRansacConfiguration.self, forKey: .ransac) ?? .happeStandard
            wavelet = try container.decodeIfPresent(ChannelWaveletGoodnessSettings.self, forKey: .wavelet) ?? .defaults
        }
    }

    private func save() {
        let stored = Stored(base: base, impedance: impedance, spectral: spectral, ransac: ransac, wavelet: wavelet)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

private enum GoodnessSettingsTool: String, CaseIterable, Identifiable {
    case base = "Core"
    case impedance = "Impedance"
    case spectral = "Spectral"
    case ransac = "Neighbor"
    case wavelet = "Wavelet"

    var id: String { rawValue }

    var caption: String {
        switch self {
        case .base:
            return "Green/red thresholds for the always-on core health metrics. \u{201C}Green\u{201D} scores fully good (1.0); \u{201C}Red\u{201D} scores fully poor (0.0); values between interpolate."
        case .impedance:
            return "EGI-style electrode contact-quality bands (great/good/fair/poor), only scored when the file recorded an impedance value. Great scores fully good (1.0); Poor scores fully poor (0.0)."
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
                case .impedance: impedanceSection(settings: settings)
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
        .frame(width: 460, height: 470)
    }

    private func restoreCurrentTool() {
        switch tool {
        case .base: settings.base = .defaults
        case .impedance: settings.impedance = .defaults
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
                    MetricHelpLabel(name: "On", help: FieldHelp.enabled).frame(width: 40)
                    MetricHelpLabel(name: "Good", help: FieldHelp.good).frame(width: 62)
                    MetricHelpLabel(name: "Poor", help: FieldHelp.poor).frame(width: 62)
                    MetricHelpLabel(name: "Weight", help: FieldHelp.weight).frame(width: 62)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                baseRow("Finite Samples", help: MetricHelp.finite, enabled: $settings.base.finiteEnabled, green: $settings.base.finiteGreen, red: $settings.base.finiteRed, weight: $settings.base.finiteWeight, fraction: 3)
                baseRow("Signal Amplitude", help: MetricHelp.amplitude, enabled: $settings.base.amplitudeEnabled, green: $settings.base.amplitudeGreen, red: $settings.base.amplitudeRed, weight: $settings.base.amplitudeWeight, fraction: 1)
                baseRow("Burst Peaks", help: MetricHelp.burst, enabled: $settings.base.burstEnabled, green: $settings.base.burstGreen, red: $settings.base.burstRed, weight: $settings.base.burstWeight, fraction: 1)
                baseRow("Flatline", help: MetricHelp.flatline, enabled: $settings.base.flatlineEnabled, green: $settings.base.flatlineGreen, red: $settings.base.flatlineRed, weight: $settings.base.flatlineWeight, fraction: 3)
                baseRow("Clipping", help: MetricHelp.clipping, enabled: $settings.base.clippingEnabled, green: $settings.base.clippingGreen, red: $settings.base.clippingRed, weight: $settings.base.clippingWeight, fraction: 3)
                baseRow("Fast Noise", help: MetricHelp.fastNoise, enabled: $settings.base.fastNoiseEnabled, green: $settings.base.fastNoiseGreen, red: $settings.base.fastNoiseRed, weight: $settings.base.fastNoiseWeight, fraction: 1)
                baseRow("Slow Drift", help: MetricHelp.slowDrift, enabled: $settings.base.slowDriftEnabled, green: $settings.base.slowDriftGreen, red: $settings.base.slowDriftRed, weight: $settings.base.slowDriftWeight, fraction: 1)
            }
        }
    }

    private func baseRow(
        _ name: String,
        help: String,
        enabled: Binding<Bool>,
        green: Binding<Double>,
        red: Binding<Double>,
        weight: Binding<Double>,
        fraction: Int
    ) -> some View {
        GridRow {
            MetricHelpLabel(name: name, help: help)
            Toggle("", isOn: enabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 40)
            TextField("", value: green, format: .number.precision(.fractionLength(fraction)))
                .frame(width: 62)
                .disabled(!enabled.wrappedValue)
            TextField("", value: red, format: .number.precision(.fractionLength(fraction)))
                .frame(width: 62)
                .disabled(!enabled.wrappedValue)
            TextField("", value: weight, format: .number.precision(.fractionLength(1)))
                .frame(width: 62)
                .disabled(!enabled.wrappedValue)
        }
    }

    @ViewBuilder
    private func impedanceSection(settings: ChannelGoodnessSettings) -> some View {
        @Bindable var settings = settings
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                MetricHelpLabel(name: "Enabled", help: FieldHelp.enabled)
                Toggle("", isOn: $settings.impedance.isEnabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            GridRow {
                MetricHelpLabel(name: "Great max (kΩ)", help: FieldHelp.impedanceGreatMax)
                TextField("kΩ", value: $settings.impedance.greatMaxKOhm, format: .number.precision(.fractionLength(0)))
                    .frame(width: 90)
            }
            GridRow {
                MetricHelpLabel(name: "Good max (kΩ)", help: FieldHelp.impedanceGoodMax)
                TextField("kΩ", value: $settings.impedance.goodMaxKOhm, format: .number.precision(.fractionLength(0)))
                    .frame(width: 90)
            }
            GridRow {
                MetricHelpLabel(name: "Fair max (kΩ)", help: FieldHelp.impedanceFairMax)
                TextField("kΩ", value: $settings.impedance.fairMaxKOhm, format: .number.precision(.fractionLength(0)))
                    .frame(width: 90)
            }
            GridRow {
                MetricHelpLabel(name: "Poor max (kΩ)", help: FieldHelp.impedancePoorMax)
                TextField("kΩ", value: $settings.impedance.poorMaxKOhm, format: .number.precision(.fractionLength(0)))
                    .frame(width: 90)
            }
            GridRow {
                MetricHelpLabel(name: "Weight", help: FieldHelp.weight)
                TextField("x", value: $settings.impedance.weight, format: .number.precision(.fractionLength(1)))
                    .frame(width: 90)
            }
        }
    }

    @ViewBuilder
    private func spectralSection(settings: ChannelGoodnessSettings) -> some View {
        @Bindable var settings = settings
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                MetricHelpLabel(name: "Enabled", help: FieldHelp.enabled)
                Toggle("", isOn: $settings.spectral.isEnabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            GridRow {
                MetricHelpLabel(name: "Low freq (Hz)", help: FieldHelp.spectralLowFrequency)
                TextField("Hz", value: $settings.spectral.lowFrequencyHz, format: .number.precision(.fractionLength(1)))
                    .frame(width: 90)
            }
            GridRow {
                MetricHelpLabel(name: "High freq (Hz)", help: FieldHelp.spectralHighFrequency)
                TextField("Hz", value: $settings.spectral.highFrequencyHz, format: .number.precision(.fractionLength(1)))
                    .frame(width: 90)
            }
            GridRow {
                MetricHelpLabel(name: "Upper z", help: FieldHelp.spectralUpperZ)
                TextField("z", value: $settings.spectral.upperZThreshold, format: .number.precision(.fractionLength(2)))
                    .frame(width: 90)
            }
            GridRow {
                MetricHelpLabel(name: "Lower z", help: FieldHelp.spectralLowerZ)
                TextField("z", value: $settings.spectral.lowerZThreshold, format: .number.precision(.fractionLength(2)))
                    .frame(width: 90)
            }
            GridRow {
                MetricHelpLabel(name: "Weight", help: FieldHelp.weight)
                TextField("x", value: $settings.spectral.weight, format: .number.precision(.fractionLength(1)))
                    .frame(width: 90)
            }
        }
    }

    @ViewBuilder
    private func ransacSection(settings: ChannelGoodnessSettings) -> some View {
        @Bindable var settings = settings
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                MetricHelpLabel(name: "Enabled", help: FieldHelp.enabled)
                Toggle("", isOn: $settings.ransac.isEnabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            GridRow {
                MetricHelpLabel(name: "Min correlation", help: FieldHelp.ransacMinimumCorrelation)
                TextField("r", value: $settings.ransac.minimumCorrelation, format: .number.precision(.fractionLength(3)))
                    .frame(width: 90)
            }
            GridRow {
                MetricHelpLabel(name: "Neighbors", help: FieldHelp.ransacNeighborCount)
                Stepper("\(settings.ransac.neighborCount)", value: $settings.ransac.neighborCount, in: 2...12)
                    .frame(width: 120)
            }
            GridRow {
                MetricHelpLabel(name: "Window (s)", help: FieldHelp.ransacWindowSeconds)
                TextField("s", value: $settings.ransac.windowSeconds, format: .number.precision(.fractionLength(1)))
                    .frame(width: 90)
            }
            GridRow {
                MetricHelpLabel(name: "Weight", help: FieldHelp.weight)
                TextField("x", value: $settings.ransac.weight, format: .number.precision(.fractionLength(1)))
                    .frame(width: 90)
            }
        }
    }

    @ViewBuilder
    private func waveletSection(settings: ChannelGoodnessSettings) -> some View {
        @Bindable var settings = settings
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                MetricHelpLabel(name: "Wavelet", help: FieldHelp.waveletFamily)
                Picker("", selection: $settings.wavelet.family) {
                    ForEach(WaveletReductionFamily.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            GridRow {
                MetricHelpLabel(name: "Cleaning mode", help: FieldHelp.waveletCleaningMode)
                Picker("", selection: $settings.wavelet.cleaningMode) {
                    ForEach(WaveletCleaningMode.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            GridRow {
                MetricHelpLabel(name: "Threshold model", help: FieldHelp.waveletThresholdModel)
                Picker("", selection: $settings.wavelet.thresholdModel) {
                    ForEach(WaveletCleaningThresholdModel.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            GridRow {
                MetricHelpLabel(name: "Threshold rule", help: FieldHelp.waveletThresholdRule)
                Picker("", selection: $settings.wavelet.thresholdRule) {
                    ForEach(WaveletCleaningThresholdRule.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            GridRow {
                MetricHelpLabel(name: "Levels", help: FieldHelp.waveletLevelCount)
                Stepper("\(settings.wavelet.levelCount)", value: $settings.wavelet.levelCount, in: 1...WaveletArtifactAnalyzer.maximumLevelCount)
                    .frame(width: 120)
            }
            GridRow {
                MetricHelpLabel(name: "Intensity", help: FieldHelp.waveletIntensity)
                TextField("x", value: $settings.wavelet.intensity, format: .number.precision(.fractionLength(2)))
                    .frame(width: 90)
            }
            GridRow {
                MetricHelpLabel(name: "Downsample (Hz)", help: FieldHelp.waveletDownsampleRate)
                TextField("Hz", value: $settings.wavelet.downsampleRate, format: .number.precision(.fractionLength(0)))
                    .frame(width: 90)
            }
            GridRow {
                MetricHelpLabel(name: "Weight", help: FieldHelp.weight)
                TextField("x", value: $settings.wavelet.weight, format: .number.precision(.fractionLength(1)))
                    .frame(width: 90)
            }
        }
    }
}

/// A metric name followed by a "?" button that explains what the metric measures
/// and why it matters for channel goodness.
struct MetricHelpLabel: View {
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

enum FieldHelp {
    static let impedanceGreatMax = "Impedance (kΩ) at or below which a channel scores fully good (1.0) — a clean, low-resistance scalp-electrode contact. Only applies to files that recorded an impedance value."

    static let impedanceGoodMax = "Impedance (kΩ) marking the top of the \u{201C}good\u{201D} band. Between Great and Good, the score interpolates down from 1.0."

    static let impedanceFairMax = "Impedance (kΩ) marking the top of the \u{201C}fair\u{201D} band. Between Good and Fair, the score keeps interpolating downward — channels here are still usable but worth watching."

    static let impedancePoorMax = "Impedance (kΩ) at or above which a channel scores fully poor (0.0) — a failing scalp-electrode connection likely to introduce noise and drift. Between Fair and Poor, the score interpolates down to 0."

    static let enabled = "Whether this metric runs at all. When off, it's skipped entirely and dropped from the weighted overall percentage — the other metrics simply carry more weight."

    static let good = "The value at which this metric scores fully good (1.0). Values at least this favorable never drag the channel's overall percentage down."

    static let poor = "The value at which this metric scores fully poor (0.0). Values at least this unfavorable count as a complete failure for this metric alone. Between Good and Poor, the score interpolates."

    static let weight = "How much this metric counts toward the overall goodness percentage, relative to the other metrics. Higher weight means this metric moves the overall score more; 0 removes its influence entirely without disabling the underlying detector."

    static let spectralLowFrequency = "Low edge (Hz) of the power band examined for the spectral-outlier check. Narrows or widens which frequencies contribute to each channel's band-power estimate."

    static let spectralHighFrequency = "High edge (Hz) of the power band examined for the spectral-outlier check, clamped to the recording's Nyquist frequency."

    static let spectralUpperZ = "Channels whose band-power z-score exceeds this are flagged as abnormally noisy (too much power for the band, relative to other channels)."

    static let spectralLowerZ = "Channels whose band-power z-score falls below the negative of this are flagged as abnormally quiet (too little power for the band). HAPPE keeps this lenient by default."

    static let ransacMinimumCorrelation = "Minimum acceptable correlation between a channel and its neighbor-based reconstruction. Below this, the channel is flagged as poorly predicted by its neighbors — the RANSAC/clean_rawdata ChannelCriterion check."

    static let ransacNeighborCount = "Number of nearest neighboring channels used to reconstruct each channel's expected signal for the neighbor-prediction check."

    static let ransacWindowSeconds = "Length, in seconds, of the sliding window over which neighbor-reconstruction correlation is measured. The median window correlation across the recording drives the decision."

    static let waveletFamily = "The mother wavelet used to decompose each channel when scoring its multiscale transient (artifact) burden. Different families trade off time vs. frequency localization."

    static let waveletCleaningMode = "How aggressively the wavelet detector treats a coefficient as artifact vs. genuine signal when estimating burden."

    static let waveletThresholdModel = "The statistical model used to set the wavelet-coefficient threshold that separates artifact from signal (e.g. BayesShrink)."

    static let waveletThresholdRule = "Whether coefficients past the threshold are hard-thresholded (kept or zeroed) or soft-thresholded (shrunk toward zero)."

    static let waveletLevelCount = "Number of wavelet decomposition levels analyzed. More levels reach lower frequencies but cost more to compute."

    static let waveletIntensity = "Scales how sensitive the wavelet burden score is to detected artifact energy, on top of the chosen cleaning mode's base sensitivity."

    static let waveletDownsampleRate = "Sampling rate (Hz) the signal is downsampled to before the wavelet transform runs — lowering this speeds up scoring at the cost of high-frequency detail."
}
