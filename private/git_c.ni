// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/**
 * @brief Hash borrowed origin bytes into caller storage without retaining pointers.
 * @returns 64 lowercase digest bytes on success, or a negative provider error.
 * @note Output capacity must include the terminator; the caller owns both buffers.
 */
pub @extern("C") func ngit_hash_bytes(data: *const int8, length: int32, output: *mut int8, capacity: int32) -> int32;
/**
 * @brief Prepare a repository using borrowed length-based paths and explicit transport controls.
 * @returns Zero for an existing repository, one for a staged clone, or a negative error.
 * @note Retains no path pointers. The caller owns clone publication and cleanup.
 */
pub @extern("C") func ngit_prepare_repository(
  origin: *const int8, origin_len: int32,
  repository: *const int8, repository_len: int32,
  clone: *const int8, clone_len: int32,
  offline: int32, timeout_ms: int32
) -> int32;
/**
 * @brief Export a bounded tree to a caller-owned stage using borrowed path/revision bytes.
 * @returns 105 bytes of commit/newline/digest framing, or a negative provider error.
 * @note Output and input arrays remain caller-owned; no native handle escapes the call.
 */
pub @extern("C") func ngit_export_snapshot(
  origin: *const int8, origin_len: int32,
  revision: *const int8, revision_len: int32,
  repository: *const int8, repository_len: int32,
  destination: *const int8, destination_len: int32,
  offline: int32, timeout_ms: int32,
  output: *mut int8, capacity: int32
) -> int32;
