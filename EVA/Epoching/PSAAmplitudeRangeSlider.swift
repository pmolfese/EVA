// Dual-thumb amplitude bounds for the Decision Matrix's automatic suggestions.
// Developed by P. Molfese, National Institutes of Health (NIH).
// U.S. Government work (17 U.S.C. § 105).

import SwiftUI

struct PSAAmplitudeRangeSlider: View {
    @Binding var range: ClosedRange<Double>
    var bounds: ClosedRange<Double>
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedThumb: Thumb?
    @Namespace private var sliderSpace

    private enum Thumb: Hashable { case minimum, maximum }
    private let knobRadius: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.width - knobRadius * 2, 1)
            let lowerX = position(range.lowerBound, travel: travel)
            let upperX = position(range.upperBound, travel: travel)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: travel, height: 4)
                    .offset(x: knobRadius)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(upperX - lowerX, 0), height: 4)
                    .offset(x: lowerX)
                thumb(.minimum, travel: travel)
                    .position(x: lowerX, y: 12)
                thumb(.maximum, travel: travel)
                    .position(x: upperX, y: 12)
            }
            .frame(height: 24)
            .coordinateSpace(name: sliderSpace)
        }
        .frame(height: 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Amplitude cutoffs")
    }

    private func position(_ value: Double, travel: CGFloat) -> CGFloat {
        let fraction = (value - bounds.lowerBound) / max(bounds.upperBound - bounds.lowerBound, 1)
        return knobRadius + travel * min(max(fraction, 0), 1)
    }

    private func value(_ thumb: Thumb) -> Double {
        thumb == .minimum ? range.lowerBound : range.upperBound
    }

    private func move(_ thumb: Thumb, to proposed: Double) {
        guard proposed.isFinite else { return }
        let clamped = min(bounds.upperBound, max(bounds.lowerBound, proposed))
        if thumb == .minimum {
            range = min(clamped, range.upperBound)...range.upperBound
        } else {
            range = range.lowerBound...max(clamped, range.lowerBound)
        }
    }

    private func thumb(_ thumb: Thumb, travel: CGFloat) -> some View {
        Circle()
            .fill(colorScheme == .dark ? Color(white: 0.82) : Color(nsColor: .controlBackgroundColor))
            .overlay {
                Circle().strokeBorder(focusedThumb == thumb ? Color.accentColor : Color.secondary.opacity(0.4),
                                      lineWidth: focusedThumb == thumb ? 2 : 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
            .frame(width: knobRadius * 2, height: knobRadius * 2)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .focusable()
            .focused($focusedThumb, equals: thumb)
            .onMoveCommand { direction in
                switch direction {
                case .left, .down: move(thumb, to: value(thumb) - 1)
                case .right, .up: move(thumb, to: value(thumb) + 1)
                default: break
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(sliderSpace))
                    .onChanged { gesture in
                        focusedThumb = thumb
                        let fraction = (gesture.location.x - knobRadius) / travel
                        let proposed = bounds.lowerBound + fraction * (bounds.upperBound - bounds.lowerBound)
                        move(thumb, to: proposed.rounded())
                    }
            )
            .accessibilityLabel(thumb == .minimum ? "Minimum amplitude" : "Maximum amplitude")
            .accessibilityValue("\(value(thumb).formatted(.number.precision(.fractionLength(0...1)))) microvolts")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: move(thumb, to: value(thumb) + 1)
                case .decrement: move(thumb, to: value(thumb) - 1)
                @unknown default: break
                }
            }
            .zIndex(focusedThumb == thumb ? 1 : 0)
    }
}
