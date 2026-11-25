#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/fcitx5-wetypex"
cp "$root/packages/fcitx5-wetypex"/{PKGBUILD,.SRCINFO,update.toml,fcitx5-wetypex.install} "$tmp/fcitx5-wetypex/"
recipe="$tmp/fcitx5-wetypex/PKGBUILD"
revision=$(awk -F= '/^_source_revision=[0-9]+$/ { print $2 }' "$recipe")
[[ -n "$revision" ]]
# Recreate a fresh AUR recipe, then apply the real ABI bump entry point.
sed -i -e '/^# emoeem overlay: keep the upstream asset revision/d' \
    -e "s/^pkgrel=.*/pkgrel=$revision/" \
    -e 's/^_source_revision=.*/_source_revision=${pkgrel%%.*}/' "$recipe"
bash "$root/scripts/overlays/fcitx5-wetypex.sh" "$tmp/fcitx5-wetypex"
grep -qxF "_source_revision=$revision" "$recipe"
BUMP_PKGREL=true bash "$root/scripts/prepare-build-source.sh" "$tmp/fcitx5-wetypex"
grep -qxF "pkgrel=$((revision + 1))" "$recipe"
bash "$root/scripts/overlays/fcitx5-wetypex.sh" "$tmp/fcitx5-wetypex"
grep -qxF "_source_revision=$revision" "$recipe"
if command -v makepkg >/dev/null && (( EUID != 0 )); then
    (cd "$tmp/fcitx5-wetypex" && makepkg --printsrcinfo > generated)
    diff -u "$tmp/fcitx5-wetypex/.SRCINFO" "$tmp/fcitx5-wetypex/generated"
fi
printf 'ok: fcitx5-wetypex pkgrel bumps do not change upstream source revision\n'
