#!/usr/bin/env python3
"""Local package imports and the package inventory."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from bot import declaration as decl  # noqa: E402
from bot import update  # noqa: E402
from lib.pkgbuild_lib import PACKAGE_NAME_PATTERN, SourceInfoError, parse_srcinfo  # noqa: E402

TRACKS = decl.UPDATE_TRACKS
UPDATE_FILE = decl.UPDATE_FILENAME
MANUAL_REASON = "Imported from a local PKGBUILD; updates are maintained manually."
REPLACED_METADATA = {UPDATE_FILE, ".aur-url", ".aur-commit", ".build-strategy"}


class ManageError(RuntimeError):
    pass


def checked_name(name: str) -> str:
    if not PACKAGE_NAME_PATTERN.fullmatch(name) or name.startswith(("-", ".")):
        raise ManageError(f"invalid package name: {name!r}")
    return name


def regular_file(directory: Path, name: str) -> Path:
    path = directory / name
    if not path.is_file() or path.is_symlink():
        raise ManageError(f"{directory}: missing regular {name}")
    return path


def run(*argv: str, cwd: Path | None = None, env: dict | None = None) -> str:
    if not shutil.which(argv[0]):
        raise ManageError(f"{argv[0]} is required for this import but is not on PATH")
    result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise ManageError(f"{' '.join(argv[:2])} failed: {result.stderr.strip() or result.returncode}")
    return result.stdout


def prompt(label: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    print(f"{label}{suffix}: ", file=sys.stderr, end="", flush=True)
    answer = sys.stdin.readline()
    if not answer:
        raise ManageError("import cancelled")
    return answer.strip() or default


def options_for_track(args: argparse.Namespace, track: str) -> None:
    allowed = {
        "reason": track == "manual", "workflow": track == "workflow",
        "git": track in update.TRACKS, "on_update": track in update.TRACKS,
        "tag_pattern": track in ("git-tag", "git-tag-pin"), "pkgver_from": track == "git-tag",
    }
    for option, accepted in allowed.items():
        if getattr(args, option) is not None and not accepted:
            raise ManageError(f"--{option.replace('_', '-')} is not valid with --track {track}")


def git_source(srcinfo: str) -> str | None:
    """Infer an upstream only from a single, unpinned Git source."""
    urls = set(re.findall(r"(?m)^\s*source(?:_[\w-]+)? = (?:[^\n]*?::)?git\+([^\n]+)$", srcinfo))
    if len(urls) != 1:
        return None
    url = urls.pop().strip()
    return url if re.fullmatch(r"(?:https?|ssh|git)://[^\s#$?]+", url) else None


def local_spec(root: Path, args: argparse.Namespace, stage: Path,
               srcinfo: str, has_pkgver: bool) -> dict[str, str]:
    inferred_git = git_source(srcinfo)
    default = "git-vcs" if has_pkgver and inferred_git else "manual"
    guided = not args.non_interactive and sys.stdin.isatty()
    track = args.track
    if track is None and args.reason is not None:
        track = "manual"
    if track is None and args.workflow is not None:
        track = "workflow"
    if track is None and guided:
        track = prompt(f"Update track ({', '.join(TRACKS[1:])})", default)
    track = track or default
    if track not in TRACKS[1:]:
        raise ManageError(f"invalid local update track: {track!r}")
    options_for_track(args, track)

    if track == "manual":
        suggested = "" if args.track else MANUAL_REASON
        reason = args.reason if args.reason is not None else (
            prompt("Why are updates manual?", suggested) if guided else suggested
        )
        if not reason.strip():
            raise ManageError("manual track requires a nonempty --reason")
        return {"track": track, "reason": reason.strip()}
    if track == "workflow":
        value = args.workflow if args.workflow is not None else (
            prompt("Workflow path (relative to the repository)") if guided else ""
        )
        path = Path(value)
        if (path.parent != Path(".github/workflows") or path.suffix not in (".yml", ".yaml")
                or not (root / path).is_file()):
            raise ManageError("workflow track requires --workflow .github/workflows/<existing-file>.yml")
        return {"track": track, "workflow": path.as_posix()}
    if track == "git-vcs" and not has_pkgver:
        raise ManageError("git-vcs track requires a pkgver() function")
    if track in ("git-tag-pin", "git-commit") and not decl.read_pkgbuild_variable(stage, "_commit"):
        raise ManageError(f"{track} track requires a _commit assignment in PKGBUILD")
    git = args.git if args.git is not None else (
        prompt("Upstream Git URL", inferred_git or "") if guided else inferred_git or ""
    )
    git = git.strip()
    if not git or git.startswith("-") or "::" in git.split("://", 1)[0] or re.search(r"\s", git):
        raise ManageError(f"{track} track requires a valid --git URL")
    spec = {"track": track, "git": git}
    for key in ("tag_pattern", "pkgver_from", "on_update"):
        value = getattr(args, key)
        if value is not None:
            spec[key] = value
    if "tag_pattern" in spec:
        re.compile(spec["tag_pattern"])
    if "pkgver_from" in spec:
        name, _, arg = spec["pkgver_from"].partition(":")
        if name not in ("identity", "strip_v", "date_version", "regex_extract"):
            raise ManageError(f"unknown --pkgver-from function {name!r}")
        if name == "regex_extract":
            if not arg:
                raise ManageError("--pkgver-from regex_extract requires a pattern")
            re.compile(arg)
    return spec


def copy_local(source: Path, stage: Path) -> None:
    regular_file(source, "PKGBUILD")

    def ignored(parent: str, names: list[str]) -> set[str]:
        skip = {".git"}
        if Path(parent) == source:
            skip.update(REPLACED_METADATA | {".SRCINFO"})
        for name in set(names) - skip:
            path = Path(parent) / name
            if path.is_symlink():
                if path.readlink().is_absolute() or not path.resolve().is_relative_to(source):
                    raise ManageError(f"support file symlink points outside the package: {path}")
            elif not (path.is_file() or path.is_dir()):
                raise ManageError(f"unsupported file in local package: {path}")
        return skip.intersection(names)

    shutil.copytree(source, stage, symlinks=True, ignore=ignored)


def aur_base_for_name(name: str) -> str:
    query = urlencode({"arg[]": name})
    with urlopen(f"https://aur.archlinux.org/rpc/v5/info?{query}", timeout=20) as response:
        results = json.load(response).get("results", [])
    for result in results:
        if result.get("Name") == name and isinstance(result.get("PackageBase"), str):
            return checked_name(result["PackageBase"])
    raise ManageError(f"{name} was not found in AUR")


def stage_aur(name: str, stage: Path, scratch: Path) -> dict[str, str]:
    def clone(base: str, checkout: Path) -> tuple[str, str]:
        url = f"https://aur.archlinux.org/{base}.git"
        run("git", "clone", "--depth", "1", "--no-checkout", "--", url, str(checkout))
        return url, run("git", "-C", str(checkout), "rev-parse", "--verify", "HEAD").strip()

    checkout = scratch / "aur"
    try:
        url, commit = clone(name, checkout)
    except ManageError as original:
        # Split package names can differ from the base used as the Git repo name.
        if not shutil.which("git"):
            raise
        try:
            base = aur_base_for_name(name)
        except (ManageError, ValueError, OSError) as exc:
            raise ManageError(f"{original}; {exc}") from exc
        if base == name:
            raise original
        checkout = scratch / "aur-base"
        url, commit = clone(base, checkout)
    if not decl.GIT_COMMIT.fullmatch(commit):
        raise ManageError(f"invalid AUR commit: {commit!r}")
    archive = scratch / "aur.tar"
    run("git", "-C", str(checkout), "archive", "--format=tar", f"--output={archive}", commit)
    stage.mkdir()
    with tarfile.open(archive) as tree:
        for member in tree:
            parts = Path(member.name).parts
            if ".git" in parts or (len(parts) == 1 and parts[0] in REPLACED_METADATA):
                continue
            tree.extract(member, stage, filter="data")
    return {"track": "aur", "url": url, "commit": commit}


def require_no_overlay(root: Path, name: str) -> None:
    if (root / "scripts" / "overlays" / f"{name}.sh").is_file():
        raise ManageError(f"{name} has a local overlay; import a reviewed, overlaid PKGBUILD with --from")


def add(root: Path, args: argparse.Namespace) -> None:
    name = checked_name(args.package)
    packages = root / "packages"
    if packages.is_symlink():
        raise ManageError(f"refusing to import through a symlink: {packages}")
    destination = packages / name
    if destination.exists() or destination.is_symlink():
        raise ManageError(f"{name} is already managed; refusing to overwrite packages/{name}")
    source = args.source.resolve() if args.source is not None else None
    if source is not None:
        if args.track == "aur":
            raise ManageError("--track aur imports from AUR and cannot be used with --from")
        if not source.is_dir() or packages.is_relative_to(source):
            raise ManageError("--from must name a PKGBUILD directory outside the repository's packages root")
        if args.track:
            options_for_track(args, args.track)
    else:
        if args.track not in (None, "aur"):
            raise ManageError("non-AUR tracks require --from <local PKGBUILD directory>")
        options_for_track(args, "aur")
        require_no_overlay(root, name)

    packages.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".manage-", dir=packages) as temporary:
        scratch = Path(temporary)
        stage = scratch / "package"
        if source is not None:
            copy_local(source, stage)
            env = os.environ.copy()
            for key in ("BUILDDIR", "SRCDEST", "PKGDEST", "LOGDEST"):
                target = scratch / key.lower()
                target.mkdir()
                env[key] = str(target)
            # makepkg sources the explicitly supplied local recipe, never AUR.
            print("Generating .SRCINFO (makepkg sources the local PKGBUILD).", file=sys.stderr)
            srcinfo = run("makepkg", "--printsrcinfo", cwd=stage, env=env)
            with (stage / ".SRCINFO").open("x", encoding="utf-8") as stream:
                stream.write(srcinfo)
        else:
            spec = stage_aur(name, stage, scratch)
            srcinfo = regular_file(stage, ".SRCINFO").read_text(encoding="utf-8")

        metadata = parse_srcinfo(stage / ".SRCINFO")
        if len(re.findall(r"(?m)^pkgbase = \S+\s*$", srcinfo)) != 1 or not metadata.pkgver or not metadata.pkgrel:
            raise ManageError(".SRCINFO must declare one pkgbase, pkgver and pkgrel")
        for declared in (metadata.base, *metadata.packages):
            checked_name(declared)
        if source is not None and metadata.base != name:
            raise ManageError(f"requested pkgbase {name!r} does not match .SRCINFO pkgbase {metadata.base!r}")
        if source is None:
            if (name not in (metadata.base, *metadata.packages)
                    or spec["url"] != f"https://aur.archlinux.org/{metadata.base}.git"):
                raise ManageError(f"AUR .SRCINFO does not match {name!r} and the cloned package base")
            require_no_overlay(root, metadata.base)
        destination = packages / metadata.base
        if destination.exists() or destination.is_symlink():
            raise ManageError(f"{metadata.base} is already managed; refusing to overwrite {destination.relative_to(root)}")

        recipe = regular_file(stage, "PKGBUILD").read_text(encoding="utf-8")
        has_pkgver = bool(decl.PKGVER_FUNCTION.search(recipe))
        strategy = args.strategy or ("vcs" if has_pkgver else "source")
        if (strategy == "vcs" and not has_pkgver) or (strategy == "binary" and has_pkgver):
            raise ManageError(f"strategy {strategy!r} is inconsistent with the recipe's pkgver() function")
        if source is not None:
            spec = local_spec(root, args, stage, srcinfo, has_pkgver)
        spec["strategy"] = strategy
        with (stage / UPDATE_FILE).open("x", encoding="utf-8") as stream:
            for key, value in spec.items():
                encoded = json.dumps(value, ensure_ascii=False).replace("\x7f", "\\u007f")
                stream.write(f"{key} = {encoded}\n")
        _, _, errors = decl.read_update(stage / UPDATE_FILE)
        if errors:
            raise ManageError("; ".join(errors))
        stage.rename(destination)

    print(f"Added packages/{metadata.base} (track: {spec['track']}; strategy: {strategy}).")
    print("Review PKGBUILD, .SRCINFO and support files before building or committing.")
    if (root / "removals" / metadata.base).is_file():
        print(f"Note: review the existing removals/{metadata.base} marker before publishing.")


def read_spec(directory: Path, registry: dict) -> dict:
    if decl.has_update_file(directory):
        source, strategy, errors = decl.read_update(directory / UPDATE_FILE)
        if errors:
            raise ManageError("; ".join(errors))
    else:
        strategy, _ = decl.read_build_strategy(directory / decl.BUILD_STRATEGY_FILENAME)
        legacy_url = directory / decl.AUR_URL_FILENAME
        legacy_commit = directory / decl.AUR_COMMIT_FILENAME
        if legacy_url.is_file():
            return {"track": "aur", "strategy": strategy or "-",
                    "url": legacy_url.read_text(encoding="utf-8").strip(),
                    "commit": legacy_commit.read_text(encoding="utf-8").strip() if legacy_commit.is_file() else "-"}
        if directory.name in registry:
            kind, detail = registry[directory.name]
            return {"track": kind, "strategy": strategy or "-",
                    "workflow" if kind == "workflow" else "reason": detail}
        source = None
    fields = {"track": "-", "strategy": strategy or "-"}
    if isinstance(source, decl.AurMirror):
        fields.update(track="aur", url=source.url, commit=source.commit)
    elif isinstance(source, decl.ManualUpdate):
        fields.update(track="manual", reason=source.reason)
    elif isinstance(source, decl.WorkflowUpdate):
        fields.update(track="workflow", workflow=source.path)
    elif isinstance(source, decl.GitUpdate):
        fields.update(track=source.track, git=source.git, on_update=source.on_update)
        if source.tag_pattern:
            fields["tag_pattern"] = source.tag_pattern
        if source.track == "git-tag":
            fields["pkgver_from"] = source.pkgver_from
    return fields


def packages_overview(root: Path, args: argparse.Namespace) -> None:
    registry, _ = decl.read_registry(root / decl.REGISTRY_PATH)
    directories = decl.package_dirs(root)
    name = getattr(args, "package", None)
    if name:
        checked_name(name)
        directories = [directory for directory in directories if directory.name == name]
        if not directories:
            raise ManageError(f"unknown package base: {name}")
    if not name and not getattr(args, "no_header", False):
        print("PACKAGE\tVERSION\tTRACK\tSTRATEGY")
    for directory in directories:
        try:
            spec = read_spec(directory, registry)
            track = spec.get("track", "-")
        except (ManageError, OSError, ValueError) as exc:
            if name:
                raise ManageError(f"cannot read {name} declaration: {exc}") from exc
            print(f"{directory.name}: cannot read declaration: {exc}", file=sys.stderr)
            spec, track = {}, "invalid"
        if getattr(args, "track", None) not in (None, track):
            continue
        try:
            info = parse_srcinfo(directory / ".SRCINFO")
            version = info.version or "-"
        except (SourceInfoError, UnicodeError):
            info, version = None, "-"
        strategy = spec.get("strategy", "-")
        if not name:
            print(f"{directory.name}\t{version}\t{track}\t{strategy}")
            continue
        print(f"Package: {name}\nVersion: {version}\nTrack: {track}\nStrategy: {strategy}")
        if info:
            print(f"Outputs: {', '.join(info.packages)}")
        for key in ("url", "commit", "git", "tag_pattern", "pkgver_from", "on_update", "reason", "workflow"):
            if key in spec:
                print(f"{key}: {spec[key]}")
        schedule = spec.get("schedule")
        if isinstance(schedule, dict):
            print(f"schedule: {schedule.get('cron', decl.DEFAULT_SCHEDULE)} ({schedule.get('timezone', decl.DEFAULT_TIMEZONE)})")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help=argparse.SUPPRESS)
    commands = parser.add_subparsers(dest="command", required=True)
    add_parser = commands.add_parser("add", prog="./manage.sh add", help="import an AUR or a local package")
    add_parser.description = "Import locally without pulling, staging, committing, or pushing Git changes."
    add_parser.add_argument("package", metavar="PACKAGE", help="AUR package name or local pkgbase")
    add_parser.add_argument("--from", dest="source", type=Path, metavar="DIR",
                            help="trusted local PKGBUILD directory (runs makepkg --printsrcinfo)")
    add_parser.add_argument("--track", choices=TRACKS, help="update mechanism; AUR by default without --from")
    add_parser.add_argument("--strategy", choices=decl.BUILD_STRATEGIES,
                            type=lambda value: decl.normalize_build_strategy(value) or value,
                            help="build strategy; defaults to vcs with pkgver(), otherwise source")
    add_parser.add_argument("--reason", help="reason updates are manual")
    add_parser.add_argument("--workflow", help="repository-relative workflow file")
    add_parser.add_argument("--git", help="upstream Git URL for git-* tracks")
    add_parser.add_argument("--tag-pattern", help="regex selecting upstream tags")
    add_parser.add_argument("--pkgver-from", help="git-tag version conversion rule")
    add_parser.add_argument("--on-update", choices=update.ON_UPDATE, help="git-* update action")
    add_parser.add_argument("--non-interactive", action="store_true", help="do not prompt for update options")
    package_parser = commands.add_parser("packages", prog="./manage.sh packages", help="show the package inventory")
    overview = package_parser.add_subparsers(dest="view")
    list_parser = overview.add_parser("list", help="list package bases, versions, tracks and strategies")
    list_parser.add_argument("--track", choices=TRACKS, help="filter by update track")
    list_parser.add_argument("--no-header", action="store_true", help="omit the column header")
    show_parser = overview.add_parser("show", help="show details for one package base")
    show_parser.add_argument("package", metavar="PKGBASE")
    args = parser.parse_args(argv)
    try:
        root = args.root.resolve()
        if args.command == "add":
            add(root, args)
        else:
            packages_overview(root, args)
    except (ManageError, SourceInfoError, OSError, ValueError, re.error, subprocess.TimeoutExpired, tarfile.TarError) as exc:
        print(f"manage: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nmanage: cancelled", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
