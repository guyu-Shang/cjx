# CJX V0.1 独立验收报告

验收日期：2026-10-04。本轮暂停 Phase 10，没有改动生产源码、现有测试、SDK、真实项目配置，没有新增业务功能。

## 结论

**核心功能验收：PASS（有环境与工具链限制）。** 在已加载官方 SDK 环境的 Windows、Cangjie 1.0.5 / CJPM 1.0.5 上，直接运行干净构建的 exe，Path 依赖的 list / doctor / add / remove、dry-run、真实 update 失败后的元数据回滚均得到独立验证。实际 import 依赖的全新消费者也成功编译、链接并输出 `foo`。

**“任意环境下均可运行、所有历史测试已由 cjpm test 执行、改代码后任意 build 都可靠”的无条件发布结论：FAIL。** 这些结论不符合本机证据。发现两项可脱离 CJX 复现的工具链问题和几项测试盲区，详见下文。

没有发现本轮必须修改 CJX 业务代码才能解决的阻塞缺陷。可以进入限定 Windows / SDK 1.0.5 范围的发布收尾，但发布前必须明确运行环境、中文 argv 限制、官方构建异常的恢复步骤，以及真正运行自定义测试的方法。本轮没有继续 Phase 10，也没有实施这些后续调整。

本次不是对所有 Git 远程、所有 TOML 语法、并发竞争、断电持久性或其他 SDK 版本的认证。

## 方法与证据

所有业务黑盒调用均直接启动 `C:\sourse\cj\cjx\target\release\bin\main.exe`，不使用 `cjpm run`。Native ProcessStartInfo 使用独立 argv、显式 cwd、并行收集 stdout/stderr，保存实际退出码。没有把 shell 最后一条成功命令当作子进程成功。

使用四批全新、随机命名的临时工作区，项目均由官方 `cjpm init` 创建，不复用历史夹具。每条原生命令记录 TOML / lock 前后存在性、完整文本、Base64 原始字节、SHA-256。对关键回滚还比较字节表示；指纹不是唯一依据。失败记录保留，后续对照不覆盖它们。

| 批次 | 原生命令数 | 日志 |
|---|---:|---|
| 首轮独立验收 | 40 | [逐条命令与退出码](evidence/commands.md)、[完整字节与输出快照](evidence/summary.json) |
| 纯官方 / CJX、含空格路径对照 | 24 | [命令](follow-up/commands.md)、[快照](follow-up/summary.json) |
| 已构建项目新增 import 对照 | 23 | [命令](cache-control/commands.md)、[快照](cache-control/summary.json) |
| 纯 SDK Unicode 探针、真实项目只读检查 | 9 | [命令](final-checks/commands.md)、[快照](final-checks/summary.json) |

合计 **96 条原生命令**。各批次的 `NNN.stdout.txt` / `NNN.stderr.txt` 保留完整输出，`commands.jsonl` 保留结构化记录。文末附全部原生命令、cwd、退出码。负面测试的 exit 1 是预期失败，不算功能失败。

运行验收脚本的命令如下；四次 PowerShell 调用均正常结束，业务子命令的失败独立记录，不由脚本整体成功掩盖：

```powershell
& ./docs/acceptance/run-independent.ps1 -SdkRoot 'C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie'
& ./docs/acceptance/run-control.ps1 -SdkRoot 'C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie'
& ./docs/acceptance/run-cache-control.ps1 -SdkRoot 'C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie'
& ./docs/acceptance/run-final-checks.ps1 -SdkRoot 'C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie'
```

脚本只在测试进程中点加载 SDK 官方 `envsetup.ps1`。没有修改 User/Machine PATH，没有升级 SDK。每个临时目录清理前检查绝对路径属于本次随机工作区；四个工作区最后均不存在。

## 干净构建：PASS

首轮 001 / 002：`cjc --version`、`cjpm --version` 均 exit 0，实际显示 1.0.5。003：`cjpm clean` exit 0，旧 exe 不存在、target 剩余文件数为 0。004：`cjpm build` exit 0，重新生成 exe。

- 旧 exe SHA-256：`8D9B89500887868841CA314D00061CCBF32C8721587EC166DD7834E26177C41A`
- 新 exe SHA-256：`F652AD338FB75F2E1006B7391690DFD968E58E7011A84A9EB36438247B36465D`
- 随后 `cjpm test` 后 exe 指纹仍等于新 exe。

