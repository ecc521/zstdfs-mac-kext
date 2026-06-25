// kernel_sym.c — resolve private decmpfs symbols by offset from a public anchor.
//
// register_decmpfs_decompressor / unregister_decmpfs_decompressor live only in
// com.apple.kpi.private. Rather than link that (which forces a com.apple bundle
// id that can't enter the AuxKC), we compute their addresses relative to IOLog,
// a public KPI function in the same kernel __TEXT_EXEC. The IOLog→target byte
// offset is fixed at kernel build time and survives KASLR slide and
// kernel-collection rebasing (both symbols move together as one blob).
//
// Offsets for kernel build 26.4 25E246 (arm64e), from KDK kernel.release.vmapple:
//   IOLog                            @ 0xfffffe0007a8cbc0
//   register_decmpfs_decompressor    @ 0xfffffe000758e998  (IOLog - 0x4fe228)
//   unregister_decmpfs_decompressor  @ 0xfffffe000758eae8  (IOLog - 0x4fe0d8)
//
// Safety: before calling, we verify the first two instructions at the computed
// address match the known prologue (pacibsp; sub sp,sp,#0xa0). A wrong offset
// therefore returns an error instead of branching into arbitrary kernel code.

#include <mach/mach_types.h>
#include <IOKit/IOLib.h>
#include <ptrauth.h>

#include "kernel_sym.h"

#define OFF_REGISTER    (-0x4fe228L)
#define OFF_UNREGISTER  (-0x4fe0d8L)

// arm64e instruction words at the start of both functions.
#define PROLOGUE_W0  0xd503237fu   // pacibsp
#define PROLOGUE_W1  0xd10283ffu   // sub sp, sp, #0xa0

static uintptr_t anchor_base(void) {
    // Strip PAC from &IOLog to get its raw (slid) text address.
    void *p = ptrauth_strip((void *)&IOLog, ptrauth_key_function_pointer);
    return (uintptr_t)p;
}

static int prologue_ok(uintptr_t addr) {
    const volatile uint32_t *w = (const volatile uint32_t *)addr;
    return w[0] == PROLOGUE_W0 && w[1] == PROLOGUE_W1;
}

// Call a resolved kernel function (uint32_t, ptr) -> int via a raw BLR.
// We must NOT use a C function pointer: on arm64e the compiler would emit an
// authenticated branch (blraa) expecting a PAC-signed pointer, but our computed
// address is unsigned. BLR branches to a raw address; the callee signs/auths its
// own return path, so this is correct.
static int call2(uintptr_t fn, uint64_t a0, uint64_t a1) {
    register uint64_t x0  __asm__("x0")  = a0;
    register uint64_t x1  __asm__("x1")  = a1;
    register uint64_t x16 __asm__("x16") = fn;
    __asm__ volatile(
        "blr x16"
        : "+r"(x0)
        : "r"(x1), "r"(x16)
        : "x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12",
          "x13","x14","x15","x17","x30","memory","cc",
          "v0","v1","v2","v3","v4","v5","v6","v7"
    );
    return (int)x0;
}

int decmpfs_register(uint32_t type, const decmpfs_registration_t *reg) {
    uintptr_t a = anchor_base() + OFF_REGISTER;
    if (!prologue_ok(a)) {
        IOLog("DecmpfsZstd: register_decmpfs_decompressor prologue check failed @ 0x%lx\n", a);
        return -1;
    }
    return call2(a, (uint64_t)type, (uint64_t)(uintptr_t)reg);
}

int decmpfs_unregister(uint32_t type, decmpfs_registration_t *reg) {
    uintptr_t a = anchor_base() + OFF_UNREGISTER;
    if (!prologue_ok(a)) {
        IOLog("DecmpfsZstd: unregister_decmpfs_decompressor prologue check failed @ 0x%lx\n", a);
        return -1;
    }
    return call2(a, (uint64_t)type, (uint64_t)(uintptr_t)reg);
}
