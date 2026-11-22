#!/usr/bin/env python3
"""Declarative upstream updates, driven by a per-package update.toml.

A package opts in by carrying a `packages/<name>/update.toml`:

    track = "git-tag"          # git-tag | git-commit | git-vcs
    git   = "https://github.com/user/repo"
    tag_pattern = "^v(\\d+\\.\\d+\\.\\d+)$"   # git-tag only
    on_update = "pull-request"               # pull-request | issue | none

What each track does when its upstream moves:

  git-tag     a new tag matching tag_pattern exists  -> pkgver=<tag>, pkgrel=1
  git-commit  upstream HEAD differs from _commit      -> _commit=<sha>, pkgrel+1
  git-vcs     upstream HEAD differs from the built rev -> pkgrel+1 (pkgver() re-derives)

The script never edits the working tree by itself: it computes the change and,
with --apply, rewrites PKGBUILD (+ regenerates .SRCINFO via makepkg) in place.
The workflow runs it inside a fresh branch so the change arrives as a pull
request, not a silent commit.

It reuses scripts/hub/pins.py for git probing and scripts/lib/pkgrel-policy.sh
for pkgrel arithmetic, so a bump here obeys the same policy every other entry
point does.

Exit status: 0 when every declared package is current, 10 when at least one
has an available update (a normal "please open a PR" signal), 2 when the check
could not run -- a probe failure is never "no update".
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from hub import declaration as decl  # noqa: E402
from hub import pins  # noqa: E402

UPDATE_FILENAME = "update.toml"
TRACKS = ("git-tag", "git-commit", "git-vcs")
ON_UPDATE = ("pull-request", "issue", "none")

#: Exit code meaning "there is at least one update to carry".
HAS_UPDATE = 10
FAILED = 2


@dataclass(frozen=True)
class UpdateSpec:
    package: str
    directory: Path
    track: str
    git: str
    tag_pattern: str = ""
    pkgver_from: str = "strip_v"
    on_update: str = "pull-request"


@dataclass
class Plan:
    package: str
    track: str
    available: bool
    old: str = ""
    new: str = ""
    detail: str = ""
    error: str = ""
    edits: list[tuple[str, str]] = field(default_factory=list)  # (field, new-value)
    directory: Path = field(default_factory=lambda: ROOT)


def read_specs(root: Path, only: set[str] | None = None) -> tuple[list[UpdateSpec], list[str]]:
    specs: list[UpdateSpec] = []
    errors: list[str] = []
    for directory in decl.package_dirs(root):
        path = directory / UPDATE_FILENAME
        if not path.is_file():
            continue
        name = directory.name
        if only is not None and name not in only:
            continue
        try:
            data = tomllib.loads(path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError) as exc:
            errors.append(f"{name}: cannot read {UPDATE_FILENAME}: {exc}")
            continue
        track = str(data.get("track", "")).strip()
        git = str(data.get("git", "")).strip()
        if track not in TRACKS:
            errors.append(f"{name}: track must be one of {', '.join(TRACKS)} (got {track!r})")
            continue
        if not git:
            errors.append(f"{name}: update.toml has no git URL")
            continue
        on_update = str(data.get("on_update", "pull-request")).strip() or "pull-request"
        if on_update not in ON_UPDATE:
            errors.append(f"{name}: on_update must be one of {', '.join(ON_UPDATE)} (got {on_update!r})")
            continue
        specs.append(UpdateSpec(
            package=name, directory=directory, track=track, git=git,
            tag_pattern=str(data.get("tag_pattern", "")).strip(),
            pkgver_from=str(data.get("pkgver_from", "strip_v")).strip() or "strip_v",
            on_update=on_update,
        ))
    if only is not None:
        present = {spec.package for spec in specs}
        for missing in sorted(only - present):
            errors.append(f"{missing}: no {UPDATE_FILENAME}")
    return specs, errors


def apply_version_function(raw: str, function: str) -> str:
    """Turn an upstream tag into a pkgver using a named, non-executable rule.

    The function language is deliberately a closed set: a config file must not
    be able to run code.  Unknown names are an error the caller reports, never
    a silent passthrough.
    """
    name, _, arg = function.partition(":")
    name = name.strip()
    if name in ("", "identity"):
        return raw
    if name == "strip_v":
        return re.sub(r"^v", "", raw)
    if name == "date_version":
        # 2026-11-22 / 20261122 / v2026.11.22 -> 2026.11.22
        digits = re.sub(r"\D", "", raw)
        if len(digits) >= 8:
            return f"{digits[0:4]}.{digits[4:6]}.{digits[6:8]}"
        return raw
    if name == "regex_extract":
        match = re.search(arg, raw)
        if match is None:
            raise ValueError(f"regex_extract:{arg} did not match {raw!r}")
        return match.group(1) if match.groups() else match.group(0)
    raise ValueError(f"unknown pkgver_from function {name!r}")


def _select_tag(tags: list[str], pattern: str) -> str | None:
    if pattern:
        regex = re.compile(pattern)
        candidates = [tag for tag in tags if regex.match(tag)]
    else:
        candidates = list(tags)
    if not candidates:
        return None
    # Delegate ordering to sort -V so it matches how the repo already picks tags.
    ordered = subprocess.run(
        ["sort", "-V"], input="\n".join(candidates), capture_output=True, text=True,
    )
    lines = [line for line in ordered.stdout.splitlines() if line]
    return lines[-1] if lines else candidates[-1]


def git_remote_tags(url: str, timeout: int = 60) -> list[str] | None:
    try:
        result = subprocess.run(
            ["git", "ls-remote", "--tags", "--refs", url],
            capture_output=True, text=True, timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    tags = []
    for line in result.stdout.splitlines():
        _sha, _, ref = line.partition("\t")
        ref = ref.strip()
        if ref.startswith("refs/tags/"):
            tags.append(ref[len("refs/tags/"):])
    return tags


def _pkgrel_next(rel: str) -> str | None:
    """Same arithmetic as scripts/lib/pkgrel-policy.sh pkgrel_policy_next."""
    if re.fullmatch(r"[0-9]+", rel):
        return str(int(rel) + 1)
    if re.fullmatch(r"[0-9]+\.[0-9]+", rel):
        whole, frac = rel.split(".")
        return f"{whole}.{int(frac) + 1}"
    return None


def plan_package(spec: UpdateSpec) -> Plan:
    directory = spec.directory
    if spec.track == "git-tag":
        tags = git_remote_tags(spec.git)
        if tags is None:
            return Plan(spec.package, spec.track, False, error="upstream tags could not be read")
        tag = _select_tag(tags, spec.tag_pattern)
        if tag is None:
            return Plan(spec.package, spec.track, False, detail="no tag matches the pattern")
        try:
            new_pkgver = apply_version_function(tag, spec.pkgver_from)
        except ValueError as exc:
            return Plan(spec.package, spec.track, False, error=str(exc))
        current = decl.pkgver_from_pkgbuild(directory / "PKGBUILD") or ""
        if current == new_pkgver:
            return Plan(spec.package, spec.track, False, old=current, new=new_pkgver,
                        detail="already at the newest tag")
        return Plan(spec.package, spec.track, True, old=current, new=new_pkgver,
                    edits=[("pkgver", new_pkgver), ("pkgrel", "1")], directory=directory)

    if spec.track == "git-commit":
        upstream = pins.git_remote_head(spec.git)
        if upstream is None:
            return Plan(spec.package, spec.track, False, error="upstream HEAD could not be read")
        current = decl.read_pkgbuild_variable(directory, "_commit") or "HEAD"
        if current == upstream:
            return Plan(spec.package, spec.track, False, old=current, new=upstream,
                        detail="pin is current")
        rel = decl.pkgrel_from_pkgbuild(directory / "PKGBUILD") or "1"
        next_rel = _pkgrel_next(rel)
        if next_rel is None:
            return Plan(spec.package, spec.track, False, error=f"unsupported pkgrel {rel!r}")
        return Plan(spec.package, spec.track, True, old=current, new=upstream,
                    edits=[("_commit", upstream), ("pkgrel", next_rel)], directory=directory)

    # git-vcs: pkgver() re-derives from HEAD, so only pkgrel needs to move.
    upstream = pins.git_remote_head(spec.git)
    if upstream is None:
        return Plan(spec.package, spec.track, False, error="upstream HEAD could not be read")
    built = _built_revision(directory)
    if built is not None and built.startswith(upstream[:7]):
        return Plan(spec.package, spec.track, False, old=built, new=upstream,
                    detail="already built from upstream HEAD")
    rel = decl.pkgrel_from_pkgbuild(directory / "PKGBUILD") or "1"
    next_rel = _pkgrel_next(rel)
    if next_rel is None:
        return Plan(spec.package, spec.track, False, error=f"unsupported pkgrel {rel!r}")
    return Plan(spec.package, spec.track, True, old=built or "", new=upstream,
                edits=[("pkgrel", next_rel)], directory=directory)


def _built_revision(directory: Path) -> str | None:
    """The short hash currently baked into a vcs package's pkgver (rNN.abc1234)."""
    pkgver = decl.pkgver_from_pkgbuild(directory / "PKGBUILD")
    if not pkgver:
        return None
    match = re.search(r"\.([0-9a-f]{7,})$", pkgver)
    return match.group(1) if match else None


