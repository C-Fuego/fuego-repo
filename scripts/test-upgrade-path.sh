#!/usr/bin/env bash
# Test a repository package upgrade in a disposable CachyOS-v3 chroot.
set -Eeuo pipefail
package_name="${PACKAGE_NAME:?PACKAGE_NAME is required}"
new_dir="${1:?usage: test-upgrade-path.sh NEW_ARTIFACT_DIR OLD_REPOSITORY_DIR CACHE_DIR}"
old_dir="${2:?}"
cache_dir="${3:?}"
case "$package_name" in linuxqq-wayland-fix-git|folia) ;; *) echo "Upgrade dry-run is scoped to linuxqq-wayland-fix-git (AUR-synced VCS) and folia (tag-tracking crate); skipping $package_name."; exit 0 ;; esac
new_pkg="$(find "$new_dir" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print -quit)"
[[ -n "$new_pkg" ]] || { echo "No newly built package in $new_dir" >&2; exit 2; }
new_name="$(bsdtar -xOf "$new_pkg" .PKGINFO | awk -F ' = ' '$1 == "pkgname" {print $2; exit}')"
[[ "$new_name" == "$package_name" ]] || { echo "Expected $package_name, got $new_name" >&2; exit 2; }
# Both scoped packages keep their name across publishes, so the previous
# artifact is simply found by name. A first publish legitimately has none and
# reports UNVERIFIABLE instead of failing.
old_pkg="$(find "$old_dir" -maxdepth 1 -type f -name "${package_name}-*.pkg.tar.zst" -print -quit)"
if [[ -z "$old_pkg" ]]; then
    echo "UPGRADE_PATH=UNVERIFIABLE: no previous $package_name package in the published repository; no upgrade success is claimed." >&2
    exit 0
fi
# 哨兵:chroot 构建留下的 pacman-base.conf(树形态)或 runner 缓存里的
# baseline 归档(纯 legacy run 的常态)任一存在即可继续。
base_config="$cache_dir/chroot/pacman-base.conf"
cached_archive="$(find "$cache_dir/chroot/baselines" -maxdepth 1 -type f -name 'baseline-*.tar.zst' -print -quit 2>/dev/null || true)"
if [[ ! -f "$base_config" && -z "$cached_archive" ]]; then
    # The baseline fixture only exists once a chroot-mode build (or a warm
    # baseline cache) creates it. Legacy-mode runs legitimately have none:
    # failing the build would block publishing a verified package because a
    # test fixture is absent. Skip loudly instead of failing; the promotion of
    # chroot as the default build mode makes this deterministic.
    printf '::warning::Clean chroot baseline missing (%s); upgrade-path test skipped for %s.\n' "$base_config" "$package_name"
    echo 'UPGRADE_PATH=UNVERIFIABLE: no clean-chroot baseline fixture; no upgrade success is claimed.' >&2
    exit 0
fi
work="$(mktemp -d "$cache_dir/chroot/upgrade-${package_name}.XXXXXX")"
# 容器里跑 arch-nspawn 需要同一个 nspawn 垫片(见 lib/nspawn-shim.sh),否则
# 裸 nspawn 会在 journal 链接上失败——baseline 一就位这里就会真的执行。
upgrade_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/nspawn-shim.sh
source "$upgrade_script_dir/lib/nspawn-shim.sh"
shim_dir="$(nspawn_shim_install "/tmp/pkgbuild-upgrade-nspawn-${package_name}.XXXXXX")"
trap 'rm -rf -- "$work" "$shim_dir"' EXIT INT TERM
PATH="$shim_dir:$PATH"
mkdir -p "$work/root"
baseline_root="$(find "$cache_dir/chroot" -mindepth 2 -maxdepth 2 -type d -path '*/baseline-*/root' -print -quit)"
if [[ -n "$baseline_root" ]]; then
    cp --reflink=auto -a "$baseline_root/." "$work/root/"
else
    # 容器内打的归档(baselines/ 子目录)是 runner 缓存的单元;树是构建期产物。
    baseline_archive="$(find "$cache_dir/chroot/baselines" -maxdepth 1 -type f -name 'baseline-*.tar.zst' -print -quit 2>/dev/null)"
    if [[ -z "$baseline_archive" ]]; then
        printf '::warning::No cached clean-chroot baseline archive; upgrade-path test skipped for %s.\n' "$package_name"
        echo 'UPGRADE_PATH=UNVERIFIABLE: no clean-chroot baseline fixture; no upgrade success is claimed.' >&2
        exit 0
    fi
    mkdir -p "$work/baseline"
    tar --zstd -xf "$baseline_archive" -C "$work/baseline"
    cp --reflink=auto -a "$work/baseline/root/." "$work/root/"
