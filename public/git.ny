// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

module GitSnapshotModel;
import "stdlib:stdlib.ny";
import "interface/git.ni";

/** @brief Type namespace with no native resource ownership. */
pub struct Git {
  _pad: int8;
}

/** @brief Language-owned snapshot identity; files remain in the caller's store. */
pub struct GitSnapshot {
  commit: string;
  content: string;
  relative_path: string;
}

/** @brief Read the retained commit identity.
 * @returns The owned lowercase SHA-1 identity. */
pub method(GitSnapshot) Commit() -> string {
  return self.commit;
}

/** @brief Read the retained canonical content identity.
 * @returns The owned lowercase SHA256 identity. */
pub method(GitSnapshot) ContentDigest() -> string {
  return self.content;
}

/** @brief Read the immutable store-relative snapshot directory.
 * @returns An owned relative path; cached files remain in the caller's store. */
pub method(GitSnapshot) RelativePath() -> string {
  return self.relative_path;
}
