#!/usr/bin/env bash
# update-pkgver.sh — 检测 osu!lazer tachyon 最新版并更新本 PKGBUILD (轻量, 不下载)
# 由 check-upstream.sh 的 always 分支调用。sha256 已设 SKIP, makepkg 构建时会下载真实 AppImage。
set -euo pipefail

cd "$(dirname "$0")"
f=PKGBUILD
repo="https://github.com/ppy/osu.git"

latest="$(git ls-remote --refs --tags "$repo" 2>/dev/null \
    | awk '{print $2}' | sed 's|refs/tags/||; s|\^{}||' \
    | grep -E '[0-9]+\.[0-9]+\.[0-9]+-tachyon' | sort -V | tail -1 || true)"
if [[ -z "$latest" ]]; then
    echo "[update-pkgver] 无法获取 osu tachyon tag" >&2
    exit 1
fi

newver="${latest%-tachyon}"
oldver="$(awk -F= '/^pkgver=/{print $2; exit}' "$f")"
if [[ "$newver" == "$oldver" ]]; then
    echo "[update-pkgver] osu 已最新 ($newver)" >&2
    exit 0
fi

sed -i \
    -e "s|^pkgver=.*|pkgver=${newver}|" \
    -e "s|^_pkgtag=.*|_pkgtag=${newver}-tachyon|" \
    -e "s|^pkgrel=.*|pkgrel=1|" \
    "$f"
echo "[update-pkgver] osu ${oldver} -> ${newver}"
