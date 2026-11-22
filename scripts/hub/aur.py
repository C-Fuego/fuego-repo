#!/usr/bin/env python3
"""Read AUR metadata for the shell tools and refresh its pinned commit."""

import argparse
import ctypes
import os
import re
import shutil
import sys
import tomllib
from pathlib import Path

COMMIT = re.compile(r"[0-9a-fA-F]{40}")
PACKAGE = re.compile(r"[A-Za-z0-9@._+-]+")
COMMIT_VALUE = re.compile(
    r'''^[ \t]*(?:commit|"(?:[^"\\\r\n]|\\.)*"|'commit')[ \t]*=[ \t]*(?P<value>['"])''',
    re.MULTILINE,
)


def aur_metadata(directory: Path, *, audit: bool = False) -> tuple[str, str] | None:
    metadata = directory / "update.toml"
    if metadata.exists() or metadata.is_symlink():
        data = tomllib.loads(metadata.read_text(encoding="utf-8"))
        if data.get("track") != "aur":
            return None
        url, commit = data.get("url"), data.get("commit")
        source = metadata.name
    elif audit:
        url_file, commit_file = directory / ".aur-url", directory / ".aur-commit"
        if not url_file.is_file():
            if commit_file.is_file():
                raise ValueError(".aur-commit is present without .aur-url")
            return None
        url = url_file.read_text(encoding="utf-8").rstrip("\n")
        commit = commit_file.read_text(encoding="utf-8").strip() if commit_file.is_file() else ""
        source = url_file.name
    else:
        return None

    if (not isinstance(url, str) or not url or url.startswith("-")
            or any(c.isspace() or not c.isprintable() for c in url)):
        raise ValueError(f"{source}: expected an explicit Git clone URL without whitespace or controls")
    if not isinstance(commit, str) or not COMMIT.fullmatch(commit):
        pin = f"{source}: commit" if source == metadata.name else ".aur-commit"
        raise ValueError(f"{pin} must be a 40-character hexadecimal Git commit")
    return url, commit.lower()


def refresh_commit(source: Path, destination: Path, commit: str) -> None:
    if not COMMIT.fullmatch(commit):
        raise ValueError("upstream HEAD is not a 40-character hexadecimal Git commit")
    original = source.read_bytes().decode("utf-8")
    data = tomllib.loads(original)
    if data["commit"] == commit:
        shutil.copy2(source, destination)
        return
    # repr also compares TOML NaN values, which are unequal even to themselves.
    expected = repr({**data, "commit": commit})

    # Only replace the value token. Reparse candidates to reject matches inside
    # tables or multiline strings without reserializing user metadata.
    for match in COMMIT_VALUE.finditer(original):
        start = match.start("value")
        quote = match.group("value")
        delimiter = quote * 3 if original.startswith(quote * 3, start) else quote
        end = start + len(delimiter)
        while (end := original.find(delimiter, end)) != -1:
            end += len(delimiter)
            try:
                old = tomllib.loads(f"value = {original[start:end]}")["value"]
            except tomllib.TOMLDecodeError:
                continue  # e.g. a basic string with an escaped quote
            if old == data["commit"]:
                candidate = original[:start] + delimiter + commit + delimiter + original[end:]
                try:
                    if repr(tomllib.loads(candidate)) == expected:
                        destination.write_bytes(candidate.encode("utf-8"))
                        shutil.copymode(source, destination)
                        return
                except tomllib.TOMLDecodeError:
                    pass
            break
    raise ValueError(f"{source}: unable to replace the top-level commit without modifying other metadata")


def publish(staged: Path, destination: Path) -> None:
    # Linux renameat2 exchanges the two directories in one filesystem operation.
    # The displaced directory remains under the disposable staging root.
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = libc.renameat2
    renameat2.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
    renameat2.restype = ctypes.c_int
    at_fdcwd, rename_exchange = -100, 2
    if renameat2(at_fdcwd, os.fsencode(staged), at_fdcwd, os.fsencode(destination), rename_exchange):
        error = ctypes.get_errno()
        raise OSError(error, f"cannot atomically replace {destination}: {os.strerror(error)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    select = subparsers.add_parser("select")
    select.add_argument("root", type=Path)
    select.add_argument("packages", nargs="*")
    audit = subparsers.add_parser("audit")
    audit.add_argument("directory", type=Path)
    refresh = subparsers.add_parser("refresh")
    refresh.add_argument("source", type=Path)
    refresh.add_argument("destination", type=Path)
    refresh.add_argument("commit")
    swap = subparsers.add_parser("publish")
    swap.add_argument("staged", type=Path)
    swap.add_argument("destination", type=Path)
    args = parser.parse_args()

    try:
        if args.command == "select":
            root = args.root / "packages"
            names = args.packages or sorted(
                d.name for d in root.iterdir() if d.is_dir() and not d.is_symlink()
            )
            for name in dict.fromkeys(names):
                directory = root / name
                if name in (".", "..") or not PACKAGE.fullmatch(name) or directory.is_symlink():
                    raise ValueError(f"invalid package name or directory: {name!r}")
                try:
                    metadata = aur_metadata(directory)
                except (ValueError, OSError) as exc:
                    raise ValueError(f"{name}: {exc}") from exc
                if metadata:
                    print(name, *metadata, sep="\t")
                elif args.packages:
                    print(f"{name} has no AUR track in update.toml.", file=sys.stderr)
                    return 1
        elif args.command == "audit":
            metadata = aur_metadata(args.directory, audit=True)
            if metadata:
                print(metadata[0])
        elif args.command == "refresh":
            refresh_commit(args.source, args.destination, args.commit)
        elif args.command == "publish":
            publish(args.staged, args.destination)
    except (AttributeError, OSError, ValueError) as exc:
        print(exc, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
