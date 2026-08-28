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

/// Cheap identity of the external file a motion series was read from.
///
/// Motion parameters are the one correction input that lives outside the
/// recording package: nothing in `eva.xml` used to say *which* file produced the
/// censored-volume set, so replaying a gradient step with a different — or
/// edited — motion file produced different samples under an identical history
/// node (ROADMAP RW-1 item 11). This is the explicit staleness rule for that
/// input.
///
/// Name, size, and modification date, as the roadmap's cache policy prescribes:
/// cheap source metadata, no content digest. It cannot prove two files are
/// identical, and is not asked to — it detects the ordinary ways a motion file
/// stops being the one that was used, and says so instead of correcting on.
nonisolated struct MotionSourceFingerprint: Sendable, Equatable {
    var name: String
    var byteCount: Int
    /// Whole seconds since 1970: the resolution that survives a file copy, an
    /// archive round-trip, and a plist encode.
    var modifiedAt: Int
    /// Rows *as used* — after any trim — rather than as found in the file, since
    /// the trimmed series is what the correction consumed.
    var rowCount: Int

    static let parameterPrefix = "motionSource"

    var parameterValues: [String: String] {
        [
            "\(Self.parameterPrefix)Name": name,
            "\(Self.parameterPrefix)Bytes": "\(byteCount)",
            "\(Self.parameterPrefix)Modified": "\(modifiedAt)",
            "\(Self.parameterPrefix)Rows": "\(rowCount)"
        ]
    }

    init(name: String, byteCount: Int, modifiedAt: Int, rowCount: Int) {
        self.name = name
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.rowCount = rowCount
    }

    /// Reads back a fingerprint recorded in a processing step's parameters.
    init?(parameters: [String: String]) {
        let prefix = Self.parameterPrefix
        guard let name = parameters["\(prefix)Name"],
              let bytes = parameters["\(prefix)Bytes"].flatMap(Int.init),
              let modified = parameters["\(prefix)Modified"].flatMap(Int.init),
              let rows = parameters["\(prefix)Rows"].flatMap(Int.init) else { return nil }
        self.init(name: name, byteCount: bytes, modifiedAt: modified, rowCount: rows)
    }

    /// Fingerprints the file at `url`, or `nil` when its attributes are
    /// unreadable — an unknown fingerprint is recorded as absent rather than as
    /// zeroes, which would compare equal to another unreadable file.
    static func read(fileAt url: URL, rowCount: Int) -> MotionSourceFingerprint? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate else { return nil }
        return MotionSourceFingerprint(
            name: url.lastPathComponent,
            byteCount: size,
            modifiedAt: Int(modified.timeIntervalSince1970.rounded()),
            rowCount: rowCount
        )
    }

    /// Why `self` is not the file `recorded` describes, in one sentence, or
    /// `nil` when nothing detectable differs.
    func mismatch(against recorded: MotionSourceFingerprint) -> String? {
        guard self != recorded else { return nil }
        var parts: [String] = []
        if name != recorded.name { parts.append("file is \(name), was \(recorded.name)") }
        if byteCount != recorded.byteCount { parts.append("size \(byteCount) B, was \(recorded.byteCount) B") }
        if modifiedAt != recorded.modifiedAt { parts.append("modified since") }
        if rowCount != recorded.rowCount { parts.append("\(rowCount) rows, was \(recorded.rowCount)") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ")
    }
}

nonisolated struct MotionParameters: Sendable {
    var samples: [MotionSample]
    /// Display name of the file the parameters were read from.
    var sourceName: String
    /// How the loaded numeric rows were interpreted.
    var format: MotionFileFormat = .afni3dvolreg
    /// Identity of the file on disk, when it was loaded from one.
    var source: MotionSourceFingerprint?

    var count: Int { samples.count }

    /// The fingerprint to record for the series as it stands — the loaded file's
    /// identity with the row count it currently has, so a trim is visible.
    var currentFingerprint: MotionSourceFingerprint? {
        guard var source else { return nil }
        source.rowCount = samples.count
        return source
    }

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

    /// Returns a copy with `start` samples dropped from the front and `end`
    /// dropped from the back — e.g. to line up a motion file that has an
    /// extra volume or two versus the EEG's TR markers. IDs are renumbered
    /// from 0 so the trimmed samples still plot as a contiguous volume axis.
    func trimmed(start: Int, end: Int) -> MotionParameters {
        let lower = min(max(start, 0), samples.count)
        let upper = min(max(end, 0), samples.count - lower)
        let kept = samples[lower..<(samples.count - upper)]
        let reindexed = kept.enumerated().map { index, sample in
            MotionSample(
                id: index,
                roll: sample.roll, pitch: sample.pitch, yaw: sample.yaw,
                dS: sample.dS, dL: sample.dL, dP: sample.dP
            )
        }
        return MotionParameters(samples: reindexed, sourceName: sourceName, format: format, source: source)
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
