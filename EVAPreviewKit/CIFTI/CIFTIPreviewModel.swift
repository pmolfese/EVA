//
//  CIFTIPreviewModel.swift
//  EVAPreviewKit
//

import Foundation

nonisolated enum CIFTIMappingType: String, Sendable, Equatable {
    case brainModels = "CIFTI_INDEX_TYPE_BRAIN_MODELS"
    case parcels = "CIFTI_INDEX_TYPE_PARCELS"
    case series = "CIFTI_INDEX_TYPE_SERIES"
    case scalars = "CIFTI_INDEX_TYPE_SCALARS"
    case labels = "CIFTI_INDEX_TYPE_LABELS"
    case unknown

    init(ciftiName: String) {
        self = CIFTIMappingType(rawValue: ciftiName) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .brainModels: return "Brainordinates"
        case .parcels: return "Parcels"
        case .series: return "Series"
        case .scalars: return "Scalar Maps"
        case .labels: return "Label Maps"
        case .unknown: return "Unknown Mapping"
        }
    }
}

nonisolated struct CIFTILabel: Sendable, Equatable {
    let key: Int
    let name: String
    let red: Double?
    let green: Double?
    let blue: Double?
    let alpha: Double?
}

nonisolated struct CIFTINamedMap: Sendable, Equatable {
    let name: String
    let labels: [CIFTILabel]
}

nonisolated struct CIFTIBrainModel: Sendable, Equatable {
    let structure: String
    let modelType: String
    let indexOffset: Int
    let indexCount: Int
    let surfaceVertexCount: Int?

    var structureDisplayName: String {
        structure
            .replacingOccurrences(of: "CIFTI_STRUCTURE_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    var isSurface: Bool { modelType == "CIFTI_MODEL_TYPE_SURFACE" }
}

nonisolated struct CIFTIMapping: Sendable, Equatable, Identifiable {
    let dimensions: [Int]
    let type: CIFTIMappingType
    let length: Int
    let namedMaps: [CIFTINamedMap]
    let brainModels: [CIFTIBrainModel]
    let parcelNames: [String]
    let seriesStart: Double?
    let seriesStep: Double?
    let seriesUnit: String?

    var id: String { dimensions.map(String.init).joined(separator: ",") }

    var detailText: String {
        switch type {
        case .series:
            guard let seriesStep else { return length.formatted() }
            let unit = seriesUnit.map { " \($0.lowercased())" } ?? ""
            return "\(length.formatted()) • step \(short(seriesStep))\(unit)"
        case .brainModels:
            return "\(length.formatted()) • \(brainModels.count.formatted()) structures"
        case .parcels:
            return "\(length.formatted()) parcels"
        case .scalars, .labels:
            return "\(length.formatted()) maps"
        case .unknown:
            return length.formatted()
        }
    }

    private func short(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(3...5)))
    }
}

nonisolated struct CIFTIMatrixSample: Sendable {
    let width: Int
    let height: Int
    let sourceColumns: [Int]
    let sourceRows: [Int]
    let values: [Double]
    let window: ClosedRange<Double>

    var isEmpty: Bool { width == 0 || height == 0 || values.isEmpty }
}

nonisolated struct CIFTIPreviewModel: Sendable {
    let url: URL
    let header: NIfTIHeader
    let ciftiVersion: String
    let metadata: [String: String]
    let matrixDimensions: [Int]
    let mappings: [CIFTIMapping]
    let sample: CIFTIMatrixSample
    let byteSize: Int64

    var displayName: String { url.lastPathComponent }

    var fileKind: String {
        switch header.intentCode {
        case 3001: return "Dense Connectivity"
        case 3002: return "Dense Data Series"
        case 3003: return "Parcellated Connectivity"
        case 3004: return "Parcellated Data Series"
        case 3006: return "Dense Scalar"
        case 3007: return "Dense Label"
        case 3008: return "Parcellated Scalar"
        case 3009: return "Parcel-to-Dense Connectivity"
        case 3010: return "Dense-to-Parcel Connectivity"
        case 3011: return "Parcellated Connectivity Series"
        case 3012: return "Parcellated Connectivity Scalar"
        default: return inferredFileKind
        }
    }

    var dimensionsText: String {
        matrixDimensions.map { $0.formatted() }.joined(separator: " × ")
    }

    func mapping(for dimension: Int) -> CIFTIMapping? {
        mappings.first { $0.dimensions.contains(dimension) }
    }

    var horizontalAxisTitle: String {
        mapping(for: 0)?.type.displayName ?? "Dimension 1"
    }

    var verticalAxisTitle: String {
        guard matrixDimensions.count > 1 else { return "Rows" }
        if matrixDimensions.count == 2 {
            return mapping(for: 1)?.type.displayName ?? "Dimension 2"
        }
        return (1..<matrixDimensions.count)
            .map { mapping(for: $0)?.type.displayName ?? "Dimension \($0 + 1)" }
            .joined(separator: " × ")
    }

    var isLabelData: Bool {
        mappings.contains { $0.type == .labels }
    }

    var labelMaps: [CIFTINamedMap] {
        mappings.first { $0.type == .labels }?.namedMaps ?? []
    }

    var structureNames: [String] {
        var seen = Set<String>()
        return mappings.flatMap(\.brainModels).compactMap { model in
            let name = model.structureDisplayName
            return seen.insert(name).inserted ? name : nil
        }
    }

    private var inferredFileKind: String {
        let types = mappings.map(\.type)
        if types.contains(.labels) { return "CIFTI Label Data" }
        if types.contains(.series) { return "CIFTI Data Series" }
        if types.contains(.scalars) { return "CIFTI Scalar Data" }
        if types.filter({ $0 == .brainModels || $0 == .parcels }).count >= 2 {
            return "CIFTI Connectivity"
        }
        return "CIFTI Matrix"
    }
}
