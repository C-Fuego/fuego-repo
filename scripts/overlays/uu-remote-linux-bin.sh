#!/usr/bin/env bash
# Support releases where upstream moved its desktop assets out of contrib/.
set -euo pipefail

pkgbuild="${1:?usage: uu-remote-linux-bin.sh <package-dir>}/PKGBUILD"
python3 - "$pkgbuild" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
assets = '  install -Dm644 contrib/desktop/'
marker = '# emoeem overlay: support the new upstream desktop asset directory'
count = text.count(assets)
if marker not in text and count:
    if count != 3:
        raise SystemExit('expected three legacy desktop asset install commands')
    text = text.replace(assets, '  install -Dm644 "${_desktop_dir}"/', 3)
    first = '  install -Dm644 "${_desktop_dir}"/'
    text = text.replace(first, f'''  {marker}
  local _desktop_dir=packaging/common/desktop
  [[ -d "${{_desktop_dir}}" ]] || _desktop_dir=contrib/desktop
{first}''', 1)

# The shipped portal plugin links these libraries directly.
portal_optdepends = (
    "  'libei: GNOME/KDE Wayland portal backend'\n"
    "  'libpipewire: GNOME/KDE Wayland portal backend'\n"
)
if portal_optdepends in text:
    boundary = ')\noptdepends=(\n'
    if text.count(boundary) != 1:
        raise SystemExit('expected one boundary between depends and optdepends')
    text = text.replace(portal_optdepends, '', 1)
    text = text.replace(boundary, "  # emoeem overlay: link dependencies of the shipped portal plugin\n"
                        "  'libei'\n  'libpipewire'\n" + boundary, 1)

if text != path.read_text():
    path.write_text(text)
PY
