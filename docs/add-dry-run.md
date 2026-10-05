# Phase 7A：纯内存 add

本文是 Phase 7A 的历史记录。Phase 7C 起 add 默认写入，预览必须显式加 `--dry-run`；见 [当前 add 文档](add-cli.md)。

`add` 只读取配置、生成内存文本并展示声明。没有写入 API、备份、rename、进程调用或真实写入开关。
本阶段结束，不进入 Phase 7B。

## 请求与兼容性

```text
cjx add foo --path ../foo
cjx add foo --git https://example.com/foo.git --branch main
cjx add foo --git https://example.com/foo.git --tag v1 --commit-id abc123
```

`parseAddRequest(Array<String>): AddRequest` 接收不含 `add` 的参数。
AddRequest 保存 name 和字段映射；planner 会重新校验直接构造的请求。
缺失或空值、未知/重复选项、path+git、path+selector、无来源均拒绝。
不支持 `--option=value`；以 `--` 开头的值视为缺失参数，可用 `./--name` 表达这种相对路径。
不支持 version add，也不做路径存在性、远程 URL 可访问性验证。

[CJPM 1.0.5 官方手册](https://docs.cangjie-lang.cn/docs/1.0.5/tools/source_zh_cn/cmd-tools/cjpm_manual.html)
明确 Git 字段为 branch、tag、commitId。不同 selector 可以同时出现，生效优先级
commitId > branch > tag；生成声明保留全部，重复同一选项拒绝。
未联网 clone，也没有对真实项目运行 check/update。

本机临时项目使用 `cjpm init` 创建，随后以 `cjpm check --skip-script` 验证依赖名称。
本地依赖项目的 package.name 与依赖 key 保持一致（初次探测名称不一致时 check 会拒绝）。
名称校验规则为 `_*[A-Za-z][A-Za-z0-9_]*`：前导下划线后必须有 ASCII 字母。
这是 dependency declaration 检查，不承诺该名字能作为任意仓颉源码标识符使用。

| 本机探测 | 结果 |
|---|---|
| foo、a_1、Foo、_foo、__a、a、a_、if、package、std | check 退出 0 |
| _、__、___、_1、1foo、foo-bar、org::foo、中文、a.b | 依赖名称检查拒绝 |

模块命名文档写字母开头；本机实际允许前导下划线，按实测处理。
临时探测目录均已清理。生产配置未改动。

另用 CJX dry-run 实际输出的 declaration 写入独立临时测试项目，验证转义与路径：
含空格相对路径、带反斜杠的 Windows 绝对路径均通过 `cjpm check --skip-script`（退出 0）。
包含引号、反斜杠和 `\u000A` 的声明被 CJPM 正确解码，随后因路径不存在退出 1，
没有 TOML 语法错误。仅测试夹具写入临时目录，测试后清理；产品 add 不写文件。

## 转义与补丁

`tomlBasicString` 在 UTF-8 字节上转义双引号、反斜杠，U+0000–001F、U+007F
输出为 `\u00XX`。其余 UTF-8 字节保持原样。生成单行 inline table。
这解决 TOML 表达，不意味着 Windows 接受包含控制字符或引号的文件名。

`TextPatch(start: Int64, end: Int64, replacement: String)` 使用 UTF-8 半开字节范围。
`applyPatch(original, patch)` 验证范围；分别 UTF-8 解码前后片段，拒绝切断中文等编码序列。
`planAdd(original, request): AddPlan` 返回 patch、modifiedText、declaration，全部只在内存。

插入规则：

- 有依赖：最后一个 entry.statementEnd，即包含行尾注释与换行的完整声明之后。
- 空 section：contentStart，即表头及其行尾注释/换行之后。
- 无 section：文件 EOF 追加 `[dependencies]` 和声明；BOM-only 的 BOM 后直接追加表头。
- 不占用或删除原有空行/前置或尾部注释，不重新排列声明。
- 换行选 section 内 LF/CRLF 多数；没有则用全文多数；平票用首先出现的风格；完全没有则 LF。
- 插入点前不是换行时补一个分隔换行（BOM-only 除外）。插入点有后缀或原文以 LF/CRLF
  结尾时补结束换行；EOF 且原文无末尾换行时，新文本同样无末尾换行。空文件也采用无末尾换行。
- 不转换原文换行；BOM、其他 section 和注释作为前后字节片段保留。

返回计划前再次扫描完整修改文本；新依赖的 name/source/spec 必须匹配，数量必须 +1，
原条目 key/rawValue 均必须保留，末尾换行状态相同，补丁外前缀/后缀逐字节一致。
重复依赖、scanner 的 malformed/unsupported/duplicate 均直接拒绝，不回退正则。

## 测试与结果

`tests/run.ps1`：53 个原扫描测试、38 个原 value/list 测试全部通过；新增 44 组全部通过。
新增清单：

| 编号 | 覆盖 |
|---|---|
| 01–05 | 空 section、1 个旧依赖、多个旧依赖、无 section、空文件精确结果 |
| 06–10 | LF、CRLF、BOM、无末尾换行、有末尾换行 |
| 11–15 | 中文注释、中文路径、Windows 路径、空格、引号/反斜杠 |
| 16–19 | Git 特殊 URL、branch、tag、commitId |
| 20–24 | selector/path 冲突、path/git 冲突、解码后重名、malformed、unsupported |
| 25–29 | 后续 section 精确结果、大量注释、multiline 伪表头、重新扫描计数、Unicode 字节保留 |
| 30–34 | 所有 ASCII 控制字符转义往返、多个 selector、重复 selector、缺参数、未知/禁用开关 |
| 35–39 | 非法/合法名称、非法补丁范围、UTF-8 中间偏移拒绝、BOM-only |
| 40–44 | EOF 表头、重复 section、混合换行多数策略、EOF 注释、未闭合 table |

所有成功规划测试额外检查非修改区字节、EOF 换行状态和重新扫描结果。
`tests/dry_run.ps1` 实际执行 CJX 与 practice 的 `add testdep --path ../test`，均退出 0，
并验证缺参数/禁用选项退出 2。两份真实配置前后 SHA-256：

```text
CJX:      57766ACE28A83E1073987FB8BBA28431987FD2B5DA5309058E46BCB392292F2C
practice: EA5F1F8F88788B0588A68D1C0021ACA79AB4DA4FEEAC58830DED5375B2EB7E53
```

`cjpm build` 成功；SDK/CJPM 仍为 1.0.5。scanner/value reader 源码未修改。

## 已知边界与写盘阶段前提

中文内存字符串及原文件内容通过测试。但本机 Windows 1.0.5 直接执行
`main.exe add foo --path ../中文库` 时仍出现此前 Phase 4 记录的运行时
`IllegalArgumentException: Invalid unicode scalar value`，退出 1。
未更换 SDK、未引入 Windows FFI 绕过入口参数转换。不能声称中文 CLI 参数已通过。

planner 继承扫描器的有限词法保证，不是完整 TOML/CJPM 语义验证：扫描器接受的
部分声明（例如 multiline inline table、version）可能不受 CJPM 1.0.5 支持。
不会静默改写这些旧声明。转义已通过现有 scanner/value reader 全控制字符往返测试；
不宣称每种不可用 Windows 文件名都通过 CJPM 的路径检查。

当前适合作为只读规划模块。进入真正写盘前，仍需解决/界定中文 CLI 输入兼容性，
并另行设计读取后文件变化检测、原子写入、失败恢复以及 scanner 有限验证的策略。
本阶段没有实现这些写盘能力。
