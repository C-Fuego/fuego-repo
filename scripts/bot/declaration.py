"""One declaration per package: who the upstream is, and how it is tracked.

``update.toml`` is the authoritative source for the update track and build
strategy. Packages without it may still use ``.aur-url`` and ``.aur-commit`` or
``config/package-updates.txt`` for the update source, and ``.build-strategy``
for the strategy. Version trackers and rebuild triggers are still read from
``.nvchecker.toml`` and ``.rebuild-on`` respectively.

Roles that are easy to conflate are kept apart:

  update        which process refreshes PKGBUILD pkgver (at most one)
  trackers      which upstream versions the repository watches (zero or more)

The distinction matters for packages that track vendored dependencies:
those trackers are watched for drift but never update the package on their own.
Treating those as one list would either lose trackers or claim multiple update
sources.  `declaration.validate` cross-checks the result against the existing
readers, so a disagreement is a failing check rather than a silent divergence.
"""

from __future__ import annotations

import re
import tomllib
from dataclasses import dataclass
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

PACKAGE_ROOT = "packages"
UPDATE_FILENAME = "update.toml"
AUR_URL_FILENAME = ".aur-url"
AUR_COMMIT_FILENAME = ".aur-commit"
NVCHECKER_FILENAME = ".nvchecker.toml"
BUILD_STRATEGY_FILENAME = ".build-strategy"
REBUILD_ON_FILENAME = ".rebuild-on"
REGISTRY_PATH = Path("config/package-updates.txt")

BUILD_STRATEGIES = ("source", "vcs", "binary", "data")
BUILD_STRATEGY_ALIASES = {"binary-repack": "binary"}
REGISTRY_KINDS = ("manual", "workflow")
GIT_TRACKS = ("git-tag", "git-tag-pin", "git-commit", "git-vcs")
UPDATE_TRACKS = ("aur", *REGISTRY_KINDS, *GIT_TRACKS)
ON_UPDATE = ("pull-request", "issue", "none")
DEFAULT_SCHEDULE = "0 0,12 * * *"
DEFAULT_TIMEZONE = "Asia/Shanghai"
REBUILD_ON_KINDS = ("soname", "package")

AUR_URL = re.compile(r"^https://aur\.archlinux\.org/(?P<name>[A-Za-z0-9@._+-]+)\.git$")
GIT_COMMIT = re.compile(r"^[0-9a-f]{40}$")
SONAME = re.compile(r"^[A-Za-z0-9+._-]+\.so(\.[0-9]+)*$")
PKGVER_FUNCTION = re.compile(
    r"^[ \t]*(?:function[ \t]+)?pkgver[ \t]*\([ \t]*\)\s*\{", re.MULTILINE
)
VERSION_CONSTRAINT = re.compile(r"[<>=].*$")

#: Reserved nvchecker tables that are this repository's own extension, not
#: upstream definitions.  See scripts/check-upstream-versions.py.
NVCHECKER_RESERVED = ("__config__", "__baselines__")

#: A baseline expressed as a reference into the package directory rather than a
#: literal version (again this repository's extension).
PKGVAR_BASELINE = "pkgvar:"
PIN_BASELINE = "pin:"


class DeclarationError(RuntimeError):
    """A package's declaration cannot be read at all (not merely suspect)."""


@dataclass(frozen=True)
class AurMirror:
    """The package is a mirror of an AUR repo, pinned to a commit."""

    url: str
    package: str
    commit: str


@dataclass(frozen=True)
class WorkflowUpdate:
    """An automated updater owns this package's PKGBUILD."""

    path: str


@dataclass(frozen=True)
class ManualUpdate:
    """Nothing refreshes this package, and that is a recorded decision."""

    reason: str


@dataclass(frozen=True)
class GitUpdate:
    """The package is refreshed by the declarative git updater."""

    track: str
    git: str
    tag_pattern: str = ""
    pkgver_from: str = "strip_v"
    on_update: str = "pull-request"


UpdateSource = AurMirror | WorkflowUpdate | ManualUpdate | GitUpdate


