//
//  WaveletModels.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//

import Foundation

nonisolated enum WaveletCleaningPipeline: String, CaseIterable, Identifiable, Sendable {
    case eeg = "EEG"
    case erp = "ERP"

    var id: String { rawValue }

    var defaultFamily: WaveletReductionFamily {
        switch self {
        case .eeg: return .bior44
        case .erp: return .coif4
        }
    }

    var defaultThresholdRule: WaveletCleaningThresholdRule {
        switch self {
        case .eeg: return .hard
        case .erp: return .soft
        }
    }

    /// Robust universal (MAD σ · sqrt(2 ln N)). This seeds the Explorer's
    /// *detection*, not the Reducer's subtraction, and a fixed rule is what its
    /// current behaviour is tuned around — the Reducer defaults to
    /// `.empiricalBayes` for compatibility with MATLAB `wdenoise`'s public
    /// Bayes-denoising semantics.
    ///
    /// Never `.bayesShrink`, whose T = σ_n²/σ_s collapses on artifact-inflated
    /// EEG bands and flags nearly everything — see `WaveletReducer`'s header.
    var defaultThresholdModel: WaveletCleaningThresholdModel {
        .robustUniversal
    }

    /// 1.0 = the textbook threshold for the chosen model. The scale is a gate
    /// multiplier: raising it flags/removes less, lowering it flags/removes
    /// more. (The ERP path's gentleness comes from soft thresholding, not
    /// from a lowered gate — an earlier 0.85 here removed *more*, not less.)
    var defaultThresholdScale: Double {
        1.0
    }

    func defaultLevelCount(samplingRate: Double) -> Int {
        switch self {
        case .eeg:
            if samplingRate > 500 { return 10 }
            if samplingRate > 250 { return 9 }
            return 8
        case .erp:
            if samplingRate > 500 { return 11 }
            if samplingRate > 250 { return 10 }
            return 9
        }
    }
}

nonisolated enum WaveletCleaningMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case conservativeLocal = "Conservative Local"
    case global = "Global"
    case erpGentle = "ERP Gentle"

    var id: String { rawValue }

    var displayName: String {
        rawValue
    }

    var defaultIntensity: Double {
        switch self {
        case .conservativeLocal: return 1.0
        case .global: return 1.6
        case .erpGentle: return 0.75
        }
    }

    var thresholdMultiplier: Double {
        switch self {
        case .conservativeLocal: return 1.0
        case .global: return 0.72
        case .erpGentle: return 1.15
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "HAPPE-like Global" {
            self = .global
            return
        }
        guard let mode = WaveletCleaningMode(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown wavelet cleaning mode: \(value)"
            )
        }
        self = mode
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated enum WaveletCleaningThresholdRule: String, CaseIterable, Identifiable, Codable, Sendable {
    case hard = "Hard"
    case soft = "Soft"

    var id: String { rawValue }
}

nonisolated enum WaveletCleaningThresholdModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case robustUniversal = "Universal"
    case bayesShrink = "BayesShrink"
    /// Johnstone–Silverman empirical Bayes with the quasi-Cauchy prior — the
    /// method behind MATLAB `wdenoise`'s documented `'Bayes'` denoising option,
    /// which HAPPE selects in its wavelet-cleaning pipeline.
    /// See `EmpiricalBayesThreshold`.
    case empiricalBayes = "Empirical Bayes"

    var id: String { rawValue }

    /// One-line description shared by every picker that offers these models.
    var summary: String {
        switch self {
        case .robustUniversal:
            return "sigma × sqrt(2·ln N) from a robust (MAD) noise estimate — a fixed rule, not fitted to the band."
        case .bayesShrink:
            return "T = sigma_n²/sigma_s. Shares only the name with MATLAB wdenoise's documented Bayes method; on artifact-heavy EEG its gate collapses toward zero and nearly the whole signal is called artifact."
        case .empiricalBayes:
            return "Fits a sparse mixture prior to each level by marginal maximum likelihood and takes the gate where the posterior median first becomes nonzero. Method of Johnstone & Silverman (2005), Ann. Statist. 33(4), 1700–1752."
        }
    }
}

nonisolated struct WaveletCleaningConfiguration: Sendable {
    var pipeline: WaveletCleaningPipeline
    var mode: WaveletCleaningMode
    var channelIndices: [Int]
    var waveletFamily: WaveletReductionFamily
    var thresholdRule: WaveletCleaningThresholdRule
    var thresholdModel: WaveletCleaningThresholdModel
    var levelCount: Int
    var thresholdScale: Double
    var intensity: Double
    var paddingSeconds: Double
}

nonisolated struct WaveletCleaningPreviewResult: Sendable {
    var beforeAverage: ArtifactTemplateAverage
    var artifactAverage: ArtifactTemplateAverage
    var afterAverage: ArtifactTemplateAverage
    var metrics: WaveletCleaningPreviewMetrics
    var channelRemovedEnergy: [WaveletCleaningChannelEnergy]
    var startTimeSeconds: Double
    var endTimeSeconds: Double
}

nonisolated struct WaveletCleaningPreviewMetrics: Sendable {
    var varianceRetainedPercent: Double
    var correlation: Double
    var removedRMSMicrovolts: Double
    var peakReductionPercent: Double
}

nonisolated struct WaveletCleaningChannelEnergy: Identifiable, Sendable {
    var channelIndex: Int
    var removedRMSMicrovolts: Double
    var removedEnergyFraction: Double
    var peakRemovedMicrovolts: Float
    var normalizedRemovedEnergy: Double

    var id: Int { channelIndex }
}
