# ngit module architecture

The public `Git.PrepareSnapshot` contract returns owned immutable snapshot values.
Package/workspace selection, project dependency graphs and lock-file policy stay
in callers. The source implementation separates store transactions from libgit2.

- `public/git.ny` owns snapshot identity values and accessors. It neither calls
  native functions nor parses their result framing.
- `private/acquire.ny` admits public controls and starts one store operation.
- `private/store.ny` defines `GitStore`, retaining its root and provider controls.
  It owns cache layout, input/origin admission, origin/content
  locks, stale own-origin stage reclamation, repository publication and immutable
  content publication. `GitStage` drops only its own stage. Its origin `FileLock`
  stays alive through cleanup; the content lock covers final publication.
  Reclamation inspects entry kinds without following links, removes only the
  matching origin's stages and preserves unrelated origin stages.
- `private/provider.ny` defines `GitProvider`, retaining offline/timeout controls.
  It adapts bounded native hash/clone/resolve/export operations
  into typed results. It copies native output before temporary buffers drop.
- `private/result.ny` gives `GitSnapshot` its typed decoder, which validates framing, hexadecimal identities, canonical paths
  and exact requested commits. It consumes immutable owned text and performs no
  repository/store mutation.
- `private/git_c.ni` and `private/native/git_bridge.{c,h}` own the private provider
  ABI. C retains libgit2/TLS/auth/proxy controls, transfer limits, Git tree/blob
  traversal and bounded tree materialization. It does not choose cache roots,
  acquire generic store locks, allocate transaction stages or publish snapshots.

Store policy depends on provider operations and stdlib filesystem/lock resources.
The provider depends on result validation and the value model. The value model
has no reverse acquisition dependency. No libgit2 handle crosses into Nyra.

## Ownership and compatibility

`FileLock` is a scoped stdlib resource over private platform primitives. No
product `Free` or package-specific filesystem C shim is introduced. Native
libgit2 timeout/trust settings remain process-wide; callers still serialize
in-process provider calls. Cross-process exclusion uses the same regular lock
paths as the preceding implementation.

The `git`, `locks`, `staging`, `packages/<digest>/content` layout, exact origin
hash and `nyra-package-content-v1` content framing remain the store contract.
Staged clone/export paths belong to the Nyra transaction. Native code returns
only commit/content identity; Nyra constructs the cache-relative result path.

This source now requires the 1.0.4 stdlib `FileLock` capability and its matching
platform ABI 10 archive. The old private monolithic native entry is replaced by
three provider operations, so old native archives cannot be mixed with this
source. No release/version tag or public Git API was changed by this refactor.

## Verification

The 2026-10-29 macOS arm64 closeout passes semantic checking, all five package
unit tests, production precompilation without test symbols, and 27 public Nyra
consumer checks. The consumer covers local/HTTPS and offline acquisition,
symbolic revision updates and exact commits, independently computed content
digests, concurrent origin/content publication, lock contention and process
death, failed publication, interrupted-stage reclamation, symlink-safe cleanup,
store relocation and rejected symlink/submodule/LFS/oversized inventories.
Certificate trust, credentials, redirect refusal and transport timeout are
exercised against a controlled local HTTPS smart-Git server. The consumer runs
without a Git executable in PATH. Native invalid-input/output-bound checks are
separate from public transaction acceptance.

The native compiler's borrowed-string index type check is fixed at its source;
the positive regression covers string/ref/ref mut receivers and high-bit bytes.
The ngit decoder retains its uint8 declaration without a cast workaround.
Acceptance uses a focused native development compiler and the matching source
stdlib/platform ABI 10; it does not qualify the whole parent compiler refactor
or a distributable SDK. Windows, Linux and Intel execution, SDK qualification
and publication remain separate gates. See README for repeatable test commands.

## 1.0.5 ownership increment

`GitStore` owns transaction policy, `GitProvider` owns native controls,
`GitSnapshot.Decode` validates owned output, and `GitError.FromProviderStatus`
maps native status. `GitStage.Reclaim` owns stage-selection policy; generic
no-follow removal delegates to stdlib `Path.DeleteTreeNoFollow`. Entry
classification and deletion are separate operations, so path replacement must
remain serialized by the caller's store/origin locks.

The established stateless `Git` public admission namespace is retained as an
explicit compatibility exception and delegates directly to these owners. No new
empty helper namespace or C policy implementation is introduced. Native provider
symbols/archive inputs and public Git snapshot value layouts stay unchanged.
This increment requires matching 1.0.5 source stdlib; the earlier 1.0.4 requirement
above describes the historical closeout. Five package units, 24 package-manager
smoke checks and 40 controlled Git/cache checks pass on macOS arm64. The parent
receipt is `docs/roadmaps/m_v1.0.5/ngit-owner-refactor.json`; other hosts, full SDK
qualification and package publication remain separate.
