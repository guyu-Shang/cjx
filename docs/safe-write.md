# Phase 7B：独立安全写入引擎

本文记录 Phase 7B 的历史实现和测试。Phase 7C 已将引擎接入 add，详见 [正式 add](add-cli.md)。
在 Phase 7B 时正常 CLI 不调用写入引擎，add 只做 dry-run；
没有 apply/force/yes 开关，没有 remove、central add 或 cjpm update。

## API 与实际 Windows 行为

本机 SDK/CJPM 1.0.5 编译并验证了以下 std.fs API：

| API | 用途/验证 |
|---|---|
| File.createTemp(parent) | 在指定父目录创建并打开临时文件，实际名称 tmpFileXXXXXX |
| File.write(Array<Byte>) | 写入显式 UTF-8 字节，失败抛异常 |
| File.flush()、close() | 写入后调用 flush、close；写入异常时也尝试 close |
| File.readFrom(Path) | 从磁盘重新读取全部字节 |
| FileInfo.isRegular()/isSymbolicLink()、File.info.path | 普通文件检查、拒绝符号链接、取得临时文件实际路径 |
| Path.parent/fileName/join、canonicalize | 固定绝对父路径，同目录创建临时文件 |
| Directory.create | 排他创建事务目录；已存在时本机抛异常 |
| exists、rename、remove | 存在检查、不覆盖重命名、删除自己拥有的事务文件 |

独立最小程序真实验证：默认 rename(temp, to: original) 在目标存在时抛
`Destination path exists.`，原文件仍是 old；overwrite: true 可以将内容替换为 new。
但是文档契约规定 overwrite: true 先删除目标，因此写入引擎**从不使用 true**。
不覆盖的 original→backup→original 往返成功；既有事务目录的重复创建被拒绝。

连续保留 64 个临时文件的探测中，File.createTemp 有时会报创建失败；不假定它会无限重试。
回归测试验证所有已创建文件仍存在且内容不变。创建失败会放弃事务，不覆盖用户已有文件。

标准库 File.flush 的文档说明 File 没有缓冲区，该函数无实际作用。
未找到并验证标准库提供的 fsync、原子覆盖或目录持久化接口；未使用 Windows FFI。
本实现不能承诺断电持久性，也不能把双重 rename 称为原子替换。