这证明清理后重新生成了当前项目构建产物。没有删除 SDK 库或 CJPM 全局缓存；CJX 本身没有第三方依赖，因此没有借助缓存的第三方包来完成此次项目构建。不是“所有机器级缓存均已清空”的证明。

## 全新项目的完整链路：PASS

新建 executable `acceptapp` 和 static `foo`；没有在真实 CJX/practice 上执行 add/remove。

| 首轮 ID | 操作 | exit | 独立观察 |
|---|---|---:|---|
| 009–010 | exe --help / --version | 各 0 | 帮助可见，版本 cjx 0.1.0 |
| 011 | doctor | 0 | cjc/CJPM 1.0.5；缺 lock 仅 WARN |
| 012 | list | 0 | 0 dependencies |
| 013 | add foo --path ../foo --dry-run | 0 | TOML 字节不变，lock 仍不存在 |
| 014 | add foo --path ../foo | 0 | 真正添加声明；update 成功；lock 创建 |
| 015 | list | 0 | foo / path / ../foo |
| 016–017 | cjpm check / build | 各 0 | 官方接受配置、默认消费者可构建 |
| 018 | remove foo --dry-run | 0 | TOML / lock 均不变 |
| 019 | remove foo | 0 | 声明删除；update 成功；保留空 section |
| 020 | list | 0 | 0 dependencies |
| 021–022 | cjpm check / build | 各 0 | 删除后官方检查、构建成功 |

默认 Hello World 没有 import foo，因此上述 build 本身只证明该消费者能构建，**不能证明依赖函数参与链接**。为此追加了实际 `import foo.*`、调用 `message()` 的新项目对照：纯官方手工声明和 CJX add 声明，在有空格 / 无空格路径中均 check/build 成功，生成的消费者直接执行 exit 0、输出 `foo`。Verbose 输出包含 foo 静态库编译及消费者 `-L ...\foo -lfoo` 链接参数。

关键元数据：

| 状态 | TOML SHA-256 | lock |
|---|---|---|
| 初始化 | `93F40FC23A6A5E90FE8BFDCFEEB94A435573457D9C74E288EB3E415DCA1A14D6` | 不存在 |
| add 后 | `A72A78445EEFDD805DB310D9B1CEE1A65BF658A37874591181284F77EE619DE3` | 存在，SHA `7B09643CC3E7107D2A0F09605871366C547525D40221945A60BEE8A9A5E3F3B0` |
| remove 后 | 恢复初始化 TOML 指纹、字节 | lock 保留且 SHA 不变 |

此处实际 lock 为 24 字节：`version = 0`、空 `[requires]`。**这些 Path 依赖的成功 add/remove 并不导致 lock 内容每次变化**。不能用“lock SHA 必须改变”作为 update 成功的通用判据。

## 真实 update 失败与回滚：PASS

另一个新项目先实际 add foo、add bar，并通过官方 check/build（首轮 027–030），建立可用基线。

1. `add missing --path "../does not exist"`，首轮 031，exit **1**。不是伪 runner：真实 CJPM 报路径不存在、update failed。TOML / 现有 lock 的存在性、原始字节、SHA 与操作前一致。随后官方 check/build（032–033）均 exit 0。
2. 将独立临时 bar 目录暂时移走，然后 `remove foo`，034，exit **1**。真实 CJPM 因剩余 bar 不可访问而 update failed；TOML / lock 恢复操作前字节。再由验收脚本恢复外部 bar 目录，官方 check/build（035–036）均 exit 0。

第二项必须区分：**CJX 恢复项目元数据，验收脚本恢复外部依赖目录**。CJX 没有修复用户删除/移动的外部目录；外部故障仍在时，不能声称项目已经恢复可构建。

两次失败前后的 TOML 均为 `6DF572F9367550753339DEB5C04C7173EBDB9BDD4E3AEC6E25926FEAC57660B7`，lock 均为 `7B09643CC3E7107D2A0F09605871366C547525D40221945A60BEE8A9A5E3F3B0`。完整 Base64 与文本位于首轮 031 / 034 的 Before/After。没有仅凭“Project files were restored”日志判定成功。

## 环境与 cwd：PASS，但存在必要前提

