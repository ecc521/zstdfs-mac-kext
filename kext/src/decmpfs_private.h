#pragma once

// decmpfs private KPI — recovered ABI for macOS 26.4 (build 25E246, arm64e VM).
//
// These declarations are NOT in any public/KDK header (bsd/sys/decmpfs.h is
// KERNEL_PRIVATE and not shipped). Every field offset, type signature, struct
// size, version value, and PAC discriminator below was recovered empirically
// from KDK_26.4_25E246's kernel.release.vmapple and its DWARF dSYM:
//
//   register_decmpfs_decompressor   @ 0xfffffe000758e998  (S, exported via kpi.private)
//   unregister_decmpfs_decompressor @ 0xfffffe000758eae8
//   decompressor table _decompressors @ 0xfffffe0007d1eef0  (256 slots, type<<3)
//   per-field accessor              @ 0xfffffe000758dea0
//
// Source of truth: DWARF struct `decmpfs_registration` (bsd/sys/decmpfs.h:268),
// byte_size 0x30; struct `decmpfs_header` (decmpfs.h:140), byte_size 0x14.
//
// Linkage: the register/unregister symbols come from com.apple.kpi.private
// (see Info.plist OSBundleLibraries). No runtime address resolution needed.

#include <sys/types.h>
#include <sys/vnode.h>
#include <ptrauth.h>

// ---------------------------------------------------------------------------
// decmpfs_header — 20 bytes (0x14). Passed by the kernel to every callback.
//
// IMPORTANT: there is a leading `attr_size` field. The on-disk decmpfs xattr
// (magic/type/uncompressed_size + inline data) is mapped at offset +0x04, and
// any inline compressed payload begins at offset +0x14 (NOT +0x10).
// ---------------------------------------------------------------------------
typedef struct __attribute__((packed)) {
    uint32_t attr_size;            // 0x00  size of the attribute (excludes this field)
    uint32_t compression_magic;    // 0x04  0x636d7066 'cmpf' (bytes "fpmc")
    uint32_t compression_type;     // 0x08  200 or 201 for us
    uint64_t uncompressed_size;    // 0x0c  (union slot; logical size in bytes) — 4-byte aligned (packed)
    uint8_t  attr_bytes[];         // 0x14  inline attribute/compressed data
} decmpfs_header;

typedef decmpfs_header decmpfs_header_t;   // back-compat alias

#define DECMPFS_MAGIC               0x636d7066u   // 'cmpf'
#define DECMPFS_HEADER_INLINE_OFF   0x14          // offset of attr_bytes[]

// ---------------------------------------------------------------------------
// decmpfs_vector — 16 bytes. The `fetch` callback writes decompressed bytes
// into an array of these (scatter list), NOT into a uio.
// ---------------------------------------------------------------------------
typedef struct decmpfs_vector {
    void         *buf;             // 0x00  destination buffer
    user_ssize_t  size;            // 0x08  bytes available in buf
} decmpfs_vector;

// ---------------------------------------------------------------------------
// Callback signatures (exact, from DWARF subroutine types).
// ---------------------------------------------------------------------------
typedef int      (*decmpfs_validate_fn)    (vnode_t, vfs_context_t, decmpfs_header *);
typedef void     (*decmpfs_adjust_fetch_fn)(vnode_t, vfs_context_t, decmpfs_header *,
                                            off_t *offset, user_ssize_t *size);
typedef int      (*decmpfs_fetch_fn)       (vnode_t, vfs_context_t, decmpfs_header *,
                                            off_t offset, user_ssize_t size,
                                            int nvec, decmpfs_vector *vec,
                                            uint64_t *bytes_read);
typedef int      (*decmpfs_free_fn)        (vnode_t, vfs_context_t, decmpfs_header *);
typedef uint64_t (*decmpfs_flags_fn)       (vnode_t, vfs_context_t, decmpfs_header *);

// ---------------------------------------------------------------------------
// Per-field PAC discriminators.
//
// The kernel authenticates each stored callback pointer with:
//     autia x16, x17      ; key = IA (function-pointer key), modifier = x17
// where x17 = the bare discriminator below (NO address diversity). Therefore
// each field is qualified __ptrauth(ptrauth_key_function_pointer, 0, DISC) so
// the compiler signs our function pointers to match. A plain (unqualified)
// function pointer is signed with discriminator 0 and FAILS authentication
// (brk #0xc470 → kernel panic on first use).
// ---------------------------------------------------------------------------
#define DECMPFS_DISC_VALIDATE      0xbcad
#define DECMPFS_DISC_ADJUST_FETCH  0x3a83
#define DECMPFS_DISC_FETCH         0xc33d
#define DECMPFS_DISC_FREE          0xbcad
#define DECMPFS_DISC_GET_FLAGS     0xbcad

#define DECMPFS_PTRAUTH(disc) __ptrauth(ptrauth_key_function_pointer, 0, disc)

// ---------------------------------------------------------------------------
// decmpfs_registration — 48 bytes (0x30).
//
// Field 0 is the version int. The register function accepts a value V where
// (V | 2) == 3, i.e. V == 1 or V == 3. We register as version 1; with v1 the
// kernel only invokes fields up to offset 0x20 (free_data) — get_flags (0x28)
// is version-3 only. Any unused callback may be NULL (call sites null-check).
// ---------------------------------------------------------------------------
#define DECMPFS_REGISTRATION_VERSION 1

typedef struct {
    int                version;                                       // 0x00
    decmpfs_validate_fn     DECMPFS_PTRAUTH(DECMPFS_DISC_VALIDATE)     validate;     // 0x08
    decmpfs_adjust_fetch_fn DECMPFS_PTRAUTH(DECMPFS_DISC_ADJUST_FETCH) adjust_fetch; // 0x10
    decmpfs_fetch_fn        DECMPFS_PTRAUTH(DECMPFS_DISC_FETCH)        fetch;        // 0x18
    decmpfs_free_fn         DECMPFS_PTRAUTH(DECMPFS_DISC_FREE)         free_data;    // 0x20
    decmpfs_flags_fn        DECMPFS_PTRAUTH(DECMPFS_DISC_GET_FLAGS)    get_flags;    // 0x28
} decmpfs_registration_t;                                            // sizeof == 0x30

_Static_assert(sizeof(decmpfs_registration_t) == 0x30, "decmpfs_registration must be 48 bytes");
_Static_assert(__builtin_offsetof(decmpfs_registration_t, fetch) == 0x18, "fetch must be at 0x18");
_Static_assert(__builtin_offsetof(decmpfs_registration_t, free_data) == 0x20, "free_data must be at 0x20");

// The register/unregister functions live only in com.apple.kpi.private. We do
// not link them — they are resolved at runtime in kernel_sym.c (see
// decmpfs_register/decmpfs_unregister there). Valid type range: 0..254;
// registration returns EEXIST(17) if the type slot is already taken.