@dataclass(frozen=True)
class Tracker:
    """One nvchecker definition, plus the baseline it is compared against.

    `name` is the nvchecker table name, which is *not* necessarily the package
    name: a package can watch a vendored dependency under its own upstream
    name.  `config` is the definition verbatim so that regenerating the TOML is
    byte-exact.
    """

    name: str
    config: dict
    baseline: str
    #: Set when the baseline comes from a `pkgvar:`/`pin:` reference rather
    #: than from the package's own pkgver.
    baseline_reference: str | None = None

    @property
    def is_package_version(self) -> bool:
        """True when this tracker's baseline is the package's own pkgver."""
        return self.baseline_reference is None


@dataclass(frozen=True)
class RebuildTrigger:
    kind: str
    name: str
    provider: str | None = None


@dataclass(frozen=True)
class PackageDeclaration:
    name: str
    directory: Path
    build_strategy: str
    update: UpdateSource | None
    trackers: tuple[Tracker, ...] = ()
    rebuild_on: tuple[RebuildTrigger, ...] = ()
    pkgver: str | None = None
    pkgrel: str | None = None
    errors: tuple[str, ...] = ()

    @property
    def strategy(self) -> str:
        return self.build_strategy

    @property
    def package_version_tracker(self) -> Tracker | None:
        """The tracker whose baseline is this package's own version, if any."""
        for tracker in self.trackers:
            if tracker.is_package_version:
                return tracker
        return None

    @property
    def is_pinned(self) -> bool:
        """Whether the package's own update path is deliberately held back.

        AUR mirrors pin a commit (.aur-commit); the Rezig packages pin `_commit`
        inside the PKGBUILD.  Both mean "upstream moved, and we did not", which
        is exactly what a pin watcher reports.  A `manual` entry is not a pin:
        it says nobody refreshes the package, not that a specific revision is
        deliberately held.
        """
        return isinstance(self.update, AurMirror) or (
            isinstance(self.update, GitUpdate)
            and self.update.track in ("git-tag-pin", "git-commit")
        )


# --------------------------------------------------------------------------
# readers
# --------------------------------------------------------------------------


def _read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def read_aur(url_path: Path, commit_path: Path) -> tuple[AurMirror | None, list[str]]:
    """Read .aur-url/.aur-commit.  Missing files are not an error here."""
    errors: list[str] = []
    if not url_path.is_file() and not commit_path.is_file():
        return None, errors
    if not url_path.is_file():
        return None, [f"{commit_path.name} is present without {url_path.name}"]
    if not commit_path.is_file():
        return None, [f"{url_path.name} is present without {commit_path.name}"]
    url = _read_text(url_path).strip()
    commit = _read_text(commit_path).strip()
    match = AUR_URL.match(url)
    if not match:
        errors.append(f"{url_path.name}: {url!r} is not an AUR git URL")
        return None, errors
    if not GIT_COMMIT.match(commit):
        errors.append(f"{commit_path.name}: {commit!r} is not a 40-character commit")
        return None, errors
    return AurMirror(url=url, package=match.group("name"), commit=commit), errors


def has_update_file(package_dir: Path) -> bool:
    path = package_dir / UPDATE_FILENAME
    return path.exists() or path.is_symlink()


def normalize_build_strategy(value: object) -> str | None:
    """Return the canonical name for a supported strategy value."""
    if not isinstance(value, str):
        return None
    value = BUILD_STRATEGY_ALIASES.get(value, value)
    return value if value in BUILD_STRATEGIES else None


