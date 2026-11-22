# 构建优化策略

目标：x86-64-v3 基线（AVX2 / BMI2 / FMA，Haswell 与 Zen 1 及更新的 Intel / AMD 处理器均可），RTX 4050 Laptop 对应的 CUDA 89 只用于需要 CUDA 的包。

## 为什么不用厂商专属的 `-march`

曾经这里写的是 `znver3`。它会生成 AMD 专有的 SSE4a 指令（`insertq` / `extrq`），在 Intel 处理器上直接触发 SIGILL：发布出来的 `libflyline.so` 在 Intel Core Ultra 机器上被 bash 加载时崩溃，终端随之退出。`tests/test-build-regressions.sh` 现在会拒绝 `znver*` / `zen*` / `native` 回到构建配置里。

## 编译参数

- C / C++：`-march=x86-64-v3 -mtune=generic -O3 -pipe -fno-plt -fexceptions`，加上 Fortify、format、stack-clash-protection
- Rust：`-C target-cpu=x86-64-v3 -C opt-level=3`
- Zig：包的 PKGBUILD 里写 `-Dcpu=x86_64_v3`
- CUDA：固定架构 `89`，不依赖 CI 构建机 GPU 探测

配置在 `config/emo-native-flags.conf`（makepkg）与 `config/emo-native-flags.sh`（`build-in-arch.sh`）。

## LTO / PGO

LTO 不全局强制。链接用 lld 的 Rust 包，如果带有 C 依赖（例如 zstd-sys），要写 `options=('!lto')`，否则 GCC 的 LTO 目标文件 lld 读不懂。PGO 目前不默认启用。

## 构建可重复性

不依赖构建机的随机硬件探测：CPU 目标固定为 x86-64-v3，GPU 固定为 CUDA 89，builder 预检 GCC、Objective-C、assembler、linker。
