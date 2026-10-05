# Phase 6：正式 list

`list` 仅读取当前项目的顶层 `[dependencies]`，不会查询远程仓库、解析依赖图、
修改配置或调用 CJPM。定位与词法边界继续使用 Phase 3–5 的实现。

`DependencyInfo` 保存 name、source、spec；`DependencySource` 包含 Path、Git、Central、Unknown。
分类入口为 `classifyDependency(entry: DependencyEntry): DependencyInfo`。

## 分类规则

| 原始声明 | SOURCE | SPEC |
| --- | --- | --- |
| `{ path = "../foo" }` | path | 解码后的路径 |
| `{ git = "url" }` | git | 解码后的 URL |
| `{ git = "url", branch = "main" }` | git | `url [branch=main]` |
| `{ git = "url", tag = "v1" }` | git | `url [tag=v1]` |
| `{ git = "url", commitId = "abc" }` | git | `url [commitId=abc]` |
| `"1.2.3"` 或 `{ version = "1.2.3" }` | central | 版本声明 |
| `{ version = "[1.0.0, 2.0.0)" }` | central | 原版本范围 |
| 无法安全理解的字段表 | unknown | 原始声明的单行摘要 |

value reader 逐字节读取键、等号、字符串和逗号；逗号/等号/注释符在字符串里不参与分隔。
支持 basic/literal 单行字符串、标准转义和 Unicode 标量转义，quoted field key 也会解码。
扁平表可跨行并带注释。没有使用 split(',') 或 split('=')，也没有修改 scanner。

重复字段、冲突来源、未知字段、非字符串字段、嵌套值、多行字符串、尾随逗号或空来源等
降级为 Unknown，不显示某个未经确定的来源。高级可合法配置也可能 Unknown，这是有限 reader
的支持边界。scanner 已拒绝的结构错误仍导致 list 返回 1，不能由分类回退吞掉。

未知摘要最多取 80 个 UTF-8 字节，再附 `...`；截断点避开多字节字符内部。
终端展示将 CR/LF/TAB 转成可见转义，其他 ASCII 控制字节替换为 `?`，避免破坏行布局。
姓名列宽按 UTF-8 字节数动态填空格，中文姓名对齐不保证精确终端显示宽度；中文内容保持正确。

## CJPM 1.0.5 兼容性

[官方 1.0.5 手册 dependencies](https://docs.cangjie-lang.cn/docs/1.0.5/tools/source_zh_cn/cmd-tools/cjpm_manual.html#dependencies)
确认 Git 选择器是 branch、tag、commitId；多个配置时优先级为 commitId > branch > tag。
本命令按这个顺序显示所有已声明的选择器，不隐藏较低优先级声明；不声称已经解析到某个提交。
`commit` 不是这里确认的配置字段，因此出现它时为 Unknown。

central 只是声明的分类显示，不代表当前 CJPM 1.0.5 支持中心仓版本依赖、版本满足要求，
或包已经下载。本轮没有执行远程 Git 请求。其他 1.0.5 兼容性实验记录见 scanner.md。

## 输出与退出码

practice 的实际只读结果：

```text
Dependencies
------------------------------------------------------------
NAME  SOURCE     SPEC
cui   path       ../CangjieCUI

1 dependency
```

CJX 自身配置为空：

```text
Dependencies
-------------
(0 dependencies)
```

无 section、空 section 和含 Unknown 的列表成功均返回 0。读取或扫描失败返回 1。
条目按配置原顺序展示，单个为 `1 dependency`，多个为 `N dependencies`。

## 验证结果

`cjpm build`、`cjpm run` 成功。`tests/run.ps1` 中原 53 组 scanner 测试全部通过，
原 scanner 和它的测试源码没有修改；新增 38 组 value/list 测试全部通过：

| 编号 | 场景 | 结果 |
| --- | --- | --- |
| 1 | Path | 通过 |
| 2 | Git | 通过 |
| 3 | Git + branch | 通过 |
| 4 | Git + tag | 通过 |
| 5 | URL 中逗号、#、=、括号 | 通过 |
| 6 | 版本字符串 | 通过 |
| 7 | 版本范围 | 通过 |
| 8 | org::package quoted key | 通过 |
| 9 | Unknown | 通过 |
| 10 | 空 dependencies | 通过 |
| 11 | 多种来源 | 通过 |
| 12 | 中文路径 | 通过 |
| 13 | CRLF | 通过 |
| 14 | LF | 通过 |
| 15 | commitId | 通过 |
| 16 | 多个选择器全部保留 | 通过 |
| 17 | commit 不误当 commitId | 通过 |
| 18 | 冲突来源 | Unknown，通过 |
| 19 | 重复字段 | Unknown，通过 |
| 20 | quoted field 解码后重复 | Unknown，通过 |
| 21 | quoted field | 通过 |
| 22 | Unicode 转义 | 通过 |
| 23 | literal 反斜杠 | 通过 |
| 24 | basic string 转义 | 通过 |
| 25 | 嵌套值 | Unknown，通过 |
| 26 | 非字符串字段 | Unknown，通过 |
| 27 | 尾随逗号 | Unknown，通过 |
| 28 | 配对但字段语法错误的表 | Unknown，通过 |
| 29 | 表内注释及字符串特殊字符 | 通过 |
| 30 | 无 dependencies section | 0 dependencies，通过 |
| 31 | 空选择器 | Unknown，通过 |
| 32 | 空来源 | Unknown，通过 |
| 33 | 多行字符串 | Unknown，通过 |
| 34 | 单个依赖完整输出快照 | 通过 |
| 35 | 终端控制字节 | 安全单行展示，通过 |
| 36 | 长 UTF-8 Unknown 摘要 | 安全截断，通过 |
| 37 | version inline table | 通过 |
| 38 | scanner 错误继续传播 | 通过 |

真实 CJX 和 practice 的 list 均返回 0，两份 cjpm.toml 的 SHA-256 与运行前完全一致。
help 中 list 说明已更新；add/remove/doctor 继续提示未实现。临时测试产物自动清理。
