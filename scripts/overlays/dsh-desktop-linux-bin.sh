#!/usr/bin/env bash
set -Eeuo pipefail

python3 - "${1:?package directory required}/PKGBUILD" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
anchor = "conflicts=('deepseek-harness-desktop')"
block = """# emoeem overlay: migrate installations of the former Fuego package.
conflicts=('deepseek-harness-desktop' 'dsh-desktop-linux')
provides=("dsh-desktop-linux=$pkgver")
replaces=('dsh-desktop-linux')"""
lines = text.splitlines()
if block in text:
    sys.exit(0)
if lines.count(anchor) != 1 or any(line.startswith(('provides=', 'replaces=')) for line in lines):
    sys.exit('DSH AUR metadata changed; review the package migration overlay.')
path.write_text(text.replace(anchor + '\n', block + '\n', 1))
PY
