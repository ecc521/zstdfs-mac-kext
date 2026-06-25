#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>

extern "C" {
#include "decmpfs_private.h"
#include "kernel_sym.h"
#include "zstd_ctx.h"

int zstd200_validate(vnode_t, vfs_context_t, decmpfs_header *);
int zstd200_fetch   (vnode_t, vfs_context_t, decmpfs_header *,
                     off_t, user_ssize_t, int, decmpfs_vector *, uint64_t *);

int zstd201_validate(vnode_t, vfs_context_t, decmpfs_header *);
int zstd201_fetch   (vnode_t, vfs_context_t, decmpfs_header *,
                     off_t, user_ssize_t, int, decmpfs_vector *, uint64_t *);
}

class DecmpfsZstdService : public IOService {
    OSDeclareDefaultStructors(DecmpfsZstdService)
    typedef IOService super;  // macOS 26 SDK removed this from OSDeclareDefaultStructors
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
};

OSDefineMetaClassAndStructors(DecmpfsZstdService, IOService)

// Registration tables. version 1 → kernel uses validate/adjust_fetch/fetch/
// free_data (offsets 0x08/0x10/0x18/0x20); get_flags (0x28) is version-3 only.
// Function-pointer fields are PAC-signed automatically via the __ptrauth
// qualifiers in decmpfs_registration_t. Unused callbacks are NULL (the kernel
// null-checks each call site).
static decmpfs_registration_t reg200 = {
    .version      = DECMPFS_REGISTRATION_VERSION,
    .validate     = zstd200_validate,
    .adjust_fetch = nullptr,
    .fetch        = zstd200_fetch,
    .free_data    = nullptr,
    .get_flags    = nullptr,
};

static decmpfs_registration_t reg201 = {
    .version      = DECMPFS_REGISTRATION_VERSION,
    .validate     = zstd201_validate,
    .adjust_fetch = nullptr,
    .fetch        = zstd201_fetch,
    .free_data    = nullptr,
    .get_flags    = nullptr,
};

bool DecmpfsZstdService::start(IOService *provider) {
    if (!super::start(provider)) return false;

    if (zstd_ctx_pool_init() != 0) {
        IOLog("DecmpfsZstd: failed to allocate DCtx pool\n");
        super::stop(provider);
        return false;
    }

    int r200 = decmpfs_register(200, &reg200);
    int r201 = decmpfs_register(201, &reg201);
    if (r200 || r201) {
        IOLog("DecmpfsZstd: registration failed (200=%d 201=%d)\n", r200, r201);
        if (!r200) decmpfs_unregister(200, &reg200);
        if (!r201) decmpfs_unregister(201, &reg201);
        zstd_ctx_pool_free();
        super::stop(provider);
        return false;
    }

    IOLog("DecmpfsZstd: registered types 200, 201\n");
    return true;
}

void DecmpfsZstdService::stop(IOService *provider) {
    decmpfs_unregister(200, &reg200);
    decmpfs_unregister(201, &reg201);
    zstd_ctx_pool_free();
    IOLog("DecmpfsZstd: unregistered\n");
    super::stop(provider);
}
