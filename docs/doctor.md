# Phase 9: read-only doctor

`cjx doctor` performs diagnostics only. No flags, repair mode or write options.
Extra arguments return 2 without running diagnostics.

## Checks and result

`diagnoseProject()` returns a `DoctorReport` containing `DoctorCheck` rows,
error/warning counts and an exit code. `formatDoctor` formats the sections.
`doctorProject` is the small CLI entry point. No unrelated command is invoked.

| Check | Meaning |
|---|---|
| Cangjie SDK / CJPM | Locate cjc.exe / cjpm.exe on the inherited Windows PATH, run only `--version`, parse the official version banner. |
| cjpm.toml | Reuse nearest-parent project discovery and complete UTF-8 read. Nonregular paths/read/UTF-8 errors are reported. |
| cjpm.lock | Reuse the read-only metadata state helper: existence, regular/non-symbolic type, full byte readability. No lock parser or consistency check. |
| Dependencies | Reuse full scanner and value classifier. Distinguish missing section and empty section; count safe entries. |
| Path entry | Resolve relative to the located project root; check existence, directory type and presence of a regular cjpm.toml. Missing Path is ERROR, other uncertain local structure is WARN. |
| Git entry | Report configured only. No clone, ls-remote, ping or network validation. |
| TOML scan | Structural scanner only, not a complete TOML parser or CJPM schema validator. |
| Unsupported | Count understood central/version declarations known to be unsupported by detected CJPM 1.0.5. This is not exhaustive validation of all CJPM restrictions. |
| Unknown values | Count values the limited value reader cannot classify; warn and suggest reviewing `cjx list`. |
| Transaction | If the shared operation/recovery directory exists, warn and preserve it. It may be active or require recovery; doctor does not guess or remove it. |
| cjpm update | READY only means the CJPM executable can run its version query; update is never executed. Project errors do not change this tool-startup indicator. |

Missing or empty lock is WARN, not ERROR. A missing lock is not a blocker for
a future update, which can generate it. A nonregular/unreadable lock is ERROR.
Missing tools, startup/version failure, manifest read error and scanner rejection
are ERROR. Unknown values make the Dependencies summary WARN and are listed by
name; the Unknown-values count is also displayed. Recovery state remains WARN
and is never removed. Known 1.0.5-incompatible central/version declarations are
WARN, not ERROR. Other SDK/CJPM versions are WARN because this release was validated
with 1.0.5; compatibility counts are SKIP rather than invented claims. No
upgrade is required or performed. Version equality is not an enforced rule.
Per-dependency central warnings only apply to detected CJPM 1.0.5; other
versions receive informational declarations without guesses about support.

UNC/device Path declarations are warned and skipped to avoid a network-backed
existence probe. Local mapped drives/junctions follow filesystem behavior;
doctor does not establish the physical backing of every filesystem path.

All independent checks continue when a check fails. Dependent checks use SKIP
when no safe input exists, so one malformed configuration does not become
several invented errors. Problems count independent ERROR/WARN findings;
supplementary Unknown/central detail/count rows do not count the same finding
again. SKIP and BLOCKED do not create duplicate counts. Exit 0 means no ERROR (warnings may
still exist), exit 1 means one or more errors, exit 2 means invalid arguments.

All checks passed means these listed checks passed. Empty text is a successful
structural read with zero declarations, not evidence of a valid CJPM project.
READY does not verify dependency resolution, complete Path project validity,
Git availability, network, writable files, package schema, lock consistency or
absence of races. It can appear alongside project ERRORs: those still cause exit 1.

## API and side effects

The standard-library API actually compiled and ran on the installed SDK:

```text
std.process.executeWithOutput(command, ["--version"], stdIn: ProcessRedirect.Discard)
    -> (Int64, Array<Byte>, Array<Byte>)
```

Only short official version output is captured in memory. Unlike the update
runner, doctor never creates output files/directories, never uses a shell and
never changes PATH or executes envsetup. A shared executable lookup was
extracted from `locateCjpm`; update still calls the same lookup with `cjpm` and
its behavior is unchanged. Doctor uses it with `cjc` and `cjpm`.

Current local output verified:

```text
Cangjie Compiler: 1.0.5 (cjnative)
Target: x86_64-w64-mingw32
Cangjie Package Manager: 1.0.5
```

Normal startup failure includes the underlying reason and advice to load the
installed SDK environment in the user's terminal. Missing runtime DLLs may
prevent CJX itself from reaching main; doctor cannot diagnose that from inside
a process that cannot start. No damaged-executable or missing-DLL popup test
was performed. Standard version execution is synchronous with no custom
timeout; a malfunctioning executable can still block. The large-output pipe
limits discussed for update are not expanded into a general process runner
here. Output controls are escaped before rendering.

## Verification

After loading the already installed SDK into the testing PowerShell:

```powershell
cjfmt -f src/doctor.cj
cjfmt -f src/cli.cj
cjfmt -f src/cjpm_runner.cj
cjpm build
& tests/doctor.ps1
& tests/run.ps1
& tests/add_cli.ps1
& tests/update_cli.ps1
& tests/remove_cli.ps1
& tests/remove_write_cli.ps1
```

Build succeeded. Thirty-two doctor tests passed: normal Path/Git;
missing/empty lock; absent/empty section and empty text; malformed/unsupported/
duplicate configuration; 1.0.5 version incompatibility; unknown values; missing
tools/project; nonregular manifest; permission/read failure; nonregular lock;
other unverified tool versions; startup failure with remaining checks; UTF-8
Chinese/BOM/CRLF; terminal escaping; and rejected extra arguments. Added real
temporary Path checks for existing relative/absolute Chinese paths, missing
paths, files instead of directories and absent project manifests; Git-no-path-
inspection, long/control-escaped Unknown names, independent cjc missing/startup,
cjpm missing, actual SDK version capture, invalid UTF-8 and UNC skip tests.

Seven temporary CLI scenarios passed: missing lock, malformed configuration,
preserved recovery state, nested cwd, missing Path resolved against project
root, central+Unknown WARN exit 0, and outside-project environment reporting. File and
directory SHA-256 snapshots verify no diagnostic mutation. Tests create only
new isolated temporary fixtures; these are cleaned after assertions. Permission
and startup failures are injected through read-only seams, not by modifying
SDK permissions or launching damaged executables.

All original 321 tests passed, including the 171 pure-memory scanner/value/
add-plan/remove-plan regressions and the existing safe-write/update/remove
integration regressions. Existing regression writes/update run only within
isolated temporary fixtures; doctor itself never invokes these commands.
With 32 unit + 7 CLI doctor tests, the suite is 360 tests, plus two actual
read-only project diagnoses. Compared to the first partial Phase 9 request,
this adds 15 doctor tests. `tests/run.ps1 -ReadOnly` remains available to select
the 171 pure-memory regressions; no tests were discarded.

Actual doctor on CJX and practice both returned 0 and All checks passed:

- SDK and CJPM: 1.0.5.
- CJX dependencies: 0; practice dependencies: 1.
- Both lock files: 24 readable bytes.
- practice `cui`: OK, local `../CangjieCUI` exists with project manifest.
- TOML scan OK; known unsupported 0; unknown 0; basic update status READY,
  explicitly not executed. Version inequality is not used as an error rule.

TOML and lock SHA-256 before/after remained identical in both real projects.
No add/remove/update/check/build was launched by doctor; `cjpm build` above
was solely the explicit development verification step.
