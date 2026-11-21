# 私人 Arch Linux 软件仓库

这个项目把 `packages/*/PKGBUILD` 自动构建成 Arch Linux `x86_64`
软件包，并在私有 `repo` 分支维护标准 pacman 仓库数据库。

当前维护 16 个 package base。

## Features

- 使用真实 Arch Linux `base-devel` 容器运行 `makepkg`。
- Pull Request 和 Push 自动执行 Bash 语法、`.SRCINFO`、ShellCheck 与 namcap 检查。
- Build Plan 由 `scripts/build-planner.py` 统一生成，依赖图来自 `scripts/lib/pkgbuild_lib.py`，同时处理 `.SRCINFO` 依赖、逐包 `.rebuild-on` 声明与可用的已发布 ABI manifest。
- `scripts/overlays/<package>.sh` 变化只触发对应包；`config/**` 变化触发全量重建。
- CI 使用可复用 CachyOS-v3 builder image，预装仓库配置、namcap 和 yay，减少重复 bootstrap。
- Repository integration tests 在真实 Arch 容器中验证 `repo-add`、删除和 epoch 文件名处理。
- 成功产物通过 `repo-add` 更新 `repo` 分支中的 pacman 仓库。

构建平台（详见 `docs/build-platform.md`）：

- **Build Plan**：每次运行先输出 changed / affected / rebuild / skipped 与**逐包原因**，不再是黑箱矩阵。
- **DAG 调度**：仓库内互相依赖的包按波次排序；CI 等待本轮被选中的前置 job，并把其新构建产物 staging 到下游的本地构建仓库；本地可用 `scripts/parallel-build.sh` 波次并行。
- **分层缓存**：pacman / VCS 源 / Cargo / ccache 四层独立 key，统一由 `.github/builder/generation` 失效。
- **构建时序**：按 makepkg 阶段统计 download / prepare / build / package 耗时与每次构建的 ccache 命中率，历史归档到 `state/timing-history.jsonl`。
- **失败分析**：59 条机器可读规则归类 16 类错误，给出根因、提供者、受影响包与建议动作，并产出 `build-report/` 诊断包。
- **事务式自动修复**：分级（Level 0-3，Level 4 只出建议）、快照 + 校验 + 失败逐字节回滚，带修复预算与审计记录。
- **运行时验证**：ldd / SONAME / 符号链接 / 权限 / 缺失依赖 / smoke 命令；发布闸门会在一次性容器中安装可选的新包并验证，默认跳过大型安装闭包（查看 CI skipped 清单）。
- **一键诊断**：`./scripts/doctor.sh` 检查环境、工具链、缓存、仓库与网络并给出 READY 结论。

## Packages

| Package | Arch | 说明 |
| --- | --- | --- |
| `dsh-desktop-linux` | `x86_64` | DeepSeek Harness 桌面版（上游 ffyfox 的 Electron 壳 + 内嵌 dsh 运行时）；直接重新打包上游 CI 产出的 Arch 安装包，安装到 `/opt/deepseek-harness-desktop` |
| `ffmpeg-full` | `x86_64` | 启用大量编解码器、CUDA 和 Whisper 支持的 FFmpeg |
| `linuxqq-wayland-fix-git` | `x86_64` | 修复 Linux QQ 在 Wayland 下的屏幕共享、声音共享、剪贴板和截图 |
| `mpeghdec` | `x86_64` | Fraunhofer MPEG-H 解码器 |
| `quirc` | `x86_64` | QR 解码库 |
| `svt-jpeg-xs-git` | `x86_64` | JPEG XS 编解码器 |
| `folia` | `x86_64` | Folia 音乐播放器（Rust + Zig 构建，`-C target-cpu=x86-64-v3`）；跟随上游 tag，安装到 `/usr/lib/folia` |
| `zbonsai` | `x86_64` | Rezig 的 Bonsai 组件 |
| `zclock` | `x86_64` | Rezig 的时钟组件 |
| `zeraora` | `x86_64` | Rezig 的 Zeraora 组件 |
| `ziglet` | `x86_64` | Rezig 的 Ziglet 组件 |
| `zlolcat` | `x86_64` | Rezig 的 lolcat（Zig 实现） |
| `zmatrix` | `x86_64` | Rezig 的 Matrix 数字雨效果 |
| `zpipes` | `x86_64` | Rezig 的管道屏保 |
| `shorin-contrib-git` | `any` | SHORiN 的 Arch 仓库贡献脚本集（VCS 包，版本由 `pkgver()` 计算） |
| `shorin-pac-git` | `any` | Shorin 的 pacman 辅助工具（VCS 包，版本由 `pkgver()` 计算） |

