//
//  StandardMontage.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Template electrode positions for recordings that ship no digitization: the
//  idealized 10-20 / 10-10 / 10-05 systems on a sphere (see
//  `StandardMontageData`), scaled to a nominal head radius and returned as
//  `ElectrodePositions` with nasion / LPA / RPA so they coregister like any
//  digitized set. EGI HydroCel nets are deliberately not bundled: every MFF
//  carries its own `coordinates.xml`, which is the better source.
//

import Foundation
import simd

nonisolated enum StandardMontage: String, CaseIterable, Sendable, Identifiable {
    case tenTwenty = "10-20"
    case tenTen = "10-10"
    case tenFive = "10-05"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tenTwenty: return "10-20 (idealized sphere)"
        case .tenTen: return "10-10 (idealized sphere)"
        case .tenFive: return "10-05 (idealized sphere)"
        }
    }

    /// Nominal adult head radius used to scale the unit sphere, metres.
    static let nominalRadiusMeters = 0.095

    private static let allPoints: [(label: String, position: SIMD3<Double>)] = {
        StandardMontageData.spherical1005.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ")
            guard f.count == 4, let x = Double(f[1]), let y = Double(f[2]), let z = Double(f[3]) else { return nil }
            return (String(f[0]), SIMD3(x, y, z))
        }
    }()

    func positions(radiusMeters: Double = StandardMontage.nominalRadiusMeters) -> ElectrodePositions {
        let wanted: Set<String>?
        switch self {
        case .tenTwenty: wanted = Set(StandardMontageData.labels1020)
        case .tenTen: wanted = Set(StandardMontageData.labels1010)
        case .tenFive: wanted = nil
        }
        var points: [ElectrodePositions.Point] = []
        var eegIndex = 0
        for (label, unit) in StandardMontage.allPoints {
            // Only the three fiducial rows are fiducials here: the 10-05 system also
            // has an *electrode* named Nz, which the generic aliases would swallow.
            let kind: ElectrodePositions.Kind? = ["NAS": .nasion, "LPA": .lpa, "RPA": .rpa][label]
            if kind == nil, let wanted, !wanted.contains(label) { continue }
            let p = unit * radiusMeters
            if let kind {
                points.append(.init(name: label, kind: kind, position: p, channelIndex: nil))
            } else {
                points.append(.init(name: label, kind: .eeg, position: p, channelIndex: eegIndex))
                eegIndex += 1
            }
        }
        return ElectrodePositions(name: displayName, points: points, frame: .head)
    }
}