def render_plan(plans: list[Plan], errors: list[str]) -> str:
    updates = [p for p in plans if p.available]
    failed = [p for p in plans if p.error]
    lines: list[str] = []
    if updates:
        lines.append(f"## {len(updates)} update(s) available")
        lines.append("")
        lines.append("| package | track | current | new |")
        lines.append("| --- | --- | --- | --- |")
        for plan in updates:
            lines.append(f"| {plan.package} | {plan.track} | `{plan.old}` | `{plan.new}` |")
        lines.append("")
    if failed:
        lines.append(f"## {len(failed)} probe failure(s)")
        lines.append("")
        for plan in failed:
            lines.append(f"- {plan.package}: {plan.error}")
        lines.append("")
    if not updates and not failed and not errors:
        lines.append("Every declared package is current.")
        lines.append("")
    if errors:
        lines.append(f"## {len(errors)} declaration error(s)")
        lines.append("")
        for error in errors:
            lines.append(f"- {error}")
        lines.append("")
    lines.append(f"SUMMARY specs={len(plans)} updates={len(updates)} "
                 f"failures={len(failed)} errors={len(errors)}")
    return "\n".join(lines)


def apply_plan(plan: Plan) -> list[str]:
    """Write the plan's edits into PKGBUILD and regenerate .SRCINFO. Returns errors."""
    pkgbuild = plan.directory / "PKGBUILD"
    text = pkgbuild.read_text(encoding="utf-8")
    original = text
    for field_name, new_value in plan.edits:
        if field_name == "_commit":
            text = re.sub(r"(?m)^_commit=.*$", f"_commit={new_value}", text, count=1)
        elif field_name == "pkgver":
            text = re.sub(r"(?m)^pkgver=.*$", f"pkgver={new_value}", text, count=1)
        elif field_name == "pkgrel":
            text = re.sub(r"(?m)^pkgrel=.*$", f"pkgrel={new_value}", text, count=1)
    if text == original:
        return [f"{plan.package}: no PKGBUILD line changed (edits {plan.edits})"]
    pkgbuild.write_text(text, encoding="utf-8")
    return regenerate_srcinfo(plan.directory)


