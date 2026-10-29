// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

#ifndef NGIT_PRIVATE_BRIDGE_H
#define NGIT_PRIVATE_BRIDGE_H
#include <stdint.h>
/* Private provider ABI. Paths/output are borrowed for one synchronous call.
 * prepare returns 0 for existing or 1 for a staged clone; negatives are errors.
 * export returns the byte count of commit\ndigest, or a negative provider error. */
int32_t ngit_hash_bytes(const char *bytes, int32_t length, char *output, int32_t capacity);
int32_t ngit_prepare_repository(const char *url, int32_t url_length, const char *repository,
                                int32_t repository_length, const char *clone, int32_t clone_length,
                                int32_t offline, int32_t timeout_ms);
int32_t ngit_export_snapshot(const char *url, int32_t url_length, const char *revision,
                             int32_t revision_length, const char *repository,
                             int32_t repository_length, const char *destination,
                             int32_t destination_length, int32_t offline, int32_t timeout_ms,
                             char *output, int32_t capacity);
#endif