参考：
[官方 File API（可访问的 1.0.0 页面）](https://docs.cangjie-lang.cn/docs/1.0.0/libs/std/fs/fs_package_api/fs_package_classes.html)、
[官方 rename 契约（可访问的 1.1.0 页面）](https://docs.cangjie-lang.cn/docs/1.1.0/libs/std/fs/fs_package_api/fs_package_funcs.html)。
上述文档用于查找候选 API，兼容性最终以本机 1.0.5 编译/运行结果确认，不把其他版本文档当成本机验证。

## 接口与流程

```cangjie
safeReplaceFile(
    path: Path,
    expectedOriginalBytes: Array<Byte>,
    replacementBytes: Array<Byte>,
    validate!: (Array<Byte>) -> Unit = validateConfigBytes
): SafeWriteResult
```

接口不理解 add/remove。内建 UTF-8 + scanner 检查；调用者可以补充语义校验函数。
测试使用真实 add planner 的结果，语义回调确认新依赖的 name/source/spec。
传入的两组字节先复制为事务快照；校验回调收到副本，不能改变待提交字节。

1. 校验 replacement，检查原文件为普通非符号链接文件，并逐字节比较原内容。
2. 排他创建同目录的 `.cjpm.toml.cjx-lock` 目录。既有锁不复用、不删除、不自动判断过期。
   这使使用同一引擎、同一路径的 CJX 事务相互排斥；不会阻止其他编辑器。
3. File.createTemp(original.parent) 创建 T。写显式 Array<Byte>，flush，close。
4. 重新读取 T，字节必须等于 replacement，再进行 UTF-8/scanner/调用者语义校验。
5. 再读 A，与 original 快照逐字节比较；不同则报 changed since the operation started。
6. 不覆盖地将 A 移至 `.cjpm.toml.cjx-lock/original`，再读该备份并比较，检测检查与移动之间的变化。
7. 不覆盖地将 T 移至 A。若其他工具在间隙创建 A，拒绝覆盖。
8. 重新读取最终 A，验证字节、UTF-8、scanner 和语义；验证通过才算提交完成。
9. 删除短期备份和空锁目录。正常成功没有长期备份。

所有字节直接写入，没有平台默认编码、换行转换或 BOM 重建。
字节保真覆盖中文、BOM、LF/CRLF、空文件及末尾换行状态。

## 失败、恢复与结果含义

- 原文件移动前失败：不碰 A，关闭句柄，尽力删除 T 和锁目录。
- 已移走 A 但尚未安装 T：尝试不覆盖地把 backup 移回 A。
- 最终验证失败：报告 SERIOUS；如果 A 是普通文件，将其移至锁目录内 rejected 保留，
  再恢复 backup，重新读取验证恢复结果。最终 A 消失时直接尝试恢复 backup。
- 恢复不能完成：保留 backup，不覆盖外部创建的 A；错误包含恢复位置和目标路径。
  此时 A 可能暂缺，不能报告“原路径已恢复”，但已测试 backup 与原始字节完全一致。
- 检查/移动间隙发现外部改动时保留/恢复外部版本，而非恢复较早快照覆盖用户改动。
- 清理失败保留文件并报告路径，不使用递归删除。保留 backup/rejected 时锁也保留。
- SafeWriteResult 返回表示最终提交验证成功；warning 非空表示已提交但清理不完整。
  调用者不能因 warning 自动重试写入。写入/验证失败抛 Exception，保留根因及恢复信息。

剩余锁目录不能盲目删除：先检查错误报告、A、original 和 rejected，确认需要的版本。
本阶段不提供自动崩溃恢复或用户备份管理命令。

## 测试结果

原 53 扫描 + 38 list/value + 44 planner = **135 组全部通过**。
新增 **37 组全部通过**，合计 172 组。执行 `tests/run.ps1` 可复现。
测试进程在单独的系统临时目录运行，各用例再创建独立子目录，结束后清理，包括故意留下的恢复文件。
没有将 CJX 或 practice 的真实配置交给写入引擎。

| 编号 | 测试 | 结果 |
|---|---|---|
| 01 | 正常事务及 add 语义 | 通过 |
| 02 | commit 前外部修改 | 保留外部字节，拒绝提交 |
| 03–05 | temp 创建失败、部分写失败、磁盘内容损坏 | 原文件逐字节不变 |
| 06 | replacement 失败 | 原字节恢复 |
| 07 | backup 清理失败 | 已提交警告、备份保留、后续事务被锁拒绝 |
| 08–09 | 原文件不存在、原文件变目录 | 拒绝；不创建/不覆盖目标 |
| 10 | 预存 temp 命名文件 | 全部保留 |
| 11–17 | BOM、LF、CRLF、中文、空文件、有/无末尾换行 | 写回字节精确匹配 |
| 18 | 60,000 行中文注释配置，约 1.2 MB | 字节匹配 |
| 19 | 连续 12 次安全写入 | 全部匹配，无遗留 |
| 20–21 | 保存原文件失败、flush 阶段失败 | 原字节不变、临时文件清理 |
| 22 | commit 后损坏 | 原字节恢复、损坏版本保留为 rejected |
| 23 | replacement 和恢复均失败 | 严重错误，原字节保留于 backup |
| 24–25 | temp 清理失败、锁名碰撞 | 报告遗留；不碰既有锁内容 |
| 26–27 | malformed replacement、非法 UTF-8 | 写入前拒绝 |
| 28 | 重读之后、rename 之前外部改动 | 检测并恢复外部版本 |
| 29 | rename 间隙外部创建 A | 不覆盖外部文件；原字节保留于 backup |
| 30–31 | temp/final 阶段语义验证失败 | 验证确实重跑，原字节不变/恢复 |
| 32 | 锁清理失败 | 已提交警告 |
| 33 | 真实默认 rename 覆盖既有目标 | 拒绝，双方字节不变 |
| 34 | 连续创建 64 个临时文件的成功/碰撞行为 | 成功文件不被覆盖；失败安全退出 |
| 35–36 | validator 改动数组、过期快照 | 快照隔离；过期操作拒绝 |
| 37 | 最终文件消失 | backup 恢复到原路径 |

注入使用内部函数的 `(stage, path) -> Unit` hook：抛异常或实际改变临时文件/目标状态。
生产入口只传空 hook，CLI 不暴露它。创建失败、flush/恢复失败等采用注入，
不宣称测试真的耗尽磁盘或制造了断电。Windows 文件写入、读回、rename、删除均是真实操作。

`cjpm build` 成功；因为按要求没有接入 CLI，编译器有一条 safeReplaceFile 未使用警告，
未为隐藏该警告修改编译选项。测试调用该入口正常。
生产源码共 9 个文件、1367 行，其中 safe_write.cj 184 行。

`tests/dry_run.ps1` 再次确认 CLI 行为不变，两份真实文件前后 SHA-256 相同：

```text
CJX      57766ACE28A83E1073987FB8BBA28431987FD2B5DA5309058E46BCB392292F2C
practice EA5F1F8F88788B0588A68D1C0021ACA79AB4DA4FEEAC58830DED5375B2EB7E53
```

## 能否进入 Phase 7C

作为受控场景下可回滚的写入模块已通过测试，但**不建议直接开放真实项目写入**。
两次 rename 中间目标路径可能暂缺；进程终止、断电以及不遵守锁的外部写入者仍有竞态。
重读比较不是操作系统级 compare-and-swap。对方持有旧文件句柄时，可能在最后检查之后继续修改旧文件。
File.flush 也不提供 fsync 的耐久性。成功替换会改变文件身份，尚未承诺保留原 ACL、其他元数据和硬链接关系。
后续应先决定是否引入并验证 Windows 原生替换/同步能力及恢复协议，明确并发和崩溃保证，再接入真实 add。

中文文件内容的读写已通过；中文 CLI 参数的既有 runtime 限制未修改。
上述进入 Phase 7C 的建议是 Phase 7B 时的判断；现已按用户明确授权接入 CLI，保留这些保证边界。
