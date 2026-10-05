package cjx

import std.fs.*

var passed: Int64 = 0
var failed: Int64 = 0
let oldText = "[dependencies]\nold = { path = '../old' }\n"

func verify(ok: Bool, message: String): Unit { if (!ok) { throw Exception(message) } }
func test(name: String, action: (Path) -> Unit): Unit {
    // The runner's cwd is an isolated, generated temporary directory.
    let parent = canonicalize(Path("."))
    let root = Directory.createTemp(parent)
    try { action(root); passed++; println("PASS ${name}") }
    catch (e: Exception) { failed++; println("FAIL ${name}: ${e.message}") }
    finally {
        verify(root.parent == parent, "unsafe fixture cleanup")
        remove(root, recursive: true)
    }
}
func rejected(action: () -> Unit): String {
    try { action() } catch (e: Exception) { return e.message }
    throw Exception("expected failure")
}
func plan(text: String): AddPlan { return planAdd(text, parseAddRequest(["foo", "--path", "../中文 库"])) }
func fixture(root: Path, text: String): Path {
    let target = root.join("cjpm.toml")
    File.writeTo(target, text.toArray())
    return target
}
func unchanged(target: Path, text: String): Unit {
    verify(sameBytes(File.readFrom(target), text.toArray()), "original bytes changed")
}
func validator(bytes: Array<Byte>): Unit {
    match (scanDependencies(String.fromUtf8(bytes))) {
        case Some(s) =>
            var found = false
            for (entry in s.entries) {
                if (entry.key == "foo") {
                    let info = classifyDependency(entry)
                    found = sourceLabel(info.source) == "path" && info.spec == "../中文 库"
                }
            }
            verify(found, "new dependency semantics")
        case None => throw Exception("section missing")
    }
}
func writeWith(target: Path, text: String, hook: (String, Path) -> Unit): SafeWriteResult {
    return safeReplaceFileForTest(target, text.toArray(), plan(text).modifiedText.toArray(), validator, hook)
}
func success(root: Path, text: String): Unit {
    let target = fixture(root, text)
    let result = safeReplaceFile(target, text.toArray(), plan(text).modifiedText.toArray(), validate: validator)
    verify(result.warning.isEmpty(), "unexpected warning")
    unchanged(target, plan(text).modifiedText)
    verify(Directory.readFrom(root).size == 1, "leaked artifacts")
}
func failAt(root: Path, stage: String): Unit {
    let target = fixture(root, oldText)
    let message = rejected({ => writeWith(target, oldText, { s, _ =>
        if (s == stage) { throw Exception("injected " + stage) }
    }) })
    verify(message.contains("injected " + stage), "cause lost")
    unchanged(target, oldText)
    verify(Directory.readFrom(root).size == 1, "precommit/rollback leak")
}

