//
//  FIFQuickLookSummary.swift
//  EVAPreviewKit
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Everything the FIF preview draws, read once off the main thread and handed to
//  the view as plain data.
//
//  A `.fif` is a container for at least a dozen different documents (see
//  `FIFDocument`), so this is a discriminated union rather than one flat
//  summary: a recording gets channels and a waveform, a head model gets shells
//  and contours, a transform gets its matrix, and anything EVA has no picture
//  for still gets an honest structural outline.
//

import Foundation
import simd

nonisolated struct FIFQuickLookSummary: Sendable {
    var displayName: String
    var kind: FIFDocument.Kind
    var fileSizeBytes: Int64
    var isCompressed: Bool
    /// Blocks present, for the detail strip and the fallback outline.
    var outline: [FIFDocument.BlockCount]
    var tagCount: Int
    var values: [FIFDocument.Value]
    var largestTagName: String?
    var largestTagBytes: Int?
    var warnings: [String]

    var recording: Recording?
    var headModel: HeadModel?
    var transform: Transform?
    var digitization: Digitization?

    // MARK: Recording

    struct Recording: Sendable {
        struct Channel: Sendable, Identifiable {
            var name: String
            var kindName: String
            var isBad: Bool
            /// Unit-sphere direction, for the sensor-cap picture. `nil` when the
            /// file gives the channel no position.
            var direction: SIMD3<Double>?
            var id: String { name }
        }
        struct Marker: Sendable, Identifiable {
            var timeSeconds: Double
            var label: String
            /// Annotations and stimulus edges are drawn differently; they are
            /// different claims about the recording.
            var isAnnotation: Bool
            var id: String { "\(timeSeconds)-\(label)-\(isAnnotation)" }
        }
        struct Condition: Sendable, Identifiable {
            var name: String
            var count: Int
            var id: String { name }
        }
        /// One channel's trace, already decimated to the pixels available.
        struct Trace: Sendable, Identifiable {
            var name: String
            var values: [Float]
            var id: String { name }
        }

        var content: FIFRecording.Content
        var samplingRate: Double
        var durationSeconds: Double
        var sampleCount: Int
        var channels: [Channel]
        var brainChannelCount: Int
        var peripheralChannelCount: Int
        var stimulusChannelCount: Int
        var measurementDate: Date?
        var subject: String?
        var highpassHz: Double?
        var lowpassHz: Double?
        var projectorDescriptions: [String]
        var markers: [Marker]
        var conditions: [Condition]
        /// Continuous: the first seconds of a few channels. Epoched/averaged:
        /// every channel of each condition, i.e. a butterfly.
        var traces: [Trace]
        /// Butterfly traces grouped by condition, for epoched/averaged files.
        var conditionTraces: [[Trace]]
        /// Condition names in the order `conditionTraces` holds them — file
        /// order, which is *not* the alphabetical order `conditions` uses.
        var conditionTraceNames: [String]
        var traceSeconds: Double
        var traceStartSeconds: Double
        var isTruncated: Bool
        var amplitudeMicrovolts: Float
    }

    // MARK: Head model

    struct HeadModel: Sendable {
        struct Shell: Sendable, Identifiable {
            var name: String
            var conductivity: Double
            var vertexCount: Int
            var triangleCount: Int
            /// Cross-section outlines in a shared normalized box, so the shells
            /// nest on screen the way they nest in the head.
            var sagittal: [Contour]
            var axial: [Contour]
            var id: String { name }
        }
        /// One line segment of a slice outline, in 0…1 view coordinates.
        struct Contour: Sendable {
            var from: SIMD2<Double>
            var to: SIMD2<Double>
        }

        var shells: [Shell]
        var frameName: String
        var solver: String?
        var approximation: String?
        var hasSolution: Bool
        var solutionSize: Int?
        var solutionBytes: Int?
        /// The quality report, so a broken model says so in Quick Look rather
        /// than at import time.
        var checks: [Check]
        struct Check: Sendable, Identifiable {
            var name: String
            var severity: String
            var detail: String
            var id: String { name }
        }
    }

    // MARK: Transform

    struct Transform: Sendable {
        var fromFrame: String
        var toFrame: String
        var matrix: [[Double]]
        var translationMillimetres: SIMD3<Double>
        var rotationDegrees: SIMD3<Double>
        var scale: Double
    }

    // MARK: Digitization

    struct Digitization: Sendable {
        struct Point: Sendable, Identifiable {
            var label: String
            var kindName: String
            /// Projected into 0…1 for the top and side views.
            var top: SIMD2<Double>
            var side: SIMD2<Double>
            var isFiducial: Bool
            var id: String { label }
        }
        var frameName: String
        var points: [Point]
        var counts: [(kind: String, count: Int)]
        var headWidthMillimetres: Double?
    }
}
