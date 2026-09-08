//
//  NIfTIQuickLookReader.swift
//  EVAPreviewKit
//
//  Reads the header and only the three intersecting center planes from volume
//  zero. Memory therefore depends on image dimensions, not the number of time
//  points in a functional dataset.
//

import Foundation

nonisolated enum NIfTIQuickLookReader {
    private static let maximumRetainedSamples = 50_000_000

    static func read(from url: URL) throws -> NIfTIPreviewModel {
        let lowerName = url.lastPathComponent.lowercased()
        guard lowerName.hasSuffix(".nii") || lowerName.hasSuffix(".nii.gz") else {
            throw NIfTIReadError.unsupportedFile(url)
        }
        let compressed = lowerName.hasSuffix(".gz")
        let source: any NIfTIByteSource = compressed
            ? try NIfTIGzipByteSource(url: url)
            : try NIfTIFileByteSource(url: url)

        let firstFour: Data
        do { firstFour = try source.readExactly(4) }
        catch { throw NIfTIReadError.truncatedHeader }
        let (version, byteOrder) = try NIfTIHeader.versionAndByteOrder(from: firstFour)
        let rest: Data
        do { rest = try source.readExactly(version.byteCount - 4) }
        catch { throw NIfTIReadError.truncatedHeader }
        var headerData = firstFour
        headerData.append(rest)
        let header = try NIfTIHeader.decode(headerData, version: version, byteOrder: byteOrder)
        try validate(header)

        let bytesAlreadyRead = Int64(version.byteCount)
        try source.skip(header.voxelOffset - bytesAlreadyRead)
        let slices = try extractCenterSlices(header: header, source: source)
        let window = NIfTIIntensityWindow.make(header: header, slices: slices)
        let byteSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return NIfTIPreviewModel(
            url: url,
            header: header,
            slices: slices,
            intensityWindow: window,
            byteSize: byteSize,
            isCompressed: compressed
        )
    }

    private static func validate(_ header: NIfTIHeader) throws {
        guard header.magic.hasPrefix("n+1") || header.magic.hasPrefix("ni1")
                || header.magic.hasPrefix("n+2") || header.magic.hasPrefix("ni2") else {
            throw NIfTIReadError.invalidMagic(header.magic)
        }
        guard header.isSingleFile else { throw NIfTIReadError.pairedFileUnsupported }
        guard (1...7).contains(header.dimensionCount), header.dimensions.count == 8 else {
            throw NIfTIReadError.invalidDimensions(header.dimensions)
        }
        for dimension in header.dimensions[1...header.dimensionCount] {
            guard dimension > 0, dimension <= Int64(Int.max) else {
                throw NIfTIReadError.invalidDimensions(header.dimensions)
            }
        }
        guard header.width > 0, header.height > 0, header.depth > 0 else {
            throw NIfTIReadError.invalidDimensions(header.dimensions)
        }
        guard let expectedBits = header.dataType.supportedScalarBitCount else {
            throw NIfTIReadError.unsupportedScalarType(header.dataType.displayName)
        }
        guard header.bitpix == expectedBits else {
            throw NIfTIReadError.invalidBitpix(expected: expectedBits, actual: header.bitpix)
        }
        guard header.voxelOffset >= Int64(header.version.byteCount) else {
            throw NIfTIReadError.invalidVoxelOffset(header.voxelOffset)
        }

        let (xy, xyOverflow) = header.width.multipliedReportingOverflow(by: header.height)
        let (xz, xzOverflow) = header.width.multipliedReportingOverflow(by: header.depth)
        let (yz, yzOverflow) = header.height.multipliedReportingOverflow(by: header.depth)
        guard !xyOverflow, !xzOverflow, !yzOverflow else { throw NIfTIReadError.previewTooLarge }
        let (firstSum, sumOverflow) = xy.addingReportingOverflow(xz)
        let (sampleCount, secondOverflow) = firstSum.addingReportingOverflow(yz)
        guard !sumOverflow, !secondOverflow, sampleCount <= maximumRetainedSamples else {
            throw NIfTIReadError.previewTooLarge
        }
        let (_, rowOverflow) = header.width.multipliedReportingOverflow(by: header.bytesPerVoxel)
        let (planeBytes, planeOverflow) = xy.multipliedReportingOverflow(by: header.bytesPerVoxel)
        guard !rowOverflow, !planeOverflow, planeBytes <= Int.max else {
            throw NIfTIReadError.previewTooLarge
        }
    }

    private static func extractCenterSlices(
        header: NIfTIHeader,
        source: any NIfTIByteSource
    ) throws -> [NIfTISlice] {
        let nx = header.width, ny = header.height, nz = header.depth
        let midX = nx / 2, midY = ny / 2, midZ = nz / 2
        var fixedZ = [Double](repeating: .nan, count: nx * ny)
        var fixedY = [Double](repeating: .nan, count: nx * nz)
        var fixedX = [Double](repeating: .nan, count: ny * nz)
        let slabByteCount = nx * ny * header.bytesPerVoxel
        let slope = header.effectiveSlope
        let intercept = header.effectiveIntercept

        for z in 0..<nz {
            let slab: Data
            do { slab = try source.readExactly(slabByteCount) }
            catch { throw NIfTIReadError.truncatedVoxelData }
            slab.withUnsafeBytes { bytes in
                @inline(__always) func value(x: Int, y: Int) -> Double {
                    let offset = (y * nx + x) * header.bytesPerVoxel
                    return NIfTIScalarDecoder.value(
                        from: bytes,
                        at: offset,
                        type: header.dataType,
                        byteOrder: header.byteOrder
                    ) * slope + intercept
                }

                if z == midZ {
                    for y in 0..<ny {
                        for x in 0..<nx {
                            fixedZ[y * nx + x] = value(x: x, y: y)
                        }
                    }
                }
                for x in 0..<nx {
                    fixedY[z * nx + x] = value(x: x, y: midY)
                }
                for y in 0..<ny {
                    fixedX[z * ny + y] = value(x: midX, y: y)
                }
            }
        }

        let nativeSlices = [
            NIfTINativeSlice(axes: [1, 2], sizes: [ny, nz], values: fixedX),
            NIfTINativeSlice(axes: [0, 2], sizes: [nx, nz], values: fixedY),
            NIfTINativeSlice(axes: [0, 1], sizes: [nx, ny], values: fixedZ)
        ]
        return canonicalSlices(header: header, nativeSlices: nativeSlices)
    }

    private static func canonicalSlices(
        header: NIfTIHeader,
        nativeSlices: [NIfTINativeSlice]
    ) -> [NIfTISlice] {
        let orientations = header.affine?.axisOrientations ?? [
            NIfTIHeader.Affine.AxisOrientation(worldAxis: 0, isPositive: true),
            NIfTIHeader.Affine.AxisOrientation(worldAxis: 1, isPositive: true),
            NIfTIHeader.Affine.AxisOrientation(worldAxis: 2, isPositive: true)
        ]

        func voxelAxis(forWorldAxis worldAxis: Int) -> Int {
            orientations.firstIndex(where: { $0.worldAxis == worldAxis }) ?? worldAxis
        }

        func makeSlice(
            plane: NIfTISlice.Plane,
            fixedWorldAxis: Int,
            horizontalWorldAxis: Int,
            verticalWorldAxis: Int,
            labels: (left: String, right: String, top: String, bottom: String)
        ) -> NIfTISlice {
            let fixedVoxelAxis = voxelAxis(forWorldAxis: fixedWorldAxis)
            let horizontalVoxelAxis = voxelAxis(forWorldAxis: horizontalWorldAxis)
            let verticalVoxelAxis = voxelAxis(forWorldAxis: verticalWorldAxis)
            let source = nativeSlices[fixedVoxelAxis]
            let dimensions = [header.width, header.height, header.depth]
            let width = dimensions[horizontalVoxelAxis]
            let height = dimensions[verticalVoxelAxis]
            var values = [Double](repeating: .nan, count: width * height)

            for targetY in 0..<height {
                let sourceY = orientations[verticalVoxelAxis].isPositive
                    ? targetY : height - targetY - 1
                for targetX in 0..<width {
                    let sourceX = orientations[horizontalVoxelAxis].isPositive
                        ? targetX : width - targetX - 1
                    let first: Int
                    let second: Int
                    if source.axes[0] == horizontalVoxelAxis {
                        first = sourceX
                        second = sourceY
                    } else {
                        first = sourceY
                        second = sourceX
                    }
                    values[targetY * width + targetX] = source.values[second * source.sizes[0] + first]
                }
            }

            return NIfTISlice(
                plane: plane,
                width: width,
                height: height,
                horizontalSpacing: spacing(header, horizontalVoxelAxis + 1),
                verticalSpacing: spacing(header, verticalVoxelAxis + 1),
                values: values,
                leftLabel: labels.left,
                rightLabel: labels.right,
                topLabel: labels.top,
                bottomLabel: labels.bottom
            )
        }

        return [
            makeSlice(
                plane: .axial, fixedWorldAxis: 2,
                horizontalWorldAxis: 0, verticalWorldAxis: 1,
                labels: ("L", "R", "A", "P")
            ),
            makeSlice(
                plane: .coronal, fixedWorldAxis: 1,
                horizontalWorldAxis: 0, verticalWorldAxis: 2,
                labels: ("L", "R", "S", "I")
            ),
            makeSlice(
                plane: .sagittal, fixedWorldAxis: 0,
                horizontalWorldAxis: 1, verticalWorldAxis: 2,
                labels: ("P", "A", "S", "I")
            )
        ]
    }

    private struct NIfTINativeSlice {
        let axes: [Int]
        let sizes: [Int]
        let values: [Double]
    }

    private static func spacing(_ header: NIfTIHeader, _ index: Int) -> Double {
        guard header.pixelDimensions.indices.contains(index) else { return 1 }
        let value = abs(header.pixelDimensions[index])
        return value.isFinite && value > 0 ? value : 1
    }

}
