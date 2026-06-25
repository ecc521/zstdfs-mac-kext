import Foundation
import ArgumentParser
import CZstd

// APFS inline xattr record: 3,804 bytes total - 2 (xv_flags) - 16 (decmpfs header) = 3,786
// Route to type 200 only if the compressed payload fits in 3,786 bytes.
let XATTR_PAYLOAD_LIMIT = 3786
let CHUNK_SIZE = 256 * 1024

let DECMPFS_MAGIC: UInt32 = 0x636D7066
let TYPE_XATTR:   UInt32 = 200
let TYPE_RSRC:    UInt32 = 201
let UF_COMPRESSED: UInt32 = 0x20

struct Compress: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Compress a file in-place")

    @Option(name: .shortAndLong, help: "zstd compression level (1–22)")
    var level: Int = 19

    @Argument(help: "File to compress")
    var path: String

    func run() throws {
        let url = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: url)
        if original.isEmpty { return }

        guard let compressed = zstdCompress(original, level: level) else {
            fputs("\(path): zstd compress failed\n", stderr)
            throw ExitCode.failure
        }

        if compressed.count >= original.count {
            print("\(path): incompressible, skipping")
            return
        }

        if compressed.count <= XATTR_PAYLOAD_LIMIT {
            try writeType200(url: url, original: original, compressed: compressed)
            let ratio = Double(original.count) / Double(compressed.count + 16)
            print("\(path): type 200, \(original.count) → \(compressed.count + 16) bytes (\(String(format: "%.2f", ratio))x)")
        } else {
            let (rsrc, chunkCount) = try buildRsrcFork(original, level: level)
            try writeType201(url: url, uncompressedSize: original.count, rsrc: rsrc)
            let ratio = Double(original.count) / Double(rsrc.count + 16)
            print("\(path): type 201, \(original.count) → \(rsrc.count + 16) bytes (\(chunkCount) chunks, \(String(format: "%.2f", ratio))x)")
        }
    }
}

// MARK: - Format writers

func writeType200(url: URL, original: Data, compressed: Data) throws {
    let xattr = makeDecmpfsHeader(type: TYPE_XATTR, size: UInt64(original.count)) + compressed
    try setXattr(url: url, name: "com.apple.decmpfs", data: xattr)
    try applyCompressedFlag(url: url)
}

func writeType201(url: URL, uncompressedSize: Int, rsrc: Data) throws {
    let header = makeDecmpfsHeader(type: TYPE_RSRC, size: UInt64(uncompressedSize))
    try setXattr(url: url, name: "com.apple.decmpfs", data: header)
    try setXattr(url: url, name: "com.apple.ResourceFork", data: rsrc)
    try applyCompressedFlag(url: url)
}

// MARK: - Chunk table builder

// Always stores valid zstd frames — ZSTD_compress never fails on valid input.
// Storing raw bytes as a fallback would break the kext decompressor.
func buildRsrcFork(_ data: Data, level: Int) throws -> (Data, Int) {
    var chunks: [Data] = []
    var pos = data.startIndex

    while pos < data.endIndex {
        let end = data.index(pos, offsetBy: CHUNK_SIZE, limitedBy: data.endIndex) ?? data.endIndex
        let chunk = data[pos..<end]
        guard let c = zstdCompress(chunk, level: level) else {
            throw ValidationError("zstd chunk compression failed")
        }
        chunks.append(c)
        pos = end
    }

    // Table: table_size (4 bytes) + chunk_ends[N] (4 bytes each)
    let tableSize = UInt32((chunks.count + 1) * 4)
    var rsrc = Data()
    rsrc += withUnsafeBytes(of: tableSize.littleEndian) { Data($0) }

    var offset = tableSize
    for chunk in chunks {
        offset += UInt32(chunk.count)
        rsrc += withUnsafeBytes(of: offset.littleEndian) { Data($0) }
    }
    for chunk in chunks { rsrc += chunk }

    return (rsrc, chunks.count)
}

// MARK: - decmpfs header

func makeDecmpfsHeader(type: UInt32, size: UInt64) -> Data {
    var d = Data(count: 16)
    d.withUnsafeMutableBytes { ptr in
        ptr.storeBytes(of: DECMPFS_MAGIC.littleEndian, toByteOffset: 0, as: UInt32.self)
        ptr.storeBytes(of: type.littleEndian,          toByteOffset: 4, as: UInt32.self)
        ptr.storeBytes(of: size.littleEndian,          toByteOffset: 8, as: UInt64.self)
    }
    return d
}

// MARK: - xattr helpers

func setXattr(url: URL, name: String, data: Data) throws {
    let err = data.withUnsafeBytes { buf in
        setxattr(url.path, name, buf.baseAddress!, buf.count, 0, 0)
    }
    if err != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
}

func applyCompressedFlag(url: URL) throws {
    let path = url.path
    // Clear any existing flags first so we can truncate cleanly
    chflags(path, 0)
    let fd = open(path, O_WRONLY | O_TRUNC)
    if fd < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    close(fd)
    if chflags(path, UF_COMPRESSED) != 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno)!)
    }
}

// MARK: - zstd

func zstdCompress(_ data: Data, level: Int) -> Data? {
    let bound = ZSTD_compressBound(data.count)
    var out = Data(count: bound)
    let written = out.withUnsafeMutableBytes { dst -> Int in
        data.withUnsafeBytes { src -> Int in
            ZSTD_compress(dst.baseAddress!, dst.count,
                          src.baseAddress!, src.count,
                          Int32(level))
        }
    }
    guard written > 0, written <= bound else { return nil }
    out.count = written
    return out
}

func zstdDecompress(_ data: Data, uncompressedSize: Int) -> Data? {
    var out = Data(count: uncompressedSize)
    let written = out.withUnsafeMutableBytes { dst -> Int in
        data.withUnsafeBytes { src -> Int in
            ZSTD_decompress(dst.baseAddress!, dst.count,
                            src.baseAddress!, src.count)
        }
    }
    guard written == uncompressedSize else { return nil }
    return out
}