def validate_schedule(value: object, timezone: object, path: Path) -> tuple[str, str, list[str]]:
    """Validate the small five-field cron subset and IANA timezone."""
    errors: list[str] = []
    if not isinstance(value, str) or not value.strip():
        errors.append(f"{path.name}: schedule.cron must be a non-empty string")
        return "", "", errors
    cron = value.strip()
    fields = cron.split()
    if len(fields) != 5:
        errors.append(f"{path.name}: schedule.cron must have five cron fields")
    else:
        ranges = ((0, 59), (0, 23), (1, 31), (1, 12), (0, 7))
        for field_text, (minimum, maximum) in zip(fields, ranges):
            for item in field_text.split(","):
                base, slash, step = item.partition("/")
                if slash and (not step.isdigit() or int(step) < 1):
                    errors.append(f"{path.name}: invalid cron step {item!r}")
                    continue
                bounds = base.split("-") if base != "*" else ["*"]
                if len(bounds) == 2:
                    try:
                        start, end = map(int, bounds)
                        if start < minimum or end > maximum or start > end:
                            raise ValueError
                    except ValueError:
                        errors.append(f"{path.name}: cron value {item!r} is out of range")
                elif len(bounds) == 1 and bounds[0] != "*":
                    if not bounds[0].isdigit() or not minimum <= int(bounds[0]) <= maximum:
                        errors.append(f"{path.name}: cron value {item!r} is out of range")
                elif len(bounds) > 2:
                    errors.append(f"{path.name}: invalid cron field {item!r}")
    if not isinstance(timezone, str) or not timezone.strip():
        errors.append(f"{path.name}: schedule.timezone must be a non-empty IANA timezone")
        zone = ""
    else:
        zone = timezone.strip()
        try:
            ZoneInfo(zone)
        except (ZoneInfoNotFoundError, ValueError):
            errors.append(f"{path.name}: unknown IANA timezone {zone!r}")
    return cron, zone, errors


def read_update(path: Path) -> tuple[UpdateSource | None, str | None, list[str]]:
    """Read a package update.toml, including its required build strategy."""
    try:
        with path.open("rb") as stream:
            data = tomllib.load(stream)
    except (OSError, UnicodeError, tomllib.TOMLDecodeError) as exc:
        return None, None, [f"{path.name}: cannot read: {exc}"]

    errors: list[str] = []

    def field(key: str, default: str = "", *, required: bool = False) -> str:
        value = data.get(key, default)
        if not isinstance(value, str):
            errors.append(f"{path.name}: {key} must be a string")
            return ""
        value = value.strip()
        if required and not value:
            errors.append(f"{path.name}: {key} must be a non-empty string")
        return value

    schedule = data.get("schedule")
    if schedule is not None:
        if not isinstance(schedule, dict):
            errors.append(f"{path.name}: schedule must be a table")
        else:
            unknown = sorted(set(schedule) - {"cron", "timezone"})
            if unknown:
                errors.append(f"{path.name}: unknown schedule field(s): {', '.join(unknown)}")
            _, _, schedule_errors = validate_schedule(
                schedule.get("cron"), schedule.get("timezone", DEFAULT_TIMEZONE), path
            )
            errors.extend(schedule_errors)

    track = field("track")
    value = field("strategy")
    strategy = normalize_build_strategy(value)
    if strategy is None:
        errors.append(
            f"{path.name}: strategy must be one of {', '.join(BUILD_STRATEGIES)} "
            f"(got {value!r})"
        )

    update = None
    if track == "aur":
        url = field("url", required=True)
        commit = field("commit", required=True)
        match = AUR_URL.fullmatch(url)
        if url and match is None:
            errors.append(f"{path.name}: url {url!r} is not an https://aur.archlinux.org/<name>.git URL")
        valid_commit = bool(GIT_COMMIT.fullmatch(commit))
        if commit and not valid_commit:
            errors.append(f"{path.name}: commit must be a 40-character git commit hash")
        if match and valid_commit:
            update = AurMirror(url, match.group("name"), commit)
    elif track == "manual":
        reason = field("reason", required=True)
        if reason:
            update = ManualUpdate(reason)
    elif track == "workflow":
        workflow = field("workflow", required=True)
        if workflow:
            candidate = Path(workflow)
            if candidate.is_absolute() or ".." in candidate.parts or candidate == Path("."):
                errors.append(f"{path.name}: workflow must be a repository-relative file path")
            else:
                update = WorkflowUpdate(candidate.as_posix())
    elif track in GIT_TRACKS:
        git = field("git", required=True)
        tag_pattern = field("tag_pattern")
        pkgver_from = field("pkgver_from", "strip_v") or "strip_v"
        on_update = field("on_update", "pull-request") or "pull-request"
        if on_update not in ON_UPDATE:
            errors.append(f"{path.name}: on_update must be one of {', '.join(ON_UPDATE)}")
        if tag_pattern:
            try:
                re.compile(tag_pattern)
            except re.error as exc:
                errors.append(f"{path.name}: invalid tag_pattern: {exc}")
        if git:
            update = GitUpdate(track, git, tag_pattern, pkgver_from, on_update)
    else:
        errors.append(f"{path.name}: track must be one of {', '.join(UPDATE_TRACKS)} (got {track!r})")
    return update, strategy, errors


