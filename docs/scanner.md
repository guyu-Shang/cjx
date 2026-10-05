# Phase 5：依赖结构的只读扫描

入口为 `scanDependencies(text: String): Option<DependencySection>`。
复用现有定位、读取函数，无文件写入、TOML 序列化或 CJPM 更新调用。

## 返回结果与范围契约

全部 offset 为原始 UTF-8 字节数组的半开区间 `[start, end)`，不是字符序号。
扫描 `text.toArray()`；取原文片段使用 `String.fromUtf8(bytes[start..end])`。
ASCII 结构字符不会落在 UTF-8 多字节字符内部。公开的范围边界位于完整字符之间，
测试对每个边界分别解码前后两段，并验证拼接结果等于原文。

`DependencySection`：

| 字段 | 含义 |
| --- | --- |
| start | header 所在行起点；文件首部 BOM 不计入 |
| contentStart | header 及其行尾注释、换行之后 |
| end | 下一个真正的 section header 行起点，或 EOF |
| entries | 按原文顺序排列的条目 |

`DependencyEntry`：

| 字段 | 含义 |
| --- | --- |
| key | 解码后的键；裸键和等价 quoted key 用于重复检查 |
| rawValue | 原始 value 文本，不重排、不去除内部注释或换行 |
| start | key 的首字节，不含行首缩进 |
| valueStart / end | value 的首字节 / 末尾之后；不含行尾空白、注释 |
| lineStart | 条目开始行的起点，含缩进 |
| statementEnd | 整条语句末尾，含行尾注释和原始换行 |
| commentStart | 行尾注释 `#` 的位置；不存在为 -1 |

`[start,end)` 和 `[lineStart,statementEnd)` 不是可无条件用于 remove 的删除策略。
前置注释保持为原文中的空隙；`commentStart` 让未来区分行尾注释。
本阶段没有决定任何注释的删除归属。

`None` 表示不存在顶层 dependencies section；`Some` 加零 entries 表示空 section。
失败抛出包含原因和字节位置的异常，CLI 捕获后返回 1。扫描完成前不显示依赖列表。

## 扫描方法

- 按顶层语句推进。仅在语句起点识别 section header，按裸键、quoted key 和点号解析表路径。
- 扫描整个文件，其他 section 的字符串、数组和表也需要正确跳过。
- basic/literal string 及两种 multiline string 分别处理；basic string 验证转义与 Unicode 标量。
- 多行字符串支持换行续接和四/五个结束引号；普通字符串不能跨行。
- comment 消耗到 LF/CRLF；字符串中的 `#` 不开启注释。
- `{}` 和 `[]` 用闭合符栈匹配，不混用计数，不递归调用容器扫描。
- 只有容器完整闭合后才完成该 value，因此跨行 inline table 可以形成一个连续范围。
- 处理 LF、CRLF 和可选 UTF-8 BOM，不进行换行或文本规范化。
- 两类依赖 value 可以形成条目：字符串和 inline table。内部字段保留为原文，不解释业务含义。

此扫描器不是完整 TOML parser：不验证数值/日期格式、其他表的重复键或 inline table
内部的完整 key/value 语法。因此“扫描成功”只代表支持范围内的结构定位成功，不能当成
完整 TOML 合法性证明，更不能单凭扫描成功授权未来写回。

## 主动拒绝的依赖形式

- `[dependencies.foo]`、`[[dependencies.foo]]`、`[[dependencies]]`。
- 根级 `dependencies = {...}` 或 `dependencies.foo... = ...`。
- `[dependencies]` 中的点分键，以及非字符串/非 inline-table 的依赖 value。
- 重复 dependencies header 或重复解码后的依赖键。
- 未闭合字符串、数组、inline table、header，错配括号、非法转义、尾部多余文本等。

这些拒绝不等于认定对应语法全部不合法，而是声明当前扫描范围。
`[target.<平台>.dependencies]`、`[test-dependencies]` 等不属于当前顶层 dependencies，
会正常跳过。仅有这些 section 时返回“没有顶层 dependencies section”。

## 本机 CJPM 1.0.5 兼容性实测

