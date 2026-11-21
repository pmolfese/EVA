//
//  SimulationTruthFixture.swift
//  EVATests
//
//  The deliberately small decoding surface shared by end-to-end tests. JSONDecoder
//  ignores the rest of EVASimulate's truth sidecar, so adding simulator metadata
//  does not couple the app test target to the command-line tool's source module.
//

import Foundation

struct SimulationTruthFixture: Decodable {
    struct Config: Decodable {
        var lineNoiseHz: Double
    }

    struct BCGGenerator: Decodable {
        var topography: [Double]
    }

    struct LeadField: Decodable {
        var matrixMicrovoltsPerNanoampereMeter: [[Double]]
    }

    struct SourceSpace: Decodable {
        var leadField: LeadField
    }

    struct ERPComponent: Decodable {
        var id: String
        var peakLatencySeconds: Double
        var peakAmplitudeMicrovolts: Double
    }

    struct ERPTrial: Decodable {
        var condition: String
        var eventCode: String
        var onsetSeconds: Double
        var peakLatencySeconds: Double
        var peakAmplitudeMicrovolts: Double
        var omitted: Bool
        var overlapsAnotherTrial: Bool?
    }

    struct ChannelBridge: Decodable {
        var firstChannel: Int
        var secondChannel: Int
    }

    var bcgTrueBeatSeconds: [Double]
    var bcgDetectedBeatSeconds: [Double]
    var bcgGenerators: [BCGGenerator]?
    var badChannels: [String: String]
    var blinkTopography: [Double]
    var horizontalEyeTopography: [Double]
    var emgLeftTemporalisTopography: [Double]?
    var emgRightTemporalisTopography: [Double]?
    var emgPosteriorNeckTopography: [Double]?
    var impedanceLineNoiseGainsMicrovolts: [Double]?
    var sourceSpace: SourceSpace?
    var config: Config
    var erpComponents: [ERPComponent]?
    var erpTrials: [ERPTrial]?
    var erpTopography: [Double]?
    var bridgedChannelPairs: [ChannelBridge]?
    var badReferenceRMSMicrovolts: Double?

    static func load(from url: URL) throws -> SimulationTruthFixture {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
