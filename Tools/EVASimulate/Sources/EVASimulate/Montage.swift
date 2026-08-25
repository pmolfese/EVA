//
//  Montage.swift
//  EVA Simulate
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Electrode names and 3D positions, and the two sidecar files EVA reads them
//  from.
//
//  The original forward model had no geometry at all — channels were an ordered
//  list with a circular smoothing kernel, which is all the paper's simulations
//  needed. Anything spatial needs more than that: an eye blink is frontal, a bad
//  electrode is somewhere in particular, and a topographic map needs to know
//  where to draw each disc. So channels now sit on a sphere at approximate
//  10-20 positions.
//
//  "Approximate" is doing real work in that sentence. The midline and the outer
//  ring follow the 10-20 construction directly (nasion-to-inion in 10% steps, so
//  Fpz sits 72 degrees forward of the vertex, Fz 36, and so on). The
//  intermediate sites and the 10-10 extension are eyeballed to within a few
//  degrees. That is entirely adequate for simulating where a blink is large and
//  for drawing a recognizable head map; it is not a digitized montage and should
//  not be used as one.
//
//  Coordinate frame: +x right, +y toward the nose, +z toward the vertex, on the
//  unit sphere.
//

import Foundation

nonisolated struct Electrode: Sendable {
    var name: String
    /// Arc angle from the vertex, in degrees. Cz is 0, the equator is 90.
    var thetaDegrees: Double
    /// Azimuth in degrees, measured from the nose toward the right ear.
    var phiDegrees: Double

    var position: (x: Double, y: Double, z: Double) {
        let theta = thetaDegrees * Double.pi / 180
        let phi = phiDegrees * Double.pi / 180
        return (sin(theta) * sin(phi), sin(theta) * cos(phi), cos(theta))
    }
}