def package_build_strategy(package_dir: Path) -> tuple[str | None, list[str]]:
    """Read the effective build strategy without reading unrelated metadata."""
    if has_update_file(package_dir):
        _, strategy, errors = read_update(package_dir / UPDATE_FILENAME)
        return strategy, errors
    return read_build_strategy(package_dir / BUILD_STRATEGY_FILENAME)


def read_build_strategy(path: Path) -> tuple[str | None, list[str]]:
    """First non-blank, non-comment line; the format lib/build-strategy.sh reads."""
    if not path.is_file():
        return None, [f"{BUILD_STRATEGY_FILENAME} is missing"]
    for line in _read_text(path).splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            strategy = normalize_build_strategy(stripped)
            if strategy is None:
                return None, [
                    f"{BUILD_STRATEGY_FILENAME} declares {stripped!r}, "
                    f"expected one of: {', '.join(BUILD_STRATEGIES)}"
                ]
            return strategy, []
    return None, [f"{BUILD_STRATEGY_FILENAME} is empty"]


def read_registry(path: Path, *, superseded: set[str] | None = None) -> tuple[dict[str, tuple[str, str]], list[str]]:
    """config/package-updates.txt as {package: (kind, detail)}."""
    entries: dict[str, tuple[str, str]] = {}
    errors: list[str] = []
    if not path.is_file():
        return entries, errors
    for lineno, raw in enumerate(_read_text(path).splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 2)
        if superseded and parts[0] in superseded:
            continue
        if len(parts) < 3:
            errors.append(f"{path}:{lineno}: expected `<package> <kind> <detail>`")
            continue
        package, kind, detail = parts
        if kind not in REGISTRY_KINDS:
            errors.append(
                f"{path}:{lineno}: unknown kind {kind!r} "
                f"(expected one of: {', '.join(REGISTRY_KINDS)})"
            )
            continue
        if package in entries:
            errors.append(f"{path}:{lineno}: duplicate entry for {package}")
            continue
        entries[package] = (kind, detail)
    return entries, errors


def pkgver_from_pkgbuild(path: Path) -> str | None:
    """The literal pkgver assignment, or None for a VCS pkgver() package."""
    try:
        text = _read_text(path)
    except OSError:
        return None
    match = re.search(r"(?m)^pkgver=['\"]?([^'\"\s#]+)", text)
    return match.group(1) if match else None


def pkgrel_from_pkgbuild(path: Path) -> str | None:
    try:
        text = _read_text(path)
    except OSError:
        return None
    match = re.search(r"(?m)^pkgrel=['\"]?([^'\"\s#]+)", text)
    return match.group(1) if match else None


def read_pkgbuild_variable(package_dir: Path, variable: str) -> str | None:
    match = re.search(
        rf"(?m)^{re.escape(variable)}=['\"]?([^'\"\s#]+)",
        _read_text(package_dir / "PKGBUILD"),
    )
    return match.group(1) if match else None


#: A git source reported by nvchecker with use_commit is a full hash, and the
#: repository's definition truncates it to 7 characters.  The baseline has to
#: be truncated the same way or the comparison never matches.
_GIT_HASH_TAIL = re.compile(r"([0-9a-f]{7,})$")
_GIT_PKGVER_SUFFIX = re.compile(r"\.g([0-9a-f]{7,})$")


