//
//  ProcessingDefaults.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  App-wide, persisted defaults that seed each newly-opened recording's
//  per-run processing stores (L4 view-models). This is the "global-default"
//  half of the settings split from REFACTOR.md: the domain VMs hold per-run
//  state and read their initial values from this shared, UserDefaults-backed
//  store. Edited in the Preferences window (⌘,).
//
//  Each setting is a computed property reading/writing its own UserDefaults
//  key directly (registered with a default via `register(defaults:)`), so
//  @Observable can track get/set the same as a stored property, unlike
//  @AppStorage (which only publishes changes when used directly on a View).
//

import SwiftUI

@MainActor
@Observable
final class ProcessingDefaults {
    static let shared = ProcessingDefaults()

    private enum Keys {
        static let filterHighPassHz = "filterHighPassHz"
        static let filterLowPassHz = "filterLowPassHz"
        static let filterNotch60 = "filterNotch60"
        static let filterAverageReference = "filterAverageReference"
        static let filterDefaultFamily = "filterDefaultFamily"
        static let icaMethod = "icaMethod"
        static let icaComponentCount = "icaComponentCount"
        static let bcgAutoSelectProxySet = "bcgAutoSelectProxySet"
        static let bcgDefaultMethodRaw = "bcgDefaultMethodRaw"
        static let artifactDetectionDefaultMethodRaw = "artifactDetectionDefaultMethodRaw"
        static let ocularBlinkThresholdConfig = "ocularBlinkThresholdConfig"
        static let ocularMovementThresholdConfig = "ocularMovementThresholdConfig"
        static let ocularTopologyDefaultMigrationV2 = "ocularTopologyDefaultMigrationV2"
        static let interpolatedHealthFromNeighbors = "interpolatedHealthFromNeighbors"
        static let autoRunSegmentHealthAfterSegmentation = "autoRunSegmentHealthAfterSegmentation"
    }

    private enum Defaults {
        static let filterHighPassHz = 0.1
        static let filterLowPassHz = 30.0
        static let filterNotch60 = false
        static let filterAverageReference = false
        static let filterDefaultFamily = FilterFamily.iir.rawValue
        static let icaMethod = ICAMethod.picard
        static let icaComponentCount = 20
        static let bcgAutoSelectProxySet = false
        static let bcgDefaultMethodRaw = "spatialPCA"
        static let artifactDetectionDefaultMethodRaw = ArtifactDetectionMethod.threshold.rawValue
        static let ocularBlinkThresholdConfig = EyeArtifactThresholdConfiguration.defaults(for: .blink)
        static let ocularMovementThresholdConfig = EyeArtifactThresholdConfiguration.defaults(for: .movement)
        static let interpolatedHealthFromNeighbors = true
        static let autoRunSegmentHealthAfterSegmentation = true
    }

