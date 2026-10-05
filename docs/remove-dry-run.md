# Phase 8A: remove planner and read-only CLI

Historical Phase 8A behavior. Phase 8B now writes by default; use
`cjx remove <name> --dry-run` for the preview described here. The byte range,
leading-comment policy and planner safety rules remain unchanged. See
[remove-write.md](remove-write.md). The original 8 CLI tests now use explicit
dry-run and retain their read-only assertions.

`cjx remove <name>` currently always previews. No write flag exists. It does
not call the safe writer, metadata transaction or CJPM runner. It reads only
the located `cjpm.toml`; `cjpm.lock` is not opened by this command.

## Plan and byte boundaries

`planRemoveDependency(original: String, name: String): RemovePlan` reuses
`scanDependencies`, `TextPatch`, `applyPatch`, and `classifyDependency`.
`RemovePlan` holds the selected `DependencyEntry`, deletion patch, validated
modified text, and the original declaration for display.

The patch is `[entry.lineStart, entry.statementEnd) -> ""`, with additional
checks that it stays inside section content and starts/ends on complete
statement-line boundaries (or ends at EOF). It removes indentation, all lines
of a multiline statement, spaces after the value, its trailing comment and
its own LF/CRLF terminator. A multiline statement's internal comments are
part of that statement and are removed too. The preview includes the trailing
comment but omits the final line terminator.

All preceding comment-only lines are preserved, even a block directly next
to the entry. Adjacency does not establish semantic ownership; a note could
describe the entire section or several entries. This conservative choice may
leave an obsolete leading note, but never silently deletes such explanations.
General notes, separated notes and trailing section notes stay unchanged.
There is no blank-line compression, including when deletion makes originally
separated blank lines adjacent.

The section header is always retained, including deletion of its last entry.
For EOF with no newline, delete the statement through EOF. The previous line's
newline stays intact: `[dependencies]\nfoo='1'` becomes `[dependencies]\n`.
No newline is added or removed outside the patch to preserve EOF appearance.
BOM, mixed LF/CRLF, UTF-8 Chinese text and other sections remain byte-identical
outside the deletion. UTF-8 half-open byte offsets come from the scanner;
`applyPatch` validates decoding at both slice boundaries.

## Matching and validation

Matching is exact and case-sensitive against the scanner's decoded key.
`"foo"`, `'foo'` and `"f\u006fo"` match CLI name `foo`. An existing
`'org::foo'` matches `org::foo`; this does not claim that CJPM 1.0.5 accepts it
for add. CLI accepts exactly one nonempty name and rejects option-looking names
starting with `-`, extra arguments and every flag (including `--dry-run`, since
dry-run is already unconditional). Parameter errors return 2. Missing project,
read errors, missing entry or scanner rejection return 1; successful preview 0.

There is no fallback for malformed/unsupported/duplicate input. The full
original scan must succeed before finding an entry, so malformed text even in
a later unrelated section refuses planning.

After applying the deletion, the planner checks:

- full scan succeeds and the dependencies section remains;
- removed name is absent and count decreases by exactly one;
- remaining entries keep their order, decoded key, exact raw value, source and spec;
- output byte length equals original length minus the range length;
- prefix and suffix bytes exactly match the original outside the range.

## Verification on Cangjie / CJPM 1.0.5, Windows

Commands were run after loading the installed SDK environment:

```powershell
cjfmt -f src/remove_plan.cj
cjfmt -f src/cli.cj
cjpm build
& tests/run.ps1
& tests/remove_cli.ps1
& tests/add_cli.ps1
& tests/update_cli.ps1
& tests/dry_run.ps1
```

Build succeeded. Original 237 tests all passed unchanged. New 36 planner
tests and 8 CLI tests passed: 281 total, plus real-project read-only hash
checks. Existing add/update regression tests still perform their authorized
integration writes/update only inside independent temporary fixtures; remove
itself never starts CJPM. All new test fixture directories were cleaned.

Planner coverage includes first/middle/last/only entries; missing names/section;
empty section; path/Git/version; quoted/literal/escaped names; case sensitivity;
trailing/leading/general/Chinese comments; separated notes; multiple blanks;
LF/CRLF/mixed endings/BOM; both EOF newline states; following sections;
multiline tables, internal comments and multiline strings with fake headers;
malformed strings/tables/later sections, unsupported subtables, duplicate
names/sections; unknown retained values; exact range and semantic checks.
CLI fixtures additionally check recursive file/directory state and SHA-256,
lock-present/absent states, argument rejection, nested cwd, help and Git preview.

practice output:

```text
Dry run

Would remove:

cui = { path = "../CangjieCUI" }

from:

C:\sourse\cj\practice\cjpm.toml

No files were modified.
```

practice TOML SHA-256 before/after:
`EA5F1F8F88788B0588A68D1C0021ACA79AB4DA4FEEAC58830DED5375B2EB7E53`.
CJX TOML unchanged:
`57766ACE28A83E1073987FB8BBA28431987FD2B5DA5309058E46BCB392292F2C`.
Both real lock hashes unchanged:
`7B09643CC3E7107D2A0F09605871366C547525D40221945A60BEE8A9A5E3F3B0`.

Production size: 12 Cangjie files / 2084 lines; new planner module 105 lines,
CLI +26 lines. The planner is ready for a separately authorized write stage;
safe commit, metadata snapshots, update and rollback remain unconnected to remove.
