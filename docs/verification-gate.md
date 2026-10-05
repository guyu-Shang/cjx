# Phase 9.5B：V0.1 Verification Gate

本阶段仅调整验证入口、测试可移植性与限制说明，生产 `.cj` 文件未改动；没有继续 Phase 10 或发布 release。

## 正式入口

在已加载安装 SDK 环境的 PowerShell 7 中执行：

```powershell
.\tests\verify.ps1
# 可选；只读验证自己的练习项目（应包含 cui = { path = "../CangjieCUI" }）
.\tests\verify.ps1 -PracticeRoot 'C:\sourse\cj\practice'
```

缺少 cjc/cjpm 时明确 FAIL、退出码 1，提示先手动加载 SDK 官方 envsetup.ps1。
不会自动 envsetup，也不会改变系统或用户 PATH。入口向子进程明确传递当前有效 PATH，
避免启动器同时提供 Path/PATH 时继承 SDK DLL 路径不一致；不修改父进程的环境。
测试 PowerShell 子进程使用 UTF-8 解码 native stdout，避免中文配置的输出断言受 OEM 代码页影响。

日志位于本轮 `target/verification/<run-id>/summary.json` 和各入口 `.log`；
下一轮 clean 会删除旧构建区证据，需要保留时另行复制。
本阶段取证另外保存在 [verification-gate-evidence](verification-gate-evidence/)。

## 阶段及失败规则

1. 检查 cjc/cjpm 存在、实际运行 --version，显示版本。
2. cjpm clean；确认旧 main.exe 不存在，再 cjpm build，确认新产物存在。
3. 依次运行七个正式自定义测试入口，不执行 ReadOnly 子集替代全部测试。
4. 运行 cjpm test，记录官方发现数量，明确它不是自定义测试入口。
5. 直接执行最终 main.exe 的 --help/--version；在官方 init 的独立临时项目中验证 doctor/list。
6. Path add/list/remove/list、dry-run、官方 check/build，并运行实际 import foo 的新消费者，输出必须为 foo。
7. 从有效项目基线制造真实 update 失败，分别验证 add/remove 的失败码、TOML/lock 字节恢复；恢复外部测试目录后 check/build。
8. 检查真实配置、生产源码及 User/Machine PATH 未改变，检查测试清理；删除本次拥有的工作区，输出汇总并保存证据。

脚本失败立即停止后续测试阶段，最终仍执行保护与清理检查。命令非零、显式 FAIL 行、汇总非零失败数、
某入口没有可识别的测试数量、黑盒 PASS 标记缺失、保护文件变化、未清理的临时内容均使结果为 FAIL。
exit 0 仅表示完整 gate PASS；预期的 update 失败必须由 smoke 断言 exit 1，不能直接放宽阶段退出码。

所有 child test 的 TEMP/TMP 指向本轮随机工作区，方便发现并清理遗留文件。
清理和临时依赖目录移动前核对绝对路径范围，不触及其他测试或用户目录。

## 自定义测试及数量

`run.ps1`、`doctor.ps1` 使用真正的 cjc 编译生产源码副本及测试 main，再执行测试 exe；
其他 CLI 入口直接运行干净构建的生产 main.exe。没有为 cjpm test 迁移或重写框架。

| 正式入口 | 本次实际通过组数 |
|---|---:|
| run.ps1（scanner/value/planner/安全写入/事务） | 260 |
| doctor.ps1（32 单元 + 7 临时 CLI） | 39 |
| add_cli.ps1 | 24 |
| update_cli.ps1 | 9 |
| remove_cli.ps1 | 8 |
| remove_write_cli.ps1 | 20 |
| dry_run.ps1（缺少/禁止参数的组合检查） | 1 |
| 合计 | **361** |

此表是本轮结果，入口没有硬编码这些历史数字。统计各 runner 的 passed 汇总行，
doctor/dry-run 的 CLI 组合检查按 PASS CLI 行计数；SHA/文件保护断言、真实项目诊断、
新 smoke 操作不再混入自定义用例数，避免重复统计。原有 360 组之外，已有 dry_run.ps1 的
一组参数组合检查也纳入了正式入口，并非新增业务用例来凑数。

