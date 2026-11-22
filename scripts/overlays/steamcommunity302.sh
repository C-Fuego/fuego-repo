#!/usr/bin/env bash
# makepkg can link an AppImage from a source cache owned by another user.
set -euo pipefail

pkgbuild="${1:?usage: steamcommunity302.sh <package-dir>}/PKGBUILD"
python3 - "$pkgbuild" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = '''  chmod 755 "${_appimage}"
  (
    cd "${srcdir}"
    "${_appimage}" --appimage-extract
  )'''
new = '''  # emoeem overlay: extract from a writable copy of the cached AppImage
  local _extractor="${srcdir}/steamcommunity302-extract.AppImage"
  install -m755 "${_appimage}" "${_extractor}"
  (
    cd "${srcdir}"
    "${_extractor}" --appimage-extract
  )'''
count = text.count(old)
if count > 1:
    raise SystemExit('expected a single AppImage extraction block')
if count == 1:
    path.write_text(text.replace(old, new, 1))
PY