def _resolve_baseline(package_dir: Path, name: str, reference: str,
                      config: dict) -> tuple[str | None, str, list[str]]:
    """Turn a `pkgvar:`/`pin:` baseline reference into a concrete version."""
    source_path = package_dir / NVCHECKER_FILENAME
    if reference.startswith(PKGVAR_BASELINE):
        variable = reference[len(PKGVAR_BASELINE):]
        value = read_pkgbuild_variable(package_dir, variable)
        if value is None:
            return None, reference, [
                f"{source_path.name}: baseline {reference} not found in PKGBUILD"
            ]
    elif reference.startswith(PIN_BASELINE):
        pin_name = reference[len(PIN_BASELINE):]
        pin_path = package_dir / pin_name
        try:
            lines = _read_text(pin_path).strip().splitlines()
            value = lines[0].strip()
        except (OSError, IndexError):
            return None, reference, [
                f"{source_path.name}: baseline {reference} is unreadable or empty"
            ]
    else:
        return reference, "", []

    if config.get("source") == "git" and config.get("use_commit"):
        match = _GIT_HASH_TAIL.search(value)
        if not match:
            return None, reference, [
                f"{source_path.name}: baseline {reference} ({value!r}) is not a git commit"
            ]
        value = match.group(1)[:7]
    return value, reference, []


def read_trackers(package_dir: Path) -> tuple[tuple[Tracker, ...], list[str]]:
    """Read .nvchecker.toml into Tracker objects with resolved baselines."""
    path = package_dir / NVCHECKER_FILENAME
    if not path.is_file():
        return (), []
    errors: list[str] = []
    try:
        data = tomllib.loads(_read_text(path))
    except tomllib.TOMLDecodeError as exc:
        return (), [f"{path.name}: {exc}"]

    explicit = data.get("__baselines__", {}) or {}
    if not isinstance(explicit, dict):
        return (), [f"{path.name}: __baselines__ must be a table"]

    pkgver = pkgver_from_pkgbuild(package_dir / "PKGBUILD")
    trackers: list[Tracker] = []
    for name, config in data.items():
        if name in NVCHECKER_RESERVED:
            continue
        if not isinstance(config, dict):
            errors.append(f"{path.name}: {name!r} is not a table")
            continue
        if name in explicit:
            baseline, reference, problems = _resolve_baseline(
                package_dir, name, str(explicit[name]), config
            )
            errors.extend(problems)
            if baseline is None:
                continue
            trackers.append(Tracker(name, config, baseline, reference))
            continue

        # No explicit baseline: it is the package's own pkgver.
        if pkgver is None:
            errors.append(
                f"{path.name}: {name!r} has no baseline and the PKGBUILD derives "
                "pkgver(), so there is nothing to compare against"
            )
            continue
        baseline = pkgver
        if config.get("source") == "git" and config.get("use_commit"):
            match = _GIT_PKGVER_SUFFIX.search(pkgver)
            if not match:
                errors.append(
                    f"{path.name}: git pkgver {pkgver!r} has no .g<sha> suffix"
                )
                continue
            baseline = match.group(1)[:7]
        trackers.append(Tracker(name, config, baseline))
    return tuple(trackers), errors


