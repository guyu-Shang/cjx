# CJX

**CJPM dependency management UX extension.**

CJX（CJPM eXtension）为仓颉项目提供依赖操作 CLI：列出依赖、安全增删依赖、检查环境。
V0.1 已在 Windows + Cangjie 1.0.5 / CJPM 1.0.5 完成独立验收；无第三方依赖。

## What is CJX

CJX 是 CJPM 的开发者体验增强层，不是 CJPM 替代品。
它负责 dependency CLI UX、局部 TOML 安全编辑、CJPM 集成与诊断；
依赖解析、下载、缓存、lock 管理和构建仍由官方 CJPM 完成。

## Why CJX

手动增删 `cjpm.toml` 的依赖容易遗漏刷新或误改其他配置。
CJX 为常用 Path / Git 依赖提供清晰命令，先规划并验证局部补丁，
再安全写入并调用官方 `cjpm update`，遇到失败时尝试恢复项目元数据。

## Features

- `list`：展示 path / git / central / unknown 声明。
- `add`：添加 CJPM 1.0.5 接受的 Path 或 Git 依赖，拒绝覆盖现有名称。
- `remove`：删除依赖声明，保留其他声明、前置注释与空行。
- `doctor`：只读检查 SDK、CJPM、配置结构、Path 依赖及 lock 状态。
- `--dry-run`：增删预览；`--no-update`：仅提交 TOML，稍后手动刷新。
- 字节范围补丁保留原文、UTF-8、BOM、CRLF/LF 和其他 section。

## Requirements

Tested with:

- Windows
- Cangjie 1.0.5
- CJPM 1.0.5

运行 `cjx.exe` 前需安装并加载 Cangjie SDK 环境，包括 runtime DLL 搜索路径。
开发、verification 和本地打包脚本使用 PowerShell 7。
其他操作系统或 SDK/CJPM 版本可能可用，但没有完成同等级验收。

## Installation

### A. 使用可执行文件

从项目维护者提供的本地发布包或未来正式发布附件取得 `cjx.exe`。
当前只准备本地 `dist/` 产物，尚未上传公开 release；没有在线下载地址。
不要单独下载未知来源的 SDK DLL，发布包也不包含 SDK DLL。

在加载 SDK 的终端中直接使用绝对路径：

```powershell
# 替换为自己已安装 SDK 的路径；只设置当前终端的环境
. 'C:\path\to\cangjie\envsetup.ps1'
& 'C:\tools\cjx\cjx.exe' --version
```

也可自行把 `cjx.exe` 放入已有 PATH 目录，之后使用 `cjx`。
项目脚本不会修改系统 PATH，也没有 installer。

### B. 源码构建

在仓库根目录的已加载 SDK 终端执行：

```powershell
cjpm clean
cjpm build -o cjx
.\target\release\bin\cjx.exe --version
```

发布名称由官方 `-o cjx` 产生，不是复制 `main.exe` 后重命名。
日常 `cjpm build` 仍生成 `target/release/bin/main.exe`。

## Quick Start

先切换到自己的 CJPM 项目目录；也可以从其子目录运行，CJX 会向上定位最近的 `cjpm.toml`。
以下示例假设 `cjx.exe` 已可通过 `cjx` 调用，否则替换为 exe 的完整路径。

```powershell
cjx doctor
cjx list
cjx add cui --path ../CangjieCUI --dry-run
cjx add cui --path ../CangjieCUI
cjx list
cjx remove cui --dry-run
cjx remove cui
```

普通 add/remove **会写配置并执行 update**；只想查看计划时必须显式加 `--dry-run`。
示例 Path 目录需要实际存在才能完成 update。

## Commands

| 命令 | 行为 |
|---|---|
| `cjx list` | 展示最近项目的依赖；无 section / 空 section 均为 0 dependencies |
| `cjx add <name> --path <path>` | 添加本地依赖，路径相对于目标项目根目录 |
| `cjx add <name> --git <url>` | 添加 Git 依赖，由 CJPM 处理下载与解析 |
| `cjx remove <name>` | 删除指定声明，名称区分大小写；不存在则拒绝 |
| `cjx doctor` | 只读诊断，不执行 update/check/build 或联网 |
| `cjx --help` / `-h` | 显示帮助；无参数同样显示帮助 |
| `cjx --version` | 显示 CJX 版本 |

add/remove 支持 `--dry-run`、`--no-update`，同时指定时 dry-run 优先。
Git 可选 `--branch`、`--tag`、`--commit-id`（写为官方 `commitId`）。
1.0.5 的多个 selector 可以同时声明，优先级 commitId > branch > tag；
Path 不能与 Git 或其 selector 混用。不提供 force/apply/yes 开关。

退出码：0 成功（doctor 仅 WARN 也为 0）；1 文件、配置、环境、事务或 update 失败；2 参数错误。
doctor 在项目外仍检查工具，项目缺失 ERROR、退出码 1。缺少 lock 仅 WARN。

## Examples

```powershell
cjx add foo --git https://example.com/foo.git --branch main --dry-run
cjx add foo --git https://example.com/foo.git --tag v1.0.0 --dry-run
cjx add foo --git https://example.com/foo.git --commit-id abc123 --dry-run
# URL/selector 仅示意，实际添加需使用真实仓库和引用
cjx add foo --path ../foo --no-update
# 稍后由用户手动刷新
cjpm update
```

典型列表：

