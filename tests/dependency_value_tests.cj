package cjx

var passed: Int64 = 0
var failed: Int64 = 0

func verify(condition: Bool, message: String): Unit {
    if (!condition) { throw Exception(message) }
}

func test(name: String, action: () -> Unit): Unit {
    try { action(); passed++; println("PASS ${name}") }
    catch (error: Exception) { failed++; println("FAIL ${name}: ${error.message}") }
}

func expectValue(raw: String, source: String, spec: String): Unit {
    let entry = DependencyEntry("foo", raw, 0, 0, raw.size, 0, raw.size, -1)
    let info = classifyDependency(entry)
    verify(info.name == "foo", "name changed")
    verify(sourceLabel(info.source) == source, "wrong source")
    verify(info.spec == spec, "wrong spec")
    verify(entry.rawValue == raw, "raw value changed")
}

func table(text: String): String { return formatDependencyList(scanDependencies(text)) }

main(): Int64 {
    test("01 path", { => expectValue("{ path = \"../foo\" }", "path", "../foo") })
    test("02 git", { => expectValue("{ git = 'https://example.com/foo.git' }", "git", "https://example.com/foo.git") })
    test("03 git branch", { => expectValue("{ git='url', branch='main' }", "git", "url [branch=main]") })
    test("04 git tag", { => expectValue("{ tag='v1', git='url' }", "git", "url [tag=v1]") })
    test("05 special URL", { => expectValue("{git='https://host/foo?x=a,b#c=d[]=z'}", "git", "https://host/foo?x=a,b#c=d[]=z") })
    test("06 version string", { => expectValue("\"1.2.3\"", "central", "1.2.3") })
    test("07 version range", { => expectValue("{version='[1.0.0, 2.0.0)'}", "central", "[1.0.0, 2.0.0)") })
    test("08 quoted org key", { =>
        let result = table("[dependencies]\n\"org::package\"='1.2.3'\n")
        verify(result.contains("org::package  central    1.2.3") && result.endsWith("1 dependency\n"), "quoted key output")
    })
    test("09 unknown", { => expectValue("{features=['a,b'], path='x'}", "unknown", "{features=['a,b'], path='x'}") })
    test("10 empty", { => verify(table("[dependencies]\n") == "Dependencies\n-------------\n(0 dependencies)\n", "empty output") })
    test("11 multiple sources", { =>
        let result = table("[dependencies]\np={path='x'}\ng={git='url'}\nv='1'\nu={custom='x'}\n")
        verify(result.contains("p     path       x") && result.contains("g     git        url") &&
            result.contains("v     central    1") && result.contains("u     unknown    {custom='x'}") &&
            result.endsWith("4 dependencies\n"), "mixed output")
    })
    test("12 Chinese path", { => expectValue("{path='../中文目录'}", "path", "../中文目录") })
    test("13 CRLF", { => verify(table("[dependencies]\r\nfoo={\r\n path='x'\r\n}\r\n").contains("foo   path       x"), "CRLF output") })
    test("14 LF", { => verify(table("[dependencies]\nfoo={\n path='x'\n}\n").contains("foo   path       x"), "LF output") })
    test("15 commitId", { => expectValue("{git='url',commitId='abcdef'}", "git", "url [commitId=abcdef]") })
    test("16 all selectors retained", { => expectValue("{tag='v',branch='b',commitId='c',git='url'}", "git", "url [commitId=c] [branch=b] [tag=v]") })
    test("17 commit is not commitId", { => expectValue("{git='url',commit='abc'}", "unknown", "{git='url',commit='abc'}") })
    test("18 conflicting sources", { => expectValue("{git='url',path='x'}", "unknown", "{git='url',path='x'}") })
    test("19 duplicate field", { => expectValue("{path='x',path='y'}", "unknown", "{path='x',path='y'}") })
    test("20 quoted duplicate field", { => expectValue("{path='x',\"p\\u0061th\"='y'}", "unknown", "{path='x',\"p\\u0061th\"='y'}") })
    test("21 quoted field", { => expectValue("{\"p\\u0061th\"='x'}", "path", "x") })
    test("22 Unicode escape", { => expectValue("{path=\"../\\u4E2D\\u6587\"}", "path", "../中文") })
    test("23 literal backslash", { => expectValue("{path='C:\\foo'}", "path", "C:\\foo") })
    test("24 basic escapes", { => expectValue("{path=\"a\\\"b\\\\c\"}", "path", "a\"b\\c") })
    test("25 nested unknown", { => expectValue("{path={value='x'}}", "unknown", "{path={value='x'}}") })
    test("26 non-string field", { => expectValue("{path=42}", "unknown", "{path=42}") })
    test("27 trailing comma", { => expectValue("{path='x',}", "unknown", "{path='x',}") })
    test("28 malformed balanced table", { => expectValue("{path 'x'}", "unknown", "{path 'x'}") })
    test("29 comments within table", { => expectValue("{\n# fake,=field\n git='u,#=', # after\n branch='main'\n}", "git", "u,#= [branch=main]") })
    test("30 missing section", { => verify(table("[package]\nname='demo'\n") == "Dependencies\n-------------\n(0 dependencies)\n", "missing output") })
    test("31 empty selector", { => expectValue("{git='url',branch=''}", "unknown", "{git='url',branch=''}") })
    test("32 empty source", { => expectValue("{path=''}", "unknown", "{path=''}") })
    test("33 multiline string unknown", { => expectValue("\"\"\"1.2.3\"\"\"", "unknown", "\"\"\"1.2.3\"\"\"") })
    test("34 one dependency snapshot", { =>
        verify(table("[dependencies]\ncui={path='../CangjieCUI'}\n") ==
            "Dependencies\n------------------------------------------------------------\nNAME  SOURCE     SPEC\ncui   path       ../CangjieCUI\n\n1 dependency\n", "snapshot")
    })
    test("35 terminal controls", { =>
        let result = table("[dependencies]\n\"a\\nb\"={path=\"x\\r\\ny\\t\\u001B\"}\n")
        verify(result.contains("a\\nb") && result.contains("x\\r\\ny\\t?") && !result.contains("\r"), "unsafe terminal text")
    })
    test("36 shortened UTF-8 unknown", { =>
        let raw = "{custom='" + "中文" * 30 + "'}"
        let result = table("[dependencies]\nfoo=" + raw + "\n")
        verify(result.contains("unknown") && result.contains("...") && !result.contains(raw), "unknown shortening")
    })
    test("37 version inline table", { => expectValue("{version='1.2.3'}", "central", "1.2.3") })
    test("38 malformed scanner still rejects", { =>
        var rejected = false
        try { table("[dependencies]\nfoo={path='unclosed\n") }
        catch (_: Exception) { rejected = true }
        verify(rejected, "scanner error swallowed")
    })
    println("${passed} value/list tests passed; ${failed} failed")
    return if (failed == 0) { 0 } else { 1 }
}