- SDK 环境正确时直接 exe 可运行、版本正确。
- 仅在子进程 PATH 中隐藏两项工具：doctor exit 1，SDK/CJPM 均 ERROR。
- 保留 cjc、隐藏 cjpm：doctor exit 1，SDK OK 1.0.5、CJPM ERROR。
- 保留 cjpm、隐藏 cjc：doctor exit 1，SDK ERROR；**CJPM --version 也失败**，底层原因是无法运行 `cjc -v`。实际 CJPM 1.0.5 版本查询依赖 cjc，不能用假的版本闭包假定二者独立。
- 测试保留运行时 DLL 搜索路径，隐藏的是工具 exe；没有刻意制造 DLL 缺失弹窗。未加载完整 SDK 运行环境时 exe 能否启动，是运行时前提，不是 doctor 在 main 中能补救的问题。
- 无项目目录 doctor 仍完整检查环境，项目 ERROR，exit 1。
- 从 CJX/src 直接运行 exe list 向上查找正确，exit 0。
- 独立项目路径含空格 / 不含空格，两类实际依赖消费者均可全新构建。

源码检查未发现生产代码硬编码本机 SDK、practice、固定系统临时目录。工具发现采用 Windows PATH 的 `;`、`.exe`；这是 Windows V0.1 的明确实现范围。项目发现以当前 cwd 为起点是 CLI 契约。更新使用项目根目录 cwd，临时捕获也在项目目录，要求可写目录。官方默认产物名确实是 `main.exe`，还没有安装成 PATH 上的 `cjx` 命令，不能宣称“已全局安装”。

## 独立发现的问题

### 1. 已构建项目新增 import 的官方构建问题：FAIL，可恢复

最小纯官方对照，不调用 CJX：init app/foo → 声明 Path → update → build Hello World 成功 → 改 main 加 `import foo.*` 和调用 → build exit 1，undefined symbol。再次 build -V 仍 exit 1；clean exit 0 → build -V exit 0 → exe 输出 foo、exit 0。

同样的流程经过 CJX add/remove/re-add 也复现。证据为 cache-control 005–009 和 018–022。全新首次构建已有 import 的对照全部成功，因此不是目录含空格，也不是生成 TOML 不合法。

**能够确认问题在纯官方工具链流程中存在，且清理构建状态可恢复；没有调查工具链内部根因，不能断言具体是哪一个缓存算法。** CJX 不负责重新实现或修复 CJPM build。本轮没有自动 clean、修改 SDK 或业务代码。

首轮 024 构建失败后，验收脚本仍运行了已有 exe（025 exit 0，输出旧 Hello World）。这是验收脚本的错误判据和工具链保留旧产物的实际表现；该执行不算新代码成功。后续对照只在本次构建成功后运行产物。

### 2. 中文 argv 运行时异常：FAIL，工具链限制

CJX `add ... --path ../中文目录 --dry-run` exit 1，出现 `IllegalArgumentException: Invalid unicode scalar value`，元数据不变。

独立编译只有 main(args)、首先打印 `ENTERED_MAIN` 的最小程序：ASCII argv exit 0、进入 main；中文 argv exit 1、出现相同异常、没有入口标记。证据 final-checks 001–003。因此不是 CJX planner 或 TOML 编码逻辑造成。本轮不宣称支持此类直接中文 argv，也没有修改 runtime。

本次中文 argv 测试不能替代中文文件内容的读写验证；后者历史测试存在，本轮不以 argv 结果否定它，也不冒称本轮重新覆盖了所有编码场景。

## 当前测试体系的真实性与盲区

`cjpm test` 首轮 040 exit 0，**Summary: TOTAL: 0**，PASSED/FAILED 均 0。这是零发现结果，不是已有几百组测试通过。

现有 `tests/run.ps1` 把实际生产 `.cj` 源码复制到每轮独立临时目录，配上测试 main，再用真实 `cjc -p` 编译执行；CLI PowerShell 脚本则运行构建产物、核对文件和退出码。这些测试确实编译生产逻辑，并非只测试另写的模型，但使用自定义 main 而没有官方 unittest 发现入口，所以不属于当前 `cjpm test` 发现的测试。

本轮评估了这些脚本与源码，没有为了形式迁移测试，也没有把历史“360 组通过”当作本轮重新运行的结论。本轮结论来自上述 96 条独立原生命令。现有测试与独立黑盒互为补充，不能互相代替。

发现/修正的盲区：

1. 默认 Hello World build 成功不能证明依赖实际参与链接；追加真实 import 消费者。
2. 从已经不可构建的夹具出发验证 remove 回滚，不能证明恢复可用项目；此次先建立有效基线再制造外部故障。
3. CJPM/cjc 版本查询被 mock 为独立关系不符合本机实际行为。
4. 失败构建后旧 exe 仍可执行，exit 0 不证明新源码构建成功。
5. 官方 test 零发现仍 exit 0，应检查用例数量。
6. lock 在合法 Path 操作后可能保持原字节，不应强制要求 hash 改变。
7. 本轮没有网络 Git 拉取、并发竞争/崩溃恢复、UNC/映射盘/目录链接、其他 SDK 版本的独立验收。

