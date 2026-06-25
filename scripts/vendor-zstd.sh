#!/usr/bin/env bash
# Vendors zstd decompressor sources into kext/zstd/ for kernel-mode use.
# Pulls from facebook/zstd at a pinned tag.
#
# Usage: ./scripts/vendor-zstd.sh
#        (or: make vendor-zstd from kext/)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="$REPO_ROOT/kext/zstd"
ZSTD_TAG="v1.5.6"
TMP="$(mktemp -d)"

echo "Vendoring zstd $ZSTD_TAG → $DEST"

# Clone decompressor-relevant parts only (shallow, sparse)
git clone --depth 1 --branch "$ZSTD_TAG" \
    --filter=blob:none \
    --sparse \
    https://github.com/facebook/zstd.git "$TMP/zstd"

pushd "$TMP/zstd" > /dev/null
git sparse-checkout set lib/
popd > /dev/null

mkdir -p "$DEST"

# Copy header and implementation files needed for decompression
ZLIB="$TMP/zstd/lib"

# Public headers
cp "$ZLIB/zstd.h"        "$DEST/"
cp "$ZLIB/zstd_errors.h" "$DEST/"

# Common sources (decompression path only)
for f in \
    common/allocations.h \
    common/bits.h \
    common/bitstream.h \
    common/compiler.h \
    common/portability_macros.h \
    common/cpu.h \
    common/debug.c \
    common/debug.h \
    common/entropy_common.c \
    common/error_private.c \
    common/error_private.h \
    common/fse.h \
    common/fse_decompress.c \
    common/huf.h \
    common/mem.h \
    common/zstd_common.c \
    common/zstd_deps.h \
    common/zstd_internal.h \
    common/zstd_trace.h \
    common/xxhash.c \
    common/xxhash.h; do
    mkdir -p "$DEST/$(dirname "$f")"
    cp "$ZLIB/$f" "$DEST/$f"
done

# Decompress sources
for f in \
    decompress/huf_decompress.c \
    decompress/zstd_ddict.c \
    decompress/zstd_ddict.h \
    decompress/zstd_decompress.c \
    decompress/zstd_decompress_block.c \
    decompress/zstd_decompress_block.h \
    decompress/zstd_decompress_internal.h; do
    mkdir -p "$DEST/$(dirname "$f")"
    cp "$ZLIB/$f" "$DEST/$f"
done

# Kernel compatibility shim — must be included before any zstd header
cp "$REPO_ROOT/kext/zstd/zstd_kernel_compat.h" "$DEST/" 2>/dev/null || true

rm -rf "$TMP"

cat > "$DEST/zstd_kernel_compat.h" << 'EOF'
// zstd_kernel_compat.h — shims zstd's userspace deps to XNU kernel equivalents.
// Include path: compiler sees this via -Izstd; zstd_deps.h pulls it in when
// ZSTD_DEPS_CUSTOM is defined.
#pragma once

// XNU provides memcpy/memset/memmove via -fno-builtin + kernel headers
#include <string.h>
#include <sys/types.h>

// Kernel integer types
#include <stdint.h>
#include <stddef.h>

// Disable zstd's own malloc/free — we use static DCtx, so heap is never needed
// during decompression. Hitting these would indicate a configuration error.
#define ZSTD_malloc(s)    (panic("zstd malloc in kernel — static DCtx not used?"), (void*)0)
#define ZSTD_free(p, _)   (panic("zstd free in kernel"), (void)p)
#define ZSTD_calloc(n, s) (panic("zstd calloc in kernel"), (void*)0)

// assert → kernel panic with message
#include <kern/assert.h>
EOF

# Patch zstd_deps.h to use our kernel shim
DEPS="$DEST/common/zstd_deps.h"
if ! grep -q "ZSTD_DEPS_CUSTOM" "$DEPS"; then
    # Prepend the custom-deps guard at the top of the file
    TMP_DEPS="$(mktemp)"
    cat > "$TMP_DEPS" << 'PATCH'
/* Kernel build: redirect deps to our shim */
#ifdef KERNEL
#  define ZSTD_DEPS_CUSTOM
#  include "../zstd_kernel_compat.h"
#endif
PATCH
    cat "$TMP_DEPS" "$DEPS" > "${DEPS}.new" && mv "${DEPS}.new" "$DEPS"
    rm -f "$TMP_DEPS"
fi

echo "Done. Files in $DEST:"
find "$DEST" -type f | sed "s|$DEST/||" | sort
