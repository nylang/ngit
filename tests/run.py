#!/usr/bin/env python3
# Copyright (c) 2026 tangxiangjiang
# SPDX-License-Identifier: MIT
"""Build and accept ngit with one coherent compiler, runtime and native provider.

The optional source runtime overlay is private to this new output directory.
It never changes published package declarations or installs an SDK.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, required=True)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--platform-archive", type=Path, required=True)
    parser.add_argument("--link-args", type=Path, required=True)
    parser.add_argument("--openssl", type=Path, required=True)
    parser.add_argument("--runtime-source", type=Path, help="Source root containing kernel, stdlib and ntest")
    parser.add_argument("--out-dir", type=Path, required=True, help="New output directory")
    args = parser.parse_args()
    package = Path(__file__).resolve().parents[1]
    output = args.out_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    project = output / "project"
    project.mkdir()
    ignored = shutil.ignore_patterns(".git", ".nyra", "cache", "__pycache__")
    shutil.copytree(package, project / "ngit", ignore=ignored)
    mappings = ["  ngit: ./ngit/package.yaml"]
    if args.runtime_source:
        runtime = args.runtime_source.resolve()
        for name in ("kernel", "stdlib", "ntest"):
            shutil.copytree(runtime / name, project / name, ignore=ignored)
            mappings.append(f"  {name}: ./{name}/package.yaml")
        with (project / "ngit/package.yaml").open("a") as manifest:
            manifest.write("dependencies:\n  stdlib:\n    workspace: true\n"
                           "dev-dependencies:\n  ntest:\n    workspace: true\n")
    (project / "workspace.yaml").write_text("version: 1\npackages:\n" + "\n".join(mappings) + "\n")
    consumer = project / "consumer"
    consumer.mkdir()
    shutil.copyfile(package / "tests/data/consumer.ny.in", consumer / "main.ny")
    manifest = "name: ngit_acceptance\nversion: 0.0.0\ndependencies:\n  ngit:\n    path: ../ngit\n"
    if args.runtime_source:
        manifest += "  stdlib:\n    workspace: true\n"
    (consumer / "package.yaml").write_text(manifest)

    env = os.environ | {"NYRA_SDK_ROOT": str(args.sdk.resolve())}
    if sys.platform == "darwin" and not env.get("SDKROOT"):
        env["SDKROOT"] = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    link_args = json.loads(args.link_args.read_text())
    if not isinstance(link_args, list) or not all(isinstance(arg, str) for arg in link_args):
        raise ValueError("link-args must be a JSON string array from tools/build.py")
    common = ["-O2", "-j", "4", "--platform-archive=" + str(args.platform_archive.resolve())]
    compiler = str(args.compiler.resolve())
    commands = []

    def run(name, command, accepted=(0,)):
        with (output / f"{name}.log").open("w") as log:
            result = subprocess.run(command, cwd=project, env=env, stdout=log, stderr=subprocess.STDOUT)
        commands.append({"name": name, "exit_code": result.returncode})
        if result.returncode not in accepted:
            raise RuntimeError(f"{name} failed; see {output / (name + '.log')}")

    run("check", [compiler, "check", str(project / "ngit/ngit.ny")])
    run("units", [compiler, "test", str(project / "ngit"), *common,
                  "--out-dir", str(output / "unit-objects"), "-o", str(output / "units"),
                  "--report", str(output / "unit-report.json"), *link_args])
    units = json.loads((output / "unit-report.json").read_text())
    if units.get("passed") != 5 or units.get("failed") != 0:
        raise RuntimeError(f"expected all 5 ngit unit tests: {units}")
    run("consumer-build", [compiler, "build", str(consumer / "main.ny"), "--link", *common,
                           "--out-dir", str(output / "consumer-objects"), "-o", str(output / "consumer"),
                           *link_args])
    run("precompile", [compiler, "precompile", str(project / "ngit/ngit.ny"), *common,
                       "--out-dir", str(output / "library-objects"), "-o", str(output / "library")])
    archives = list((output / "library").rglob("*.a"))
    if not archives:
        raise RuntimeError("production precompile did not produce an archive")
    symbols = subprocess.run(["nm", *map(str, archives)], capture_output=True, text=True, check=True).stdout
    if "GitResultTests" in symbols or "test_snapshot_" in symbols:
        raise RuntimeError("test implementation leaked into production archive")
    (output / "production-symbols.txt").write_text(symbols)
    run("acceptance", [sys.executable, str(package / "tests/accept.py"),
                       "--consumer", str(output / "consumer"), "--openssl", str(args.openssl.resolve()),
                       "--out-dir", str(output / "acceptance")])
    report = {
        "commands": commands,
        "units": units,
        "acceptance": json.loads((output / "acceptance/report.json").read_text()),
        "compiler_sha256": hashlib.sha256(args.compiler.read_bytes()).hexdigest(),
        "platform_archive_sha256": hashlib.sha256(args.platform_archive.read_bytes()).hexdigest(),
        "production_archive_test_symbols": False,
    }
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(output / "report.json")


if __name__ == "__main__":
    main()
