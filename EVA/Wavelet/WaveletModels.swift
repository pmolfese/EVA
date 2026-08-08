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
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
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

    /// Robust universal (MAD σ · sqrt(2 ln N)) — the behaviorally closest
    /// stand-in for MATLAB wdenoise's empirical-Bayes 'Bayes' method. Not
    /// BayesShrink: its T = σ_n²/σ_s collapses on artifact-inflated EEG
    /// bands, flagging nearly everything as artifact (see WaveletReducer's
    /// header note).
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
    case happeLikeGlobal = "HAPPE-like Global"
    case erpGentle = "ERP Gentle"

    var id: String { rawValue }

    var defaultIntensity: Double {
        switch self {
        case .conservativeLocal: return 1.0
        case .happeLikeGlobal: return 1.6
        case .erpGentle: return 0.75
        }
    }

    var thresholdMultiplier: Double {
        switch self {
        case .conservativeLocal: return 1.0
        case .happeLikeGlobal: return 0.72
        case .erpGentle: return 1.15
        }
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

    var id: String { rawValue }
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
