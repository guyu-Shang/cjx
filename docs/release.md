# Phase 10：CJX V0.1 本地发布准备

> 此文保留 MIT 接入前的 Phase 10 验收记录。当前许可证已选择 MIT；最新发布包与冻结结果见 [V0.1.0 最终冻结](freeze.md)。

2026-10-05 完成。本阶段未新增业务命令，未改 SDK，未上传或自动 tag/push。
本地验证与打包 PASS；公开开源发布前仍需所有者决定 LICENSE。

## 文件变更

- src/cli.cj：整理帮助；版本集中为单点 CJX_VERSION，输出 `CJX 0.1.0`。命令行为和事务逻辑未改。
- tests/verify.ps1：新增 exe 版本与当前项目 `[package].version` 一致性检查，不从用户项目读取工具版本。
- README.md：改为项目首页，覆盖定位、使用、环境、安装、安全与验证。
- docs/architecture.md：简述模块职责及实际事务顺序；原阶段文档全部保留。
- scripts/release.ps1：本地门禁、官方命名构建、打包及黑盒检查。
- .gitignore：忽略 dist、构建、临时暂存、测试产物和已知 CJX 恢复路径，不删除恢复数据。
- dist/：本地可执行文件、README、SHA256SUMS；docs/release-evidence/：实际执行证据。

## README 首页结构

What is CJX / Why CJX / Features / Requirements / Installation / Quick Start /
Commands / Examples / Safety / Verification / Known Limitations / Development / Roadmap / License。
实现与阶段记录通过 docs 链接保留，不将 README 写成开发流水账。
CJX 仅处理 CLI、安全 TOML 编辑、CJPM 集成和诊断，不替代官方解析、下载、缓存、lock 或构建。

## 实际帮助和版本

```text
CJX - CJPM eXtension
Usage: cjx <command> [options]

Commands:
  list           List project dependencies
  add <name>     Add a path or Git dependency
  remove <name>  Remove a project dependency
  doctor         Diagnose project and SDK environment (read-only)

Options:
  -h, --help     Show help
  --version      Show version
  --dry-run      Preview add/remove without writing
  --no-update    Write add/remove without running CJPM

Examples:
  cjx list
  cjx add cui --path ../CangjieCUI
  cjx add foo --git https://example.com/foo.git
  cjx remove cui --dry-run
  cjx doctor

Add/remove run cjpm update by default. See README for Git selectors.
```

`--version` 实际为 `CJX 0.1.0`，与原 cjpm.toml 一致。CLI 只维护一个版本常量，
改版本时同时更新 manifest；verification 运行 exe 并自动核对，避免静默失同步。

## 构建与目录

本机实测 `cjpm clean` exit 0、`cjpm build -o cjx` exit 0，官方直接生成
`target/release/bin/cjx.exe`（以及 cjx.cjo）；没有将 main.exe 重命名冒充发布构建。
日常 build / verification 保留默认 main.exe。

```text
dist/
  cjx.exe          3,629,568 bytes
  README.md
  SHA256SUMS.txt
```

没有 LICENSE 文件、没有打包任何 SDK DLL。
使用者需自行安装并加载 SDK 环境，再用完整 exe 路径或自行放入 PATH；没有 installer。
当前只有本地产物，没有捏造公开下载地址。

本轮 cjx.exe SHA-256：

```text
13FBE348B47A45BB01A07E947400FB0D1E06FEBCC093675F0C6FA0010D245F1F
```

该指纹与 target 官方命名产物、暂存复制、最终 dist 和 SHA256SUMS 一致。
不宣称不同机器或未来再次编译一定产生同一指纹。

## release.ps1 流程

