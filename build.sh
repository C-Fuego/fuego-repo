#!/usr/bin/env bash
# build.sh — 构建选定/全部包并更新仓库数据库 (供 GitHub Actions 调用)
#
# 用法:
#   build.sh                从 .needs-build 读取需要重建的包 (cron 增量)
#   build.sh --all          构建全部受支持包 (workflow_dispatch / push)
#   build.sh pkg1 [pkg2..]  构建指定包
#
# 产物写入 packages/fuego-repo/x86_64/, 用 repo-add 更新 fuego-repo.db
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
REPO_DIR="${ROOT}/packages/fuego-repo/x86_64"
NEEDS_BUILD="${ROOT}/.needs-build"

ALL_PKGS=(enable-3fg-drag grub-btrfs krabby-git clock-rs-git cnmplayer-git
          librime linuxqq-appimage linuxqq-clipsync mbpfan niri-shorin-fork-git
          osu-lazer-tachyon-bin osu-mime pipes-rs-git rime-frost-git
          shorin-contrib-git ttf-jetbrains-maple-mono-xx-xx-xx wechat-appimage
          we-layerd-patched-git xclip-git)

# 需要 "先更新 PKGBUILD 到上游最新" 再构建的 always 类包
#   osu / 字体: 自带轻量 update-pkgver.sh (git ls-remote, sha256=SKIP)
#   wechat: 自带 update 脚本 (HEAD 探测 + extract 取版本 + updpkgsums)
#   linuxqq: 自带 update.sh (需 node get_latest + download.sh)
UPD_PKGS=(linuxqq-appimage wechat-appimage osu-lazer-tachyon-bin ttf-jetbrains-maple-mono-xx-xx-xx)

# 构建前更新 PKGBUILD 到上游最新版本 (仅用于 always 类)
update_pkg() {
    local pkg="$1" upd="${ROOT}/pkgbuilds/${pkg}/update-pkgver.sh"
    if [[ -x "$upd" ]]; then
        "${upd}" || { warn "${pkg}: 版本检测/更新失败, 跳过"; return 1; }
    elif [[ "$pkg" == "wechat-appimage" ]]; then
        ( cd "${ROOT}/pkgbuilds/${pkg}" && ./update ) || { warn "${pkg}: 自带 update 脚本失败, 跳过"; return 1; }
    elif [[ "$pkg" == "linuxqq-appimage" ]]; then
        ( cd "${ROOT}/pkgbuilds/${pkg}" && ./update.sh ) || { warn "${pkg}: 自带 update.sh 失败, 跳过"; return 1; }
    fi
}

log()  { printf '\033[1;36m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

mkdir -p "$REPO_DIR"

# ── 确定要构建的包 ──
build_pkgs=()
mode="${1:-auto}"
case "$mode" in
    --all)
        build_pkgs=("${ALL_PKGS[@]}") ;;
    auto)
        if [[ -f "$NEEDS_BUILD" ]] && [[ -s "$NEEDS_BUILD" ]]; then
            mapfile -t build_pkgs < "$NEEDS_BUILD"
        else
            warn "没有 .needs-build 记录, 无包需构建"
            exit 0
        fi ;;
    *)
        build_pkgs=("$@") ;;
esac

if [[ ${#build_pkgs[@]} -eq 0 ]]; then
    log "没有需要构建的包"
    exit 0
fi
log "待构建: ${build_pkgs[*]}"

# ── 构建每个包 ──
for pkg in "${build_pkgs[@]}"; do
    dir="${ROOT}/pkgbuilds/${pkg}"
    [[ -d "$dir" ]] || { warn "跳过 ${pkg}: 目录不存在"; continue; }

    log "构建 ${pkg}..."
    if ! (
        cd "$dir"
        if [[ " ${UPD_PKGS[*]} " =~ " ${pkg} " ]]; then
            log "[${pkg}] 先更新到上游最新版本..."
            update_pkg "$pkg" || exit 1
        fi
        # linuxqq-clipsync: 绕过 gitconfig 里失效的代理 insteadOf 规则
        if [[ "$pkg" == "linuxqq-clipsync" ]]; then
            GIT_CONFIG_GLOBAL=/dev/null makepkg -sf --noconfirm
        else
            makepkg -sf --noconfirm
        fi
    ); then
        warn "${pkg} 构建失败 (可能补丁与新版上游冲突)"
        # 回滚该包 PKGBUILD 的 auto-bump (若有), 避免 pkgver 停在打不上的版本
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            git checkout -- "pkgbuilds/${pkg}/PKGBUILD" 2>/dev/null && warn "  已回滚 ${pkg}/PKGBUILD 的 auto-bump" || true
        fi
        continue
    fi

    # 收集该包的所有 .zst (repo-add --new 会去重旧版本)
    for zst in "$dir"/*.pkg.tar.zst; do
        [[ -f "$zst" ]] || continue
        cp -f "$zst" "$REPO_DIR/"
    done
    log "${pkg} 完成"
done

# ── 更新仓库数据库 ──
log "更新仓库数据库 (fuego-repo)..."
cd "$REPO_DIR"
repo-add --new fuego-repo.db.tar.gz *.pkg.tar.zst

log "构建完成。产物:"
ls -lh "$REPO_DIR"/*.pkg.tar.zst 2>/dev/null | awk '{print "  "$5"  "$9}'
echo ""
log "仓库包数: $(ls "$REPO_DIR"/*.pkg.tar.zst 2>/dev/null | wc -l)"