```text
Dependencies
------------------------------------------------------------
NAME  SOURCE     SPEC
cui   path       ../CangjieCUI

1 dependency
```

## Safety / Transaction Behavior

读取 → scanner → planner → 内存补丁验证 → 安全写入 → 官方 update → 最终验证。
修改使用原文 UTF-8 byte range，拒绝重复名称、结构歧义、malformed 或不支持的 dependencies 表达形式。
这不是完整 TOML parser；目前可编辑普通 `[dependencies]`，不支持依赖子表/数组表等形式。

写入前检测原始字节未变化；同目录临时写入、关闭、回读验证后通过短期恢复文件替换。
默认 add/remove 共用项目操作锁及 TOML/lock 元数据快照。
update 失败时尝试恢复操作前 TOML、lock 的字节及原始存在状态。
若存在外部修改或恢复失败，报告原因并保留恢复路径，不强行覆盖其他工具的编辑。
恢复目录即使被 .gitignore 忽略，也应按错误提示人工检查，不能因被忽略就删除。

不回滚 CJPM 全局缓存、已下载仓库或远程副作用；不保证断电/OS crash 下绝对原子持久化，
也不能完全排除不遵循 CJX 锁的外部工具竞争。详见 [安全写入](docs/safe-write.md)。

## Verification

正式发布验证入口（已加载 SDK 的 PowerShell 7）：

```powershell
.\tests\verify.ps1
# 可选：增加指定练习项目的只读验证，不作为公共验证前提
.\tests\verify.ps1 -PracticeRoot 'C:\sourse\cj\practice'
```

入口依次检查版本、clean/build、全部自定义测试、CLI smoke、真实 Path 生命周期、update 失败回滚、
清理及文件保护，返回 PASS/FAIL 和退出码。数量从当次 runner 输出统计，不硬编码历史总数。
阶段日志与文件快照位于 `target/verification/<run-id>/`，下次 clean 会删除这些构建区日志。

自定义测试真实编译生产源码或直接执行生产 exe。
当前 `cjpm test` 发现 **0 tests**，它不能代替 verify，也不能说明自定义测试已运行。
[Verification Gate 说明](docs/verification-gate.md) · [独立验收报告](docs/acceptance/report.md)

## Known Limitations

1. Windows + Cangjie 1.0.5 下，部分中文 CLI argv 可能在进入 main 前由 runtime 拒绝，
   报 `Invalid unicode scalar value`；纯 SDK 最小程序已复现。
   **中文 UTF-8 配置文件内容可读取、扫描、保真写回，已有测试覆盖**，两者不能混淆。
2. CJPM 1.0.5 不支持 central version add。list 可展示该声明，doctor 给兼容 WARN；不自动升级 SDK。
3. Git doctor 只检查声明，不 clone/ls-remote/ping，不验证网络、仓库或引用是否可访问。
4. 文件事务不承诺断电/OS crash 的原子持久化或阻止任意外部竞争。
5. `cjpm test` 不自动发现 CJX 自定义测试；使用 verify.ps1。
6. 修改依赖/import 后出现异常链接错误时，先手动 `cjpm clean`、`cjpm build`。
   该现象纯官方 CJPM 也可复现；构建失败后可能保留旧 exe，不能用旧 exe 运行成功证明新构建成功。
7. exe 启动需要 SDK/runtime DLL 环境；doctor 只能诊断已成功启动后的问题。
   CJPM 1.0.5 的 --version 也会调用 cjc，缺少 cjc 时版本查询可能一并失败。

## Development

```powershell
cjpm build
.\target\release\bin\main.exe --help
.\tests\verify.ps1
# 完成全部验证后生成本地发布目录；脚本也会再次运行 verification
.\scripts\release.ps1
```

release 执行 verification → clean → `build -o cjx` → 暂存复制 → SHA-256 校验 → 打包产物 smoke → dist。
任何 verification 或 smoke 失败均停止；不自动 tag/push/上传。
`dist/` 已存在时脚本拒绝覆盖，请先自行将上一份产物移到其他目录。

本地目录包含 `cjx.exe`、`README.md`、`SHA256SUMS.txt`，若项目已有 LICENSE 也会复制。
绝不打包 SDK DLL。完整 gate 证据在 clean 前归档到 `docs/release-evidence/<run-id>/`，不进入 dist。

版本维护位置：`src/cli.cj` 的单点 `CJX_VERSION`，同时更新 `cjpm.toml` 的 `[package].version`；
verification 会执行 exe --version 并核对一致性，不从用户项目配置读取工具自身版本。

项目结构与历史实现记录：

- [Architecture](docs/architecture.md)
- [Scanner](docs/scanner.md) / [List](docs/list.md)
- [Add planner](docs/add-dry-run.md) / [Add CLI](docs/add-cli.md) / [Update](docs/add-update.md)
- [Remove planner](docs/remove-dry-run.md) / [Remove write](docs/remove-write.md)
- [Doctor](docs/doctor.md) / [Verification](docs/verification-gate.md)

## Roadmap

V0.1：list、Path/Git add、remove、doctor、安全编辑与 CJPM 集成。
未来再评估 search/info/outdated/upgrade、中心仓版本依赖、更多平台验证；目前没有实现或承诺发布时间。
CJX 始终保留 UX 增强层定位，不自行开发解析下载系统或包仓库。

## License

CJX is licensed under the [MIT License](LICENSE). SPDX identifier: `MIT`.

版权行已确认为 `Copyright (c) 2026 guyu-Shang`。
