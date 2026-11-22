# `update.toml` reference

Each package may declare `packages/<pkgbase>/update.toml`. When present, it is authoritative for both update source (`track`) and build behavior (`strategy`); an invalid declaration does not fall back to legacy files. The parser is implemented in `scripts/bot/declaration.py`. The updater in `scripts/bot/update.py` handles only Git tracks whose `on_update` is `pull-request`.

## Common fields

| Field | Required | Accepted values / behavior |
|---|---:|---|
| `track` | yes | `aur`, `manual`, `workflow`, `git-tag`, `git-tag-pin`, `git-commit`, `git-vcs` |
| `strategy` | yes | `source`, `vcs`, `binary`, `data`; legacy alias `binary-repack` parses as `binary` |

Both fields must be TOML strings. Values are trimmed. Strategy is independent of track. Manifest checks additionally require a `pkgver()` function for `vcs` and forbid one for `binary`; no equivalent recipe check is made for `source` or `data`.

## Track fields

| Track | Required fields | Optional fields | Meaning |
|---|---|---|---|
| `aur` | `url`, `commit` | none | `url` must exactly match `https://aur.archlinux.org/<name>.git`; `commit` must be 40 lowercase hex characters. AUR sync mirrors that pinned commit and updates package files and the declaration. |
| `manual` | `reason` | none | Records why updates are maintained manually. `reason` must be nonempty after trimming. |
| `workflow` | `workflow` | none | Names the repository-relative workflow owning updates. Declaration validation rejects absolute paths, `..`, and `.`. `manage add` further requires the exact `.github/workflows/<existing-file>.yml` or `.yaml` form. |
| `git-tag` | `git` | `tag_pattern`, `pkgver_from`, `on_update` | Chooses the newest version-sorted matching tag, converts it to `pkgver`, and sets `pkgrel = 1` when the converted version differs. |
| `git-tag-pin` | `git` | `tag_pattern`, `on_update` | Chooses the newest matching tag and pins `_commit` to its commit; increments `pkgrel`, leaving `pkgver` unchanged. Intended for packages versioned independently within a shared upstream repository. |
| `git-commit` | `git` | `on_update` | Pins `_commit` to upstream HEAD and increments `pkgrel` when changed. |
| `git-vcs` | `git` | `on_update` | Compares the last dot-separated suffix in PKGBUILD’s `pkgver` (at least seven lowercase hex characters) with the first seven characters of upstream HEAD. A mismatch or missing suffix causes a `pkgrel` increment. `pkgver()` derives the new version during build. |

Git URL is a required nonempty string in the declaration parser. `manage add` additionally rejects whitespace, leading `-`, and a `::` prefix before the scheme. `git-tag-pin` and `git-commit` require `_commit` in PKGBUILD when imported via the CLI; `git-vcs` requires `pkgver()`.

## Git options and defaults

`tag_pattern` is an optional regular expression compiled by Python. It is applied with `match()` to each tag; the newest candidate is selected using `sort -V`. An empty or omitted pattern allows all tags. It is meaningful for `git-tag` and `git-tag-pin`.

`pkgver_from` applies only to `git-tag`. It defaults to `strip_v`. The supported closed set is:

| Rule | Result |
|---|---|
| `identity` | Keep the tag unchanged. |
| `strip_v` | Remove one leading lowercase `v`. |
| `date_version` | Collect digits; when there are at least 8, format the first eight as `YYYY.MM.DD`; otherwise retain the original tag. |
| `regex_extract:<pattern>` | Search the tag; return capture group 1 if present, otherwise the full match. No match is an update error. |

An empty value is normalized to `strip_v`. The declaration reader accepts these Git option fields as strings for every Git track. Their effects are limited to the tracks above. For `git-tag`, `manage add` validates the rule name and requires a compilable, nonempty `regex_extract` pattern. For a handwritten declaration the rule is evaluated when the updater finds a matching tag. An unknown function causes an update error.

`on_update` applies to all Git tracks and defaults to `pull-request` when missing or empty:

- `pull-request`: eligible for `scripts/bot/update.py` plan/apply and the scheduled PR updater.
- `issue`: excluded from the PR updater; use a separate issue-reporting mechanism if configured.
- `none`: excluded from automated update actions.

## Optional schedule

A package may limit when the central updater probes it:

```toml
[schedule]
cron = "0 0,12 * * *"
timezone = "Asia/Shanghai"
```

`cron` uses five fields (minute, hour, day of month, month, day of week) and
supports lists, ranges, steps, and `*`. `timezone` is an IANA timezone name.
When `[schedule]` is omitted, the repository default is twice daily at 00:00
and 12:00 in `Asia/Shanghai`. The scheduled workflow runs at the corresponding
UTC times and passes `--due-only`; manual dispatches ignore the schedule so a
maintainer can force an immediate check. The schedule controls probing only;
PKGBUILD dependencies remain the source of build ordering and install tests.

The Git updater only reads eligible Git declarations. Probe or declaration errors return failure, not “up to date.” Exit status is `0` when current, `10` when an update is available, and `2` when a check/apply fails. It only writes PKGBUILD and `.SRCINFO` with `--apply`; the scheduled workflow performs this in a branch and proposes a PR.

Recognized fields are strings with surrounding whitespace stripped. Unknown top-level keys are ignored. The manifest checker also verifies that a `workflow` path is Git-tracked (or exists on disk when Git tracking information is unavailable).

## Build strategy semantics

- `source`: locally build package payload from source.
- `vcs`: build from a moving Git source; requires `pkgver()`.
- `binary`: repack upstream-built binaries; must not define `pkgver()`.
- `data`: static data/assets, not subject to system ABI rebuilds.

These strategies influence drift reporting and rebuild dispatch. See [build strategy](build-strategy.md) for the exact consumers and fail-safe behavior.

## Legacy declarations

Packages without `update.toml` may use `.aur-url` + `.aur-commit`, `config/package-updates.txt`, and `.build-strategy`. A present TOML takes precedence; malformed TOML is an error and does not fall back. Historical legacy Git declarations without `strategy` can be read by a separate compatibility path, but new declarations must include it. `.nvchecker.toml` and `.rebuild-on` remain separate inputs: they describe version trackers and rebuild triggers, not the package's update source.

Validate with `python3 scripts/check-package-manifests.py`; inspect effective values with `./manage.sh packages show <pkgbase>`.
