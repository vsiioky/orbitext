// On ARM, rlottie expects two symbols from its NEON code path, which is
// pixman assembly the Apple toolchain does not build. These definitions keep
// the generic renderers and supply a portable fill.
#ifdef __ARM_NEON__

#include <algorithm>

#include "vdrawhelper.h"

void memfill32(uint32_t *dest, uint32_t value, int length)
{
    if (length > 0) {
        std::fill_n(dest, length, value);
    }
}

void RenderFuncTable::neon()
{
    // No NEON-specific blend functions: the defaults set up earlier stay.
}

#endif // __ARM_NEON__