版本以各目录中的 `PKGBUILD` 和 `.SRCINFO` 为准。

## Build and CI

`check.yml` 在 Arch 容器中运行 `makepkg --printsrcinfo`、ShellCheck 和
namcap，同时运行 build-graph 与 repository integration tests；`build.yml`
独立负责只构建变更包及其递归依赖，并优先使用 GHCR 中的可复用 builder image。
Artifact 保存。构建成功后发布为滚动 GitHub Release（固定 tag `repo`），
pacman 直接从 Release 资产下载仓库数据库和软件包。AUR 同步只提交源
文件，提交本身会触发一次构建，不会重复 dispatch 同一个构建。

### 文档索引

| 文档 | 内容 |
| --- | --- |
| [`docs/BUILD-STRATEGY.md`](docs/BUILD-STRATEGY.md) | 四类构建策略（source/vcs/binary-repack/data）、逐包归类与调度分流 |
| [`docs/PKGREL-POLICY.md`](docs/PKGREL-POLICY.md) | pkgrel 形状、全部递增入口、`.pkgrel-floor-skip` 语义、写回与闸门链 |
| [`docs/ABI-REBUILD-POLICY.md`](docs/ABI-REBUILD-POLICY.md) | ABI watch 两类检测、STALE/UPSTREAM/NOTE 三态、冷却与豁免 |
| [`docs/DEPENDENCY-MANAGEMENT.md`](docs/DEPENDENCY-MANAGEMENT.md) | 更新来源三通道、nvchecker（含 vendored 基线）、`.rebuild-on`、依赖对账 |
| [`docs/FFmpeg-FEATURE-MATRIX.md`](docs/FFmpeg-FEATURE-MATRIX.md) | ffmpeg-full 功能矩阵、构建后验证、GPU 三态、ELF 检查 |
| [`docs/CI-QUALITY-GATES.md`](docs/CI-QUALITY-GATES.md) | 全部门禁清单、执行原则、并发去重、失败通知 |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | 按症状索引的排障手册（对应真实事故） |
默认采用原子发布：任一构建失败就不会发布本轮仓库更新；只有手动启用 `allow_partial_publish` 时才允许部分发布。

构建环境按以下优先级使用依赖：

1. CachyOS 仓库（`cachyos-v3`、`cachyos-extra-v3`、`cachyos-core-v3`、
   `cachyos`，使用官方 mirrorlist，容器同时接受 `x86_64_v3` 架构）
2. Arch Linux 官方仓库
3. archlinuxcn
4. coderkun-aur
5. Chaotic-AUR
6. 仍未满足的依赖由 `yay` 从 AUR 构建并安装

CachyOS 仓库排在 Arch 官方仓库之前，与目标系统的仓库优先级一致：构建
链接到的是本机 CachyOS 系统实际运行的库版本。若把 CachyOS 排在后面，
Arch 会在同名包冲突时胜出，当 CachyOS 先行替换了某个库（例如 openvino
的小版本更新带来的 soname 变化）时，构建出的包在本机就会出现共享库
找不到的问题。

构建容器保留 Arch 官方仓库的签名校验；未签名的第三方仓库仅在各自的
repository 段落中设置 `SigLevel = Never`。目标包本身仍由本项目保存的
PKGBUILD 重新构建，不会直接安装同名预编译包。


## 自动更新

**Sync AUR package sources** 工作流每天 `03:17 UTC` 检查一次所有带
`.aur-url` 的包目录。AUR 脚本发生变化时，它会更新对应的 PKGBUILD、
`.SRCINFO`、补丁和其他源文件，提交变化到 `main`，并触发对应软件包构建。

