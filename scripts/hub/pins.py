#!/usr/bin/env python3
"""Report packages whose declared upstream pin has fallen behind.

Some packages hold upstream at a specific revision on purpose: the AUR mirrors
pin .aur-commit, and the Rezig packages pin `_commit` inside their PKGBUILD.
Nothing in the repository ever notices when such a pin goes stale, because the
update workflows only act on packages an updater owns and nvchecker only
reports what a .nvchecker.toml describes.  A pin that nobody changes is
therefore indistinguishable from a pin that is current.

This script answers, for every package whose update source is a pin: has the
upstream moved past the revision we hold?

Three states are reported, and they are deliberately not merged:

  PINNED     upstream HEAD differs from the declared pin.
  AT-HEAD    the package declares `_commit=HEAD` (or `tag=` derived from a
             moving value).  Nothing is pinned, so "behind" has no meaning --
             but the package ALSO does not look like an auto-updating package,
             so it is easy to believe it is.  Reported separately because the
             fix is different: pin it, or accept that every build takes
             whatever upstream currently has.
  CURRENT    the pin still points at what upstream publishes.

It never edits a PKGBUILD.  Changing a pin is a deliberate act with a pkgrel
consequence, and a background job doing it silently is exactly the
"compiler warned and nobody noticed" failure this repository keeps fixing.

Exit status: 0 when nothing is behind (AT-HEAD still counts as nothing behind),
1 when at least one pin is behind, 2 when the check could not run (network
failure, unreadable PKGBUILD) -- a crash is never "no drift".
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from hub import declaration as decl  # noqa: E402

PINNED = "PINNED"
AT_HEAD = "AT-HEAD"
CURRENT = "CURRENT"
UNKNOWN = "UNKNOWN"

#: `source=("pkg::git+https://...#commit=$_commit")` and the plain form.
GIT_SOURCE = re.compile(
    r"git\+(?P<url>https?://[^\"'\s#]+)(?:#(?P<frag>[^\"'\s]*))?"
)
COMMIT_VALUE = re.compile(r"(?m)^_commit=(?P<value>['\"]?)(?P<raw>[^'\"\s#]+)")


@dataclass(frozen=True)
class PinProbe:
    package: str
    state: str
    declared: str
    upstream: str | None
    url: str | None
    detail: str = ""


def git_remote_head(url: str, timeout: int = 60) -> str | None:
    """Full SHA of the remote's HEAD branch, or None when it cannot be read."""
    try:
        result = subprocess.run(
            ["git", "ls-remote", url, "HEAD"],
            capture_output=True, text=True, timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        sha, _, ref = line.partition("\t")
        if ref.strip() == "HEAD" and decl.GIT_COMMIT.match(sha.strip()):
            return sha.strip()
    return None


def git_remote_tag(url: str, tag: str, timeout: int = 60) -> str | None:
    """Full SHA of a specific tag, or None when it does not exist."""
    try:
        result = subprocess.run(
            ["git", "ls-remote", url, f"refs/tags/{tag}"],
            capture_output=True, text=True, timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        sha, _, ref = line.partition("\t")
        if ref.strip().startswith(f"refs/tags/{tag}") and decl.GIT_COMMIT.match(sha.strip()):
            return sha.strip()
    return None


def _pkgbuild_git_source(package_dir: Path) -> tuple[str | None, str | None]:
    """(url, fragment) of the package's own git source, if it has one."""
    text = (package_dir / "PKGBUILD").read_text(encoding="utf-8", errors="replace")
    for match in GIT_SOURCE.finditer(text):
        return match.group("url"), (match.group("frag") or "")
    return None, None


def probe_commit_pin(directory: Path) -> PinProbe:
    """Follow a `#commit=$_commit` pin, including the `_commit=HEAD` case."""
    name = directory.name
    text = (directory / "PKGBUILD").read_text(encoding="utf-8", errors="replace")
    url, fragment = _pkgbuild_git_source(directory)
    if url is None or "commit=" not in fragment:
        return PinProbe(name, UNKNOWN, "", None, url, "no git #commit= source")

    value_match = COMMIT_VALUE.search(text)
    declared = value_match.group("raw").strip() if value_match else ""
    if not declared:
        declared = fragment.split("commit=", 1)[1].split("&")[0].strip()

    if declared.upper() == "HEAD" or not decl.GIT_COMMIT.match(declared):
        # Not a pin: the build takes whatever upstream currently serves.
        upstream = git_remote_head(url)
        if upstream is None:
            return PinProbe(name, UNKNOWN, declared, None, url,
                            "upstream HEAD could not be read")
        return PinProbe(name, AT_HEAD, declared, upstream, url,
                        "the PKGBUILD does not pin a revision; every build "
                        "takes upstream HEAD")

    upstream = git_remote_head(url)
    if upstream is None:
        return PinProbe(name, UNKNOWN, declared, None, url,
                        "upstream HEAD could not be read")
    if upstream == declared:
        return PinProbe(name, CURRENT, declared, upstream, url)
    return PinProbe(name, PINNED, declared, upstream, url)


def probe_tag_pin(directory: Path) -> PinProbe:
    """Follow a `#tag=$_tag` source whose tag is derived from pkgver."""
    name = directory.name
    url, fragment = _pkgbuild_git_source(directory)
    pkgver = decl.pkgver_from_pkgbuild(directory / "PKGBUILD")
    if url is None or "tag=" not in fragment or not pkgver:
        return PinProbe(name, UNKNOWN, "", None, url, "no tag or pkgver to follow")
    # `_tag="v${pkgver}"` is the common shape; fall back to a bare tag.
    pattern = re.search(r'(?m)^_tag=["\']?(?P<value>[^"\'\s]+)', 
                        (directory / "PKGBUILD").read_text(encoding="utf-8", errors="replace"))
    raw = pattern.group("value") if pattern else ""
    tag = (raw.replace("${pkgver}", pkgver).replace("$pkgver", pkgver)
           if raw else fragment.split("tag=", 1)[1].split("&")[0].strip())
    if not tag:
        return PinProbe(name, UNKNOWN, pkgver, None, url, "the tag could not be resolved")
    if not git_remote_tag(url, tag):
        return PinProbe(name, PINNED, pkgver, None, url,
                        f"tag {tag!r} does not exist upstream")
    return PinProbe(name, CURRENT, pkgver, tag, url)


def probe_aur_pin(mirror) -> PinProbe:
    """Compare .aur-commit with the AUR repo's current HEAD."""
    upstream = git_remote_head(mirror.url)
    if upstream is None:
        return PinProbe(mirror.package, UNKNOWN, mirror.commit, None, mirror.url,
                        "the AUR repository could not be read")
    if upstream == mirror.commit:
        return PinProbe(mirror.package, CURRENT, mirror.commit, upstream, mirror.url)
    return PinProbe(mirror.package, PINNED, mirror.commit, upstream, mirror.url,
                    "the AUR package has moved past .aur-commit")


AUR_MIRROR_MARKER = decl.AUR_URL_FILENAME


def _wants_probe(directory: Path) -> str:
    """Why this package is a pin candidate, or '' when it is not one."""
    if (directory / AUR_MIRROR_MARKER).is_file():
        return "aur"
    url, fragment = _pkgbuild_git_source(directory)
    if url is None:
        return ""
    if "commit=" in fragment:
        return "commit"
    if "tag=" in fragment:
        return "tag"
    return ""


def collect(root: Path, only: set[str] | None = None) -> tuple[list[PinProbe], list[str]]:
    """Probe every pin candidate; return probes plus hard failures."""
    failures: list[str] = []
    probes: list[PinProbe] = []
    seen: set[str] = set()
    for directory in decl.package_dirs(root):
        if only is not None and directory.name not in only:
            continue
        seen.add(directory.name)
        kind = _wants_probe(directory)
        if not kind:
            continue
        try:
            if kind == "aur":
                mirror, aur_errors = decl.read_aur(
                    directory / decl.AUR_URL_FILENAME,
                    directory / decl.AUR_COMMIT_FILENAME,
                )
                if mirror is None:
                    failures.extend(f"{directory.name}: {e}" for e in aur_errors)
                    continue
                probes.append(probe_aur_pin(mirror))
            elif kind == "commit":
                probes.append(probe_commit_pin(directory))
            else:
                probes.append(probe_tag_pin(directory))
        except (OSError, IndexError) as exc:
            failures.append(f"{directory.name}: {exc}")
    if only is not None:
        for missing in sorted(only - seen):
            failures.append(f"{missing}: no such package directory")
    return probes, failures


def render(probes: list[PinProbe], failures: list[str]) -> str:
    behind = [p for p in probes if p.state == PINNED]
    at_head = [p for p in probes if p.state == AT_HEAD]
    unknown = [p for p in probes if p.state == UNKNOWN]

    lines: list[str] = []
    if behind:
        lines.append(f"## {len(behind)} pin(s) behind upstream")
        lines.append("")
        lines.append("| package | holds | upstream | source |")
        lines.append("| --- | --- | --- | --- |")
        for probe in behind:
            held = probe.declared[:12]
            upstream = (probe.upstream or "")[:12]
            lines.append(f"| {probe.package} | `{held}` | `{upstream}` | {probe.url} |")
        lines.append("")
    if at_head:
        lines.append(f"## {len(at_head)} package(s) build whatever upstream currently serves")
        lines.append("")
        lines.append("| package | source |")
        lines.append("| --- | --- |")
        for probe in at_head:
            lines.append(f"| {probe.package} | {probe.url} |")
        lines.append("")
        lines.append("These declare `_commit=HEAD`, so the pin is not a pin. "
                     "Either pin a commit or treat the package as auto-tracking.")
        lines.append("")
    if unknown:
        lines.append(f"## {len(unknown)} pin(s) could not be read")
        lines.append("")
        for probe in unknown:
            lines.append(f"- {probe.package}: {probe.detail}")
        lines.append("")
    if failures:
        lines.append(f"## {len(failures)} failure(s)")
        lines.append("")
        for failure in failures:
            lines.append(f"- {failure}")
        lines.append("")
    if not (behind or at_head or unknown or failures):
        lines.append("Every declared pin is current.")
        lines.append("")

    lines.append(f"SUMMARY pinned={len(behind)} at-head={len(at_head)} "
                 f"current={sum(1 for p in probes if p.state == CURRENT)} "
                 f"unknown={len(unknown)} failures={len(failures)}")
    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--package", action="append", default=None,
                        metavar="NAME",
                        help="only report this package (repeatable)")
    parser.add_argument("--report", type=Path, default=None,
                        help="write the markdown report here instead of stdout")
    parser.add_argument("--json", type=Path, default=None,
                        help="also write machine-readable results here")
    args = parser.parse_args(argv)

    only = set(args.package) if args.package else None
    probes, failures = collect(args.root, only)
    report = render(probes, failures)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(report + "\n", encoding="utf-8")
        print(report)
    else:
        print(report)

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(
            json.dumps(
                {
                    "probes": [probe.__dict__ for probe in probes],
                    "failures": failures,
                },
                indent=2,
            ) + "\n",
            encoding="utf-8",
        )

    if failures:
        return 2
    if any(probe.state == PINNED for probe in probes):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
