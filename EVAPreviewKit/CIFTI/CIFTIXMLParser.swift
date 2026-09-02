//
//  CIFTIXMLParser.swift
//  EVAPreviewKit
//
//  Streaming interpretation of the CIFTI-2 XML extension. Large vertex and
//  voxel index lists are deliberately not retained for a matrix Quick Look;
//  their declared ranges are enough to summarize brainordinate structure.
//

import Foundation

nonisolated struct CIFTIXMLDocument: Sendable {
    let version: String
    let metadata: [String: String]
    let mappings: [CIFTIMapping]
}

nonisolated enum CIFTIXMLParser {
    static func parse(_ data: Data) throws -> CIFTIXMLDocument {
        let parser = XMLParser(data: data)
        let delegate = CIFTIXMLDelegate()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            if let failure = delegate.failure { throw failure }
            throw CIFTIReadError.invalidXML(parser.parserError?.localizedDescription ?? "unknown XML error")
        }
        return try delegate.document()
    }
}

private nonisolated struct CIFTIMappingDraft {
    let dimensions: [Int]
    let type: CIFTIMappingType
    let numberOfSeriesPoints: Int?
    let seriesStart: Double?
    let seriesStep: Double?
    let seriesUnit: String?
    var namedMaps: [CIFTINamedMap] = []
    var namedMapCount = 0
    var brainModels: [CIFTIBrainModel] = []
    var brainModelLength = 0
    var parcelNames: [String] = []
    var parcelCount = 0

    var length: Int {
        switch type {
        case .brainModels: return brainModelLength
        case .parcels: return parcelCount
        case .series: return numberOfSeriesPoints ?? 0
        case .scalars, .labels: return namedMapCount
        case .unknown: return 0
        }
    }

    func finalized() -> CIFTIMapping {
        CIFTIMapping(
            dimensions: dimensions,
            type: type,
            length: length,
            namedMaps: namedMaps,
            brainModels: brainModels,
            parcelNames: parcelNames,
            seriesStart: seriesStart,
            seriesStep: seriesStep,
            seriesUnit: seriesUnit
        )
    }
}

