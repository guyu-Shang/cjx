# Phase 7C：正式 add 与 dry-run

本文为 Phase 7C 历史记录。Phase 7D 起默认 add 自动 update；保留本阶段的仅写入行为需加 `--no-update`。
见 [当前 add/update 契约](add-update.md)。原 24 组写入测试及 9 组失败接入测试已显式使用 no-update 保留原覆盖范围。

```text
cjx add foo --path ../foo
cjx add foo --git https://example.com/foo.git --branch main
cjx add foo --git https://example.com/foo.git --tag v1 --commit-id abc123
cjx add foo --path ../foo --dry-run
```

默认真实写回最近的 cjpm.toml；`--dry-run` 只预览。
可在 name 之后的选项位置使用 dry-run，如 `add foo --dry-run --path ../foo`。
重复 dry-run 拒绝；它不接受值，也不能占据 path/git/selector 的值位置。
没有 force/apply/yes，也不支持 package@version。
继续采用已验证的名称与 Git selector 规则，见 [Phase 7A](add-dry-run.md)。

## 实现与验证顺序

1. `parseAddCommand` 解析 CLI-only dry-run 标志，委托原 `parseAddRequest` 校验依赖请求。
2. `findCjpmToml` 定位，`readCjpmToml` 安全读取完整 UTF-8 文本。
3. `planAdd` 原有扫描、重名检查、插入规划、重新扫描、语义及非修改区字节验证全部保留。
4. dry-run 显示相同 plan 并返回，不调用 writer，也不创建事务文件。
5. 正式 add 将 original.toArray() 与 plan.modifiedText.toArray() 传给 `safeReplaceFile`。
   UTF-8 decode/re-encode 保留原字节、BOM 和换行，不做编码转换或规范化。
6. 共用 `validateAddResult(original, modified, request)`：从原 planner 提取，而非维护另一套解析器。
   确认新条目 name/source/spec、数量 +1、所有旧条目 key/rawValue 保留。
7. 该函数作为引擎 validator，在预检、临时文件与最终磁盘内容上运行。
8. 引擎返回后，CLI **再次独立读取最终文件**，验证全部字节等于 plan，并重跑共享语义验证。
9. 全部通过才输出 Added/Updated 和手动 cjpm update 提示。

CLI 未调用任何进程 API，不执行 cjpm update/check，不 clone Git，不验证路径实际存在。
Git 成功表示声明已写入并验证，不代表远程仓库可访问或依赖已下载。

## 输出与退出码

| 情况 | 输出/行为 | 退出码 |
|---|---|---|
| 参数错误 | Error + 缺失/冲突/未知/重复选项原因 | 2 |
| 读取失败 | Error: failed to read cjpm.toml + 原因 | 1 |
| scanner 不支持或 malformed | 保留 scanner 原因，写入前拒绝 | 1 |
| dependency 已存在 | Error: dependency 'foo' already exists. | 1 |
| 原内容变化 | changed since the operation started；不覆盖外部版本 | 1 |
| 临时写入、验证或 commit 失败 | safe write 阶段 + 根因 + 恢复信息 | 1 |
| recovery 失败 | SERIOUS + 恢复文件位置和目标位置 | 1 |
| CLI 最终复查失败 | SERIOUS: final add verification failed；不打印 Added | 1 |
| 已提交但清理失败 | 最终验证成功后输出 Added，附 Warning/遗留位置；不要盲目重试 | 0 |
| 正常 add / dry-run | Added 或 Dry run | 0 |

错误不打印异常堆栈；通过 displayCell 阻止解码后的控制字符扰乱终端。
如果引擎已返回、备份已清理，而后续 CLI 复查失败，则报告严重错误，不声称有可恢复备份。
不自动覆盖可能由外部工具新写入的内容。

## 集成测试结果

