//
//  CIFTIQuickLookReader.swift
//  EVAPreviewKit
//
//  Native Swift CIFTI-2 reader. It reads the NIfTI-2 container and CIFTI XML,
//  then seeks only to a bounded set of matrix rows for visualization. Even a
//  dense connectome therefore has a small, predictable Quick Look footprint.
//

import Foundation

nonisolated enum CIFTIQuickLookReader {
    private static let ciftiExtensionCode = 32
    private static let maximumXMLBytes = 128 * 1024 * 1024
    private static let maximumSampleColumns = 512
    private static let maximumSampleRows = 192
    private static let maximumSampleInputBytes = 48 * 1024 * 1024
    private static let maximumWholeRowBytes = 8 * 1024 * 1024

    static func read(from url: URL) throws -> CIFTIPreviewModel {
        let name = url.lastPathComponent.lowercased()
        guard EVAPreviewFormat.isCIFTIFileName(name) else {
            throw CIFTIReadError.unsupportedFile(url)
        }
        guard !name.hasSuffix(".gz") else {
            throw CIFTIReadError.compressedUnsupported
        }

        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw CIFTIReadError.cannotOpen(url) }
        defer { try? handle.close() }

        let fileSize = fileByteSize(url)
        let firstFour = try read(handle, at: 0, count: 4, truncated: .truncatedHeader)
        let (version, byteOrder) = try NIfTIHeader.versionAndByteOrder(from: firstFour)
        guard version == .two else { throw CIFTIReadError.requiresNIfTI2 }
        var headerData = firstFour
        headerData.append(try read(
            handle, at: 4, count: version.byteCount - 4, truncated: .truncatedHeader
        ))
        let header = try NIfTIHeader.decode(headerData, version: version, byteOrder: byteOrder)
        let matrixDimensions = try validate(header: header, fileSize: fileSize)
        let xmlData = try readCIFTIXML(handle: handle, header: header)
        let document = try CIFTIXMLParser.parse(xmlData)
        try validate(mappings: document.mappings, dimensions: matrixDimensions)
        let sample = try readSample(
            handle: handle, header: header, dimensions: matrixDimensions
        )

        return CIFTIPreviewModel(
            url: url,
            header: header,
            ciftiVersion: document.version,
            metadata: document.metadata,
            matrixDimensions: matrixDimensions,
            mappings: document.mappings,
            sample: sample,
            byteSize: fileSize
        )
    }

    private static func validate(header: NIfTIHeader, fileSize: Int64) throws -> [Int] {
        guard header.magic.hasPrefix("n+2"), header.isSingleFile else {
            throw CIFTIReadError.invalidContainer("CIFTI-2 requires a single-file NIfTI-2 container")
        }
        guard (3000..<3100).contains(header.intentCode) else {
            throw CIFTIReadError.invalidIntent(header.intentCode)
        }
        guard header.dimensionCount == 6 || header.dimensionCount == 7,
              header.dimensions.count == 8,
              header.dimensions[1...4].allSatisfy({ $0 == 1 }) else {
            throw CIFTIReadError.invalidDimensions(header.dimensions)
        }
        let rawDimensions = header.dimensions[5...header.dimensionCount]
        guard rawDimensions.allSatisfy({ $0 > 0 && $0 <= Int64(Int.max) }) else {
            throw CIFTIReadError.invalidDimensions(header.dimensions)
        }
        guard let expectedBits = header.dataType.supportedScalarBitCount,
              header.bitpix == expectedBits else {
            throw CIFTIReadError.unsupportedDataType(header.dataType.displayName)
        }
        guard header.voxelOffset >= 544, header.voxelOffset <= fileSize else {
            throw CIFTIReadError.invalidVoxelOffset(header.voxelOffset)
        }

        let dimensions = rawDimensions.map(Int.init)
        var valueCount: Int64 = 1
        for dimension in dimensions {
            let (next, overflow) = valueCount.multipliedReportingOverflow(by: Int64(dimension))
            guard !overflow else { throw CIFTIReadError.matrixTooLarge }
            valueCount = next
        }
        let (dataBytes, overflow) = valueCount.multipliedReportingOverflow(by: Int64(header.bytesPerVoxel))
        guard !overflow, dataBytes <= fileSize - header.voxelOffset else {
            throw CIFTIReadError.truncatedMatrix
        }
        return dimensions
    }

    private static func validate(mappings: [CIFTIMapping], dimensions: [Int]) throws {
        for dimension in dimensions.indices {
            let matches = mappings.filter { $0.dimensions.contains(dimension) }
            guard matches.count == 1 else {
                throw CIFTIReadError.invalidXML("matrix dimension \(dimension) must have exactly one mapping")
            }
            let mapping = matches[0]
            if mapping.type != .unknown, mapping.length != dimensions[dimension] {
                throw CIFTIReadError.mappingLengthMismatch(
                    dimension: dimension, expected: dimensions[dimension], actual: mapping.length
                )
            }
        }
        let invalid = mappings.flatMap(\.dimensions).contains { !dimensions.indices.contains($0) }
        guard !invalid else { throw CIFTIReadError.invalidXML("mapping references a missing matrix dimension") }
    }

    private static func readCIFTIXML(handle: FileHandle, header: NIfTIHeader) throws -> Data {
        let extender = try read(handle, at: 540, count: 4, truncated: .truncatedExtensions)
        guard extender.first != 0 else { throw CIFTIReadError.missingXML }

        var offset: Int64 = 544
        while offset + 8 <= header.voxelOffset {
            let extensionHeader = try read(
                handle, at: offset, count: 8, truncated: .truncatedExtensions
            )
            let size = extensionHeader.withUnsafeBytes {
                Int(Int32(bitPattern: uint32($0, at: 0, order: header.byteOrder)))
            }
            let code = extensionHeader.withUnsafeBytes {
                Int(Int32(bitPattern: uint32($0, at: 4, order: header.byteOrder)))
            }
            guard size >= 8, size.isMultiple(of: 16), Int64(size) <= header.voxelOffset - offset else {
                throw CIFTIReadError.invalidExtensionSize(size)
            }
            if code == ciftiExtensionCode {
                let payloadCount = size - 8
                guard payloadCount <= maximumXMLBytes else { throw CIFTIReadError.xmlTooLarge }
                var payload = try read(
                    handle, at: offset + 8, count: payloadCount, truncated: .truncatedExtensions
                )
                while payload.last == 0 { payload.removeLast() }
                guard !payload.isEmpty else { throw CIFTIReadError.missingXML }
                return payload
            }
            offset += Int64(size)
        }
        throw CIFTIReadError.missingXML
    }

    private static func readSample(
        handle: FileHandle,
        header: NIfTIHeader,
        dimensions: [Int]
    ) throws -> CIFTIMatrixSample {
        let columnCount = dimensions[0]
        var rowCount = 1
        for dimension in dimensions.dropFirst() {
            let (next, overflow) = rowCount.multipliedReportingOverflow(by: dimension)
            guard !overflow else { throw CIFTIReadError.matrixTooLarge }
            rowCount = next
        }
        let (rowBytes, rowOverflow) = columnCount.multipliedReportingOverflow(by: header.bytesPerVoxel)
        guard !rowOverflow else { throw CIFTIReadError.matrixTooLarge }

        let sourceColumns = sampledIndices(count: columnCount, limit: maximumSampleColumns)
        let inputBoundRows = rowBytes > 0 ? max(maximumSampleInputBytes / rowBytes, 1) : 1
        let sourceRows = sampledIndices(
            count: rowCount,
            limit: min(maximumSampleRows, inputBoundRows)
        )
        var values = [Double]()
        values.reserveCapacity(sourceColumns.count * sourceRows.count)
        let slope = header.effectiveSlope
        let intercept = header.effectiveIntercept

        for row in sourceRows {
            let rowOffset = try checkedOffset(
                base: header.voxelOffset,
                elementIndex: row,
                stride: rowBytes
            )
            if rowBytes <= maximumWholeRowBytes {
                let data = try read(handle, at: rowOffset, count: rowBytes, truncated: .truncatedMatrix)
                data.withUnsafeBytes { bytes in
                    for column in sourceColumns {
                        let raw = NIfTIScalarDecoder.value(
                            from: bytes,
                            at: column * header.bytesPerVoxel,
                            type: header.dataType,
                            byteOrder: header.byteOrder
                        )
                        values.append(raw * slope + intercept)
                    }
                }
            } else {
                for column in sourceColumns {
                    let valueOffset = try checkedOffset(
                        base: rowOffset,
                        elementIndex: column,
                        stride: header.bytesPerVoxel
                    )
                    let data = try read(
                        handle, at: valueOffset, count: header.bytesPerVoxel,
                        truncated: .truncatedMatrix
                    )
                    let raw = data.withUnsafeBytes {
                        NIfTIScalarDecoder.value(
                            from: $0, at: 0, type: header.dataType, byteOrder: header.byteOrder
                        )
                    }
                    values.append(raw * slope + intercept)
                }
            }
        }
        return CIFTIMatrixSample(
            width: sourceColumns.count,
            height: sourceRows.count,
            sourceColumns: sourceColumns,
            sourceRows: sourceRows,
            values: values,
            window: intensityWindow(values)
        )
    }

    private static func sampledIndices(count: Int, limit: Int) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        guard count > limit else { return Array(0..<count) }
        guard limit > 1 else { return [count / 2] }
        let step = Double(count - 1) / Double(limit - 1)
        return (0..<limit).map { Int((Double($0) * step).rounded(.down)) }
    }

    private static func intensityWindow(_ values: [Double]) -> ClosedRange<Double> {
        let finite = values.filter(\.isFinite).sorted()
        guard let first = finite.first, let last = finite.last else { return 0...1 }
        let low = finite[Int(Double(finite.count - 1) * 0.02)]
        let high = finite[Int(Double(finite.count - 1) * 0.98)]
        if high > low { return low...high }
        let padding = max(abs(first) * 0.01, abs(last) * 0.01, 0.5)
        return (first - padding)...(last + padding)
    }

    private static func checkedOffset(base: Int64, elementIndex: Int, stride: Int) throws -> Int64 {
        let (delta, overflow) = Int64(elementIndex).multipliedReportingOverflow(by: Int64(stride))
        let (result, sumOverflow) = base.addingReportingOverflow(delta)
        guard !overflow, !sumOverflow else { throw CIFTIReadError.matrixTooLarge }
        return result
    }

    private static func read(
        _ handle: FileHandle,
        at offset: Int64,
        count: Int,
        truncated error: CIFTIReadError
    ) throws -> Data {
        guard offset >= 0, count >= 0 else { throw error }
        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: count), data.count == count else { throw error }
            return data
        } catch let readError as CIFTIReadError {
            throw readError
        } catch {
            throw CIFTIReadError.io(error.localizedDescription)
        }
    }

    private static func uint32(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int,
        order: NIfTIHeader.ByteOrder
    ) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[offset + index]) << UInt32(index * 8) }
        return order == .littleEndian ? value : value.byteSwapped
    }

    private static func fileByteSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}

