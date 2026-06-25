// Type 201: zstd-compressed resource-fork path (large files, 256 KB chunks).
//
// NOT YET IMPLEMENTED. The compressed data for type 201 lives in the
// com.apple.ResourceFork xattr, which the fetch callback must read itself —
// vnode_getxattr is not in the public KPI on macOS 26 (a kpi.private or
// VNOP_GETXATTR-based path is needed). Until that lands, registration of type
// 201 simply returns ENOTSUP from fetch so a stray type-201 file is a clean
// I/O error rather than a panic. The first milestone targets type 200 only.

#include "decmpfs_private.h"
#include <sys/errno.h>

int zstd201_validate(vnode_t vp, vfs_context_t ctx, decmpfs_header *hdr) {
    (void)vp; (void)ctx; (void)hdr;
    return 0;
}

int zstd201_fetch(vnode_t vp, vfs_context_t ctx, decmpfs_header *hdr,
                  off_t offset, user_ssize_t size, int nvec,
                  decmpfs_vector *vec, uint64_t *bytes_read) {
    (void)vp; (void)ctx; (void)hdr; (void)offset; (void)size;
    (void)nvec; (void)vec;
    if (bytes_read) *bytes_read = 0;
    return ENOTSUP;
}
