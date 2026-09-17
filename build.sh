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
          osu-mime osu-lazer-tachyon-bin pipes-rs-git rime-frost-git
          shorin-contrib-git ttf-jetbrains-maple-mono-xx-xx-xx wechat-appimage
          we-layerd-patched-git xclip-git)
# 注意顺序: 有依赖关系的排前面 (osu-mime 在 osu-lazer-tachyon-bin 之前)

# 这些包的 depends 里有本仓库自己的包, 而构建容器里没配本仓库源, makepkg 会以
# "target not found" 失败。用 --nodeps 跳过构建期依赖检查（运行时依赖由用户侧 pacman 解析）。
NODEPS_PKGS=(osu-lazer-tachyon-bin)

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
        elif [[ " ${NODEPS_PKGS[*]} " =~ " ${pkg} " ]]; then
            makepkg -sf --noconfirm --nodeps
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

    # 收集该包的所有 .zst (旧版本在下面 prune_old_versions 里清理)
    for zst in "$dir"/*.pkg.tar.zst; do
        [[ -f "$zst" ]] || continue
        cp -f "$zst" "$REPO_DIR/"
    done
    log "${pkg} 完成"
done

# ── 更新仓库数据库 ──
# 注意: 不要用 `repo-add --new`。--new 只添加"库里还没有"的包,
# 于是同版本重打后 db 里的 CSIZE 仍是旧值, pacman 会以
# "Maximum file size exceeded" 拒绝下载（实测踩过）。正确做法是先清掉旧版本文件, 再普通 repo-add。
prune_old_versions() {
    local zst name ver
    local -A keep_file=() keep_ver=()
    _pkginfo() { bsdtar -xOf "$1" .PKGINFO 2>/dev/null; }
    for zst in "$REPO_DIR"/*.pkg.tar.zst; do
        [[ -f "$zst" ]] || continue
        read -r name ver < <(_pkginfo "$zst" | awk -F' = ' '
            /^pkgname/{n=$2} /^pkgver/{v=$2} END{print n, v}')
        [[ -n "${name:-}" && -n "${ver:-}" ]] || { warn "读不出包信息, 跳过: $(basename "$zst")"; continue; }
        if [[ -z "${keep_file[$name]:-}" ]]; then
            keep_file[$name]="$zst"; keep_ver[$name]="$ver"
        else
            # 版本更高的留下; 同版本保留文件更新的那个
            if (( $(vercmp "$ver" "${keep_ver[$name]}") > 0 )) ||
               { (( $(vercmp "$ver" "${keep_ver[$name]}") == 0 )) && [[ "$zst" -nt "${keep_file[$name]}" ]]; }; then
                keep_file[$name]="$zst"; keep_ver[$name]="$ver"
            fi
        fi
    done
    for zst in "$REPO_DIR"/*.pkg.tar.zst; do
        [[ -f "$zst" ]] || continue
        read -r name ver < <(_pkginfo "$zst" | awk -F' = ' '
            /^pkgname/{n=$2} /^pkgver/{v=$2} END{print n, v}')
        [[ -n "${name:-}" ]] || continue
        if [[ "${keep_file[$name]}" != "$zst" ]]; then
            warn "清理旧版本: $(basename "$zst")"
            rm -f "$zst"
        fi
    done
}

log "更新仓库数据库 (fuego-repo)..."
cd "$REPO_DIR"
[[ -f fuego-repo.db.tar.gz ]] || warn "首次建库"
prune_old_versions
shopt -s nullglob
_zsts=( *.pkg.tar.zst )
shopt -u nullglob
if (( ${#_zsts[@]} == 0 )); then
    warn "没有 .zst 产物, 跳过建库"
else
    repo-add fuego-repo.db.tar.gz "${_zsts[@]}"
fi

log "构建完成。产物:"
ls -lh "$REPO_DIR"/*.pkg.tar.zst 2>/dev/null | awk '{print "  "$5"  "$9}'
echo ""
log "仓库包数: $(ls "$REPO_DIR"/*.pkg.tar.zst 2>/dev/null | wc -l)"
