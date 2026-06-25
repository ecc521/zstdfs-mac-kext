// Type 200: zstd-compressed inline (xattr) path.
//
// For type 200 the entire file is one zstd frame stored inline in the
// com.apple.decmpfs xattr, immediately after the 16-byte on-disk header. The
// kernel hands us a decmpfs_header* whose attr_bytes[] (offset 0x14) is that
// frame; attr_size covers the 16 on-disk header bytes plus the frame, so the
// compressed length is (attr_size - 16).
//
// The `fetch` callback fills a scatter list (decmpfs_vector[]) with the
// requested [offset, offset+size) byte range of the decompressed file.

#include "decmpfs_private.h"
#include "zstd_ctx.h"
#include <sys/errno.h>
#include <IOKit/IOLib.h>

// On-disk decmpfs header is 16 bytes (magic+type+uncompressed_size); the inline
// compressed payload follows. attr_size in the in-memory header counts those 16
// bytes plus the payload.
#define DECMPFS_ONDISK_HEADER 16

int zstd200_validate(vnode_t vp, vfs_context_t ctx, decmpfs_header *hdr) {
    (void)vp; (void)ctx;
    if (hdr->compression_magic != DECMPFS_MAGIC) return EINVAL;
    if (hdr->compression_type != 200)            return EINVAL;
    if (hdr->attr_size < DECMPFS_ONDISK_HEADER)  return EINVAL;
    return 0;
}

int zstd200_fetch(vnode_t vp, vfs_context_t ctx, decmpfs_header *hdr,
                  off_t offset, user_ssize_t size, int nvec,
                  decmpfs_vector *vec, uint64_t *bytes_read) {
    (void)vp; (void)ctx;
    if (bytes_read) *bytes_read = 0;

    const uint64_t usize = hdr->uncompressed_size;
    if (offset < 0 || (uint64_t)offset > usize) return EINVAL;
    if (size < 0) return EINVAL;

    const uint8_t *payload  = hdr->attr_bytes;                       // +0x14
    const size_t   comp_len = (size_t)(hdr->attr_size - DECMPFS_ONDISK_HEADER);

    // Whole-file decompress into a scratch buffer, then scatter the requested
    // window. Type-200 files are small (compressed <= ~3.8 KB), so this is cheap.
    const size_t alloc = (size_t)(usize ? usize : 1);
    uint8_t *plain = (uint8_t *)IOMalloc(alloc);
    if (!plain) return ENOMEM;

    int produced = zstd_decompress(plain, (size_t)usize, payload, comp_len);
    if (produced < 0 || (uint64_t)produced != usize) {
        IOFree(plain, alloc);
        return EIO;
    }

    uint64_t want = (uint64_t)size;
    const uint64_t avail = usize - (uint64_t)offset;
    if (want > avail) want = avail;

    uint64_t copied = 0;
    const uint8_t *src = plain + offset;
    for (int i = 0; i < nvec && copied < want; i++) {
        if (!vec[i].buf || vec[i].size <= 0) continue;
        size_t chunk = (size_t)(want - copied);
        if ((user_ssize_t)chunk > vec[i].size) chunk = (size_t)vec[i].size;
        memcpy(vec[i].buf, src + copied, chunk);
        copied += chunk;
    }

    if (bytes_read) *bytes_read = copied;
    IOFree(plain, alloc);
    return 0;
}