fi
# staging 仓库放宿主侧:arch-nspawn 会对 pacman.conf 里的 file:// Server 按
# 宿主路径做 bind,「容器内路径」(/tmp/upgrade-repo,落在 work root 里)在
# 宿主侧不存在,nspawn 直接 'Failed to clone'(2026-10-11 首次真跑实测)。
# 宿主路径同时就是容器内路径,nspawn --bind 两端一致。
repo_dir="$(mktemp -d /tmp/upgrade-repo.XXXXXX)"
trap 'rm -rf -- "$work" "$shim_dir" "$repo_dir"' EXIT INT TERM
# Include the previous repository package set so private dependencies remain
# resolvable in the disposable chroot. Replace the old target package with the
# artifact built in this run before generating the temporary database.
while IFS= read -r -d '' package; do
    cp -f -- "$package" "$repo_dir/"
done < <(find "$old_dir" -maxdepth 1 -type f -name '*.pkg.tar.zst' -print0)
if [[ -n "$old_pkg" ]]; then
    mkdir -p "$work/root/tmp"
    cp -f -- "$old_pkg" "$work/root/tmp/old.pkg.tar.zst"
fi
new_pkgname="$(bsdtar -xOf "$new_pkg" .PKGINFO | awk -F ' = ' '$1 == "pkgname" {print $2; exit}')"
[[ -n "$new_pkgname" ]] || { echo "Missing pkgname in $new_pkg" >&2; exit 2; }
find "$repo_dir" -maxdepth 1 -type f -name "${new_pkgname}-*.pkg.tar.zst" -delete
cp -f -- "$new_pkg" "$repo_dir/"
repo-add --remove "$repo_dir/fuego-repo-staging.db.tar.gz" "$repo_dir/"*.pkg.tar.zst
python3 - "$work/root/etc/pacman.conf" "$repo_dir" <<'PYCONF'
from pathlib import Path
import re, sys
path, staging_dir = sys.argv[1], sys.argv[2]
text = Path(path).read_text(encoding='utf-8')
match = re.search(r'(?m)^\[cachyos-v3\]\s*$', text)
if not match:
    raise SystemExit('Upgrade chroot config lost the cachyos-v3 repository')
staging = f'[fuego-repo-staging]\nSigLevel = Never\nServer = file://{staging_dir}\n\n'
Path(path).write_text(text[:match.start()] + staging + text[match.start():], encoding='utf-8')
PYCONF
# -c:baseline 的 config 由 mkarchroot -c 写入 CacheDir=/cache/pacman,但不
# bind 的话 pacman 只能落在 /tmp("couldn't find or create package cache")。
# 与 build-in-clean-chroot.sh 的 update-first 同款:同路径 rw bind 共享缓存。
arch-nspawn -c "$cache_dir/pacman" "$work/root" pacman -Syu --noconfirm
# Both scoped packages keep their name across publishes, so the upgrade is a
# plain same-name transaction: install the old private release, then let pacman
# upgrade it to the artifact built in this run.
mapfile -t dependencies < <(bsdtar -xOf "$old_pkg" .PKGINFO | awk -F ' = ' '$1 == "depend" {print $2}')
if ((${#dependencies[@]} > 0)); then arch-nspawn -c "$cache_dir/pacman" "$work/root" pacman -S --needed --noconfirm "${dependencies[@]}"; fi
# Install the old private release first to exercise the upgrade transaction.
arch-nspawn -c "$cache_dir/pacman" "$work/root" pacman -U --noconfirm /tmp/old.pkg.tar.zst
# conflicts 移除问题在 --noconfirm 下照默认答 N,事务直接失败(--ask=4 与
# build-in-arch.sh 的 pacman 垫片同语义:一次性容器里自动接受冲突移除)。
arch-nspawn -c "$cache_dir/pacman" "$work/root" pacman -Syu --noconfirm --ask=4 "$package_name"
installed="$(arch-nspawn "$work/root" pacman -Q "$package_name")"
printf 'UPGRADE_PATH=PASS: %s\n' "$installed"
