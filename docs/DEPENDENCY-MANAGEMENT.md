# 依赖管理

三类输入：**包从哪更新**（update source）、**上游有什么新版本**（nvchecker）、**依赖关系怎么传播**（`.SRCINFO` + `.rebuild-on`）。

## 逐包声明：`update.toml`

在 `packages/<pkgbase>/update.toml` 中，用顶层字符串 `track` 声明唯一的更新方式，
用 `strategy` 独立声明构建策略：`source`、`vcs`、`binary` 或 `data`（见
[构建策略](BUILD-STRATEGY.md)）。例如：

```toml
track = "aur"
strategy = "source"
url = "https://aur.archlinux.org/quirc.git"
commit = "0123456789abcdef0123456789abcdef01234567" # 示例；同步会记录真实提交
```

| `track` | 额外字段 | 行为 |
|---|---|---|
| `aur` | `url` 为 AUR Git URL，`commit` 为 40 位小写十六进制提交哈希 | 同步 AUR 打包文件 |
| `workflow` | `workflow` 为仓库内已被 Git 跟踪的工作流路径，例如 `.github/workflows/filee-update.yml` | 由该工作流更新 |
| `manual` | `reason` 为非空字符串 | 不自动更新 |
| `git-tag` | `git` 为上游 Git URL；可选 `tag_pattern` 正则、`pkgver_from`（默认 `strip_v`） | 从匹配的 tag 更新 `pkgver` |
| `git-tag-pin` | `git`；可选 `tag_pattern` | 将 PKGBUILD 的 `_commit` 更新到匹配 tag 的提交 |
| `git-commit` | `git` | 将 PKGBUILD 的 `_commit` 更新到上游 HEAD |
| `git-vcs` | `git`；PKGBUILD 须有 `pkgver()` | 上游 HEAD 变化时提升 `pkgrel`，由 makepkg 推导 `pkgver` |

Git tracks 的 `on_update` 可为 `pull-request`（默认）、`issue` 或 `none`；只有
`pull-request` 会进入开 PR 的更新流程。版本监视和外部重建触发仍分别由
`.nvchecker.toml` 和 `.rebuild-on` 声明。

`update.toml` 存在时以它为准，格式有误不会回退到旧的更新来源。没有 TOML 的旧包
仍可读取 `.aur-url` / `.aur-commit`、`config/package-updates.txt` 和 `.build-strategy`；
旧版 Git track 的 TOML 未写 `strategy` 时仍可读取 `.build-strategy`。新包不需要这些旧文件。
可用 `./manage.sh packages show <pkgbase>` 查看生效声明，或用
`python3 scripts/check-package-manifests.py` 校验。

AUR 同步（`sync-aur-packages.sh`）是 per-package 故障隔离的：单包失败不拖累整批；本地定制写进 `scripts/overlays/<pkg>.sh`（sync 每次重放，必须幂等），不要直接改包目录文件——AUR 版本会覆盖它。

## 上游版本追踪（nvchecker）

`packages/*/.nvchecker.toml`，每文件至少一个 section；`check-upstream-versions.py` 每日汇总跑 nvchecker + nvcmp，`[upstream]` issue 通道提示（开/评论/自动关闭）。

- 普通包：基线 = PKGBUILD `pkgver`（git source 且 `use_commit` 时取 `.g<sha>` 短哈希）；
- **vendored 依赖**：`__baselines__` 表给显式基线，支持 `pin:<文件>`（如 ffmpeg-full 的 `.lensfun-pin`）与 `pkgvar:<VAR>`（如 `_whispercpp_ver`）。git source 的显式基线同样截短 7 位，否则 nvcmp 恒报更新；
- 基线优先取"已发布版本"（`emoeem.db`），PKGBUILD 只作未发布包的回退——正确的问题是"发布的东西旧不旧"。

## 运行依赖声明

- `depends` 以运行时真实需要为准；构建期头文件进 `makedepends`；可选运行时能力进 `optdepends` 并写明运行条件（如 `cuda: for NVIDIA NPP filters (...)`）。
- **repack 包的 depends 对账**：dsh-desktop-linux 的 `build()` 把资产 `.PKGINFO` 的 depend 集合与本地 `depends=()` 双向比较，任一方向不一致即构建失败（上游 rc2 删 libxss 就是这样漂移了三个版本的）。依赖语义的变更由人改数组，更新器只 pin pkgver/sha256。
- 仓库内互相依赖的包（mpeghdec/quirc/svt-jpeg-xs-git → ffmpeg-full）：构建 DAG 分波次，下游 job 等待并把上游新产物 staging 进本地仓库（`wait-for-build-dependencies.sh`）。

## 仓库外触发（`.rebuild-on`）

`packages/<dir>/.rebuild-on` 逐包声明 `.SRCINFO` 表达不了的触发：

```
soname <soname> <provider>   # 本包 NEEDS 但提供者在仓库外（如 shine）
package <name>               # 仓库解析不到版本的依赖走 AUR RPC 对账
```

格式由 `list-rebuild-triggers.sh` 解析、`check-package-manifests.py` 把关、两个漂移检测器消费。逐包声明替代了旧的全局 soname 白名单（白名单只要列了，任何包缺这个库都被掩盖）。声明了但产物实际不 NEED 的 soname 会被报 `STALE-DECLARATION`（声明必须与产物一致）。

## vendored 依赖的升级流程（ffmpeg-full 为例）

1. `[upstream]` issue 提示 lensfun/whisper.cpp 有新版；
2. 改 `.lensfun-pin`（或 PKGBUILD `_whispercpp_ver`）；
3. `makepkg --printsrcinfo` 同步 `.SRCINFO`（overlay 会在下次 sync 时自动重放 pin）；
4. 完整构建验证：`#commit=` 路径的 verifysource、补丁兼容性（070 whisper 补丁）、69 条功能矩阵；
5. 矩阵假红先核对 token 与产物实际命名，修矩阵而不是放宽脚本。

## 相关文档

[ABI-REBUILD-POLICY.md](ABI-REBUILD-POLICY.md)（漂移检测与重建）、[BUILD-STRATEGY.md](BUILD-STRATEGY.md)（哪些包不参与）、[FFmpeg-FEATURE-MATRIX.md](FFmpeg-FEATURE-MATRIX.md)（功能验证）。
