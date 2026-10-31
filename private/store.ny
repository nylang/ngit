// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Immutable Git store transactions; native code owns only provider operations. */
module GitSnapshotStore;
import "stdlib:stdlib.ny";
import "interface/git.ni";
import "public/git.ny";
import "private/provider.ny";

/**
 * @brief Selected immutable Git cache root and transport controls for one operation.
 * @note Owns store/lock/stage publication policy; provider owns native transport,
 *       and GitSnapshot owns framing. Excludes package manifests and workspace policy.
 */
pub struct GitStore {
  root: string;
  provider: GitProvider;
}

/** @brief Retain the selected store root and transport controls without performing I/O.
 * @returns A store value; language drop releases its root string, not cached files. */
pub static method(GitStore) New(root: ref string, offline: bool, timeout_ms: int32) -> GitStore {
  return GitStore{root: copy(root), provider: GitProvider.New(offline, timeout_ms)};
}

// This is input framing, not platform path conversion or authentication policy.
static method(GitStore) InputValid(value: ref string) -> bool {
  if value.length <= 0 || value.length > 32768 {
    return false;
  }

  var index: int32 = 0;
  while index < value.length {
    let byte: uint8 = value[index];
    if byte == 0 || byte == 10 || byte == 13 {
      return false;
    }

    index = index + 1;
  }

  return true;
}

static method(GitStore) OriginValid(origin: ref string) -> bool {
  if origin.StartsWith("https://") {
    let rest: string = origin.Slice(8, origin.length);
    let slash: int32 = rest.Find("/");
    var authority: string = rest;
    if slash >= 0 {
      authority = rest.Slice(0, slash);
    }

    return !authority.Contains("@") && !origin.Contains("?") && !origin.Contains("#");
  }

  return origin.StartsWith("file:///") || origin.StartsWith("/") || (
    origin.length > 2 && origin[1] == ':' && (origin[2] == '/' || origin[2] == '\\')
  );
}

// Reclaim stage contents without traversing a stale symlink into another owner.
// Fresh provider exports reject links; stale or interrupted stages need the same
// no-follow cleanup contract as the preceding native transaction implementation.
// An operation only removes its own stage. The origin lock outlives this owner.
@scoped struct GitStage {
  path: string;
}

method(GitStage) operator drop() -> void {
  if self.path.length > 0 {
    let ignored: Result<Unit, IoError> = Path.DeleteTreeNoFollow(self.path);
  }
}

method(GitStage) operator move() -> GitStage {
  let path: string = move(self.path);
  self.path = "";

  return GitStage{ path: move(path) };
}

static method(GitStage) Reclaim(root: string, key: string) -> void {
  let read: Result<DirectoryList, IoError> = Directory.New(root).List();
  let entries: DirectoryList? = read.get_if<DirectoryList>();
  if entries == nil {
    return;
  }

  let values: DirectoryList = entries as DirectoryList;
  let prefix: string = "op-".Concat(key).Concat("-");
  var index: int32 = 0;
  while index < values.Len() {
    let path: string = values.Get(index);
    let name: string = path;
    var separator: int32 = name.length;
    while separator > 0 && name[separator - 1] != '/' && name[separator - 1] != '\\' {
      separator = separator - 1;
    }

    if name.Slice(separator, name.length).StartsWith(prefix) {
      let ignored: Result<Unit, IoError> = Path.DeleteTreeNoFollow(path);
    }

    index = index + 1;
  }
}

/** @brief Acquire and publish an immutable snapshot under the existing origin/content locks.
 * @returns An owned snapshot, or GitError without publishing an invalid snapshot. */