main(): Int64 {
    test("01 normal transaction and add semantics", { r => success(r, oldText) })
    test("02 external change before commit", { r =>
        let p = fixture(r, oldText)
        let external = oldText + "# external\n"
        let msg = rejected({ => writeWith(p, oldText, { s, _ => if (s == "before-check") { File.writeTo(p, external.toArray()) } }) })
        verify(msg.contains("changed since the operation started. No changes were written."), "conflict message")
        unchanged(p, external)
        verify(Directory.readFrom(r).size == 1, "conflict cleanup")
    })
    test("03 temp creation failure", { r => failAt(r, "create") })
    test("04 partial temp write failure", { r =>
        let p = fixture(r, oldText)
        rejected({ => writeWith(p, oldText, { s, t =>
            if (s == "write") { File.writeTo(t, "partial".toArray()); throw Exception("disk full injected") }
        }) })
        unchanged(p, oldText)
        verify(Directory.readFrom(r).size == 1, "write failure cleanup")
    })
    test("05 temp byte verification failure", { r =>
        let p = fixture(r, oldText)
        let msg = rejected({ => writeWith(p, oldText, { s, t => if (s == "closed") { File.writeTo(t, "corrupt".toArray()) } }) })
        verify(msg.contains("Temporary file byte verification failed"), "temp verification")
        unchanged(p, oldText)
    })
    test("06 replacement failure restores original", { r => failAt(r, "replace") })
    test("07 cleanup backup failure is committed warning", { r =>
        let p = fixture(r, oldText)
        let result = writeWith(p, oldText, { s, _ => if (s == "cleanup-backup") { throw Exception("cannot delete backup") } })
        verify(result.warning.contains("Backup retained"), "cleanup status")
        unchanged(p, plan(oldText).modifiedText)
        unchanged(r.join(".cjpm.toml.cjx-lock").join("original"), oldText)
        rejected({ => safeReplaceFile(p, plan(oldText).modifiedText.toArray(), oldText.toArray()) })
    })
    test("08 missing original", { r =>
        rejected({ => safeReplaceFile(r.join("cjpm.toml"), oldText.toArray(), plan(oldText).modifiedText.toArray()) })
        verify(Directory.readFrom(r).isEmpty(), "created artifacts for missing file")
    })
    test("09 original becomes directory", { r =>
        let p = fixture(r, oldText)
        rejected({ => writeWith(p, oldText, { s, _ => if (s == "before-check") { remove(p); Directory.create(p) } }) })
        verify(FileInfo(p).isDirectory(), "external directory touched")
        verify(Directory.readFrom(r).size == 1, "directory conflict cleanup")
    })
    test("10 existing temporary names preserved", { r =>
        let sentinel = r.join("tmpFileAAAAAA")
        File.writeTo(sentinel, "user file".toArray())
        File.writeTo(r.join(".cjpm.toml.cjx.tmp"), "user file".toArray())
        let p = fixture(r, oldText)
        safeReplaceFile(p, oldText.toArray(), plan(oldText).modifiedText.toArray())
        unchanged(sentinel, "user file")
        unchanged(r.join(".cjpm.toml.cjx.tmp"), "user file")
    })
    test("11 BOM", { r => success(r, "\u{FEFF}" + oldText) })
    test("12 LF", { r => success(r, "[dependencies]\n") })
    test("13 CRLF", { r => success(r, "[dependencies]\r\nold={path='../old'}\r\n") })
    test("14 Chinese content", { r => success(r, "# 中文注释\n[dependencies]\nold={path='../原始库'}\n") })
    test("15 empty file", { r => success(r, "") })
    test("16 no final newline", { r => success(r, "[dependencies]") })
    test("17 final newline", { r => success(r, "[dependencies]\n\n") })
    test("18 larger file", { r => success(r, "# 中文保留注释\r\n" * 60000 + "[dependencies]\r\n") })
    test("19 consecutive transactions", { r =>
        let p = fixture(r, oldText)
        var current = oldText
        for (i in 0..12) {
            let next = planAdd(current, parseAddRequest(["foo${i}", "--path", "../foo"])).modifiedText
            safeReplaceFile(p, current.toArray(), next.toArray())
            unchanged(p, next); current = next
        }
        verify(Directory.readFrom(r).size == 1, "consecutive write leak")
    })
    test("20 failed save preserves original bytes", { r => failAt(r, "save") })
    test("21 flush failure closes and cleans", { r => failAt(r, "flush") })
    test("22 final corrupt bytes restore and retain rejected", { r =>
        let p = fixture(r, oldText)
        let msg = rejected({ => writeWith(p, oldText, { s, t => if (s == "final") { File.writeTo(t, "corrupt".toArray()) } }) })
        verify(msg.contains("SERIOUS") && msg.contains("Original bytes restored"), "final verification report")
        unchanged(p, oldText)
        unchanged(r.join(".cjpm.toml.cjx-lock").join("rejected"), "corrupt")
    })
    test("23 restore failure retains exact original backup", { r =>
        let p = fixture(r, oldText)
        let msg = rejected({ => writeWith(p, oldText, { s, _ =>
            if (s == "replace" || s == "restore") { throw Exception("injected " + s) }
        }) })
        verify(msg.contains("SERIOUS: recovery failed"), "restore report")
        unchanged(r.join(".cjpm.toml.cjx-lock").join("original"), oldText)
        verify(!exists(p), "must not pretend path restored")
    })
    test("24 temp cleanup failure reported", { r =>
        let p = fixture(r, oldText)
        let msg = rejected({ => writeWith(p, oldText, { s, _ =>
            if (s == "write" || s == "cleanup-temp") { throw Exception("injected " + s) }
        }) })
        verify(msg.contains("Temporary file retained"), "cleanup failure hidden")
        unchanged(p, oldText)
    })
    test("25 lock collision never reused", { r =>
        let p = fixture(r, oldText)
        let lock = r.join(".cjpm.toml.cjx-lock")
        Directory.create(lock)
        File.writeTo(lock.join("owner"), "another transaction".toArray())
        rejected({ => safeReplaceFile(p, oldText.toArray(), plan(oldText).modifiedText.toArray()) })
        unchanged(p, oldText); unchanged(lock.join("owner"), "another transaction")
    })
    test("26 malformed replacement before write", { r =>
        let p = fixture(r, oldText)
        rejected({ => safeReplaceFile(p, oldText.toArray(), "[dependencies]\nx={".toArray()) })
        unchanged(p, oldText); verify(Directory.readFrom(r).size == 1, "malformed artifacts")
    })
    test("27 invalid UTF8 before write", { r =>
        let p = fixture(r, oldText)
        rejected({ => safeReplaceFile(p, oldText.toArray(), [255]) })
        unchanged(p, oldText)
    })
    test("28 change between recheck and rename", { r =>
        let p = fixture(r, oldText)
        let external = oldText + "# new external\n"
        rejected({ => writeWith(p, oldText, { s, _ => if (s == "save") { File.writeTo(p, external.toArray()) } }) })
        unchanged(p, external)
        verify(Directory.readFrom(r).size == 1, "race recovery cleanup")
    })
    test("29 external file in rename gap is not overwritten", { r =>
        let p = fixture(r, oldText)
        let msg = rejected({ => writeWith(p, oldText, { s, _ => if (s == "replace") { File.writeTo(p, "external".toArray()) } }) })
        verify(msg.contains("recovery failed"), "must report pending recovery")
        unchanged(p, "external"); unchanged(r.join(".cjpm.toml.cjx-lock").join("original"), oldText)
    })
    test("30 semantic validation reruns at temp", { r =>
        let p = fixture(r, oldText)
        let count = [Int64(0)]
        rejected({ => safeReplaceFile(p, oldText.toArray(), plan(oldText).modifiedText.toArray(), validate: { b =>
            validator(b); count[0]++
            if (count[0] == 2) { throw Exception("semantic validation failure") }
        }) })
        verify(count[0] == 2, "validator call count"); unchanged(p, oldText)
    })
    test("31 semantic validation reruns at final", { r =>
        let p = fixture(r, oldText)
        let count = [Int64(0)]
        rejected({ => safeReplaceFile(p, oldText.toArray(), plan(oldText).modifiedText.toArray(), validate: { b =>
            validator(b); count[0]++
            if (count[0] == 3) { throw Exception("final semantic failure") }
        }) })
        verify(count[0] == 3, "validator call count"); unchanged(p, oldText)
    })
    test("32 lock cleanup warning after commit", { r =>
        let p = fixture(r, oldText)
        let result = writeWith(p, oldText, { s, _ => if (s == "cleanup-lock") { throw Exception("lock cleanup denied") } })
        verify(result.warning.contains("Lock retained"), "lock warning")
        unchanged(p, plan(oldText).modifiedText)
    })
    test("33 rename without overwrite rejects existing target", { r =>
        let p = fixture(r, oldText)
        let temp = r.join("other")
        File.writeTo(temp, "new".toArray())
        rejected({ => rename(temp, to: p) })
        unchanged(p, oldText); unchanged(temp, "new")
    })
    test("34 temp collisions fail closed without overwriting", { r =>
        var created: Int64 = 0
        var refused: Int64 = 0
        for (_ in 0..64) {
            try {
                let f = File.createTemp(r)
                f.write("sentinel".toArray()); f.close(); created++
            } catch (_: Exception) { refused++ }
        }
        verify(created > 0 && created + refused == 64, "temp attempts")
        verify(Directory.readFrom(r).size == created, "temp collision overwrote a file")
        for (entry in Directory.readFrom(r)) { unchanged(entry.path, "sentinel") }
    })
    test("35 validator cannot mutate planned bytes", { r =>
        let p = fixture(r, oldText)
        let next = plan(oldText).modifiedText
        safeReplaceFile(p, oldText.toArray(), next.toArray(), validate: { bytes => bytes[0] = 0 })
        unchanged(p, next)
    })
    test("36 stale snapshot rejected before temp creation", { r =>
        let p = fixture(r, oldText + "# external\n")
        rejected({ => safeReplaceFile(p, oldText.toArray(), plan(oldText).modifiedText.toArray()) })
        unchanged(p, oldText + "# external\n")
        verify(Directory.readFrom(r).size == 1, "stale snapshot artifacts")
    })
    test("37 final file disappeared restores backup", { r =>
        let p = fixture(r, oldText)
        rejected({ => writeWith(p, oldText, { s, t => if (s == "final") { remove(t) } }) })
        unchanged(p, oldText)
        verify(Directory.readFrom(r).size == 1, "restoration cleanup")
    })
    println("${passed} safe-write tests passed; ${failed} failed")
    return if (failed == 0) { 0 } else { 1 }
}