def regenerate_srcinfo(directory: Path) -> list[str]:
    if not (directory / ".SRCINFO").is_file():
        return []
    if not _have("makepkg"):
        return [f"{directory.name}: makepkg not available to regenerate .SRCINFO"]
    result = subprocess.run(
        ["makepkg", "--printsrcinfo"],
        cwd=directory, capture_output=True, text=True,
        env={**_env(), "BUILDDIR": str(directory), "SRCDEST": str(directory),
             "PKGDEST": str(directory), "LOGDEST": str(directory)},
    )
    if result.returncode != 0:
        return [f"{directory.name}: makepkg --printsrcinfo failed: {result.stderr.strip()}"]
    (directory / ".SRCINFO").write_text(result.stdout, encoding="utf-8")
    return []


def _have(tool: str) -> bool:
    import shutil
    return shutil.which(tool) is not None


def _env() -> dict[str, str]:
    import os
    return dict(os.environ)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--package", action="append", default=None, metavar="NAME")
    parser.add_argument("--report", type=Path, default=None)
    parser.add_argument("--json", type=Path, default=None)
    parser.add_argument("--apply", action="store_true",
                        help="write the edits into PKGBUILD/.SRCINFO")
    args = parser.parse_args(argv)

    only = set(args.package) if args.package else None
    specs, errors = read_specs(args.root, only)
    plans = [plan_package(spec) for spec in specs]
    report = render_plan(plans, errors)

    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(report + "\n", encoding="utf-8")
    print(report)

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps({
            "plans": [plan.__dict__ for plan in plans],
            "errors": errors,
        }, indent=2, default=str) + "\n", encoding="utf-8")

    apply_errors: list[str] = []
    if args.apply:
        for plan in plans:
            if plan.available:
                apply_errors.extend(apply_plan(plan))
        for error in apply_errors:
            print(f"apply: {error}", file=sys.stderr)

    if errors or any(plan.error for plan in plans) or apply_errors:
        return FAILED
    if any(plan.available for plan in plans):
        return HAS_UPDATE
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