nonisolated struct Montage: Sendable {
    var name: String
    var electrodes: [Electrode]

    var channelNames: [String] { electrodes.map(\.name) }

    var positions: [(x: Double, y: Double, z: Double)] { electrodes.map(\.position) }

    /// The standard 19-electrode 10-20 montage plus Oz, ordered roughly front to
    /// back. The ordering matters beyond cosmetics: the paper's spatial model
    /// smooths across *adjacent channel indices*, so a front-to-back ordering
    /// makes that smoothing approximately anatomical rather than arbitrary.
    static let tenTwenty: [Electrode] = [
        Electrode(name: "Fp1", thetaDegrees: 72, phiDegrees: -18),
        Electrode(name: "Fp2", thetaDegrees: 72, phiDegrees: 18),
        Electrode(name: "F7", thetaDegrees: 72, phiDegrees: -54),
        Electrode(name: "F3", thetaDegrees: 44, phiDegrees: -40),
        Electrode(name: "Fz", thetaDegrees: 36, phiDegrees: 0),
        Electrode(name: "F4", thetaDegrees: 44, phiDegrees: 40),
        Electrode(name: "F8", thetaDegrees: 72, phiDegrees: 54),
        Electrode(name: "T7", thetaDegrees: 90, phiDegrees: -90),
        Electrode(name: "C3", thetaDegrees: 45, phiDegrees: -90),
        Electrode(name: "Cz", thetaDegrees: 0, phiDegrees: 0),
        Electrode(name: "C4", thetaDegrees: 45, phiDegrees: 90),
        Electrode(name: "T8", thetaDegrees: 90, phiDegrees: 90),
        Electrode(name: "P7", thetaDegrees: 72, phiDegrees: -126),
        Electrode(name: "P3", thetaDegrees: 44, phiDegrees: -140),
        Electrode(name: "Pz", thetaDegrees: 36, phiDegrees: 180),
        Electrode(name: "P4", thetaDegrees: 44, phiDegrees: 140),
        Electrode(name: "P8", thetaDegrees: 72, phiDegrees: 126),
        Electrode(name: "O1", thetaDegrees: 72, phiDegrees: -162),
        Electrode(name: "Oz", thetaDegrees: 72, phiDegrees: 180),
        Electrode(name: "O2", thetaDegrees: 72, phiDegrees: 162)
    ]

    /// 10-10 sites used to fill out montages larger than 20 channels.
    static let tenTenExtension: [Electrode] = [
        Electrode(name: "Fpz", thetaDegrees: 72, phiDegrees: 0),
        Electrode(name: "AF7", thetaDegrees: 62, phiDegrees: -38),
        Electrode(name: "AF3", thetaDegrees: 52, phiDegrees: -24),
        Electrode(name: "AF4", thetaDegrees: 52, phiDegrees: 24),
        Electrode(name: "AF8", thetaDegrees: 62, phiDegrees: 38),
        Electrode(name: "FT7", thetaDegrees: 82, phiDegrees: -72),
        Electrode(name: "FC5", thetaDegrees: 64, phiDegrees: -64),
        Electrode(name: "FC1", thetaDegrees: 34, phiDegrees: -56),
        Electrode(name: "FC2", thetaDegrees: 34, phiDegrees: 56),
        Electrode(name: "FC6", thetaDegrees: 64, phiDegrees: 64),
        Electrode(name: "FT8", thetaDegrees: 82, phiDegrees: 72),
        Electrode(name: "TP7", thetaDegrees: 82, phiDegrees: -108),
        Electrode(name: "CP5", thetaDegrees: 64, phiDegrees: -116),
        Electrode(name: "CP1", thetaDegrees: 34, phiDegrees: -124),
        Electrode(name: "CP2", thetaDegrees: 34, phiDegrees: 124),
        Electrode(name: "CP6", thetaDegrees: 64, phiDegrees: 116),
        Electrode(name: "TP8", thetaDegrees: 82, phiDegrees: 108),
        Electrode(name: "PO7", thetaDegrees: 70, phiDegrees: -144),
        Electrode(name: "PO3", thetaDegrees: 56, phiDegrees: -158),
        Electrode(name: "PO4", thetaDegrees: 56, phiDegrees: 158),
        Electrode(name: "PO8", thetaDegrees: 70, phiDegrees: 144)
    ]

    /// A montage of `count` channels.
    ///
    /// At exactly 20 this is the standard 10-20 set plus Oz. Below that the set
    /// is *subsampled* across the list rather than truncated, because truncating
    /// a front-to-back ordering would hand back an all-frontal montage — fine
    /// for arithmetic, useless for a demo. Above 41 it falls back to a spiral,
    /// which is not a real montage and is named so nobody mistakes it for one.
    /// The standard montage with each electrode displaced by a random angle.
    ///
    /// Models cap placement, which is never twice the same and which changes
    /// every subject's topography even for identical sources. The jitter is
    /// applied in the spherical angles the montage is defined in, seeded from
    /// the recording's own seed so a subject's montage is reproducible.
    static func standard(count: Int, jitterDegrees: Double, seed: UInt64) -> Montage {
        var montage = standard(count: count)
        guard jitterDegrees > 0 else { return montage }
        var random = GaussianSource(seed: seed)
        for index in montage.electrodes.indices {
            montage.electrodes[index].thetaDegrees += jitterDegrees * random.gaussian()
            montage.electrodes[index].phiDegrees += jitterDegrees * random.gaussian()
        }
        montage.name += String(format: " (placement ±%.1f°)", jitterDegrees)
        return montage
    }

    static func standard(count: Int) -> Montage {
        let full = tenTwenty + tenTenExtension
        guard count > 0 else { return Montage(name: "Empty", electrodes: []) }

        if count == tenTwenty.count {
            return Montage(name: "10-20", electrodes: tenTwenty)
        }
        if count < tenTwenty.count {
            let picked = (0..<count).map { index -> Electrode in
                let position = Double(index) * Double(tenTwenty.count - 1) / Double(max(1, count - 1))
                return tenTwenty[min(tenTwenty.count - 1, Int(position.rounded()))]
            }
            return Montage(name: "10-20 subset", electrodes: dedupe(picked))
        }
        if count <= full.count {
            return Montage(name: "10-10 subset", electrodes: Array(full.prefix(count)))
        }
        return Montage(name: "Spiral (synthetic)", electrodes: spiral(count: count))
    }

    /// Names must stay unique — they are how EVA identifies a channel, and a
    /// duplicate would make channel selection ambiguous.
    private static func dedupe(_ electrodes: [Electrode]) -> [Electrode] {
        var seen: Set<String> = []
        var result: [Electrode] = []
        for electrode in electrodes {
            var candidate = electrode
            var suffix = 2
            while seen.contains(candidate.name) {
                candidate.name = "\(electrode.name)-\(suffix)"
                suffix += 1
            }
            seen.insert(candidate.name)
            result.append(candidate)
        }
        return result
    }

    /// A Fibonacci spiral over the upper hemisphere, for channel counts past the
    /// named sites. Evenly spaced and reproducible, but it is not a montage any
    /// amplifier ships.
    private static func spiral(count: Int) -> [Electrode] {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        return (0..<count).map { index in
            let fraction = Double(index) / Double(max(1, count - 1))
            let theta = 88 * fraction.squareRoot()
            let phi = (Double(index) * golden * 180 / Double.pi).truncatingRemainder(dividingBy: 360) - 180
            return Electrode(name: "E\(index + 1)", thetaDegrees: theta, phiDegrees: phi)
        }
    }
}

