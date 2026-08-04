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
//  The U.S. Government authorizes the distribution and modification of this software
//  subject to the copyleft requirements of the GPL-3.0.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Rigid-body head-motion parameters used to drive fMRI-gradient artifact
//  correction (e.g. FASTR) on simultaneous EEG/fMRI data.
//
//  AFNI 3dvolreg and SPM/Bergen realignment-parameter text outputs are
//  supported. AFNI encodes rotations first; SPM/Bergen encodes translations
//  first and rotations in radians:
//
//    -1Dfile  (6 columns):  roll pitch yaw  dS dL dP
//    -dfile   (9 columns):  n  roll pitch yaw  dS dL dP  rmsold rmsnew
//    rp_*.txt (6 columns):  x y z  pitch roll yaw
//

import Foundation

nonisolated enum MotionFileFormat: String, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case afni3dvolreg = "afni3dvolreg"
    case spmBergen = "spmBergen"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .afni3dvolreg: return "AFNI 3dvolreg"
        case .spmBergen: return "BERGEN/SPM"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Detect from columns and scale"
        case .afni3dvolreg: return "roll pitch yaw dS dL dP"
        case .spmBergen: return "x y z, rotations in radians"
        }
    }
}

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
    case spmBergenRequiresSixColumns(Int)

    var errorDescription: String? {
        switch self {
        case .noData:
            return "No numeric motion rows were found in the file."
        case .unexpectedColumnCount(let count):
            return "Expected 6 columns (-1Dfile/rp_*.txt) or 9 columns (-dfile) per row, but found \(count)."
        case .spmBergenRequiresSixColumns(let count):
            return "BERGEN/SPM realignment files should have 6 columns, but found \(count)."
        }
    }
}

nonisolated struct MotionParameters: Sendable {
    var samples: [MotionSample]
    /// Display name of the file the parameters were read from.
    var sourceName: String
    /// How the loaded numeric rows were interpreted.
    var format: MotionFileFormat = .afni3dvolreg

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

    /// Parses the text contents of an AFNI 3dvolreg file or BERGEN/SPM rp_*.txt.
    static func parse(
        text: String,
        sourceName: String,
        format requestedFormat: MotionFileFormat = .auto
    ) throws -> MotionParameters {
        var rows: [[Double]] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Skip blank lines and comment/header lines (3dvolreg matrix files
            // and some pipelines prepend '#' comments).
            guard let first = line.first, first != "#" else { continue }

            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let values = fields.compactMap { Double($0) }
            // A valid data row parses entirely to numbers.
            guard values.count == fields.count, !values.isEmpty else { continue }
            rows.append(values)
        }

        guard !rows.isEmpty else { throw MotionParametersError.noData }

        let resolvedFormat = resolveFormat(requestedFormat, rows: rows, sourceName: sourceName)
        var samples: [MotionSample] = []
        samples.reserveCapacity(rows.count)

        for (index, values) in rows.enumerated() {
            if resolvedFormat == .spmBergen, values.count != 6 {
                throw MotionParametersError.spmBergenRequiresSixColumns(values.count)
            }
            let params: ArraySlice<Double>
            switch values.count {
            case 6:
                params = values[0..<6]
            case 9:
                // -dfile: n roll pitch yaw dS dL dP rmsold rmsnew
                params = values[1..<7]
            default:
                throw MotionParametersError.unexpectedColumnCount(values.count)
            }

            let p = Array(params)
            if resolvedFormat == .spmBergen {
                let radToDeg = 180.0 / Double.pi
                samples.append(MotionSample(
                    id: index,
                    roll: p[3] * radToDeg,
                    pitch: p[4] * radToDeg,
                    yaw: p[5] * radToDeg,
                    dS: p[0], dL: p[1], dP: p[2]
                ))
            } else {
                samples.append(MotionSample(
                    id: index,
                    roll: p[0], pitch: p[1], yaw: p[2],
                    dS: p[3], dL: p[4], dP: p[5]
                ))
            }
        }

        return MotionParameters(samples: samples, sourceName: sourceName, format: resolvedFormat)
    }

    private static func resolveFormat(
        _ requested: MotionFileFormat,
        rows: [[Double]],
        sourceName: String
    ) -> MotionFileFormat {
        switch requested {
        case .afni3dvolreg, .spmBergen:
            return requested
        case .auto:
            break
        }

        if rows.contains(where: { $0.count == 9 }) {
            return .afni3dvolreg
        }

        let lowerName = sourceName.lowercased()
        if lowerName.hasPrefix("rp_") || lowerName.contains("bergen") {
            return .spmBergen
        }
        if lowerName.hasSuffix(".1d") || lowerName.contains("3dvolreg") {
            return .afni3dvolreg
        }

        return looksLikeSPMBergen(rows) ? .spmBergen : .afni3dvolreg
    }

    /// SPM/Bergen files usually have mm translations in columns 1-3 and small
    /// radian rotations in columns 4-6; AFNI's first/last triplets are closer in
    /// scale. Use this only for Auto mode.
    private static func looksLikeSPMBergen(_ rows: [[Double]]) -> Bool {
        let sixColumnRows = rows.filter { $0.count == 6 }
        guard sixColumnRows.count >= 2 else { return false }

        var firstTripletSpeed = 0.0
        var lastTripletSpeed = 0.0
        var count = 0
        for i in 1..<sixColumnRows.count {
            let previous = sixColumnRows[i - 1]
            let current = sixColumnRows[i]
            firstTripletSpeed += squaredDistance(current, previous, range: 0..<3).squareRoot()
            lastTripletSpeed += squaredDistance(current, previous, range: 3..<6).squareRoot()
            count += 1
        }

        guard count > 0 else { return false }
        let firstMean = firstTripletSpeed / Double(count)
        let lastMean = lastTripletSpeed / Double(count)
        return firstMean > max(lastMean * 8, 0.05) && lastMean < 0.02
    }

    private static func squaredDistance(_ a: [Double], _ b: [Double], range: Range<Int>) -> Double {
        var total = 0.0
        for i in range {
            let d = a[i] - b[i]
            total += d * d
        }
        return total
    }
}
