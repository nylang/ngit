# ngit

Development API 0.2.0 requires a matching Nyra SDK 1.0.5 or newer.
Rebuild precompiled consumers against the matching interfaces and runtime.

Nyra bindings and a private C adapter for libgit2-backed source snapshots.
Independently versioned **0.2.0**, licensed under MIT.
Repository: <https://github.com/nylang/ngit>.

This initial API resolves Git revisions and materializes bounded immutable
snapshots. It is a snapshot subset, not a complete libgit2 binding. Package names,
dependency graphs, workspace selection and project lock files belong to callers.
No package.yaml is required inside the fetched repository. No Git executable,
shell, checkout filter or credential-helper subprocess is invoked at runtime.

## Nyra interface

Import only `ngit:ngit.ny`. `Git.PrepareSnapshot(origin, revision, store, offline,
timeout_ms)` returns `Result<GitSnapshot, GitError>`. Snapshot methods `Commit`,
`ContentDigest` and `RelativePath` return language-owned strings; no native handle
or manual buffer disposal is exposed. The caller owns the persistent store.
Use a full lowercase SHA-1 commit for reproducible inputs. Symbolic revisions
are available for callers that deliberately resolve/update their own lock.

```nyra
import "stdlib:stdlib.ny";
import "ngit:ngit.ny";

func main() -> int32 {
  let prepared: Result<GitSnapshot, GitError> = Git.PrepareSnapshot(
    "https://github.com/nylang/json.git", "main", ".cache/git", false, 30000
  );
  let value: GitSnapshot? = prepared.get_if<GitSnapshot>();
  if value == nil {
    return 1;
  }

  Console.Println((value as GitSnapshot).Commit());
  return 0;
}
```

## Portable dependencies

The package manifest uses the installed SDK's implicit stdlib. It contains no
private workspace paths. An application's package.yaml can declare:

```yaml
dependencies:
  ngit:
    git: https://github.com/nylang/ngit.git
    rev: 5745ebf696272c4ec21d5f7a0d70a7f750fcbcf7
```

Use `nyra lock` to resolve the selector and commit the generated lock, then
`nyra fetch --frozen` for preparation. Fetching sources does not build native
libraries. A local workspace may map ngit to this package.yaml without changing
the application's published Git declaration. Compiler/SDK portable-lock support
depends on the selected SDK; this source publication does not release a new SDK.

## Native backend build

Use Python 3.12+, CMake, Clang, llvm-ar and a matching static OpenSSL prefix.
Windows additionally needs Ninja and static CRT-compatible OpenSSL libraries;
macOS builds target 14.0 or later. libgit2 1.9.7 and its exact source digest are
pinned in `private/native/libgit2.lock.json`. No NyraLang checkout is required.

```sh
python3 tools/build.py --openssl-prefix /path/to/openssl --out-dir cache/native
```

The script builds the C shim as libngit.a and produces `build.json`,
`link-args.json`, dependency archives, notices and the original libgit2 source
archive. `link-args.json` is a JSON argument array containing all native library
and system-library link arguments. Pass those arguments to `nyrac build --link`
when building a consumer. Example from an application directory:

```python
import json
import subprocess
from pathlib import Path

native = Path("/absolute/path/to/ngit/cache/native")
link_args = json.loads((native / "link-args.json").read_text())
subprocess.run(["nyrac", "build", "main.ny", "--link", *link_args], check=True)
```

The build preserves the Windows libgit2 long-path patch and its exact original/
patched source hashes. Build receipts describe construction, not test acceptance.
The initial extraction was source-only; the subsequent source closeout below
records its own verification scope.

## Runtime policy and limits

HTTPS and local/file origins are supported. SSH and GSSAPI are disabled.
Credentials in URLs, redirects across the transport policy, symlinks, submodules
and LFS pointer contents are rejected. Trees are bounded to 10,000 files and a
64 MiB framed inventory; transfer/object limits also apply. Only SHA-1 repository
object identities are supported. Offline mode reuses local objects and never
fetches. A timeout bounds network operations and lock waits, not an entire
multi-repository workflow. Serialize calls within a process: libgit2 timeout and
trust configuration are process-wide. Cross-process store writers use OS locks.

