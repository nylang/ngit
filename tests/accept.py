#!/usr/bin/env python3
# Copyright (c) 2026 tangxiangjiang
# SPDX-License-Identifier: MIT
"""Exercise the public Nyra transaction in separate processes on POSIX hosts.

Git and OpenSSL executables create fixtures only. The consumer runs with an
empty PATH and an isolated home, without Git configuration or credentials.
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import fcntl
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import threading
import time
import urllib.parse


class Acceptance:
    def __init__(self, consumer: Path, output: Path):
        self.consumer = consumer.resolve()
        self.output = output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.git = shutil.which("git")
        if not self.git:
            raise RuntimeError("Git is required to construct fixtures")

        home = self.output / "home"
        home.mkdir()
        empty = self.output / "empty-path"
        empty.mkdir()
        self.fixture_env = os.environ | {
            "HOME": str(home), "XDG_CONFIG_HOME": str(home),
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_AUTHOR_NAME": "ngit acceptance", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "ngit acceptance", "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        }
        self.env = {key: value for key, value in self.fixture_env.items()
                    if not key.startswith(("NGIT_", "NYRA_GIT_", "SSL_CERT_"))
                    and key.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
        self.env.update(PATH=str(empty), NO_PROXY="localhost,127.0.0.1")
        self.results = []

    def git_run(self, repo: Path, *args: str) -> str:
        result = subprocess.run([self.git, "-C", str(repo), *args],
                                env=self.fixture_env, capture_output=True, text=True, check=True)
        return result.stdout.strip()

    def repository(self, name: str, files: dict[str, bytes]) -> tuple[Path, str]:
        repo = self.output / name
        repo.mkdir()
        self.git_run(repo, "init", "-b", "main")
        for name, data in files.items():
            path = repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.git_run(repo, "add", ".")
        self.git_run(repo, "commit", "-qm", "fixture")
        return repo, self.git_run(repo, "rev-parse", "HEAD")

    def run(self, origin: str, revision: str, store: Path, *, offline=False,
            short=False, expected=0, env=None) -> list[str]:
        result = subprocess.run([
            str(self.consumer), "snapshot", origin, revision, str(store),
            "offline" if offline else "online", "short" if short else "normal",
        ], env=self.env | (env or {}), capture_output=True, text=True, timeout=20)
        assert result.returncode == expected, (origin, revision, expected, result.returncode,
                                               result.stdout, result.stderr)
        assert not result.stderr, result.stderr
        if expected:
            assert not result.stdout, result.stdout
            return []
        lines = result.stdout.splitlines()
        assert len(lines) == 3, lines
        assert len(lines[0]) == 40 and len(lines[1]) == 64, lines
        assert lines[2] == f"packages/{lines[1]}/content", lines
        return lines

    def passed(self, name: str):
        self.results.append({"name": name, "status": "passed"})
        print(f"PASS {name}", flush=True)

    @staticmethod
    def digest(files: dict[str, bytes]) -> str:
        digest = hashlib.sha256(b"nyra-package-content-v1\n")
        for name, data in sorted(files.items()):
            path = name.encode()
            digest.update(str(len(path)).encode() + b"\n" + path + b"\n")
            digest.update(str(len(data)).encode() + b"\n" + data)
        return digest.hexdigest()

    @staticmethod
    def clean(store: Path):
        staging = store / "staging"
        assert not staging.exists() or not list(staging.iterdir()), list(staging.iterdir())

    def local(self):
        files = {"README.md": b"fixture\n", "nested/binary": b"\x00\x80\xff\n"}
        repo, commit = self.repository("origin", files)
        origin = repo.as_uri()
        store = self.output / "store"
        identity = self.run(origin, commit, store)
        digest = self.digest(files)
        assert identity[:2] == [commit, digest], identity
        for name, data in files.items():
            assert (store / identity[2] / name).read_bytes() == data
        self.clean(store)
        self.passed("local-snapshot-and-independent-content-digest")

        assert self.run(origin, commit, store, offline=True) == identity
        self.passed("warm-offline")
        cold = self.output / "cold"
        self.run(origin, commit, cold, offline=True, expected=15)
        assert not cold.exists()
        self.passed("cold-offline-without-store-mutation")

        self.run(origin, "0" * 40, store, expected=13)
        self.clean(store)
        self.passed("missing-revision-cleans-stage")
        self.run((self.output / "absent-origin").as_uri(), commit,
                 self.output / "clone-failure", expected=10)
        self.clean(self.output / "clone-failure")
        self.passed("failed-clone-cleans-stage")

        for invalid in ("ssh://example.invalid/repo.git", "https://user:secret@example.invalid/repo", "relative/path"):
            self.run(invalid, commit, store, expected=11)
        self.run(origin + "\ninvalid", commit, store, expected=12)
        self.run(origin, "bad\rrevision", store, expected=12)
        self.passed("origin-and-input-admission")

        self.git_run(repo, "tag", "v1")
        assert self.run(origin, "v1", store)[0] == commit
        (repo / "README.md").write_bytes(b"updated\n")
        self.git_run(repo, "commit", "-qam", "update")
        updated = self.git_run(repo, "rev-parse", "HEAD")
        self.git_run(repo, "tag", "-f", "v1")
        assert self.run(origin, "v1", store)[0] == updated
        assert self.run(origin, "main", store)[0] == updated
        assert self.run(origin, commit, store) == identity
        self.passed("moving-tag-branch-and-fixed-commit")

        moved = self.output / "relocated-store"
        shutil.move(store, moved)
        assert self.run(origin, commit, moved, offline=True) == identity
        self.passed("relocated-store-offline")

        second, second_commit = self.repository("second-origin", files)
        other = self.run(second.as_uri(), second_commit, moved)
        assert other[1:] == identity[1:]
        self.passed("different-origins-share-identical-content")

        key = hashlib.sha256(origin.encode()).hexdigest()
        with (moved / "locks" / key).open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.run(origin, commit, moved, short=True, expected=12)
        assert self.run(origin, commit, moved, offline=True) == identity
        self.passed("origin-lock-timeout-and-release")
        with (moved / "locks" / digest).open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.run(origin, commit, moved, short=True, expected=12)
        self.clean(moved)
        assert self.run(origin, commit, moved, offline=True) == identity
        self.passed("content-lock-timeout-and-release")

        stale = moved / "staging" / f"op-{key}-interrupted"
        stale.mkdir()
        victim = self.output / "must-survive"
        victim.mkdir()
        (victim / "owned").write_text("preserve")
        (stale / "link").symlink_to(victim, target_is_directory=True)
        (stale / "partial").write_text("partial")
        foreign = moved / "staging" / ("op-" + "f" * 64 + "-foreign")
        foreign.mkdir()
        (foreign / "owned").write_text("preserve")
        assert self.run(origin, commit, moved, offline=True) == identity
        assert not stale.exists() and (victim / "owned").read_text() == "preserve"
        assert (foreign / "owned").read_text() == "preserve"
        shutil.rmtree(foreign)
        self.clean(moved)
        self.passed("stale-stage-no-follow-and-foreign-stage-preservation")

        collision = self.output / "publication-collision"
        target = collision / "packages" / digest
        target.parent.mkdir(parents=True)
        target.write_text("caller-owned collision")
        self.run(origin, commit, collision, expected=12)
        assert target.read_text() == "caller-owned collision"
        self.clean(collision)
        target.unlink()
        assert self.run(origin, commit, collision)[1] == digest
        self.passed("failed-publication-preserves-target-and-releases-locks")

        concurrent_store = self.output / "concurrent"
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            tasks = [pool.submit(self.run, url, rev, concurrent_store)
                     for url, rev in [(origin, commit), (second.as_uri(), second_commit)] * 3]
            for task in tasks:
                assert task.result()[1] == digest
        self.clean(concurrent_store)
        self.passed("concurrent-origin-and-content-publication")

        linked, linked_commit = self.repository("linked-origin", {"file": b"data"})
        (linked / "link").symlink_to("file")
        self.git_run(linked, "add", "link")
        self.git_run(linked, "commit", "-qm", "symlink")
        linked_commit = self.git_run(linked, "rev-parse", "HEAD")
        rejected = self.output / "linked-store"
        self.run(linked.as_uri(), linked_commit, rejected, expected=14)
        self.clean(rejected)
        self.passed("symlink-tree-rejection")

        lfs, lfs_commit = self.repository("lfs-origin", {
            "pointer": b"version https://git-lfs.github.com/spec/v1\noid sha256:" + b"0" * 64 + b"\nsize 1\n"})
        rejected = self.output / "lfs-store"
        self.run(lfs.as_uri(), lfs_commit, rejected, expected=14)
        self.clean(rejected)
        self.passed("lfs-tree-rejection")

        # Gitlink entries require no recursive checkout or network operation.
        self.git_run(linked, "update-index", "--add", "--cacheinfo", f"160000,{commit},submodule")
        self.git_run(linked, "update-index", "--force-remove", "link")
        self.git_run(linked, "commit", "-qm", "gitlink")
        rejected = self.output / "submodule-store"
        self.run(linked.as_uri(), self.git_run(linked, "rev-parse", "HEAD"), rejected, expected=14)
        self.clean(rejected)
        self.passed("submodule-tree-rejection")

        # A wide tree can share one tiny blob: test the entry bound without a
        # huge checkout, download or dependence on host filesystem limits.
        blob = self.git_run(repo, "rev-parse", f"{commit}:README.md")
        listing = "".join(f"100644 blob {blob}\tfile-{index:05d}\n" for index in range(10001))
        tree = subprocess.run([self.git, "-C", str(repo), "mktree"], input=listing,
                              env=self.fixture_env, text=True, capture_output=True, check=True).stdout.strip()
        wide_commit = self.git_run(repo, "commit-tree", tree, "-m", "wide fixture")
        self.git_run(repo, "update-ref", "refs/heads/wide", wide_commit)
        rejected = self.output / "wide-store"
        self.run(origin, wide_commit, rejected, expected=14)
        self.clean(rejected)
        self.passed("inventory-entry-limit-cleans-stage")
        return repo, commit

    def locks(self):
        path = self.output / "scoped.lock"
        command = [str(self.consumer), "lock", str(path)]
        for _ in range(3):
            subprocess.run(command, env=self.env, capture_output=True, check=True, timeout=5)
        self.passed("scoped-lock-result-move-drop-and-reacquire")

        holder = subprocess.Popen([*command, "hold"], env=self.env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            # Observe the OS lock, without depending on console buffering.
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                with path.open("r+") as lock:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        break
                time.sleep(0.01)
            else:
                raise AssertionError("scoped owner never held OS lock")
            blocked = subprocess.run(command, env=self.env, capture_output=True, timeout=5)
            assert blocked.returncode == 8, blocked
            holder.kill()
            holder.communicate(timeout=5)
            subprocess.run(command, env=self.env, capture_output=True, check=True, timeout=5)
            self.passed("lock-contention-and-process-death-release")
        finally:
            if holder.poll() is None:
                holder.kill()
                holder.communicate(timeout=5)

        link = self.output / "lock-link"
        link.symlink_to(path)
        rejected = subprocess.run([str(self.consumer), "lock", str(link)],
                                  env=self.env, capture_output=True, timeout=5)
        assert rejected.returncode == 8, rejected
        self.passed("lock-rejects-final-symlink")

    def https(self, repo: Path, commit: str, openssl: Path):
        root = self.output / "https"
        root.mkdir()
        self.git_run(root, "clone", "--bare", str(repo), str(root / "repo.git"))
        key, cert = root / "key.pem", root / "cert.pem"
        config = root / "openssl.cnf"
        config.write_text("[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=localhost\n")
        subprocess.run([str(openssl), "req", "-config", str(config), "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
                       capture_output=True, check=True, timeout=20)
        username, token = "fixture", "local-fixture-token"
        auth = "Basic " + base64.b64encode(f"{username}:{token}".encode()).decode()
        controls = {"slow": False}
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                self.handle_git()

            def do_POST(self):
                self.handle_git()

            def handle_git(self):
                try:
                    if controls["slow"]:
                        time.sleep(0.5)
                    if self.path.startswith("/redirect"):
                        self.send_response(302)
                        self.send_header("Location", "https://127.0.0.1:1/elsewhere")
                        self.end_headers()
                        return
                    if self.headers.get("Authorization") != auth:
                        self.send_response(401)
                        self.send_header("WWW-Authenticate", 'Basic realm="fixture"')
                        self.end_headers()
                        return
                    parsed = urllib.parse.urlsplit(self.path)
                    length = int(self.headers.get("Content-Length", "0"))
                    body = self.rfile.read(length)
                    env = owner.fixture_env | {
                        "GIT_PROJECT_ROOT": str(root), "GIT_HTTP_EXPORT_ALL": "1",
                        "REQUEST_METHOD": self.command, "PATH_INFO": parsed.path,
                        "QUERY_STRING": parsed.query, "CONTENT_LENGTH": str(length),
                        "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                        "REMOTE_USER": username, "SERVER_PROTOCOL": "HTTP/1.1",
                    }
                    response = subprocess.run([owner.git, "http-backend"], input=body,
                                              env=env, capture_output=True, check=True, timeout=10)
                    header, payload = response.stdout.split(b"\r\n\r\n", 1)
                    status, headers = 200, []
                    for line in header.decode().split("\r\n"):
                        field, value = line.split(":", 1)
                        if field.lower() == "status":
                            status = int(value.strip().split()[0])
                        else:
                            headers.append((field, value.strip()))
                    self.send_response(status)
                    for field, value in headers:
                        self.send_header(field, value)
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                    pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        server.socket = tls.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"https://127.0.0.1:{server.server_port}/repo.git"
        trusted = {"NGIT_CA_FILE": str(cert), "NGIT_USERNAME": username, "NGIT_TOKEN": token}
        try:
            self.run(url, commit, self.output / "untrusted", expected=10)
            self.clean(self.output / "untrusted")
            self.passed("https-untrusted-certificate-rejected")
            self.run(url, commit, self.output / "unauthenticated", expected=10,
                     env={"NGIT_CA_FILE": str(cert)})
            self.clean(self.output / "unauthenticated")
            self.passed("https-missing-credentials-rejected")
            snapshot = self.run(url, commit, self.output / "trusted", env=trusted)
            assert snapshot[0] == commit
            self.passed("https-verified-certificate-and-credentials")
            self.run(url.replace("/repo.git", "/redirect"), commit,
                     self.output / "redirect", expected=10, env=trusted)
            self.clean(self.output / "redirect")
            self.passed("https-redirect-rejected")
            controls["slow"] = True
            self.run(url, commit, self.output / "timeout", short=True, expected=10, env=trusted)
            self.clean(self.output / "timeout")
            self.passed("https-timeout-cleans-stage")
        finally:
            controls["slow"] = False
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        assert self.run(url, commit, self.output / "trusted", offline=True, env=trusted) == snapshot
        self.passed("https-offline-after-server-stops")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--consumer", type=Path, required=True)
    parser.add_argument("--openssl", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True, help="New fixture directory")
    args = parser.parse_args()
    suite = Acceptance(args.consumer, args.out_dir)
    completed = False
    try:
        suite.locks()
        repo, commit = suite.local()
        suite.https(repo, commit, args.openssl.resolve())
        completed = True
    finally:
        report = {"status": "passed" if completed else "failed",
                  "passed": len(suite.results), "checks": suite.results,
                  "consumer_sha256": hashlib.sha256(suite.consumer.read_bytes()).hexdigest(),
                  "host": os.uname().sysname + " " + os.uname().machine}
        (suite.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