private nonisolated final class CIFTIXMLDelegate: NSObject, XMLParserDelegate {
    private static let maximumRetainedNames = 4_096
    private static let maximumLabelsPerMap = 16_384
    private static let maximumRetainedLabels = 65_536
    private static let maximumTextCharacters = 8 * 1024 * 1024

    private(set) var failure: CIFTIReadError?
    private var sawRoot = false
    private var version = ""
    private var matrixMetadata: [String: String] = [:]
    private var mappings: [CIFTIMapping] = []
    private var currentMapping: CIFTIMappingDraft?
    private var currentNamedMapName: String?
    private var currentLabels: [CIFTILabel] = []
    private var retainedLabelCount = 0
    private var pendingLabel: (key: Int, red: Double?, green: Double?, blue: Double?, alpha: Double?)?
    private var metadataName: String?
    private var metadataValue: String?
    private var elementStack: [String] = []
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        elementStack.append(elementName)
        text = ""
        do {
            switch elementName {
            case "CIFTI":
                sawRoot = true
                version = attributeDict["Version"] ?? ""
            case "MatrixIndicesMap":
                currentMapping = try makeMapping(attributeDict)
            case "BrainModel":
                guard currentMapping != nil else { throw CIFTIReadError.invalidXML("BrainModel outside MatrixIndicesMap") }
                let model = try makeBrainModel(attributeDict)
                let (length, overflow) = (currentMapping?.brainModelLength ?? 0)
                    .addingReportingOverflow(model.indexCount)
                guard !overflow else { throw CIFTIReadError.invalidXML("brain model length overflows") }
                currentMapping?.brainModelLength = length
                if (currentMapping?.brainModels.count ?? 0) < Self.maximumRetainedNames {
                    currentMapping?.brainModels.append(model)
                }
            case "Parcel":
                guard currentMapping != nil else { throw CIFTIReadError.invalidXML("Parcel outside MatrixIndicesMap") }
                currentMapping?.parcelCount += 1
                if let name = attributeDict["Name"], (currentMapping?.parcelNames.count ?? 0) < Self.maximumRetainedNames {
                    currentMapping?.parcelNames.append(name)
                }
            case "NamedMap":
                currentNamedMapName = nil
                currentLabels = []
            case "Label":
                guard let keyText = attributeDict["Key"], let key = Int(keyText) else {
                    throw CIFTIReadError.invalidXML("Label is missing an integer Key")
                }
                pendingLabel = (
                    key,
                    number(attributeDict["Red"]), number(attributeDict["Green"]),
                    number(attributeDict["Blue"]), number(attributeDict["Alpha"])
                )
            default: break
            }
        } catch let error as CIFTIReadError {
            fail(error, parser)
        } catch {
            fail(.invalidXML(error.localizedDescription), parser)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard failure == nil, let element = elementStack.last else { return }
        let captured = ["MapName", "Label", "Name", "Value"].contains(element)
        guard captured else { return }
        guard text.count + string.count <= Self.maximumTextCharacters else {
            fail(.invalidXML("CIFTI XML text is too large"), parser)
            return
        }
        text.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard failure == nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "MapName":
            currentNamedMapName = value
        case "Label":
            if let label = pendingLabel,
               currentLabels.count < Self.maximumLabelsPerMap,
               retainedLabelCount < Self.maximumRetainedLabels {
                currentLabels.append(CIFTILabel(
                    key: label.key, name: value,
                    red: label.red, green: label.green, blue: label.blue, alpha: label.alpha
                ))
                retainedLabelCount += 1
            }
            pendingLabel = nil
        case "NamedMap":
            if currentMapping != nil {
                currentMapping?.namedMapCount += 1
                if (currentMapping?.namedMaps.count ?? 0) < Self.maximumRetainedNames {
                    let fallback = "Map \(currentMapping?.namedMapCount ?? 1)"
                    let name = currentNamedMapName.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
                    currentMapping?.namedMaps.append(CIFTINamedMap(name: name, labels: currentLabels))
                }
            }
            currentNamedMapName = nil
            currentLabels = []
        case "Name":
            metadataName = value
        case "Value":
            metadataValue = value
        case "MD":
            if currentNamedMapName == nil, let name = metadataName, let value = metadataValue {
                matrixMetadata[name] = value
            }
            metadataName = nil
            metadataValue = nil
        case "MatrixIndicesMap":
            if let currentMapping { mappings.append(currentMapping.finalized()) }
            currentMapping = nil
        default: break
        }
        if !elementStack.isEmpty { elementStack.removeLast() }
        text = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if failure == nil { failure = .invalidXML(parseError.localizedDescription) }
    }

    func document() throws -> CIFTIXMLDocument {
        guard sawRoot else { throw CIFTIReadError.invalidXML("missing CIFTI root element") }
        guard version == "2" || version.hasPrefix("2.") else {
            throw CIFTIReadError.unsupportedVersion(version.isEmpty ? "unknown" : version)
        }
        guard !mappings.isEmpty else { throw CIFTIReadError.invalidXML("missing MatrixIndicesMap") }
        return CIFTIXMLDocument(version: version, metadata: matrixMetadata, mappings: mappings)
    }

    private func makeMapping(_ attributes: [String: String]) throws -> CIFTIMappingDraft {
        guard let rawDimensions = attributes["AppliesToMatrixDimension"] else {
            throw CIFTIReadError.invalidXML("MatrixIndicesMap is missing AppliesToMatrixDimension")
        }
        let dimensions = rawDimensions.split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !dimensions.isEmpty, dimensions.allSatisfy({ $0 >= 0 }) else {
            throw CIFTIReadError.invalidXML("invalid AppliesToMatrixDimension \(rawDimensions)")
        }
        guard let rawType = attributes["IndicesMapToDataType"] else {
            throw CIFTIReadError.invalidXML("MatrixIndicesMap is missing IndicesMapToDataType")
        }
        let exponent = Int(attributes["SeriesExponent"] ?? "0") ?? 0
        let multiplier = pow(10, Double(exponent))
        let start = number(attributes["SeriesStart"]).map { $0 * multiplier }
        let step = number(attributes["SeriesStep"]).map { $0 * multiplier }
        let count = attributes["NumberOfSeriesPoints"].flatMap(Int.init)
        return CIFTIMappingDraft(
            dimensions: dimensions,
            type: CIFTIMappingType(ciftiName: rawType),
            numberOfSeriesPoints: count,
            seriesStart: start,
            seriesStep: step,
            seriesUnit: attributes["SeriesUnit"]
        )
    }

    private func makeBrainModel(_ attributes: [String: String]) throws -> CIFTIBrainModel {
        guard let structure = attributes["BrainStructure"],
              let modelType = attributes["ModelType"],
              let offsetText = attributes["IndexOffset"], let offset = Int(offsetText), offset >= 0,
              let countText = attributes["IndexCount"], let count = Int(countText), count > 0 else {
            throw CIFTIReadError.invalidXML("invalid BrainModel attributes")
        }
        let vertexCount = attributes["SurfaceNumberOfVertices"].flatMap(Int.init)
        return CIFTIBrainModel(
            structure: structure,
            modelType: modelType,
            indexOffset: offset,
            indexCount: count,
            surfaceVertexCount: vertexCount
        )
    }

    private func number(_ text: String?) -> Double? {
        guard let text, let value = Double(text), value.isFinite else { return nil }
        return value
    }

    private func fail(_ error: CIFTIReadError, _ parser: XMLParser) {
        failure = error
        parser.abortParsing()
    }
}
