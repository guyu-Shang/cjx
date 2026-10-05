package cjx

import std.fs.*

var passed: Int64 = 0
var failed: Int64 = 0
let initial = "[dependencies]\n# keep notes\nfoo={path='../foo'} # remove note\nold={path='../old'}\n"
let oldLock = "# 原始 lock\r\nversion = 0\r\n[requires]\r\n"
func verify(ok: Bool, reason: String): Unit { if (!ok) { throw Exception(reason) } }
func test(name: String, body: (Path) -> Unit): Unit {
    let parent = canonicalize(Path("."))
    let root = Directory.createTemp(parent)
    println("BEGIN ${name}")
    try { body(root); passed++; println("PASS ${name}") }
    catch (e: Exception) { failed++; println("FAIL ${name}: ${e.message}") }
    finally { verify(root.parent == parent, "unsafe cleanup"); remove(root, recursive: true) }
}
func fixture(root: Path, lock!: Bool = false): Path {
    let p = root.join("cjpm.toml")
    File.writeTo(p, initial.toArray())
    if (lock) { File.writeTo(root.join("cjpm.lock"), oldLock.toArray()) }
    return p
}
func bytesAre(path: Path, text: String): Unit { verify(sameBytes(File.readFrom(path), text.toArray()), "bytes differ") }
func success(): CjpmUpdateResult { return CjpmUpdateResult(0, Array<Byte>(), Array<Byte>()) }
func failure(): CjpmUpdateResult { return CjpmUpdateResult(1, Array<Byte>(), "controlled update failure".toArray()) }
func restored(root: Path, path: Path, lock: Bool): Unit {
    bytesAre(path, initial)
    if (lock) { bytesAre(root.join("cjpm.lock"), oldLock) } else { verify(!exists(root.join("cjpm.lock")), "new lock left") }
    verify(Directory.readFrom(root).size == if (lock) { 2 } else { 1 }, "transaction artifacts")
}