nonisolated enum CIFTIReadError: LocalizedError, Sendable {
    case unsupportedFile(URL)
    case cannotOpen(URL)
    case compressedUnsupported
    case truncatedHeader
    case requiresNIfTI2
    case invalidContainer(String)
    case invalidIntent(Int)
    case invalidDimensions([Int64])
    case unsupportedDataType(String)
    case invalidVoxelOffset(Int64)
    case truncatedExtensions
    case invalidExtensionSize(Int)
    case missingXML
    case xmlTooLarge
    case invalidXML(String)
    case unsupportedVersion(String)
    case mappingLengthMismatch(dimension: Int, expected: Int, actual: Int)
    case matrixTooLarge
    case truncatedMatrix
    case io(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url): return "\(url.lastPathComponent) is not a recognized CIFTI file."
        case .cannotOpen(let url): return "Could not open \(url.lastPathComponent)."
        case .compressedUnsupported: return "CIFTI-2 Quick Look requires the standard uncompressed .nii storage for fast row access."
        case .truncatedHeader: return "The CIFTI NIfTI-2 header is truncated."
        case .requiresNIfTI2: return "CIFTI-2 must use a NIfTI-2 container."
        case .invalidContainer(let reason): return "Invalid CIFTI container: \(reason)"
        case .invalidIntent(let code): return "NIfTI intent code \(code) is not a CIFTI intent."
        case .invalidDimensions: return "The CIFTI matrix dimensions are invalid."
        case .unsupportedDataType(let type): return "Unsupported CIFTI matrix datatype \(type)."
        case .invalidVoxelOffset(let offset): return "Invalid CIFTI matrix offset \(offset)."
        case .truncatedExtensions: return "The CIFTI header extensions are truncated."
        case .invalidExtensionSize(let size): return "Invalid CIFTI header extension size \(size)."
        case .missingXML: return "The NIfTI-2 file has no CIFTI XML extension."
        case .xmlTooLarge: return "The CIFTI XML is too large to preview safely."
        case .invalidXML(let reason): return "Invalid CIFTI XML: \(reason)"
        case .unsupportedVersion(let version): return "CIFTI XML version \(version) is not supported."
        case .mappingLengthMismatch(let dimension, let expected, let actual):
            return "CIFTI mapping \(dimension) describes \(actual) indices; the matrix contains \(expected)."
        case .matrixTooLarge: return "The CIFTI matrix dimensions are too large to preview safely."
        case .truncatedMatrix: return "The CIFTI matrix data is truncated."
        case .io(let reason): return "Could not read the CIFTI file: \(reason)"
        }
    }
}
