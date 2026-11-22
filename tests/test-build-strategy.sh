#!/usr/bin/env bash
# 构建策略库（scripts/lib/build-strategy.sh）与消费点判据的测试（Phase 3）。
#
# 钉住三件事：
#   1. lib 的解析：四值合法、注释与空行跳过、非法/缺失输出为空且返回非零；
#   2. fail-safe 判据的唯一方向：只有**明确声明**的 binary/data 才
#      defer 给上游；缺失或非法一律按可本地重建处理——三个消费点（依赖版本
#      漂移、SONAME 检测、dispatch）对「策略不明」不允许各自假设；
#   3. 真实树：packages/ 下 24 个包全部声明了合法策略，且 binary/data
#      的成员与可本地重建集合互斥（dispatch 端 IGNORE 的对象清单）。
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# shellcheck source=../scripts/lib/build-strategy.sh
source "$root/scripts/lib/build-strategy.sh"

printf '%s\n' '1: build_strategy_of parses the documented format'
mk_pkg() { # <name> <file-content-or-empty>
    local dir="$tmp/$1"
    mkdir -p "$dir"
    [[ -n "$2" ]] && printf '%s\n' "$2" > "$dir/.build-strategy"
    printf '%s\n' "$dir"
}
d="$(mk_pkg src "$(printf 'source\n# compiled from source\n')")"
[[ "$(build_strategy_of "$d")" == source ]] || fail 'source not parsed'

for value in source vcs binary data; do
    d="$(mk_pkg "ok-$value" "$value")"
    [[ "$(build_strategy_of "$d")" == "$value" ]] || fail "legacy file value $value not parsed"
    printf 'track = "manual"\nstrategy = "%s"\n' "$value" > "$d/update.toml"
    [[ "$(build_strategy_of "$d")" == "$value" ]] || fail "TOML value $value not parsed"
done

d="$(mk_pkg leading-comment "$(printf '# why\n\nbinary-repack\n')")"
[[ "$(build_strategy_of "$d")" == binary ]] || fail 'legacy alias not parsed'
printf 'track = "manual"\nstrategy = "binary-repack"\n' > "$d/update.toml"
[[ "$(build_strategy_of "$d")" == binary ]] || fail 'TOML alias not parsed'
printf 'track = "manual"\nstrategy = "bogus"\n' > "$d/update.toml"
[[ -z "$(build_strategy_of "$d" 2>/dev/null || true)" ]] || fail 'invalid strategy must mask legacy'

printf 'track = "git-tag"\ngit = "https://example.org"\n' > "$d/update.toml"
if build_strategy_of "$d" >/dev/null; then
    fail 'missing TOML strategy must mask legacy for Git tracks'
fi

d="$(mk_pkg bad 'sometimes')"
[[ -z "$(build_strategy_of "$d" 2>/dev/null || true)" ]] || fail 'an unknown value must not parse'
d="$(mk_pkg empty '')"
[[ -z "$(build_strategy_of "$d" 2>/dev/null || true)" ]] || fail 'an empty file must not parse'
d="$(mk_pkg absent '')"
rm -f "$d/.build-strategy"
[[ -z "$(build_strategy_of "$d" 2>/dev/null || true)" ]] || fail 'a missing file must not parse'
echo 'ok: lib parsing (four values, comments, unknown/empty/missing)'

printf '%s\n' '2: the fail-safe criterion only honors explicit declarations'
build_strategy_defers_to_upstream binary || fail 'binary must defer to upstream'
build_strategy_defers_to_upstream data || fail 'data must defer to upstream'
build_strategy_defers_to_upstream source && fail 'source must not defer'
build_strategy_defers_to_upstream vcs && fail 'vcs must not defer'
build_strategy_defers_to_upstream "" && fail 'an unknown strategy must NOT defer (fail-safe: rebuild)'
build_strategy_defers_to_upstream garbage && fail 'a garbage strategy must NOT defer'
echo 'ok: only binary/data defer; unknown strategies rebuild (fail-safe)'

printf '%s\n' '3: the real tree declares exactly one legal strategy per package'
shopt -s nullglob
declared=0
for pkg_dir in "$root"/packages/*/; do
    name="$(basename "$pkg_dir")"
    [[ -f "$pkg_dir/update.toml" ]] || fail "$name: missing update.toml"
    for legacy in .aur-url .aur-commit .build-strategy; do
        [[ ! -e "$pkg_dir/$legacy" ]] || fail "$name: obsolete $legacy"
    done
    value="$(build_strategy_of "$pkg_dir")" ||
        fail "$name: missing or illegal build strategy in the real tree"
    declared=$((declared + 1))
done
shopt -u nullglob
[[ ! -e "$root/config/package-updates.txt" ]] || fail 'obsolete package updates registry'
(( declared == 24 )) || fail "expected 24 packages with a strategy, found $declared"
echo "ok: $declared/24 packages declare a legal strategy"

printf '%s\n' '4: binary/data members match the audit classification'
expected_repack='dsh-desktop-linux fuego-repo-keyring magpie-bin steamcommunity302 uu-remote-linux-bin'
expected_data='ttf-jetbrains-maple-mono-xx-xx-xx'
actual="$(for pkg_dir in "$root"/packages/*/; do
    value="$(build_strategy_of "$pkg_dir")" || continue
    if build_strategy_defers_to_upstream "$value"; then
        basename "$pkg_dir"
    fi
done | sort | paste -sd' ' -)"
expected="$(for e in $expected_repack $expected_data; do printf '%s\n' "$e"; done | sort | paste -sd' ' -)"
[[ "$actual" == "$expected" ]] ||
    fail "binary/data set drifted from the audit: $actual"
echo 'ok: binary/data membership matches reports/pkgbuild-optimization/package-strategy-audit.md'

printf 'all build-strategy cases passed\n'
