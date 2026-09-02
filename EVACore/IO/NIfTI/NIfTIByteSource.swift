//
//  NIfTIByteSource.swift
//  EVAPreviewKit
//
//  Sequential input for plain and gzip-compressed NIfTI files. Gzip parsing is
//  Swift; the payload is streamed through Apple's raw-DEFLATE decoder. This
//  lets the reader stop after volume zero rather than expanding an entire 4D
//  dataset in a Quick Look process.
//

import Compression
import Foundation

nonisolated protocol NIfTIByteSource: AnyObject {
    func read(maxCount: Int) throws -> Data
}

nonisolated extension NIfTIByteSource {
    func readExactly(_ count: Int) throws -> Data {
        guard count >= 0 else { throw NIfTIReadError.truncatedVoxelData }
        if count == 0 { return Data() }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let chunk = try read(maxCount: count - result.count)
            guard !chunk.isEmpty else { throw NIfTIReadError.truncatedVoxelData }
            result.append(chunk)
        }
        return result
    }

    func skip(_ count: Int64) throws {
        guard count >= 0 else { throw NIfTIReadError.invalidVoxelOffset(count) }
        var remaining = count
        while remaining > 0 {
            let amount = Int(min(remaining, 64 * 1024))
            let chunk = try read(maxCount: amount)
            guard !chunk.isEmpty else { throw NIfTIReadError.truncatedVoxelData }
            remaining -= Int64(chunk.count)
        }
    }
}

nonisolated final class NIfTIFileByteSource: NIfTIByteSource {
    private let handle: FileHandle

    init(url: URL) throws {
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw NIfTIReadError.cannotOpen(url) }
    }

    deinit { try? handle.close() }

    func read(maxCount: Int) throws -> Data {
        guard maxCount > 0 else { return Data() }
        return try handle.read(upToCount: maxCount) ?? Data()
    }
}

nonisolated final class NIfTIGzipByteSource: NIfTIByteSource {
    private let handle: FileHandle
    private var filter: InputFilter<Data>!

    init(url: URL) throws {
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw NIfTIReadError.cannotOpen(url) }
        do {
            try Self.consumeGzipHeader(from: handle)
            let fileHandle = handle
            filter = try InputFilter(.decompress, using: .zlib, bufferCapacity: 1024 * 1024) { count in
                let data = try fileHandle.read(upToCount: count) ?? Data()
                return data.isEmpty ? nil : data
            }
        } catch let error as NIfTIReadError {
            try? handle.close()
            throw error
        } catch {
            try? handle.close()
            throw NIfTIReadError.invalidGzip(error.localizedDescription)
        }
    }

    deinit { try? handle.close() }

    func read(maxCount: Int) throws -> Data {
        guard maxCount > 0 else { return Data() }
        do { return try filter.readData(ofLength: maxCount) ?? Data() }
        catch { throw NIfTIReadError.invalidGzip(error.localizedDescription) }
    }

    private static func consumeGzipHeader(from handle: FileHandle) throws {
        guard let fixedHeader = try handle.read(upToCount: 10), fixedHeader.count == 10 else {
            throw NIfTIReadError.invalidGzip("truncated header")
        }
        let fixed = [UInt8](fixedHeader)

        func byte() throws -> UInt8 {
            guard let data = try handle.read(upToCount: 1), data.count == 1 else {
                throw NIfTIReadError.invalidGzip("truncated header")
            }
            return data[data.startIndex]
        }

        guard fixed[0] == 0x1f, fixed[1] == 0x8b else {
            throw NIfTIReadError.invalidGzip("missing gzip signature")
        }
        guard fixed[2] == 8 else {
            throw NIfTIReadError.invalidGzip("unsupported compression method")
        }
        let flags = fixed[3]
        guard flags & 0xe0 == 0 else {
            throw NIfTIReadError.invalidGzip("reserved flags are set")
        }

        if flags & 0x04 != 0 {
            let low = UInt16(try byte())
            let high = UInt16(try byte()) << 8
            for _ in 0..<Int(low | high) { _ = try byte() }
        }
        if flags & 0x08 != 0 { while try byte() != 0 {} }
        if flags & 0x10 != 0 { while try byte() != 0 {} }
        if flags & 0x02 != 0 { _ = try byte(); _ = try byte() }
    }
}
