import Foundation
import ArgumentParser

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show compression info for a file")

    @Argument var path: String

    func run() throws {
        let url = URL(fileURLWithPath: path)

        guard let xattrData = getXattr(url: url, name: "com.apple.decmpfs") else {
            print("\(path): not a compressed file")
            return
        }

        guard xattrData.count >= 16 else {
            print("\(path): decmpfs xattr too short")
            return
        }

        let magic = xattrData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
        let type  = xattrData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }
        let size  = xattrData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self).littleEndian }

        guard magic == DECMPFS_MAGIC else {
            print("\(path): bad decmpfs magic \(String(format: "%08x", magic))")
            return
        }

        print("path:             \(path)")
        print("type:             \(type) (\(typeName(type)))")
        print("uncompressed:     \(size) bytes")

        if type == TYPE_XATTR {
            let payloadSize = xattrData.count - 16
            let ratio = Double(size) / Double(payloadSize)
            print("compressed xattr: \(payloadSize) bytes (ratio \(String(format: "%.2f", ratio))x)")
        } else if type == TYPE_RSRC {
            if let rsrc = getXattr(url: url, name: "com.apple.ResourceFork"), rsrc.count >= 8 {
                let tableSize = rsrc.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
                let numChunks = Int(tableSize) / 4 - 1
                let ratio = Double(size) / Double(rsrc.count)
                print("rsrc fork:        \(rsrc.count) bytes, \(numChunks) chunks (ratio \(String(format: "%.2f", ratio))x)")
                print("chunk size:       \(CHUNK_SIZE / 1024) KB")
            }
        }
    }

    func typeName(_ t: UInt32) -> String {
        switch t {
        case TYPE_XATTR: return "zstd xattr"
        case TYPE_RSRC:  return "zstd rsrc"
        default:         return "unknown"
        }
    }
}

// MARK: - Decompress (in-place)

struct Decompress: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Decompress a file in-place")

    @Argument var path: String

    func run() throws {
        let url = URL(fileURLWithPath: path)

        guard let xattrData = getXattr(url: url, name: "com.apple.decmpfs"),
              xattrData.count >= 16 else {
            print("\(path): not a compressed file")
            return
        }

        let magic = xattrData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
        let type  = xattrData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }
        let size  = Int(xattrData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self).littleEndian })

        guard magic == DECMPFS_MAGIC else {
            fputs("\(path): bad decmpfs magic\n", stderr)
            throw ExitCode.failure
        }

        let plaintext: Data

        switch type {
        case TYPE_XATTR:
            let payload = xattrData.dropFirst(16)
            guard let d = zstdDecompress(payload, uncompressedSize: size) else {
                fputs("\(path): decompression failed\n", stderr)
                throw ExitCode.failure
            }
            plaintext = d

        case TYPE_RSRC:
            plaintext = try decompressRsrc(url: url, uncompressedSize: size)

        default:
            fputs("\(path): unknown compression type \(type)\n", stderr)
            throw ExitCode.failure
        }

        // Restore file
        chflags(url.path, 0)
        removexattr(url.path, "com.apple.decmpfs", 0)
        removexattr(url.path, "com.apple.ResourceFork", 0)
        try plaintext.write(to: url, options: .atomic)
        print("\(path): decompressed \(plaintext.count) bytes")
    }

    private func decompressRsrc(url: URL, uncompressedSize: Int) throws -> Data {
        guard let rsrc = getXattr(url: url, name: "com.apple.ResourceFork"),
              rsrc.count >= 8 else {
            fputs("\(url.path): no resource fork\n", stderr)
            throw ExitCode.failure
        }

        let tableSize = Int(rsrc.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian })
        let numChunks = tableSize / 4 - 1

        var chunkEnds = [Int](repeating: 0, count: numChunks)
        rsrc.withUnsafeBytes { ptr in
            for i in 0..<numChunks {
                chunkEnds[i] = Int(ptr.load(fromByteOffset: 4 + i * 4, as: UInt32.self).littleEndian)
            }
        }

        var out = Data()
        out.reserveCapacity(uncompressedSize)

        for i in 0..<numChunks {
            let start = i == 0 ? tableSize : chunkEnds[i - 1]
            let end   = chunkEnds[i]
            let comp  = rsrc[start..<end]
            let chunkPlainSize = min(CHUNK_SIZE, uncompressedSize - i * CHUNK_SIZE)
            guard let d = zstdDecompress(comp, uncompressedSize: chunkPlainSize) else {
                fputs("\(url.path): chunk \(i) decompression failed\n", stderr)
                throw ExitCode.failure
            }
            out.append(d)
        }
        return out
    }
}

