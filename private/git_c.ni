// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Private provider ABI; all buffers are borrowed for one synchronous call. */
pub @extern("C") func ngit_hash_bytes(data: *const int8, length: int32, output: *mut int8, capacity: int32) -> int32;
/** @brief Prepare a bare repository at an explicit staging path; returns existing/staged status. */
pub @extern("C") func ngit_prepare_repository(
  origin: *const int8, origin_len: int32,
  repository: *const int8, repository_len: int32,
  clone: *const int8, clone_len: int32,
  offline: int32, timeout_ms: int32
) -> int32;
/** @brief Export a bounded Git tree to an explicit destination; returns commit/digest bytes. */
pub @extern("C") func ngit_export_snapshot(
  origin: *const int8, origin_len: int32,
  revision: *const int8, revision_len: int32,
  repository: *const int8, repository_len: int32,
  destination: *const int8, destination_len: int32,
  offline: int32, timeout_ms: int32,
  output: *mut int8, capacity: int32
) -> int32;
