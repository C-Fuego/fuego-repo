# 导入和查看软件包

在源码 checkout 根目录用 `./manage.sh add` 导入 AUR 或本地 PKGBUILD。它只创建
`packages/<pkgbase>/`，不会拉取本仓库，也不会暂存、提交或推送。已存在的包不会被覆盖。

## 从 AUR 导入

```bash
./manage.sh add package-name
./manage.sh add package-name --strategy binary
```

默认克隆 `https://aur.archlinux.org/<pkgbase>.git`。split package 建议传入 AUR 页面上的
package base；若直接用输出包名克隆失败，CLI 会尝试通过 AUR RPC 查找对应的 package base。
导入的文件来自该次克隆的提交，包括 PKGBUILD、`.SRCINFO` 和补丁等辅助文件；
`update.toml` 会写入 `track = "aur"`、`url`、`commit` 和 `strategy`。导入时若发现已有
该包的 overlay，命令会拒绝直接导入；先审查并应用 overlay，再用下面的本地导入方式，
如仍要维护为 AUR 镜像，需把生成的声明改为 `aur` 并填写真正的 URL 和提交。

## 从本地目录导入

```bash
./manage.sh add package-name --from /path/to/pkgbuild-dir \
  --track manual --reason 'Maintained in this repository' --non-interactive
```

名称须与 PKGBUILD 的 `pkgbase` 一致。命令复制 PKGBUILD 和辅助文件，使用
`makepkg --printsrcinfo` 重新生成 `.SRCINFO`，再写入新的 `update.toml`。这一步会执行
PKGBUILD 顶层代码，只能导入已审查的本地目录，并以普通用户运行。不要用含构建产物或其他
无关文件的目录。

- 不指定 `--strategy` 时，有 `pkgver()` 默认 `vcs`，否则默认 `source`；重打包上游二进制和纯数据包应明确选 `binary` 或 `data`。
- 终端交互模式会询问未提供的更新参数。`--non-interactive` 禁止询问；应显式传入需要的参数。未指定更新方式时，若有 `pkgver()` 且能识别唯一的未固定 Git 源，默认 `git-vcs`，否则默认 `manual`。
- 自有更新工作流可用 `--track workflow --workflow .github/workflows/example.yml`；该路径必须存在并由 Git 跟踪才能通过清单校验。Git 更新方式可用 `--track git-tag` 等，并以 `--git` 指定上游地址。

全部选项见 `./manage.sh add --help`；声明格式见 [依赖管理](DEPENDENCY-MANAGEMENT.md)。

## 复查并提交

```bash
./manage.sh packages list
./manage.sh packages list --track aur
./manage.sh packages show package-name
python3 scripts/check-package-manifests.py
./scripts/check-package.sh package-name
```

`packages list` 展示包基名、版本、更新方式及构建策略（`--no-header` 可省略表头）；
`packages show` 按实际包基名查看输出包名和生效的更新声明。确认新增目录内没有构建产物，
并审查 PKGBUILD、`.SRCINFO`、`update.toml` 及辅助文件后，再自行提交和推送。

推送后 GitHub Actions 会检查打包元数据，按构建计划编译并在发布检查通过后发布二进制包。
每日 AUR 同步检查 `track = "aur"` 的包，更新 AUR 文件并把同步点写入 `update.toml` 的
`commit`。仓库自己的 `update.toml`、`.nvchecker.toml` 和 `.gitignore` 等元数据不会被上游覆盖。
对上游普通文件的本地定制（例如修改 PKGBUILD 或补丁）应写入幂等的
`scripts/overlays/<pkgbase>.sh`，同步时会重新应用。

## 捆绑 runtime 的包的 namcap 例外

`packages/<name>/.namcap-exclude` 每行一个 namcap **规则名**（`namcap -L`
第一列），`scripts/run-namcap.sh` 把它反做成 `--rules` 白名单：取全部启用
规则，去掉列出的那些。

不用 `--exclude` 是因为 namcap 自己的循环 bug：它每轮都执行
`active_modules.update(modules)`，逗号列表会把上一轮排除的规则加回来，多个
名字里只有最后一个真正生效。白名单的 `-r` 是逐个累加，没有这个问题。

它只用于上游把完整运行时打进载荷的包：namcap 只看系统包，会把载荷内自带的
Python 模块报成缺失依赖（`pydepends`），也会把上游构建机留下的 RPATH/RUNPATH
报成不安全路径（`rpath`、`runpath`）。不写这个文件就必须让 namcap 全量通过，
这是默认路径。

## 常见失败

- `already managed`：该包已存在。用 `packages show` 检查声明；AUR 包可用 `./scripts/sync-aur-packages.sh <pkgbase>` 同步。
- `does not match .SRCINFO pkgbase`：本地导入的名称须与 `pkgbase` 一致，而不是 split package 的输出名。
- `makepkg is required`：本地导入需在安装了 makepkg 的环境运行。
- CI 构建失败：查看 GitHub Actions 对应软件包 job 的日志。
