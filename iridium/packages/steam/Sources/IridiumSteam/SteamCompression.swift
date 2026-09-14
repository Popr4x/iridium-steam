import Foundation
import Compression

enum SteamCompressionError: Error {
    case decodeFailed
    case sizeMismatch
}

/// Thin wrapper around Apple's Compression framework for one-shot buffer decode.
enum SteamCompression {
    static func decompress(_ input: Data, algorithm: compression_algorithm, expectedSize: Int) throws -> Data {
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { outPtr -> Int in
            input.withUnsafeBytes { inPtr -> Int in
                compression_decode_buffer(
                    outPtr.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    inPtr.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, algorithm
                )
            }
        }
        guard written == expectedSize else { throw SteamCompressionError.sizeMismatch }
        return output
    }
}

/// Decodes a classic ".lzma"/"lzma_alone" stream (1-byte properties + 4-byte little-endian
/// dictionary size + 8-byte little-endian uncompressed size header, then raw LZMA1 data),
/// using Apple's LZMA decoder which expects exactly this container.
enum SteamLZMA {
    static func decodeLZMAAlone(propByte: UInt8, dictSize: UInt32, uncompressedSize: UInt64, compressed: Data) throws -> Data {
        var header = Data()
        header.append(propByte)
        header.append(littleEndian: dictSize)
        header.append(littleEndian: UInt64(uncompressedSize))
        var framed = header
        framed.append(compressed)
        return try SteamCompression.decompress(framed, algorithm: COMPRESSION_LZMA, expectedSize: Int(uncompressedSize))
    }
}

enum SteamZipError: Error {
    case malformed
    case unsupportedMethod
}

/// Reads the single entry out of a minimal (non-multi-disk) PKZIP archive, as produced by
/// Steam's CDN for manifest downloads: one local file header, optionally deflate-compressed.
enum SteamZip {
    static func decompressSingleEntry(_ data: Data) throws -> Data {
        guard data.count >= 30 else { throw SteamZipError.malformed }
        let start = data.startIndex
        guard data[start] == 0x50, data[start + 1] == 0x4B, data[start + 2] == 0x03, data[start + 3] == 0x04 else {
            throw SteamZipError.malformed
        }
        func u16(_ offset: Int) -> UInt16 {
            data.subdata(in: (start + offset)..<(start + offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        }
        func u32(_ offset: Int) -> UInt32 {
            data.subdata(in: (start + offset)..<(start + offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        let method = u16(8)
        let compressedSize = Int(u32(18))
        let uncompressedSize = Int(u32(22))
        let filenameLength = Int(u16(26))
        let extraLength = Int(u16(28))
        let dataStart = start + 30 + filenameLength + extraLength
        guard dataStart + compressedSize <= data.endIndex else { throw SteamZipError.malformed }
        let compressedData = data.subdata(in: dataStart..<(dataStart + compressedSize))
        switch method {
        case 0: // stored
            return compressedData
        case 8: // deflate (raw, no zlib/gzip wrapper)
            return try SteamCompression.decompress(compressedData, algorithm: COMPRESSION_ZLIB, expectedSize: uncompressedSize)
        default:
            throw SteamZipError.unsupportedMethod
        }
    }
}