def read_rebuild_on(path: Path) -> tuple[tuple[RebuildTrigger, ...], list[str]]:
    """Read .rebuild-on: `soname <soname> <provider>` / `package <name>`."""
    if not path.is_file():
        return (), []
    triggers: list[RebuildTrigger] = []
    errors: list[str] = []
    seen: set[tuple[str, str]] = set()
    for lineno, raw in enumerate(_read_text(path).splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        kind = parts[0]
        where = f"{path.parent.name}/{REBUILD_ON_FILENAME}:{lineno}"
        if kind not in REBUILD_ON_KINDS:
            errors.append(
                f"{where}: unknown kind {kind!r} "
                f"(expected one of: {', '.join(REBUILD_ON_KINDS)})"
            )
            continue
        if kind == "soname":
            if len(parts) != 3:
                errors.append(f"{where}: expected `soname <soname> <provider>`")
                continue
            soname, provider = parts[1], parts[2]
            if not SONAME.match(soname):
                errors.append(f"{where}: {soname!r} is not a SONAME")
                continue
            trigger = RebuildTrigger("soname", soname, provider)
            key = (kind, soname)
        else:
            if len(parts) != 2:
                errors.append(f"{where}: expected `package <name>`")
                continue
            trigger = RebuildTrigger("package", parts[1])
            key = (kind, parts[1])
        if key in seen:
            errors.append(f"{where}: duplicate {kind} {trigger.name}")
            continue
        seen.add(key)
        triggers.append(trigger)
    return tuple(triggers), errors


def _update_from_registry(entry: tuple[str, str] | None) -> UpdateSource | None:
    if entry is None:
        return None
    kind, detail = entry
    if kind == "workflow":
        return WorkflowUpdate(path=detail)
    return ManualUpdate(reason=detail)


def read_package(package_dir: Path, registry: dict[str, tuple[str, str]]) -> PackageDeclaration:
    """Build one declaration from a packages/<name> directory."""
    name = package_dir.name
    errors: list[str] = []

    if has_update_file(package_dir):
        update, strategy, problems = read_update(package_dir / UPDATE_FILENAME)
        errors.extend(problems)
    else:
        aur, aur_errors = read_aur(package_dir / AUR_URL_FILENAME,
                                   package_dir / AUR_COMMIT_FILENAME)
        errors.extend(aur_errors)
        strategy, strategy_errors = read_build_strategy(package_dir / BUILD_STRATEGY_FILENAME)
        errors.extend(strategy_errors)
        registry_update = _update_from_registry(registry.get(name))
        if aur is not None and registry_update is not None:
            errors.append("declares an update source twice (.aur-url and registry entry)")
        update = aur or registry_update
        if update is None:
            errors.append("no update source declared")

    trackers, tracker_errors = read_trackers(package_dir)
    errors.extend(tracker_errors)

    triggers, trigger_errors = read_rebuild_on(package_dir / REBUILD_ON_FILENAME)
    errors.extend(trigger_errors)

    pkgbuild = package_dir / "PKGBUILD"
    pkgver = pkgver_from_pkgbuild(pkgbuild)
    pkgrel = pkgrel_from_pkgbuild(pkgbuild)

    # The strategy makes a claim the PKGBUILD can confirm or refute.
    build_text = _read_text(pkgbuild) if pkgbuild.is_file() else ""
    if strategy == "vcs" and not PKGVER_FUNCTION.search(build_text):
        errors.append("strategy 'vcs' requires a pkgver() function in the PKGBUILD")
    if strategy == "binary" and PKGVER_FUNCTION.search(build_text):
        errors.append("strategy 'binary' must not use pkgver()")

    # A tracker whose baseline is the package's own version has to agree with it.
    # For a git source the comparison happens on a truncated commit, not on the
    # full pkgver ("0.10.0.r0.g01bc7cc" is compared as "01bc7cc"), so apply the
    # same projection before calling them different.
    if pkgver is not None:
        for tracker in trackers:
            if not tracker.is_package_version:
                continue
            expected = pkgver
            if tracker.config.get("source") == "git" and tracker.config.get("use_commit"):
                match = _GIT_PKGVER_SUFFIX.search(pkgver)
                expected = match.group(1)[:7] if match else pkgver
            if tracker.baseline != expected:
                errors.append(
                    f"tracker {tracker.name!r} compares against {tracker.baseline!r} "
                    f"but the package declares pkgver {pkgver!r}"
                )

    return PackageDeclaration(
        name=name,
        directory=package_dir,
        build_strategy=strategy or "",
        update=update,
        trackers=trackers,
        rebuild_on=triggers,
        pkgver=pkgver,
        pkgrel=pkgrel,
        errors=tuple(errors),
    )


def package_dirs(root: Path) -> list[Path]:
    packages_root = root / PACKAGE_ROOT
    if not packages_root.is_dir():
        return []
    return sorted(
        (path for path in packages_root.iterdir()
         if path.is_dir() and ((path / "PKGBUILD").is_file()
                               or (path / ".SRCINFO").is_file())),
        key=lambda path: path.name,
    )


def load_all(root: Path) -> tuple[list[PackageDeclaration], list[str]]:
    """Every declaration under root, plus errors that are not package-local."""
    directories = package_dirs(root)
    superseded = {path.name for path in directories if has_update_file(path)}
    registry, errors = ({}, [])
    if len(superseded) != len(directories):
        registry, errors = read_registry(root / REGISTRY_PATH, superseded=superseded)
    declarations = [read_package(path, registry) for path in directories]

    known = {declaration.name for declaration in declarations}
    for package in sorted(registry):
        if package not in known:
            errors.append(
                f"{REGISTRY_PATH}: entry for {package!r}, which is not a package directory"
            )
    return declarations, errors
