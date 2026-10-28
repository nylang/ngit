"""Apply the retained, exact-source Windows libgit2 path-buffer correction."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path

NATIVE = Path(__file__).resolve().parents[1] / 'private/native'


def locked_patch() -> dict:
    return json.loads((NATIVE / 'libgit2-windows-long-paths.json').read_text())


def apply_patch(source: Path) -> dict:
    record = locked_patch()
    patch = NATIVE / Path(record['path']).name
    if hashlib.sha256(patch.read_bytes()).hexdigest() != record['sha256']:
        raise ValueError('libgit2 Windows patch digest mismatch')
    # Retained unified hunks, exact context only. No fuzz or external patch/Git.
    sections = {}; current = None
    for line in patch.read_text().splitlines(keepends=True):
        if line.startswith('--- a/'):
            current = line[len('--- a/'):].strip(); sections[current] = []
        elif line.startswith('@@'):
            sections[current].append([])
        elif line.startswith('+++ '):
            continue
        elif current and sections[current]:
            sections[current][-1].append(line)
    if set(sections) != {row['path'] for row in record['files']}:
        raise ValueError('libgit2 Windows patch file inventory mismatch')
    changes = []
    for row in record['files']:
        path = source / row['path']
        data = path.read_bytes().replace(b'\r\n', b'\n')
        current = hashlib.sha256(data).hexdigest()
        if current == row['patched_sha256']:
            continue
        if current != row['original_sha256']:
            raise ValueError('libgit2 Windows patch source digest mismatch')
        for hunk in sections[row['path']]:
            before = ''.join(line[1:] for line in hunk if line[0] in ' -').encode()
            after = ''.join(line[1:] for line in hunk if line[0] in ' +').encode()
            if data.count(before) != 1:
                raise ValueError('libgit2 Windows patch context mismatch')
            data = data.replace(before, after, 1)
        if hashlib.sha256(data).hexdigest() != row['patched_sha256']:
            raise ValueError('libgit2 Windows patched source digest mismatch')
        changes.append((path, data))
    for path, data in changes:
        path.write_bytes(data)
    return record

