//
//  MotionParameters.swift
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
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Rigid-body head-motion parameters estimated by AFNI's 3dvolreg, used to drive
//  fMRI-gradient artifact correction (e.g. FASTR) on simultaneous EEG/fMRI data.
//
//  Two 3dvolreg text outputs are supported, both giving the 6 motion parameters
//  needed to bring each volume back into alignment with the base:
//
//    -1Dfile  (6 columns):  roll pitch yaw  dS dL dP
//    -dfile   (9 columns):  n  roll pitch yaw  dS dL dP  rmsold rmsnew
//
//  where roll/pitch/yaw are rotations in degrees (CCW) about the I-S / R-L / A-P
//  axes and dS/dL/dP are translations in mm (Superior / Left / Posterior).
//

import Foundation

/// One volume's worth of rigid-body motion parameters.
nonisolated struct MotionSample: Identifiable, Sendable, Hashable {
    /// Volume (sub-brick) index, 0-based.
    let id: Int
    let roll: Double   // deg, rotation about the I-S axis ("no")
    let pitch: Double  // deg, rotation about the R-L axis ("yes")
    let yaw: Double    // deg, rotation about the A-P axis ("wobble")
    let dS: Double     // mm, displacement Superior
    let dL: Double     // mm, displacement Left
    let dP: Double     // mm, displacement Posterior
}

nonisolated enum MotionParametersError: LocalizedError {
    case noData
    case unexpectedColumnCount(Int)

    var errorDescription: String? {
        switch self {
        case .noData:
            return "No numeric motion rows were found in the file."
        case .unexpectedColumnCount(let count):
            return "Expected 6 columns (-1Dfile) or 9 columns (-dfile) per row, but found \(count)."
        }
    }
}

nonisolated struct MotionParameters: Sendable {
    var samples: [MotionSample]
    /// Display name of the file the parameters were read from.
    var sourceName: String

    var count: Int { samples.count }

    /// Framewise displacement (Power et al. 2012) in mm, one value per volume.
    ///
    /// FD is the sum of the absolute volume-to-volume changes of all six
    /// parameters, with the three rotations converted from degrees to mm of arc
    /// length on a sphere of radius `radiusMm` (50 mm is the common default,
    /// approximating the cortical surface). The first volume has no predecessor,
    /// so its FD is defined as 0.
    func framewiseDisplacement(radiusMm: Double = 50) -> [Double] {
        guard samples.count > 1 else { return [Double](repeating: 0, count: samples.count) }
        let degToMM = Double.pi / 180.0 * radiusMm
        var fd = [Double](repeating: 0, count: samples.count)
        for i in 1..<samples.count {
            let a = samples[i]
            let b = samples[i - 1]
            fd[i] = abs(a.roll - b.roll) * degToMM
                + abs(a.pitch - b.pitch) * degToMM
                + abs(a.yaw - b.yaw) * degToMM
                + abs(a.dS - b.dS)
                + abs(a.dL - b.dL)
                + abs(a.dP - b.dP)
        }
        return fd
    }

    /// Volume indices whose framewise displacement exceeds `threshold` (mm).
    func volumesExceeding(threshold: Double, radiusMm: Double = 50) -> [Int] {
        let fd = framewiseDisplacement(radiusMm: radiusMm)
        return fd.indices.filter { fd[$0] > threshold }
    }

    /// Parses the text contents of a 3dvolreg `-1Dfile` or `-dfile` output.
    static func parse(text: String, sourceName: String) throws -> MotionParameters {
        var samples: [MotionSample] = []
        var index = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Skip blank lines and comment/header lines (3dvolreg matrix files
            // and some pipelines prepend '#' comments).
            guard let first = line.first, first != "#" else { continue }

            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let values = fields.compactMap { Double($0) }
            // A valid data row parses entirely to numbers.
            guard values.count == fields.count, !values.isEmpty else { continue }

            let params: ArraySlice<Double>
            switch values.count {
            case 6:
                // -1Dfile: roll pitch yaw dS dL dP
                params = values[0..<6]
            case 9:
                // -dfile: n roll pitch yaw dS dL dP rmsold rmsnew
                params = values[1..<7]
            default:
                throw MotionParametersError.unexpectedColumnCount(values.count)
            }

            let p = Array(params)
            samples.append(MotionSample(
                id: index,
                roll: p[0], pitch: p[1], yaw: p[2],
                dS: p[3], dL: p[4], dP: p[5]
            ))
            index += 1
        }

        guard !samples.isEmpty else { throw MotionParametersError.noData }
        return MotionParameters(samples: samples, sourceName: sourceName)
    }
}
