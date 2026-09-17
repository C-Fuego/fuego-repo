# fuego-repo

自建 Arch 软件包仓库。GitHub 为**构建上游**（源码 + GitHub Actions CI + 产物），Codeberg 为**安装镜像**。pacman 安装统一走 Codeberg。

## 架构

```
GitHub (C-Fuego/fuego-repo)
  ├── pkgbuilds/            # 19 个包的 PKGBUILD
  ├── check-upstream.sh     # cron 轮询上游, 输出 .needs-build
  ├── build.sh              # 读 .needs-build/--all/指定包, makepkg 构建 + repo-add
  ├── ci/cargo-config.toml  # Rust 性能优化 (target-cpu=x86-64-v3 + release lto=fat)
  ├── ci/check-size.sh      # 推送前守门: >100MiB 拒绝 + 产物误忽略检查 + db CSIZE 一致性检查
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
| linuxqq-appimage / wechat-appimage | always | 瘦身包: 首次运行时下载官方 AppImage |
| osu-lazer-tachyon-bin | always | 瘦身包: 首次运行时下载官方 AppImage |
| ttf-jetbrains-maple-mono-xx-xx-xx | always | 瘦身包: 安装时下载字体 zip |
| osu-mime | fixed | 手动 |

**包类型**:
- `git-head` — 跟踪上游最新 commit, 变则重建
- `git-tag` — 跟踪最新 tag, auto-bump pkgver + 重建 (失败则回滚 bump)
- `always` — release/appimage/静态, 每次 cron 重建;**构建前自动更新 PKGBUILD 版本**:
  - osu / 字体: 自带轻量 `update-pkgver.sh` (git ls-remote 检测最新 tag, sha256=SKIP 由 makepkg 下载真实文件)
  - wechat: 自带 `update` 脚本 (HEAD 探测 Last-Modified + extract 取版本 + updpkgsums)
  - linuxqq: 自带 `update.sh` (node get_latest + download.sh, CI 需 nodejs)
- `fixed` — 固定源码, 不轮询

## 大包瘦身（为什么仓库里没有大文件）

GitHub 对**单个文件**的硬上限是 100MiB（服务端强制），超限对象推送时被直接拒收，
客户端只会看到 `error: RPC failed; HTTP 500 / fatal: the remote end hung up unexpectedly`。
所以下面四个超大的包不再把载荷装进 .zst，仓库里只有启动器/下载器（几 KB ~ 几百 KB），
载荷在运行时按需下载。pacman 侧使用方式完全不变（照样 `pacman -S`）。

| 包 | 载荷 | 下载时机 | 落到哪 |
|----|------|----------|--------|
| wechat-appimage | 官方 AppImage ~180MB | 首次运行 | `${XDG_DATA_HOME:-~/.local/share}/wechat-appimage/` |
| linuxqq-appimage | 官方 AppImage ~250MB | 首次运行 | `${XDG_DATA_HOME:-~/.local/share}/linuxqq-appimage/` |
| osu-lazer-tachyon-bin | 上游 release AppImage ~290MB | 首次运行 | `${XDG_DATA_HOME:-~/.local/share}/osu-lazer/` |
| ttf-jetbrains-maple-mono-xx-xx-xx | 上游字体 zip ~134MB | 安装/升级时 (.install) | `/usr/share/fonts/TTF` |

- 启动器在构建期由 PKGBUILD 用 sed 烘入「下载地址 + sha256 + 载荷标识」；首次运行下载并校验后缓存，
  之后直接启动；包升级（标识变化）时自动重新下载并清掉旧缓存。
- 下载失败会明确报错退出；校验和不符只告警（上游可能静默替换了同 URL 的文件）但继续启动。
- 国内下载慢时可用环境变量指向镜像：
  - wechat: `WECHAT_APPIMAGE_URL`
  - osu: `OSU_LAZER_APPIMAGE_URL`（例如 `https://<gh 代理>/https://github.com/ppy/osu/releases/download/<tag>/osu.AppImage`）
  - 字体: `sudo TTF_MAPLE_MONO_URL=https://<镜像>/...zip ttf-jetbrains-maple-mono-fetch`
- 字体是安装时下载，所以那些 ttf 不在 pacman 文件库里（`pacman -Qkk` 不会管），卸载时由包的
  `pre_remove` 清理；下载失败时联网后手动修复：`sudo ttf-jetbrains-maple-mono-fetch`。
- **改这几个启动器脚本后要同步 PKGBUILD 里的 sha256sums**（它们是本地源，makepkg 会校验；
  不同步会以「一个或多个文件没有通过有效性检查」失败）。wechat/linuxqq 的 `update` 脚本会跑
  `updpkgsums` 自动刷新。
- 构建期 makepkg 仍会下载这些载荷（取图标/desktop + 算校验和），由 `.gitignore` 排除：
  `*.AppImage`、`*.zip`、`*.tar.*`、上游 git 克隆（`pkgbuilds/*/*/`）、`squashfs-root/` 等，永不入库。
- 推送前 `ci/check-size.sh` 再兜一层：暂存文件 >100MiB 直接失败，>50MiB 只告警。

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

> 微信 / QQ / osu / 字体这四个包只装启动器（或下载器），首次运行（字体是安装时）需要联网下载载荷；
> 详见上面「大包瘦身」。其余 15 个包的 .zst 都是完整内容，装完即用。
