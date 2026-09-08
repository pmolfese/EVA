//
//  MGHQuickLookReader.swift
//  EVAPreviewKit
//
//  Reads FreeSurfer MGH/MGZ independently of the NIfTI container reader. Like
//  the NIfTI Quick Look path, it retains only three center planes from frame 0.
//

import Foundation

nonisolated enum MGHQuickLookReader {
    private static let maximumRetainedSamples = 50_000_000

    static func read(from url: URL) throws -> MGHPreviewModel {
        let name = url.lastPathComponent.lowercased()
        guard name.hasSuffix(".mgh") || name.hasSuffix(".mgz") || name.hasSuffix(".mgh.gz") else {
            throw MGHReadError.unsupportedFile(url)
        }
        let compressed = name.hasSuffix(".mgz") || name.hasSuffix(".mgh.gz")
        let source: any NIfTIByteSource
        do {
            source = compressed ? try NIfTIGzipByteSource(url: url) : try NIfTIFileByteSource(url: url)
        } catch let error as NIfTIReadError {
            switch error {
            case .cannotOpen: throw MGHReadError.cannotOpen(url)
            case .invalidGzip(let reason): throw MGHReadError.invalidGzip(reason)
            default: throw MGHReadError.cannotOpen(url)
            }
        }

        let headerData: Data
        do { headerData = try source.readExactly(MGHHeader.byteCount) }
        catch { throw MGHReadError.truncatedHeader }
        let header = try MGHHeader.decode(headerData)
        try validate(header)
        let slices = try extractCenterSlices(header: header, source: source)
        let byteSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return MGHPreviewModel(
            url: url, header: header, slices: slices,
            intensityWindow: NIfTIIntensityWindow.make(slices: slices),
            byteSize: byteSize, isCompressed: compressed
        )
    }

    private static func validate(_ header: MGHHeader) throws {
        let dimensions = [header.width, header.height, header.depth]
        let products = [
            header.width.multipliedReportingOverflow(by: header.height),
            header.width.multipliedReportingOverflow(by: header.depth),
            header.height.multipliedReportingOverflow(by: header.depth)
        ]
        guard products.allSatisfy({ !$0.overflow }) else { throw MGHReadError.previewTooLarge }
        var retained = 0
        for product in products {
            let (sum, overflow) = retained.addingReportingOverflow(product.partialValue)
            guard !overflow, sum <= maximumRetainedSamples else { throw MGHReadError.previewTooLarge }
            retained = sum
        }
        let (planeSamples, sampleOverflow) = dimensions[0].multipliedReportingOverflow(by: dimensions[1])
        let (planeBytes, byteOverflow) = planeSamples.multipliedReportingOverflow(by: header.dataType.bytesPerVoxel)
        guard !sampleOverflow, !byteOverflow, planeBytes <= Int.max else {
            throw MGHReadError.previewTooLarge
        }
    }

    private static func extractCenterSlices(
        header: MGHHeader,
        source: any NIfTIByteSource
    ) throws -> [NIfTISlice] {
        let nx = header.width, ny = header.height, nz = header.depth
        let midX = nx / 2, midY = ny / 2, midZ = nz / 2
        var fixedZ = [Double](repeating: .nan, count: nx * ny)
        var fixedY = [Double](repeating: .nan, count: nx * nz)
        var fixedX = [Double](repeating: .nan, count: ny * nz)
        let slabByteCount = nx * ny * header.dataType.bytesPerVoxel

        for z in 0..<nz {
            let slab: Data
            do { slab = try source.readExactly(slabByteCount) }
            catch { throw MGHReadError.truncatedVoxelData }
            slab.withUnsafeBytes { bytes in
                @inline(__always) func value(x: Int, y: Int) -> Double {
                    NIfTIScalarDecoder.value(
                        from: bytes, at: (y * nx + x) * header.dataType.bytesPerVoxel,
                        type: header.dataType.niftiType, byteOrder: .bigEndian
                    )
                }
                if z == midZ {
                    for y in 0..<ny { for x in 0..<nx { fixedZ[y * nx + x] = value(x: x, y: y) } }
                }
                for x in 0..<nx { fixedY[z * nx + x] = value(x: x, y: midY) }
                for y in 0..<ny { fixedX[z * ny + y] = value(x: midX, y: y) }
            }
        }

        let native = [
            NativeSlice(axes: [1, 2], sizes: [ny, nz], values: fixedX),
            NativeSlice(axes: [0, 2], sizes: [nx, nz], values: fixedY),
            NativeSlice(axes: [0, 1], sizes: [nx, ny], values: fixedZ)
        ]
        return canonicalSlices(header: header, nativeSlices: native)
    }

    private static func canonicalSlices(header: MGHHeader, nativeSlices: [NativeSlice]) -> [NIfTISlice] {
        let orientations = header.affine?.axisOrientations ?? [
            NIfTIHeader.Affine.AxisOrientation(worldAxis: 0, isPositive: true),
            NIfTIHeader.Affine.AxisOrientation(worldAxis: 1, isPositive: true),
            NIfTIHeader.Affine.AxisOrientation(worldAxis: 2, isPositive: true)
        ]
        func voxelAxis(for worldAxis: Int) -> Int {
            orientations.firstIndex(where: { $0.worldAxis == worldAxis }) ?? worldAxis
        }
        func make(
            _ plane: NIfTISlice.Plane, fixedWorld: Int, horizontalWorld: Int, verticalWorld: Int,
            labels: (String, String, String, String)
        ) -> NIfTISlice {
            let fixedAxis = voxelAxis(for: fixedWorld)
            let horizontalAxis = voxelAxis(for: horizontalWorld)
            let verticalAxis = voxelAxis(for: verticalWorld)
            let source = nativeSlices[fixedAxis]
            let dimensions = [header.width, header.height, header.depth]
            let width = dimensions[horizontalAxis], height = dimensions[verticalAxis]
            var values = [Double](repeating: .nan, count: width * height)
            for targetY in 0..<height {
                let sourceY = orientations[verticalAxis].isPositive ? targetY : height - targetY - 1
                for targetX in 0..<width {
                    let sourceX = orientations[horizontalAxis].isPositive ? targetX : width - targetX - 1
                    let first = source.axes[0] == horizontalAxis ? sourceX : sourceY
                    let second = source.axes[0] == horizontalAxis ? sourceY : sourceX
                    values[targetY * width + targetX] = source.values[second * source.sizes[0] + first]
                }
            }
            return NIfTISlice(
                plane: plane, width: width, height: height,
                horizontalSpacing: header.voxelSizes[horizontalAxis],
                verticalSpacing: header.voxelSizes[verticalAxis], values: values,
                leftLabel: labels.0, rightLabel: labels.1,
                topLabel: labels.2, bottomLabel: labels.3
            )
        }
        return [
            make(.axial, fixedWorld: 2, horizontalWorld: 0, verticalWorld: 1, labels: ("L", "R", "A", "P")),
            make(.coronal, fixedWorld: 1, horizontalWorld: 0, verticalWorld: 2, labels: ("L", "R", "S", "I")),
            make(.sagittal, fixedWorld: 0, horizontalWorld: 1, verticalWorld: 2, labels: ("P", "A", "S", "I"))
        ]
    }

    private struct NativeSlice {
        let axes: [Int]
        let sizes: [Int]
        let values: [Double]
    }
}
