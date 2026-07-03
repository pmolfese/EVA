import Testing
import Foundation
@testable import EVA

struct ScratchReproTest {
    @Test func inspectRealFile() throws {
        let url = URL(fileURLWithPath: "/Users/molfesepj/Desktop/MFF_tests/NNU_Pilot02/NNU_Pilot02_run1b_20240708_104633.mff")
        let reader = MFFReader()
        let signal = try reader.loadSignal(from: url) { _ in }
        var report = "numberOfChannels=\(signal.numberOfChannels) data.count=\(signal.data.count) sampleCount=\(signal.data.first?.count ?? -1) samplingRate=\(signal.samplingRate) events=\(signal.events.count)\n"

        let geometry = ElectrodeGeometry.load(fromPackageContaining: signal.signalURL)
        report += "geometry=\(geometry != nil) positionsCount=\(geometry?.positions.count ?? -1)\n"
        if let geometry {
            let missing = signal.data.indices.filter { geometry.positions[$0] == nil }
            report += "channelsWithoutPosition=\(missing.count) sample=\(Array(missing.prefix(10)))\n"
            let maxKey = geometry.positions.keys.max() ?? -1
            let minKey = geometry.positions.keys.min() ?? -1
            report += "positionKeyRange=\(minKey)...\(maxKey) dataIndexRange=0...\(signal.data.count - 1)\n"
        }

        let eventCodes = Dictionary(grouping: signal.events, by: \.code).mapValues(\.count)
        report += "eventCodes=\(eventCodes)\n"

        Issue.record(Comment(rawValue: report))
        #expect(Bool(false), Comment(rawValue: report))
    }
}
