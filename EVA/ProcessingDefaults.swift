//
//  ProcessingDefaults.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  App-wide, persisted defaults that seed each newly-opened recording's
//  per-run processing stores (L4 view-models). This is the "global-default"
//  half of the settings split from REFACTOR.md: the domain VMs hold per-run
//  state and read their initial values from this shared, UserDefaults-backed
//  store. Edited in the Preferences window (⌘,).
//

import SwiftUI

@MainActor
@Observable
final class ProcessingDefaults {
    static let shared = ProcessingDefaults()

    // MARK: Filter defaults
    var filterHighPassHz: Double { didSet { save() } }
    var filterLowPassHz: Double { didSet { save() } }
    var filterNotch60: Bool { didSet { save() } }
    var filterAverageReference: Bool { didSet { save() } }

    // MARK: ICA defaults
    var icaMethod: ICAMethod { didSet { save() } }
    var icaComponentCount: Int { didSet { save() } }

    // MARK: BCG defaults
    /// When on, a compatible built-in BCG proxy set is auto-selected on open.
    var bcgAutoSelectProxySet: Bool { didSet { save() } }
    var bcgDefaultMethodRaw: String { didSet { save() } }

    private static let key = "ProcessingDefaults.v1"

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? .defaults
        filterHighPassHz = stored.filterHighPassHz
        filterLowPassHz = stored.filterLowPassHz
        filterNotch60 = stored.filterNotch60
        filterAverageReference = stored.filterAverageReference
        icaMethod = ICAMethod(rawValue: stored.icaMethodRaw) ?? .picard
        icaComponentCount = stored.icaComponentCount
        bcgAutoSelectProxySet = stored.bcgAutoSelectProxySet
        bcgDefaultMethodRaw = stored.bcgDefaultMethodRaw
    }

    func restoreDefaults() {
        let d = Stored.defaults
        filterHighPassHz = d.filterHighPassHz
        filterLowPassHz = d.filterLowPassHz
        filterNotch60 = d.filterNotch60
        filterAverageReference = d.filterAverageReference
        icaMethod = ICAMethod(rawValue: d.icaMethodRaw) ?? .picard
        icaComponentCount = d.icaComponentCount
        bcgAutoSelectProxySet = d.bcgAutoSelectProxySet
        bcgDefaultMethodRaw = d.bcgDefaultMethodRaw
    }

    private func save() {
        let stored = Stored(
            filterHighPassHz: filterHighPassHz,
            filterLowPassHz: filterLowPassHz,
            filterNotch60: filterNotch60,
            filterAverageReference: filterAverageReference,
            icaMethodRaw: icaMethod.rawValue,
            icaComponentCount: icaComponentCount,
            bcgAutoSelectProxySet: bcgAutoSelectProxySet,
            bcgDefaultMethodRaw: bcgDefaultMethodRaw
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Forward/backward-compatible persisted shape (missing fields fall back).
    private struct Stored: Codable {
        var filterHighPassHz = 0.1
        var filterLowPassHz = 30.0
        var filterNotch60 = false
        var filterAverageReference = false
        var icaMethodRaw = ICAMethod.picard.rawValue
        var icaComponentCount = 20
        var bcgAutoSelectProxySet = false
        var bcgDefaultMethodRaw = "periodicity"

        static let defaults = Stored()

        init(filterHighPassHz: Double = 0.1, filterLowPassHz: Double = 30.0,
             filterNotch60: Bool = false, filterAverageReference: Bool = false,
             icaMethodRaw: String = ICAMethod.picard.rawValue, icaComponentCount: Int = 20,
             bcgAutoSelectProxySet: Bool = false, bcgDefaultMethodRaw: String = "periodicity") {
            self.filterHighPassHz = filterHighPassHz
            self.filterLowPassHz = filterLowPassHz
            self.filterNotch60 = filterNotch60
            self.filterAverageReference = filterAverageReference
            self.icaMethodRaw = icaMethodRaw
            self.icaComponentCount = icaComponentCount
            self.bcgAutoSelectProxySet = bcgAutoSelectProxySet
            self.bcgDefaultMethodRaw = bcgDefaultMethodRaw
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            filterHighPassHz = try c.decodeIfPresent(Double.self, forKey: .filterHighPassHz) ?? 0.1
            filterLowPassHz = try c.decodeIfPresent(Double.self, forKey: .filterLowPassHz) ?? 30.0
            filterNotch60 = try c.decodeIfPresent(Bool.self, forKey: .filterNotch60) ?? false
            filterAverageReference = try c.decodeIfPresent(Bool.self, forKey: .filterAverageReference) ?? false
            icaMethodRaw = try c.decodeIfPresent(String.self, forKey: .icaMethodRaw) ?? ICAMethod.picard.rawValue
            icaComponentCount = try c.decodeIfPresent(Int.self, forKey: .icaComponentCount) ?? 20
            bcgAutoSelectProxySet = try c.decodeIfPresent(Bool.self, forKey: .bcgAutoSelectProxySet) ?? false
            bcgDefaultMethodRaw = try c.decodeIfPresent(String.self, forKey: .bcgDefaultMethodRaw) ?? "periodicity"
        }
    }
}
