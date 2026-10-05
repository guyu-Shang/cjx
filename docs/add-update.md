# Phase 7D：自动 update 与元数据回滚

默认 `cjx add foo --path ../foo`：安全写入 TOML，自动执行 `cjpm update`，成功后报告
`Added dependency successfully.`。Git、branch、tag、commit-id 继续沿用已验证规则。
CLI 不调用 check/build，不实现 remove、central/version add 或 search。

| 选项 | TOML | lock | 运行 CJPM |
|---|---|---|---|
| 默认 add | 安全写入 | 由 CJPM update 刷新 | update |
| --no-update | 安全写入 | CJX 不修改 | 否 |
| --dry-run | 不写 | 不写 | 否 |
| --dry-run + --no-update | 不写，dry-run 优先 | 不写 | 否 |

重复选项拒绝；选项不能占据 path/git/selector 的值位置。no-update 成功明确输出
`Dependency was added to cjpm.toml.` 和手动刷新 cjpm.lock 的提示，不声称 update 已完成。

## Runner 与实际 API

`runCjpmUpdate(projectRoot): CjpmUpdateResult` 位于 cjpm_runner.cj，返回 exitCode、stdout bytes、stderr bytes。
本机 Cangjie 1.0.5 实际编译验证：

```cangjie
execute(executable.toString(), ["update"], workingDirectory: Some(root),
    stdIn: ProcessRedirect.Discard,
    stdOut: ProcessRedirect.FromFile(outFile),
    stdErr: ProcessRedirect.FromFile(errFile))
```

- std.env.getVariable 读取 PATH；Windows 按分号查找普通文件 cjpm.exe，canonicalize 成绝对路径。
  不使用 cmd /c，不修改 PATH，不运行 envsetup.ps1，不优先从当前目录搜索。
- std.process.execute 直接启动 executable，使用项目根目录作为子进程 cwd；不改变 CJX 本身 cwd。
- stdout/stderr 分别重定向到项目下独立临时捕获目录中的两个文件；等待退出后读取完整 bytes，关闭并清理。
  采用文件重定向以避免等待期间两条管道写满。实际子进程两路各约 300 KB 输出测试通过。
- 输出按 UTF-8 解码；非法 UTF-8 的非 ASCII 字节展示为 \xNN，原始 bytes 保留在结果中，不静默丢弃。
- 成功时只显示 Updating 与简短完成信息；非零退出码时显示退出码及 stdout/stderr 有价值的错误内容。
- 缺失可执行文件、非普通文件或进程 API 启动/等待异常会提示 unable to start cjpm 和加载 SDK 环境的建议。
  若 main.exe 自己就因 runtime DLL 环境缺失而无法进入 main，CLI 无法捕获该启动前错误。

本机损坏 EXE 的故障探测出现 Windows 层阻塞，已终止测试并移除该用例；未更换 SDK。
最终启动失败覆盖缺失路径、目录代替 executable、受控启动异常；不宣称所有损坏 SDK 场景都不会阻塞。
runner 当前同步等待、无额外超时；网络/Git 长时间等待不在本阶段新增的控制范围。
PATH 查找采用 Windows 规则，尚未实现 Linux/macOS executable 搜索。

## 快照、提交和成功

1. 复用 parse/find/read/plan/内存验证，dry-run 在任何快照或写入前返回。
2. 正式写入前排他创建 `.cjpm.toml.cjx-add`，持有至 update/回滚结束，阻止其他同一协议的 CJX add 并发。
3. 重新比对原 TOML，保存完整 `cjpm.toml.original`；保存 lock 是否存在的 `lock-state`。
   原 lock 存在时还保存完整 `cjpm.lock.original`，均在新建目录中写入、关闭并读回验证。
4. 复用 safeReplaceFile 提交 add plan，原有临时文件、外部变化、扫描及语义验证保留。
5. CLI 独立读回并验证 TOML；no-update 至此成功并清理操作快照。
6. 默认模式再比对 lock 与操作前快照，启动前已观察到外部变化则不运行 update。
7. runner 执行 CJPM update。退出 0 后再次核对 TOML 与 committed plan 的完整字节和依赖语义，读取 lock 检查实际文件类型。
8. 两部分成功才报告完整 add 成功，清理快照。清理失败报告警告及遗留路径，不盲目重试。

正常成功不会长期留下备份；失败冲突时保留原始快照与操作锁，不能盲目删除后强行重试。
手动恢复前需检查目标当前内容，决定保留用户修改还是原始版本。原 lock 缺失以 lock-state=absent 记录。

## 失败回滚

update 非零、启动/等待异常或 update 后 TOML 验证失败时返回 1，尝试恢复两个元数据文件。
保留 CJPM 错误或启动原因；仅两份状态均最终读回匹配原快照时输出 `Project files were restored.`。

TOML 当前必须仍等于本次 committed bytes，才用 safeReplaceFile 恢复原 bytes。
若外部修改/删除/变目录，则不覆盖，报告 changed externally 和快照目录。

lock 在 update 结束时读取一次观察状态，实际恢复前再次核对该状态；启动前就发现变化时使用操作前基线，避免把外部版本归为 update 结果。

| 操作前 lock | 回滚观察状态 | 恢复策略 |
|---|---|---|
| 存在，且未变 | 相同 bytes | 不额外写入 |
| 存在 | 不同 bytes | 复用 safeReplaceBytes 事务恢复原 bytes |
| 存在 | 被删除 | 同目录 temp 写原 bytes、读回验证、不覆盖 rename 创建 |
| 不存在 | 不存在 | 不操作 |
| 不存在 | 新文件 | 校验当前版本、移到受保护 staging、再次比较后删除；最终验证缺失 |
| 任意 | 恢复前又变了、变目录/符号链接 | 拒绝覆盖/删除，保留恢复快照 |

