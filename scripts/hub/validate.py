#!/usr/bin/env python3
"""Cross-check hub declarations against the readers they are meant to replace.

`.hub.declaration` reads the five package metadata files on its own.  That is
only safe while the two readings agree: the moment they drift, one consumer
acts on a package the other describes differently, and the repository has
exactly one description that no longer matches reality.

This script is the seam.  It asks both sides the same question and reports any
disagreement as an error:

  update sources      declaration vs scripts/check-package-manifests.py
  strategies          declaration vs packages/<name>/.build-strategy
  trackers + baselines  declaration vs scripts/check-upstream-versions.py

Nothing is rewritten and no file is replaced.  The existing scripts keep doing
the work; this only proves the new reading is the same reading, so it can be a
check that runs on every push without any risk to a publish.

A disagreement is printed as `MISMATCH <package>: <field> ...` with both
values, so the fix is obvious without reading either implementation.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from hub import declaration as decl  # noqa: E402


def _load_manifest_gate():
    """Import scripts/check-package-manifests.py as a module."""
    import importlib.util

    path = ROOT / "scripts" / "check-package-manifests.py"
    spec = importlib.util.spec_from_file_location("check_package_manifests", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _load_upstream_checker():
    import importlib.util

    path = ROOT / "scripts" / "check-upstream-versions.py"
    spec = importlib.util.spec_from_file_location("check_upstream_versions", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def compare_update_sources(root: Path, declarations, mismatches):
    """Every package must get the same update source from both readers."""
    gate = _load_manifest_gate()
    registry, registry_errors = gate.load_registry(root / decl.REGISTRY_PATH)
    for error in registry_errors:
        mismatches.append(f"registry: {error}")

    for package in declarations:
        directory = package.directory
        aur_url = directory / decl.AUR_URL_FILENAME
        # The gate's rule, restated from its own primitives: an .aur-url file
        # is an AUR mirror, otherwise the registry decides.
        gate_kind = "aur" if aur_url.is_file() else (
            registry[package.name][0] if package.name in registry else None
        )
        if package.update is None:
            ours = None
        elif isinstance(package.update, decl.AurMirror):
            ours = "aur"
        elif isinstance(package.update, decl.WorkflowUpdate):
            ours = "workflow"
        else:
            ours = "manual"
        if ours != gate_kind:
            mismatches.append(
                f"MISMATCH {package.name}: update source is {ours!r} per the "
                f"declaration and {gate_kind!r} per the manifest gate"
            )


def compare_strategies(root: Path, declarations, mismatches):
    """The declaration must read .build-strategy the way the shell library does."""
    for package in declarations:
        path = package.directory / decl.BUILD_STRATEGY_FILENAME
        if not path.is_file():
            mismatches.append(f"MISMATCH {package.name}: .build-strategy is missing")
            continue
        value = ""
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            stripped = line.strip()
            if stripped and not stripped.startswith("#"):
                value = stripped
                break
        if value != package.build_strategy:
            mismatches.append(
                f"MISMATCH {package.name}: strategy is {package.build_strategy!r} "
                f"per the declaration and {value!r} per .build-strategy"
            )


def compare_trackers(root: Path, declarations, mismatches, notes):
    """Trackers and their baselines must match check-upstream-versions.py exactly."""
    checker = _load_upstream_checker()
    try:
        definitions, baselines = checker.load_definitions(root)
    except (ValueError, OSError) as exc:
        mismatches.append(f"check-upstream-versions.py cannot load definitions: {exc}")
        return

    ours_definitions: dict[str, dict] = {}
    ours_baselines: dict[str, str] = {}
    for package in declarations:
        for tracker in package.trackers:
            if tracker.name in ours_definitions:
                mismatches.append(
                    f"MISMATCH {package.name}: tracker {tracker.name!r} is declared "
                    "by more than one package"
                )
                continue
            ours_definitions[tracker.name] = tracker.config
            ours_baselines[tracker.name] = tracker.baseline

    for name in sorted(set(definitions) | set(ours_definitions)):
        if name not in definitions:
            mismatches.append(f"MISMATCH tracker {name!r}: declared by the hub only")
        elif name not in ours_definitions:
            mismatches.append(f"MISMATCH tracker {name!r}: known to nvchecker only")
        else:
            if definitions[name] != ours_definitions[name]:
                mismatches.append(
                    f"MISMATCH tracker {name!r}: definition differs "
                    f"({ours_definitions[name]!r} vs {definitions[name]!r})"
                )
            if baselines.get(name) != ours_baselines[name]:
                mismatches.append(
                    f"MISMATCH tracker {name!r}: baseline is "
                    f"{ours_baselines[name]!r} per the declaration and "
                    f"{baselines.get(name)!r} per nvchecker"
                )

    notes.append(
        f"compared {len(definitions)} nvchecker tracker(s) from the existing "
        f"loader against {len(ours_definitions)} from the hub"
    )


def run(root: Path) -> tuple[list[str], list[str], int]:
    declarations, errors = decl.load_all(root)
    notes: list[str] = []
    mismatches: list[str] = []

    for error in errors:
        mismatches.append(error)
    for package in declarations:
        for error in package.errors:
            mismatches.append(f"{package.name}: {error}")

    if not declarations:
        mismatches.append(f"{root / decl.PACKAGE_ROOT}: no packages found")
        return mismatches, notes, 0

    compare_update_sources(root, declarations, mismatches)
    compare_strategies(root, declarations, mismatches)
    compare_trackers(root, declarations, mismatches, notes)

    tracked = _tracked_packages(root)
    if tracked is not None:
        for package in declarations:
            if package.name not in tracked:
                mismatches.append(
                    f"{package.name}: no tracked file under packages/{package.name}"
                )
        for name in sorted(tracked - {p.name for p in declarations}):
            mismatches.append(
                f"{name}: tracked under packages/ but has no PKGBUILD or .SRCINFO"
            )

    return mismatches, notes, len(declarations)


def _tracked_packages(root: Path) -> set[str] | None:
    """Package directory names git knows about, or None outside a checkout."""
    import subprocess

    try:
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files", "--", "packages/"],
            check=True, capture_output=True, text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    names = set()
    for line in result.stdout.splitlines():
        parts = line.split("/")
        if len(parts) >= 3 and parts[0] == "packages":
            names.add(parts[1])
    return names


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT,
                        help="repository root (default: the checkout holding this script)")
    args = parser.parse_args(argv)

    mismatches, notes, count = run(args.root)
    for note in notes:
        print(f"NOTE {note}")
    for mismatch in mismatches:
        print(mismatch)
    print(f"SUMMARY packages={count} mismatches={len(mismatches)}")
    return 0 if not mismatches else 1


if __name__ == "__main__":
    raise SystemExit(main())
