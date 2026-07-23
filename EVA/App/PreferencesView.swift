//
//  PreferencesView.swift
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
//  The app's centralized Preferences window (⌘,), generalizing the old
//  Channel-Goodness sheet into a tabbed panel (REFACTOR.md settings step). Each
//  tab binds to a persisted settings store; "Processing Defaults" seeds each
//  newly-opened recording's per-run stores.
//

import AppKit
import SwiftUI

nonisolated enum EVAGeneralPreferences {
    static let pixelAdaptiveWaveformRenderingKey = "pixelAdaptiveWaveformRenderingEnabled"
    static let waveformTimeMarkersAcrossTracesKey = "waveformTimeMarkersAcrossTracesEnabled"
    static let waveformTimeMarkerStyleKey = "waveformTimeMarkerStyle.v1"
}

nonisolated struct WaveformTimeMarkerStyle: Codable, Equatable {
    var red: Double = 0.55
    var green: Double = 0.20
    var blue: Double = 0.85
    var alpha: Double = 0.18
    var lineWidth: Double = 0.75
    var isSolid: Bool = false
    var dashOn: Double = 2
    var dashOff: Double = 5

    static let defaultValue = WaveformTimeMarkerStyle()

    private enum CodingKeys: String, CodingKey {
        case red
        case green
        case blue
        case alpha
        case lineWidth
        case isSolid
        case dashOn
        case dashOff
    }

    init(
        red: Double = 0.55,
        green: Double = 0.20,
        blue: Double = 0.85,
        alpha: Double = 0.18,
        lineWidth: Double = 0.75,
        isSolid: Bool = false,
        dashOn: Double = 2,
        dashOff: Double = 5
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.lineWidth = lineWidth
        self.isSolid = isSolid
        self.dashOn = dashOn
        self.dashOff = dashOff
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        red = try container.decodeIfPresent(Double.self, forKey: .red) ?? Self.defaultValue.red
        green = try container.decodeIfPresent(Double.self, forKey: .green) ?? Self.defaultValue.green
        blue = try container.decodeIfPresent(Double.self, forKey: .blue) ?? Self.defaultValue.blue
        alpha = try container.decodeIfPresent(Double.self, forKey: .alpha) ?? Self.defaultValue.alpha
        lineWidth = try container.decodeIfPresent(Double.self, forKey: .lineWidth) ?? Self.defaultValue.lineWidth
        isSolid = try container.decodeIfPresent(Bool.self, forKey: .isSolid) ?? Self.defaultValue.isSolid
        dashOn = try container.decodeIfPresent(Double.self, forKey: .dashOn) ?? Self.defaultValue.dashOn
        dashOff = try container.decodeIfPresent(Double.self, forKey: .dashOff) ?? Self.defaultValue.dashOff
    }

    static var defaultData: Data {
        (try? JSONEncoder().encode(defaultValue)) ?? Data()
    }

    static func decoded(from data: Data) -> WaveformTimeMarkerStyle {
        guard !data.isEmpty,
              let style = try? JSONDecoder().decode(WaveformTimeMarkerStyle.self, from: data)
        else { return defaultValue }
        return style.normalized()
    }

    var encodedData: Data {
        (try? JSONEncoder().encode(normalized())) ?? Self.defaultData
    }

    func normalized() -> WaveformTimeMarkerStyle {
        WaveformTimeMarkerStyle(
            red: Self.clamped(red, to: 0...1),
            green: Self.clamped(green, to: 0...1),
            blue: Self.clamped(blue, to: 0...1),
            alpha: Self.clamped(alpha, to: 0.05...0.8),
            lineWidth: Self.clamped(lineWidth, to: 0.25...3),
            isSolid: isSolid,
            dashOn: Self.clamped(dashOn, to: 1...12),
            dashOff: Self.clamped(dashOff, to: 1...16)
        )
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem { Label("General", systemImage: "gearshape") }

            ProcessingDefaultsView()
                .tabItem { Label("Processing", systemImage: "slider.horizontal.3") }

            ChannelGoodnessSettingsView()
                .tabItem { Label("Channel Goodness", systemImage: "waveform.path.ecg") }

            SegmentGoodnessSettingsView()
                .tabItem { Label("Segment Goodness", systemImage: "chart.bar.doc.horizontal") }
        }
        .frame(width: 480, height: 560)
    }
}

