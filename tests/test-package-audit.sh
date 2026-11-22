#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Keep the production audit testable in a tiny fixture. The fixture provides
# makepkg-readable PKGBUILDs and checks duplicate providers/self dependencies.
mkdir -p "$work/packages/demo-a" "$work/packages/demo-b"

cat > "$work/packages/demo-a/PKGBUILD" <<'EOF'
pkgname=demo-a
pkgver=1
pkgrel=1
arch=(x86_64)
provides=(demo-virtual)
EOF

cat > "$work/packages/demo-b/PKGBUILD" <<'EOF'
pkgname=demo-b
pkgver=1
pkgrel=1
arch=(x86_64)
depends=(demo-virtual)
EOF

if ! command -v makepkg >/dev/null 2>&1; then
    echo 'makepkg is required for package audit tests.' >&2
    exit 2
fi
(cd "$work/packages/demo-a" && makepkg --printsrcinfo > .SRCINFO)
(cd "$work/packages/demo-b" && makepkg --printsrcinfo > .SRCINFO)

bash -n "$root/scripts/audit-packages.sh"
bash -n "$root/tests/test-package-audit.sh"
cat > "$work/packages/demo-a/update.toml" <<'EOF'
track = "aur"
strategy = "source"
url = "https://aur.archlinux.org/demo-a.git"
commit = "0123456789abcdef0123456789abcdef01234567"
EOF
printf '%s\n' 'https://aur.archlinux.org/demo-b.git' > "$work/packages/demo-b/.aur-url"
printf '%s\n' '0123456789abcdef0123456789abcdef01234567' > "$work/packages/demo-b/.aur-commit"
AUDIT_ROOT="$work" "$root/scripts/audit-packages.sh" >/dev/null

# A malformed top-level pin must not be hidden by valid legacy metadata.
cp "$work/packages/demo-b/.aur-url" "$work/packages/demo-a/.aur-url"
cp "$work/packages/demo-b/.aur-commit" "$work/packages/demo-a/.aur-commit"
sed -i '/^commit = /s/".*"/"short"/' "$work/packages/demo-a/update.toml"
if AUDIT_ROOT="$work" "$root/scripts/audit-packages.sh" > "$work/log" 2>&1; then
    echo 'invalid TOML commit was not rejected' >&2
    exit 1
fi
grep -q 'demo-a: update.toml: commit must be a 40-character hexadecimal Git commit' "$work/log"
sed -i '/^commit = /s/".*"/"0123456789abcdef0123456789abcdef01234567"/' "$work/packages/demo-a/update.toml"

# A duplicate virtual provider must be rejected.
sed -i 's/pkgname=demo-b/pkgname=demo-b\nprovides=(demo-virtual)/' "$work/packages/demo-b/PKGBUILD"
(cd "$work/packages/demo-b" && makepkg --printsrcinfo > .SRCINFO)
if AUDIT_ROOT="$work" "$root/scripts/audit-packages.sh" >/dev/null 2>&1; then
    echo 'duplicate provider was not rejected' >&2
    exit 1
fi

printf 'package audit regression tests passed\n'