首轮原始日志含 5 个 FAIL，均保留：build stdout 未提 foo 的过强判据；真实 import 链接失败；误运行旧 exe；错误假定 CJPM --version 不依赖 cjc；错误按字面匹配官方零测试输出。后两项由实际输出纠正；链接失败由纯官方对照定位，不能删除原始 FAIL 后宣布“从未失败”。

## 真实文件与源码保护

真实 CJX/practice 最终 list / doctor 均 exit 0，仅只读。CJX：0 dependencies；practice：`cui / path / ../CangjieCUI`，doctor 发现路径存在，两者 SDK/CJPM 1.0.5，All checks passed。具体输出位于 final-checks 004–008。

| 文件 | 验收前后相同 SHA-256 |
|---|---|
| CJX cjpm.toml | `57766ACE28A83E1073987FB8BBA28431987FD2B5DA5309058E46BCB392292F2C` |
| practice cjpm.toml | `EA5F1F8F88788B0588A68D1C0021ACA79AB4DA4FEEAC58830DED5375B2EB7E53` |
| 两个真实 cjpm.lock | `7B09643CC3E7107D2A0F09605871366C547525D40221945A60BEE8A9A5E3F3B0` |

全部 13 个生产源码文件（含空行共 2518 行）的前后 SHA 相同。新增内容仅为本验收目录的脚本、报告和证据；target 按要求清理并重建。没有改 README 或现有测试，没有执行真实项目的 update/add/remove。

补充逐字节验证读取已保存的 Base64 快照、解码成 byte 数组、逐项比较，不依赖 SHA 唯一判据：[byte-verification.json](byte-verification.json)。两项 dry-run、两项失败回滚的 TOML/lock，以及 add/remove 往返后的初始化 TOML，全数一致。

## 发布前必须解决的结论/流程问题

- 明确 SDK envsetup 与运行时 DLL 前提、当前 Windows 范围及默认 main.exe 产物；不要把尚未安装的命令当作已安装。
- 明确中文 argv 的 1.0.5 限制；若发布承诺中文直接参数支持，则它是阻塞问题，须另立方案，当前不能声称完成。
- 将官方已构建项目新增 import 失败的可复现流程与手动 clean/build 恢复步骤写进发布限制；若要求无该工具链限制，则当前未满足。
- 发布验证必须显式运行已有自定义测试，而不是只运行 `cjpm test`；记录数量，禁止失败构建后运行旧 exe 作为成功证据。

在这些发布承诺与流程明确后，可以收尾有限范围 V0.1。若坚持无条件通过，则不能发布为“上述限制全部已解决”。**本轮到此停止。**

## 全部原生命令与退出码

以下从各批次原始日志直接附入，编号在各批次独立计数。JSON 保留 literal argv，Markdown 的命令列用于阅读，遇到空格应按 JSON argv 重放，而非直接复制未经引号的展示串。

### evidence

# Native command journal

Each stdout/stderr file and JSON metadata snapshot is keyed by ID.

