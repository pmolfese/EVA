//
//  SegmentGoodnessSettings.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Sticky, app-wide configuration for the segment-goodness fit metrics.
//  Mirrors ChannelGoodnessSettings.swift, but there is only one metric family
//  (no on-demand sub-detectors), so the settings model and view are flatter.
//

import SwiftUI

@MainActor
@Observable
final class SegmentGoodnessSettings {
    var base: SegmentHealthMetricSettings { didSet { save() } }

    private static let storageKey = "SegmentGoodnessSettings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            base = stored.base
        } else {
            base = .defaults
        }
    }

    func restoreDefaults() {
        base = .defaults
    }

    /// Forward/backward-compatible: any field missing from stored JSON falls
    /// back to its default rather than failing the whole decode.
    private struct Stored: Codable {
        var base: SegmentHealthMetricSettings

        init(base: SegmentHealthMetricSettings) {
            self.base = base
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            base = try container.decodeIfPresent(SegmentHealthMetricSettings.self, forKey: .base) ?? .defaults
        }
    }

    private func save() {
        let stored = Stored(base: base)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

struct SegmentGoodnessSettingsView: View {
    @Environment(SegmentGoodnessSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 14) {
            Text("Segment Goodness Settings")
                .font(.title3.weight(.semibold))

            Text("For continuous metrics, \u{201C}Good\u{201D} scores 1.0, \u{201C}Poor\u{201D} scores 0.0, and values between interpolate. Labeled Artifacts is binary: any overlap scores 0.0.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

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

                    row("Finite Samples", help: SegmentMetricHelp.finite, enabled: $settings.base.finiteEnabled, green: $settings.base.finiteGreen, red: $settings.base.finiteRed, weight: $settings.base.finiteWeight, fraction: 3)
                    row("Channel Coverage", help: SegmentMetricHelp.channelCoverage, enabled: $settings.base.channelCoverageEnabled, green: $settings.base.channelCoverageGreen, red: $settings.base.channelCoverageRed, weight: $settings.base.channelCoverageWeight, fraction: 2)
                    row("Global Field Power", help: SegmentMetricHelp.gfp, enabled: $settings.base.gfpEnabled, green: $settings.base.gfpGreen, red: $settings.base.gfpRed, weight: $settings.base.gfpWeight, fraction: 1)
                    row("Segment Amplitude", help: SegmentMetricHelp.amplitude, enabled: $settings.base.amplitudeEnabled, green: $settings.base.amplitudeGreen, red: $settings.base.amplitudeRed, weight: $settings.base.amplitudeWeight, fraction: 1)
                    row("Burst Peaks", help: SegmentMetricHelp.burst, enabled: $settings.base.burstEnabled, green: $settings.base.burstGreen, red: $settings.base.burstRed, weight: $settings.base.burstWeight, fraction: 1)
                    row("GFP Bursts", help: SegmentMetricHelp.gfpBurst, enabled: $settings.base.gfpBurstEnabled, green: $settings.base.gfpBurstGreen, red: $settings.base.gfpBurstRed, weight: $settings.base.gfpBurstWeight, fraction: 1)
                    // Flatline and Clipping combine into one scored metric, so they share one enable flag and weight.
                    row("Flatline", help: SegmentMetricHelp.flatline, enabled: $settings.base.dropoutEnabled, green: $settings.base.flatlineGreen, red: $settings.base.flatlineRed, weight: $settings.base.dropoutWeight, fraction: 3)
                    row("Clipping", help: SegmentMetricHelp.clipping, enabled: $settings.base.dropoutEnabled, green: $settings.base.clippingGreen, red: $settings.base.clippingRed, weight: $settings.base.dropoutWeight, fraction: 3)
                    row("Fast Noise", help: SegmentMetricHelp.fastNoise, enabled: $settings.base.fastNoiseEnabled, green: $settings.base.fastNoiseGreen, red: $settings.base.fastNoiseRed, weight: $settings.base.fastNoiseWeight, fraction: 1)
                    row("Slow Drift", help: SegmentMetricHelp.slowDrift, enabled: $settings.base.slowDriftEnabled, green: $settings.base.slowDriftGreen, red: $settings.base.slowDriftRed, weight: $settings.base.slowDriftWeight, fraction: 1)
                    binaryRow("Labeled Artifacts", help: SegmentMetricHelp.artifact, enabled: $settings.base.artifactEnabled, weight: $settings.base.artifactWeight)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)

            Spacer(minLength: 0)

            HStack {
                Button("Restore Defaults") { settings.restoreDefaults() }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 470)
    }

    private func row(
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

    private func binaryRow(
        _ name: String,
        help: String,
        enabled: Binding<Bool>,
        weight: Binding<Double>
    ) -> some View {
        GridRow {
            MetricHelpLabel(name: name, help: help)
            Toggle("", isOn: enabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 40)
            Text("—")
                .frame(width: 62)
                .foregroundStyle(.secondary)
            Text("—")
                .frame(width: 62)
                .foregroundStyle(.secondary)
            TextField("", value: weight, format: .number.precision(.fractionLength(1)))
                .frame(width: 62)
                .disabled(!enabled.wrappedValue)
        }
    }
}

private enum SegmentMetricHelp {
    static let finite = "Fraction of samples that are valid numbers (not NaN, infinity, or dropped) across the segment's included channels. Low values point to data loss or a broken recording within this window."

    static let channelCoverage = "Fraction of the recording's channels included in this segment's scoring (bad/excluded channels are left out). Low coverage means the segment's other metrics rest on fewer channels than usual."

    static let gfp = "The segment's Global Field Power (spatial standard deviation across channels) at its 95th percentile, compared to what's typical for the recording. High GFP suggests a burst of large-amplitude activity or artifact across many channels at once."

    static let amplitude = "The segment's typical signal size (95th-percentile absolute amplitude) compared to what's typical for the recording. Values far above typical suggest noise, movement, or an artifact-laden window."

    static let burst = "How large the segment's biggest excursion is versus the recording's typical peak (99th percentile). Flags brief, extreme spikes within an otherwise ordinary segment."

    static let gfpBurst = "The segment's peak Global Field Power versus what's typical for the recording. Flags a brief moment where many channels spike together, characteristic of a shared artifact (e.g. a movement or electrical event)."

    static let flatline = "Fraction of samples in the segment showing little or no change. A high flatline fraction points to a stretch of dead or disconnected signal within the segment."

    static let clipping = "Fraction of samples in the segment pinned at the amplifier's maximum. Clipping means part of the segment's signal exceeded the recordable range."

    static let fastNoise = "Sample-to-sample change within the segment relative to what's typical for the recording. Elevated values mean high-frequency noise (muscle, electrical interference) concentrated in this window."

    static let slowDrift = "Baseline shift from the start to the end of the segment, relative to what's typical. High drift suggests slow movement or electrode-contact changes during the segment. Only scored for segments long enough to measure a meaningful shift."

    static let artifact = "Whether the segment contains any labeled artifact interval (from threshold/template/ICA detection). This metric is binary: no labeled artifact scores fully good; any overlap scores fully poor."
}
