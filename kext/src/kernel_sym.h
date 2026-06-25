#pragma once
#include "decmpfs_private.h"

// Path A: resolve the private decmpfs registration symbols at runtime.
// A non-apple kext cannot link com.apple.kpi.private (kmutil rejects it), and a
// com.apple-prefixed kext cannot be auto-loaded into the AuxKC ("apple-prefixed
// bundle without explicit auxiliary collection load requirement"). So instead of
// linking the symbols we compute their addresses from a public KPI anchor and
// call them directly. Each call is guarded by a function-prologue check, so a
// stale offset fails cleanly (returns error) rather than panicking.

int decmpfs_register  (uint32_t type, const decmpfs_registration_t *reg);
int decmpfs_unregister(uint32_t type, decmpfs_registration_t *reg);
