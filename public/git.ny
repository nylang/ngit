/**
 * @brief Typed snapshot wrapper over the private libgit2 bridge.
 * @note Returned strings are owned by the language; native handles never escape a call.
 */
module Ngit;
part "../private/git_c.ny";
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

func git_error(error: GitError) -> Result<GitSnapshot, GitError> {
  let result: Result<GitSnapshot, GitError> = error;

  return result;
}

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

func git_lower_hex(value: ref string, length: int32) -> bool {
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

  var bytes: owned <int8>[] = new <int8>[512];
  var offline_flag: int32 = 0;
  if offline {
    offline_flag = 1;
  }

  var count: int32 = 0;
  unsafe {
    count = ngit_prepare_snapshot(
      origin.data as *const int8, origin.length,
      revision.data as *const int8, revision.length,
      store.data as *const int8, store.length,
      offline_flag, timeout_ms, &mut bytes[0], 512
    );
  }

  if count < 0 {
    return git_error(git_status_error(count));
  }

  if count == 0 || count >= 512 {
    return git_error(GitError.InvalidResult);
  }

  var text: string = "";
  unsafe {
    // Copy before the temporary native-output array drops.
    text = string.ViewFrom(&bytes[0] as *const int8, count).Substring(0, count);
  }

  let first: int32 = text.Find("\n");
  if first != 40 {
    return git_error(GitError.InvalidResult);
  }

  let tail: string = text.Slice(first + 1, text.length);
  let second: int32 = tail.Find("\n");
  if second != 64 {
    return git_error(GitError.InvalidResult);
  }

  let commit: string = text.Slice(0, first);
  let content: string = tail.Slice(0, second);
  let relative: string = tail.Slice(second + 1, tail.length);
  if !git_lower_hex(commit, 40) || !git_lower_hex(
    content,
    64
  ) || relative != "packages/".Concat(content).Concat("/content") {
    return git_error(GitError.InvalidResult);
  }

  if git_lower_hex(revision, 40) && commit != revision {
    return git_error(GitError.InvalidResult);
  }

  let result: Result<GitSnapshot, GitError> = GitSnapshot{
    commit: commit,
    content: content,
    relative_path: relative
  };

  return result;
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
