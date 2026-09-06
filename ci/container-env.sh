#!/usr/bin/env bash
# container-env.sh — 在 archlinux 容器内准备构建环境并运行 build.sh
# 用法: bash /work/ci/container-env.sh [--all | <pkg...>]
#
# workflow 通过 docker run 挂载工作区后调用本脚本:
#   docker run --rm -v "$WS":/work -w /work archlinux:latest bash /work/ci/container-env.sh --all
set -euo pipefail

# ── 构建环境 ──
pacman -Syu --noconfirm
pacman -S --noconfirm --needed base-devel git sudo curl jq zig clang llvm nodejs npm

# 全部 C/C++ 项目优化: march=x86-64-v3 + O3 (对应 Rust 的 target-cpu=x86-64-v3)
sed -i 's|^CFLAGS=.*|CFLAGS="-march=x86-64-v3 -O3 -pipe -fno-plt -fexceptions"|' /etc/makepkg.conf
sed -i 's|^LDFLAGS=.*|LDFLAGS="-Wl,-O1 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now"|' /etc/makepkg.conf

# makepkg 拒绝 root → 建 builder 用户
useradd -m builder || true
echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
chown -R builder:builder /work

# Rust 优化 config → builder 的 CARGO_HOME (覆盖不含私有 CARGO_HOME 的 rust 包)
install -d -o builder -g builder /home/builder/.cargo
install -o builder -g builder /work/ci/cargo-config.toml /home/builder/.cargo/config.toml

# ── 确定构建方式 ──
if [[ "${1:-}" == "--all" ]] || [[ ! -s /work/.needs-build ]]; then
    ARGS=(--all)
else
    mapfile -t ARGS < <(tr '\n' ' ' < /work/.needs-build)
fi

# ── 构建 ──
su builder -c "cd /work && ./build.sh ${ARGS[*]}"