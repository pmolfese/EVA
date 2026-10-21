import SwiftUI

struct PSAWaveformReviewRequest: Equatable {
    var id = UUID()
    var segmentID: String
    var channelIndex: Int?
}

/// Both inspectors edit the same model. No copied decision state and no scan
/// or waveform materialization is needed when the operator changes a choice.
struct PSAWaveformDecisionControls: View {
    @Bindable var model: PSADecisionMatrixModel
    let epochIndex: Int
    let channelIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Decision Matrix · Epoch \(epochIndex + 1)")
                .font(.caption.weight(.semibold))
            Picker("Epoch", selection: Binding(
                get: { model.epochOverrides[epochIndex] ?? .automatic },
                set: { model.setEpochDecision($0, epoch: epochIndex) }
            )) {
                ForEach(PSAEpochDecision.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if let channelIndex {
                let cell = PSADecisionCellID(channelIndex: channelIndex, epochIndex: epochIndex)
                Picker("\(channelName(channelIndex)) in this epoch", selection: Binding(
                    get: { model.cellOverrides[cell] ?? .automatic },
                    set: { model.setCellDecision($0, for: cell) }
                )) {
                    ForEach(PSACellDecision.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Text("Interpolation applies to this channel in this epoch when averaging.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(model.resolvedEpochDecision(epochIndex) == .reject ? "Excluded from average" : "Kept for average")
                .font(.caption)
                .foregroundStyle(model.resolvedEpochDecision(epochIndex) == .reject ? Color.red : .secondary)
        }
        .font(.caption)
        .padding(12)
        .frame(width: 340)
        .onAppear {
            if let channelIndex {
                model.selectCell(.init(channelIndex: channelIndex, epochIndex: epochIndex))
            }
        }
    }

    private func channelName(_ index: Int) -> String {
        let names = model.preparation.signal.channelNames
        return names?.indices.contains(index) == true ? names?[index] ?? "Ch \(index + 1)" : "Ch \(index + 1)"
    }
}
