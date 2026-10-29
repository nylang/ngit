// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/**
 * @brief Git acquisition and immutable source snapshots, independent of package management.
 * @note This initial API is a snapshot subset, not a complete libgit2 binding.
 */
import "stdlib:stdlib.ny";
/** @brief Redacted acquisition errors; no credentials or native error buffers escape. */
pub enum GitError {
  InvalidArgument,
  Transport,
  UnsupportedOrigin,
  CacheFailure,
  RevisionUnavailable,
  UnsupportedTree,
  OfflineMiss,
  UnsupportedObjectFormat,
  InvalidResult,
}

/** @brief Namespace for Git transport and snapshot preparation. */
pub struct Git;

/**
 * @brief Identity of a prepared source snapshot; owns its identity/path strings.
 * @note Language drop releases strings; the caller-owned store retains files.
 */
pub struct GitSnapshot;

/**
 * @brief Fetch/resolve a revision and atomically materialize its content snapshot.
 * @param origin Borrowed HTTPS or local/file origin without credentials in the URL.
 * @param revision Borrowed full lowercase SHA-1 commit or symbolic revision selector.
 * @param store Borrowed cache root; no project or package manifest is required.
 * @param offline Forbid network access; missing local objects return OfflineMiss.
 * @param timeout_ms Connect/read and lock wait bounds, 1..120000 milliseconds.
 * @returns Owned GitSnapshot or a redacted GitError. No native handle escapes.
 * @note Requires linked ngit/libgit2/OpenSSL libraries, never an external Git process.
 *       Symlinks, submodules, LFS pointers and oversized trees are rejected.
 *       libgit2 global options are process-wide: serialize calls in a process.
 */
pub static method(Git) PrepareSnapshot(
  origin: ref string,
  revision: ref string,
  store: ref string,
  offline: bool,
  timeout_ms: int32
) -> Result<GitSnapshot, GitError>;

/**
 * @brief Return the owned lowercase SHA-1 commit identity; no native buffer is borrowed.
 * @returns The snapshot commit identity as a language-owned string.
 */
pub method(GitSnapshot) Commit() -> string;

/**
 * @brief Return the owned SHA256 of canonical content framing; no native buffer is borrowed.
 * @returns The canonical snapshot SHA256 as a language-owned string.
 */
pub method(GitSnapshot) ContentDigest() -> string;

/**
 * @brief Return the owned store-relative snapshot directory path.
 * @note Currently packages/<content digest>/content, retained for cache compatibility.
 * @returns The snapshot directory relative to the caller-owned store.
 */
pub method(GitSnapshot) RelativePath() -> string;
