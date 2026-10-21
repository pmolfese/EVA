//
//  ChannelLocationImportViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import SwiftUI

struct ChannelLocationImportRequest: Identifiable {
    let id = UUID()
    let recordingID: UUID
    let recordingName: String
    let signal: MFFSignalData
    let montage: ElectrodeLocationFile
    let reference: ElectrodeGeometry.Reference?
    let layoutReference: SensorReference?

    var channelNames: [String] {
        signal.channelNames ?? (0..<signal.numberOfChannels).map { "Ch \($0 + 1)" }
    }
}

struct ChannelLocationImportView: View {
    let request: ChannelLocationImportRequest
    @Environment(\.dismiss) private var dismiss
    @State private var matching: ElectrodeLocationMatching = .names
    @State private var error: String?

    private var matches: [ElectrodeLocationFile.Match] {
        (try? request.montage.matches(channelNames: request.channelNames, using: matching)) ?? []
    }
    private var located: Int { matches.filter { $0.electrode?.hasLocation == true }.count }
    private var matchingProblem: String? {
        do { _ = try request.montage.matches(channelNames: request.channelNames, using: matching); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import EEG Locations").font(.title2.bold())
            Text("\(request.montage.sourceName) → \(request.recordingName)")
                .font(.callout).foregroundStyle(.secondary)
            Text(request.montage.formatDescription).font(.caption).foregroundStyle(.secondary)
            Picker("Match by", selection: $matching) {
                ForEach(ElectrodeLocationMatching.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)
            Text(matching == .numbers
                 ? "File Number 1 maps to recording channel 1, Number 2 to channel 2, and so on. Confirm that the acquisition order matches."
                 : "Electrode names are matched without case differences or EEG / -REF wrappers.")
                .font(.callout)
            HStack {
                Label("\(located) of \(request.signal.numberOfChannels) channels have locations", systemImage: "mappin.and.ellipse")
                Spacer()
                Text("\(request.montage.electrodes.count) file entries").foregroundStyle(.secondary)
            }.font(.callout)
            List(matches) { match in
                HStack {
                    Text("\(match.channelIndex + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    Text(match.recordingName).frame(width: 140, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text(match.electrode?.name ?? "No match").frame(maxWidth: .infinity, alignment: .leading)
                    Text(match.electrode?.hasLocation != true ? "No location" : match.electrode?.position == nil ? "2D layout" : "3D location")
                        .font(.caption).foregroundStyle(match.electrode?.hasLocation != true ? .secondary : .primary)
                }
            }
            .listStyle(.bordered)
            Text("Replaces the current EEG locations. Unmatched channels and entries without locations will have no scalp coordinates. Existing channel repairs are recalculated. Channel labels, order, and recorded samples stay the same. Export MFF to save the locations; the source file stays unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = error ?? matchingProblem { Text(message).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Apply Locations") { apply() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(located == 0 || ChannelsWindowModel.shared.activeRecordingID != request.recordingID)
            }
        }
        .padding(22)
        .frame(width: 700, height: 610)
        .onAppear {
            if (try? request.montage.matches(channelNames: request.channelNames, using: .names))?
                .contains(where: { $0.electrode?.hasLocation == true }) != true {
                matching = .numbers
            }
        }
        .onChange(of: matching) { _, _ in error = nil }
    }

    private func apply() {
        do {
            let override = try request.montage.resolved(channelNames: request.channelNames, using: matching, reference: request.reference, layoutReference: request.layoutReference)
            try ChannelsWindowModel.shared.applyLocationOverride(override, toRecording: request.recordingID)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

extension WaveformView {
    func applyEEGLocationOverride(_ value: EEGLocationOverride) throws {
        // Preserve acquisition-reference identity independently of the montage's
        // unnumbered REF/GND entries. They must never add phantom signal rows.
        let reference = value.layoutOverride == nil ? (value.geometry.reference ?? recording.electrodeGeometry?.reference) : nil
        let resolved = EEGLocationOverride(sourceName: value.sourceName, matching: value.matching,
            channelNames: value.channelNames,
            geometry: ElectrodeGeometry(name: value.geometry.name, positions: value.geometry.positions,
                                         channelNames: value.geometry.channelNames, reference: reference),
            layoutOverride: value.layoutOverride)
        try recording.applyLocationOverride(resolved)
        electrodeGeometry = recording.electrodeGeometry

        // Interpolation is a spatial operator. Existing repairs must be
        // re-solved, not left cached against the previous cap's geometry.
        let targets = channels.interpolated.keys.sorted()
        if !targets.isEmpty, let signal = continuousProcessedSignal ?? recording.signal {
            channels.bad.formUnion(targets)
            channels.removeAllInterpolations()
            recordingStore.interpolatedSignalResolver.reset()
            var failed = false
            for target in targets {
                let result = interpolate(target, in: signal, updatesStatus: false, recordsLossOnFailure: true)
                failed = failed || result.isError
            }
            if failed { invalidateEpochsForSignalChange() }
        }
        resetChannelHealthForStateChange()
        publishChannelSetContext()
        channels.showsHealth = true
        channels.healthRefreshToken += 1
    }
}
