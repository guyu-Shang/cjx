package cjx

var passed: Int64 = 0
var failed: Int64 = 0
func verify(ok: Bool, reason: String): Unit { if (!ok) { throw Exception(reason) } }
func test(name: String, body: () -> Unit): Unit {
    try { body(); passed++; println("PASS ${name}") }
    catch (e: Exception) { failed++; println("FAIL ${name}: ${e.message}") }
}
func rejects(text: String, name: String, reason: String): Unit {
    var rejected = false
    try { planRemoveDependency(text, name) }
    catch (e: Exception) { rejected = e.message.contains(reason) }
    verify(rejected, "expected rejection: " + reason)
}
func removed(text: String, name: String, expected: String): RemovePlan {
    let plan = planRemoveDependency(text, name)
    verify(plan.modifiedText == expected, "exact output mismatch")
    verify(plan.patch.replacement == "", "deletion only")
    let before = text.toArray()
    let after = plan.modifiedText.toArray()
    verify(after.size == before.size - (plan.patch.end - plan.patch.start), "byte length")
    for (i in 0..plan.patch.start) { verify(before[i] == after[i], "prefix byte") }
    for (i in plan.patch.end..before.size) {
        verify(before[i] == after[i - (plan.patch.end - plan.patch.start)], "suffix byte")
    }
    match (scanDependencies(plan.modifiedText)) {
        case Some(s) => for (e in s.entries) { verify(e.key != name, "removed key remains") }
        case None => throw Exception("section lost")
    }
    return plan
}

main(): Int64 {
    let h = "[dependencies]\n"
    let a = "a = { path = '../a' }\n"
    let b = "b = { git = 'https://example.com/b?x=1,2#tag=y', branch = 'main' }\n"
    let c = "c = '1.2.3'\n"
    test("01 sole path keeps section", { => removed(h+a, "a", h) })
    test("02 first of three", { => removed(h+a+b+c, "a", h+b+c) })
    test("03 middle Git preserves neighbours", { => removed(h+a+b+c, "b", h+a+c) })
    test("04 last version", { => removed(h+a+b+c, "c", h+a+b) })
    test("05 missing key", { => rejects(h+a, "missing", "dependency 'missing' was not found.") })
    test("06 quoted basic key decoded", { => removed(h+"\"foo\" = { path = 'x' }\n", "foo", h) })
    test("07 quoted org name existing only", { => removed(h+"'org::foo' = '1.0'\n", "org::foo", h) })
    test("08 escaped quoted key", { => removed(h+"\"f\\u006fo\" = '1'\n", "foo", h) })
    test("09 trailing comment belongs to entry", { =>
        let p = removed(h+"foo = '1' # local foo [=]\n"+a, "foo", h+a)
        verify(p.declaration == "foo = '1' # local foo [=]", "comment preview")
    })
    test("10 leading single comment retained", { => removed(h+"# UI framework\n"+a, "a", h+"# UI framework\n") })
    test("11 leading block retained", { => removed(h+"# line 1\n# line 2\n"+a+b, "a", h+"# line 1\n# line 2\n"+b) })
    test("12 separated comment retained", { => removed(h+"# notes\n\n"+a, "a", h+"# notes\n\n") })
    test("13 general and UI comments retained", { =>
        removed(h+"# general dependency notes\n\n# UI framework\n"+a+b, "a", h+"# general dependency notes\n\n# UI framework\n"+b)
    })
    test("14 Chinese comments and values", { => removed(h+"# 中文说明\nfoo = { path = '../中文库' } # 中文尾注释\n"+a, "foo", h+"# 中文说明\n"+a) })
    test("15 CRLF exact", { => removed("[dependencies]\r\nfoo='1' # x\r\nbar='2'\r\n", "foo", "[dependencies]\r\nbar='2'\r\n") })
    test("16 BOM retained", { => removed("\u{FEFF}"+h+a, "a", "\u{FEFF}"+h) })
    test("17 EOF without newline", { => removed(h+"foo='1'", "foo", h) })
    test("18 EOF with newline", { => removed(h+"foo='1'\n", "foo", h) })
    test("19 following section and header comments unchanged", { => removed(h+a+"# package notes\n[package] # pkg\nname='demo'", "a", h+"# package notes\n[package] # pkg\nname='demo'") })
    test("20 empty dependencies missing", { => rejects(h, "foo", "was not found") })
    test("21 multiple blank lines untouched", { => removed(h+"\n\n"+a+"\n\n"+b, "a", h+"\n\n\n\n"+b) })
    test("22 multiline inline table and internal comment", { => removed(h+"foo = {\n  # fields\n  git = 'url',\n  branch = 'main'\n} # last line\n"+a, "foo", h+a) })
    test("23 multiline string fake headers", { => removed("[package]\ndescription='''\n[dependencies]\nfoo='fake'\n'''\n"+h+a, "a", "[package]\ndescription='''\n[dependencies]\nfoo='fake'\n'''\n"+h) })
    test("24 malformed string refuses even other key", { => rejects(h+a+"foo='broken", "a", "malformed") })
    test("25 malformed table", { => rejects(h+"foo={path='x'", "foo", "malformed") })
    test("26 unsupported subtable", { => rejects(h+a+"[dependencies.foo]\npath='x'", "a", "unsupported") })
    test("27 duplicate decoded dependency", { => rejects(h+"foo='1'\n\"foo\"='2'\n", "foo", "duplicate") })
    test("28 duplicate section", { => rejects(h+a+h, "a", "duplicate") })
    test("29 retained unknown and source semantics", { => removed(h+a+"x={custom='v'}\n"+b+c, "a", h+"x={custom='v'}\n"+b+c) })
    test("30 mixed endings and Unicode outside patch", { => removed("\u{FEFF}# 前\r\n[dependencies]\r\n"+a+"# 后\n"+b+"[package]\r\nname='中文'", "a", "\u{FEFF}# 前\r\n[dependencies]\r\n# 后\n"+b+"[package]\r\nname='中文'") })
    test("31 indentation and trailing spaces", { => removed(h+" \tfoo = '1'  \t # note\r\n"+a, "foo", h+a) })
    test("32 decoded key exact case sensitive", { => rejects(h+"Foo='1'\n", "foo", "was not found") })
    test("33 no section missing", { => rejects("[package]\nname='demo'\n", "foo", "was not found") })
    test("34 malformed outside dependencies", { => rejects(h+a+"[package]\nname='broken", "a", "malformed") })
    test("35 multiline value with equals and hash", { => removed(h+"foo='''\n# [dependencies] = string\n''' # trailing\n"+a, "foo", h+a) })
    test("36 request rejects options and extra names", { =>
        for (args in [Array<String>(), [""], ["foo", "bar"], ["--force"], ["foo", "--dry-run"], ["foo", "--apply"]]) {
            var rejected = false
            try { parseRemoveRequest(args) } catch (_: Exception) { rejected = true }
            verify(rejected, "invalid request accepted")
        }
        verify(parseRemoveRequest(["org::foo"]) == "org::foo", "no add name rules")
    })
    println("Remove planner tests: ${passed} passed, ${failed} failed")
    return if (failed == 0) { 0 } else { 1 }
}
