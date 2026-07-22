#include "local_flow_c_api.h"
#include <stdlib.h>
#include <unistd.h>

/* ggml Metal aborts in __cxa_finalize when residency sets remain
 * (ggml_metal_rsets_free GGML_ASSERT count==0). Register last → run first on
 * exit() → _exit skips remaining C++ destructors. */
static inline void lf_die_clean(void) { _exit(0); }
static inline void lf_install_clean_die(void) { atexit(lf_die_clean); }
