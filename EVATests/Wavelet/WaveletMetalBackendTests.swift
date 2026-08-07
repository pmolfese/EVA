//
//  WaveletMetalBackendTests.swift
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
//  The GPU decomposition has to agree with the CPU one, or the "Use GPU"
//  checkbox silently changes what the Explorer finds. These compare the two
//  backends directly, and end-to-end through a scan.
//

import Testing
import Foundation
@testable import EVA

struct WaveletMetalBackendTests {

    private func noisyChannel(seed: UInt64, count: Int, withBurstAt burst: Int? = nil) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1
        var channel = (0..<count).map { _ -> Float in
            state = state &* 6364136223846793005 &+ 1
            return Float((Double(state >> 40) / Double(UInt32.max) - 0.5) * 2)
        }
        if let burst {
            for k in 0..<200 where burst + k < count {
                let phase = Double(k) / 200.0 * .pi
                channel[burst + k] += Float(sin(phase)) * 100
            }
        }
        return channel
    }

    /// The kernel mirrors `WaveletTransform.swtStep` tap for tap, so the only
    /// expected divergence is single vs. double precision (compounded across
    /// the level cascade, and with Metal fast-math enabled).
    @Test func gpuDetailBandsMatchCPUWithinPrecision() throws {
        let backend = try #require(
            WaveletMetalBackend.shared,
            "no Metal device available on this machine"
        )

        let sampleCount = 4096
        let levelCount = 6
        let family = WaveletReductionFamily.bior44
        let bank = family.filterBank

        let channels = (0..<4).map { c in
            WaveletArtifactAnalyzer.detrendedForTransform(
                noisyChannel(seed: UInt64(c + 1), count: sampleCount, withBurstAt: 1500 + c * 100)
            )
        }

        let gpu = try #require(
            backend.forwardSWTDetails(
                channels: channels,
                levelCount: levelCount,
                lowPass: bank.decompositionLowPass.map(Float.init),
                highPass: bank.decompositionHighPass.map(Float.init)
            ),
            "GPU dispatch returned no result"
        )

        #expect(gpu.count == channels.count)

        let transform = WaveletTransform(bank: bank)
        for (channelIndex, channel) in channels.enumerated() {
            let cpu = transform.forwardSWT(channel.map(Double.init), levels: levelCount).details
            #expect(gpu[channelIndex].count == levelCount)

            for level in 0..<levelCount {
                let gpuLevel = gpu[channelIndex][level]
                let cpuLevel = cpu[level]
                #expect(gpuLevel.count == cpuLevel.count)

                // Compare against the level's own scale rather than a flat
                // epsilon — deep levels carry much larger coefficients than
                // fine ones, so a single absolute tolerance would be
                // meaninglessly loose at one end and impossibly tight at the other.
                let scale = max(cpuLevel.map { abs($0) }.max() ?? 0, 1e-6)
                var worst = 0.0
                for index in cpuLevel.indices {
                    worst = max(worst, abs(Double(gpuLevel[index]) - cpuLevel[index]) / scale)
                }
                #expect(
                    worst < 1e-4,
                    "Ch \(channelIndex) level \(level + 1): worst relative deviation \(worst)"
                )
            }
        }
    }

    /// What actually matters to a user ticking the box: the same scan finds
    /// the same artifacts.
    @Test func gpuScanFindsTheSameCandidatesAsCPU() throws {
        _ = try #require(
            WaveletMetalBackend.shared,
            "no Metal device available on this machine"
        )

        let sr = 500.0
        let n = 20_000
        let burstStarts = [4_000, 9_000, 14_000]

        var data: [[Float]] = []
        for c in 0..<8 {
            var channel = noisyChannel(seed: UInt64(c + 11), count: n)
            // Shared bursts, but with amplitude rising by channel so there's
            // one unambiguous strongest channel. With identical bursts the
            // winner is decided by noise alone, and "do the backends agree"
            // becomes a coin flip rather than a real check.
            let amplitude = Float(50 + c * 12)
            for burst in burstStarts {
                for k in 0..<300 where burst + k < n {
                    let phase = Double(k) / 300.0 * .pi
                    channel[burst + k] += Float(sin(phase)) * amplitude
                }
            }
            data.append(channel)
        }

        let signal = SyntheticSignal.make(data, samplingRate: sr)
        func configuration(gpu: Bool) -> WaveletArtifactExplorerConfiguration {
            WaveletArtifactExplorerConfiguration(
                channelIndices: Array(0..<8), downsampleRate: 500, levelCount: 7, thresholdScale: 1,
                cleaningMode: .conservativeLocal, intensity: 1, waveletFamily: .bior44,
                thresholdRule: .hard, thresholdModel: .bayesShrink,
                mergeWindowSeconds: 0.1, minimumDurationSeconds: 0.02, maximumCandidates: 40,
                usesGPU: gpu
            )
        }

        let roles = WaveletChannelRoles(ocular: Set(0..<2), lateral: Set(4..<6))
        let cpu = WaveletArtifactAnalyzer.explore(
            in: signal, configuration: configuration(gpu: false), channelRoles: roles
        )
        let gpu = WaveletArtifactAnalyzer.explore(
            in: signal, configuration: configuration(gpu: true), channelRoles: roles
        )

        // Both must find every planted burst. Checked as overlap with the
        // burst's span rather than proximity to its onset: for a smooth bump
        // the wavelet response is strongest at the steep edges, so the
        // reported peak legitimately lands at the bump's shoulder rather than
        // its centre.
        for burst in burstStarts {
            let start = Double(burst) / sr
            let end = Double(burst + 300) / sr
            func covers(_ candidate: WaveletArtifactCandidate) -> Bool {
                candidate.peakTimeSeconds >= start - 0.1 && candidate.peakTimeSeconds <= end + 0.1
            }
            #expect(cpu.candidates.contains(where: covers), "CPU missed the burst spanning \(start)-\(end)s")
            #expect(gpu.candidates.contains(where: covers), "GPU missed the burst spanning \(start)-\(end)s")
        }

        // And agree on the strongest one, which is the result a user acts on.
        let cpuTop = try #require(cpu.candidates.first)
        let gpuTop = try #require(gpu.candidates.first)
        #expect(
            abs(cpuTop.peakTimeSeconds - gpuTop.peakTimeSeconds) < 0.05,
            "top candidate differs: CPU \(cpuTop.peakTimeSeconds)s vs GPU \(gpuTop.peakTimeSeconds)s"
        )
        #expect(cpuTop.channelIndex == gpuTop.channelIndex)
        // Scores come from different arithmetic (GPU float vs CPU double, and
        // thresholds from a subsample vs the full window), so they shouldn't
        // match exactly — but they must agree closely enough that ranking and
        // any score-based judgement carry over.
        let scoreDelta = abs(cpuTop.score - gpuTop.score) / max(cpuTop.score, 1e-9)
        #expect(scoreDelta < 0.05, "top score differs by \(scoreDelta * 100)%: CPU \(cpuTop.score) vs GPU \(gpuTop.score)")
    }
}
