#include "zstd_ctx.h"
#include "../zstd/zstd.h"
#include <IOKit/IOLib.h>
#include <sys/errno.h>

// Pool of pre-allocated static DCtx workspaces (~160 KB each).
// IOLockTryLock gives us per-slot concurrency; IOSleep(0) yields on full contention.
// For burst reads across N files simultaneously, ZSTD_CTX_POOL_SIZE=4 is plenty.

typedef struct {
    void       *workspace;
    ZSTD_DCtx  *dctx;
    IOLock     *lock;
} zstd_slot_t;

static zstd_slot_t g_pool[ZSTD_CTX_POOL_SIZE];

int zstd_ctx_pool_init(void) {
    size_t ws_size = ZSTD_estimateDCtxSize();
    for (int i = 0; i < ZSTD_CTX_POOL_SIZE; i++) {
        g_pool[i].lock      = IOLockAlloc();
        g_pool[i].workspace = IOMalloc(ws_size);
        if (!g_pool[i].lock || !g_pool[i].workspace) return -1;
        g_pool[i].dctx = ZSTD_initStaticDCtx(g_pool[i].workspace, ws_size);
        if (!g_pool[i].dctx) return -1;
    }
    return 0;
}

void zstd_ctx_pool_free(void) {
    size_t ws_size = ZSTD_estimateDCtxSize();
    for (int i = 0; i < ZSTD_CTX_POOL_SIZE; i++) {
        if (g_pool[i].lock)      IOLockFree(g_pool[i].lock);
        if (g_pool[i].workspace) IOFree(g_pool[i].workspace, ws_size);
    }
}

int zstd_decompress(void *dst, size_t dst_cap,
                    const void *src, size_t src_size) {
    for (;;) {
        for (int i = 0; i < ZSTD_CTX_POOL_SIZE; i++) {
            if (IOLockTryLock(g_pool[i].lock)) {
                size_t r = ZSTD_decompressDCtx(g_pool[i].dctx,
                                                dst, dst_cap,
                                                src, src_size);
                IOLockUnlock(g_pool[i].lock);
                if (ZSTD_isError(r)) return -EIO;
                return (int)r;
            }
        }
        // All slots busy — yield and retry (extremely rare in practice)
        IOSleep(0);
    }
}
