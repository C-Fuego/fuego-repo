#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/ffmpeg"
cp "$root/packages/ffmpeg-full/PKGBUILD" "$root/packages/ffmpeg-full/.SRCINFO" \
    "$root/packages/ffmpeg-full/.lensfun-pin" "$root/packages/ffmpeg-full"/0*.patch "$tmp/ffmpeg/"
bash "$root/scripts/overlays/ffmpeg-full.sh" "$tmp/ffmpeg" >/dev/null
bash -n "$tmp/ffmpeg/PKGBUILD"
# Extract and exercise the actual generated guard against a small patch.
awk '/^    if ! patch .*080-ffmpeg-openapv/ { inside=1 }
     inside { print }
     inside && /^    fi$/ { exit }' "$tmp/ffmpeg/PKGBUILD" > "$tmp/guard.sh"
[[ -s "$tmp/guard.sh" ]]
mkdir -p "$tmp/ffmpeg-fixture" "$tmp/patches"
fixture="$tmp/ffmpeg-fixture/example.c"
printf 'before\n' > "$fixture"
printf '%s\n' '--- a/example.c' '+++ b/example.c' '@@ -1 +1 @@' '-before' '+after' \
    > "$tmp/patches/080-ffmpeg-openapv1.1-fix.patch"
run_guard() {
    (cd "$tmp" && pkgver=fixture srcdir="$tmp/patches" bash -e "$tmp/guard.sh")
}
run_guard
grep -qx after "$fixture"
run_guard
grep -qx after "$fixture"
printf 'unrelated\n' > "$fixture"
if run_guard; then
    printf 'guard accepted an incompatible patch\n' >&2
    exit 1
fi
grep -qx unrelated "$fixture"
# AUR stages the nested header under srcdir, but configure runs in ffmpeg-*.
# Reapply the overlay as if the incoming recipe did not carry our include flag.
sed -i '/export CFLAGS.*-I${srcdir}\/include/d' "$tmp/ffmpeg/PKGBUILD"
bash "$root/scripts/overlays/ffmpeg-full.sh" "$tmp/ffmpeg" >/dev/null
grep -Fxq '    export CFLAGS+=" -I${srcdir}/include"' "$tmp/ffmpeg/PKGBUILD"
grep -Fxq '    ln -sf /usr/include/astcenc.h include/astcenc/astcenc.h' "$tmp/ffmpeg/PKGBUILD"
first="$(sha256sum "$tmp/ffmpeg/PKGBUILD" | cut -d' ' -f1)"
bash "$root/scripts/overlays/ffmpeg-full.sh" "$tmp/ffmpeg" >/dev/null
[[ "$(sha256sum "$tmp/ffmpeg/PKGBUILD" | cut -d' ' -f1)" == "$first" ]]
printf 'ok: ffmpeg overlay guards an already-applied backport and stays idempotent\n'

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
