#!/usr/bin/env bash
# check-upstream.sh — 全自动轮询上游变动, 输出需重建包清单
#
# 包类型:
#   git-head  跟踪上游最新 commit        → 变则重建
#   git-tag   跟踪上游最新发布 tag        → 新版本 auto-bump pkgver + 重建
#   always    release/appimage/静态包     → 每次 cron 都重建 (makepkg 内部更新版本)
#   fixed     固定源码, 手动              → 不轮询
#
# 变更记录 .upstream/<pkg>.commit, 重建清单 .needs-build
# 退出码: 0=有包要重建; 2=无变动
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
TRACK_DIR="${ROOT}/.upstream"
NEEDS_BUILD="${ROOT}/.needs-build"

# 包配置: <pkg>:<type>:<upstream-repo|->  (always/fixed 的上游用 -)
PKGS=(
    #  原 repo 6 包
    "enable-3fg-drag:fixed:-"
    "grub-btrfs:git-tag:https://github.com/Antynea/grub-btrfs.git"
    "librime:git-tag:https://github.com/rime/librime.git"
    "linuxqq-clipsync:git-head:https://github.com/SHORiN-KiWATA/linuxqq-clipsync.git"
    "mbpfan:git-tag:https://github.com/linux-on-mac/mbpfan.git"
    "we-layerd-patched-git:git-head:https://github.com/Aromatic05/we-layerd.git"
    #  新增 AUR 包
    "krabby-git:git-head:https://github.com/yannjor/krabby.git"
    "pipes-rs-git:git-head:https://github.com/lhvy/pipes-rs.git"
    "clock-rs-git:git-head:https://github.com/Oughie/clock-rs.git"
    "cnmplayer-git:git-head:https://github.com/professor-lee/CNMPlayer.git"
    "rime-frost-git:git-head:https://github.com/gaboolic/rime-frost.git"
    "shorin-contrib-git:git-head:https://github.com/SHORiN-KiWATA/shorin-contrib.git"
    "niri-shorin-fork-git:git-head:https://github.com/SHORiN-KiWATA/niri.git"
    "xclip-git:git-head:https://github.com/astrand/xclip.git"
    "linuxqq-appimage:always:-"
    "wechat-appimage:always:-"
    "osu-lazer-tachyon-bin:always:-"
    "osu-mime:fixed:-"
    "ttf-jetbrains-maple-mono-xx-xx-xx:always:-"
)

log()  { printf '\033[1;36m[ check-upstream ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

mkdir -p "$TRACK_DIR"
: > "$NEEDS_BUILD"

pkg_current_ver() {
    awk -F= '/^pkgver=/{print $2; exit}' "pkgbuilds/$1/PKGBUILD"
}
latest_tag_ver() {
    local repo="$1"
    git ls-remote --refs --tags "$repo" 2>/dev/null \
        | awk '{print $2}' | sed 's|refs/tags/||; s|\^{}||' \
        | grep -E '^v?[0-9]+(\.[0-9]+)*$' | sed 's/^v//' | sort -V | tail -1
}
bump_pkgver() {
    local pkg="$1" newver="$2" curver
    curver="$(pkg_current_ver "$pkg")"
    [[ "$newver" == "$curver" ]] && return 1
    sed -i "s/^pkgver=${curver}/pkgver=${newver}/" "pkgbuilds/${pkg}/PKGBUILD"
    [[ "$pkg" == "librime" ]] && sed -i 's/^pkgrel=.*/pkgrel=1/' "pkgbuilds/${pkg}/PKGBUILD"
    log "${pkg}: pkgver ${curver} -> ${newver}"
    return 0
}

rebuilt=0
for line in "${PKGS[@]}"; do
    pkg="${line%%:*}"
    rest="${line#*:}"
    type="${rest%%:*}"
    repo="${rest#*:}"

    [[ -d "pkgbuilds/${pkg}" ]] || { warn "跳过 ${pkg}: 无 pkgbuilds"; continue; }

    case "$type" in
        fixed)
            log "${pkg}: 固定源码 (manual)" ;;
        git-head)
            up="$(git ls-remote "$repo" HEAD 2>/dev/null | awk '{print $1}')"
            [[ -z "$up" ]] && { warn "${pkg}: 无法获取上游"; continue; }
            rec="${TRACK_DIR}/${pkg}.commit"; last=""; [[ -f "$rec" ]] && last="$(cat "$rec")"
            if [[ "$last" != "$up" ]]; then
                echo "$up" > "$rec"; echo "$pkg" >> "$NEEDS_BUILD"; rebuilt=$((rebuilt+1))
                log "${pkg}: HEAD 变动 $(printf '%.8s' "$last") -> $(printf '%.8s' "$up")"
            else
                log "${pkg}: 无变动 (HEAD)"
            fi ;;
        git-tag)
            latest="$(latest_tag_ver "$repo")"; cur="$(pkg_current_ver "$pkg")"
            [[ -z "$latest" ]] && { warn "${pkg}: 无法获取 tag"; continue; }
            if bump_pkgver "$pkg" "$latest"; then
                echo "$pkg" >> "$NEEDS_BUILD"; rebuilt=$((rebuilt+1))
            else
                log "${pkg}: 已最新 ($cur)"
            fi ;;
        always)
            echo "$pkg" >> "$NEEDS_BUILD"; rebuilt=$((rebuilt+1))
            log "${pkg}: 每次 cron 重建 (release/appimage)" ;;
        *) warn "${pkg}: 未知类型 $type" ;;
    esac
done

if [[ "$rebuilt" -gt 0 ]]; then
    log "${rebuilt} 个包需重建: $(tr '\n' ' ' < "$NEEDS_BUILD")"
    exit 0
else
    log "所有包均无变动"
    exit 2
fi
