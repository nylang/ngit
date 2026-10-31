// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Decode and validate immutable snapshot identities returned by the native bridge. */
module GitSnapshotResult;
import "stdlib:stdlib.ny";
import "interface/git.ni";
import "public/git.ny";

static method(GitSnapshot) LowerHex(value: ref string, length: int32) -> bool {
  if value.length != length {
    return false;
  }

  var at: int32 = 0;
  while at < length {
    let byte: uint8 = value[at];
    if ! ((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f')) {
      return false;
    }

    at = at + 1;
  }

  return true;
}

/** @brief Validate native result framing, canonical path and exact requested commit.
 * @returns An owned snapshot or InvalidResult; input strings remain borrowed.
 */
pub static method(GitSnapshot) Decode(text: ref string, revision: ref string) -> Result<GitSnapshot, GitError> {
  let first: int32 = text.Find("\n");
  if first != 40 {
    return GitError.InvalidResult;
  }

  let tail: string = text.Slice(first + 1, text.length);
  let second: int32 = tail.Find("\n");
  if second != 64 {
    return GitError.InvalidResult;
  }

  let commit: string = text.Slice(0, first);
  let content: string = tail.Slice(0, second);
  let relative: string = tail.Slice(second + 1, tail.length);
  if !GitSnapshot.LowerHex(commit, 40)
    || !GitSnapshot.LowerHex(content, 64)
    || relative != "packages/".Concat(content).Concat("/content") {
    return GitError.InvalidResult;
  }

  if GitSnapshot.LowerHex(revision, 40) && commit != revision {
    return GitError.InvalidResult;
  }

  let result: Result<GitSnapshot, GitError> = GitSnapshot{
    commit: commit,
    content: content,
    relative_path: relative
  };

  return result;
}
