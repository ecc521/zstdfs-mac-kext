#pragma once
#include <stddef.h>

// Chunk size for type-201 (rsrc fork) compression.
// Stored as complete zstd frames — no magic stripping, ZSTD_decompress() takes
// the raw ZSTD_compress() output directly.
#define ZSTD_CHUNK_SIZE (256 * 1024)

// Upper bound on compressed chunk size: ZSTD_COMPRESSBOUND(ZSTD_CHUNK_SIZE).
// Formula: srcSize + (srcSize >> 8) + 64 for large inputs (>= 128 KB).
// Used to size the read buffer in type201 — must cover any valid stored frame.
#define ZSTD_CHUNK_MAX_COMP_SIZE (ZSTD_CHUNK_SIZE + (ZSTD_CHUNK_SIZE >> 8) + 64)

// Pool of N pre-allocated DCtx instances (~160 KB each).
// Sized for concurrent page-fault decompression on different files.
#define ZSTD_CTX_POOL_SIZE 4

int  zstd_ctx_pool_init(void);
void zstd_ctx_pool_free(void);

// Acquire a DCtx from the pool (blocks if all in use), decompress, release.
// Returns decompressed byte count, or negative errno on error.
int zstd_decompress(void *dst, size_t dst_cap,
                    const void *src, size_t src_size);
