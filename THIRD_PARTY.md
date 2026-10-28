# Native dependencies

The repository contains an authored MIT wrapper and a retained libgit2 source
patch. It does not vendor a full libgit2 or OpenSSL source distribution.

libgit2 1.9.7 is pinned by URL and SHA256 in
`private/native/libgit2.lock.json`. Its license is GPL-2.0-only with the upstream
linking exception; the exact source archive's COPYING is retained by the build.
The Windows path-buffer correction is supplied as a separate source patch with
original and patched file hashes in `private/native/libgit2-windows-long-paths.json`.
The archive pin is not rewritten to conceal this patch.

OpenSSL is supplied explicitly by the builder and retains its own license.
The build copies LICENSE.txt or LICENSE from that prefix, and records the
provider version. The extraction's existing provider is OpenSSL 3.x
(Apache-2.0); no provider binaries or credentials are committed here.

The backend build outputs notices, original corresponding source and patch
metadata for downstream distribution. Building or linking does not convert
upstream source licenses into MIT. Distributors retain these materials along
with ngit's LICENSE and their selected provider's notices.