safeReplaceBytes 与原 safe write 使用同一个事务主体，关闭 dependencies scanner：lock 是 opaque bytes，
不应为了恢复 lock 强行使用 dependencies parser。原 safeReplaceFile 的 UTF-8/scanner 默认规则不变。

恢复独立尝试两个文件：可能一个恢复、另一个冲突。此时明确报告回滚未完成，保留两份原始快照，不报告整体成功。
恢复自身失败同样保留快照和底层引擎的恢复位置。所有状态比较基于完整 bytes，包含 BOM、CRLF、中文及末尾换行。

## 保证边界

CJX 尝试在程序级失败下让 cjpm.toml + cjpm.lock 一起成功或一起恢复。
无法回滚 CJPM 全局 cache、已下载 Git 仓库、远程网络副作用；不保证突然断电、OS crash 或系统级原子性。
操作目录与每文件事务锁只约束采用相同协议的 CJX；其他工具可能不遵守。

特别是 lock：**update 运行期间的字节变化不能仅靠结果判断来自 CJPM 还是其他进程**。
当前可检测启动前变化、update 结束后至恢复时的变化，并拒绝已观察到的冲突；
无法对运行期间的所有外部 lock 写入提供来源归属或绝对保护保证。重读检查也不是操作系统级 compare-and-swap。
这些限制不被“恢复完成”的测试结果掩盖，后续加强需要 OS 支持或外部工具协作。
原双 rename 暂缺窗口、fsync 缺失、文件身份/ACL 等边界继续见 [安全写入说明](safe-write.md)。
中文 CLI 参数的既有 runtime 问题未修改；中文文件 bytes 恢复已覆盖。

## 测试与结果

格式化后 `cjpm build` 成功，无警告。原 **205 组通过**，新增 **32 组通过**，共 **237 组**。
原 Phase 7C 只写入/Git 离线测试显式使用 no-update 保留原覆盖，避免默认 update 对虚构 Git URL 访问公网。

```powershell
cjpm build
.\tests\run.ps1        # 原 181 + 23 个 update/runner/rollback 场景
.\tests\add_cli.ps1    # 原 24 个 CLI 场景（写入场景用 --no-update）
.\tests\update_cli.ps1 # 新增 9 个真实 CJPM 场景
.\tests\dry_run.ps1    # CJX / practice，TOML 与 lock 哈希/存在状态比较
```

| 新增 Cangjie 测试 | 结果 |
|---|---|
| 01–04 | update 成功生成/更换 lock、no-update、dry-run 优先通过 |
| 05–08 | 非零退出、原 lock 精确恢复、新 lock 删除、被删除原 lock 重建通过 |
| 09–12 | update/回滚时外部 TOML 修改、回滚时外部 lock 修改保留，启动异常恢复通过 |
| 13–15 | runner 缺失/非文件错误，真实子进程 cwd/update 参数/exit=7/双路输出捕获通过 |
| 16–18 | 回滚自身失败保留快照、空 PATH 报环境错误、未变 lock 跳过写入通过 |
| 19–23 | 操作锁、选项组合、lock 变目录、exit=0 但 TOML 外部变化拒绝成功、update 前 lock 外部变化通过 |

空 PATH 仅在测试进程中临时设置并在 finally 恢复；产品源代码只读取环境变量，不设置环境。

| 新增真实 CLI 测试 | 结果 |
|---|---|
| 01–03 | 真实 Path add 自动 update 生成 lock、已有 lock 刷新、连续两个合法 Path add 通过 |
| 04–05 | no-update 改 TOML 不动原 lock、dry-run+no-update 两份均不动通过 |
| 06–07 | 真实缺失 Path update 退出 1，TOML 恢复，lock 原先存在/缺失均恢复准确通过 |
| 08–09 | no-update 不生成新 lock、从 src 执行但 update 在项目根目录通过 |

真实 CJPM 1.0.5 的 Path lock 实测为 `version = 0` 与 `[requires]`，不把“必须包含 foo 路径条目”当作验收条件。
真实缺失 Path 失败发生在依赖验证阶段，未新建 lock；失败生成/改写/删除 lock 的路径用受控 updater 注入验证。
所有写入和 update 均在独立临时项目，无公网 Git 测试，测试目录与原始故障探测目录已清理。

成功输出：

```text
Updating dependencies...
Added dependency successfully.

  foo = { path = "../foo" }

Updated:
  ...\app\cjpm.toml

Dependencies updated successfully.
```

真实失败输出：

```text
Updating dependencies...
Error: cjpm update failed (exit 1).
CJPM:
  Error: the path '../missing' of module 'missing' does not exist ...
  Error: cjpm update failed
Project files were restored.
```

practice 仅 dry-run，TOML 前后 SHA-256：
`EA5F1F8F88788B0588A68D1C0021ACA79AB4DA4FEEAC58830DED5375B2EB7E53`。
practice 和 CJX 的 lock 均保持原存在状态/哈希 `7B09643CC3E7107D2A0F09605871366C547525D40221945A60BEE8A9A5E3F3B0`。
CJX TOML 仍为 `57766ACE28A83E1073987FB8BBA28431987FD2B5DA5309058E46BCB392292F2C`。

生产代码共 **11 个文件、1953 行**。在上述明确保证范围内，add 已具备 V0.1 完整流程。
未开始 remove。
