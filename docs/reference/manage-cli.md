# Package manager CLI reference

The non-interactive package commands are implemented by `scripts/bot/manage.py` and dispatched directly by `manage.sh`; they do not require fzf or a Git worktree. Import operations only create `packages/<pkgbase>/`: they do not pull, stage, commit, or push. Existing package directories are never overwritten.

Run `./manage.sh add --help`, `./manage.sh packages --help`, and the subcommand `--help` for generated argparse help.

## `manage.sh add`

```text
./manage.sh add PACKAGE [--from DIR] [--track TRACK] [--strategy STRATEGY]
  [--reason REASON] [--workflow PATH] [--git URL]
  [--tag-pattern REGEX] [--pkgver-from RULE] [--on-update ACTION]
  [--non-interactive]
```

| Argument | Meaning and constraints |
|---|---|
| `PACKAGE` | AUR package name or local `pkgbase`; names must match the package-name grammar and may not start with `-` or `.`. |
| `--from DIR` | Import a trusted local PKGBUILD directory outside the repository's `packages/` root. `makepkg --printsrcinfo` executes PKGBUILD top-level code. Cannot be combined with AUR track. |
| `--track TRACK` | `aur`, `manual`, `workflow`, `git-tag`, `git-tag-pin`, `git-commit`, or `git-vcs`. Without `--from`, only AUR is permitted and is the default. With local import, inferred default is `git-vcs` when there is `pkgver()` and one inferable unpinned Git source, otherwise `manual`. |
| `--strategy STRATEGY` | `source`, `vcs`, `binary`, or `data`. Defaults to `vcs` if PKGBUILD defines `pkgver()`, otherwise `source`. `vcs` requires `pkgver()`; `binary` forbids it. |
| `--reason REASON` | Only valid with `--track manual`; required and nonempty for manual declarations. |
| `--workflow PATH` | Only valid with `--track workflow`; must identify an existing `.github/workflows/<name>.yml` or `.yaml` file. |
| `--git URL` | Only valid with Git tracks; required unless a unique unpinned Git source is inferred. |
| `--tag-pattern REGEX` | Only valid with `git-tag` and `git-tag-pin`; compiled as a regular expression. |
| `--pkgver-from RULE` | Only valid with `git-tag`; accepts `identity`, `strip_v`, `date_version`, or `regex_extract:<pattern>`. |
| `--on-update ACTION` | Only valid with Git tracks; `pull-request`, `issue`, or `none`. Defaults to `pull-request`. |
| `--non-interactive` | Do not prompt for unspecified local-import options. Supply all fields needed by the selected track. |

With a terminal and without `--non-interactive`, missing local update settings may be prompted. Options incompatible with the selected track are rejected. A local directory must contain a regular `PKGBUILD`, and its declared `pkgbase` must equal `PACKAGE`. Support files are copied; `.SRCINFO` and repository metadata are regenerated. The package is staged in a temporary directory and renamed into place only after validation succeeds.

AUR import clones the AUR package-base repository and records its URL and commit. If a requested output package name is not itself a repository, the command uses AUR RPC to resolve the package base. Existing overlays cause the import to be refused so they cannot be silently omitted.

## `manage.sh packages`

```text
./manage.sh packages list [--track TRACK] [--no-header]
./manage.sh packages show PKGBASE
```

`list` prints tab-separated package base, version, update track, and strategy; `--track` filters by one of the declared tracks and `--no-header` omits the heading. `show` displays one package's version, track, strategy, output packages, and applicable declaration fields. The hidden `--root PATH` option exists for internal/testing use.

## Main fzf interface

Running `./manage.sh` opens the separate interactive management interface. Its startup `--no-push` option only changes the initial automatic-push toggle; it does not alter the direct `add` or `packages` commands. Install `fzf` and `github-cli` for the interactive workflows. See [package management tutorial](../tutorials/package-management.md).
