// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Validate acquisition controls and start one Nyra-owned snapshot transaction. */
module GitSnapshotAcquisition;
import "stdlib:stdlib.ny";
import "interface/git.ni";
import "public/git.ny";
import "private/store.ny";

func git_error(error: GitError) -> Result<GitSnapshot, GitError> {
  let result: Result<GitSnapshot, GitError> = error;

  return result;
}

/** @brief Prepare a bounded immutable snapshot from borrowed inputs; failures are redacted. */
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
    return git_error(GitError.InvalidArgument);
  }

  return GitPrepareStoredSnapshot(origin, revision, store, offline, timeout_ms);
}
