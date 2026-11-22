#!/usr/bin/env bash
set -Eeuo pipefail

script_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd -P -- "${REPO_ROOT:-$script_root}" && pwd)"
readonly repo_root
aur_helper="$script_root/scripts/bot/aur.py"

# 退出码：0 = 全部同步成功；3 = 部分包失败已隔离（成功包照常落位待提交，失败
# 清单在 SYNC_FAILURES_FILE）；1 = 全部失败或环境级错误；2 = 用法/配置错误。
# 背景（2026-11-05，runs #103/#104）：scx-scheds-git 一个包的 overlay 落空就
# 让整轮 sync 连红四天，其余包的 AUR 更新被一起扣住——同步的价值在"别的包照
# 常前进"，所以失败按包隔离，环境级故障（全军覆没）才整体失败。
readonly EXIT_PARTIAL=3

# Validate the complete selection before changing any package.
selection="$(python3 "$aur_helper" select "$repo_root" -- "$@")" || exit "$?"
[[ -n "$selection" ]] || { echo 'No AUR-managed packages selected.' >&2; exit 1; }
mapfile -t package_records <<< "$selection"

# Stage on the same filesystem so the final directory exchange is atomic.
temporary_dir="$(mktemp -d "$repo_root/packages/.aur-sync.XXXXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT
mkdir -- "$temporary_dir/packages" "$temporary_dir/scripts"
ln -s -- "$repo_root/scripts/check-package.sh" "$repo_root/scripts/validate-source-cache.sh" "$temporary_dir/scripts/"

failures_file="$temporary_dir/failures.txt"
: > "$failures_file"

