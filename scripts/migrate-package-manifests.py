#!/usr/bin/env python3
"""Preview or apply the legacy package metadata migration (Python 3.11+).

All update.toml files have top-level `track` and `strategy` strings. AUR
tracks add `url` and `commit`, manual tracks add `reason`, and workflow tracks
add `workflow`. Existing git-* tracks retain `git` and any updater options.
The upstream-bot registry entry is represented by the existing git-* track.

A dry run prints the actions. Pass --apply to write update.toml files. All
packages are checked before writing, and the legacy files are left in place.
"""

from __future__ import annotations

import argparse
import json
import os
import stat
import subprocess
import sys
import tempfile
import tomllib
from dataclasses import dataclass
from pathlib import Path

# The preview should not create __pycache__ files in the checkout either.
sys.dont_write_bytecode = True

from hub import declaration as decl  # noqa: E402
from hub.update import ON_UPDATE, TRACKS, UPDATE_FILENAME  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM_BOT = ".github/workflows/upstream-bot.yml"


@dataclass(frozen=True)
class Change:
    path: Path
    before: bytes | None
    after: bytes


def toml_line(key: str, value: str) -> bytes:
    # JSON string escaping matches TOML basic strings for these values, except
    # DEL, which TOML requires us to escape. Keep Unicode literal (no surrogates).
    encoded = json.dumps(value, ensure_ascii=False).replace("\x7f", r"\u007f")
    return f"{key} = {encoded}\n".encode("utf-8")


def tracked_paths(root: Path) -> set[str] | None:
    repo = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], cwd=root, capture_output=True,
        check=False,
    )
    if repo.returncode or Path(os.fsdecode(repo.stdout.rstrip(b"\n"))).resolve() != root:
        return None
    result = subprocess.run(["git", "ls-files", "-z"], cwd=root, capture_output=True, check=True)
    return set(os.fsdecode(result.stdout).split("\0"))


def legacy_track(directory: Path, entry: tuple[str, str] | None) -> dict[str, str]:
    aur, errors = decl.read_aur(directory / decl.AUR_URL_FILENAME,
                               directory / decl.AUR_COMMIT_FILENAME)
    if errors:
        raise ValueError("; ".join(errors))
    if aur is not None:
        if entry is not None:
            raise ValueError("declares both an AUR mirror and a registry entry")
        return {"track": "aur", "url": aur.url, "commit": aur.commit}
    if entry is None:
        return {}
    kind, detail = entry
    return {"track": kind, "workflow" if kind == "workflow" else "reason": detail}


def check_workflow(root: Path, workflow: str, tracked: set[str] | None) -> None:
    path = Path(workflow)
    if path.is_absolute() or ".." in path.parts or path.as_posix() != workflow:
        raise ValueError(f"workflow must be a repository-relative path: {workflow!r}")
    if not (root / path).is_file():
        raise ValueError(f"missing workflow file {workflow!r}")
    if tracked is not None and workflow not in tracked:
        raise ValueError(f"workflow file is not tracked by git: {workflow!r}")


def required_string(data: dict, key: str) -> str:
    value = data.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{UPDATE_FILENAME}: {key} must be a nonempty string")
    return value


def check_track(data: dict, root: Path, tracked: set[str] | None) -> str:
    track = required_string(data, "track")
    if track in TRACKS:
        required_string(data, "git")
        for key in ("tag_pattern", "pkgver_from", "on_update"):
            if key in data and not isinstance(data[key], str):
                raise ValueError(f"{UPDATE_FILENAME}: {key} must be a string")
        if (data.get("on_update", "").strip() or "pull-request") not in ON_UPDATE:
            raise ValueError(f"{UPDATE_FILENAME}: invalid on_update value")
    elif track == "aur":
        if not decl.AUR_URL.fullmatch(required_string(data, "url")):
            raise ValueError(f"{UPDATE_FILENAME}: invalid AUR URL")
        if not decl.GIT_COMMIT.fullmatch(required_string(data, "commit")):
            raise ValueError(f"{UPDATE_FILENAME}: invalid AUR commit")
    elif track == "manual":
        required_string(data, "reason")
    elif track == "workflow":
        check_workflow(root, required_string(data, "workflow"), tracked)
    else:
        raise ValueError(f"{UPDATE_FILENAME}: unknown track {track!r}")
    return track


