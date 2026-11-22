#!/usr/bin/env python3
"""Tests for scripts/hub/update.py -- the declarative upstream updater.

Two layers:
  * unit: the closed set of pkgver_from functions (no network, no repo)
  * integration: a throwaway package + fake git so plan/apply can be exercised
    without touching upstream or the real tree
"""

from __future__ import annotations

import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_SPEC = importlib.util.spec_from_file_location("hub_update", ROOT / "scripts/hub/update.py")
assert _SPEC is not None and _SPEC.loader is not None
_MODULE = importlib.util.module_from_spec(_SPEC)
sys.modules["hub_update"] = _MODULE
_SPEC.loader.exec_module(_MODULE)

apply_version_function = _MODULE.apply_version_function


class VersionFunctionTests(unittest.TestCase):
    def test_strip_v(self):
        self.assertEqual("0.1.3", apply_version_function("v0.1.3", "strip_v"))

    def test_identity_and_default(self):
        self.assertEqual("v0.1.3", apply_version_function("v0.1.3", "identity"))
        self.assertEqual("1.2.3", apply_version_function("1.2.3", ""))

    def test_date_version(self):
        self.assertEqual("2026.11.22", apply_version_function("2026-11-22", "date_version"))
        self.assertEqual("2026.11.22", apply_version_function("20261122", "date_version"))
        self.assertEqual("2026.11.22", apply_version_function("v2026.11.22", "date_version"))

    def test_regex_extract(self):
        self.assertEqual(
            "1.2.3",
            apply_version_function("release-v1.2.3-final", r"regex_extract:(\d+\.\d+\.\d+)"),
        )

    def test_unknown_function_is_an_error_not_a_passthrough(self):
        with self.assertRaises(ValueError):
            apply_version_function("v1", "bogus")

    def test_regex_extract_without_match_is_an_error(self):
        with self.assertRaises(ValueError):
            apply_version_function("v1", r"regex_extract:(\d+\.\d+\.\d+)")


class PlanApplyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _make_package(self, name: str, pkgbuild: str, srcinfo: str, update_toml: str):
        d = self.tmp / "packages" / name
        d.mkdir(parents=True)
        (d / "PKGBUILD").write_text(pkgbuild, encoding="utf-8")
        (d / ".SRCINFO").write_text(srcinfo, encoding="utf-8")
        (d / "update.toml").write_text(update_toml, encoding="utf-8")
        return d

    def test_read_specs_rejects_bad_track(self):
        self._make_package(
            "demo",
            "pkgname=demo\npkgver=1.0\npkgrel=1\n",
            "pkgbase = demo\n\tpkgver = 1.0\n\tpkgrel = 1\n",
            'track = "nonsense"\ngit = "https://example/x"\n',
        )
        specs, errors = _MODULE.read_specs(self.tmp, None)
        self.assertEqual([], specs)
        self.assertTrue(any("track must be one of" in e for e in errors))

    def test_read_specs_reads_pkgver_from(self):
        self._make_package(
            "demo",
            "pkgname=demo\npkgver=1.0\npkgrel=1\n",
            "pkgbase = demo\n\tpkgver = 1.0\n\tpkgrel = 1\n",
            'track = "git-tag"\ngit = "https://example/x"\n'
            'tag_pattern = "^v\\\\d+\\\\.\\\\d+$"\npkgver_from = "identity"\n',
        )
        specs, errors = _MODULE.read_specs(self.tmp, None)
        self.assertEqual([], errors)
        self.assertEqual(1, len(specs))
        self.assertEqual("identity", specs[0].pkgver_from)

    def test_pkgrel_next_matches_policy_shape(self):
        self.assertEqual("2", _MODULE._pkgrel_next("1"))
        self.assertEqual("2.7", _MODULE._pkgrel_next("2.6"))
        self.assertIsNone(_MODULE._pkgrel_next("1.2.3"))
        self.assertIsNone(_MODULE._pkgrel_next("1a"))


