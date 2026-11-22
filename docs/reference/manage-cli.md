# Package manager CLI reference

For an installed `repo-manager` entry point, always pass `--repo PATH`; it never discovers or binds to the current directory automatically. Create a lightweight checkout first with `repo-manager init PATH`, then launch it explicitly with `repo-manager --repo PATH`.

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
| `--strategy STRATEGY` | `source`, `vcs`, `binary`, or `data`. The legacy spelling `binary-repack` is accepted as `binary`. Defaults to `vcs` if PKGBUILD defines `pkgver()`, otherwise `source`. `vcs` requires `pkgver()`; `binary` forbids it. |
| `--reason REASON` | Only valid with `--track manual`; must be nonempty. If `--track manual` is explicit, provide a reason or enter it when prompted. Inferred `manual` defaults to `Imported from a local PKGBUILD; updates are maintained manually.` |
| `--workflow PATH` | Only valid with `--track workflow`; must identify an existing `.github/workflows/<name>.yml` or `.yaml` file. |
| `--git URL` | Only valid with Git tracks; required unless a unique unpinned Git source is inferred. |
| `--tag-pattern REGEX` | Only valid with `git-tag` and `git-tag-pin`; compiled as a regular expression. |
| `--pkgver-from RULE` | Only valid with `git-tag`; accepts `identity`, `strip_v`, `date_version`, or `regex_extract:<pattern>`. |
| `--on-update ACTION` | Only valid with Git tracks; `pull-request`, `issue`, or `none`. Defaults to `pull-request`. |
| `--non-interactive` | Do not prompt for unspecified local-import options. Supply all fields needed by the selected track. |

With a terminal on stdin and without `--non-interactive`, the CLI can prompt for the track, manual reason, workflow path, or Git URL. With no explicit `--track`, `--reason` selects manual and `--workflow` selects workflow (in that order). Options incompatible with the selected track are rejected. A local directory must contain a regular `PKGBUILD`, and its declared `pkgbase` must equal `PACKAGE`. Support files are copied; `.SRCINFO` and repository metadata are regenerated. The package is staged in a temporary directory and renamed into place only after validation succeeds.

AUR import clones the AUR package-base repository and records its URL and commit. If a requested output package name is not itself a repository, the command uses AUR RPC to resolve the package base. Existing overlays cause the import to be refused so they cannot be silently omitted.

## `manage.sh packages`

```text
./manage.sh packages
./manage.sh packages list [--track TRACK] [--no-header]
./manage.sh packages show PKGBASE
```

`packages` alone behaves like `packages list`. `list` prints tab-separated package base, version, update track, and strategy; `--track` filters by one of the declared tracks and `--no-header` omits the heading. `show` displays one package's version, track, strategy, output packages, and applicable declaration fields. The hidden `--root PATH` option exists for internal/testing use.

## Menu and named actions

```text
./manage.sh [--no-push] [ACTION]
./manage.sh --list
./manage.sh -h | --help
```

Without an action, the script starts the fzf menu. A named action skips the main menu but can still open pickers or confirmation prompts. The menu and action runner require Git and fzf. GitHub operations also require an authenticated `gh`. See the [package management tutorial](../tutorials/package-management.md).

| Option | Effect |
|---|---|
| `--no-push` | Starts the automatic-push toggle off. Legacy add and remove actions can still commit locally. The direct `add` and `packages` commands also accept this flag before the command and have the same behavior with or without it. |
| `--list` | Prints action codes and menu labels as tab-separated pairs, then exits. |
| `-h`, `--help` | Prints shell command help, then exits. The Python subcommands also accept their own `-h` and `--help`. |

| Action | Behavior |
|---|---|
| `dashboard` | Show repository and worktree status, recent CI activity, and local timing/repair record counts. |
| `add` | Direct CLI import as documented above. The menu entry offers AUR or a trusted local PKGBUILD directory, then prompts for the input before invoking the importer. |
| `packages` | Direct CLI inventory. The menu entry opens a searchable inventory and shows details for the selected package. |
| `add-aur` | Run the legacy Git-based AUR add workflow with commit and optional push. |
| `add-custom` | Run the legacy add workflow with a custom Git source, commit, and optional push. |
| `remove` | Select and confirm removal of a package base, then commit and optionally push the removal. |
| `sync-aur` | Dispatch GitHub Actions to sync all or selected AUR mirrors. |
| `build` | Select packages and dispatch the GitHub build workflow with a compiler job count. |
| `track` | Select and follow a running GitHub build. |
| `triage` | Select a failed build to inspect its failed jobs and logs. |
| `check-local` | Run local PKGBUILD checks for selected packages. |
| `audit` | Run the local audit across all packages. |
| `plan` | Show a build plan for all packages, the last commit difference, or selected package names, followed by the dependency DAG. |
| `parallel` | Preview dependency waves or run a local parallel build. |
| `timing` | Report aggregate durations and cache statistics from local build history. |
| `repair` | Analyze a supplied build log, preview auto-repair from a failure report, or view recent repair history. |
| `doctor` | Run environment, toolchain, cache, repository, and network checks. |
| `updates` | Compare locally installed and repository versions. |
| `update-repo` | Refresh the local pacman repository. |
| `install` | Select a repository package to install. |
| `actions` | Browse recent GitHub Actions runs. |
| `pull` | Pull `origin main` with `--ff-only` after checking that the worktree is clean. |

The menu also includes controls to toggle automatic push and to quit. They are available from the menu itself.

| Environment variable | Default | Effect |
|---|---|---|
| `PKGBUILD_GITHUB_REPOSITORY` | `C-Fuego/fuego-repo` | GitHub repository in `owner/repository` form for remote operations. |
| `PKGBUILD_PACMAN_REPOSITORY` | `fuego-repo` | Pacman repository name for local operations. |
| `PKGBUILD_DEFAULT_MAKE_JOBS` | `2` | Default compiler job count in the GitHub build prompt, from `1` to `4`. |
| `AUTO_FIX_LEVEL` | `1` | Repair level passed to the repair preview action. |
