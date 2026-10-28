#ifndef NGIT_PRIVATE_BRIDGE_H
#define NGIT_PRIVATE_BRIDGE_H
#include <stdint.h>
/* Private ABI: all inputs borrowed for the call; output belongs to the caller.
 * Returns output byte count, or a negative redacted status. No native object escapes. */
int32_t ngit_prepare_snapshot(const char *url, int32_t url_len,
    const char *rev, int32_t rev_len, const char *cache, int32_t cache_len,
    int32_t offline, int32_t timeout_ms, char *output, int32_t capacity);
#endif