`cjpm test` 实际 exit 0、`Summary: TOTAL: 0`；0-test 情况仍存在，作为 INFO 记录。
任何人都不应把它的成功退出码解释为上述 361 组已经运行。

## 黑盒与回滚

`tests/smoke.ps1` 使用新的随机临时目录，官方 init app/foo/bar。
帮助和版本、doctor/list/dry-run 均直接调用生产 exe，不使用 cjpm run。
写盘测试只针对临时项目。读取完整元数据为 Base64 字节表示做相等断言，不用 stdout 代替内容证明。

为防止“Hello World build 成功但没有真的链接依赖”，第一次消费者构建前写入 import foo 和函数调用，
构建成功后才运行产物，必须输出 foo。remove 后恢复临时 Hello World 并 clean/build。
首轮独立验收日志是固定取证快照并包含工具链负面实验，不能直接作为可重复 PASS gate；
本 smoke 保留其中关键的可靠黑盒流程，不复制复杂负面探针或历史夹具。

失败回滚：有效 foo/bar 项目先通过 check/build；add 不存在的 Path 必须失败并恢复两份元数据；
暂时移走 bar 后 remove foo 必须失败并恢复元数据，再由测试恢复外部 bar 目录，check/build 成功。
外部依赖目录恢复由测试完成，不归功于 CJX。Git 不做联网验证。

## README 风险说明

- 同等级验收范围仅 Windows、Cangjie 1.0.5、CJPM 1.0.5；验证入口使用 PowerShell 7。
- 中文 UTF-8 配置内容可读取、扫描、保真写回，有测试覆盖。
- 部分中文 CLI argv 受 Windows / SDK 1.0.5 runtime 限制，可能在 main 前异常，不能误写成 CJX 不支持中文。
- 已构建项目新增 import 后的官方链接异常可先手动 clean/build；正式 gate 始终 clean，失败构建后不能运行旧 exe 证明成功。
- SDK/runtime DLL 是启动前提；CJPM 1.0.5 --version 也依赖 cjc。

`doctor.ps1`、`remove_cli.ps1`、`dry_run.ps1` 的本机 practice 路径改为可选 -PracticeRoot。
默认验证不用开发者拥有别人的练习目录；指定参数只增加只读检查，不改变命令业务设计。

## 调试过程的失败记录

首次 gate 用过宽的文本匹配把 `PASS 20 failed save` 测试名称误当失败；已改为明确 FAIL 行、
汇总失败数与退出码，原始记录保留。之后发现启动器重复 Path/PATH 引起的一次 DLL 启动失败、
重定向 PowerShell 中文输出按 OEM 解码导致一次旧 CLI 断言失败；入口明确传递有效 PATH、
设置 UTF-8 后完整 suite 通过。没有关闭断言、跳过中文测试或修改 SDK。

缺少 SDK 的独立负面运行实际返回 exit 1，RESULT FAIL、保护及清理均 PASS；
见 [missing-sdk-summary.json](verification-gate-evidence/missing-sdk-summary.json)。
带真实 practice 参数的完整正面运行返回 exit 0，361 组及全部黑盒阶段 PASS，
见 [pass-with-practice-summary.json](verification-gate-evidence/pass-with-practice-summary.json)。

本阶段未发现阻塞 Phase 10 的新业务缺陷，已知工具链限制仍需按限定范围说明，不声称修复。

## 最终执行结果（2026-10-05）

最终默认入口 `tests/verify.ps1` 再次从 clean 开始，实际退出码 **0**、RESULT **PASS**，
361 组自定义检查、官方零发现记录、CLI smoke、Integration、Rollback、保护及清理全部完成。
见 [final-pass-summary.json](verification-gate-evidence/final-pass-summary.json) 与
[final-verify.log](verification-gate-evidence/final-verify.log)。日志中 13 个顶层原生/测试入口调用均 exit 0，
smoke 内预期失败的两次 update 操作则明确要求 exit 1。

临时工作区已不存在；所有测试 runner 没有留下本轮临时内容。
再对照独立验收时的原始指纹，13 个生产源码文件、CJX/practice 的 TOML/lock 均完全一致。
本阶段改动：新增 verify.ps1 / smoke.ps1；三个只读验证脚本增加可选 PracticeRoot；
README 和本说明更新；保留最终及调试证据。没有新增业务功能或修改 SDK。
