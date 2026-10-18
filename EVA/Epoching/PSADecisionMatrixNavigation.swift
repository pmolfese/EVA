import SwiftUI

extension WaveformView {
    func openWaveformDecisionInspector(at sample: Int, channel: Int?) {
        guard !epoching.isAveraged, let model = epoching.decisionMatrix,
              let epoch = epoching.epochSegments.firstIndex(where: {
                  sample >= $0.startSample && sample <= $0.endSample
              }), model.preparation.segments.indices.contains(epoch) else { return }
        let segmentID = SegmentHealthAnalyzer.segmentID(index: epoch, segment: epoching.epochSegments[epoch])
        // Reuse the published health analysis. A request also works when the
        // band mounts after the operator has hidden the health overlay.
        segHealth.shows = true
        recordingStore.selection.matrixReviewRequest = .init(segmentID: segmentID, channelIndex: channel)
    }

    func waveformDecisionControls(for result: SegmentHealthResult) -> ((Int?) -> AnyView)? {
        guard !epoching.isAveraged, let model = epoching.decisionMatrix,
              model.preparation.segments.indices.contains(result.segmentIndex),
              SegmentHealthAnalyzer.segmentID(
                  index: result.segmentIndex,
                  segment: model.preparation.segments[result.segmentIndex]
              ) == result.segmentID else { return nil }
        return { channel in
            AnyView(PSAWaveformDecisionControls(model: model, epochIndex: result.segmentIndex, channelIndex: channel))
        }
    }

    /// Returning from an average uses the retained, complete source epoch set.
    /// Navigation and hiding the panel never materialize interpolation.
    func showDecisionMatrixSourceEpochs() {
        guard epoching.isAveraged, let source = segmentedEpochSignal else { return }
        epoching.isAveraged = false
        epoching.epochedSignal = source
        epoching.epochSegments = segmentedEpochSegments
        epoching.showsButterflyPlot = false
        epoching.showsOverlaidCategories = false
        selectedSampleRange = nil
        topomapSample = nil
        refreshEpochDisplay()
    }

    func navigateDecisionMatrix(channel: Int?, epoch: Int?) {
        guard !epoching.isAveraged, let signal = epoching.epochedSignal else { return }
        if let channel, signal.data.indices.contains(channel) {
            if !channelIndices(in: signal).contains(channel) {
                recordingStore.displayedChannelSetID = nil
            }
            channels.hidden.remove(channel)
            scrollToChannelRequest = channel
        }
        guard let epoch, epoching.epochSegments.indices.contains(epoch) else { return }
        let segment = epoching.epochSegments[epoch]
        selectedSampleRange = segment.startSample...segment.endSample
        dragSelectionStartSample = nil
        dragSelectionEndSample = nil
        selectedEventID = nil
        let center = (contentX(forSample: segment.startSample, in: signal)
            + contentX(forSample: segment.endSample + 1, in: signal)) / 2
        let maxOffset = max(plotWidth(for: signal) - horizontalViewportWidth, 0)
        let offset = min(max(center - horizontalViewportWidth / 2, 0), maxOffset)
        isSyncingSliderFromScroll = true
        horizontalJumpValue = maxOffset > 0 ? Double(offset / maxOffset) : 0
        isSyncingSliderFromScroll = false
        horizontalScrollPosition.scrollTo(x: offset)
    }

    func selectDecisionMatrixCell(at sample: Int, channel: Int?) {
        guard !epoching.isAveraged, let model = epoching.decisionMatrix,
              let channel,
              let epoch = epoching.epochSegments.firstIndex(where: {
                  sample >= $0.startSample && sample <= $0.endSample
              }),
              model.preparation.segments.indices.contains(epoch) else { return }
        model.selectCell(.init(channelIndex: channel, epochIndex: epoch))
    }

    @ViewBuilder
    func decisionMatrixFocusOverlay(for signal: MFFSignalData) -> some View {
        if !epoching.isAveraged,
           (!segHealth.shows || segHealth.analysis == nil),
           let model = epoching.decisionMatrix {
            // The exclusion cue remains visible even with the optional health
            // overlay switched off. One canvas avoids adding a view per trial.
            Canvas { context, size in
                var rejected = Path()
                for (index, segment) in epoching.epochSegments.enumerated()
                where model.resolvedEpochDecision(index) == .reject {
                    let lower = contentX(forSample: segment.startSample, in: signal)
                    let upper = contentX(forSample: segment.endSample + 1, in: signal)
                    rejected.addRect(CGRect(x: lower, y: 0, width: max(upper - lower, 2), height: size.height))
                }
                context.fill(rejected, with: .color(.red.opacity(0.18)))
            }
            .allowsHitTesting(false)
        }
        if !epoching.isAveraged,
           let cell = epoching.decisionMatrix?.selectedCell,
           epoching.epochSegments.indices.contains(cell.epochIndex),
           let row = channelIndices(in: signal).firstIndex(of: cell.channelIndex) {
            let segment = epoching.epochSegments[cell.epochIndex]
            let startX = contentX(forSample: segment.startSample, in: signal)
            let endX = contentX(forSample: segment.endSample + 1, in: signal)
            Rectangle()
                .fill(Color.accentColor.opacity(0.08))
                .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 2))
                .frame(width: max(endX - startX, 2), height: channelRowHeight)
                .offset(x: startX, y: CGFloat(row) * (channelRowHeight + rowSpacing))
                .allowsHitTesting(false)
        }
    }
}
