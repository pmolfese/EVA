//
//  PreferencesView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The app's centralized Preferences window (⌘,), generalizing the old
//  Channel-Goodness sheet into a tabbed panel (REFACTOR.md settings step). Each
//  tab binds to a persisted settings store; "Processing Defaults" seeds each
//  newly-opened recording's per-run stores.
//

import SwiftUI

nonisolated enum EVAGeneralPreferences {
    static let pixelAdaptiveWaveformRenderingKey = "pixelAdaptiveWaveformRenderingEnabled"
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
    @AppStorage(ToolbarButtonLabels.storageKey) private var showsToolbarButtonLabels = true

    var body: some View {
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
        }
        .formStyle(.grouped)
        .padding(.top, 4)
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
