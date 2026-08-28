//
//  ElectrodeGeometry+Forward.swift
//  EVA
//
//  Adapts EVA's indexed unit-sphere geometry to physical, ordered forward input.
//

import Foundation

nonisolated enum ElectrodeGeometryForwardError: LocalizedError, Sendable, Equatable {
    case incomplete(expected: Int, found: Int, missingOneBased: [Int])

    var errorDescription: String? {
        switch self {
        case .incomplete(let expected, let found, let missing):
            let preview = missing.prefix(8).map(String.init).joined(separator: ", ")
            let suffix = missing.count > 8 ? ", …" : ""
            return "coordinates contain \(found) of \(expected) EEG channels"
                + (missing.isEmpty ? "" : "; missing channel numbers \(preview)\(suffix)")
        }
    }
}

extension ElectrodeGeometry {
    /// Projects indexed unit directions onto the forward model's outer shell,
    /// preserving signal row order and names. Missing geometry fails explicitly.
    nonisolated func orderedForwardElectrodes(
        channelCount: Int,
        signalChannelNames: [String]? = nil,
        head: ForwardHeadModel
    ) throws -> OrderedElectrodes {
        let expected = Set(0..<channelCount)
        let present = Set(positions.keys.filter(expected.contains))
        let missing = expected.subtracting(present).sorted().map { $0 + 1 }
        guard positions.count == channelCount,
              present.count == channelCount,
              missing.isEmpty else {
            throw ElectrodeGeometryForwardError.incomplete(
                expected: channelCount,
                found: positions.count,
                missingOneBased: missing
            )
        }

        var names = [String]()
        var physicalPositions = [SIMD3<Double>]()
        names.reserveCapacity(channelCount)
        physicalPositions.reserveCapacity(channelCount)

        for index in 0..<channelCount {
            let direction = positions[index]!
            let signalName = signalChannelNames.flatMap {
                $0.indices.contains(index) ? $0[index] : nil
            }?.trimmingCharacters(in: .whitespacesAndNewlines)
            names.append(
                signalName?.isEmpty == false
                    ? signalName!
                    : channelNames[index] ?? "E\(index + 1)"
            )
            physicalPositions.append(
                SIMD3<Double>(
                    direction.x * head.scalpRadiusMeters + head.centerMeters.x,
                    direction.y * head.scalpRadiusMeters + head.centerMeters.y,
                    direction.z * head.scalpRadiusMeters + head.centerMeters.z
                )
            )
        }

        return OrderedElectrodes(names: names, positionsMeters: physicalPositions)
    }
}
