//
//  WaveformAxisViews.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Real tick marks + labels for exported butterfly-style figures. The live
//  in-app plots get away without them because the toolbar Scale slider and
//  latency scrubber supply that context on screen; an exported PNG/PDF has
//  neither, so a "publication" figure needs the axes drawn into the image
//  itself. `WaveformVoltageAxisOverlay` draws INSIDE the plot's own bounds
//  (no reserved margin) so it doesn't shift the x-mapping joint-marker guide
//  lines/boxes depend on; `WaveformTimeAxisView` is meant to be appended
//  BELOW a plot (adds height, doesn't compress it) for the same reason.
//

import SwiftUI

/// µV tick labels along the left edge of a butterfly-style plot, matching
/// `OverlayButterflyPlot`'s own baseline-centered y-mapping
/// (`WaveformScaleUnits.traceRowFraction`) exactly, so the numbers line up
/// with what's actually drawn.
struct WaveformVoltageAxisOverlay: View {
    let amplitudeScale: Double

    var body: some View {
        GeometryReader { proxy in
            let midY = proxy.size.height / 2
            let pointsPerMicrovolt = (proxy.size.height * WaveformScaleUnits.traceRowFraction) / max(amplitudeScale, 1)

            ZStack(alignment: .topLeading) {
                ForEach(Self.voltageTicks(amplitudeScale: amplitudeScale), id: \.self) { microvolts in
                    let y = midY - CGFloat(microvolts) * pointsPerMicrovolt
                    if y >= 6, y <= proxy.size.height - 6 {
                        Text(Self.formatMicrovolts(microvolts))
                            .font(.system(size: 8, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                            .position(x: 16, y: y)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static func formatMicrovolts(_ value: Double) -> String {
        let rounded = value.rounded()
        if rounded == 0 { return "0" }
        return rounded > 0 ? "+\(Int(rounded))" : "\(Int(rounded))"
    }

    /// 0 plus symmetric ± ticks at a "nice" round step (1/2/5 × a power of
    /// ten) chosen so roughly 3-5 ticks fit within `amplitudeScale`.
    private static func voltageTicks(amplitudeScale: Double) -> [Double] {
        guard amplitudeScale > 0 else { return [0] }
        let step = niceStep(for: amplitudeScale / 2)
        var values: [Double] = [0]
        var v = step
        while v <= amplitudeScale * 1.02 {
            values.append(v)
            values.append(-v)
            v += step
        }
        return values
    }

    fileprivate static func niceStep(for target: Double) -> Double {
        guard target > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(target)))
        let normalized = target / magnitude
        let nice: Double = normalized < 1.5 ? 1 : (normalized < 3.5 ? 2 : (normalized < 7.5 ? 5 : 10))
        return nice * magnitude
    }
}

/// Horizontal ms/s tick row for a butterfly-style plot's time axis. Meant to
/// be appended below the plot (own fixed height, e.g. `.frame(height: 20)`),
/// not overlaid — appending keeps the plot's own baseline centering intact.
struct WaveformTimeAxisView: View {
    let segment: EpochSegment
    let samplingRate: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let epochLength = max(segment.endSample - segment.startSample + 1, 1)
            let durationSeconds = samplingRate > 0 ? Double(epochLength - 1) / samplingRate : 0
            let startSeconds = samplingRate > 0 ? -Double(segment.stimulusOffsetSamples) / samplingRate : 0

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: width, height: 1)

                ForEach(Self.timeTicks(durationSeconds: durationSeconds, startSeconds: startSeconds), id: \.self) { seconds in
                    let fraction = durationSeconds > 0 ? (seconds - startSeconds) / durationSeconds : 0
                    let x = CGFloat(fraction) * width
                    if x >= 0, x <= width {
                        VStack(spacing: 1) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.5))
                                .frame(width: 1, height: 4)
                            Text(Self.formatSeconds(seconds))
                                .font(.system(size: 8, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        .position(x: min(max(x, 14), width - 14), y: 11)
                    }
                }
            }
        }
    }

    private static func timeTicks(durationSeconds: Double, startSeconds: Double) -> [Double] {
        guard durationSeconds > 0 else { return [0] }
        let step = WaveformVoltageAxisOverlay.niceStep(for: durationSeconds / 6)
        let endSeconds = startSeconds + durationSeconds
        var ticks: [Double] = []
        var t = (startSeconds / step).rounded(.up) * step
        while t <= endSeconds + step * 0.001 {
            ticks.append((t * 1000).rounded() / 1000)
            t += step
        }
        return ticks
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        if abs(seconds) < 1 {
            return "\(Int((seconds * 1000).rounded()))ms"
        }
        return String(format: "%.2gs", seconds)
    }
}