在独立临时项目中用官方 `cjpm init` 生成配置，再以本地空静态库作为 Path 依赖，
运行 `cjpm check --skip-script`。全部实验文件已清理，未在真实项目执行这些兼容性实验。

| 配置形式 | CJPM 1.0.5 结果 | CJX 扫描策略 |
| --- | --- | --- |
| 空 dependencies | 通过 | 返回空 section |
| `foo = "1.0.0"` | 拒绝：不是 DataModelStruct | 支持结构识别 |
| `foo = { path = "./foo" }` | 通过 | 支持 |
| 跨多行 inline table | 拒绝：errLexInlineTableNL | 按需求支持结构识别 |
| `foo = { version = "1.0.0" }` | 拒绝：必须存在 git 或 path | 支持结构识别 |
| `foo = { version = "[1.0.0, 2.0.0)" }` | 同上 | 支持结构识别 |
| `"org::foo" = { path = "./foo" }` | 拒绝依赖名称 | 支持 quoted key 识别 |
| `[dependencies.foo]` 加 path | 通过 | 按本阶段范围主动拒绝 |
| `[[dependencies.foo]]` 加 path | 拒绝：不是 DataModelStruct | 主动拒绝 |

Git inline table 是 [1.0.5 官方文档](https://docs.cangjie-lang.cn/docs/1.0.5/dev-guide/source_zh_cn/compile_and_build/cjpm_usage.html)
列出的形式，本阶段测试其扫描结果，没有请求远程 Git 仓库。
多行 inline table 同时超出了 [TOML 1.0 inline table 规则](https://toml.io/en/v1.0.0#inline-table)；
扫描器的宽容识别不改变官方工具的兼容边界。

## 回归测试

加载 SDK 环境后运行 `tests/run.ps1`，测试源码在 `tests/dependencies_tests.cj`。
测试直接编译真实的生产扫描器，无复制维护的测试版实现。53 组全部通过。

| 编号 | 用户要求的测试 | 结果 |
| --- | --- | --- |
| 1 | 空 dependencies | 空 section |
| 2 | version 字符串 | 识别 foo |
| 3 | path | 识别 foo，保留原始 value |
| 4 | git | 识别 foo，保留原始 value |
| 5 | org::package quoted key | 正确解码键 |
| 6 | version range | 方括号不影响边界 |
| 7 | 多个依赖 | 顺序一致 |
| 8 | 跨行 inline table | 单一连续条目 |
| 9 | 行尾注释 | 不进入 rawValue |
| 10 | 前置注释 | 不进入条目范围 |
| 11 | 注释里的伪 header | 无 section |
| 12 | 普通字符串里的伪 header | 无 section |
| 13 | 两种 multiline string 的伪 header | 无 section |
| 14 | 字符串里的 #、=、括号 | 不作为结构 |
| 15 | 中文注释与路径 | UTF-8 范围正确 |
| 16 | CRLF | 原样保留 |
| 17 | LF | 原样保留 |
| 18 | 无 section 与空文件 | 返回 None |
| 19 | 后续其他 section | 边界正确，其他键不混入 |
| 20 | 未闭合字符串 | 明确拒绝 |
| 21 | 未闭合 inline table | 明确拒绝 |
| 22 | 重复 dependencies | 明确拒绝 |

23–53 额外覆盖：version 字段、literal key、转义、嵌套、两类未闭合多行字符串、
依赖子表/数组表/点分键、等价转义导致的重复键/header、错配括号、尾部垃圾、缺失值、
非法 Unicode 标量、后续坏 header、单独 CR、无文件末换行、平台依赖跳过、续行、
连续引号、空 quoted key、BOM 与精确字节位置、容器内注释、前置/行尾注释独立范围。

额外 CLI 验证：缺少 section 和空 section 返回 0；结构错误和不支持子表返回 1。
真实项目：CJX 为 0 dependencies；practice 为 cui，均返回 0。
两份真实 cjpm.toml 的 SHA-256 在运行前后相同。临时目录已清理。

当前适合继续做只读 list 的字段解释与展示。进入 add/remove 前仍需单独设计并验证
支持的内部依赖字段语法、注释策略、文件变更检测、补丁不变量与安全写回。
