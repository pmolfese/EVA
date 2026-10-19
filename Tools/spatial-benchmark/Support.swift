// Minimal display-data adapters for compiling the production spatial builder
// outside the app. All scoring and tree construction use the actual source.
import Foundation
struct SensorPosition: Sendable { let channelIndex: Int; let x: Double; let y: Double }
struct SensorLayout: Sendable { let name: String; let positions: [SensorPosition] }
struct ArtifactReviewTopography: Sendable { let values: [Double]; let channelIndices: [Int] }
struct ArtifactReviewExample: Sendable {
    let id: String
    let topography: ArtifactReviewTopography?
    let hasCompleteWindow: Bool
}