    // MARK: Filter defaults
    var filterHighPassHz: Double {
        get { UserDefaults.standard.double(forKey: Keys.filterHighPassHz) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.filterHighPassHz) }
    }
    var filterLowPassHz: Double {
        get { UserDefaults.standard.double(forKey: Keys.filterLowPassHz) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.filterLowPassHz) }
    }
    var filterNotch60: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.filterNotch60) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.filterNotch60) }
    }
    var filterAverageReference: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.filterAverageReference) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.filterAverageReference) }
    }
    /// Default filter family for NEW filtering. Replay of existing eva.xml always
    /// defaults a missing `filterFamily` to IIR independent of this preference.
    var filterDefaultFamily: String {
        get { UserDefaults.standard.string(forKey: Keys.filterDefaultFamily) ?? Defaults.filterDefaultFamily }
        set { UserDefaults.standard.set(newValue, forKey: Keys.filterDefaultFamily) }
    }

    // MARK: ICA defaults
    var icaMethod: ICAMethod {
        get { UserDefaults.standard.string(forKey: Keys.icaMethod).flatMap(ICAMethod.init(rawValue:)) ?? .picard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.icaMethod) }
    }
    var icaComponentCount: Int {
        get { UserDefaults.standard.integer(forKey: Keys.icaComponentCount) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.icaComponentCount) }
    }

    // MARK: BCG defaults
    /// When on, a compatible built-in BCG proxy set is auto-selected on open.
    var bcgAutoSelectProxySet: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.bcgAutoSelectProxySet) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.bcgAutoSelectProxySet) }
    }
    var bcgDefaultMethodRaw: String {
        get { UserDefaults.standard.string(forKey: Keys.bcgDefaultMethodRaw) ?? Defaults.bcgDefaultMethodRaw }
        set { UserDefaults.standard.set(newValue, forKey: Keys.bcgDefaultMethodRaw) }
    }
    /// Typed convenience over `bcgDefaultMethodRaw`, for binding directly to a `Picker`.
    var bcgDefaultMethod: BCGDetectionMethod {
        get { BCGDetectionMethod(rawValue: bcgDefaultMethodRaw) ?? .spatialPCA }
        set { bcgDefaultMethodRaw = newValue.rawValue }
    }

    // MARK: Artifact-detection defaults
    var artifactDetectionDefaultMethodRaw: String {
        get { UserDefaults.standard.string(forKey: Keys.artifactDetectionDefaultMethodRaw) ?? Defaults.artifactDetectionDefaultMethodRaw }
        set { UserDefaults.standard.set(newValue, forKey: Keys.artifactDetectionDefaultMethodRaw) }
    }
    /// Typed convenience over `artifactDetectionDefaultMethodRaw`, for binding directly to a `Picker`.
    var artifactDetectionDefaultMethod: ArtifactDetectionMethod {
        get { ArtifactDetectionMethod(rawValue: artifactDetectionDefaultMethodRaw) ?? .threshold }
        set { artifactDetectionDefaultMethodRaw = newValue.rawValue }
    }

    var ocularBlinkThresholdConfig: EyeArtifactThresholdConfiguration {
        get {
            ocularThresholdConfig(
                forKey: Keys.ocularBlinkThresholdConfig,
                fallback: Defaults.ocularBlinkThresholdConfig
            )
        }
        set { setOcularThresholdConfig(newValue, forKey: Keys.ocularBlinkThresholdConfig) }
    }

    var ocularMovementThresholdConfig: EyeArtifactThresholdConfiguration {
        get {
            ocularThresholdConfig(
                forKey: Keys.ocularMovementThresholdConfig,
                fallback: Defaults.ocularMovementThresholdConfig
            )
        }
        set { setOcularThresholdConfig(newValue, forKey: Keys.ocularMovementThresholdConfig) }
    }

    // MARK: Channel-health defaults
    /// When on, an interpolated channel's health is estimated by averaging its
    /// spline-contributing channels rather than a full montage recompute — much
    /// cheaper on modest hardware.
    var interpolatedHealthFromNeighbors: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.interpolatedHealthFromNeighbors) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.interpolatedHealthFromNeighbors) }
    }

    // MARK: Segment-health defaults
    var autoRunSegmentHealthAfterSegmentation: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.autoRunSegmentHealthAfterSegmentation) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.autoRunSegmentHealthAfterSegmentation) }
    }

    /// Legacy single-blob key from before the per-key UserDefaults refactor.
    private static let legacyKey = "ProcessingDefaults.v1"

    init() {
        UserDefaults.standard.register(defaults: [
            Keys.filterHighPassHz: Defaults.filterHighPassHz,
            Keys.filterLowPassHz: Defaults.filterLowPassHz,
            Keys.filterNotch60: Defaults.filterNotch60,
            Keys.filterAverageReference: Defaults.filterAverageReference,
            Keys.icaMethod: Defaults.icaMethod.rawValue,
            Keys.icaComponentCount: Defaults.icaComponentCount,
            Keys.bcgAutoSelectProxySet: Defaults.bcgAutoSelectProxySet,
            Keys.bcgDefaultMethodRaw: Defaults.bcgDefaultMethodRaw,
            Keys.artifactDetectionDefaultMethodRaw: Defaults.artifactDetectionDefaultMethodRaw,
            Keys.ocularBlinkThresholdConfig: Self.encodedOcularThresholdConfig(Defaults.ocularBlinkThresholdConfig),
            Keys.ocularMovementThresholdConfig: Self.encodedOcularThresholdConfig(Defaults.ocularMovementThresholdConfig),
            Keys.interpolatedHealthFromNeighbors: Defaults.interpolatedHealthFromNeighbors,
            Keys.autoRunSegmentHealthAfterSegmentation: Defaults.autoRunSegmentHealthAfterSegmentation,
        ])
        migrateLegacyBlobIfNeeded()
        migrateOcularTopologyDefaultsIfNeeded()
    }

    /// One-time migration from the old single-JSON-blob store so existing
    /// users don't silently lose their saved preferences on upgrade.
    private func migrateLegacyBlobIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: Self.legacyKey),
              let legacy = try? JSONDecoder().decode(LegacyStored.self, from: data) else { return }
        filterHighPassHz = legacy.filterHighPassHz
        filterLowPassHz = legacy.filterLowPassHz
        filterNotch60 = legacy.filterNotch60
        filterAverageReference = legacy.filterAverageReference
        icaMethod = ICAMethod(rawValue: legacy.icaMethodRaw) ?? .picard
        icaComponentCount = legacy.icaComponentCount
        bcgAutoSelectProxySet = legacy.bcgAutoSelectProxySet
        bcgDefaultMethodRaw = legacy.bcgDefaultMethodRaw
        interpolatedHealthFromNeighbors = legacy.interpolatedHealthFromNeighbors
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
    }

    private func migrateOcularTopologyDefaultsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Keys.ocularTopologyDefaultMigrationV2) else { return }
        migrateOcularTopologyDefaultIfNeeded(forKey: Keys.ocularBlinkThresholdConfig, kind: .blink)
        migrateOcularTopologyDefaultIfNeeded(forKey: Keys.ocularMovementThresholdConfig, kind: .movement)
        UserDefaults.standard.set(true, forKey: Keys.ocularTopologyDefaultMigrationV2)
    }

    private func migrateOcularTopologyDefaultIfNeeded(forKey key: String, kind: EyeArtifactKind) {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode(EyeArtifactThresholdConfiguration.self, from: data) else {
            return
        }
        var previousDefault = EyeArtifactThresholdConfiguration.defaults(for: kind)
        previousDefault.topologyMode = .derivedOcular
        if stored == previousDefault {
            setOcularThresholdConfig(EyeArtifactThresholdConfiguration.defaults(for: kind), forKey: key)
        }
    }

    func restoreDefaults() {
        filterHighPassHz = Defaults.filterHighPassHz
        filterLowPassHz = Defaults.filterLowPassHz
        filterNotch60 = Defaults.filterNotch60
        filterAverageReference = Defaults.filterAverageReference
        icaMethod = Defaults.icaMethod
        icaComponentCount = Defaults.icaComponentCount
        bcgAutoSelectProxySet = Defaults.bcgAutoSelectProxySet
        bcgDefaultMethodRaw = Defaults.bcgDefaultMethodRaw
        artifactDetectionDefaultMethodRaw = Defaults.artifactDetectionDefaultMethodRaw
        ocularBlinkThresholdConfig = Defaults.ocularBlinkThresholdConfig
        ocularMovementThresholdConfig = Defaults.ocularMovementThresholdConfig
        interpolatedHealthFromNeighbors = Defaults.interpolatedHealthFromNeighbors
        autoRunSegmentHealthAfterSegmentation = Defaults.autoRunSegmentHealthAfterSegmentation
    }

    private func ocularThresholdConfig(
        forKey key: String,
        fallback: EyeArtifactThresholdConfiguration
    ) -> EyeArtifactThresholdConfiguration {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(EyeArtifactThresholdConfiguration.self, from: data) else {
            return fallback
        }
        return config
    }

    private func setOcularThresholdConfig(_ config: EyeArtifactThresholdConfiguration, forKey key: String) {
        UserDefaults.standard.set(Self.encodedOcularThresholdConfig(config), forKey: key)
    }

    private static func encodedOcularThresholdConfig(_ config: EyeArtifactThresholdConfiguration) -> Data {
        (try? JSONEncoder().encode(config)) ?? Data()
    }

    /// Shape of the pre-refactor persisted blob, kept only for migration.
    private struct LegacyStored: Codable {
        var filterHighPassHz = 0.1
        var filterLowPassHz = 30.0
        var filterNotch60 = false
        var filterAverageReference = false
        var icaMethodRaw = ICAMethod.picard.rawValue
        var icaComponentCount = 20
        var bcgAutoSelectProxySet = false
        var bcgDefaultMethodRaw = "periodicity"
        var interpolatedHealthFromNeighbors = true

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
            interpolatedHealthFromNeighbors = try c.decodeIfPresent(Bool.self, forKey: .interpolatedHealthFromNeighbors) ?? true
        }
    }
}