**ABI watch** 工作流每两小时（`23 */2 * * *`）运行一次，是发现「已发布的包
和当前仓库对不上」的主力：一边比对 `.BUILDINFO` 记录的依赖版本，一边把已发布
包的 ELF `NEEDED` 与当前各仓库的库清单对照。检测器必须有 `SUMMARY` 输出，
跑不动就报错，不会把「没跑起来」当成「没有漂移」；命中后自动 dispatch 重建
（带 `bump_pkgrel=true`）并开 / 更新一个 issue。

**Maintenance** 工作流每天 `16:17 UTC` 运行：清理过期 Artifact，并用同一个
soname 扫描脚本对已发布的包再做一次深度复查，发现依赖过时就自动触发重建。

**Sync dae release** 工作流每天 `02:17 UTC` 运行 `scripts/sync-dae-release.sh`：
比对 dae 上游的发布标记，有更新时重建 `daed-emo` 并等待这次构建结束。

**Track dsh-desktop-linux releases** 工作流每两小时（`53 */2 * * *`）扫描
[ffyfox/dsh-desktop-linux](https://github.com/ffyfox/dsh-desktop-linux) 的
release 列表，锁定最新一个真正发布 x86_64 Arch 资产的版本（alpha 标签没有
Arch 资产，按资产规则自动跳过）。`scripts/update-dsh-desktop-linux.py` 校验
tag、资产状态与 GitHub 计算的 sha256 digest，有新版时同时更新 `PKGBUILD` 的
`pkgver`/`sha256sums` 与 `.SRCINFO` 的 `pkgver`/`noextract`/`source`/`sha256sums`
（资产名内嵌 `pkgver`，所以这五行联动）；随后同样经过 makepkg 元数据校验、
候选构建与运行时验证才提交并 dispatch 发布。同一版本换了校验和会报错拒绝，
绝不静默重 pin 已发布的 tag。

**构建不沿依赖图传播**：构建计划只包含被点名的包。依赖更新后是否需要重建
依赖者由 ABI watch 裁决——它比对已发布包的 ELF `NEEDED` 与当前库清单，只有
真实 SONAME 断裂才会 dispatch 定点重建；不存在"邻居更新了就把 pkgrel 抬一档"
的联动更新。

## 添加 AUR 软件包

在日常使用的目录克隆 `main` 源码分支：

```bash
git clone --single-branch --branch main \
  https://github.com/C-Fuego/pkgbuild.git \
  ~/pkgbuild-source
cd ~/pkgbuild-source
```

添加软件包只需要一条命令：

```bash
./scripts/add-aur-package.sh package-name
```

脚本会自动同步 `main`、下载并校验 AUR 构建文件、提交新包并推送。
推送后 GitHub Actions 会自动构建并更新 `repo` 分支。默认 AUR 地址是：

```text
https://aur.archlinux.org/package-name.git
```

也可以传入其他 Git PKGBUILD 仓库：

```bash
./scripts/add-aur-package.sh package-name https://example.com/package.git
```

只想生成本地提交而暂时不推送时：

```bash
./scripts/add-aur-package.sh --no-push package-name
```

完整执行流程见 `docs/add-aur-package.md`。

自维护脚本只需放入 `packages/package-name/`，并确保其中同时存在
`PKGBUILD` 和最新的 `.SRCINFO`。没有 `.aur-url` 的目录不会被自动覆盖。

## 删除软件包

从源码和二进制仓库删除一个 package base：

```bash
./scripts/remove-package.sh package-name
```

脚本从 `.SRCINFO` 记录该 package base 产生的所有子包，删除源码目录并
推送。GitHub Actions 随后从 `repo` 分支删除相应软件包并重建 pacman
数据库。只创建本地提交时使用 `--no-push`。

仓库删除不会自动卸载电脑上已经安装的软件包。删除发布完成后，`sudo pacman -Sy`
刷新数据库，`pacman -Sl fuego-repo` 即可确认该包已从仓库消失。

## fzf 管理界面

安装 `fzf` 和 GitHub CLI 后，可以通过一个菜单完成添加、删除、同步、
构建、本地仓库更新和安装：

```bash
sudo pacman -S fzf github-cli
./manage.sh
```

多选软件包时使用 `Tab`。完整说明见 `docs/package-management.md`。

构建依赖图、CI builder 和 repository integration tests 的设计见 `docs/build-pipeline.md`。

## 构建产物

每个包会生成独立的私有 Actions Artifact。Artifact 使用 tar 作为传输
容器，以便保留 Arch `epoch` 产生的冒号文件名；发布任务解包后，原始软件包
文件名和内容不会发生变化。所有成功产物随后被合并进 `published/x86_64/`
并上传到 R2 桶的 `x86_64/` 前缀：

- `*.pkg.tar.zst`
- `fuego-repo.db` 与 `fuego-repo.db.tar.zst`
- `fuego-repo.files` 与 `fuego-repo.files.tar.zst`
- `SHA256SUMS`
- `fuego-repo.conf`
- `fuego-repo-abi-manifest.txt`（每个已发布包的版本与 ELF `NEEDED` 清单，
  供依赖/SONAME 漂移检测快速比对，无需下载整个仓库）

更新数据库时会删除同一个包的旧版本，并删除数据库不再引用的包文件：
R2 里只保留当前数据库能解析到的那些 `.pkg.tar.zst`，不会有历史版本堆积。
包文件一旦上传就不再覆盖（内容由 `x-amz-meta-sha256` 校验，同名同大小但
内容不同会被检出并重传），数据库每次都是新对象。

## 作为 pacman 仓库使用

仓库发布到 Cloudflare R2，由一个自定义域直连桶对外提供：

```ini
[fuego-repo]
SigLevel = Required DatabaseRequired
Server = https://ignacio.dpdns.org/x86_64
```

`SigLevel` 里的 `Required` 要求仓库签名 key 已经通过 keyring 包装进
`/etc/pacman.d/gnupg`，`DatabaseRequired` 要求数据库本身带 `.sig`。两样都由
`build.yml` 的签名步骤产出；如果不启用签名，把这一行换成 `SigLevel = Never`
（此时 `Server` 不变）。

桶的布局就是 pacman 的布局，一个前缀一个架构：

```
x86_64/fuego-repo.db          数据库（永不缓存）
x86_64/fuego-repo.db.sig
x86_64/fuego-repo.files
x86_64/<pkg>-<ver>-<rel>-x86_64.pkg.tar.zst   （一年不可变缓存）
```

发布顺序是「先包后库」：包文件先传，数据库最后传，所以客户端任何时候读到的
数据库都指向已经存在的文件。包文件永不覆盖，数据库永不缓存。

## SONAME 漂移排查

私有仓库的包由自己构建，不在 Arch 官方 rebuild 范围内。第三方依赖升级换掉
SONAME（`libfoo.so.2` → `libfoo.so.1`）或 ABI 后，已发布的包会立刻变成
「装得上、跑不起来」，典型症状：

```
mpv: error while loading shared libraries: liboapv.so.2: cannot open shared object file
```

五步定位：

```bash
# 1. 缺哪个库
ldd "$(command -v mpv)" | grep 'not found'

# 2. 这个 SONAME 还有没有主人（报错 = 提供者已经换了 SONAME）
pacman -Qo /usr/lib/liboapv.so.2
pacman -Ql openapv | grep liboapv

# 3. 刚才是谁升级换掉的
grep -iE 'openapv|liboapv' /var/log/pacman.log | tail

# 4. 哪些已安装的包需要重建（AUR + 私人仓库）
LC_ALL=C checkrebuild -i fuego-repo

# 5. 重建：推送到 main（只重建变化的包及其依赖者），或手动触发
gh workflow run build.yml -f packages=<pkg> -f make_jobs=4 [-f bump_pkgrel=true]
```

`rebuild-detector` 自带的 hook 在本机是**失效**的，两个原因：

- 它内部用 `LANG=C stat --printf "%F"` 识别可执行文件，但 `LC_MESSAGES`
  的优先级高于 `LANG`，中文环境下 `%F` 输出「一般文件」而不是
  `regular file`，于是它扫不到任何文件，永远报告「没有需要重建的包」。
  实测：`checkrebuild -i fuego-repo` 无输出，写成 `LC_ALL=C checkrebuild -i fuego-repo`
  后立刻列出 `fuego-repo  ffmpeg-full`。手动调用必须带 `LC_ALL=C`。
- `checkrebuild` 默认只覆盖 AUR（foreign）包和 `file://` 仓库，私人仓库
  需要显式 `-i fuego-repo`。

安装仓库自带的 hook 覆盖版本，`pacman -Syu` 结束时会直接列出需要重建的包：

```bash
sudo install -Dm644 client/host/rebuild-detector.hook \
  /etc/pacman.d/hooks/rebuild-detector.hook
```

`/etc/pacman.d/hooks/` 中的同名 hook 会覆盖
`/usr/share/libalpm/hooks/rebuild-detector.hook`；卸载 `rebuild-detector`
后请同时删除该文件。该版本不使用 `NeedsTargets`，因此每次事务都会重扫全部
AUR + 私人仓库包（本机实测约 2 秒），也能发现由传递依赖引起的失效。

仓库侧的自动化：

- 推送 `packages/**` 或 `scripts/overlays/**` 时，`build.yml` 只重建变化的
  包，不把依赖者拖进构建；依赖 ABI 断裂由 ABI watch 定点修复。
- `dependency-drift.yml`（ABI watch）每 2 小时同时跑两件事：比对 `.BUILDINFO`
  里记录的依赖版本，以及扫描已发布包的 ELF `NEEDED`（后者才抓得住 openvino
  这类换了 SONAME 的提供者）。两个检测器都必须打印 `SUMMARY` 行；任一没跑起来
  或比较数为 0，工作流直接失败——「检测器崩了」绝不允许被当成「没有漂移」。
  命中后自动 dispatch 带 `bump_pkgrel=true` 的重建，并开 / 更新一个 issue。
  仍然只有源码树里存在的包会被 dispatch；已下架却还在发布的记为 `ORPHAN`。
- `maintenance.yml` 每天用同一个 `check-repository-sonames.sh` 再做一次深度
  复查（同时清理过期 Artifact）。来自 chaotic-aur / archlinuxcn / arch4edu /
  AUR 的库由包自己在 `packages/<包>/.rebuild-on` 里声明（`soname libshine.so.3
  shine`），声明只对该包放行——没有全局白名单，全局名单会连带掩盖别的包缺同一个
  库；声明了却不再被 NEEDED 的名字判为过期声明（`STALE-DECLARATION`，退出码 4），
  而不是继续豁免。

`dependency-drift.yml` 比对的是 `<version>-<pkgrel>`（依赖只是重打包也可能换
SONAME），对象既有当前 `.SRCINFO` 里的依赖，也有 `.rebuild-on` 里 `package <名字>`
声明的名字——依赖从 `.SRCINFO` 消失后仍然被盯住；只在容器仓库之外提供的声明名
（如 archlinuxcn 的 `shine`）留一行 `NOTE`，不算漂移。

如果依赖提供者自己没声明 `provides=('libfoo.so=N-64')`（例如 chaotic-aur 的
`openapv`、CachyOS 的 `openvino`），pacman 无法阻止不兼容升级，只能依赖上面的
自动检测及时重建。openvino `2026.4.0` → `2026.4.1` 把 `libopenvino_c.so.2640`
换成 `.2641` 就是这样打断了 `ffmpeg-full`：`openvino` 在 depends 里是普通依赖，
pacman 拦不住；本地 hook 当场报了 `fuego-repo  ffmpeg-full`，但真正的重建要等检测器
发现——这就是把 soname 扫描从「每天一次」提到「每两小时一次」的原因。

## 客户端配置

`client/install.sh` 上游脚本针对 GitHub Release 发布方式，迁移到 R2 后已
不再适用，本 fork 没有携带它。手动配置见上文「作为 pacman 仓库使用」。

建议为 CI 单独创建仅用于仓库签名的 GPG 子密钥。

## 资源与许可

`ffmpeg-full` 会下载 CUDA，完整构建仍可能消耗较多时间和磁盘。可以在
仓库的 Actions Variables 中设置 `BUILD_RUNNER=self-hosted`，改用带
Docker 的 Linux 自托管 runner。

`ffmpeg-full` 的许可标识是
`LicenseRef-nonfree-and-unredistributable`。仓库必须保持私有，产物仅供
最终用户本人构建和使用，不要公开发布或用于商业用途。


## 维护工程化状态

当前仓库已完成一轮五阶段维护优化：

1. **AUR / Overlay**：AUR 同步改为事务式 staging，先验证上游、overlay、PKGBUILD 和 `.SRCINFO`，再替换工作区，避免失败同步破坏现有包。
2. **PKGBUILD 审计**：`scripts/audit-packages.sh` 对全部有效 package base 做元数据、架构、AUR 元数据以及 provider / dependency 一致性审计。
3. **构建缓存**：CI 复用 pacman、VCS source 和 Cargo 缓存；builder / build 脚本变化会使缓存 key 失效（按 flavor 前缀部分恢复旧缓存），下载的仓库资产存放在缓存目录之外，不进入缓存快照。
4. **Repository 完整性**：发布前运行 `scripts/verify-repository.sh`，校验数据库引用、软件包资产、SHA256 和仓库配置。
5. **管理与文档**：TUI 增加「审计全部软件包」，构建流水线文档同步记录实际维护流程。

在此之上完成的构建平台升级见 `docs/build-platform.md`，架构现状与文档/代码差异见
`docs/architecture-audit.md`；TUI 增加「构建计划与 DAG」「并行构建」「构建时序统计」
「修复中心」「运行环境自检（doctor）」。

推荐的本地维护检查（与 CI integration job 执行同一套）：

```bash
./tests/run-all.sh          # 语法 + lint + Python + 行为测试
# 静态检查统一入口（与 check.yml 的静态关卡同一份清单）；先接线一次：
# ./scripts/install-git-hooks.sh 让 pre-commit 钩子自动跑它
./scripts/run-static-checks.sh
bash tests/test-static-checks.sh
./scripts/doctor.sh         # 环境自检
./scripts/build-planner.py --selection changed --before HEAD~1 --after HEAD
./scripts/audit-packages.sh
```

## 构建平台优化（P1–P5）

- **P1 干净构建**：CachyOS-v3 `devtools` clean chroot；`workflow_dispatch` 可选 `legacy` / `chroot`（默认 legacy，push 始终 legacy）；基线按 builder generation / 架构 / 配置指纹缓存，每包工作副本用后删除；同批次 DAG 依赖通过只读临时仓库传递。切换前必须完成 3 次连续 chroot shadow-run 验收。
- **P2 上游追踪**：`packages/*/.nvchecker.toml` + 每日 workflow；新版本开/更新 issue，不自动修改 PKGBUILD。
- **P3 失败闭环**：失败分类与根因进入去重 issue，构建恢复后关闭。
- **P4 升级验证**：隔离 chroot 中先安装已发布的旧版本，再升级到本轮新构建的包，抓只有升级才暴露的问题（provides/conflicts 写错、SONAME 变了但版本号没变、包改名残留）；对 `linuxqq-wayland-fix-git`（VCS）和 `folia`（跟 tag）执行，缺少旧版时明确标记不可验证。
- **P5 质量留痕**：默认执行 `check()`；仅 `.skip-check` 可显式豁免；namcap issue 按包 + 规范化警告内容去重，`.namcap-ignore` 支持逐条长期豁免。

详细设计、shadow-run 操作、回退条件、缓存监控和本地 rootless Podman 限制见 [`docs/build-pipeline.md`](docs/build-pipeline.md)。当前任务指针见 [`CURRENT-STATUS.md`](CURRENT-STATUS.md)；历史评审材料归档于 [`docs/archive/`](docs/archive/)。
