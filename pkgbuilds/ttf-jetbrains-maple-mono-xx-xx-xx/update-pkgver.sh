#!/usr/bin/env bash
# update-pkgver.sh — 检测 Fusion-JetBrainsMapleMono 最新 release tag 并更新本 PKGBUILD (轻量, 不下载)
# 由 check-upstream.sh 的 always 分支调用。sha256 已设 SKIP, makepkg 构建时会下载真实字体包。
set -euo pipefail

cd "$(dirname "$0")"
f=PKGBUILD
repo="https://github.com/SpaceTimee/Fusion-JetBrainsMapleMono.git"

latest="$(git ls-remote --refs --tags "$repo" 2>/dev/null \
    | awk '{print $2}' | sed 's|refs/tags/||; s|\^{}||' \
    | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -V | tail -1 || true)"
if [[ -z "$latest" ]]; then
    echo "[update-pkgver] 无法获取字体 release tag" >&2
    exit 1
fi

oldver="$(awk -F= '/^pkgver=/{print $2; exit}' "$f")"
if [[ "$latest" == "$oldver" ]]; then
    echo "[update-pkgver] 字体已最新 ($latest)" >&2
    exit 0
fi

sed -i \
    -e "s|^pkgver=.*|pkgver=${latest}|" \
    -e "s|^pkgrel=.*|pkgrel=1|" \
    -e "s|JetBrainsMapleMono-XX-XX-XX-\${pkgver}.zip::https://github.com/SpaceTimee/Fusion-JetBrainsMapleMono/releases/download/\${pkgver}/JetBrainsMapleMono-XX-XX-XX.zip|JetBrainsMapleMono-XX-XX-XX-${latest}.zip::https://github.com/SpaceTimee/Fusion-JetBrainsMapleMono/releases/download/${latest}/JetBrainsMapleMono-XX-XX-XX.zip|" \
    "$f"
echo "[update-pkgver] 字体 ${oldver} -> ${latest}"
