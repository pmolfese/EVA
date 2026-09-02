//
//  SourceTimelineView.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  SIM-3 Stage 3a — the activation timeline. A multi-track editor (one row per
//  dipole) where each activation is a block: drag it to move, drag its right edge
//  to resize, click to select and edit in the inspector. The playhead scrubs the
//  live field; Play watches the whole scene evolve. This replaces the single
//  per-source time course with any number of timed firings per dipole.
//

import SwiftUI

struct SourceTimelineView: View {
    @Bindable var controller: SourceSimulatorController
    let open: (URL) -> Void

    private let labelWidth: CGFloat = 104
    private let rowHeight: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            transport

            VStack(spacing: 3) {
                ForEach(controller.sources) { source in
                    TimelineRow(controller: controller, sourceID: source.id,
                                labelWidth: labelWidth, rowHeight: rowHeight)
                        .frame(height: rowHeight)
                }
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: labelWidth)
                Text("0 s").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f s", controller.durationSeconds))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var transport: some View {
        @Bindable var controller = controller
        return HStack(spacing: 10) {
            Button { controller.isPlaying.toggle() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
            }
            .help(controller.isPlaying ? "Pause" : "Play")

            Text(String(format: "%.2f / %.2f s", controller.currentTime, controller.durationSeconds))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)

            Button { controller.addActivation() } label: {
                Label("Activation", systemImage: "plus.rectangle")
            }
            .help("Add an activation to the selected dipole at the playhead")
            .disabled(controller.selectedID == nil)

            Button { controller.removeSelectedActivation() } label: {
                Image(systemName: "minus.rectangle")
            }
            .help("Remove the selected activation")
            .disabled(controller.selectedActivationID == nil)

            Spacer()

            if controller.isGeneratingRecording {
                ProgressView().controlSize(.small)
            }
            Button { controller.generateRecording(open: open) } label: {
                Label("Generate scalp EEG", systemImage: "square.and.arrow.down")
            }
            .disabled(controller.isGeneratingRecording)
        }
    }
}

/// One dipole's track: its label plus a Canvas of activation blocks with a
/// combined move / resize / scrub drag gesture.
private struct TimelineRow: View {
    @Bindable var controller: SourceSimulatorController
    let sourceID: SourceSimulatorController.Source.ID
    let labelWidth: CGFloat
    let rowHeight: CGFloat

    private enum Mode { case none, move, resize, scrub }
    @State private var mode: Mode = .none
    @State private var dragActivationID: SourceSimulatorController.Activation.ID?
    @State private var grabOffsetSeconds: Double = 0

    private let edgeGrab: CGFloat = 7

    private var sourceIndex: Int? { controller.sources.firstIndex { $0.id == sourceID } }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                controller.selectedID = sourceID
            } label: {
                Text(controller.sources.first { $0.id == sourceID }?.name ?? "")
                    .font(.caption).lineLimit(1).truncationMode(.tail)
                    .frame(width: labelWidth, alignment: .leading)
                    .foregroundStyle(sourceID == controller.selectedID ? Color.accentColor : .primary)
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                let scale = geo.size.width / max(controller.durationSeconds, 0.001)
                Canvas { context, size in draw(&context, size: size, scale: scale) }
                    .contentShape(Rectangle())
                    .gesture(drag(scale: scale))
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, scale: CGFloat) {
        // Second gridlines.
        var grid = Path()
        var s = 0.0
        while s <= controller.durationSeconds {
            let x = CGFloat(s) * scale
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            s += 1
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)

        guard let index = sourceIndex else { return }
        for activation in controller.sources[index].activations {
            let x = CGFloat(activation.startSeconds) * scale
            let w = max(2, CGFloat(activation.lengthSeconds) * scale)
            let rect = CGRect(x: x, y: 3, width: w, height: size.height - 6)
            let selected = activation.id == controller.selectedActivationID
            let color = Self.color(for: activation.waveform)
            context.fill(RoundedRectangle(cornerRadius: 4).path(in: rect),
                         with: .color(color.opacity(selected ? 0.9 : 0.55)))
            context.stroke(RoundedRectangle(cornerRadius: 4).path(in: rect),
                           with: .color(selected ? .accentColor : color), lineWidth: selected ? 1.6 : 0.8)
            if w > 26 {
                context.draw(
                    Text(activation.waveform.label).font(.system(size: 9)).foregroundColor(.white),
                    at: CGPoint(x: rect.minX + 4 + min(rect.width, 60) / 2, y: rect.midY)
                )
            }
        }

        // Playhead.
        let px = CGFloat(controller.currentTime) * scale
        var playhead = Path()
        playhead.move(to: CGPoint(x: px, y: 0)); playhead.addLine(to: CGPoint(x: px, y: size.height))
        context.stroke(playhead, with: .color(.red.opacity(0.8)), lineWidth: 1)
    }

    private func drag(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let index = sourceIndex else { return }
                controller.selectedID = sourceID
                let seconds = Double(value.location.x / scale)

                if mode == .none {
                    (mode, dragActivationID, grabOffsetSeconds) = classify(startX: value.startLocation.x, scale: scale, sourceIndex: index)
                }

                switch mode {
                case .scrub, .none:
                    controller.currentTime = min(max(seconds, 0), controller.durationSeconds)
                case .move:
                    guard let id = dragActivationID,
                          let a = controller.sources[index].activations.firstIndex(where: { $0.id == id }) else { return }
                    let length = controller.sources[index].activations[a].lengthSeconds
                    let newStart = min(max(seconds - grabOffsetSeconds, 0), max(0, controller.durationSeconds - length))
                    controller.sources[index].activations[a].startSeconds = newStart
                    controller.selectedActivationID = id
                case .resize:
                    guard let id = dragActivationID,
                          let a = controller.sources[index].activations.firstIndex(where: { $0.id == id }) else { return }
                    let start = controller.sources[index].activations[a].startSeconds
                    let newLength = min(max(seconds - start, 0.02), controller.durationSeconds - start)
                    controller.sources[index].activations[a].lengthSeconds = newLength
                    controller.selectedActivationID = id
                }
            }
            .onEnded { _ in mode = .none; dragActivationID = nil }
    }

    /// Decides whether a press begins a move, a resize, or a scrub.
    private func classify(startX: CGFloat, scale: CGFloat, sourceIndex index: Int) -> (Mode, SourceSimulatorController.Activation.ID?, Double) {
        for activation in controller.sources[index].activations {
            let x0 = CGFloat(activation.startSeconds) * scale
            let x1 = CGFloat(activation.startSeconds + activation.lengthSeconds) * scale
            if abs(startX - x1) <= edgeGrab {
                return (.resize, activation.id, 0)
            }
            if startX >= x0 && startX <= x1 {
                let grab = Double(startX / scale) - activation.startSeconds
                return (.move, activation.id, grab)
            }
        }
        return (.scrub, nil, 0)
    }

    private static func color(for waveform: SourceSimulatorController.Waveform) -> Color {
        switch waveform {
        case .hold: return .blue
        case .sine: return .teal
        case .erp: return .orange
        case .noise: return .purple
        }
    }
}
