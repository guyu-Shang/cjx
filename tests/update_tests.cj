package cjx

import std.fs.*
import std.env.{getVariable, setVariable, removeVariable}

var passed: Int64 = 0
var failed: Int64 = 0
let originalText = "[dependencies]\nold={path='../old'}\n"
let oldLock = "# 原锁内容\r\nversion = 0\r\n[requires]\r\n"
func verify(ok: Bool, message: String): Unit { if (!ok) { throw Exception(message) } }
func test(name: String, action: (Path) -> Unit): Unit {
    let parent = canonicalize(Path("."))
    let root = Directory.createTemp(parent)
    println("BEGIN ${name}")
    try { action(root); passed++; println("PASS ${name}") }
    catch (e: Exception) { failed++; println("FAIL ${name}: ${e.message}") }
    finally { verify(root.parent == parent, "unsafe cleanup"); remove(root, recursive: true) }
}
func fixture(root: Path, lock!: Bool = false): Path {
    let p = root.join("cjpm.toml")
    File.writeTo(p, originalText.toArray())
    if (lock) { File.writeTo(root.join("cjpm.lock"), oldLock.toArray()) }
    return p
}
func request(): AddRequest { return parseAddRequest(["foo", "--path", "../foo"]) }
func bytesAre(path: Path, text: String): Unit { verify(sameBytes(File.readFrom(path), text.toArray()), "disk bytes mismatch") }
func failure(): CjpmUpdateResult { return CjpmUpdateResult(1, "mock stdout error\n".toArray(), "mock stderr error\n".toArray()) }
func success(): CjpmUpdateResult { return CjpmUpdateResult(0, "success\n".toArray(), Array<Byte>()) }
func onlyMetadata(root: Path, lock: Bool): Unit { verify(Directory.readFrom(root).size == if (lock) { 2 } else { 1 }, "operation artifacts") }