# sync_one <name> <url> <old-commit>。调用处把包在子 shell 里跑并按退出码隔
# 离，但注意：bash 在 if/|| 等条件上下文里会压制 set -e（且子 shell 内显式
# set -e 也救不回来，2026-11-05 实测），所以函数内每个易错步骤都必须显式
# `|| return 1`，不能依赖 errexit。
sync_one() {
    local package_name="$1" aur_url="$2" old_commit="$3"
    local package_dir="$repo_root/packages/$package_name"
    local checkout_dir="$temporary_dir/upstream-$package_name"
    timeout 600 git clone --depth 1 -- "$aur_url" "$checkout_dir" || return 1
    local aur_commit
    aur_commit="$(git -C "$checkout_dir" rev-parse HEAD)" || return 1

    # Stage the upstream tree separately. A failed overlay or package audit must
    # never destroy the current working package directory.
    local staged_dir="$temporary_dir/packages/$package_name"
    mkdir -p "$staged_dir" || return 1
    cp -a "$checkout_dir"/. "$staged_dir"/ || return 1
    # Repository-owned metadata cannot be supplied (or symlinked) by upstream.
    rm -rf -- "$staged_dir"/{.git,update.toml,.aur-url,.aur-commit,.build-strategy} || return 1
    if [[ -L "$staged_dir/.SRCINFO" || ( -e "$staged_dir/.SRCINFO" && ! -f "$staged_dir/.SRCINFO" ) ]]; then
        printf '%s: upstream .SRCINFO is not a regular file.\n' "$package_name" >&2
        return 1
    fi
    if [[ ! -f "$staged_dir/PKGBUILD" || -L "$staged_dir/PKGBUILD" ]]; then
        printf '%s: upstream tree has no regular PKGBUILD.\n' "$package_name" >&2
        return 1
    fi

    # Preserve repository-owned files before applying overlays. PKGBUILD must
    # come from AUR and then receive its explicit overlay; .SRCINFO is regenerated
    # from that result. The configured URL is kept and the commit is refreshed.
    # Everything else in the current package tree is local state: local-only
    # files are restored, hidden metadata (.nvchecker.toml, .namcap-ignore,
    # .gitignore) wins on conflict, and any other conflicting file follows AUR
    # with a warning — local changes to AUR-owned files belong in an overlay.
    if [[ -d "$package_dir" ]]; then
        local preserved_manifest="$temporary_dir/preserved-files-$package_name"
        git -C "$repo_root" ls-files --cached --others --exclude-standard -z -- \
            "packages/$package_name" > "$preserved_manifest" || return 1
        local tracked_path local_path relative_path staged_path
        while IFS= read -r -d '' tracked_path; do
            local_path="$repo_root/$tracked_path"
            [[ -e "$local_path" || -L "$local_path" ]] || continue
            relative_path="${tracked_path#"packages/$package_name"/}"
            case "$relative_path" in
                PKGBUILD|.SRCINFO|update.toml|.aur-url|.aur-commit|.build-strategy)
                    continue
                    ;;
            esac
            staged_path="$staged_dir/$relative_path"
            local parent_path resolved_parent
            parent_path="$(dirname -- "$staged_path")" || return 1
            resolved_parent="$(realpath -m -- "$parent_path")" || return 1
            if [[ "$resolved_parent" != "$parent_path" ]]; then
                printf '%s: refusing to copy local file through an upstream symlink: %s\n' \
                    "$package_name" "$relative_path" >&2
                return 1
            fi
            if [[ -d "$local_path" && ! -L "$local_path" ]]; then
                if [[ -L "$staged_path" || ( -e "$staged_path" && ! -d "$staged_path" ) ]]; then
                    printf 'warning: %s: local directory replaces conflicting AUR path %s\n' \
                        "$package_name" "$relative_path" >&2
                    rm -rf -- "$staged_path" || return 1
                fi
                mkdir -p -- "$staged_path" || return 1
                continue
            fi

            mkdir -p -- "$parent_path" || return 1
            if [[ -e "$staged_path" || -L "$staged_path" ]]; then
                # 同名冲突分两类:隐藏文件是仓库自己的元数据,保留本地版本;
                # 包内容的普通文件以 AUR 为准,本地改动必须写进
                # scripts/overlays/<包名>.sh。旧策略「本地一律优先」会让
                # AUR 更新过的源文件永远停在旧内容,而 PKGBUILD 的
                # sha256sums 已随 AUR 前进,同步就卡在校验和上永远修不好
                # (svt-jpeg-xs-git 的补丁,2026-11-02)。
                if [[ "$(basename -- "$relative_path")" != .* ]]; then
                    # 内容相同就静默沿用 AUR 那份,只有真的改过才提示。
                    if [[ -f "$local_path" && -f "$staged_path" ]] \
                        && cmp -s -- "$local_path" "$staged_path"; then
                        continue
                    fi
                    if [[ -L "$local_path" && -L "$staged_path" ]] \
                        && [[ "$(readlink "$local_path")" == "$(readlink "$staged_path")" ]]; then
                        continue
                    fi
                    printf 'warning: %s: AUR version replaces locally modified %s (move local changes into scripts/overlays/%s.sh)\n' \
                        "$package_name" "$relative_path" "$package_name" >&2
                    continue
                fi
                if [[ -L "$local_path" && -L "$staged_path" ]]; then
                    if [[ "$(readlink "$local_path")" != "$(readlink "$staged_path")" ]]; then
                        printf 'warning: %s: keeping local version of conflicting file %s\n' \
                            "$package_name" "$relative_path" >&2
                    fi
                elif [[ -f "$local_path" && -f "$staged_path" ]]; then
                    if ! cmp -s -- "$local_path" "$staged_path"; then
                        printf 'warning: %s: keeping local version of conflicting file %s\n' \
                            "$package_name" "$relative_path" >&2
                    fi
                else
                    printf 'warning: %s: keeping local version of conflicting path %s\n' \
                        "$package_name" "$relative_path" >&2
                fi
            fi
            rm -rf -- "$staged_path" || return 1
            cp -a -- "$local_path" "$staged_path" || return 1
        done < "$preserved_manifest"
    fi

    python3 "$aur_helper" refresh "$package_dir/update.toml" "$staged_dir/update.toml" "$aur_commit" || return 1

    local overlay="$repo_root/scripts/overlays/$package_name.sh"
    if [[ -f "$overlay" ]]; then
        printf 'Applying local overlay for %s...\n' "$package_name"
        bash "$overlay" "$staged_dir" || return 1
    fi
    if [[ ! -f "$staged_dir/PKGBUILD" || -L "$staged_dir/PKGBUILD" ]]; then
        printf '%s: overlay left no regular PKGBUILD.\n' "$package_name" >&2
        return 1
    fi
    # 同步不得把 pkgrel 拉回上游基线：本地用 .N 子版本号记录自己的重建次数，
    # 而仓库里的版本号只允许前进（pacman 只看版本号，repo-add 还会照单覆盖，
    # 于是发布版本一旦倒退，装了高版本的机器就再也收不到更新）。overlay 之外
    # 的包也要覆盖，所以这一步放在 overlay 之后、.SRCINFO 生成之前。
    if [[ -f "$package_dir/PKGBUILD" ]]; then
        bash "$repo_root/scripts/pkgrel-floor.sh" \
            "$staged_dir" --against-pkgbuild "$package_dir/PKGBUILD" || return 1
    fi
    if ! (cd "$staged_dir" && BUILDDIR="$temporary_dir/build" SRCDEST="$temporary_dir/src" \
        PKGDEST="$temporary_dir/pkg" LOGDEST="$temporary_dir/log" makepkg --printsrcinfo > .SRCINFO); then
        printf '%s: failed to generate .SRCINFO after overlay.\n' "$package_name" >&2
        return 1
    fi
    if ! bash -n "$staged_dir/PKGBUILD"; then
        printf '%s: PKGBUILD syntax check failed after overlay.\n' "$package_name" >&2
        return 1
    fi
    local check_log="$temporary_dir/check-$package_name.log"
    if ! bash "$temporary_dir/scripts/check-package.sh" "$package_name" > "$check_log" 2>&1; then
        tail -5 "$check_log" >&2 || true
        printf 'check-package: %s\n' "$(tail -1 "$check_log" | cut -c1-180)" >&2
        return 1
    fi
    python3 "$aur_helper" publish "$staged_dir" "$package_dir" || return 1
    if [[ "$old_commit" == "$aur_commit" ]]; then
        printf '%s: AUR commit unchanged; checking overlay state only.\n' "$package_name"
    else
        printf '%s: AUR updated %s -> %s.\n' "$package_name" "$old_commit" "$aur_commit"
    fi
}

