#include <mach/mach_types.h>

// _start / _stop are provided by libkmod (c_start.o / c_stop.o).
// They call _realmain / _antimain respectively; setting them to 0 lets
// IOKit's matching layer drive the kext lifecycle via IOService::start/stop.
extern kern_return_t _start(kmod_info_t *ki, void *data);
extern kern_return_t _stop(kmod_info_t *ki, void *data);

KMOD_EXPLICIT_DECL(io.zstdfs.DecmpfsZstd, "1.0.0", _start, _stop)

__private_extern__ kmod_start_func_t *_realmain  = 0;
__private_extern__ kmod_stop_func_t  *_antimain  = 0;
