#!/usr/bin/env bash
set -Eeuo pipefail

python3 - "${1:?package directory required}/PKGBUILD" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = '# emoeem overlay: keep the upstream asset revision independent of local pkgrel bumps.\n'
if marker in text:
    if len(re.findall(r'^_source_revision=[0-9]+$', text, re.M)) != 1:
        raise SystemExit('fcitx5-wetypex: malformed overlaid source revision')
    sys.exit(0)
revisions = re.findall(r'^pkgrel=([0-9]+)(?:\.[0-9]+)?$', text, re.M)
anchor = '_source_revision=${pkgrel%%.*}\n'
if len(revisions) != 1:
    raise SystemExit('fcitx5-wetypex: cannot read the upstream pkgrel')
if text.splitlines(keepends=True).count(anchor) != 1:
    # A newer upstream may have removed the coupling itself. Only accept a
    # simple literal revision; if the recipe structure changes, review it.
    if len(re.findall(r'^_source_revision=[0-9]+$', text, re.M)) == 1:
        sys.exit(0)
    raise SystemExit('fcitx5-wetypex: upstream source revision layout changed; review overlay')
path.write_text(text.replace(anchor, marker + f'_source_revision={revisions[0]}\n', 1))
PY