| ID | cwd | mode | native command | exit |
|---|---|---|---|---|
| 001 | C:\sourse\cj\cjx | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\bin\cjc.exe --version` | 0 |
| 002 | C:\sourse\cj\cjx | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe --version` | 0 |
| 003 | C:\sourse\cj\cjx | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe clean` | 0 |
| 004 | C:\sourse\cj\cjx | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build` | 0 |
| 005 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe init --name acceptapp --type executable` | 0 |
| 006 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\foo | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe init --name foo --type static` | 0 |
| 007 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\bar | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe init --name bar --type static` | 0 |
| 008 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\failure app | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe init --name failureapp --type executable` | 0 |
| 009 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\sourse\cj\cjx\target\release\bin\main.exe --help` | 0 |
| 010 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\sourse\cj\cjx\target\release\bin\main.exe --version` | 0 |
| 011 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\sourse\cj\cjx\target\release\bin\main.exe doctor` | 0 |
| 012 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\sourse\cj\cjx\target\release\bin\main.exe list` | 0 |
| 013 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\sourse\cj\cjx\target\release\bin\main.exe add foo --path ../foo --dry-run` | 0 |
| 014 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\sourse\cj\cjx\target\release\bin\main.exe add foo --path ../foo` | 0 |
| 015 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\sourse\cj\cjx\target\release\bin\main.exe list` | 0 |
| 016 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe check` | 0 |
| 017 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build` | 0 |
| 018 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\sourse\cj\cjx\target\release\bin\main.exe remove foo --dry-run` | 0 |
| 019 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\sourse\cj\cjx\target\release\bin\main.exe remove foo` | 0 |
| 020 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\sourse\cj\cjx\target\release\bin\main.exe list` | 0 |
| 021 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe check` | 0 |
| 022 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build` | 0 |
| 023 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\sourse\cj\cjx\target\release\bin\main.exe add foo --path ../foo` | 0 |
| 024 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build` | 1 |
| 025 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app\target\release\bin\main.exe ` | 0 |
| 026 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | normal | `C:\sourse\cj\cjx\target\release\bin\main.exe remove foo` | 0 |
| 027 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\failure app | normal | `C:\sourse\cj\cjx\target\release\bin\main.exe add foo --path ../foo` | 0 |
| 028 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\failure app | normal | `C:\sourse\cj\cjx\target\release\bin\main.exe add bar --path ../bar` | 0 |
| 029 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\failure app | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe check` | 0 |
| 030 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\failure app | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build` | 0 |
| 031 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\failure app | normal | `C:\sourse\cj\cjx\target\release\bin\main.exe add missing --path ../does not exist` | 1 |
| 032 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\failure app | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe check` | 0 |
| 033 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\failure app | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build` | 0 |
| 034 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\failure app | normal | `C:\sourse\cj\cjx\target\release\bin\main.exe remove foo` | 1 |
| 035 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\failure app | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe check` | 0 |
| 036 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\failure app | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build` | 0 |
| 037 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | missing-both-tools | `C:\sourse\cj\cjx\target\release\bin\main.exe doctor` | 1 |
| 038 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | missing-cjpm | `C:\sourse\cj\cjx\target\release\bin\main.exe doctor` | 1 |
| 039 | C:\Users\33\AppData\Local\Temp\CJX independent audit 387c53f809f943cfbd1ee2977a8d3e47\app | missing-cjc | `C:\sourse\cj\cjx\target\release\bin\main.exe doctor` | 1 |
| 040 | C:\sourse\cj\cjx | normal | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe test` | 0 |

### follow-up

# Official-only control journal

| ID | cwd | native command | exit |
|---|---|---|---|
| 001 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\noSpaces\foo | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe init --name foo --type static` | 0 |
| 002 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\noSpaces\manual | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe init --name consumer --type executable` | 0 |
| 003 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\noSpaces\cjx | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe init --name consumer --type executable` | 0 |
| 004 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\noSpaces\manual | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe update` | 0 |
| 005 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\noSpaces\manual | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe check` | 0 |
| 006 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\noSpaces\manual | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build -V` | 0 |
| 007 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\noSpaces\cjx | `C:\sourse\cj\cjx\target\release\bin\main.exe add foo --path ../foo` | 0 |
| 008 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\noSpaces\cjx | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe check` | 0 |
| 009 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\noSpaces\cjx | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build -V` | 0 |
| 010 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\noSpaces\cjx | `C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\noSpaces\cjx\target\release\bin\main.exe ` | 0 |
| 011 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\noSpaces\foo | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build -V` | 0 |
| 012 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\noSpaces\manual | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build -V` | 0 |
| 013 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\with spaces\foo | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe init --name foo --type static` | 0 |
| 014 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\with spaces\manual | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe init --name consumer --type executable` | 0 |
| 015 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\with spaces\cjx | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe init --name consumer --type executable` | 0 |
| 016 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\with spaces\manual | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe update` | 0 |
| 017 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\with spaces\manual | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe check` | 0 |
| 018 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\with spaces\manual | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build -V` | 0 |
| 019 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\with spaces\cjx | `C:\sourse\cj\cjx\target\release\bin\main.exe add foo --path ../foo` | 0 |
| 020 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\with spaces\cjx | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe check` | 0 |
| 021 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\with spaces\cjx | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build -V` | 0 |
| 022 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\with spaces\cjx | `C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\with spaces\cjx\target\release\bin\main.exe ` | 0 |
| 023 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\with spaces\foo | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build -V` | 0 |
| 024 | C:\Users\33\AppData\Local\Temp\CJXauditControl_32166ffc349745199ba581db995ac184\with spaces\manual | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build -V` | 0 |