pub method(GitStore) Prepare(
  origin: ref string,
  revision: ref string
) -> Result<GitSnapshot, GitError> {
  let store: string = self.root;
  let offline: bool = self.provider.IsOffline();
  let timeout_ms: int32 = self.provider.Timeout();

  if !GitStore.InputValid(origin) || !GitStore.InputValid(revision) || !GitStore.InputValid(store) {
    return GitError.CacheFailure;
  }

  if !GitStore.OriginValid(origin) {
    return GitError.UnsupportedOrigin;
  }

  let repositories: string = Path.Join(store, "git");
  let packages: string = Path.Join(store, "packages");
  let locks: string = Path.Join(store, "locks");
  let staging: string = Path.Join(store, "staging");
  if offline && !Directory.New(repositories).Exists() {
    return GitError.OfflineMiss;
  }

  if Directory.New(repositories).CreateRecursive().IsErr()
    || Directory.New(packages).CreateRecursive().IsErr()
    || Directory.New(locks).CreateRecursive().IsErr()
    || Directory.New(staging).CreateRecursive().IsErr() {
    return GitError.CacheFailure;
  }

  let digest: Result<string, GitError> = self.provider.OriginDigest(origin);
  let key_value: string? = digest.get_if<string>();
  if key_value == nil {
    return GitError.CacheFailure;
  }

  let key: string = key_value as string;
  let repository: string = Path.Join(repositories, key);
  let origin_locked: Result<FileLock, IoError> = FileLock.Acquire(Path.Join(locks, key), timeout_ms);
  let origin_value: FileLock? = origin_locked.get_if<FileLock>();
  if origin_value == nil {
    return GitError.CacheFailure;
  }

  var origin_guard: FileLock = origin_value as FileLock;
  GitStage.Reclaim(staging, key);
  let created: Result<Directory, IoError> = Directory.New(staging).CreateTemp("op-".Concat(key).Concat("-"));
  let stage_value: Directory? = created.get_if<Directory>();
  if stage_value == nil {
    return GitError.CacheFailure;
  }

  let stage_directory: Directory = stage_value as Directory;
  var stage: GitStage = GitStage{ path: copy(stage_directory.Path()) };
  let clone: string = Path.Join(stage.path, "repository");
  let prepared: Result<bool, GitError> = self.provider.Prepare(origin, repository, clone);
  let prepare_error: GitError? = prepared.get_if<GitError>();
  if prepare_error != nil {
    return prepare_error as GitError;
  }

  let cloned: bool? = prepared.get_if<bool>();
  if cloned == nil {
    return GitError.InvalidResult;
  }

  if (cloned as bool) && Path.RenameExclusive(clone, repository).IsErr() {
    return GitError.CacheFailure;
  }

  let exported_path: string = Path.Join(stage.path, "content");
  let exported: Result<GitSnapshot, GitError> = self.provider.Export(origin, revision, repository, exported_path);
  let export_error: GitError? = exported.get_if<GitError>();
  if export_error != nil {
    return export_error as GitError;
  }

  let snapshot_value: GitSnapshot? = exported.get_if<GitSnapshot>();
  if snapshot_value == nil {
    return GitError.InvalidResult;
  }

  let snapshot: GitSnapshot = snapshot_value as GitSnapshot;
  let target: string = Path.Join(packages, snapshot.ContentDigest());
  let content_locked: Result<FileLock, IoError> = FileLock.Acquire(
    Path.Join(locks, snapshot.ContentDigest()), timeout_ms
  );
  let content_value: FileLock? = content_locked.get_if<FileLock>();
  if content_value == nil {
    return GitError.CacheFailure;
  }

  var content_guard: FileLock = content_value as FileLock;
  if !Directory.New(Path.Join(target, "content")).Exists() {
    let publication: string = Path.Join(stage.path, "publication");
    if Directory.New(publication).Create().IsErr()
      || Path.RenameExclusive(exported_path, Path.Join(publication, "content")).IsErr()
      || Path.RenameExclusive(publication, target).IsErr() {
      return GitError.CacheFailure;
    }
  }

  let result: Result<GitSnapshot, GitError> = snapshot;
  return result;
}
