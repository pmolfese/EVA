//
//  OcularDipoleModel.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  A deliberately small ocular volume-conduction model. Two corneo-retinal
//  dipoles sit at approximate eye centres in a homogeneous conductor. It is not
//  the neural three-shell model (the eyes are outside its brain compartment),
//  but its topographies follow an electric dipole field instead of an invented
//  cosine. The normalized result is then scaled by the existing ocular amplitude
//  controls.
//

import Foundation

nonisolated struct OcularDipoleTruth: Codable, Sendable {
    var id: String
    var positionMeters: Vector3D
    var blinkAndVerticalOrientation: Vector3D
    var horizontalOrientation: Vector3D
    var volumeConductor: String
}

nonisolated struct OcularDipoleTopographies: Sendable {
    var blink: [Double]
    var horizontal: [Double]
    var vertical: [Double]
    var dipoles: [OcularDipoleTruth]
}

nonisolated enum OcularDipoleModel {
    static func topographies(
        montage: Montage, head: SphericalHeadModel,
        reference: EEGReference = .average
    ) -> OcularDipoleTopographies {
        let center = head.centerMeters
        let radius = head.scalpRadiusMeters
        let conductorDescription = "homogeneous dipole field, \(reference.rawValue)-referenced and normalized"
        let dipoles = [
            OcularDipoleTruth(
                id: "left-eye",
                positionMeters: center + Vector3D(x: -0.028, y: 0.060, z: -0.012),
                blinkAndVerticalOrientation: Vector3D(x: 0, y: 0, z: 1),
                horizontalOrientation: Vector3D(x: 1, y: 0, z: 0),
                volumeConductor: conductorDescription
            ),
            OcularDipoleTruth(
                id: "right-eye",
                positionMeters: center + Vector3D(x: 0.028, y: 0.060, z: -0.012),
                blinkAndVerticalOrientation: Vector3D(x: 0, y: 0, z: 1),
                horizontalOrientation: Vector3D(x: 1, y: 0, z: 0),
                volumeConductor: conductorDescription
            )
        ]
        let sensors = montage.positions.map {
            center + Vector3D(x: $0.x, y: $0.y, z: $0.z) * radius
        }
        let vertical = normalized(
            sensors.map { sensor in
                dipoles.reduce(0.0) {
                    $0 + potential(
                        sensor: sensor,
                        source: $1.positionMeters,
                        orientation: $1.blinkAndVerticalOrientation
                    )
                }
            }, reference: reference
        )
        let horizontal = normalized(
            sensors.map { sensor in
                dipoles.reduce(0.0) {
                    $0 + potential(
                        sensor: sensor,
                        source: $1.positionMeters,
                        orientation: $1.horizontalOrientation
                    )
                }
            }, reference: reference
        )
        return OcularDipoleTopographies(
            blink: vertical,
            horizontal: horizontal,
            vertical: vertical,
            dipoles: dipoles
        )
    }

    private static func potential(
        sensor: Vector3D,
        source: Vector3D,
        orientation: Vector3D
    ) -> Double {
        let displacement = sensor - source
        let distance = displacement.norm
        guard distance > 1e-9 else { return 0 }
        return orientation.dot(displacement) / (distance * distance * distance)
    }

    private static func normalized(
        _ values: [Double], reference: EEGReference
    ) -> [Double] {
        guard !values.isEmpty else { return [] }
        let mean = reference == .average
            ? values.reduce(0, +) / Double(values.count) : 0
        var result = values.map { $0 - mean }
        let peak = result.map(abs).max() ?? 0
        if peak > 0 {
            for index in result.indices { result[index] /= peak }
        }
        return result
    }
}
