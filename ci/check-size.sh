#!/usr/bin/env bash
# ci/check-size.sh — 推送前的体积守门
#
# 用法: git add -A -- packages/ pkgbuilds/ && bash ci/check-size.sh
#
# 背景: GitHub 对**单个文件**的硬上限是 100MiB（服务端强制），超限对象会被直接拒收，
# 客户端只看到 `error: RPC failed; HTTP 500 / fatal: the remote end hung up unexpectedly`，
# 排查起来很绕。所以这里在 commit 之前就拦住。
#   50MiB 以上 → 警告（GitHub 也会提醒）
#   100MiB 以上 → 报错退出，禁止提交
# Codeberg 侧没有单文件硬限，但有仓库配额（750MiB/用户），所以同样不该出现大文件。
set -euo pipefail

LIMIT_HARD=$((100 * 1024 * 1024))
LIMIT_WARN=$((50 * 1024 * 1024))

mapfile -t staged < <(git diff --cached --name-only --diff-filter=ACM)
big=(); warn=(); total=0

for f in "${staged[@]:-}"; do
    [[ -n "$f" && -f "$f" ]] || continue
    s=$(stat -c%s -- "$f")
    total=$((total + s))
    if (( s > LIMIT_HARD )); then
        big+=("$(numfmt --to=iec "$s")  $f")
    elif (( s > LIMIT_WARN )); then
        warn+=("$(numfmt --to=iec "$s")  $f")
    fi
done

if (( ${#warn[@]} > 0 )); then
    echo "::warning::以下暂存文件超过 50MiB："
    printf '  %s\n' "${warn[@]}"
fi

if (( ${#big[@]} > 0 )); then
    echo "::error::以下文件超过 GitHub 单文件 100MiB 硬上限，提交会被服务端拒绝："
    printf '  %s\n' "${big[@]}"
    echo "处理办法：把载荷（AppImage / 字体 zip / 大 .zst）改成运行时下载，别塞进 git。见 README「大包瘦身」。"
    exit 1
fi

printf '体积守门通过: 暂存 %d 个文件, 合计 %s\n' "${#staged[@]}" "$(numfmt --to=iec "$total")"

# ── 产物误忽略检查 ──
# 踩过的坑: .gitignore 里写了全局 *.pkg.tar.zst, 于是 packages/ 下要发布的产物被静默忽略,
# 提交里只剩 db, 看起来"推送成功"其实什么都没发布。这里主动发现。
missing=0
if [[ -d packages ]]; then
    while IFS= read -r -d '' z; do
        if git check-ignore -q -- "$z"; then
            echo "::error::$z 被 .gitignore 忽略, 不会随包发布"
            missing=1
        elif ! git ls-files --error-unmatch -- "$z" >/dev/null 2>&1; then
            echo "::warning::$z 存在但没有被暂存(既不在仓库也没进本次提交)"
        fi
    done < <(find packages -name '*.pkg.tar.zst' -print0)
fi
if (( missing )); then
    echo "修复 .gitignore（只能限定 pkgbuilds/ 里忽略 .zst, 别用全局通配）后重跑。"
    exit 1
fi

# ── db 一致性检查 ──
# 踩过的坑: `repo-add --new` 不会刷新已存在条目的 CSIZE, 同版本重打后 db 里的 CSIZE
# 小于实际文件, pacman 直接以 "Maximum file size exceeded" 拒绝下载。这里兜一层。
# （需要 tar 支持 --zstd；不支持就跳过并告警）
DB=packages/fuego-repo/x86_64/fuego-repo.db.tar.gz
if [[ -f $DB ]] && tar --zstd -tf "$DB" >/dev/null 2>&1; then
    db_bad=0; db_n=0
    while IFS= read -r entry; do
        info=$(tar --zstd -xOf "$DB" "$entry" 2>/dev/null) || continue
        name=$(awk '/^%NAME%$/{getline;print;exit}'  <<<"$info")
        csize=$(awk '/^%CSIZE%$/{getline;print;exit}' <<<"$info")
        fname=$(awk '/^%FILENAME%$/{getline;print;exit}' <<<"$info")
        real=$(stat -c%s "packages/fuego-repo/x86_64/$fname" 2>/dev/null || echo -1)
        db_n=$((db_n + 1))
        if [[ "$real" != "$csize" ]]; then
            echo "::error::db 里 $name 的 CSIZE=$csize, 实际文件=$real —— 不一致时 pacman 会拒绝下载 (\"Maximum file size exceeded\")"
            db_bad=$((db_bad + 1))
        fi
    done < <(tar --zstd -tf "$DB" 2>/dev/null | grep -v '/$')
    echo "db 一致性检查: $db_n 个条目, $db_bad 个不一致"
    (( db_bad == 0 )) || exit 1
elif [[ -f $DB ]]; then
    echo "::warning::tar 不支持 --zstd, 跳过 db 一致性检查"
fi
