# CJX V0.1.0：MIT 接入与最终冻结

2026-10-05 完成。版本固定为 **0.1.0**，没有新增功能、重构生产代码或继续 V0.2。
本地完整验证、release gate 和最终发布包黑盒均 PASS；未执行 Git 操作或公网发布。

## 许可证与文件改动

- 新增根目录 LICENSE：使用项目所有者提供的标准 MIT 文本，正文逐项核对一致，没有改写授权/免责条款。
- 版权行仍是 `Copyright (c) 2026 <COPYRIGHT HOLDER>`，没有推断或填写姓名/昵称。
- README 的 License 小节更新为：

  `CJX is licensed under the [MIT License](LICENSE). SPDX identifier: MIT.`

  并提示所有者公开前确认版权人，没有复制整份许可证。
- docs/release.md 增加历史状态说明，指向本冻结报告；原阶段证据保留。
- 新增本报告和 docs/freeze-evidence 的运行记录；dist 完全由已有 release.ps1 重新生成。

release.ps1 本来就支持复制根目录 LICENSE，本轮没有修改脚本，也没有手工添加/修改 dist 文件。
旧的三文件 dist 先整体移至本轮临时归档，待新包验证成功且旧包指纹未变后安全清理。

## 最终目录

```text
dist/
  cjx.exe          3,629,568 bytes
  README.md           9,890 bytes
  LICENSE             1,075 bytes
  SHA256SUMS.txt          74 bytes
```

LICENSE 与 README 的打包副本和源文件逐字节对应（SHA-256 相同）。
保持现有校验机制：SHA256SUMS.txt 记录 cjx.exe；没有为多文件哈希引入新设计。

最终 exe SHA-256：

```text
5BFBF7AF8D7C9977BD93784E91C2496F1D6559912262D912F194EB680B4C3011
```

该指纹同时匹配 `target/release/bin/cjx.exe`、`dist/cjx.exe` 和 SHA256SUMS。
产物来自本轮真实官方 `cjpm build -o cjx`，没有复制/重命名 main.exe 充当发布构建。
`target/release/bin/main.exe` 和 `dist/main.exe` 均不存在。

## 实际执行与验收

| 项目 | 结果 | exit |
|---|---|---:|
| 用户提供的 MIT 正文精确核对 | PASS | 0 |
| tests/verify.ps1 -PracticeRoot C:\sourse\cj\practice | PASS，361 组自定义测试 | 0 |
| verification 版本一致性 | PASS，manifest 与 exe 均 0.1.0 | 0 |
| scripts/release.ps1 | PASS，内置完整 gate 再次 361 组通过 | 0 |
| release 官方 clean/build -o cjx | PASS | 各 0 |
| release 打包产物 Path 生命周期/失败回滚 | PASS | 0 |
| 最终 dist/cjx.exe --help | PASS | 0 |
| 最终 dist/cjx.exe --version | CJX 0.1.0 | 0 |
| tests/smoke.ps1 对最终 dist/cjx.exe 的独立黑盒 | PASS，生命周期/实际依赖调用/失败回滚 | 0 |

预期的真实 update 失败在 smoke 内严格检查 exit 1 和 TOML/lock 原始字节恢复，
不因顶层 smoke exit 0 而忽略失败子命令。官方 `cjpm test` 仍 TOTAL 0；它不是上述自定义 suite。

证据：

- [冻结状态与所有保护文件指纹](freeze-evidence/d9c6ef1d192b44c9a4ca550ccbce44ea/freeze.json)
- [独立完整 verification](freeze-evidence/d9c6ef1d192b44c9a4ca550ccbce44ea/verification.json)
- [release 命令、退出码及 SHA](release-evidence/1b283d529f954bc9a22f7afaa266b703/release.json)
- [release 归档的完整 gate](release-evidence/1b283d529f954bc9a22f7afaa266b703/verification.json)
- [最终 dist 黑盒输出及退出码](freeze-evidence/d9c6ef1d192b44c9a4ca550ccbce44ea/artifact-blackbox.json)

## 工作区保护与清理

本阶段开始/结束的 **13 个生产 .cj 文件 SHA-256 全部相同**。
真实 CJX 和 practice 的 cjpm.toml / cjpm.lock 也全部未变，版本没有升级到 0.1.1。
没有修改 SDK、生产 CLI 行为或测试框架。

独立 gate 工作区、release gate 工作区、最终 dist smoke 工作区及本轮旧包暂存均已清理。
release smoke 自身也按现有 finally 流程清理临时项目；没有残留 `.cjx-release-*` 暂存目录。
正式 target/dist 与本地证据保留，未将 SDK DLL 打入发布包。

## 公开发布前的唯一明确人工待办

**项目所有者必须在正式公开前手工确认并填写 `<COPYRIGHT HOLDER>`，之后重新生成发布包。**
当前按要求保留占位符，没有代填。未发现新的技术阻塞缺陷；既有 SDK/runtime、平台范围、
中文 argv 和事务持久性限制继续按 README 说明适用，不宣称已修复。
本轮到此冻结并停止，没有自动 git init/commit/tag/push 或公网 Release。
