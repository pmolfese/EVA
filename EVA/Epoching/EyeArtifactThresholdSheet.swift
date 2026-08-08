//
//  EyeArtifactThresholdSheet.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Eye-blink / eye-movement threshold configuration sheet, extracted from
//  WaveformView.swift during the L5 view-decomposition refactor.
//

import SwiftUI

struct EyeArtifactThresholdSheet: View {
    let signal: MFFSignalData
    let sensorLayoutName: String?
    @Binding var detectsEyeBlinkArtifacts: Bool
    @Binding var detectsEyeMovementArtifacts: Bool
    @Binding var blinkChannelOverrideText: String
    @Binding var movementChannelOverrideText: String
    @Bindable var artifactVM: ArtifactViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ocular Artifact Thresholds")
                    .font(.headline)
                Text("Tune the threshold detector for eye blinks and eye movements independently. Each tab's toggle controls whether that artifact is detected — enable one or both.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Divider()

            TabView {
                eyeThresholdTab(
                    title: "Eye Blink",
                    kind: .blink,
                    enabled: $detectsEyeBlinkArtifacts,
                    config: $artifactVM.blinkThresholdConfig,
                    channelText: $blinkChannelOverrideText,
                    signal: signal,
                    sensorLayoutName: sensorLayoutName
                )
                .tabItem { Text("Eye Blink") }

                eyeThresholdTab(
                    title: "Eye Movement",
                    kind: .movement,
                    enabled: $detectsEyeMovementArtifacts,
                    config: $artifactVM.movementThresholdConfig,
                    channelText: $movementChannelOverrideText,
                    signal: signal,
                    sensorLayoutName: sensorLayoutName
                )
                .tabItem { Text("Eye Movement") }
            }
            .padding(20)

            Divider()

            HStack {
                Button("Restore Defaults") {
                    artifactVM.blinkThresholdConfig = .defaults(for: .blink)
                    artifactVM.movementThresholdConfig = .defaults(for: .movement)
                    blinkChannelOverrideText = ""
                    movementChannelOverrideText = ""
                    saveThresholdDefaults()
                }
                Spacer()
                Button("Done") {
                    saveThresholdDefaults()
                    artifactVM.showsThresholdSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
            .padding(.top, 12)
        }
        .frame(width: 520, height: 560)
        .onAppear {
            blinkChannelOverrideText = channelOverrideText(artifactVM.blinkThresholdConfig.channelOverride)
            movementChannelOverrideText = channelOverrideText(artifactVM.movementThresholdConfig.channelOverride)
        }
        .onDisappear {
            saveThresholdDefaults()
        }
    }

    @ViewBuilder
    private func eyeThresholdTab(
        title: String,
        kind: EyeArtifactKind,
        enabled: Binding<Bool>,
        config: Binding<EyeArtifactThresholdConfiguration>,
        channelText: Binding<String>,
        signal: MFFSignalData,
        sensorLayoutName: String?
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Detect \(title)", isOn: enabled)
                    .toggleStyle(.switch)
                    .font(.callout.weight(.semibold))

                Group {
                    thresholdSection("Topology") {
                        Picker("Signal", selection: config.topologyMode) {
                            ForEach(EyeArtifactTopologyMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(topologyCaption(kind: kind, mode: config.wrappedValue.topologyMode))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    thresholdSection("Amplitude") {
                        thresholdFloatRow("Minimum", value: config.amplitudeMinMicrovolts,
                                          unit: "µV", range: 10...500, step: 5)
                        thresholdFloatRow("Maximum", value: config.amplitudeMaxMicrovolts,
                                          unit: "µV", range: 0...2000, step: 25,
                                          caption: "0 = no cap; higher peaks are rejected as saturation.")
                        Picker("Polarity", selection: config.polarity) {
                            ForEach(EyeArtifactPolarity.allCases) { p in Text(p.rawValue).tag(p) }
                        }
                        .pickerStyle(.segmented)
                    }

                    thresholdSection("Timing") {
                        thresholdDoubleRow("Rise window", value: config.riseWindowSeconds,
                                           unit: "s", range: 0...2, step: 0.05, fraction: 2,
                                           caption: "Baseline→peak must complete within this time. 0 = unconstrained.")
                        thresholdDoubleRow("Min duration", value: config.minDurationSeconds,
                                           unit: "s", range: 0...1, step: 0.01, fraction: 2)
                        thresholdDoubleRow("Max duration", value: config.maxDurationSeconds,
                                           unit: "s", range: 0...5, step: 0.05, fraction: 2,
                                           caption: "0 = no cap.")
                        thresholdDoubleRow("Merge gap", value: config.mergeGapSeconds,
                                           unit: "s", range: 0...1, step: 0.05, fraction: 2,
                                           caption: "Events closer than this are fused into one.")
                    }

                    thresholdSection("Kinematics") {
                        Toggle("Velocity gate", isOn: config.velocityEnabled)
                        thresholdFloatRow("Min velocity", value: config.velocityThresholdMicrovoltsPerMillisecond,
                                          unit: "µV/ms", range: 0...50, step: 0.5, fraction: 1)
                            .disabled(!config.velocityEnabled.wrappedValue)
                        Toggle("Acceleration gate", isOn: config.accelerationEnabled)
                        thresholdFloatRow("Min acceleration", value: config.accelerationThresholdMicrovoltsPerMillisecondSquared,
                                          unit: "µV/ms²", range: 0...20, step: 0.25, fraction: 2)
                            .disabled(!config.accelerationEnabled.wrappedValue)
                    }

                    thresholdSection("Channels") {
                        Text(channelUsageHeadline(
                            kind: kind,
                            config: config.wrappedValue,
                            signal: signal,
                            sensorLayoutName: sensorLayoutName
                        ))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            TextField("Override channels", text: channelText)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: channelText.wrappedValue) { _, text in
                                    let parsed = WaveformView.parseChannelList(text, channelCount: signal.numberOfChannels)
                                    config.wrappedValue.channelOverride = parsed.isEmpty ? nil : parsed
                                }
                            Button("Use Auto") {
                                channelText.wrappedValue = ""
                                config.wrappedValue.channelOverride = nil
                            }
                        }
                        Text(channelOverrideCaption(
                            kind: kind,
                            config: config.wrappedValue,
                            signal: signal,
                            sensorLayoutName: sensorLayoutName
                        ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!enabled.wrappedValue)
                .opacity(enabled.wrappedValue ? 1 : 0.5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func thresholdSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func thresholdFloatRow(
        _ label: String, value: Binding<Float>, unit: String,
        range: ClosedRange<Float>, step: Float, fraction: Int = 0, caption: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).frame(width: 110, alignment: .leading)
                TextField(label, value: value, format: .number.precision(.fractionLength(fraction)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                Text(unit).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                Slider(value: value, in: range, step: step)
            }
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func thresholdDoubleRow(
        _ label: String, value: Binding<Double>, unit: String,
        range: ClosedRange<Double>, step: Double, fraction: Int, caption: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).frame(width: 110, alignment: .leading)
                TextField(label, value: value, format: .number.precision(.fractionLength(fraction)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                Text(unit).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                Slider(value: value, in: range, step: step)
            }
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func channelOverrideText(_ indices: [Int]?) -> String {
        guard let indices, !indices.isEmpty else { return "" }
        return indices.map { String($0 + 1) }.joined(separator: ", ")
    }

    private func channelUsageHeadline(
        kind: EyeArtifactKind,
        config: EyeArtifactThresholdConfiguration,
        signal: MFFSignalData,
        sensorLayoutName: String?
    ) -> String {
        let autoNames = autoChannelNames(kind: kind, signal: signal, sensorLayoutName: sensorLayoutName)
        if let override = config.channelOverride, !override.isEmpty {
            let valid = override.filter { $0 >= 0 && $0 < signal.numberOfChannels }
            let overrideNames = valid.map { String($0 + 1) }.joined(separator: ", ")
            return "Override: \(overrideNames)"
        }
        return "Auto: \(autoNames)"
    }

    private func channelOverrideCaption(
        kind: EyeArtifactKind,
        config: EyeArtifactThresholdConfiguration,
        signal: MFFSignalData,
        sensorLayoutName: String?
    ) -> String {
        let autoNames = autoChannelNames(kind: kind, signal: signal, sensorLayoutName: sensorLayoutName)
        let autoSource: String
        if let sensorLayoutName, !sensorLayoutName.isEmpty {
            autoSource = sensorLayoutName
        } else {
            autoSource = "channel-count fallback"
        }

        if let override = config.channelOverride, !override.isEmpty {
            let valid = override.filter { $0 >= 0 && $0 < signal.numberOfChannels }
            let overrideNames = valid.map { String($0 + 1) }.joined(separator: ", ")
            return "Override: channels \(overrideNames). Auto (\(autoSource)) would use: \(autoNames)."
        }
        return "Auto (\(autoSource)): channels \(autoNames)."
    }

    private func autoChannelNames(
        kind: EyeArtifactKind,
        signal: MFFSignalData,
        sensorLayoutName: String?
    ) -> String {
        EyeArtifactThresholdDetector
            .autoOcularChannelIndices(
                kind: kind,
                channelCount: signal.numberOfChannels,
                sensorLayoutName: sensorLayoutName
            )
            .map { String($0 + 1) }
            .joined(separator: ", ")
    }

    private func topologyCaption(kind: EyeArtifactKind, mode: EyeArtifactTopologyMode) -> String {
        switch (kind, mode) {
        case (.blink, .derivedOcular):
            return "Thresholds a derived VEOG-like trace that requires same-polarity activity over both eyes, reducing eye-movement cross-labeling."
        case (.movement, .derivedOcular):
            return "Thresholds a derived HEOG-like left-right opponent trace, reducing blink cross-labeling."
        case (_, .legacyMaxChannel):
            return "Original behavior: thresholds whichever selected ocular channel has the largest absolute value at each sample."
        }
    }

    private func saveThresholdDefaults() {
        ProcessingDefaults.shared.ocularBlinkThresholdConfig = artifactVM.blinkThresholdConfig
        ProcessingDefaults.shared.ocularMovementThresholdConfig = artifactVM.movementThresholdConfig
    }
}