for record in "${package_records[@]}"; do
    IFS=$'\t' read -r package_name aur_url old_commit <<< "$record"
    package_log="$temporary_dir/sync-$package_name.log"
    if ( sync_one "$package_name" "$aur_url" "$old_commit" ) > "$package_log" 2>&1; then
        grep -E '^(warning: |Applying local overlay for )' "$package_log" >&2 || true
        grep -E 'AUR (updated|commit unchanged)' "$package_log" || true
    else
        rc=$?
        printf 'sync failed for %s (exit %d); last output:\n' "$package_name" "$rc" >&2
        tail -5 "$package_log" >&2 || true
        printf '%s\t%s\n' "$package_name" \
            "$(tail -1 "$package_log" | cut -c1-200)" >> "$failures_file"
    fi
done

total=${#package_records[@]}
failed_count="$(wc -l < "$failures_file" | tr -d '[:space:]')"

if (( failed_count == 0 )); then
    printf 'AUR synchronization completed transactionally for %d package(s).\n' "$total"
    exit 0
fi

printf '\n=== AUR sync failures (%d of %d packages) ===\n' "$failed_count" "$total" >&2
while IFS=$'\t' read -r pkg reason; do
    printf '  FAILED %s: %s\n' "$pkg" "$reason" >&2
done < "$failures_file"

if [[ -n "${SYNC_FAILURES_FILE:-}" ]]; then
    cp -- "$failures_file" "$SYNC_FAILURES_FILE"
fi

if (( failed_count == total )); then
    echo 'Every selected package failed; treating this as an environment failure.' >&2
    exit 1
fi
exit "$EXIT_PARTIAL"
