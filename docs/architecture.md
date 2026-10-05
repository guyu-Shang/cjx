# CJX V0.1 Architecture

CJX 是官方 CJPM 的依赖操作 UX 层。依赖解析、下载、缓存、lock 和构建由 CJPM 负责。

```text
CLI (cli.cj / main.cj)
  ↓ project locator (project.cj)
  ↓ UTF-8 config reader (config.cj)
  ↓ lexical scanner (dependencies.cj)
  ├ list: value classification / formatting (dependency_value.cj)
  └ add/remove: byte-range planner (add_plan.cj / remove_plan.cj)
       ↓ in-memory patch and semantic validation
       ↓ metadata transaction snapshot / operation guard (metadata_transaction.cj)
       ↓ safe writer (safe_write.cj)
       ↓ official CJPM update (cjpm_runner.cj)
       ↓ final validation / metadata rollback when necessary
```

事务快照在写入前建立，而不是写入后才开始保护 lock。scanner 不构造完整 TOML AST；
planner 只补丁目标区域，其余字节保持原文。safe writer 不知道 add/remove 的业务含义，
负责比较 expected original、暂存、验证与替换；metadata transaction 负责 TOML/lock 操作级恢复。

doctor.cj 独立组织只读检查，复用定位、读取、scanner、classification 与工具定位能力；
只运行版本查询，不执行 update/check/build 或网络检查。

tests/verify.ps1 是发布前 gate：日常 main.exe 干净构建、自定义测试及直接 exe 黑盒。
scripts/release.ps1 在 gate 通过后用官方 `cjpm build -o cjx` 构建并校验本地 dist/cjx.exe，
保留外部 SDK/runtime 环境前提，不打包 SDK DLL、不上传或安装。

细节与历史阶段记录保留在各原有文档。当前写入能力不承诺崩溃/断电的原子持久化，
不回滚官方工具的全局缓存或远程副作用，不替代官方构建系统。