class TagPinTests(unittest.TestCase):
    """git-tag-pin against a real repository, not a mock of ls-remote."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.upstream = self.tmp / "upstream"
        self.upstream.mkdir()
        self._git("init", "-q", "-b", "main")
        self._git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
                  "--allow-empty", "-m", "one")
        self.first = self._git("rev-parse", "HEAD")
        self._git("-c", "user.name=t", "-c", "user.email=t@t", "tag", "-a", "v0.1.0", "-m", "x")
        self._git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
                  "--allow-empty", "-m", "two")
        self.second = self._git("rev-parse", "HEAD")
        self._git("-c", "user.name=t", "-c", "user.email=t@t", "tag", "-a", "v0.2.0", "-m", "y")
        self._git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
                  "--allow-empty", "-m", "three, after the newest tag")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _git(self, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=self.upstream, check=True,
                              capture_output=True, text=True).stdout.strip()

    def _package(self, commit: str) -> Path:
        d = self.tmp / "packages" / "demo"
        d.mkdir(parents=True)
        (d / "PKGBUILD").write_text(
            f"pkgname=demo\npkgver=0.3.0\npkgrel=4\n_commit={commit}\n", encoding="utf-8")
        return d

    def _spec(self, directory: Path):
        return _MODULE.UpdateSpec(
            package="demo", directory=directory, track="git-tag-pin",
            git=str(self.upstream), tag_pattern=r"^v\d+\.\d+\.\d+$")

    def test_annotated_tag_resolves_to_its_commit_not_the_tag_object(self):
        sha = _MODULE.git_remote_tag_commit(str(self.upstream), "v0.2.0")
        self.assertEqual(self.second, sha)

    def test_pins_newest_tag_not_head_and_leaves_pkgver_alone(self):
        plan = _MODULE.plan_package(self._spec(self._package("HEAD")))
        self.assertTrue(plan.available)
        self.assertEqual("v0.2.0", plan.ref)
        self.assertEqual([("_commit", self.second), ("pkgrel", "5")], plan.edits)
        self.assertNotIn("pkgver", [name for name, _ in plan.edits])

    def test_already_pinned_to_the_newest_tag_is_current(self):
        plan = _MODULE.plan_package(self._spec(self._package(self.second)))
        self.assertFalse(plan.available)
        self.assertEqual("", plan.error)

    def test_commits_after_the_newest_tag_are_not_an_update(self):
        # HEAD moved on, but only a new tag counts for this track.
        plan = _MODULE.plan_package(self._spec(self._package(self.second)))
        self.assertFalse(plan.available)

    def test_no_matching_tag_is_reported_not_treated_as_current(self):
        spec = self._spec(self._package("HEAD"))
        spec = _MODULE.UpdateSpec(**{**spec.__dict__, "tag_pattern": r"^release-"})
        plan = _MODULE.plan_package(spec)
        self.assertFalse(plan.available)
        self.assertIn("no tag matches", plan.detail)


_SRCINFO = (
    "pkgbase = zbonsai\n"
    "\tpkgdesc = demo\n"
    "\tpkgver = 0.1.0\n"
    "\tpkgrel = 1\n"
    "\tsource = zbonsai::git+https://github.com/C-Fuego/Rezig#commit=HEAD\n"
    "\tsha256sums = SKIP\n"
    "\n"
    "pkgname = zbonsai\n"
)


class SrcinfoPatchTests(unittest.TestCase):
    def test_commit_pin_and_pkgrel(self):
        patched = _MODULE.patch_srcinfo(
            _SRCINFO, [("_commit", "0eb8604"), ("pkgrel", "2")], old_commit="HEAD")
        self.assertIn("\tpkgrel = 2\n", patched)
        self.assertIn("#commit=0eb8604\n", patched)
        self.assertNotIn("#commit=HEAD", patched)
        self.assertIn("\tpkgver = 0.1.0\n", patched)

    def test_pkgver_and_pkgrel_for_a_tag_bump(self):
        patched = _MODULE.patch_srcinfo(_SRCINFO, [("pkgver", "0.2.0"), ("pkgrel", "1")])
        self.assertIn("\tpkgver = 0.2.0\n", patched)

    def test_missing_pin_is_an_error_not_a_silent_noop(self):
        # A pin that is not in .SRCINFO means the file drifted from the PKGBUILD;
        # writing an unchanged file would publish a PR whose metadata disagrees.
        with self.assertRaises(ValueError):
            _MODULE.patch_srcinfo(_SRCINFO, [("_commit", "abc")], old_commit="deadbeef")

    def test_missing_field_is_an_error(self):
        with self.assertRaises(ValueError):
            _MODULE.patch_srcinfo("pkgbase = x\n", [("pkgrel", "2")])

    @unittest.skipUnless(shutil.which("makepkg") and os.geteuid() != 0,
                         "needs makepkg and a non-root user")
    def test_patch_agrees_with_makepkg_for_every_declared_package(self):
        # The runner patches .SRCINFO because it has no makepkg; the maintainer's
        # machine regenerates it. Both must produce the same bytes or a PR from
        # CI would differ from one made locally.
        checked = 0
        for toml in sorted((ROOT / "packages").glob("*/update.toml")):
            package = toml.parent.name
            pkgbuild = (toml.parent / "PKGBUILD").read_text(encoding="utf-8")
            srcinfo = (toml.parent / ".SRCINFO").read_text(encoding="utf-8")
            commit = _MODULE.decl.read_pkgbuild_variable(toml.parent, "_commit")
            if commit is None:
                edits, old = [("pkgrel", "9")], ""
            else:
                edits, old = [("_commit", "0" * 40), ("pkgrel", "9")], commit
            work = Path(tempfile.mkdtemp())
            try:
                target = work / package
                shutil.copytree(toml.parent, target)
                text = pkgbuild
                for name, value in edits:
                    text = re.sub(rf"(?m)^{name}=.*$", f"{name}={value}", text, count=1)
                (target / "PKGBUILD").write_text(text, encoding="utf-8")
                errors = _MODULE.regenerate_srcinfo(target)  # makepkg path
                self.assertEqual([], errors, package)
                expected = (target / ".SRCINFO").read_text(encoding="utf-8")
                self.assertEqual(
                    expected, _MODULE.patch_srcinfo(srcinfo, edits, old), package)
                checked += 1
            finally:
                shutil.rmtree(work, ignore_errors=True)
        self.assertGreater(checked, 0)


if __name__ == "__main__":
    unittest.main()
