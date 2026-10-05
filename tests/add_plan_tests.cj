package cjx

var passed: Int64 = 0
var failed: Int64 = 0
func verify(ok: Bool, message: String): Unit { if (!ok) { throw Exception(message) } }
func test(name: String, action: () -> Unit): Unit {
    try { action(); passed++; println("PASS ${name}") }
    catch (e: Exception) { failed++; println("FAIL ${name}: ${e.message}") }
}
func rejects(action: () -> Unit): Unit {
    var rejected = false
    try { action() } catch (_: Exception) { rejected = true }
    verify(rejected, "expected rejection")
}
func planned(text: String, args: Array<String>): AddPlan {
    let plan = planAdd(text, parseAddRequest(args))
    let p = plan.patch
    verify(p.start == p.end, "must insert")
    let b = text.toArray()
    let a = plan.modifiedText.toArray()
    verify(a.size == b.size + p.replacement.size, "length")
    for (i in 0..p.start) { verify(a[i] == b[i], "prefix bytes") }
    for (i in p.end..b.size) { verify(a[i + p.replacement.size] == b[i], "suffix bytes") }
    verify(text.endsWith("\n") == plan.modifiedText.endsWith("\n"), "EOF newline")
    match (scanDependencies(plan.modifiedText)) {
        case Some(s) =>
            var found = false
            for (e in s.entries) { if (e.key == args[0]) { found = true } }
            verify(found, "new dependency missing")
        case None => throw Exception("section missing")
    }
    return plan
}
func pathPlan(text: String): AddPlan { return planned(text, ["foo", "--path", "../foo"]) }

