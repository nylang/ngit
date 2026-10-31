// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Validate acquisition controls and start one Nyra-owned snapshot transaction. */
module GitSnapshotAcquisition;
import "stdlib:stdlib.ny";
import "interface/git.ni";
import "public/git.ny";
import "private/store.ny";

/** @brief Admit bounded caller controls and delegate one store transaction.
 * @returns An owned snapshot or a redacted GitError; native handles remain internal. */
pub static method(Git) PrepareSnapshot(
  origin: ref string,
  revision: ref string,
  store: ref string,
  offline: bool,
  timeout_ms: int32
) -> Result<GitSnapshot, GitError> {
  if origin.length == 0
    || revision.length == 0
    || store.length == 0
    || timeout_ms < 1
    || timeout_ms > 120000 {
    return Err<GitSnapshot, GitError>(GitError.InvalidArgument);
  }

  return GitStore.New(store, offline, timeout_ms).Prepare(origin, revision);
}
