import Foundation

actor InitialTiming {
    var seconds: Double = 0
    var cutSeconds: Double = 0
    func record(_ hierarchy: ArtifactSpatialHierarchy, start: ContinuousClock.Instant) {
        let cutStart = ContinuousClock.now
        let cut = hierarchy.targetCut(count: 2, cohesionRule: .tenthPercentile, outlierFloor: 0.60)
        cutSeconds = SpatialBenchmark.seconds(cutStart)
        seconds = SpatialBenchmark.seconds(start)
        if cut.groups.isEmpty { fatalError("Unexpected empty initial cut") }
    }
}

@main struct SpatialBenchmark {
    static func signature(_ hierarchy: ArtifactSpatialHierarchy) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        func add(_ value: UInt64) { hash = (hash ^ value) &* 1099511628211 }
        for node in hierarchy.nodes {
            add(UInt64(node.group.id))
            for event in node.group.eventIDs { for byte in event.utf8 { add(UInt64(byte)) } }
            for value in node.group.meanFeature { add(value.bitPattern) }
            for value in node.group.orientationSigns { add(UInt64(Int(value) + 1)) }
            add(node.group.minimumCorrelation.bitPattern)
            add(node.group.tenthPercentileCorrelation.bitPattern)
            add(node.group.medianCorrelation.bitPattern)
            for child in node.children { add(UInt64(child)) }
        }
        return hash
    }
    static func seconds(_ start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
    static func fixture(events: Int, sensors: Int) -> (SensorLayout, [ArtifactReviewExample]) {
        let positions = (0..<sensors).map { index -> SensorPosition in
            let angle = Double(index) * 2.399963229728653
            let radius = sqrt((Double(index) + 0.5) / Double(sensors))
            return SensorPosition(channelIndex: index, x: radius * cos(angle), y: radius * sin(angle))
        }
        let examples = (0..<events).map { event -> ArtifactReviewExample in
            let family = event % 3
            let values = positions.enumerated().map { channel, position in
                let angle = Double(family) * 1.1
                let field = position.x * cos(angle) + position.y * sin(angle)
                let noise = 0.16 * sin(Double((event + 1) * (channel + 3)) * 0.731)
                return (event % 2 == 0 ? 1.0 : -1.0) * (field + noise)
            }
            return ArtifactReviewExample(id: String(format: "event-%06d", event),
                topography: .init(values: values, channelIndices: Array(0..<sensors)), hasCompleteWindow: true)
        }
        return (SensorLayout(name: "synthetic disk", positions: positions), examples)
    }
    static func main() async {
        let events = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 300
        let sensors = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 128
        let repeats = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 3
        let (layout, examples) = fixture(events: events, sensors: sensors)
        print("metric,events,sensors,repeat,build_seconds,cut_seconds,nodes,signature,initial_ready_seconds,progressive_complete_seconds")
        for metric in ArtifactSpatialSimilarityMetric.allCases {
            for repeatIndex in 0..<repeats {
                let start = ContinuousClock.now
                guard let hierarchy = await ArtifactSpatialGrouping.build(examples: examples,
                    layout: layout, polarityMode: .ignoreGlobalPolarity, similarityMetric: metric) else { fatalError() }
                let build = seconds(start)
                let cutStart = ContinuousClock.now
                let cut = hierarchy.targetCut(count: 2, cohesionRule: .tenthPercentile, outlierFloor: 0.60)
                let cutTime = seconds(cutStart)
                var initialSeconds = 0.0, progressiveSeconds = 0.0
                #if PROGRESSIVE
                let timing = InitialTiming()
                let progressiveStart = ContinuousClock.now
                guard let progressive = await ArtifactSpatialGrouping.build(examples: examples,
                    layout: layout, polarityMode: .ignoreGlobalPolarity, similarityMetric: metric,
                    initialCut: .targetCount(2, .tenthPercentile), onInitialHierarchy: {
                        await timing.record($0, start: progressiveStart)
                    }) else { fatalError() }
                progressiveSeconds = seconds(progressiveStart)
                initialSeconds = await timing.seconds
                precondition(signature(progressive) == signature(hierarchy), "Progressive build changed final tree")
                #endif
                print("\(metric.rawValue),\(events),\(sensors),\(repeatIndex),\(build),\(cutTime),\(hierarchy.nodes.count),\(signature(hierarchy)),\(initialSeconds),\(progressiveSeconds)")
                // Keep the actual refinement result observable to the optimizer.
                if cut.groups.isEmpty { fatalError("Unexpected empty cut") }
                fflush(stdout)
            }
        }
    }
}
