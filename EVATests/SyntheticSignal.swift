//
//  SyntheticSignal.swift
//  EVATests
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
@testable import EVA

/// Builders for deterministic in-memory recordings used by analyzer tests.
enum SyntheticSignal {

    /// Wraps raw channel data into an `MFFSignalData` with minimal metadata.
    static func make(_ data: [[Float]], samplingRate: Double) -> MFFSignalData {
        let sampleCount = data.first?.count ?? 0
        return MFFSignalData(
            signalURL: URL(fileURLWithPath: "/tmp/synthetic.bin"),
            signalType: "EEG",
            numberOfChannels: data.count,
            samplingRate: samplingRate,
            duration: samplingRate > 0 ? Double(sampleCount) / samplingRate : 0,
            recordingStartTime: nil,
            events: [],
            data: data
        )
    }

    /// A clean band-limited sinusoid channel.
    static func sine(frequency: Double, samplingRate: Double, count: Int, amplitude: Float = 20) -> [Float] {
        (0..<count).map { i in
            amplitude * Float(sin(2 * .pi * frequency * Double(i) / samplingRate))
        }
    }

    /// A single Gaussian-shaped bump of the given width, peak amplitude 80 µV.
    static func bump(width: Int) -> [Float] {
        let center = Double(width) / 2
        let sigma = Double(width) / 6
        return (0..<width).map { i in
            let x = (Double(i) - center) / sigma
            return Float(80 * exp(-0.5 * x * x))
        }
    }

    /// Channels of low-amplitude noise with an identical bump planted at each
    /// position. Returns the data plus the sample range of the first bump
    /// (usable as an exemplar range).
    static func plantedBumps(
        channelCount: Int,
        count: Int,
        positions: [Int],
        width: Int,
        samplingRate: Double
    ) -> (data: [[Float]], exemplar: ClosedRange<Int>) {
        let shape = bump(width: width)
        var data: [[Float]] = (0..<channelCount).map { c in
            var state = UInt64(c + 1) &* 6364136223846793005 &+ 1
            return (0..<count).map { _ -> Float in
                state = state &* 6364136223846793005 &+ 1
                return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2)
            }
        }
        for c in 0..<channelCount {
            for start in positions {
                for k in 0..<width where start + k < count {
                    data[c][start + k] += shape[k]
                }
            }
        }
        let first = positions.first ?? 0
        return (data, first...(first + width - 1))
    }

    /// Pearson correlation between two equal-length series (sign-agnostic via abs).
    static func absCorrelation(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 1 else { return 0 }
        let ma = a.prefix(n).reduce(0, +) / Double(n)
        let mb = b.prefix(n).reduce(0, +) / Double(n)
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<n {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        guard da > 0, db > 0 else { return 0 }
        return abs(num / (da * db).squareRoot())
    }
}
