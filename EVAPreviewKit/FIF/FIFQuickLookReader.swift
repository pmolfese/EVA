//
//  FIFQuickLookReader.swift
//  EVAPreviewKit
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
//
//  Builds `FIFQuickLookSummary` from a file. Quick Look gets a couple of seconds
//  and no scroll bar, so this reads what the picture needs and stops: the first
//  few seconds of a recording rather than all of it, contours rather than whole
//  meshes, and — for a document EVA draws no picture for — nothing beyond the
//  block structure it already walked.
//

import Foundation
import simd

nonisolated enum FIFQuickLookReader {

    /// How much of a continuous recording the sparkline shows.
    static let previewSeconds = 10.0
    /// Traces are drawn a few hundred points wide; decimating to this before the
    /// view sees them keeps a 5000-sample preview from becoming a 5000-point path.
    static let traceResolution = 600
    /// Channels in the continuous sparkline, spread across the montage.
    static let traceChannelCount = 8

    static func read(from url: URL) throws -> FIFQuickLookSummary {
        let reader = try FIFReader(url: url)
        let outline = FIFDocument.outline(reader, filename: url.lastPathComponent)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)

        var summary = FIFQuickLookSummary(
            displayName: url.lastPathComponent,
            kind: outline.kind,
            fileSizeBytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
            isCompressed: url.pathExtension.lowercased() == "gz",
            outline: outline.blocks,
            tagCount: outline.tagCount,
            values: outline.values,
            largestTagName: outline.largestTag?.name,
            largestTagBytes: outline.largestTag?.bytes,
            warnings: [])

        switch outline.kind {
        case .continuousRecording, .epochedRecording, .averagedRecording:
            do { (summary.recording, summary.warnings) = try readRecording(url) }
            catch { summary.warnings = ["The recording could not be read: \(error.localizedDescription)"] }
        case .headModel:
            do { summary.headModel = try readHeadModel(url) }
            catch { summary.warnings = ["The head model could not be read: \(error.localizedDescription)"] }
        case .coordinateTransform:
            do { summary.transform = try readTransform(url) }
            catch { summary.warnings = ["The transform could not be read: \(error.localizedDescription)"] }
        case .digitization:
            do { summary.digitization = try readDigitization(reader) }
            catch { summary.warnings = ["The digitization could not be read: \(error.localizedDescription)"] }
        default:
            break
        }
        return summary
    }

    // MARK: - Recording

    private static func readRecording(_ url: URL) throws -> (FIFQuickLookSummary.Recording, [String]) {
        // Peek at the sampling rate first so the sample cap is a duration, not a
        // guess: 10 s is 2 500 samples at 250 Hz and 50 000 at 5 kHz.
        let rate = (try? FIFMeasurementInfo.read(FIFReader(url: url)).samplingRate) ?? 1000
        let recording = try FIFRecording.read(from: url, sampleLimit: Int(previewSeconds * rate))
        let info = recording.info
        let bads = Set(info.badChannels)

        let channels = info.channels.map { channel in
            FIFQuickLookSummary.Recording.Channel(
                name: channel.name,
                kindName: channel.kind?.displayName ?? "kind \(channel.rawKind)",
                isBad: bads.contains(channel.name),
                direction: channel.positionMeters.map { simd_normalize($0) })
        }

        var markers = recording.annotations.map {
            FIFQuickLookSummary.Recording.Marker(timeSeconds: $0.onsetSeconds, label: $0.description, isAnnotation: true)
        }
        var conditions: [FIFQuickLookSummary.Recording.Condition] = []
        var traces: [FIFQuickLookSummary.Recording.Trace] = []
        var conditionTraces: [[FIFQuickLookSummary.Recording.Trace]] = []
        var conditionTraceNames: [String] = []
        var duration = 0.0
        var sampleCount = 0
        var traceStart = 0.0
        var traceSpan = 0.0

        let brain = info.brainChannelIndices
        switch recording.content {
        case .continuous:
            // The whole file's length, not the length of the peek this preview
            // decoded — otherwise a 40-minute recording would claim to be ten
            // seconds long.
            sampleCount = recording.totalSampleCount
            duration = Double(sampleCount) / info.samplingRate
            // Stimulus edges, read the way `mne.find_events` reads them.
            for channel in info.stimulusChannelIndices {
                var previous = 0.0
                for (sample, raw) in recording.samples[channel].enumerated() {
                    let value = raw.rounded()
                    if value > previous, value != 0 {
                        markers.append(.init(timeSeconds: Double(sample) / info.samplingRate,
                                             label: String(Int(value)), isAnnotation: false))
                    }
                    previous = value
                }
            }
            // A spread of channels rather than the first eight, so a 128-channel
            // montage shows the whole head rather than one corner of it.
            let picks = spread(brain, count: traceChannelCount)
            traces = picks.map { index in
                .init(name: info.channels[index].name,
                      values: decimate(recording.samples[index], to: traceResolution, scale: microvoltScale(info.channels[index])))
            }
            // The timeline and the traces cover what was actually read.
            traceSpan = Double(recording.sampleCount) / info.samplingRate
        case .epoched, .averaged:
            sampleCount = recording.sampleCount * recording.segments.count
            duration = Double(sampleCount) / info.samplingRate
            traceStart = recording.segmentStartSeconds
            traceSpan = Double(recording.sampleCount) / info.samplingRate
            var counts: [String: Int] = [:]
            for segment in recording.segments {
                counts[segment.name, default: 0] += max(segment.contributingCount, 1)
            }
            conditions = counts.map { .init(name: $0.key, count: $0.value) }.sorted { $0.name < $1.name }

            // A butterfly per condition: every brain channel overlaid. For
            // epochs, average the epochs of each condition first — an ERP file
            // and an epoch file should read the same way at a glance.
            var byCondition: [String: [[Double]]] = [:]
            var conditionOrder: [String] = []
            for segment in recording.segments {
                if byCondition[segment.name] == nil {
                    byCondition[segment.name] = brain.map { segment.data[$0] }
                    conditionOrder.append(segment.name)
                } else {
                    for (row, index) in brain.enumerated() {
                        for sample in segment.data[index].indices {
                            byCondition[segment.name]![row][sample] += segment.data[index][sample]
                        }
                    }
                }
            }
            conditionTraceNames = conditionOrder
            for name in conditionOrder {
                let repeats = Double(recording.segments.filter { $0.name == name }.count)
                let rows = byCondition[name]!
                conditionTraces.append(rows.enumerated().map { row, values in
                    .init(name: info.channels[brain[row]].name,
                          values: decimate(values.map { $0 / repeats }, to: traceResolution,
                                           scale: microvoltScale(info.channels[brain[row]])))
                })
            }
        }

        var peak: Float = 0
        for trace in traces {
            for value in trace.values { peak = max(peak, abs(value)) }
        }
        for condition in conditionTraces {
            for trace in condition {
                for value in trace.values { peak = max(peak, abs(value)) }
            }
        }

        let summary = FIFQuickLookSummary.Recording(
            content: recording.content,
            samplingRate: info.samplingRate,
            durationSeconds: duration,
            sampleCount: sampleCount,
            channels: channels,
            brainChannelCount: brain.count,
            peripheralChannelCount: info.peripheralChannelIndices.count,
            stimulusChannelCount: info.stimulusChannelIndices.count,
            measurementDate: info.measurementDate,
            subject: info.subject,
            highpassHz: info.highpassHz,
            lowpassHz: info.lowpassHz,
            projectorDescriptions: info.projectors.map { $0.isActive ? "\($0.description) (active)" : $0.description },
            markers: markers.sorted { $0.timeSeconds < $1.timeSeconds },
            conditions: conditions,
            traces: traces,
            conditionTraces: conditionTraces,
            conditionTraceNames: conditionTraceNames,
            traceSeconds: traceSpan,
            traceStartSeconds: traceStart,
            isTruncated: recording.isTruncated,
            amplitudeMicrovolts: peak > 0 ? peak : 1)
        return (summary, recording.warnings)
    }

    /// Volts to microvolts for volt-unit channels; anything else keeps its own
    /// unit rather than being silently inflated a millionfold.
    private static func microvoltScale(_ channel: FIFChannelInfo) -> Double {
        channel.unit == FIF.unitVolts ? 1e6 : 1
    }

    private static func spread(_ indices: [Int], count: Int) -> [Int] {
        guard indices.count > count, count > 0 else { return indices }
        return (0..<count).map { indices[$0 * (indices.count - 1) / (count - 1)] }
    }

    /// Min/max decimation: keeps the extremes of each bucket, so a spike does
    /// not vanish between samples the way plain subsampling loses it.
    private static func decimate(_ values: [Double], to resolution: Int, scale: Double) -> [Float] {
        guard values.count > resolution * 2, resolution > 1 else {
            return values.map { Float($0 * scale) }
        }
        let bucket = Double(values.count) / Double(resolution)
        var output: [Float] = []
        output.reserveCapacity(resolution * 2)
        for i in 0..<resolution {
            let start = Int(Double(i) * bucket)
            let end = min(Int(Double(i + 1) * bucket), values.count)
            guard start < end else { continue }
            var low = values[start], high = values[start]
            for j in start..<end {
                low = min(low, values[j])
                high = max(high, values[j])
            }
            output.append(Float(low * scale))
            output.append(Float(high * scale))
        }
        return output
    }

    // MARK: - Head model

    private static func readHeadModel(_ url: URL) throws -> FIFQuickLookSummary.HeadModel {
        let geometry = try BEMGeometry.readFIF(from: url)
        let reader = try FIFReader(url: url)
        let bemTags = reader.blocks(kind: FIF.blockBEM).first ?? reader.tags
        let solutionTag = bemTags.first { $0.kind == FIF.bemPotSolution }

        // One shared box for every shell, so nesting is visible: scaling each
        // shell to its own bounds would draw three identical ovals.
        var lo = SIMD3<Double>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
        for shell in geometry.shells {
            let (shellLow, shellHigh) = shell.mesh.boundingBox
            lo = simd_min(lo, shellLow)
            hi = simd_max(hi, shellHigh)
        }
        let centre = (lo + hi) / 2
        let extent = max((hi - lo).max(), 1e-6)

        func normalize(_ point: SIMD3<Double>, _ a: Int, _ b: Int) -> SIMD2<Double> {
            SIMD2((point[a] - centre[a]) / extent + 0.5, 0.5 - (point[b] - centre[b]) / extent)
        }

        let shells = geometry.shells.map { shell -> FIFQuickLookSummary.HeadModel.Shell in
            // Slice through the middle of the whole model, not of each shell.
            let sagittal = shell.mesh.crossSection(axis: 0, offset: centre.x).map {
                FIFQuickLookSummary.HeadModel.Contour(from: normalize($0.0, 1, 2), to: normalize($0.1, 1, 2))
            }
            let axial = shell.mesh.crossSection(axis: 2, offset: centre.z).map {
                FIFQuickLookSummary.HeadModel.Contour(from: normalize($0.0, 0, 1), to: normalize($0.1, 0, 1))
            }
            return .init(name: shell.kind.displayName,
                         conductivity: shell.sigma,
                         vertexCount: shell.mesh.vertices.count,
                         triangleCount: shell.mesh.triangles.count,
                         sagittal: sagittal,
                         axial: axial)
        }

        let report = geometry.quality(checkSelfIntersection: false)
        let approximation: String? = geometry.provenance.approximation.map {
            $0 == 2 ? "linear collocation" : ($0 == 1 ? "constant collocation" : "method \($0)")
        }
        return .init(
            shells: shells,
            frameName: geometry.frame.displayName,
            solver: geometry.provenance.solver == .unknown ? nil : geometry.provenance.solver.rawValue,
            approximation: approximation,
            hasSolution: solutionTag != nil,
            solutionSize: (try? solutionTag?.matrixDimensions())??.first,
            solutionBytes: solutionTag?.data.count,
            checks: report.checks.map { .init(name: $0.name, severity: $0.severity.rawValue, detail: $0.detail) })
    }

    // MARK: - Transform

    private static func readTransform(_ url: URL) throws -> FIFQuickLookSummary.Transform {
        let transform = try HeadTransform.readFIF(from: url)
        let m = transform.matrix
        var rows = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        for r in 0..<4 { for c in 0..<4 { rows[r][c] = m[c][r] } }

        // Decompose so the numbers mean something without mental arithmetic:
        // how far the head moved and how far it turned.
        let x = SIMD3(m[0][0], m[0][1], m[0][2])
        let y = SIMD3(m[1][0], m[1][1], m[1][2])
        let z = SIMD3(m[2][0], m[2][1], m[2][2])
        let scale = (simd_length(x) + simd_length(y) + simd_length(z)) / 3
        let r = simd_double3x3(x / simd_length(x), y / simd_length(y), z / simd_length(z))
        // Intrinsic X-Y-Z Euler angles, the convention MNE reports coregistration in.
        let pitch = asin(max(-1, min(1, -r[2][0])))
        let yaw = atan2(r[1][0], r[0][0])
        let roll = atan2(r[2][1], r[2][2])
        let degrees = 180 / Double.pi

        return .init(
            fromFrame: transform.from.displayName,
            toFrame: transform.to.displayName,
            matrix: rows,
            translationMillimetres: SIMD3(m[3][0], m[3][1], m[3][2]) * 1000,
            rotationDegrees: SIMD3(roll * degrees, pitch * degrees, yaw * degrees),
            scale: scale)
    }

    // MARK: - Digitization

    private static func readDigitization(_ reader: FIFReader) throws -> FIFQuickLookSummary.Digitization {
        let digitization = try Digitization.read(reader)
        let positions = digitization.points.map(\.r)
        guard !positions.isEmpty else { throw FIF.Error.missing("digitization points") }

        var lo = SIMD3<Double>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let centre = (lo + hi) / 2
        let extent = max((hi - lo).max(), 1e-6)

        func normalize(_ point: SIMD3<Double>, _ a: Int, _ b: Int) -> SIMD2<Double> {
            SIMD2((point[a] - centre[a]) / extent * 0.9 + 0.5, 0.5 - (point[b] - centre[b]) / extent * 0.9)
        }

        var counts: [String: Int] = [:]
        let points = digitization.points.enumerated().map { index, point -> FIFQuickLookSummary.Digitization.Point in
            let kindName: String
            let isFiducial: Bool
            switch point.kind {
            case .cardinal:
                kindName = ["", "LPA", "nasion", "RPA"].indices.contains(Int(point.ident))
                    ? ["", "LPA", "nasion", "RPA"][Int(point.ident)] : "fiducial"
                isFiducial = true
            case .eeg: kindName = point.ident == 0 ? "reference" : "EEG"; isFiducial = false
            case .hpi: kindName = "HPI coil"; isFiducial = false
            case .extra: kindName = "head shape"; isFiducial = false
            }
            counts[kindName, default: 0] += 1
            return .init(label: "\(kindName) \(index)",
                         kindName: kindName,
                         top: normalize(point.r, 0, 1),
                         side: normalize(point.r, 1, 2),
                         isFiducial: isFiducial)
        }
        return .init(
            frameName: digitization.frame.displayName,
            points: points,
            counts: counts.map { (kind: $0.key, count: $0.value) }.sorted { $0.count > $1.count },
            headWidthMillimetres: (hi.x - lo.x) * 1000)
    }
}
