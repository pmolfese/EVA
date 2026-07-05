//
//  MFFSignalSplitter.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//

import Foundation

nonisolated enum MFFSignalSplitSide: String, Sendable {
    case left
    case right

    var displayName: String {
        switch self {
        case .left:
            return "left"
        case .right:
            return "right"
        }
    }
}

nonisolated struct MFFSignalSplitSegment: Sendable {
    let side: MFFSignalSplitSide
    let signal: MFFSignalData
    let startSample: Int
    let endSampleExclusive: Int
    let startTimeSeconds: Double
    let endTimeSeconds: Double

    var sampleCount: Int {
        endSampleExclusive - startSample
    }
}

nonisolated struct MFFSignalSplitPair: Sendable {
    let boundarySample: Int
    let left: MFFSignalSplitSegment
    let right: MFFSignalSplitSegment
}

nonisolated enum MFFSignalSplitterError: LocalizedError {
    case emptySignal
    case invalidSamplingRate(Double)
    case inconsistentChannelLengths
    case invalidRange

    var errorDescription: String? {
        switch self {
        case .emptySignal:
            return "There are no samples to split."
        case .invalidSamplingRate(let rate):
            return "Cannot split a signal with invalid sampling rate \(rate)."
        case .inconsistentChannelLengths:
            return "Cannot split a signal whose channels have different lengths."
        case .invalidRange:
            return "The requested split range does not contain any samples."
        }
    }
}

nonisolated enum MFFSignalSplitter {
    static func split(signal: MFFSignalData, atSample requestedSample: Int) throws -> MFFSignalSplitPair {
        let sampleCount = try validatedSampleCount(signal)
        guard sampleCount > 1 else { throw MFFSignalSplitterError.emptySignal }

        let boundarySample = min(max(requestedSample, 1), sampleCount - 1)
        let left = try slice(
            signal: signal,
            startSample: 0,
            endSampleExclusive: boundarySample,
            side: .left
        )
        let right = try slice(
            signal: signal,
            startSample: boundarySample,
            endSampleExclusive: sampleCount,
            side: .right
        )
        return MFFSignalSplitPair(boundarySample: boundarySample, left: left, right: right)
    }

    static func slice(
        signal: MFFSignalData,
        startTimeSeconds: Double,
        endTimeSeconds: Double,
        side: MFFSignalSplitSide
    ) throws -> MFFSignalSplitSegment {
        let sampleCount = try validatedSampleCount(signal)
        let samplingRate = try validatedSamplingRate(signal)
        let lower = min(max(Int((startTimeSeconds * samplingRate).rounded()), 0), sampleCount)
        let upper = min(max(Int((endTimeSeconds * samplingRate).rounded()), lower), sampleCount)
        return try slice(signal: signal, startSample: lower, endSampleExclusive: upper, side: side)
    }

    private static func slice(
        signal: MFFSignalData,
        startSample: Int,
        endSampleExclusive: Int,
        side: MFFSignalSplitSide
    ) throws -> MFFSignalSplitSegment {
        let sampleCount = try validatedSampleCount(signal)
        let samplingRate = try validatedSamplingRate(signal)
        let lower = min(max(startSample, 0), sampleCount)
        let upper = min(max(endSampleExclusive, lower), sampleCount)
        guard upper > lower else { throw MFFSignalSplitterError.invalidRange }

        let sampleRange = lower..<upper
        let startTime = Double(lower) / samplingRate
        let endTime = Double(upper) / samplingRate
        let slicedData = signal.data.map { Array($0[sampleRange]) }
        let slicedEvents = signal.events.compactMap {
            shiftedEvent($0, fromStart: startTime, toEnd: endTime)
        }

        let splitSignal = MFFSignalData(
            signalURL: signal.signalURL,
            signalType: "\(signal.signalType) \(side.displayName.capitalized) Split",
            numberOfChannels: signal.numberOfChannels,
            samplingRate: signal.samplingRate,
            duration: endTime - startTime,
            recordingStartTime: signal.recordingStartTime?.addingTimeInterval(startTime),
            events: slicedEvents,
            data: slicedData,
            channelNames: signal.channelNames,
            epochSegments: [],
            isSegmented: false,
            isAveraged: false,
            impedancesKOhm: signal.impedancesKOhm
        )

        return MFFSignalSplitSegment(
            side: side,
            signal: splitSignal,
            startSample: lower,
            endSampleExclusive: upper,
            startTimeSeconds: startTime,
            endTimeSeconds: endTime
        )
    }

    private static func shiftedEvent(_ event: MFFEvent, fromStart start: Double, toEnd end: Double) -> MFFEvent? {
        guard event.beginTimeSeconds >= start, event.beginTimeSeconds < end else { return nil }
        let shiftedBegin = event.beginTimeSeconds - start
        let clippedDuration = event.durationSeconds.map {
            min($0, max(end - event.beginTimeSeconds, 0))
        }
        return MFFEvent(
            id: event.id,
            code: event.code,
            label: event.label,
            eventDescription: event.eventDescription,
            cell: event.cell,
            beginTimeSeconds: shiftedBegin,
            rawBeginTime: "",
            sourceFile: event.sourceFile,
            durationSeconds: clippedDuration
        )
    }

    private static func validatedSampleCount(_ signal: MFFSignalData) throws -> Int {
        guard signal.numberOfChannels > 0,
              signal.data.count == signal.numberOfChannels,
              let first = signal.data.first,
              !first.isEmpty else {
            throw MFFSignalSplitterError.emptySignal
        }
        let sampleCount = first.count
        guard signal.data.allSatisfy({ $0.count == sampleCount }) else {
            throw MFFSignalSplitterError.inconsistentChannelLengths
        }
        return sampleCount
    }

    private static func validatedSamplingRate(_ signal: MFFSignalData) throws -> Double {
        guard signal.samplingRate.isFinite, signal.samplingRate > 0 else {
            throw MFFSignalSplitterError.invalidSamplingRate(signal.samplingRate)
        }
        return signal.samplingRate
    }
}
