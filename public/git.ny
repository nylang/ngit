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

/** @brief Return the language-owned commit identity, with normal string copy semantics. */
pub method(GitSnapshot) Commit() -> string {
  return self.commit;
}

/** @brief Return the language-owned canonical content digest. */
pub method(GitSnapshot) ContentDigest() -> string {
  return self.content;
}

/** @brief Return the language-owned store-relative snapshot path. */
pub method(GitSnapshot) RelativePath() -> string {
  return self.relative_path;
}
