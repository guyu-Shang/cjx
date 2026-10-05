# Phase 8B: safe remove with automatic CJPM update

## Commands

```text
cjx remove NAME
cjx remove NAME --dry-run
cjx remove NAME --no-update
```

The default generates and validates `RemovePlan`, snapshots project metadata,
safely commits TOML, re-reads and verifies it, directly runs `cjpm update` at
the project root, then verifies TOML again. Only complete success prints
`Removed dependency successfully.` and `Dependencies updated successfully.`.

`--dry-run` uses the same planner and validation, then returns before snapshot
creation, writer or runner. It creates no transaction state and changes no
TOML/lock bytes. `--no-update` safely writes TOML only, preserves lock, and says:

```text
Dependency was removed from cjpm.toml.
Run `cjpm update` to refresh cjpm.lock.
```

With both flags, dry-run wins exactly as for add. Missing/option-looking names,
extra arguments, unknown flags and duplicate flags return 2. Missing dependency
returns 1 before any snapshot/writer/updater; no `--force`/`--apply`/`--yes`.
Matching, leading-comment preservation, multiline ranges and blank-line rules
remain those of [Phase 8A](remove-dry-run.md).

## Reuse and verification

`parseRemoveCommand` handles just name and flags. `removeProjectDependency`
reads the original, plans, and supplies its validator to the same
`commitDependencyChange` / `updateDependencyChange` helpers that add uses.
These helpers share snapshotting, safe writing, independent post-write reads,
update dispatch, success/failure output, cleanup and rollback. Only the plan,
validation closure and operation messages differ. No second writer, runner,
transaction or rollback implementation was introduced.

Existing metadata APIs keep their historical names (`AddMetadataSnapshot`,
`beginAddMetadata`, `rollbackAddMetadata`, `finishAddMetadata`) because they
already operate on bytes without knowing dependency names or operation kinds.
Both commands deliberately use the same `.cjpm.toml.cjx-add` directory lock,
so add/remove cannot bypass each other's operation guard. Recovery snapshot
layout and compatibility stay unchanged; this internal name is not a new
user-facing backup option.

`validateRemoveResult(original, modified, name)` recalculates the verified
plan from the original, compares all modified bytes, and scans the candidate.
The planner checks count minus one, target absence, retained order/name/raw
value/source/spec, section preservation and every byte outside the patch.
The validator runs on temporary bytes, committed bytes and post-update bytes.
CLI also re-reads after the writer returns and compares against expected bytes.
Failure cannot report success or continue to update after post-write mismatch.

On update nonzero or startup/wait exception, rollback restores original TOML
through `safeReplaceFile`. It restores original lock bytes via the existing
raw-byte engine, recreates an originally present lock deleted by update, or
safely removes a newly created lock when originally absent. Actual final bytes
and existence are re-checked. An external TOML edit is not overwritten; a lock
conflict similarly refuses destructive restoration. Incomplete recovery keeps
original snapshot files and reports their location.

Same boundaries as add: no rollback of global cache, Git downloads or network
side effects; no guarantee of crash/power-loss atomicity/durability or of other
programs honoring the CJX lock. Changes to lock during CJPM execution cannot
be reliably attributed to CJPM versus another process from bytes alone.
Pre-update and post-update-to-rollback lock comparisons remain in place.

## Actual Cangjie / CJPM 1.0.5 results

All true write/update tests used independent temporary projects. No true remove
was run on CJX or practice, and no SDK upgrade/modification was performed.

Real fixture `app` first depended on legitimate local `foo`, and initial
`cjpm update` succeeded. Default `remove foo` then succeeded with automatic
update. The empty `[dependencies]` header was retained. Subsequent list:

```text
Dependencies
-------------
(0 dependencies)
```

CJPM 1.0.5 accepted the empty section and produced a reasonable lock:

```toml
version = 0

[requires]
```

Real failure fixtures also contained a remaining `missing` dependency pointing
at `../missing`. Removing `foo` left that invalid Path, and actual CJPM exited
1. Both lock-present and lock-absent scenarios restored original manifest hash
and lock hash/existence. Actual output included:

```text
Updating dependencies...
Error: cjpm update failed (exit 1).
CJPM:
  Error: the path '../missing' of module 'missing' does not exist which is listed in 'dependencies' field at .\cjpm.toml
  Error: cjpm update failed
Project files were restored.
```

This real failure happens before lock generation. Lock creation/change/deletion
by a failing updater was separately verified with controlled updater hooks.
The Git removal test removes the sole Git declaration before invoking CJPM,
so it verifies remove+update without any remote clone prerequisite.

## Tests and commands

Original 281 tests retained and passed. Phase 8A CLI previews now explicitly
use `--dry-run`, retaining disk/hash assertions; the old forbidden-argument
case now rejects duplicate `--dry-run`, since a single flag is supported.

New: 20 controlled transaction tests + 20 CLI/write/integration tests, all
passed. Total 321 tests plus real-project read-only hash checks. Coverage:

- Real Path remove/update, sole/first/middle/last entries, nested cwd, retained
  list, initially present/absent lock, and Git removal without network.
- Both flags and their combination, missing dependency before side effects,
  quoted decoded key, LF/CRLF/BOM/Chinese text, both EOF newline states,
  multiline statement and unchanged leading notes, exact disk bytes.
- Actual CJPM failure with both original lock states; controlled failing
  updater with changed/new/deleted lock; TOML and lock rollback conflicts;
  temp-write failure, startup exception, rollback exception, post-write
  verification failure, changed retained values, and post-update external edit.
- Add/remove share the exact same operation guard. Failed cases never print
  `Removed dependency successfully.`. Recovery paths and final restoration
  messages are checked by the test runner.

Commands (installed SDK environment loaded first):

```powershell
cjfmt -f src/cli.cj
cjfmt -f src/remove_plan.cj
cjpm build
& tests/run.ps1
& tests/remove_write_cli.ps1
& tests/remove_cli.ps1
& tests/add_cli.ps1
& tests/update_cli.ps1
& tests/dry_run.ps1
```

Temporary fixture directories, including deliberately retained recovery cases,
are cleaned by their test harness after assertions. Build succeeds. Production:
12 Cangjie files / 2161 lines. Only `src/cli.cj` and `src/remove_plan.cj` changed;
the filesystem engine, metadata transaction and CJPM runner were reused intact.

practice invocation is exclusively `remove cui --dry-run`. Manifest SHA-256
remains `EA5F1F8F88788B0588A68D1C0021ACA79AB4DA4FEEAC58830DED5375B2EB7E53`;
lock remains `7B09643CC3E7107D2A0F09605871366C547525D40221945A60BEE8A9A5E3F3B0`.
CJX real manifest/lock hashes also remain unchanged.

Within these documented boundaries, remove meets the same V0.1 completion
standard as add. doctor/search/upgrade/central additions remain unimplemented.
