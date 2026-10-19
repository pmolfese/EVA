//
//  PSAConfigurationComponents.swift
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

struct PSACategoryTableRow: Identifiable {
    enum Kind {
        case event(EventSummary)
        case group(String)
        case regex(String)
    }

    let id: String
    let kind: Kind
    let count: Int
}

/// Disclosure state belongs to the sheet, not the portable processing settings.
struct PSAInspectorSection<Content: View>: View {
    let title: String
    @State private var isExpanded: Bool
    private let content: Content

    init(_ title: String, initiallyExpanded: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        _isExpanded = State(initialValue: initiallyExpanded)
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title).font(.headline)
        }
    }
}

struct PSAEpochWindowPreview: View {
    let preStimulus: Double
    let postStimulus: Double
    let baselineCorrected: Bool

    private var preFraction: Double {
        let duration = preStimulus + postStimulus
        guard preStimulus.isFinite, postStimulus.isFinite, duration.isFinite,
              preStimulus >= 0, postStimulus > 0 else { return 0 }
        return preStimulus / duration
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.10))
                    if baselineCorrected {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.25))
                            .frame(width: geometry.size.width * preFraction)
                            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4))
                    }
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 1, height: 38)
                        .offset(x: geometry.size.width * preFraction)
                }
            }
            .frame(height: 28)
            HStack {
                Text((-preStimulus).formatted(.number.precision(.fractionLength(3))) + " s")
                Spacer()
                Text(postStimulus.formatted(.number.precision(.fractionLength(3))) + " s")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            Text(baselineCorrected ? "Onset at 0 s · Pre-stimulus baseline" : "Onset at 0 s")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Epoch window")
        .accessibilityValue("\(-preStimulus) to \(postStimulus) seconds relative to onset. Baseline correction \(baselineCorrected ? "on" : "off").")
    }
}
