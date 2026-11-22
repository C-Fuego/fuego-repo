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
    path.write_text(text)
PY