1. 拒绝覆盖已存在的 dist；检查 SDK/CJPM 并运行真实版本查询。
2. 执行完整 tests/verify.ps1，必须 exit 0 且其 summary 为 PASS。
3. 把验证证据归档到 docs/release-evidence，避免下一次 clean 删除；不将用户配置快照放入 dist。
4. cjpm clean → cjpm build -o cjx；必须找到官方 cjx.exe。
5. 创建独立本地暂存目录，复制 exe/README，若已有 LICENSE 则复制。
6. 比较复制前后 SHA，生成 SHA256SUMS，直接对暂存 exe 执行完整 smoke。
7. 再确认 exe hash 未变，将本次暂存目录移为 dist，输出 SHA 与结果。

任何步骤失败都停止、清理本次暂存目录，并记录原因；已有 dist 不会被覆盖。
没有自动上传、tag、push 或 SDK 环境修复。没有许可证时只警告并准备本地产物，不代替所有者授权。

## 最终真实执行结果

| 调用 | exit | 结果/证据 |
|---|---:|---|
| tests/verify.ps1 -PracticeRoot C:\sourse\cj\practice | 0 | 361 组、版本一致性、clean/build、smoke、生命周期和 rollback 全部 PASS |
| scripts/release.ps1 | 0 | 内置完整 gate 361 组 PASS；官方命名构建和打包产物 smoke PASS |
| dist/cjx.exe --help | 0 | 上述帮助 |
| dist/cjx.exe --version | 0 | CJX 0.1.0 |
| tests/smoke.ps1 -Binary dist/cjx.exe（完整路径） | 0 | 最终目录中的 exe 独立 lifecycle / rollback PASS |
| release 携带无效 PracticeRoot 的负面门禁 | 1 | verification 失败即停止，没有创建 dist |

官方 `cjpm test` 仍是 exit 0、TOTAL 0，报告明确为观察信息，不代替 361 组自定义测试。
新 smoke 不混入原有自定义组数。最终 dist 测试使用全新的官方 init 临时项目，
doctor/list/add/list/remove/list、dry-run、实际 import 函数调用、check/build 和真实失败恢复均完成。
预期失败的 add/remove 分别严格断言 exit 1，没有用阶段 exit 0 掩盖子命令失败。

完整输出/退出码及文件保护证据：

- [Phase 10 verification](release-evidence/phase10-verification-summary.json)
- [release gate 和构建记录](release-evidence/f26ab8df743346149d47e02707f189f9/release.json)
- [归档的 release verification](release-evidence/f26ab8df743346149d47e02707f189f9/verification.json)
- [最终 dist 黑盒记录](release-evidence/dist-blackbox.json) / [smoke 全部命令日志](release-evidence/dist-smoke.log)
- [门禁失败日志](release-evidence/rejected-gate.log)

所有 gate、smoke 和发布暂存目录已清理。真实 CJX/practice 的 TOML/lock 指纹与本阶段开始一致；
未对 practice 做写入。13 个生产 .cj 文件仅 cli.cj 因帮助/版本改变；12 个其他文件原始 SHA 未变，
CLI 的 list/add/remove/事务业务 helper 原文未变。生产源码共 **2528 行、13 文件**。

## 已知限制与发布判断

- 同等级验证只覆盖 Windows + Cangjie/CJPM 1.0.5，脚本使用 PowerShell 7，不宣称 Linux/macOS 已完整验证。
- 部分中文 CLI argv 在 main 前受 runtime 限制；中文 UTF-8 配置内容已被测试，并非 CJX 全面不支持中文。
- 当前 1.0.5 不支持 central version add；Git doctor 不联网验证。
- 文件事务不保证断电/OS crash 的原子持久化或阻止所有外部竞争。
- cjpm test 不运行当前自定义 suite；以 verify 为准。
- 修改 import 后官方工具可能异常链接；先手动 clean/build，不能运行失败构建留下的旧 exe 当作新产物。
- exe 依赖 SDK/runtime DLL 环境，版本查询 CJPM 也会调用 cjc。

技术门禁和本地产物准备已通过，没有发现新的业务阻塞缺陷。
**当前没有 LICENSE，需要项目所有者决定；它仍是公开开源发布前必须解决的事项。**
没有擅自选许可证，没有发布公网，没有继续 V0.2。