main(): Int64 {
    test("01 update success generates lock", { r =>
        let p = fixture(r)
        verify(addProjectDependency(p, request(), false, updater: { root =>
            File.writeTo(root.join("cjpm.lock"), "new lock".toArray()); return success()
        }) == 0, "exit")
        bytesAre(p, planAdd(originalText, request()).modifiedText); bytesAre(r.join("cjpm.lock"), "new lock")
        onlyMetadata(r, true)
    })
    test("02 update success replaces existing lock", { r =>
        let p = fixture(r, lock: true)
        verify(addProjectDependency(p, request(), false, updater: { root =>
            File.writeTo(root.join("cjpm.lock"), "updated lock".toArray()); return success()
        }) == 0, "exit")
        bytesAre(r.join("cjpm.lock"), "updated lock"); onlyMetadata(r, true)
    })
    test("03 no-update preserves lock and bypasses updater", { r =>
        let p = fixture(r, lock: true)
        verify(addProjectDependency(p, request(), false, noUpdate: true, updater: { _ => throw Exception("must not run") }) == 0, "exit")
        bytesAre(p, planAdd(originalText, request()).modifiedText); bytesAre(r.join("cjpm.lock"), oldLock)
        onlyMetadata(r, true)
    })
    test("04 dry-run takes precedence over no-update", { r =>
        let p = fixture(r, lock: true)
        verify(addProjectDependency(p, request(), true, noUpdate: true, updater: { _ => throw Exception("must not run") }) == 0, "exit")
        bytesAre(p, originalText); bytesAre(r.join("cjpm.lock"), oldLock); onlyMetadata(r, true)
    })
    test("05 failure with unchanged absent lock", { r =>
        let p = fixture(r)
        verify(addProjectDependency(p, request(), false, updater: { _ => failure() }) == 1, "exit")
        bytesAre(p, originalText); onlyMetadata(r, false)
    })
    test("06 failure restores existing lock exact bytes", { r =>
        let p = fixture(r, lock: true)
        verify(addProjectDependency(p, request(), false, updater: { root =>
            File.writeTo(root.join("cjpm.lock"), [255, 0, 1]); return failure()
        }) == 1, "exit")
        bytesAre(p, originalText); bytesAre(r.join("cjpm.lock"), oldLock); onlyMetadata(r, true)
    })
    test("07 failure removes newly generated lock", { r =>
        let p = fixture(r)
        verify(addProjectDependency(p, request(), false, updater: { root =>
            File.writeTo(root.join("cjpm.lock"), "created by failed update".toArray()); return failure()
        }) == 1, "exit")
        bytesAre(p, originalText); verify(!exists(r.join("cjpm.lock")), "new lock remains"); onlyMetadata(r, false)
    })
    test("08 failure restores lock deleted during update", { r =>
        let p = fixture(r, lock: true)
        verify(addProjectDependency(p, request(), false, updater: { root => remove(root.join("cjpm.lock")); return failure() }) == 1, "exit")
        bytesAre(p, originalText); bytesAre(r.join("cjpm.lock"), oldLock); onlyMetadata(r, true)
    })
    test("09 changed TOML during update is not overwritten", { r =>
        let p = fixture(r)
        let external = planAdd(originalText, request()).modifiedText + "# external\n"
        verify(addProjectDependency(p, request(), false, updater: { root =>
            File.writeTo(root.join("cjpm.toml"), external.toArray()); return failure()
        }) == 1, "exit")
        bytesAre(p, external); bytesAre(r.join(".cjpm.toml.cjx-add").join("cjpm.toml.original"), originalText)
    })
    test("10 changed TOML during rollback is not overwritten", { r =>
        let p = fixture(r)
        verify(addProjectDependency(p, request(), false, updater: { _ => failure() }, rollbackHook: { stage, path =>
            if (stage == "toml") { File.writeTo(path, "# user edit".toArray()) }
        }) == 1, "exit")
        bytesAre(p, "# user edit"); verify(exists(r.join(".cjpm.toml.cjx-add")), "recovery snapshots missing")
    })
    test("11 changed lock during rollback is not overwritten", { r =>
        let p = fixture(r, lock: true)
        verify(addProjectDependency(p, request(), false, updater: { root =>
            File.writeTo(root.join("cjpm.lock"), "CJPM changed lock".toArray()); return failure()
        }, rollbackHook: { stage, path => if (stage == "lock") { File.writeTo(path, "external lock".toArray()) } }) == 1, "exit")
        bytesAre(p, originalText); bytesAre(r.join("cjpm.lock"), "external lock")
        bytesAre(r.join(".cjpm.toml.cjx-add").join("cjpm.lock.original"), oldLock)
    })
    test("12 unable to start updater restores metadata", { r =>
        let p = fixture(r, lock: true)
        verify(addProjectDependency(p, request(), false, updater: { _ => throw Exception("unable to start cjpm. Make sure the Cangjie SDK environment is loaded.") }) == 1, "exit")
        bytesAre(p, originalText); bytesAre(r.join("cjpm.lock"), oldLock); onlyMetadata(r, true)
    })
    test("13 runner executable not found", { r =>
        var rejected = false
        try { runCjpmExecutable(r, r.join("missing.exe")) } catch (e: Exception) { rejected = e.message.contains("unable to start") }
        verify(rejected, "runner start message"); verify(Directory.readFrom(r).isEmpty(), "runner artifacts")
    })
    test("14 runner non-executable directory rejected", { r =>
        let exe = r.join("invalid.exe"); Directory.create(exe)
        var rejected = false
        try { runCjpmExecutable(r, exe) } catch (e: Exception) { rejected = e.message.contains("SDK environment") }
        verify(rejected, "directory executable should fail"); verify(Directory.readFrom(r).size == 1, "runner artifacts")
    })
    test("15 runner exit stdout stderr and working directory", { r =>
        let executable = canonicalize(Path("fake-cjpm.exe"))
        let result = runCjpmExecutable(r, executable)
        verify(result.exitCode == 7, "exit code")
        verify(processOutputText(result.stdout).startsWith("CWD=" + r.toString() + "\nARGS=update\n"), "working directory or args")
        verify(result.stdout.size > 300000 && result.stderr.size == 300000, "large dual output capture")
        verify(Directory.readFrom(r).isEmpty(), "runner cleanup")
    })
    test("16 rollback itself fails snapshots remain", { r =>
        let p = fixture(r, lock: true)
        verify(addProjectDependency(p, request(), false, updater: { root =>
            File.writeTo(root.join("cjpm.lock"), "changed".toArray()); return failure()
        }, rollbackHook: { _, _ => throw Exception("injected rollback failure") }) == 1, "exit")
        bytesAre(r.join(".cjpm.toml.cjx-add").join("cjpm.toml.original"), originalText)
        bytesAre(r.join(".cjpm.toml.cjx-add").join("cjpm.lock.original"), oldLock)
    })
    test("17 PATH without CJPM reports missing environment", { _ =>
        let originalPath = getVariable("PATH")
        try {
            setVariable("PATH", "") // Test process only; restore immediately, never system PATH.
            var rejected = false
            try { locateCjpm() } catch (e: Exception) { rejected = e.message.contains("not found on PATH") && e.message.contains("SDK environment") }
            verify(rejected, "PATH error")
        } finally { match (originalPath) { case Some(p) => setVariable("PATH", p); case None => removeVariable("PATH") } }
    })
    test("18 unchanged lock failure skips lock write", { r =>
        let p = fixture(r, lock: true)
        verify(addProjectDependency(p, request(), false, updater: { _ => failure() }) == 1, "exit")
        bytesAre(p, originalText); bytesAre(r.join("cjpm.lock"), oldLock); onlyMetadata(r, true)
    })
    test("19 operation lock prevents second add", { r =>
        let p = fixture(r)
        Directory.create(r.join(".cjpm.toml.cjx-add"))
        verify(addProjectDependency(p, request(), false, updater: { _ => throw Exception("must not run") }) == 1, "exit")
        bytesAre(p, originalText)
    })
    test("20 no-update flags validate and combine", { _ =>
        let (_, dry, noUpdate) = parseAddCommand(["foo", "--no-update", "--path", "../foo", "--dry-run"])
        verify(dry && noUpdate, "flags")
        verify(runCli(["add", "foo", "--path", "x", "--no-update", "--no-update"]) == 2, "duplicate flag")
        verify(runCli(["add", "foo", "--path", "--no-update"]) == 2, "missing value flag")
    })
    test("21 lock directory after update refuses destructive restoration", { r =>
        let p = fixture(r)
        verify(addProjectDependency(p, request(), false, updater: { root => Directory.create(root.join("cjpm.lock")); return failure() }) == 1, "exit")
        bytesAre(p, originalText); verify(FileInfo(r.join("cjpm.lock")).isDirectory(), "directory removed")
        verify(exists(r.join(".cjpm.toml.cjx-add")), "recovery snapshots missing")
    })
    test("22 successful update with external TOML mutation refuses success", { r =>
        let p = fixture(r)
        verify(addProjectDependency(p, request(), false, updater: { root =>
            File.writeTo(root.join("cjpm.toml"), "# external version".toArray()); return success()
        }) == 1, "exit")
        bytesAre(p, "# external version")
    })
    test("23 lock changed before updater is preserved", { r =>
        let p = fixture(r, lock: true)
        verify(addProjectDependency(p, request(), false, writer: { path, old, modified, validate =>
            let result = safeReplaceFile(path, old, modified, validate: validate)
            File.writeTo(path.parent.join("cjpm.lock"), "external before update".toArray())
            return result
        }, updater: { _ => throw Exception("updater must not run") }) == 1, "exit")
        bytesAre(p, originalText); bytesAre(r.join("cjpm.lock"), "external before update")
    })
    println("${passed} update transaction tests passed; ${failed} failed")
    return if (failed == 0) { 0 } else { 1 }
}
