"""Exercise local-only package imports without contacting AUR or building packages."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from bot import manage  # noqa: E402


def srcinfo(base, source="", output=None):
    return (f"pkgbase = {base}\n\tpkgver = 1.2\n\tpkgrel = 3\n\tarch = any\n"
            f"{source}\npkgname = {output or base}\n")


class ManageTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.workspace = Path(temp.name)
        self.root = self.workspace / "repo"
        self.root.mkdir()
        self.source = self.workspace / "source with spaces"
        self.source.mkdir()
        self.stub_bin = self.workspace / "bin"
        self.stub_bin.mkdir()
        self.log = self.workspace / "makepkg-log"
        self.env = {**os.environ, "PATH": f"{self.stub_bin}:{os.environ['PATH']}",
                    "MAKEPKG_LOG": str(self.log)}
        makepkg = self.stub_bin / "makepkg"
        makepkg.write_text("#!/bin/sh\n[ \"$1\" = --printsrcinfo ] || exit 2\n"
                           "printf '%s\\n' \"$PWD\" >> \"$MAKEPKG_LOG\"\n"
                           "test -f PKGBUILD && cat recipe-metadata\n", encoding="utf-8")
        makepkg.chmod(0o755)

    def cli(self, *args):
        return subprocess.run([sys.executable, str(Path(manage.__file__)), "--root", str(self.root), *map(str, args)],
                              env=self.env, stdin=subprocess.DEVNULL, text=True, capture_output=True)

    def recipe(self, name, *, vcs=False, source=""):
        (self.source / "PKGBUILD").write_text("pkgver=1.2\npkgrel=3\n" + ("pkgver() { :; }\n" if vcs else ""))
        (self.source / "recipe-metadata").write_text(srcinfo(name, source))

    def import_local(self, name, *args):
        return self.cli("add", name, "--from", self.source, *args)

    def spec(self, name):
        return tomllib.loads((self.root / "packages" / name / "update.toml").read_text())

    def test_local_import_preserves_support_files_and_regenerates_srcinfo(self):
        self.recipe("demo")
        (self.source / ".SRCINFO").write_text("stale")
        (self.source / ".git").mkdir()
        (self.source / ".build-strategy").write_text("data\n")
        (self.source / "fixes").mkdir()
        (self.source / "fixes" / "build.patch").write_text("local patch\n")
        (self.source / ".rebuild-on").write_text("package example\n")
        reason = 'Manual "review" before publishing.'
        result = self.import_local("demo", "--track", "manual", "--reason", reason, "--strategy", "data")
        self.assertEqual(result.returncode, 0, result.stderr)
        destination = self.root / "packages" / "demo"
        self.assertEqual(self.spec("demo"), {"track": "manual", "reason": reason, "strategy": "data"})
        self.assertEqual((destination / ".SRCINFO").read_text(), srcinfo("demo"))
        self.assertEqual((destination / "fixes" / "build.patch").read_text(), "local patch\n")
        self.assertTrue((destination / ".rebuild-on").is_file())
        self.assertFalse((destination / ".git").exists())
        self.assertFalse((destination / ".build-strategy").exists())
        self.assertEqual((self.source / ".SRCINFO").read_text(), "stale")
        self.assertIn("Track: manual", self.cli("packages", "show", "demo").stdout)
        self.assertIn("demo\t1.2-3\tmanual\tdata", self.cli("packages", "list").stdout)

    def test_binary_strategy_alias_is_saved_as_binary(self):
        for strategy in ("binary", "binary-repack"):
            with self.subTest(strategy=strategy):
                name = f"demo-{strategy}"
                self.recipe(name)
                result = self.import_local(name, "--strategy", strategy)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.spec(name)["strategy"], "binary")

    def test_default_local_tracks_distinguish_floating_and_pinned_git(self):
        self.recipe("release")
        result = self.import_local("release")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.spec("release")["strategy"], "source")
        self.assertTrue(self.spec("release")["reason"])
        self.recipe("snapshot", vcs=True, source="\tsource = snapshot::git+https://example.org/org/repo.git")
        result = self.import_local("snapshot")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.spec("snapshot"), {"track": "git-vcs", "strategy": "vcs",
                                               "git": "https://example.org/org/repo.git"})
        self.recipe("pinned", vcs=True, source="\tsource = git+https://example.org/org/repo.git#commit=abc")
        result = self.import_local("pinned")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.spec("pinned")["track"], "manual")
        self.assertEqual(self.spec("pinned")["strategy"], "vcs")

    def test_workflow_and_git_tag_options(self):
        workflow = self.root / ".github/workflows/update.yml"
        workflow.parent.mkdir(parents=True)
        workflow.write_text("name: updates\n")
        self.recipe("workflow-example")
        result = self.import_local("workflow-example", "--workflow", workflow.relative_to(self.root))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.spec("workflow-example")["workflow"], ".github/workflows/update.yml")
        self.recipe("tagged")
        pattern = r"^v(\d+\.\d+)$"
        result = self.import_local("tagged", "--track", "git-tag", "--git", "https://example.org/repo",
                                   "--tag-pattern", pattern, "--pkgver-from", "strip_v", "--on-update", "issue")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.spec("tagged")["tag_pattern"], pattern)
        self.assertEqual(self.spec("tagged")["on_update"], "issue")

    def test_refuses_incomplete_and_conflicting_imports(self):
        self.recipe("valid")
        for name, args, error in (
            ("..", (), "invalid package name"),
            ("wrong", (), "does not match"),
            ("valid", ("--track", "manual"), "requires a nonempty --reason"),
            ("valid", ("--track", "workflow"), "requires --workflow"),
            ("valid", ("--strategy", "vcs"), "inconsistent"),
        ):
            with self.subTest(name=name, args=args):
                result = self.import_local(name, *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)
                self.assertEqual(list((self.root / "packages").glob("*")), [])
        self.assertEqual(self.import_local("valid").returncode, 0)
        result = self.import_local("valid")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to overwrite", result.stderr)

    @unittest.skipUnless(shutil.which("git"), "requires git for fixture")
    def test_aur_import_uses_committed_metadata_without_running_makepkg(self):
        upstream = self.workspace / "aur-upstream"
        upstream.mkdir()
        (upstream / "PKGBUILD").write_text("echo should-not-run > \"$MAKEPKG_LOG\"\npkgver() { :; }\n")
        (upstream / ".SRCINFO").write_text(srcinfo("example-git", output="split-example"))
        (upstream / "example.install").write_text("# support file\n")
        (upstream / "update.toml").write_text('track = "manual"\n')

        def git(*args):
            return subprocess.check_output(["git", "-C", str(upstream), *args], text=True, stderr=subprocess.PIPE).strip()

        git("init")
        git("add", ".")
        git("-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "-m", "Fixture")
        url = "https://aur.archlinux.org/example-git.git"
        self.env.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0=f"url.{upstream.as_uri()}.insteadOf",
                        GIT_CONFIG_VALUE_0=url, GIT_ALLOW_PROTOCOL="file")
        with patch.dict(os.environ, self.env), patch.object(manage, "aur_base_for_name", return_value="example-git") as lookup:
            self.assertEqual(manage.main(["--root", str(self.root), "add", "split-example"]), 0)
            lookup.assert_called_once_with("split-example")
        result = self.cli("add", "example-git")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to overwrite", result.stderr)
        destination = self.root / "packages" / "example-git"
        self.assertEqual((destination / ".SRCINFO").read_bytes(), (upstream / ".SRCINFO").read_bytes())
        self.assertTrue((destination / "example.install").is_file())
        self.assertEqual(self.spec("example-git"), {"track": "aur", "url": url,
                                                   "commit": git("rev-parse", "HEAD"), "strategy": "vcs"})
        self.assertFalse(self.log.exists())
        self.assertFalse((destination / ".git").exists())
        self.assertFalse((destination / ".aur-url").exists())
        self.assertFalse((self.root / ".git").exists())
        self.assertIn("example-git\t1.2-3\taur\tvcs", self.cli("packages", "list", "--track", "aur").stdout)

    def test_legacy_overview_and_shell_entrypoint(self):
        legacy = self.root / "packages" / "legacy"
        legacy.mkdir(parents=True)
        (legacy / "PKGBUILD").touch()
        (legacy / ".SRCINFO").write_text(srcinfo("legacy"))
        (legacy / ".aur-url").write_text("https://aur.archlinux.org/legacy.git\n")
        (legacy / ".aur-commit").write_text("a" * 40 + "\n")
        (legacy / ".build-strategy").write_text("source\n")
        self.assertEqual(self.cli("packages", "list", "--track", "aur", "--no-header").stdout,
                         "legacy\t1.2-3\taur\tsource\n")
        result = subprocess.run([str(ROOT / "manage.sh"), "add", "--help"], cwd=self.workspace,
                                env={**self.env, "PKGBUILD_GITHUB_REPOSITORY": "invalid"},
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("trusted local PKGBUILD directory", result.stdout)
        result = subprocess.run([str(ROOT / "manage.sh"), "--list"], cwd=self.workspace,
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("add-aur\t", result.stdout)
        self.assertIn("packages\t", result.stdout)


if __name__ == "__main__":
    unittest.main()