main(): Int64 {
    test("01 empty dependencies", { => pathPlan("[dependencies]\n") })
    test("02 one existing", { => pathPlan("[dependencies]\nx={path='x'}\n") })
    test("03 multiple", { => pathPlan("[dependencies]\nx={path='x'}\ny={git='y'}\n") })
    test("04 absent section", { => pathPlan("[package]\nname='demo'\n") })
    test("05 empty file exact", { => verify(pathPlan("").modifiedText == "[dependencies]\nfoo = { path = \"../foo\" }", "empty output") })
    test("06 LF", { => verify(pathPlan("[dependencies]\n").patch.replacement.endsWith("\n"), "LF") })
    test("07 CRLF", { => verify(pathPlan("[dependencies]\r\n").patch.replacement.endsWith("\r\n"), "CRLF") })
    test("08 BOM", { => pathPlan("\u{FEFF}[dependencies]\r\n") })
    test("09 no final newline", { => pathPlan("[dependencies]\nx={path='x'}") })
    test("10 final newline", { => pathPlan("[dependencies]\nx={path='x'}\n") })
    test("11 Chinese comments", { => pathPlan("# 中文说明\n[dependencies]\n# 尾注释\n") })
    test("12 Chinese path", { => planned("", ["foo", "--path", "../中文库"]) })
    test("13 Windows path", { => planned("", ["foo", "--path", "C:\\source\\foo"]) })
    test("14 spaces", { => planned("", ["foo", "--path", "../my foo"]) })
    test("15 quote and slash", { => planned("", ["foo", "--path", "a\\b\"c"]) })
    test("16 git", { => planned("", ["foo", "--git", "https://example.com/a?x=1,2#x=y"]) })
    test("17 branch", { => planned("", ["foo", "--git", "url", "--branch", "main"]) })
    test("18 tag", { => planned("", ["foo", "--git", "url", "--tag", "v1"]) })
    test("19 commitId", { => planned("", ["foo", "--git", "url", "--commit-id", "abc123"]) })
    test("20 illegal selector/path", { => rejects({ => parseAddRequest(["foo", "--path", "x", "--branch", "main"]) }) })
    test("21 path and git", { => rejects({ => parseAddRequest(["foo", "--path", "x", "--git", "url"]) }) })
    test("22 duplicate decoded name", { => rejects({ => pathPlan("[dependencies]\n\"foo\"={path='x'}") }) })
    test("23 malformed", { => rejects({ => pathPlan("[dependencies]\nx={path=\"x}") }) })
    test("24 unsupported", { => rejects({ => pathPlan("[dependencies.x]\npath='x'") }) })
    test("25 next section exact", { =>
        let p = pathPlan("[dependencies]\n[package]\nname='x'")
        verify(p.modifiedText == "[dependencies]\nfoo = { path = \"../foo\" }\n[package]\nname='x'", "next section")
    })
    test("26 comments unchanged", { => pathPlan("# before\n\n[dependencies] # header\n# x\nx={path='x'} # inline\n\n# next\n[package]\nname='x'\n") })
    test("27 fake header", { => pathPlan("[package]\ndescription='''\n[dependencies]\n'''\n") })
    test("28 rescan count", { =>
        match (scanDependencies(pathPlan("[dependencies]\nx={path='x'}").modifiedText)) {
            case Some(s) => verify(s.entries.size == 2, "count")
            case None => throw Exception("missing")
        }
    })
    test("29 all bytes preserved mixed Unicode", { => pathPlan("\u{FEFF}# 中\r\n[dependencies]\r\nx={path='中文'} # 中\r\n# 尾\r\n[package]\nname='x'") })
    test("30 all controls escaped", { =>
        var value = ""
        for (n in 0..32) { value += Rune(UInt32(n)).toString() }
        value += Rune(127).toString()
        planned("", ["foo", "--path", value])
    })
    test("31 multiple selectors accepted", { => planned("", ["foo", "--git", "url", "--tag", "v1", "--branch", "main", "--commit-id", "abc"]) })
    test("32 duplicate selector", { => rejects({ => parseAddRequest(["foo", "--git", "url", "--tag", "a", "--tag", "b"]) }) })
    test("33 missing arguments", { =>
        for (args in [Array<String>(), ["foo"], ["foo", "--path"], ["foo", "--branch", "main"]]) {
            rejects({ => parseAddRequest(args) })
        }
    })
    test("34 unknown and forbidden options", { =>
        for (flag in ["--apply", "--force", "--yes", "--what"]) { rejects({ => parseAddRequest(["foo", flag, "x"]) }) }
    })
    test("35 invalid names", { =>
        for (name in ["_", "__", "_1", "1foo", "foo-bar", "org::foo", "中文", "foo@1", "a.b", ""]) {
            rejects({ => parseAddRequest([name, "--path", "x"]) })
        }
    })
    test("36 valid names", { => for (name in ["a", "Foo", "a_1", "_foo", "__a", "if"]) { planned("", [name, "--path", "x"]) } })
    test("37 invalid patch bounds", { => rejects({ => applyPatch("abc", TextPatch(2, 1, "x")) }) })
    test("38 UTF8 boundary", { => rejects({ => applyPatch("中文", TextPatch(1, 1, "x")) }) })
    test("39 BOM only", { => verify(pathPlan("\u{FEFF}").modifiedText.startsWith("\u{FEFF}[dependencies]"), "BOM-only") })
    test("40 header at EOF", { => pathPlan("[dependencies]") })
    test("41 duplicate sections", { => rejects({ => pathPlan("[dependencies]\n[dependencies]\n") }) })
    test("42 mixed newline majority", { => verify(pathPlan("[dependencies]\r\n# a\n# b\n").patch.replacement.endsWith("\n") && !pathPlan("[dependencies]\r\n# a\n# b\n").patch.replacement.endsWith("\r\n"), "majority") })
    test("43 comment EOF", { => pathPlan("# comment") })
    test("44 unterminated table", { => rejects({ => pathPlan("[dependencies]\nx={path='x'") }) })
    println("${passed} passed; ${failed} failed")
    return if (failed == 0) { 0 } else { 1 }
}
