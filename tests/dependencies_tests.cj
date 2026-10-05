package cjx

var passed: Int64 = 0
var failed: Int64 = 0

func verify(condition: Bool, reason: String): Unit {
    if (!condition) { throw Exception(reason) }
}

func test(name: String, action: () -> Unit): Unit {
    try {
        action()
        passed++
        println("PASS ${name}")
    } catch (error: Exception) {
        failed++
        println("FAIL ${name}: ${error.message}")
    }
}

func expectScan(text: String, keys: Array<String>, values: Array<String>, present!: Bool = true): Unit {
    let bytes = text.toArray()
    match (scanDependencies(text)) {
        case None => verify(!present, "unexpected missing section")
        case Some(section) =>
            verify(present, "unexpected section")
            verify(section.start >= 0 && section.start <= section.contentStart &&
                section.contentStart <= section.end && section.end <= bytes.size, "section range")
            verify(section.entries.size == keys.size, "entry count")
            var previous = section.contentStart
            for (i in 0..keys.size) {
                let entry = section.entries[i]
                verify(entry.key == keys[i], "decoded key")
                verify(entry.rawValue == values[i], "raw value")
                verify(entry.lineStart >= previous && entry.lineStart <= entry.start &&
                    entry.start < entry.valueStart && entry.valueStart < entry.end &&
                    entry.end <= entry.statementEnd && entry.statementEnd <= section.end, "entry range")
                verify(String.fromUtf8(bytes[entry.valueStart..entry.end]) == values[i], "byte slice")
                // Every exposed boundary must be on a UTF-8 code-point boundary.
                for (offset in [section.start, section.contentStart, section.end, entry.lineStart,
                    entry.start, entry.valueStart, entry.end, entry.statementEnd]) {
                    verify(String.fromUtf8(bytes[..offset]) + String.fromUtf8(bytes[offset..]) == text,
                        "UTF-8 boundary reconstruction")
                }
                if (entry.commentStart >= 0) {
                    verify(entry.commentStart >= entry.end && entry.commentStart < entry.statementEnd &&
                        bytes[entry.commentStart] == 35, "comment range")
                }
                previous = entry.statementEnd
            }
    }
}

func expectError(text: String, reason: String): Unit {
    var rejected = false
    try {
        scanDependencies(text)
    } catch (error: Exception) {
        rejected = error.message.startsWith("unsupported or malformed cjpm.toml") && error.message.contains(reason)
    }
    verify(rejected, "expected scanner error containing: ${reason}")
}

