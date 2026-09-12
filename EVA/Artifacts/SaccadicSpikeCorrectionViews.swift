//
//  SaccadicSpikeCorrectionViews.swift
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

extension WaveformView {
    func openSaccadicSpikeSheet(for signal: MFFSignalData) {
        saccadicSpike.result = nil
        saccadicSpike.statusMessage = nil
        do {
            let selection = try SaccadicSpikeChannelResolver.automatic(
                signal: signal,
                layout: recording.sensorLayout,
                excluding: channels.bad.union(channels.interpolated.keys)
            )
            saccadicSpike.czChannels = String(selection.czIndex + 1)
            saccadicSpike.verticalEOGChannels = channelList(selection.verticalEOGIndices)
            saccadicSpike.lowerVerticalEOGChannels = channelList(selection.lowerVerticalEOGIndices)
            saccadicSpike.horizontalEOGChannels = channelList(selection.horizontalEOGIndices)
        } catch {
            saccadicSpike.statusMessage = error.localizedDescription
        }
        saccadicSpike.showsSheet = true
    }

    func saccadicSpikeSheet(for signal: MFFSignalData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Saccadic Spike Potential")
                        .font(.title3.weight(.semibold))
                    HelpButton(topic: SaccadicSpikeHelpTopics.overview)
                    Spacer()
                    Text("MAAC-1")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("Detect the ~10 ms biphasic saccade-locked transient in the Cz-referenced derivative, then remove only its canonical scalp pattern with a spatial filter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Detection") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker(selection: $saccadicSpike.configuration.templateSource) {
                                ForEach(SaccadicSpikeTemplateSource.allCases) { source in
                                    Text(source.rawValue).tag(source)
                                }
                            } label: {
                                RowLabel(title: "Template", help: SaccadicSpikeHelpTopics.template)
                            }
                            Text(saccadicSpike.configuration.templateSource == .canonical
                                 ? "Uses the 33-channel file template shipped with the EP Toolkit and maps it to this recording's electrode positions."
                                 : "Averages preliminary VEOG-dominant spikes in this recording. The paper reports the file template as more reliable.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack {
                                Text("Threshold")
                                    .font(.caption)
                                    .frame(width: 92, alignment: .leading)
                                HelpButton(topic: SaccadicSpikeHelpTopics.threshold)
                                Slider(value: $saccadicSpike.configuration.sensitivitySigma, in: 3...10, step: 0.25)
                                Text(String(format: "%.2f σ", saccadicSpike.configuration.sensitivitySigma))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 58, alignment: .trailing)
                            }
                            Text("Larger values are more conservative. The threshold uses each recording's robust derivative noise scale rather than assuming an amplifier-specific fixed µV value.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 9) {
                            channelRoleRow("Cz", text: $saccadicSpike.czChannels, placeholder: "129")
                            channelRoleRow("VEOG", text: $saccadicSpike.verticalEOGChannels, placeholder: "8, 25, 126, 127")
                            channelRoleRow("Lower VEOG", text: $saccadicSpike.lowerVerticalEOGChannels, placeholder: "126, 127")
                            channelRoleRow("HEOG", text: $saccadicSpike.horizontalEOGChannels, placeholder: "125, 128")
                            Text("Channels are one-based. HEOG is excluded from the spatial amplitude estimate; marked-bad and interpolated channels are excluded automatically.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 4)
                    } label: {
                        HStack(spacing: 4) {
                            Text("Channel roles")
                            HelpButton(topic: SaccadicSpikeHelpTopics.channelRoles)
                        }
                    }

                    if let result = saccadicSpike.result {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 10) {
                                    metric("Preliminary", "\(result.preliminaryCandidateCount)")
                                    metric("Confirmed", "\(result.events.count)")
                                    metric("Critical", String(format: "%.3g µV", result.criticalThresholdMicrovolts))
                                }
                                if let layout = recording.sensorLayout {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Template topography")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        TopomapView(
                                            layout: layout,
                                            values: result.topography.channelValues.map(Double.init),
                                            timeSeconds: 0,
                                            fixedScale: nil,
                                            showsHeader: false,
                                            colorBarPlacement: .bottom,
                                            minimumMapHeight: 180
                                        )
                                        .frame(height: 220)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            HStack(spacing: 4) {
                                Text("Quality control")
                                HelpButton(topic: SaccadicSpikeHelpTopics.qualityControl)
                            }
                        }
                    }

                    if let status = saccadicSpike.statusMessage {
                        Label(status, systemImage: saccadicSpike.result == nil ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(saccadicSpike.result == nil ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button("Restore Defaults") {
                    saccadicSpike.configuration = .default
                    openSaccadicSpikeSheet(for: signal)
                }
                .disabled(saccadicSpike.isDetecting)

                Spacer()

                Button("Close") {
                    saccadicSpike.showsSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button(saccadicSpike.result == nil ? "Detect" : "Detect Again") {
                    detectSaccadicSpikes(in: signal)
                }
                .disabled(saccadicSpike.isDetecting)

                Button("Use Detected SPs") {
                    useDetectedSaccadicSpikes(in: signal)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saccadicSpike.isDetecting || saccadicSpike.result?.events.isEmpty != false)
            }
            .padding(20)
        }
        .frame(width: 620, height: 720)
    }

    @ViewBuilder
    private func channelRoleRow(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .frame(width: 92, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private func channelList(_ indices: [Int]) -> String {
        indices.map { String($0 + 1) }.joined(separator: ", ")
    }

    private func currentSaccadicSpikeSelection(
        signal: MFFSignalData,
        excluding excluded: Set<Int>
    ) throws -> SaccadicSpikeChannelSelection {
        guard let cz = WaveformView.parseChannelList(
            saccadicSpike.czChannels,
            channelCount: signal.numberOfChannels
        ).first else { throw SaccadicSpikeError.missingCz }
        let vertical = WaveformView.parseChannelList(
            saccadicSpike.verticalEOGChannels,
            channelCount: signal.numberOfChannels
        )
        let lower = WaveformView.parseChannelList(
            saccadicSpike.lowerVerticalEOGChannels,
            channelCount: signal.numberOfChannels
        )
        let horizontal = WaveformView.parseChannelList(
            saccadicSpike.horizontalEOGChannels,
            channelCount: signal.numberOfChannels
        )
        let analysis = (0..<signal.numberOfChannels).filter {
            !excluded.contains($0) && !horizontal.contains($0)
        }
        return try SaccadicSpikeChannelSelection(
            czIndex: cz,
            verticalEOGIndices: vertical,
            lowerVerticalEOGIndices: lower,
            horizontalEOGIndices: horizontal,
            analysisIndices: analysis
        ).validated(channelCount: signal.numberOfChannels)
    }

    private func detectSaccadicSpikes(in signal: MFFSignalData) {
        let excluded = channels.bad.union(channels.interpolated.keys)
        let selection: SaccadicSpikeChannelSelection
        do {
            selection = try currentSaccadicSpikeSelection(signal: signal, excluding: excluded)
        } catch {
            saccadicSpike.result = nil
            saccadicSpike.statusMessage = error.localizedDescription
            return
        }

        let configuration = saccadicSpike.configuration
        let canonical: [Float]?
        do {
            canonical = configuration.templateSource == .canonical
                ? try SaccadicSpikeCanonicalTemplate.mappedValues(signal: signal, layout: recording.sensorLayout)
                : nil
        } catch {
            saccadicSpike.result = nil
            saccadicSpike.statusMessage = error.localizedDescription
            return
        }

        saccadicSpike.detectionTask?.cancel()
        saccadicSpike.isDetecting = true
        saccadicSpike.result = nil
        saccadicSpike.statusMessage = "Scanning the Cz-referenced derivative…"
        let sessionID = recordingSessionID
        saccadicSpike.detectionTask = Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    try SaccadicSpikeDetector.detect(
                        in: signal,
                        selection: selection,
                        configuration: configuration,
                        canonicalTopography: canonical
                    )
                }
            }.value
            guard !Task.isCancelled, sessionID == recordingSessionID else { return }
            switch outcome {
            case .success(let result):
                saccadicSpike.result = result
                saccadicSpike.statusMessage = result.events.isEmpty
                    ? "The preliminary scan found \(result.preliminaryCandidateCount) candidates, but none passed the 4/8 ms biphasic confirmation."
                    : "Confirmed \(result.events.count) saccadic spike potentials. Review the template map, then add them to Clean Artifacts."
            case .failure(let error):
                saccadicSpike.result = nil
                saccadicSpike.statusMessage = error.localizedDescription
            }
            saccadicSpike.isDetecting = false
            saccadicSpike.detectionTask = nil
        }
    }

    private func useDetectedSaccadicSpikes(in signal: MFFSignalData) {
        guard let result = saccadicSpike.result, !result.events.isEmpty else { return }
        let selectedChannels = result.topography.channelIndices
        let average = ArtifactTemplateDetector.templateAverage(
            signal: signal,
            events: result.events,
            selectedChannelIndices: selectedChannels,
            windowSizeSeconds: saccadicSpike.configuration.windowSeconds
        )
        let artifact = DefinedArtifact(
            id: saccadicSpike.definedArtifactID ?? UUID(),
            type: .saccadicSpike,
            name: "Saccadic Spike Potential",
            eventCode: SaccadicSpikeDetector.eventCode,
            events: result.events,
            selectedChannelIndices: selectedChannels,
            windowSizeSeconds: saccadicSpike.configuration.windowSeconds,
            average: average,
            topography: result.topography,
            cleaningMethod: .spikeTemplate,
            usesVariableEventDuration: false,
            saccadicSpikeConfiguration: saccadicSpike.configuration,
            appliedMethod: nil,
            cleanedAt: nil
        )

        if let index = template.definedArtifacts.firstIndex(where: { $0.id == artifact.id }) {
            template.definedArtifacts[index] = artifact
        } else {
            template.definedArtifacts.append(artifact)
            registerPSADefinedArtifactForRejection(artifact.id)
        }
        saccadicSpike.definedArtifactID = artifact.id
        artifactVM.events = definedArtifactEventList()
        selectedEventCodes = [artifact.eventCode]
        invalidateOBSVarianceCache(for: artifact.id)
        clearAppliedArtifactCleaning()
        artifactVM.cleaningStatusMessage = "Added \(artifact.eventCount) saccadic spike potentials."
        saccadicSpike.showsSheet = false
        artifactVM.showsCleaningSheet = true
    }
}
