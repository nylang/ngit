// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Typed adapters for bounded provider operations; no cache policy. */
module GitSnapshotProvider;
import "stdlib:stdlib.ny";
import "interface/git.ni";
import "public/git.ny";
import "private/git_c.ni";
import "private/result.ny";

/** @brief Native call controls; excludes cache paths, locking and package metadata. */
pub struct GitProvider {
  offline: bool;
  timeout_ms: int32;
}

/** @brief Configure the embedded provider without creating a native handle.
 * @returns A value retaining the explicit timeout/offline controls. */
pub static method(GitProvider) New(offline: bool, timeout_ms: int32) -> GitProvider {
  return GitProvider{offline: offline, timeout_ms: timeout_ms};
}

/** @brief Read the operation's network admission policy.
 * @returns True when this provider must avoid network acquisition. */
pub method(GitProvider) IsOffline() -> bool {
  return self.offline;
}

/** @brief Read the operation's bounded transport/lock timeout.
 * @returns The caller-selected millisecond bound. */
pub method(GitProvider) Timeout() -> int32 {
  return self.timeout_ms;
}

static method(GitError) FromProviderStatus(status: int32) -> GitError {
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
/** @brief Hash exact origin bytes for the selected cache identity.
 * @returns An owned lowercase digest, or CacheFailure for invalid native output. */
pub method(GitProvider) OriginDigest(origin: ref string) -> Result<string, GitError> {
  var bytes: owned <int8>[] = new <int8>[65];
  unsafe {
    let count: int32 = ngit_hash_bytes(origin.data as *const int8, origin.length, &mut bytes[0], 65);
    if count != 64 {
      return GitError.CacheFailure;
    }

    let result: Result<string, GitError> = string.ViewFrom(&bytes[0] as *const int8, count).Substring(0, count);
    return result;
  }
}

/** @brief Prepare a repository with this operation's transport controls.
 * @returns True for a staged clone, false for an existing repository, or a redacted error. */
pub method(GitProvider) Prepare(
  origin: ref string,
  repository: ref string,
  clone: ref string
) -> Result<bool, GitError> {
  let offline: bool = self.offline;
  let timeout_ms: int32 = self.timeout_ms;

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
    return GitError.FromProviderStatus(status);
  }

  if status > 1 {
    return GitError.InvalidResult;
  }

  let result: Result<bool, GitError> = status == 1;
  return result;
}

/** @brief Export one bounded tree and retain validated snapshot identity.
 * @returns An owned GitSnapshot or a redacted provider/framing error. */
pub method(GitProvider) Export(
  origin: ref string,
  revision: ref string,
  repository: ref string,
  destination: ref string
) -> Result<GitSnapshot, GitError> {
  let offline: bool = self.offline;
  let timeout_ms: int32 = self.timeout_ms;

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
    return GitError.FromProviderStatus(count);
  }

  if count != 105 {
    return GitError.InvalidResult;
  }

  var text: string = "";
  unsafe {
    text = string.ViewFrom(&bytes[0] as *const int8, count).Substring(0, count);
  }

  // Native output is only commit/digest; cache-relative paths are Nyra policy.
  let content: string = text.Slice(41, text.length);
  return GitSnapshot.Decode(
    text.Concat("\npackages/").Concat(content).Concat("/content"),
    revision
  );
}
