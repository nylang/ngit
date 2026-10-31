#!/usr/bin/env python3
# Copyright (c) 2026 tangxiangjiang
# SPDX-License-Identifier: MIT

"""Build ngit's pinned static C backend; no NyraLang private repository is required."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PIN = ROOT / 'private/native/libgit2.lock.json'


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(output: Path, openssl: Path, *, cc: str | None = None) -> dict:
    output = output.resolve()
    if output == ROOT or ROOT.is_relative_to(output):
        raise ValueError('backend output must not replace the package root or its ancestors')
    output.mkdir(parents=True, exist_ok=True)
    openssl = openssl.resolve()
    pin = json.loads(PIN.read_text())
    archive = output / f"libgit2-{pin['version']}.tar.gz"
    if not archive.exists():
        temporary = archive.with_suffix(".download")
        with urllib.request.urlopen(pin["url"], timeout=60) as response, temporary.open("wb") as destination:
            shutil.copyfileobj(response, destination)
        if sha(temporary) != pin["sha256"]:
            temporary.unlink()
            raise ValueError("libgit2 source archive digest mismatch")
        temporary.replace(archive)
    if sha(archive) != pin["sha256"]:
        raise ValueError("libgit2 source archive digest mismatch")
    source = output / f"libgit2-{pin['version']}"
    if not source.exists():
        with tarfile.open(archive) as bundle:
            bundle.extractall(output, filter="data")
    patches = []
    if platform.system() == "Windows":
        from vendor_patch import apply_patch
        patches.append(apply_patch(source))
    build_dir = output / "libgit2-build"
    commands = []
    build_environment = os.environ.copy()

    def run(label, argv, timeout=1200):
        argv = list(map(str, argv))
        commands.append(argv)
        with (output / f"{label}.log").open("w") as log:
            environment=build_environment.copy()
            if platform.system()=="Darwin": environment["MACOSX_DEPLOYMENT_TARGET"]="14.0"
            subprocess.run(argv, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=timeout)

    cc = cc or os.environ.get("CC", "clang")
    configure = ["cmake", "-S", source, "-B", build_dir, "-DBUILD_SHARED_LIBS=OFF",
                 "-DBUILD_TESTS=OFF", "-DBUILD_CLI=OFF", "-DUSE_HTTPS=OpenSSL", "-DUSE_SSH=OFF",
                 "-DUSE_GSSAPI=OFF", "-DUSE_BUNDLED_ZLIB=ON", "-DREGEX_BACKEND=builtin",
                 "-DOPENSSL_USE_STATIC_LIBS=TRUE", "-DOPENSSL_ROOT_DIR=" + str(openssl),
                 "-DCMAKE_BUILD_TYPE=Release"]
    windows = platform.system() == "Windows"
    if windows:
        # MSVC /GL archives cannot be consumed by the SDK's LLVM linker.
        # Use the same pinned Clang toolchain for the vendor and bridge objects.
        cmake = shutil.which("cmake")
        ninja = shutil.which("ninja")
        if not ninja and cmake:
            bundled = Path(cmake).parents[2] / "Ninja/ninja.exe"
            if bundled.is_file():
                ninja = str(bundled)
        if not ninja:
            raise ValueError("Windows package acquisition builds require Ninja on PATH or Visual Studio's bundled Ninja")
        configure.extend(["-G", "Ninja", "-DCMAKE_MAKE_PROGRAM=" + ninja,
                          "-DCMAKE_C_COMPILER=" + cc,
                          "-DCMAKE_C_FLAGS=-fms-runtime-lib=static -D_CRT_SECURE_NO_WARNINGS",
                          "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW",
                          "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
                          "-DSTATIC_CRT=ON",
                          "-DOPENSSL_SSL_LIBRARY=" + str(openssl / "lib/libssl.lib"),
                          "-DOPENSSL_CRYPTO_LIBRARY=" + str(openssl / "lib/libcrypto.lib"),
                          "-DSSL_EAY=" + str(openssl / "lib/libssl.lib"),
                          "-DLIB_EAY=" + str(openssl / "lib/libcrypto.lib")])
    if platform.system() == "Darwin":
        configure.append("-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0")
    run("configure", configure)
    run("libgit2-build", ["cmake", "--build", build_dir, "--config", "Release", "-j", "4"])
    native = output / "native"
    native.mkdir(exist_ok=True)
    bridge = native / "git_bridge.o"
    # Windows filesystem calls use checked UTF-8/extended wide paths.
    # MSVC marks these standard functions deprecated unless explicitly enabled.
    # Supply the POSIX mode predicate absent from the Windows CRT headers.
    target_flags = (["-mmacosx-version-min=14.0", "-isysroot", os.environ.get("SDKROOT") or
                     subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()] if platform.system() == "Darwin"
                    else ["-D_CRT_SECURE_NO_WARNINGS",
                          "-DS_ISDIR(mode)=(((mode)&_S_IFMT)==_S_IFDIR)"] if windows else [])
    run("bridge", [cc, *target_flags, "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-missing-field-initializers",
                   "-I" + str(source / "include"), "-I" + str(openssl / "include"),
                   "-c", ROOT / "private/native/git_bridge.c", "-o", bridge])
    git_archive = build_dir / ("Release/git2.lib" if windows else "libgit2.a")
    if windows and not git_archive.exists():
        git_archive = build_dir / "git2.lib"
    ssl_archive = openssl / "lib" / ("libssl.lib" if windows else "libssl.a")
    crypto_archive = openssl / "lib" / ("libcrypto.lib" if windows else "libcrypto.a")
    ngit_archive = output / 'libngit.a'
    ngit_archive.unlink(missing_ok=True)
    run('ngit-archive', [os.environ.get('AR', 'llvm-ar'), 'rcs', ngit_archive, bridge])
    libraries = [ngit_archive, git_archive, ssl_archive, crypto_archive]
    for path in libraries:
        if not path.is_file():
            raise ValueError(f"missing static native dependency: {path}")
    links = []
    if platform.system() == "Darwin":
        links = ["-liconv", "-framework", "Security", "-framework", "CoreFoundation"]
    elif windows:
        links = ["-lws2_32", "-lcrypt32", "-lbcrypt", "-ladvapi32", "-luser32", "-lsecur32"]
    else:
        links = ["-lpthread", "-ldl"]
    licenses = output / "licenses"
    licenses.mkdir(exist_ok=True)
    shutil.copy2(source / "COPYING", licenses / "libgit2-COPYING.txt")
    shutil.copy2(ROOT / "LICENSE", licenses / "ngit-MIT.txt")
    ssl_license = next((p for p in (openssl / "LICENSE.txt", openssl / "LICENSE") if p.exists()), None)
    if ssl_license:
        shutil.copy2(ssl_license, licenses / "OpenSSL-LICENSE.txt")
    result = {'package': 'ngit', 'version': '0.2.0', 'libgit2': pin,
              'native_libraries': {str(p): sha(p) for p in libraries},
              'bridge_source_sha256': sha(ROOT / 'private/native/git_bridge.c'),
              'windows_paths_source_sha256': sha(ROOT / 'private/native/windows_paths.h') if windows else None,
              'openssl_version': subprocess.check_output([str(openssl / 'bin' / ('openssl.exe' if windows else 'openssl')), 'version'], text=True).strip(),
              'source_patches': patches, 'commands': commands, 'system_libraries': links,
              'scope': 'source backend build; no validation or release acceptance'}
    (output / 'link-args.json').write_text(json.dumps([
        *['--link-arg=' + str(p) for p in libraries],
        *['--link-arg=' + p for p in links]], indent=2) + '\n')
    (output / 'build.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out-dir', type=Path, required=True)
    parser.add_argument('--openssl-prefix', type=Path, required=True)
    parser.add_argument('--cc')
    args = parser.parse_args()
    build(args.out_dir, args.openssl_prefix, cc=args.cc)


if __name__ == '__main__':
    main()