def plan_package(directory: Path, entry: tuple[str, str] | None,
                 root: Path, tracked: set[str] | None) -> tuple[str, Change | None]:
    if directory.is_symlink():
        raise ValueError("package directory is a symlink")
    path = directory / UPDATE_FILENAME
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"{UPDATE_FILENAME} is not a regular file")
    before = path.read_bytes() if path.exists() else None
    legacy = legacy_track(directory, entry)
    if "workflow" in legacy:
        check_workflow(root, legacy["workflow"], tracked)
    if before is None and not legacy:
        raise ValueError("no legacy update source declared")

    data = tomllib.loads(before.decode("utf-8")) if before is not None else legacy.copy()
    track = check_track(data, root, tracked)
    # The legacy registry named the common dispatcher. For a git-* declaration
    # the updater settings describe what that dispatcher actually does.
    git_dispatch = track in TRACKS and legacy == {"track": "workflow", "workflow": UPSTREAM_BOT}
    if legacy and not git_dispatch:
        for key, value in legacy.items():
            if data.get(key) != value:
                raise ValueError(f"{UPDATE_FILENAME}: {key} conflicts with legacy metadata")

    strategy_path = directory / decl.BUILD_STRATEGY_FILENAME
    strategy = decl.normalize_build_strategy(data.get("strategy"))
    if "strategy" in data and strategy is None:
        raise ValueError(f"{UPDATE_FILENAME}: invalid strategy {data['strategy']!r}")
    if strategy_path.exists() or "strategy" not in data:
        legacy_strategy, errors = decl.read_build_strategy(strategy_path)
        if errors:
            raise ValueError("; ".join(errors))
        if "strategy" in data and strategy != legacy_strategy:
            raise ValueError(f"{UPDATE_FILENAME}: strategy conflicts with legacy metadata")
        strategy = legacy_strategy

    if before is None:
        after = toml_line("track", track) + toml_line("strategy", strategy)
        after += b"".join(toml_line(key, value) for key, value in legacy.items() if key != "track")
    elif "strategy" not in data:
        # Prepend so the key is top-level even if the file ends with a table.
        # Preserve the remainder verbatim, including comments and CRLF endings.
        newline = b"\r\n" if b"\r\n" in before else b"\n"
        after = toml_line("strategy", strategy).rstrip(b"\n") + newline + before
    else:
        return track, None
    tomllib.loads(after.decode("utf-8"))
    return track, Change(path, before, after)


def apply_change(change: Change) -> None:
    path = change.path
    # Build the full file before publishing it. Create with an exclusive hard
    # link so another writer cannot lose a newly created declaration to ours.
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".migrate-", delete=False) as stream:
        pending = Path(stream.name)
    try:
        pending.write_bytes(change.after)
        if change.before is None:
            pending.chmod(0o644)
            path.hardlink_to(pending)
        else:
            if path.is_symlink() or path.read_bytes() != change.before:
                raise OSError(f"{path} changed since planning")
            pending.chmod(stat.S_IMODE(path.stat().st_mode))
            pending.replace(path)
    finally:
        pending.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root (default: this checkout)")
    parser.add_argument("--apply", action="store_true", help="write the planned migrations")
    args = parser.parse_args()
    root = args.root.resolve()

    try:
        directories = decl.package_dirs(root)
        if not directories:
            raise ValueError(f"no package directories found under {root / decl.PACKAGE_ROOT}")
        if (root / decl.PACKAGE_ROOT).is_symlink():
            raise ValueError("packages directory is a symlink")
        registry_path = root / decl.REGISTRY_PATH
        registry, errors = decl.read_registry(registry_path) if registry_path.exists() else ({}, [])
        tracked = tracked_paths(root)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    for unknown in sorted(registry.keys() - {p.name for p in directories}):
        errors.append(f"{decl.REGISTRY_PATH}: no such package directory packages/{unknown}")
    plans = []
    for directory in directories:
        try:
            track, change = plan_package(directory, registry.get(directory.name), root, tracked)
            plans.append((directory, track, change))
        except (OSError, ValueError) as exc:
            errors.append(f"{directory.relative_to(root)}: {exc}")
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print("No manifests written.", file=sys.stderr)
        return 2

    counts = {"CREATE": 0, "UPDATE": 0, "KEEP": 0}
    for directory, track, change in plans:
        action = "KEEP" if change is None else "CREATE" if change.before is None else "UPDATE"
        if args.apply and change is not None:
            try:
                apply_change(change)
            except OSError as exc:
                print(f"ERROR: {exc}", file=sys.stderr)
                return 2
        counts[action] += 1
        print(f"{action:6} {(directory / UPDATE_FILENAME).relative_to(root)} ({track})")
    summary = ", ".join(f"{amount} {action.lower()}" for action, amount in counts.items())
    mode = "Applied" if args.apply else "Dry run"
    print(f"{mode}: {len(plans)} packages, {summary}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
