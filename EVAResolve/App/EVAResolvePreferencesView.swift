//
//  EVAResolvePreferencesView.swift
//  EVA Resolve
//

import SwiftUI

/// Resolve-wide display choices. These affect visualization only; the selected
/// silhouette never changes the spherical head model or inverse-fit math.
struct EVAResolvePreferencesView: View {
    @AppStorage(HeadModelSex.preferenceKey) private var headModelSexRaw = HeadModelSex.female.rawValue

    private var headModelSex: Binding<HeadModelSex> {
        Binding(
            get: { HeadModelSex(rawValue: headModelSexRaw) ?? .female },
            set: { headModelSexRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Picker("Head model sex", selection: headModelSex) {
                ForEach(HeadModelSex.allCases) { sex in
                    Text(sex.title).tag(sex)
                }
            }
            .pickerStyle(.segmented)

            Text("This changes only the anatomical outline used to orient source-analysis views. It does not change the head model, electrodes, or fitted dipoles.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }
}