// MARK: - Verify (non-destructive integrity check)

struct Verify: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Verify compressed file integrity (non-destructive)")

    @Argument var path: String

    func run() throws {
        let url = URL(fileURLWithPath: path)

        guard let xattrData = getXattr(url: url, name: "com.apple.decmpfs"),
              xattrData.count >= 16 else {
            print("\(path): not a compressed file")
            return
        }

        let magic = xattrData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self).littleEndian }
        let type  = xattrData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }
        let size  = Int(xattrData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self).littleEndian })

        guard magic == DECMPFS_MAGIC else {
            fputs("\(path): bad decmpfs magic\n", stderr)
            throw ExitCode.failure
        }

        let decompressed: Data

        switch type {
        case TYPE_XATTR:
            let payload = xattrData.dropFirst(16)
            guard let d = zstdDecompress(payload, uncompressedSize: size) else {
                fputs("\(path): FAIL — decompression error\n", stderr)
                throw ExitCode.failure
            }
            decompressed = d

        case TYPE_RSRC:
            decompressed = try Decompress().decompressRsrcForVerify(url: url, uncompressedSize: size)

        default:
            fputs("\(path): unknown type \(type)\n", stderr)
            throw ExitCode.failure
        }

        guard decompressed.count == size else {
            fputs("\(path): FAIL — got \(decompressed.count) bytes, expected \(size)\n", stderr)
            throw ExitCode.failure
        }

        print("\(path): OK (\(size) bytes, type \(type))")
    }
}

// Internal helper so Verify can call rsrc decode without side effects
private extension Decompress {
    func decompressRsrcForVerify(url: URL, uncompressedSize: Int) throws -> Data {
        try decompressRsrc(url: url, uncompressedSize: uncompressedSize)
    }
}

// MARK: - Tree (bulk compress)

struct Tree: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Bulk compress a directory tree")

    @Option(name: .shortAndLong) var level: Int = 19
    @Option(name: .shortAndLong) var jobs: Int = 8
    @Option(name: .long, help: "Minimum file size to compress (bytes)") var minSize: Int = 4096
    @Option(name: .long, parsing: .upToNextOption, help: "Paths to skip") var skip: [String] = []
    @Argument var paths: [String]

    func run() throws {
        let fm = FileManager.default
        var targets: [URL] = []

        for root in paths {
            let rootURL = URL(fileURLWithPath: root).standardizedFileURL
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                let filePath = url.standardizedFileURL.path

                // Skip subtrees and files matching the skip list
                if skip.contains(where: { filePath.hasPrefix($0) }) {
                    enumerator.skipDescendants()
                    continue
                }

                guard let attrs = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      attrs.isRegularFile == true,
                      attrs.isSymbolicLink != true,
                      let size = attrs.fileSize,
                      size >= minSize else { continue }

                // Skip already-compressed files
                if getXattr(url: url, name: "com.apple.decmpfs") != nil { continue }

                targets.append(url)
            }
        }

        print("Found \(targets.count) files to compress")

        let sema  = DispatchSemaphore(value: jobs)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "zstdfs.tree", attributes: .concurrent)
        let compressedCount = AtomicCounter()
        let skippedCount    = AtomicCounter()

        for url in targets {
            sema.wait()
            group.enter()
            let lvl = self.level
            queue.async {
                defer { sema.signal(); group.leave() }
                var cmd = Compress()
                cmd.level = lvl
                cmd.path  = url.path
                if let _ = try? cmd.run() {
                    compressedCount.increment()
                } else {
                    skippedCount.increment()
                }
            }
        }

        group.wait()
        print("Done: \(compressedCount.value) compressed, \(skippedCount.value) skipped/failed")
    }
}

// Minimal thread-safe counter using a lock
final class AtomicCounter {
    private var _value = 0
    private let lock = NSLock()
    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}

// MARK: - xattr helpers

// XATTR_SHOWCOMPRESSION bypasses the decmpfs intercept so we can read com.apple.decmpfs
// and com.apple.ResourceFork on files that already have UF_COMPRESSED set.
private let XATTR_SHOW_COMPRESSION: Int32 = 0x0020

func getXattr(url: URL, name: String) -> Data? {
    let size = getxattr(url.path, name, nil, 0, 0, XATTR_SHOW_COMPRESSION)
    guard size > 0 else { return nil }
    var buf = Data(count: size)
    let r = buf.withUnsafeMutableBytes {
        getxattr(url.path, name, $0.baseAddress!, size, 0, XATTR_SHOW_COMPRESSION)
    }
    return r > 0 ? buf : nil
}