main(): Int64 {
    test("01 success updates existing lock and semantic validator", { r =>
        let p = fixture(r, lock: true)
        verify(removeProjectDependency(p, "foo", false, updater: { root =>
            verify(root == r, "wrong update cwd")
            File.writeTo(root.join("cjpm.lock"), "updated".toArray()); return success()
        }) == 0, "exit")
        bytesAre(p, planRemoveDependency(initial, "foo").modifiedText)
        bytesAre(r.join("cjpm.lock"), "updated")
        verify(Directory.readFrom(r).size == 2, "cleanup")
    })
    test("02 success generates initially absent lock", { r =>
        let p = fixture(r)
        verify(removeProjectDependency(p, "foo", false, updater: { root =>
            File.writeTo(root.join("cjpm.lock"), "new".toArray()); return success()
        }) == 0, "exit")
        bytesAre(r.join("cjpm.lock"), "new")
    })
    test("03 no-update bypasses updater and keeps lock", { r =>
        let p = fixture(r, lock: true)
        verify(removeProjectDependency(p, "foo", false, noUpdate: true, updater: { _ => throw Exception("must not start") }) == 0, "exit")
        bytesAre(p, planRemoveDependency(initial, "foo").modifiedText); bytesAre(r.join("cjpm.lock"), oldLock)
    })
    test("04 dry-run plus no-update bypasses writer updater snapshots", { r =>
        let p = fixture(r, lock: true)
        verify(removeProjectDependency(p, "foo", true, noUpdate: true,
            writer: { _, _, _, _ => throw Exception("must not write") }, updater: { _ => throw Exception("must not start") }) == 0, "exit")
        restored(r, p, true)
    })
    test("05 missing dependency bypasses writer updater snapshots", { r =>
        let p = fixture(r)
        verify(removeProjectDependency(p, "missing", false,
            writer: { _, _, _, _ => throw Exception("must not write") }, updater: { _ => throw Exception("must not start") }) == 1, "exit")
        restored(r, p, false)
    })
    test("06 failed update without lock restores TOML", { r =>
        let p = fixture(r)
        verify(removeProjectDependency(p, "foo", false, updater: { _ => failure() }) == 1, "exit")
        restored(r, p, false)
    })
    test("07 failed update restores opaque lock bytes", { r =>
        let p = fixture(r, lock: true)
        verify(removeProjectDependency(p, "foo", false, updater: { root =>
            File.writeTo(root.join("cjpm.lock"), [255, 0, 1]); return failure()
        }) == 1, "exit")
        restored(r, p, true)
    })
    test("08 failed update removes newly created lock", { r =>
        let p = fixture(r)
        verify(removeProjectDependency(p, "foo", false, updater: { root =>
            File.writeTo(root.join("cjpm.lock"), "new failed lock".toArray()); return failure()
        }) == 1, "exit")
        restored(r, p, false)
    })
    test("09 failed update recreates deleted original lock", { r =>
        let p = fixture(r, lock: true)
        verify(removeProjectDependency(p, "foo", false, updater: { root => remove(root.join("cjpm.lock")); return failure() }) == 1, "exit")
        restored(r, p, true)
    })
    test("10 TOML changed during update preserved", { r =>
        let p = fixture(r)
        verify(removeProjectDependency(p, "foo", false, updater: { root =>
            File.writeTo(root.join("cjpm.toml"), "# user new content".toArray()); return failure()
        }) == 1, "exit")
        bytesAre(p, "# user new content"); bytesAre(r.join(".cjpm.toml.cjx-add").join("cjpm.toml.original"), initial)
    })
    test("11 TOML changed at rollback preserved", { r =>
        let p = fixture(r)
        verify(removeProjectDependency(p, "foo", false, updater: { _ => failure() }, rollbackHook: { stage, path =>
            if (stage == "toml") { File.writeTo(path, "# edited".toArray()) }
        }) == 1, "exit")
        bytesAre(p, "# edited"); verify(exists(r.join(".cjpm.toml.cjx-add")), "recovery missing")
    })
    test("12 lock changed at rollback preserved", { r =>
        let p = fixture(r, lock: true)
        verify(removeProjectDependency(p, "foo", false, updater: { root =>
            File.writeTo(root.join("cjpm.lock"), "CJPM version".toArray()); return failure()
        }, rollbackHook: { stage, path => if (stage == "lock") { File.writeTo(path, "user lock".toArray()) } }) == 1, "exit")
        bytesAre(p, initial); bytesAre(r.join("cjpm.lock"), "user lock")
        bytesAre(r.join(".cjpm.toml.cjx-add").join("cjpm.lock.original"), oldLock)
    })
    test("13 safe temp write failure leaves original and skips update", { r =>
        let p = fixture(r, lock: true)
        verify(removeProjectDependency(p, "foo", false, writer: { path, old, modified, validate =>
            safeReplaceFileForTest(path, old, modified, validate, { stage, _ => if (stage == "write") { throw Exception("injected write") } })
        }, updater: { _ => throw Exception("must not start") }) == 1, "exit")
        restored(r, p, true)
    })
    test("14 unable to start CJPM restores both metadata", { r =>
        let p = fixture(r, lock: true)
        verify(removeProjectDependency(p, "foo", false, updater: { _ =>
            throw Exception("unable to start cjpm. Make sure the Cangjie SDK environment is loaded.")
        }) == 1, "exit")
        restored(r, p, true)
    })
    test("15 rollback failure retains snapshots", { r =>
        let p = fixture(r, lock: true)
        verify(removeProjectDependency(p, "foo", false, updater: { _ => failure() }, rollbackHook: { _, _ => throw Exception("injected rollback") }) == 1, "exit")
        bytesAre(p, planRemoveDependency(initial, "foo").modifiedText)
        bytesAre(r.join(".cjpm.toml.cjx-add").join("cjpm.toml.original"), initial)
    })
    test("16 post-write verification rejects external edit and skips update", { r =>
        let p = fixture(r)
        verify(removeProjectDependency(p, "foo", false, writer: { path, old, modified, validate =>
            let result = safeReplaceFile(path, old, modified, validate: validate)
            File.writeTo(path, "# external".toArray()); return result
        }, updater: { _ => throw Exception("must not start") }) == 1, "exit")
        bytesAre(p, "# external"); verify(exists(r.join(".cjpm.toml.cjx-add")), "snapshot missing")
    })
    test("17 disk validator rejects changed retained dependency", { r =>
        let p = fixture(r)
        verify(removeProjectDependency(p, "foo", false, writer: { _, _, _, validate =>
            validate("[dependencies]\nold={path='wrong'}\n".toArray()); return SafeWriteResult("")
        }) == 1, "exit")
        restored(r, p, false)
    })
    test("18 successful updater with altered TOML refuses success", { r =>
        let p = fixture(r)
        verify(removeProjectDependency(p, "foo", false, updater: { root =>
            File.writeTo(root.join("cjpm.toml"), "# external".toArray()); return success()
        }) == 1, "exit")
        bytesAre(p, "# external")
    })
    test("19 option parsing precedence duplicate and unknown", { _ =>
        let (name, dryRun, noUpdate) = parseRemoveCommand(["org::foo", "--no-update", "--dry-run"])
        verify(name == "org::foo" && dryRun && noUpdate, "options")
        for (args in [Array<String>(), ["foo", "bar"], ["foo", "--force"], ["foo", "--dry-run", "--dry-run"], ["foo", "--no-update", "--no-update"]]) {
            var rejected = false
            try { parseRemoveCommand(args) } catch (_: Exception) { rejected = true }
            verify(rejected, "bad options")
        }
    })
    test("20 add and remove share the same operation lock", { r =>
        let p = fixture(r)
        let snapshot = beginAddMetadata(p, initial.toArray())
        verify(removeProjectDependency(p, "foo", false, updater: { _ => throw Exception("must not start") }) == 1, "exit")
        bytesAre(p, initial); verify(finishAddMetadata(snapshot).isEmpty(), "cleanup")
    })
    println("${passed} remove transaction tests passed; ${failed} failed")
    return if (failed == 0) { 0 } else { 1 }
}