// MARK: - Sidecar files

nonisolated enum MontageWriter {

    /// Overwrites the layout sidecars inside an already-written MFF package.
    ///
    /// `MFFWriter` synthesizes a minimal `sensorLayout.xml` carrying names but no
    /// coordinates (it normally expects to copy the real one from a source
    /// package, and a simulation has no source), and writes no `coordinates.xml`
    /// at all. Without positions EVA finds no layout, so topographic maps and
    /// anything that selects channels by location come up empty. Writing both
    /// files here, after the package exists, gets the geometry in without
    /// changing app code.
    static func writeLayoutFiles(montage: Montage, to packageURL: URL) throws {
        try sensorLayoutXML(montage: montage)
            .write(to: packageURL.appendingPathComponent("sensorLayout.xml"),
                   atomically: true, encoding: .utf8)
        try coordinatesXML(montage: montage)
            .write(to: packageURL.appendingPathComponent("coordinates.xml"),
                   atomically: true, encoding: .utf8)
    }

    /// The flat 2D projection EVA draws head maps from.
    ///
    /// Azimuthal-equidistant: radius is proportional to arc angle from the
    /// vertex, which keeps the outer ring circular and the spacing even. The y
    /// axis is negated on the way out because EGI's convention — which
    /// `SensorLayout.load` decodes — puts anterior electrodes at *smaller* y.
    static func sensorLayoutXML(montage: Montage) -> String {
        var body = ""
        for (index, electrode) in montage.electrodes.enumerated() {
            let radius = electrode.thetaDegrees / 90
            let phi = electrode.phiDegrees * Double.pi / 180
            let x = radius * sin(phi)
            let y = radius * cos(phi)
            body += """
              <sensor>
                <number>\(index + 1)</number>
                <name>\(escaped(electrode.name))</name>
                <type>0</type>
                <x>\(format(x))</x>
                <y>\(format(-y))</y>
                <z>0.0</z>
              </sensor>

            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <sensorLayout>
          <name>\(escaped(montage.name))</name>
        \(body)</sensorLayout>
        """
    }

    /// True 3D positions, which EVA uses for spherical-spline interpolation.
    static func coordinatesXML(montage: Montage) -> String {
        var body = ""
        for (index, electrode) in montage.electrodes.enumerated() {
            let position = electrode.position
            body += """
              <sensor>
                <number>\(index + 1)</number>
                <name>\(escaped(electrode.name))</name>
                <type>0</type>
                <x>\(format(position.x))</x>
                <y>\(format(position.y))</y>
                <z>\(format(position.z))</z>
              </sensor>

            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <coordinates>
          <name>\(escaped(montage.name))</name>
          <sensorLayout>\(escaped(montage.name))</sensorLayout>
        \(body)</coordinates>
        """
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
