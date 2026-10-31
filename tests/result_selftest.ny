// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Snapshot result framing and public admission contracts across module boundaries. */
module GitResultTests;
import "stdlib:stdlib.ny";
import "ntest:ntest.ny";
import "interface/git.ni";
import "public/git.ny";
import "private/result.ny";
import "private/acquire.ny";

static method(GitSnapshot) TestFraming(commit: ref string, digest: ref string) -> string {
  return commit.Concat("\n").Concat(digest).Concat("\npackages/").Concat(digest).Concat("/content");
}

@test
func test_ngit_result_retains_owned_identities() {
  let commit: string = "0123456789abcdef0123456789abcdef01234567";
  let digest: string = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
  var made: Result<GitSnapshot, GitError> = GitSnapshot.Decode(GitSnapshot.TestFraming(commit, digest), commit);
  AssertTrue(made.IsOk());
  let snapshot: GitSnapshot = (made.get_if<GitSnapshot>()) as GitSnapshot;
  AssertEqString(snapshot.Commit(), commit);
  AssertEqString(snapshot.ContentDigest(), digest);
  AssertEqString(snapshot.RelativePath(), "packages/".Concat(digest).Concat("/content"));
}

@test
func test_ngit_result_symbolic_revision_is_not_a_commit_pin() {
  let commit: string = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  let digest: string = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  AssertTrue(GitSnapshot.Decode(GitSnapshot.TestFraming(commit, digest), "v1.0.0").IsOk());
  let different: string = "cccccccccccccccccccccccccccccccccccccccc";
  AssertTrue(GitSnapshot.Decode(GitSnapshot.TestFraming(commit, digest), different).IsErr());
}

@test
func test_ngit_result_rejects_noncanonical_identities() {
  let commit: string = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  let digest: string = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  AssertTrue(GitSnapshot.Decode(GitSnapshot.TestFraming("short", digest), "main").IsErr());
  AssertTrue(GitSnapshot.Decode(GitSnapshot.TestFraming(commit, "short"), "main").IsErr());
  let upper_commit: string = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
  AssertTrue(GitSnapshot.Decode(GitSnapshot.TestFraming(upper_commit, digest), "main").IsErr());
  let upper_digest: string = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
  AssertTrue(GitSnapshot.Decode(GitSnapshot.TestFraming(commit, upper_digest), "main").IsErr());
}

@test
func test_ngit_result_rejects_path_or_extra_output() {
  let commit: string = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  let digest: string = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  let prefix: string = commit.Concat("\n").Concat(digest).Concat("\n");
  AssertTrue(GitSnapshot.Decode(prefix.Concat("../content"), "main").IsErr());
  AssertTrue(GitSnapshot.Decode(prefix.Concat("packages/").Concat(digest).Concat("/content/extra"), "main").IsErr());
  AssertTrue(GitSnapshot.Decode(GitSnapshot.TestFraming(commit, digest).Concat("\n"), "main").IsErr());
}

@test
func test_ngit_public_admission_rejects_invalid_controls() {
  AssertTrue(Git.PrepareSnapshot("", "main", "unused", false, 1000).IsErr());
  AssertTrue(Git.PrepareSnapshot("/unused", "", "unused", false, 1000).IsErr());
  AssertTrue(Git.PrepareSnapshot("/unused", "main", "", false, 1000).IsErr());
  AssertTrue(Git.PrepareSnapshot("/unused", "main", "unused", false, 0).IsErr());
  AssertTrue(Git.PrepareSnapshot("/unused", "main", "unused", false, 120001).IsErr());
}
