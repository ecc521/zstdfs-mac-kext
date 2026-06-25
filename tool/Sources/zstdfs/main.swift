import Foundation
import ArgumentParser

struct ZstdFS: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "zstdfs",
        abstract: "Compress files for transparent kernel decompression via decmpfs types 200/201",
        subcommands: [Compress.self, Decompress.self, Info.self, Verify.self, Tree.self]
    )
}

ZstdFS.main()