Configure `NGIT_TOKEN` with `NGIT_USERNAME`, and optionally `NGIT_CA_FILE` without
embedding secrets in URLs. Existing `NYRA_GIT_*` equivalents remain fallbacks.
`SSL_CERT_FILE`/`SSL_CERT_DIR` and standard proxy/NO_PROXY settings remain usable.
Windows default trust imports user/machine ROOT certificates while excluding
Disallowed entries; explicit CA settings take precedence. Certificate and
hostname verification remain enabled. No macOS Keychain integration is provided.

The store's `git`, `locks`, `staging` and `packages/<digest>/content` layout and
`nyra-package-content-v1` hash framing retain existing cache compatibility.
The framing includes sorted paths and bytes, not executable mode bits.
Callers must verify existing materialized content against their trust policy;
ngit does not certify a caller-modified cached directory on reuse.

## Licensing

ngit's authored wrapper and tools use [MIT](LICENSE). libgit2 and OpenSSL retain
their own licenses; linked binaries must carry the corresponding notices and
source/patch obligations. See [THIRD_PARTY.md](THIRD_PARTY.md).

## Module architecture

See [module responsibilities, ownership and dependency boundaries](ARCHITECTURE.md).

## Source refactor requirement (1.0.5 integration)

The current store transaction is implemented in Nyra using stdlib `FileLock`;
its native bridge provides bounded Git operations. Building this worktree
requires the matching 1.0.5 source stdlib (`Path.DeleteTreeNoFollow`) and platform ABI 10, rather than mixing it
with an older SDK runtime archive. See [ARCHITECTURE.md](ARCHITECTURE.md) for
ownership and verification. This source change is not a new release
or a replacement acceptance receipt.

## Verification

On macOS arm64, the 2026-10-29 source closeout passes all five Nyra unit tests,
27 public-consumer integration checks, and production precompilation with no
test symbols. Native invalid-input and output-bound checks also pass. Other
host platforms and SDK release qualification are not claimed by this run.

Use a compiler with the borrowed-string index fix and a matching runtime with
`FileLock`, `Path.DeleteTreeNoFollow` and platform ABI 10. After building the native backend above, run on a
POSIX host:

```sh
python3 tests/run.py \
  --compiler /path/to/nyrac --sdk /path/to/sdk \
  --platform-archive /path/to/libnyra_platform.a \
  --link-args /absolute/path/to/cache/native/link-args.json \
  --openssl /path/to/openssl --out-dir cache/acceptance
```

The output directory must be new. The runner stages a private workspace, checks
the package, runs its units, builds `tests/data/consumer.ny.in`, precompiles the
production package and inspects its symbols, then runs `tests/accept.py`.
`report.json` records results and compiler/runtime hashes. For source-runtime
integration, add `--runtime-source /path/to/source` containing `kernel`, `stdlib`
and `ntest`; the overlay changes only staged manifests. Published dependencies
and installed SDKs are untouched.

Git and OpenSSL executables construct local fixtures; the Nyra consumer receives
an empty PATH. The HTTPS fixture uses a temporary certificate and authenticated
smart-Git server. No external service, credential or remote repository is needed.
The POSIX harness uses OS locks directly to observe contention; Windows needs a
corresponding host harness before claiming Windows acceptance.

## Coding-rule lint

`package.yaml` selects the portable `lint.yaml` profile. It requires the
1.0.5 P7 analyzer candidate (or a later SDK containing those rules); the
published 1.0.4 analyzer does not implement them. `import: default` inherits
the selected workspace profile when present, otherwise analyzer SDK defaults.
No sibling source path is required. Run `nyra-analyzer lint . --json`. Lint checks
coding rules; runtime qualification is a separate gate.
