//
//  SeededGenerator.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  A reproducible `RandomNumberGenerator` for the places where EVA needs
//  *arbitrary* numbers rather than *unpredictable* ones — resampling, jitter,
//  tie-breaking. Nothing here is cryptographic and nothing here should be used
//  where unpredictability matters.
//
//  This exists because of `REWIND.md`'s core promise: navigating back to a node
//  returns you to the same data. A metric that changes on every recomputation
//  weakens that promise for no benefit, and the determinism audit (work item 5)
//  found exactly one such place — the SME bootstrap in `EpochSNR`, which drew
//  from `SystemRandomNumberGenerator` and so reported values up to ~19% apart on
//  paired runs over identical epochs.
//
//  Reach for this, not `SystemRandomNumberGenerator`, in any code that
//  contributes to a reported number or a written sample.
//

import Foundation

/// SplitMix64 — the standard seeding companion to xoshiro, chosen here because
/// it is a handful of lines, has no state beyond a `UInt64`, and passes the
/// statistical batteries at the sizes EVA draws (hundreds to thousands of
/// values). Deterministic for a given seed on every platform: the arithmetic is
/// fixed-width integer only, with no floating point and no platform-dependent
/// hashing.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // A zero seed is legal for SplitMix64 (unlike xoshiro), but shifting it
        // off zero costs nothing and avoids the degenerate-looking first draw.
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