main(): Int64 {
    test("01 empty dependencies", { => expectScan("[dependencies]\n", [], []) })
    test("02 version", { => expectScan("[dependencies]\nfoo = \"1.0.0\"\n", ["foo"], ["\"1.0.0\""]) })
    test("03 path", { => expectScan("[dependencies]\nfoo = { path = \"../foo\" }\n", ["foo"], ["{ path = \"../foo\" }"]) })
    test("04 git", { => expectScan("[dependencies]\nfoo = { git = \"https://example.com/foo.git\" }\n", ["foo"], ["{ git = \"https://example.com/foo.git\" }"]) })
    test("05 quoted key", { => expectScan("[dependencies]\n\"org::package\" = '1.0.0'\n", ["org::package"], ["'1.0.0'"]) })
    test("06 version range", { => expectScan("[dependencies]\nfoo = { version = \"[1.0.0, 2.0.0)\" }\n", ["foo"], ["{ version = \"[1.0.0, 2.0.0)\" }"]) })
    test("07 multiple", { => expectScan("[dependencies]\na='1'\nb={path='../b'}\nc={git='url'}\n", ["a", "b", "c"], ["'1'", "{path='../b'}", "{git='url'}"]) })
    test("08 multiline inline table", { => expectScan("[dependencies]\nfoo = {\n git = 'url',\n branch = 'main'\n}\n", ["foo"], ["{\n git = 'url',\n branch = 'main'\n}"]) })
    test("09 trailing comment", { => expectScan("[dependencies]\nfoo = '1' # = [ ]\n", ["foo"], ["'1'"]) })
    test("10 leading comment", { => expectScan("[dependencies]\n# UI framework\nfoo = '1'\n", ["foo"], ["'1'"]) })
    test("11 fake header in comment", { => expectScan("# [dependencies]\n[package]\nname='demo'\n", [], [], present: false) })
    test("12 fake header in basic string", { => expectScan("[package]\nname=\"[dependencies]\"\n", [], [], present: false) })
    test("13 fake header in multiline strings", { =>
        expectScan("[package]\nx=\"\"\"\n[dependencies]\nfoo='fake'\n\"\"\"\ny='''\n[dependencies]\n'''\n", [], [], present: false)
    })
    test("14 string hash and equals", { => expectScan("[dependencies]\nfoo={git=\"url#[]=x\"}\n", ["foo"], ["{git=\"url#[]=x\"}"]) })
    test("15 Chinese", { => expectScan("# 中文依赖说明\n[dependencies]\n# 界面\nfoo={path='../中文'}\n", ["foo"], ["{path='../中文'}"]) })
    test("16 CRLF", { => expectScan("[dependencies]\r\nfoo={\r\n path='../foo'\r\n}\r\n", ["foo"], ["{\r\n path='../foo'\r\n}"]) })
    test("17 LF", { => expectScan("[dependencies]\nfoo='1'\n", ["foo"], ["'1'"]) })
    test("18 missing section and empty file", { =>
        expectScan("[package]\nname='demo'\n", [], [], present: false)
        expectScan("", [], [], present: false)
    })
    test("19 following section", { => expectScan("[dependencies]\nfoo='1'\n[package.package-configuration]\na='b'\n", ["foo"], ["'1'"]) })
    test("20 unclosed string", { => expectError("[dependencies]\nfoo=\"oops\n", "unclosed") })
    test("21 unclosed inline table", { => expectError("[dependencies]\nfoo={path='x'\n[next]\nx='y'\n", "unclosed") })
    test("22 repeated section", { => expectError("[dependencies]\n[dependencies]\n", "duplicate") })
    test("23 version field", { => expectScan("[dependencies]\nfoo={version='1.0.0'}", ["foo"], ["{version='1.0.0'}"]) })
    test("24 literal key and literal shielding", { => expectScan("[dependencies]\n'org::foo'={path='C:\\[x]#=y'}\n", ["org::foo"], ["{path='C:\\[x]#=y'}"]) })
    test("25 escaped quote and backslash", { => expectScan("[dependencies]\nfoo=\"a\\\"[#=]\\\\b\"\n", ["foo"], ["\"a\\\"[#=]\\\\b\""]) })
    test("26 nested containers", { => expectScan("[package]\nx=[{a=['[#=]', {b='c'}]}, 1]\n[dependencies]\nfoo={path='x', features=['a', 'b']}\n", ["foo"], ["{path='x', features=['a', 'b']}"]) })
    test("27 unclosed multiline basic", { => expectError("[package]\nx=\"\"\"\n[dependencies]\n", "unclosed") })
    test("28 unclosed multiline literal", { => expectError("[package]\nx='''\n[dependencies]\n", "unclosed") })
    test("29 subtable", { => expectError("[dependencies.foo]\npath='x'\n", "unsupported dependencies expression") })
    test("30 array table", { => expectError("[[dependencies.foo]]\npath='x'\n", "unsupported dependencies expression") })
    test("31 dotted dependency", { => expectError("[dependencies]\nfoo.path='x'\n", "dotted key") })
    test("32 root dependency expression", { => expectError("dependencies.foo.path='x'\n", "root assignment") })
    test("33 decoded duplicate key", { => expectError("[dependencies]\nfoo='1'\n\"f\\u006Fo\"='2'\n", "duplicate dependency") })
    test("34 decoded duplicate header", { => expectError("[dependencies]\n[\"dependenc\\u0069es\"]\n", "duplicate dependencies") })
    test("35 quoted header", { => expectScan("[ 'dependencies' ] # header\nfoo='1'", ["foo"], ["'1'"]) })
    test("36 mismatched nesting", { => expectError("[dependencies]\nfoo={path=['x'}]\n", "mismatched") })
    test("37 trailing garbage", { => expectError("[dependencies]\nfoo='1' bar='2'\n", "unexpected text") })
    test("38 missing value", { => expectError("[dependencies]\nfoo= # no value\n", "missing value") })
    test("39 bad escape", { => expectError("[package]\nx=\"\\q\"\n[dependencies]\n", "invalid string escape") })
    test("40 bad Unicode escape", { => expectError("[dependencies]\n\"\\uD800\"='1'\n", "invalid Unicode scalar") })
    test("41 malformed later section", { => expectError("[dependencies]\nfoo='1'\n[next\n", "unclosed section") })
    test("42 bare CR", { => expectError("[dependencies]\rfoo='1'", "bare CR") })
    test("43 no final newline", { => expectScan("[dependencies]\nfoo='1' # tail", ["foo"], ["'1'"]) })
    test("44 target dependency ignored", { => expectScan("[target.windows.dependencies]\nfoo={path='x'}\n", [], [], present: false) })
    test("45 multiline continuation", { => expectScan("[package]\nx=\"\"\"abc\\  \r\n [dependencies]\n\"\"\"\n[dependencies]\nfoo='1'\n", ["foo"], ["'1'"]) })
    test("46 four and five closing quotes", { => expectScan("[package]\nx=\"\"\"a\"\"\"\"\"\ny='''b''''\n[dependencies]\n", [], []) })
    test("47 empty quoted key", { => expectScan("[dependencies]\n''='1'\n", [""], ["'1'"]) })
    test("48 BOM and exact byte offsets", { =>
        let bom = String.fromUtf8([239, 187, 191])
        let text = bom + "# 中\r\n[dependencies]\r\n  foo = '值' # note\r\n[next]\r\nx=1\r\n"
        expectScan(text, ["foo"], ["'值'"])
        match (scanDependencies(text)) {
            case Some(s) =>
                let e = s.entries[0]
                verify(s.start == 10 && s.contentStart == 26 && s.end == 48, "exact section offsets")
                verify(e.lineStart == 26 && e.start == 28 && e.valueStart == 34 && e.end == 39 &&
                    e.commentStart == 40 && e.statementEnd == 48, "exact entry offsets")
            case None => throw Exception("missing section")
        }
    })
    test("49 comment in multiline container", { => expectScan("[dependencies]\nfoo={\n# [dependencies] = }\npath='x'\n}\n", ["foo"], ["{\n# [dependencies] = }\npath='x'\n}"]) })
    test("50 unterminated outside array", { => expectError("[package]\nx=[1,\n[dependencies]\n", "unclosed") })
    test("51 root inline dependencies", { => expectError("dependencies={foo={path='x'}}\n", "root assignment") })
    test("52 oversized Unicode scalar", { => expectError("[dependencies]\n\"\\UFFFFFFFF\"='1'\n", "invalid Unicode scalar") })
    test("53 leading and trailing comments stay separate", { =>
        let text = "[dependencies]\n# UI framework\n  cui={path='x'} # local\n\n# network\nfoo='1'\n"
        expectScan(text, ["cui", "foo"], ["{path='x'}", "'1'"])
        match (scanDependencies(text)) {
            case Some(s) =>
                let data = text.toArray()
                let first = s.entries[0]
                verify(String.fromUtf8(data[s.contentStart..first.lineStart]) == "# UI framework\n", "leading comment")
                verify(String.fromUtf8(data[first.end..first.statementEnd]) == " # local\n", "trailing comment")
                verify(String.fromUtf8(data[first.statementEnd..s.entries[1].lineStart]) == "\n# network\n", "inter-entry gap")
            case None => throw Exception("missing section")
        }
    })
    println("${passed} passed; ${failed} failed")
    return if (failed == 0) { 0 } else { 1 }
}
