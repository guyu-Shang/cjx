package cjx

import std.fs.*

var passed: Int64 = 0
var failed: Int64 = 0
let initial = "[dependencies]\nold={path='../old'}\n"
func verify(ok: Bool, message: String): Unit { if (!ok) { throw Exception(message) } }
func test(name: String, action: (Path) -> Unit): Unit {
    let parent = canonicalize(Path("."))
    let root = Directory.createTemp(parent)
    println("BEGIN ${name}")
    try { action(root); passed++; println("PASS ${name}") }
    catch (e: Exception) { failed++; println("FAIL ${name}: ${e.message}") }
    finally { verify(root.parent == parent, "unsafe cleanup"); remove(root, recursive: true) }
}
func fixture(root: Path): Path {
    let p = root.join("cjpm.toml"); File.writeTo(p, initial.toArray()); return p
}
func request(): AddRequest { return parseAddRequest(["foo", "--path", "../foo"]) }
func assertBytes(path: Path, text: String): Unit { verify(sameBytes(File.readFrom(path), text.toArray()), "wrong disk bytes") }

main(): Int64 {
    test("01 external modification refusal reaches CLI", { r =>
        let p = fixture(r)
        let external = initial + "# external\n"
        let code = addProjectDependency(p, request(), false, noUpdate: true, writer: { path, old, modified, validate =>
            safeReplaceFileForTest(path, old, modified, validate, { stage, _ =>
                if (stage == "before-check") { File.writeTo(path, external.toArray()) }
            })
        })
        verify(code == 1, "conflict exit"); assertBytes(p, external)
    })
    test("02 temp write failure reaches CLI", { r =>
        let p = fixture(r)
        let code = addProjectDependency(p, request(), false, noUpdate: true, writer: { path, old, modified, validate =>
            safeReplaceFileForTest(path, old, modified, validate, { stage, _ =>
                if (stage == "write") { throw Exception("injected temporary write failure") }
            })
        })
        verify(code == 1, "write exit"); assertBytes(p, initial)
    })
    test("03 recovery failure preserves recovery path", { r =>
        let p = fixture(r)
        let code = addProjectDependency(p, request(), false, noUpdate: true, writer: { path, old, modified, validate =>
            safeReplaceFileForTest(path, old, modified, validate, { stage, _ =>
                if (stage == "replace" || stage == "restore") { throw Exception("injected " + stage) }
            })
        })
        verify(code == 1, "recovery exit"); assertBytes(r.join(".cjpm.toml.cjx-lock").join("original"), initial)
    })
    test("04 post-transaction external change cannot report success", { r =>
        let p = fixture(r)
        let code = addProjectDependency(p, request(), false, noUpdate: true, writer: { path, old, modified, validate =>
            let result = safeReplaceFile(path, old, modified, validate: validate)
            File.writeTo(path, (initial + "# intervening edit\n").toArray())
            return result
        })
        verify(code == 1, "final verification exit"); assertBytes(p, initial + "# intervening edit\n")
    })
    test("05 dry-run never invokes writer", { r =>
        let p = fixture(r)
        let code = addProjectDependency(p, request(), true, writer: { _, _, _, _ =>
            throw Exception("dry-run called writer")
        })
        verify(code == 0, "dry-run exit"); assertBytes(p, initial)
        verify(Directory.readFrom(r).size == 1, "dry-run artifacts")
    })
    test("06 disk validator checks retained dependencies", { r =>
        let p = fixture(r)
        let code = addProjectDependency(p, request(), false, noUpdate: true, writer: { _, _, _, validate =>
            validate("[dependencies]\nfoo={path='../foo'}\n".toArray())
            return SafeWriteResult("")
        })
        verify(code == 1, "validator exit"); assertBytes(p, initial)
    })
    test("07 committed cleanup warning reaches CLI", { r =>
        let p = fixture(r)
        let code = addProjectDependency(p, request(), false, noUpdate: true, writer: { path, old, modified, validate =>
            safeReplaceFileForTest(path, old, modified, validate, { stage, _ =>
                if (stage == "cleanup-backup") { throw Exception("injected cleanup") }
            })
        })
        verify(code == 0, "committed warning exit"); assertBytes(p, planAdd(initial, request()).modifiedText)
        assertBytes(r.join(".cjpm.toml.cjx-lock").join("original"), initial)
    })
    test("08 dry-run option preserves parameter validation", { _ =>
        for (args in [
            ["add", "foo", "--path", "x", "--dry-run", "--dry-run"],
            ["add", "foo", "--path", "--dry-run"],
            ["add", "foo", "--git", "url", "--tag", "--dry-run", "v1"],
            ["add", "foo", "--path", "x", "--force"]
        ]) { verify(runCli(args) == 2, "parameter exit") }
    })
    test("09 final UTF8 failure reaches CLI", { r =>
        let p = fixture(r)
        let code = addProjectDependency(p, request(), false, noUpdate: true, writer: { path, old, modified, validate =>
            let result = safeReplaceFile(path, old, modified, validate: validate)
            File.writeTo(path, [255])
            return result
        })
        verify(code == 1, "UTF8 final verification exit")
    })
    println("${passed} add CLI failure tests passed; ${failed} failed")
    return if (failed == 0) { 0 } else { 1 }
}