### cache-control

# Cache/source-change control journal

| ID | cwd | native command | exit |
|---|---|---|---|
| 001 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\official\foo | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe init --name foo --type static` | 0 |
| 002 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\official\app | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe init --name acceptapp --type executable` | 0 |
| 003 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\official\app | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe update` | 0 |
| 004 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\official\app | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build` | 0 |
| 005 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\official\app | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build` | 1 |
| 006 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\official\app | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build -V` | 1 |
| 007 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\official\app | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe clean` | 0 |
| 008 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\official\app | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build -V` | 0 |
| 009 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\official\app | `C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\official\app\target\release\bin\main.exe ` | 0 |
| 010 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\official\app | `C:\sourse\cj\cjx\target\release\bin\main.exe add cnprobe --path ../中文目录 --dry-run` | 1 |
| 011 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\cjx\foo | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe init --name foo --type static` | 0 |
| 012 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\cjx\app | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe init --name acceptapp --type executable` | 0 |
| 013 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\cjx\app | `C:\sourse\cj\cjx\target\release\bin\main.exe add foo --path ../foo` | 0 |
| 014 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\cjx\app | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build` | 0 |
| 015 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\cjx\app | `C:\sourse\cj\cjx\target\release\bin\main.exe remove foo` | 0 |
| 016 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\cjx\app | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build` | 0 |
| 017 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\cjx\app | `C:\sourse\cj\cjx\target\release\bin\main.exe add foo --path ../foo` | 0 |
| 018 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\cjx\app | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build` | 1 |
| 019 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\cjx\app | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build -V` | 1 |
| 020 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\cjx\app | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe clean` | 0 |
| 021 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\cjx\app | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\tools\bin\cjpm.exe build -V` | 0 |
| 022 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\cjx\app | `C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\cjx\app\target\release\bin\main.exe ` | 0 |
| 023 | C:\Users\33\AppData\Local\Temp\CJXCacheAudit_9ceacaaea23c4bcf806f6d38d7dacfb0\cjx\app | `C:\sourse\cj\cjx\target\release\bin\main.exe add cnprobe --path ../中文目录 --dry-run` | 1 |

### final-checks

# Final read-only and SDK argv controls

| ID | cwd | native command | exit |
|---|---|---|---|
| 001 | C:\Users\33\AppData\Local\Temp\CJXFinalAudit_19bc7b699acd4810b2c5f0f3aae32c2c | `C:\Users\33\Downloads\cangjie-sdk-windows-x64-1.0.5\cangjie\bin\cjc.exe C:\Users\33\AppData\Local\Temp\CJXFinalAudit_19bc7b699acd4810b2c5f0f3aae32c2c\probe.cj --output-dir C:\Users\33\AppData\Local\Temp\CJXFinalAudit_19bc7b699acd4810b2c5f0f3aae32c2c -o probe.exe` | 0 |
| 002 | C:\Users\33\AppData\Local\Temp\CJXFinalAudit_19bc7b699acd4810b2c5f0f3aae32c2c | `C:\Users\33\AppData\Local\Temp\CJXFinalAudit_19bc7b699acd4810b2c5f0f3aae32c2c\probe.exe ascii` | 0 |
| 003 | C:\Users\33\AppData\Local\Temp\CJXFinalAudit_19bc7b699acd4810b2c5f0f3aae32c2c | `C:\Users\33\AppData\Local\Temp\CJXFinalAudit_19bc7b699acd4810b2c5f0f3aae32c2c\probe.exe 中文` | 1 |
| 004 | C:\sourse\cj\cjx | `C:\sourse\cj\cjx\target\release\bin\main.exe list` | 0 |
| 005 | C:\sourse\cj\cjx | `C:\sourse\cj\cjx\target\release\bin\main.exe doctor` | 0 |
| 006 | C:\sourse\cj\practice | `C:\sourse\cj\cjx\target\release\bin\main.exe list` | 0 |
| 007 | C:\sourse\cj\practice | `C:\sourse\cj\cjx\target\release\bin\main.exe doctor` | 0 |
| 008 | C:\sourse\cj\cjx\src | `C:\sourse\cj\cjx\target\release\bin\main.exe list` | 0 |
| 009 | C:\Users\33\AppData\Local\Temp\CJXFinalAudit_19bc7b699acd4810b2c5f0f3aae32c2c | `C:\sourse\cj\cjx\target\release\bin\main.exe doctor` | 1 |