本机 Cangjie/CJPM 1.0.5：原 **172 组全部通过**。
新增 **33 组全部通过**：24 个真实可执行文件场景，9 个 CLI 与真实引擎的失败接入场景。
与原测试合计 **205 组**；另执行真实项目 dry-run 哈希检查。

```powershell
cjpm build
.\tests\run.ps1       # 原 172 + 新增 9
.\tests\add_cli.ps1   # 新增 24
.\tests\dry_run.ps1   # CJX / practice 只读哈希验证
```

| 真实 CLI 测试 | 覆盖 |
|---|---|
| 01–06 | Path、Git、branch、tag、commitId、多个 selector；每次 add 后 list 验证 source/spec |
| 07–11 | dry-run SHA 不变、已存在依赖、无 section、空 section、空文件 |
| 12–18 | LF、CRLF、BOM、中文文件内容、Windows path、空格路径、无末尾换行 |
| 19–20 | 连续 add 两个不同依赖、再次 add 同名拒绝且哈希不变 |
| 21–23 | malformed/unsupported、既有锁拒绝、dry-run 选项位置 |
| 24 | cjpm init 生成真实主项目与本地依赖，add/list 后手动 cjpm check --skip-script 成功 |

| 失败接入测试 | 覆盖 |
|---|---|
| 01–03 | 实际引擎检测外部修改、注入 temp 写入失败、replacement+recovery 失败及备份路径显示 |
| 04–06 | 引擎返回后外部改动不打印成功；dry-run 不调用 writer；共享 validator 检查旧依赖保留 |
| 07–09 | 已提交清理 Warning、dry-run 参数校验、最终文件非法 UTF-8 不打印成功 |

失败测试通过 `addProjectDependency` 的内部 writer 参数接入真实引擎 hook，不暴露 CLI 开关，
不依赖公网、磁盘耗尽或真实项目改写。所有真实写入和失败恢复都在独立临时目录，结束后清理。
真实 CLI 场景还检查无事务遗留，且 add/list 不创建 cjpm.lock，避免暗中调用 CJPM。

临时项目实际输出（目录由测试随机生成，现已清理）：

```text
Added dependency:

  foo = { path = "../foo" }

Updated:
  C:\Users\33\AppData\Local\Temp\cjx-cli-tests-e299efc105e441adaef6e14d6487a7ea\case-24\app\cjpm.toml

Run `cjpm update` to refresh dependencies.

Dependencies
------------------------------------------------------------
NAME  SOURCE     SPEC
foo   path       ../foo

1 dependency

cjpm check success
```

practice 仅执行 `add testdep --path ../test --dry-run`，前后 SHA-256 完全相同：

```text
EA5F1F8F88788B0588A68D1C0021ACA79AB4DA4FEEAC58830DED5375B2EB7E53
```

CJX 真实配置也仅 dry-run，哈希仍为
`57766ACE28A83E1073987FB8BBA28431987FD2B5DA5309058E46BCB392292F2C`。
`cjpm build` 成功，无警告；生产源码仍是 9 个文件，当前共 1470 行。
未发现新的 1.0.5 API 兼容问题。中文 CLI 参数的既有 runtime 限制保留，未修改 SDK/runtime。

## 事务保证和下一阶段

在本阶段明确授权的范围内，add 已通过正常流程及程序级失败测试，可以继续规划 Phase 7D。
写入引擎可以检测已观察到的外部内容变化，处理普通写入/内容验证/replacement 失败和可恢复异常。
保证边界继续遵循 [写入引擎说明](safe-write.md)：

- 不承诺突然断电的磁盘持久性或 OS 崩溃瞬间的原子替换。
- 不承诺完全排除不遵循 CJX lock 的进程竞争；重读不是系统级 compare-and-swap。
- 双 rename 间可能暂缺目标路径；恢复失败保留备份并报告路径。
- 不承诺保留文件身份、ACL、全部元数据或硬链接关系。

本阶段未实现 remove、central/version add、update/check 自动调用，也未继续 Phase 7D。
