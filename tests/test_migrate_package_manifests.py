"""Integration tests for the standalone manifest migration CLI."""

import os
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "migrate-package-manifests.py"
COMMIT = "ab" * 20
UPSTREAM_BOT = ".github/workflows/upstream-bot.yml"


class MigrationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def write(self, relative, data):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data.encode("utf-8") if isinstance(data, str) else data)
        return path

    def package(self, name, strategy="source"):
        self.write(f"packages/{name}/PKGBUILD", f"pkgname={name}\n")
        return self.write(f"packages/{name}/.build-strategy", f"# comment\n\n{strategy}\n").parent

    def registry(self, content):
        return self.write("config/package-updates.txt", content)

    def migrate(self, *args):
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "--root", str(self.root), *args],
            text=True, capture_output=True,
        )

    def snapshot(self):
        return {p.relative_to(self.root): p.read_bytes()
                for p in self.root.rglob("*") if p.is_file()}

    def test_preview_apply_and_repeat(self):
        aur = self.package("aur-local", "vcs")
        url = "https://aur.archlinux.org/aur-upstream.git"
        self.write("packages/aur-local/.aur-url", f"\n{url}\n\n")
        self.write("packages/aur-local/.aur-commit", COMMIT + "\n")
        manual = self.package("manual-local", "binary-repack")
        workflow = self.package("workflow-local", "data")
        git = self.package("git-local")
        original_git = (
            b'# Keep this annotation.\r\ntrack = "git-tag-pin"\r\n'
            b'git = "https://example.org/upstream"\r\n'
            b"tag_pattern = '^v\\d+$'\r\non_update = 'issue'\r\n"
            b'[extra]\r\nkeep = true\r\n'
        )
        self.write("packages/git-local/update.toml", original_git)
        workflow_path = ".github/workflows/custom.yml"
        self.write(workflow_path, "name: Workflow\n")
        self.write(UPSTREAM_BOT, "name: Upstream Bot\n")
        reason = 'Contains "quotes", unicode ñ, tabs\tand a \\ backslash.'
        self.registry(f"manual-local manual {reason}\nworkflow-local workflow {workflow_path}\n"
                      f"git-local workflow {UPSTREAM_BOT}\n")
        original = self.snapshot()

        preview = self.migrate()
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertIn("Dry run: 4 packages, 3 create, 1 update, 0 keep.", preview.stdout)
        self.assertEqual(self.snapshot(), original)

        apply = self.migrate("--apply")
        self.assertEqual(apply.returncode, 0, apply.stderr)
        self.assertIn("Applied: 4 packages, 3 create, 1 update, 0 keep.", apply.stdout)
        expected = {
            aur: {"track": "aur", "strategy": "vcs", "url": url, "commit": COMMIT},
            manual: {"track": "manual", "strategy": "binary", "reason": reason},
            workflow: {"track": "workflow", "strategy": "data", "workflow": workflow_path},
            git: {"strategy": "source", **tomllib.loads(original_git.decode())},
        }
        for package, fields in expected.items():
            self.assertEqual(tomllib.loads((package / "update.toml").read_text()), fields)
        self.assertEqual((git / "update.toml").read_bytes(), b'strategy = "source"\r\n' + original_git)
        after = self.snapshot()
        self.assertEqual({p: after[p] for p in original if p.name != "update.toml"},
                         {p: data for p, data in original.items() if p.name != "update.toml"})

        repeat = self.migrate("--apply")
        self.assertEqual(repeat.returncode, 0, repeat.stderr)
        self.assertIn("Applied: 4 packages, 0 create, 0 update, 4 keep.", repeat.stdout)
        self.assertEqual(self.snapshot(), after)

    def test_conflicting_or_malformed_metadata_prevents_all_writes(self):
        self.package("a-valid")
        self.package("z-broken")
        self.registry("a-valid manual Hand maintained.\nz-broken manual By hand.\n")
        for bad_toml, expected_error in (
            ('track = "manual"\nreason = "Different reason"\n', "reason conflicts"),
            ('track = "manual"\nreason = "By hand."\nstrategy = "data"\n', "strategy conflicts"),
            ('track = "manual"\nreason = [', "Invalid value"),
        ):
            with self.subTest(bad_toml=bad_toml):
                self.write("packages/z-broken/update.toml", bad_toml)
                original = self.snapshot()
                result = self.migrate("--apply")
                self.assertEqual(result.returncode, 2)
                self.assertIn(expected_error, result.stderr)
                self.assertEqual(self.snapshot(), original)

    def test_aur_pin_and_duplicate_sources_are_checked(self):
        self.package("mirror")
        self.write("packages/mirror/.aur-url", "https://aur.archlinux.org/mirror.git\n")
        broken = self.migrate("--apply")
        self.assertEqual(broken.returncode, 2)
        self.assertIn("present without .aur-commit", broken.stderr)
        self.write("packages/mirror/.aur-commit", COMMIT + "\n")
        self.registry("mirror manual By hand.\n")
        duplicate = self.migrate("--apply")
        self.assertEqual(duplicate.returncode, 2)
        self.assertIn("both an AUR mirror and a registry entry", duplicate.stderr)

    def test_workflow_must_be_tracked_when_in_git_checkout(self):
        self.package("workflow-local")
        self.registry("workflow-local workflow .github/workflows/custom.yml\n")
        self.write(".github/workflows/custom.yml", "name: Workflow\n")
        env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull}
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True, env=env)
        preview = self.migrate()
        self.assertEqual(preview.returncode, 2)
        self.assertIn("workflow file is not tracked by git", preview.stderr)
        subprocess.run(["git", "add", ".github/workflows/custom.yml"], cwd=self.root,
                       check=True, env=env)
        apply = self.migrate("--apply")
        self.assertEqual(apply.returncode, 0, apply.stderr)


if __name__ == "__main__":
    unittest.main()
