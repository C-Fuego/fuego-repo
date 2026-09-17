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
