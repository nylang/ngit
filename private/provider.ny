// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Typed adapters for bounded provider operations; no cache policy. */
module GitSnapshotProvider;
import "stdlib:stdlib.ny";
import "interface/git.ni";
import "public/git.ny";
import "private/git_c.ni";
import "private/result.ny";

func git_status_error(status: int32) -> GitError {
  if status == -2 {
    return GitError.UnsupportedOrigin;
  }

  if status == -3 {
    return GitError.CacheFailure;
  }

  if status == -4 {
    return GitError.RevisionUnavailable;
  }

  if status == -5 {
    return GitError.UnsupportedTree;
  }

  if status == -6 {
    return GitError.OfflineMiss;
  }

  if status == -9 {
    return GitError.UnsupportedObjectFormat;
  }

  return GitError.Transport;
}

// Copy native result bytes before their call-local array owner is released.
func git_copy_output(bytes: *const int8, count: int32) -> string {
  return string.ViewFrom(bytes, count).Substring(0, count);
}

/** @brief Hash exact origin bytes; caller chooses the store identity policy. */
pub func GitProviderDigest(origin: ref string) -> Result<string, GitError> {
  var bytes: owned <int8>[] = new <int8>[65];
  unsafe {
    let count: int32 = ngit_hash_bytes(origin.data as *const int8, origin.length, &mut bytes[0], 65);
    if count != 64 {
      return GitError.CacheFailure;
    }

    let result: Result<string, GitError> = git_copy_output(&bytes[0] as *const int8, count);
    return result;
  }
}

/** @brief Clone into a caller-owned path, or report that the repository exists. */
pub func GitProviderPrepare(
  origin: ref string,
  repository: ref string,
  clone: ref string,
  offline: bool,
  timeout_ms: int32
) -> Result<bool, GitError> {
  var offline_flag: int32 = 0;
  if offline {
    offline_flag = 1;
  }

  let status: int32 = ngit_prepare_repository(
    origin.data as *const int8, origin.length,
    repository.data as *const int8, repository.length,
    clone.data as *const int8, clone.length,
    offline_flag, timeout_ms
  );
  if status < 0 {
    return git_status_error(status);
  }

  if status > 1 {
    return GitError.InvalidResult;
  }

  let result: Result<bool, GitError> = status == 1;
  return result;
}

/** @brief Resolve/export one bounded tree; all returned snapshot strings are owned. */
pub func GitProviderExport(
  origin: ref string,
  revision: ref string,
  repository: ref string,
  destination: ref string,
  offline: bool,
  timeout_ms: int32
) -> Result<GitSnapshot, GitError> {
  var bytes: owned <int8>[] = new <int8>[512];
  var offline_flag: int32 = 0;
  if offline {
    offline_flag = 1;
  }

  var count: int32 = 0;
  unsafe {
    count = ngit_export_snapshot(
      origin.data as *const int8, origin.length,
      revision.data as *const int8, revision.length,
      repository.data as *const int8, repository.length,
      destination.data as *const int8, destination.length,
      offline_flag, timeout_ms, &mut bytes[0], 512
    );
  }

  if count < 0 {
    return git_status_error(count);
  }

  if count != 105 {
    return GitError.InvalidResult;
  }

  var text: string = "";
  unsafe {
    text = git_copy_output(&bytes[0] as *const int8, count);
  }

  // Native output is only commit/digest; cache-relative paths are Nyra policy.
  let content: string = text.Slice(41, text.length);
  return GitDecodeSnapshot(
    text.Concat("\npackages/").Concat(content).Concat("/content"),
    revision
  );
}
