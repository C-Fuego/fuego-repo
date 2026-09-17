#!/usr/bin/env bash
# ci/diag-container.sh — 一次性诊断脚本（在 archlinux 容器里跑）
#
# 用途: 本地/CI 无法复现的 Rust 链接失败（例如 CI 里 pipes-rs 的
#       `ld.lld: undefined symbol: mi_zalloc_aligned`），把容器里的真实工具链
#       与完整链接命令行打印出来。
#
# 由 .github/workflows/diag.yml 手动触发，也可以通过
#   docker run --rm -v "$PWD":/work -w /work archlinux:latest bash /work/ci/diag-container.sh
# 本地跑。
set -uo pipefail

echo "===== 1. 构建环境（与 ci/container-env.sh 保持一致） ====="
pacman -Syu --noconfirm >/dev/null 2>&1
pacman -S --noconfirm --needed --noprogressbar base-devel git rust curl jq zig clang llvm >/dev/null 2>&1
sed -i 's|^CFLAGS=.*|CFLAGS="-march=x86-64-v3 -O3 -pipe -fno-plt -fexceptions"|' /etc/makepkg.conf
sed -i 's|^LDFLAGS=.*|LDFLAGS="-Wl,-O1 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now"|' /etc/makepkg.conf

echo "===== 2. 工具链是谁 ====="
for c in cc gcc x86_64-linux-gnu-gcc x86_64-pc-linux-gnu-gcc ld ld.bfd ld.lld lld ar zig cargo rustc; do
    p=$(command -v "$c" 2>/dev/null)
    if [[ -n $p ]]; then printf '  %-26s %s -> %s\n' "$c" "$p" "$(readlink -f "$p")"; else printf '  %-26s (缺)\n' "$c"; fi
done
gcc --version | head -1 | sed 's/^/  /'
ld --version  | head -1 | sed 's/^/  /'
ld.lld --version 2>/dev/null | head -1 | sed 's/^/  /'
rustc -vV | sed 's/^/  /'
echo "  CFLAGS/LDFLAGS: $(grep -E '^(CFLAGS|LDFLAGS)=' /etc/makepkg.conf | tr '\n' ' ')"

echo
echo "===== 3. 复现 pipes-rs 链接（CI 里失败的那个） ====="
mkdir -p /tmp/ch && cp /work/ci/cargo-config.toml /tmp/ch/config.toml
rm -rf /tmp/pipes-rs
git clone -q --depth 50 https://github.com/lhvy/pipes-rs.git /tmp/pipes-rs
cd /tmp/pipes-rs || exit 1
echo "  上游 HEAD: $(git log --oneline -1)"
echo "  --- cargo build -v（只摘链接相关行） ---"
CARGO_HOME=/tmp/ch RUSTFLAGS="-C target-cpu=x86-64-v3" \
    cargo build --release --locked -v 2>&1 | grep -E "rustc --crate-name pipes_rs|linking with|undefined symbol|error|Finished|note:" | tail -30 | sed 's/^/  /'
echo "  产物: $(ls -l target/release/pipes-rs 2>/dev/null | awk '{print $5" 字节"}' || echo 无)"

echo
echo "===== 4. 结论提示 ====="
echo "  如果上面出现 undefined symbol: mi_*  → 容器里能复现, 可以在此容器里试修法"
echo "  如果没有                            → 环境差异在别处（rustc 版本/网络/缓存）"