private struct GeneralPreferencesView: View {
    @AppStorage(EVAGeneralPreferences.pixelAdaptiveWaveformRenderingKey) private var pixelAdaptiveWaveformRendering = true
    @AppStorage(EVAGeneralPreferences.waveformTimeMarkersAcrossTracesKey) private var waveformTimeMarkersAcrossTraces = false
    @AppStorage(EVAGeneralPreferences.waveformTimeMarkerStyleKey) private var waveformTimeMarkerStyleData = WaveformTimeMarkerStyle.defaultData
    @AppStorage(ToolbarButtonLabels.storageKey) private var showsToolbarButtonLabels = true

    var body: some View {
        let markerStyle = WaveformTimeMarkerStyle.decoded(from: waveformTimeMarkerStyleData)

        Form {
            Section {
                Toggle("Pixel-adaptive waveform rendering", isOn: $pixelAdaptiveWaveformRendering)
                Toggle("Show toolbar button labels", isOn: $showsToolbarButtonLabels)
            } header: {
                Text("Interface")
            } footer: {
                Text("Pixel-adaptive rendering compresses dense traces to the visible screen resolution while preserving min/max excursions. Turn it off to use the original sample-by-sample path renderer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show time markers across EEG and PNS traces", isOn: $waveformTimeMarkersAcrossTraces)
                ColorPicker(
                    "Line color",
                    selection: Binding(
                        get: { color(from: markerStyle) },
                        set: { setWaveformTimeMarkerColor($0) }
                    ),
                    supportsOpacity: false
                )
                HStack {
                    Text("Line darkness")
                    Slider(
                        value: Binding(
                            get: { markerStyle.alpha },
                            set: { setWaveformTimeMarkerAlpha($0) }
                        ),
                        in: 0.05...0.8
                    )
                    Text("\(Int((markerStyle.alpha * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Line width")
                    Slider(
                        value: Binding(
                            get: { markerStyle.lineWidth },
                            set: { setWaveformTimeMarkerLineWidth($0) }
                        ),
                        in: 0.25...3
                    )
                    Text(String(format: "%.2f", markerStyle.lineWidth))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Toggle(
                    "Solid lines",
                    isOn: Binding(
                        get: { markerStyle.isSolid },
                        set: { setWaveformTimeMarkerSolid($0) }
                    )
                )
                HStack {
                    Text("Dash")
                    Slider(
                        value: Binding(
                            get: { markerStyle.dashOn },
                            set: { setWaveformTimeMarkerDash(on: $0, off: markerStyle.dashOff) }
                        ),
                        in: 1...12
                    )
                    Text(String(format: "%.0f", markerStyle.dashOn))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
                .disabled(markerStyle.isSolid)
                HStack {
                    Text("Gap")
                    Slider(
                        value: Binding(
                            get: { markerStyle.dashOff },
                            set: { setWaveformTimeMarkerDash(on: markerStyle.dashOn, off: $0) }
                        ),
                        in: 1...16
                    )
                    Text(String(format: "%.0f", markerStyle.dashOff))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
                .disabled(markerStyle.isSolid)
            } header: {
                Text("Time Markers")
            } footer: {
                Text("The Events track always shows faint one-second markers. Enable this to extend the same markers through the EEG and Physio tracers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }

    private func color(from style: WaveformTimeMarkerStyle) -> Color {
        let normalized = style.normalized()
        return Color(
            red: normalized.red,
            green: normalized.green,
            blue: normalized.blue,
            opacity: 1
        )
    }

    private func setWaveformTimeMarkerColor(_ color: Color) {
        var style = WaveformTimeMarkerStyle.decoded(from: waveformTimeMarkerStyleData)
        guard let nsColor = NSColor(color).usingColorSpace(.deviceRGB) else { return }
        style.red = Double(nsColor.redComponent)
        style.green = Double(nsColor.greenComponent)
        style.blue = Double(nsColor.blueComponent)
        waveformTimeMarkerStyleData = style.encodedData
    }

    private func setWaveformTimeMarkerAlpha(_ alpha: Double) {
        var style = WaveformTimeMarkerStyle.decoded(from: waveformTimeMarkerStyleData)
        style.alpha = alpha
        waveformTimeMarkerStyleData = style.encodedData
    }

    private func setWaveformTimeMarkerLineWidth(_ lineWidth: Double) {
        var style = WaveformTimeMarkerStyle.decoded(from: waveformTimeMarkerStyleData)
        style.lineWidth = lineWidth
        waveformTimeMarkerStyleData = style.encodedData
    }

    private func setWaveformTimeMarkerSolid(_ isSolid: Bool) {
        var style = WaveformTimeMarkerStyle.decoded(from: waveformTimeMarkerStyleData)
        style.isSolid = isSolid
        waveformTimeMarkerStyleData = style.encodedData
    }

    private func setWaveformTimeMarkerDash(on: Double, off: Double) {
        var style = WaveformTimeMarkerStyle.decoded(from: waveformTimeMarkerStyleData)
        style.dashOn = on
        style.dashOff = off
        waveformTimeMarkerStyleData = style.encodedData
    }
}

private struct ProcessingDefaultsView: View {
    @Environment(ProcessingDefaults.self) private var defaults

    var body: some View {
        @Bindable var defaults = defaults
        Form {
            Section("Filter") {
                HStack {
                    Text("High-pass")
                    Spacer()
                    TextField("Hz", value: $defaults.filterHighPassHz, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                    Text("Hz").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Low-pass")
                    Spacer()
                    TextField("Hz", value: $defaults.filterLowPassHz, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                    Text("Hz").foregroundStyle(.secondary)
                }
                Toggle("60 Hz notch", isOn: $defaults.filterNotch60)
                Toggle("Average reference", isOn: $defaults.filterAverageReference)
                Picker("Default filter type", selection: Binding(
                    get: { FilterFamily(rawValue: defaults.filterDefaultFamily) ?? .iir },
                    set: { defaults.filterDefaultFamily = $0.rawValue }
                )) {
                    Text("IIR (Butterworth)").tag(FilterFamily.iir)
                    Text("FIR Hybrid (Net Station)").tag(FilterFamily.auto)
                    Text("FIR (linear phase)").tag(FilterFamily.fir)
                }
                .help("Filter family used for NEW filtering. FIR Hybrid uses IIR for the high-pass below the crossover and linear-phase FIR elsewhere, like EGI Net Station. Replaying an existing eva.xml always reproduces its original method.")
            }

            Section("ICA") {
                Picker("Method", selection: $defaults.icaMethod) {
                    ForEach(ICAMethod.allCases) { Text($0.displayName).tag($0) }
                }
                Stepper("Components: \(defaults.icaComponentCount)", value: $defaults.icaComponentCount, in: 2...128)
            }

            Section("BCG") {
                Toggle("Auto-select proxy channel set on open", isOn: $defaults.bcgAutoSelectProxySet)
                Picker("Default method", selection: $defaults.bcgDefaultMethod) {
                    ForEach(BCGDetectionMethod.allCases) { Text($0.tabLabel).tag($0) }
                }
            }

            Section("Artifact Detection") {
                Picker("Default method", selection: $defaults.artifactDetectionDefaultMethod) {
                    ForEach(ArtifactDetectionMethod.selectableCases) { Text($0.rawValue).tag($0) }
                }
            }

            Section {
                Toggle("Estimate interpolated-channel health from neighbors", isOn: $defaults.interpolatedHealthFromNeighbors)
            } header: {
                Text("Channel Health")
            } footer: {
                Text("When on, interpolating a channel averages the health of its spline-contributing channels — fast, ideal on modest hardware. When off, the montage is fully re-analyzed for an exact score.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Run segment health automatically after segmentation", isOn: $defaults.autoRunSegmentHealthAfterSegmentation)
            } header: {
                Text("Segment Health")
            } footer: {
                Text("When on, single-trial PSA segmentation automatically turns on Segment Health and scores the newly created segments. Category averages are never scored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { defaults.restoreDefaults() }
                }
            } footer: {
                Text("These seed each newly-opened recording. Changing them does not affect the recording already open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }
}
