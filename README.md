# fuego-repo

自建 Arch 软件包仓库。GitHub 为**构建上游**（源码 + GitHub Actions CI + 产物），Codeberg 为**安装镜像**。pacman 安装统一走 Codeberg。

## 架构

```
GitHub (C-Fuego/fuego-repo)
  ├── pkgbuilds/            # 19 个包的 PKGBUILD
  ├── check-upstream.sh     # cron 轮询上游, 输出 .needs-build
  ├── build.sh              # 读 .needs-build/--all/指定包, makepkg 构建 + repo-add
  ├── ci/cargo-config.toml  # Rust 性能优化 (target-cpu=x86-64-v3 + release lto=fat)
  └── .github/workflows/build.yml
        │  cron 每天 03:17 UTC / push pkgbuilds/** / workflow_dispatch
        ▼
  archlinux:latest 容器 (CI) → 轮询→构建→产物 .zst→commit 回 GitHub→镜像 Codeberg
        ▼
Codeberg (C-Fuego/fuego-repo)  ← pacman 安装源
  raw/.../packages/fuego-repo/x86_64/fuego-repo.db.tar.gz
```

## 自动化触发

| 触发 | 时机 | 动作 |
|------|------|------|
| `schedule` | 每天 03:17 UTC | `check-upstream.sh` 轮询, 有变动才构建 |
| `push` | 改 `pkgbuilds/**`/脚本 | 全量 `--all` 构建 |
| `workflow_dispatch` | 手动 | 全量 `--all` 构建 |

## 包清单 (19)

| 包 | 类型 | 说明 |
|----|------|------|
| enable-3fg-drag | fixed | 手动, setuid 共享库 (不能 LTO) |
| grub-btrfs | git-tag | 自动 bump pkgver |
| mbpfan | git-tag | 自动 bump pkgver |
| librime | git-tag | 自动 bump pkgver + 重置 pkgrel=1 |
| linuxqq-clipsync | git-head | 构建需 `GIT_CONFIG_GLOBAL=/dev/null` |
| we-layerd-patched-git | git-head | 私有 CARGO_HOME, 内嵌 lto=fat |
| niri-shorin-fork-git | git-head | 私有 CARGO_HOME, 内嵌 lto=fat |
| krabby-git / pipes-rs-git / clock-rs-git | git-head | |
| cnmplayer-git | git-head | cargo+cmake |
| rime-frost-git | git-head | |
| shorin-contrib-git | git-head | |
| xclip-git | git-head | C, options=(lto) |
| linuxqq-appimage / wechat-appimage | always | 每次重建, 拉 AppImage |
| osu-lazer-tachyon-bin | always | 每次重建 |
| ttf-jetbrains-maple-mono-xx-xx-xx | always | 字体, 每次重建 |
| osu-mime | fixed | 手动 |

**包类型**:
- `git-head` — 跟踪上游最新 commit, 变则重建
- `git-tag` — 跟踪最新 tag, auto-bump pkgver + 重建 (失败则回滚 bump)
- `always` — release/appimage/静态, 每次 cron 重建;**构建前自动更新 PKGBUILD 版本**:
  - osu / 字体: 自带轻量 `update-pkgver.sh` (git ls-remote 检测最新 tag, sha256=SKIP 由 makepkg 下载真实文件)
  - wechat: 自带 `update` 脚本 (HEAD 探测 Last-Modified + extract 取版本 + updpkgsums)
  - linuxqq: 自带 `update.sh` (node get_latest + download.sh, CI 需 nodejs)
- `fixed` — 固定源码, 不轮询

## 构建性能优化

统一 `x86-64-v3` + 全优化, 强制开启 (无一例外, 除 enable-3fg-drag 因 setuid 需保持 `-O2 -fPIC`)。

- **C/C++** (makepkg): `CFLAGS="-march=x86-64-v3 -O3 -pipe -fno-plt -fexceptions"`, `options=(lto)` (GCC fat)
  - 应用于: xclip, librime, mbpfan, we-layerd(C++部分)
- **Rust** (cargo): `ci/cargo-config.toml` + 私有 CARGO_HOME 内嵌
  - `[env] RUSTFLAGS="-C target-cpu=x86-64-v3"`, `[profile.release] opt-level=3, lto="fat", codegen-units=1, panic="abort", strip=true`
  - we-layerd / niri-fork 覆盖私有 CARGO_HOME, 在 PKGBUILD prepare 内嵌 config
- 不携带国内镜像 (CI runner 用官方源更快)

## 手动对接 (一次性)

### 1. GitHub
- 建公开仓 `C-Fuego/fuego-repo`（可空仓）
- push 本目录到 main

### 2. Codeberg
- 把现有 `C-Fuego/fuego-artix-repo` 改名为 `C-Fuego/fuego-repo`（或新建）
- 作为镜像: Actions 每次构建后 force-push main

### 3. Actions Secrets / Variables
仓库 Settings → Secrets and variables → Actions:

| 类型 | 名称 | 值 |
|------|------|----|
| built-in | `GITHUB_TOKEN` | （自动注入, 无需配） |
| secret | `CODEBERG_USER` | Codeberg 用户名 |
| secret | `CODEBERG_TOKEN` | Codeberg 访问令牌 (read+write repo) |
| secret | `CODEBERG_OWNER` | Codeberg 拥有者 (通常=用户名, 如 `C-Fuego`) |
| variable | `CODEBERG_REPO` | 镜像仓库名, 如 `fuego-repo` |

> `GITHUB_TOKEN` 用于产物 commit 回 GitHub, Actions 内置, 无需手动配。
> Codeberg token 生成: 设置 → Applications → 生成 access token, 勾选 `write_repository`。

## 安装自建包

post-install 已封装 (`fuego-dotfiles/install/00-utils.sh` 的 `configure_repo`), 自动写:

```ini
# /etc/pacman.d/fuego-repo.conf
[fuego-repo]
SigLevel = Optional TrustAll
Server = https://codeberg.org/C-Fuego/fuego-repo/raw/branch/main/packages/fuego-repo/$arch
```

包清单用 `@fuego:包名` 前缀 (如 `@fuego:xclip-git`)。
