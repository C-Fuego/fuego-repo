#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/test-upgrade-path.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin" "$tmp/cache/chroot/baseline-test/root/etc" "$tmp/new" "$tmp/old" "$tmp/state"
printf '[options]\nArchitecture = auto\n\n[cachyos-v3]\nServer = https://example.invalid/$repo/os/$arch\n' > "$tmp/cache/chroot/baseline-test/root/etc/pacman.conf"
cp "$tmp/cache/chroot/baseline-test/root/etc/pacman.conf" "$tmp/cache/chroot/pacman-base.conf"
export MOCK_STATE="$tmp/state" MOCK_LOG="$tmp/commands.log"
cat > "$tmp/bin/arch-nspawn" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
# 跳过 arch-nspawn 的选项(-c 带一个值,--bind=x 自带等号)再丢掉 chroot root,
# 让后续 case 看到的第一个参数永远是 pacman 子命令。
while [[ "${1:-}" == -* ]]; do
  if [[ "$1" == -c ]]; then shift; fi
  shift
done
shift # chroot root
printf '%s\n' "$*" >> "$MOCK_LOG"
if [[ "$1" == pacman ]]; then
  shift
  case "${1:-}" in
    -Sl)
      printf '%s\n' 'cachyos-v3 zlib 1:1.3.2-3.1' 'fuego-repo ffmpeg-full 9.0.2-2' ;;
    -S) : ;;
    -Syu)
      target="${*: -1}"
      touch "$MOCK_STATE/$target"
      ;;
    -U) touch "$MOCK_STATE/linuxqq-wayland-fix-git" ;;
    -Qq) ls "$MOCK_STATE" ;;
    -Q)
      package="${2:-}"
      [[ -f "$MOCK_STATE/$package" ]] || exit 1
      printf '%s 1.0-1\n' "$package"
      ;;
  esac
fi
MOCK
cat > "$tmp/bin/repo-add" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
for arg in "$@"; do [[ "$arg" == *.db.tar.gz ]] && : > "$arg" || true; done
MOCK
chmod +x "$tmp/bin/arch-nspawn" "$tmp/bin/repo-add"
make_pkg() {
  local dir="$1" name="$2" version="$3" depends="${4:-}"
  mkdir -p "$tmp/pkgmeta"
  {
    printf 'pkgname = %s\n' "$name"
    printf 'pkgver = %s\n' "$version"
    [[ -z "$depends" ]] || printf 'depend = %s\n' "$depends"
  } > "$tmp/pkgmeta/.PKGINFO"
  bsdtar -cf "$dir/$name-$version-x86_64.pkg.tar.zst" -C "$tmp/pkgmeta" .PKGINFO
}
# Normal upgrade: old private package is installed, then the new repo package is upgraded.
make_pkg "$tmp/old" linuxqq-wayland-fix-git 1.0-1 'glibc>=2.0'
make_pkg "$tmp/new" linuxqq-wayland-fix-git 1.1-1
PACKAGE_NAME=linuxqq-wayland-fix-git PATH="$tmp/bin:$PATH" bash "$script" "$tmp/new" "$tmp/old" "$tmp/cache" > "$tmp/normal.out" || { cat "$tmp/normal.out"; exit 1; }
grep -q 'UPGRADE_PATH=PASS: linuxqq-wayland-fix-git' "$tmp/normal.out"
grep -q 'pacman -U --noconfirm /tmp/old.pkg.tar.zst' "$MOCK_LOG"
# Tag-tracking package: folia lives in the published repository at an older
# upstream tag and is upgraded onto the newer one, same package name.
rm -f "$tmp/new"/*.pkg.tar.zst "$tmp/old"/*.pkg.tar.zst
make_pkg "$tmp/old" folia 0.1.2-1
make_pkg "$tmp/new" folia 0.1.3-1
PACKAGE_NAME=folia PATH="$tmp/bin:$PATH" bash "$script" "$tmp/new" "$tmp/old" "$tmp/cache" > "$tmp/folia.out" || { cat "$tmp/folia.out"; exit 1; }
grep -q 'UPGRADE_PATH=PASS: folia' "$tmp/folia.out"
# Missing prior private artifact is explicitly unverified, never a false pass.
mkdir -p "$tmp/new2" "$tmp/old2"
make_pkg "$tmp/new2" linuxqq-wayland-fix-git 1.2-1
PACKAGE_NAME=linuxqq-wayland-fix-git PATH="$tmp/bin:$PATH" bash "$script" "$tmp/new2" "$tmp/old2" "$tmp/cache" > "$tmp/missing.out" 2>&1
grep -q 'UPGRADE_PATH=UNVERIFIABLE' "$tmp/missing.out"
! grep -q 'UPGRADE_PATH=PASS' "$tmp/missing.out"
# A missing clean-chroot baseline skips loudly instead of failing the build:
# legacy-mode runs have no baseline fixture, and a good package must not be
# blocked by an absent test prerequisite. The old artifact is present, so the
# run reaches the baseline lookup instead of exiting on missing-old.
mkdir -p "$tmp/new3" "$tmp/old3"
make_pkg "$tmp/new3" linuxqq-wayland-fix-git 1.3-1
make_pkg "$tmp/old3" linuxqq-wayland-fix-git 1.0-1
mv "$tmp/cache/chroot/pacman-base.conf" "$tmp/cache/chroot/pacman-base.conf.saved"
PACKAGE_NAME=linuxqq-wayland-fix-git PATH="$tmp/bin:$PATH" bash "$script" "$tmp/new3" "$tmp/old3" "$tmp/cache" > "$tmp/no-baseline.out" 2>&1
rc=$?
mv "$tmp/cache/chroot/pacman-base.conf.saved" "$tmp/cache/chroot/pacman-base.conf"
(( rc == 0 ))
grep -q 'UPGRADE_PATH=UNVERIFIABLE' "$tmp/no-baseline.out"
grep -q '::warning::' "$tmp/no-baseline.out"
! grep -q 'UPGRADE_PATH=PASS' "$tmp/no-baseline.out"
printf 'upgrade path tests passed: normal upgrade (AUR VCS), tag-tracking upgrade (folia), missing-old explicit unverified, missing-baseline loud skip\n'
