package cjx

import std.fs.*

var passed: Int64 = 0
var failed: Int64 = 0
func verify(ok: Bool, reason: String): Unit { if (!ok) { throw Exception(reason) } }
func test(name: String, body: () -> Unit): Unit {
    try { body(); passed++; println("PASS ${name}") }
    catch (e: Exception) { failed++; println("FAIL ${name}: ${e.message}") }
}
let valid = "[dependencies]\nfoo={path='../中文库'}\nbar={git='url',branch='main'}\n"
func report(text!: String = valid, hasLock!: Bool = true): DoctorReport {
    return diagnoseProject(version: {_ => "1.0.5"}, findProject: { => Some(canonicalize(Path(".")).join("sample.toml")) },
        readConfig: {_ => text}, inspectPath: {_, _ => ("OK", "path exists")}, readLock: {_ => MetadataFileState(hasLock, if (hasLock) { "version=0".toArray() } else { Array<Byte>() }) })
}
func check(r: DoctorReport, label: String): DoctorCheck {
    for (row in r.checks) { if (row.label == label) { return row } }
    throw Exception("missing row: " + label)
}
main(): Int64 {
    test("01 normal path Git report ready", { =>
        let r = report()
        verify(r.exitCode == 0 && r.errors == 0 && r.warnings == 0, "counts")
        verify(check(r,"cjpm update").status == "READY" && check(r,"Dependencies").detail == "2 dependencies", "ready")
        verify(formatDoctor(r).contains("All checks passed."), "result")
    })
    test("02 missing lock warning does not block update", { =>
        let r = report(hasLock: false)
        verify(r.warnings == 1 && r.exitCode == 0 && check(r,"cjpm.lock").status == "WARN" && check(r,"cjpm update").status == "READY", "warning")
    })
    test("03 no section distinct from empty", { =>
        verify(check(report(text: "[package]\nname='demo'\n"),"Dependencies").detail.contains("no dependencies section"), "absent")
        verify(check(report(text: "[dependencies]\n"),"Dependencies").detail == "0 dependencies", "empty")
    })
    test("04 empty file is a successful structural read", { => verify(report(text: "").errors == 0, "empty text") })
    test("05 malformed one root cause not cascaded errors", { =>
        let r = report(text: "[dependencies]\nfoo='broken")
        verify(r.errors == 1 && r.exitCode == 1 && check(r,"TOML scan").status == "ERROR", "error")
        verify(check(r,"Unsupported").status == "SKIP" && check(r,"cjpm update").status == "READY", "skipped")
    })
    test("06 unsupported dependency subtable rejected", { => verify(report(text: "[dependencies.foo]\npath='x'").errors == 1, "unsupported") })
    test("07 duplicate dependencies rejected", { => verify(report(text: "[dependencies]\nfoo='1'\nfoo='2'").errors == 1, "duplicate") })
    test("08 central declaration on CJPM 1.0.5", { =>
        let r = report(text: "[dependencies]\nfoo='1.2.3'\nbar={version='1'}\n")
        verify(check(r,"Unsupported").status == "WARN" && check(r,"Unsupported").detail.startsWith("2"), "central unsupported")
        verify(check(r,"TOML scan").status == "OK" && r.errors == 0 && r.warnings == 1 && r.exitCode == 0, "structural versus SDK compatibility")
    })
    test("09 unknown value warning", { =>
        let r = report(text: "[dependencies]\nfoo={custom='x'}\n")
        verify(r.warnings == 1 && r.errors == 0 && check(r,"Unknown values").detail.startsWith("1"), "unknown")
        verify(check(r,"cjpm update").status == "READY", "tool availability only")
    })
    test("10 missing SDK and CJPM report independently", { =>
        let r = diagnoseProject(version: {_ => throw Exception("executable not found; load SDK environment")}, findProject: { => None })
        verify(r.errors == 3 && check(r,"Cangjie SDK").status == "ERROR" && check(r,"CJPM").status == "ERROR", "independent checks")
        verify(check(r,"TOML scan").status == "SKIP", "no phantom config error")
    })
    test("11 missing project still checks both tools", { =>
        let r = diagnoseProject(version: {_ => "1.0.5"}, findProject: { => None })
        verify(r.errors == 1 && check(r,"CJPM").status == "OK" && check(r,"cjpm.lock").status == "SKIP", "environment first")
    })
    test("12 nonregular manifest location error", { =>
        let r = diagnoseProject(version: {_ => "1.0.5"}, findProject: { => throw Exception("Expected a regular file") })
        verify(r.errors == 1 && check(r,"cjpm.toml").detail.contains("regular"), "reason preserved")
    })
    test("13 permission/read failure retained without stack", { =>
        let r = diagnoseProject(version: {_ => "1.0.5"}, findProject: { => Some(canonicalize(Path(".")).join("sample.toml")) },
            readConfig: {_ => throw Exception("access denied")}, readLock: {_ => MetadataFileState(true, [1])})
        verify(r.errors == 1 && check(r,"cjpm.toml").detail.contains("access denied") && check(r,"Dependencies").status == "SKIP", "read failure")
    })
    test("14 lock read/type failure is ERROR independent of tool readiness", { =>
        let r = diagnoseProject(version: {_ => "1.0.5"}, findProject: { => Some(canonicalize(Path(".")).join("sample.toml")) },
            readConfig: {_ => valid}, inspectPath: {_, _ => ("OK", "path exists")}, readLock: {_ => throw Exception("Expected regular metadata file")})
        verify(r.errors == 1 && check(r,"cjpm update").status == "READY", "bad lock")
    })
    test("15 empty lock warning", { =>
        let r = diagnoseProject(version: {_ => "1.0.5"}, findProject: { => Some(canonicalize(Path(".")).join("sample.toml")) },
            readConfig: {_ => valid}, inspectPath: {_, _ => ("OK", "path exists")}, readLock: {_ => MetadataFileState(true, Array<Byte>())})
        verify(r.warnings == 1 && check(r,"cjpm.lock").detail.contains("empty"), "empty lock")
    })
    test("16 unverified tool version avoids compatibility claims", { =>
        let r = diagnoseProject(version: {_ => "1.2.0"}, findProject: { => Some(canonicalize(Path(".")).join("sample.toml")) },
            readConfig: {_ => "[dependencies]\nfoo='1'"}, readLock: {_ => MetadataFileState(true,[1])})
        verify(r.errors == 0 && r.warnings == 2 && check(r,"Unsupported").status == "SKIP", "unknown compatibility")
    })
    test("17 startup failure still reports configuration", { =>
        let r = diagnoseProject(version: {tool => if (tool == "cjc") { return "1.0.5" }; throw Exception("unable to start cjpm") },
            findProject: { => Some(canonicalize(Path(".")).join("sample.toml")) }, readConfig: {_ => valid}, inspectPath: {_, _ => ("OK", "path exists")}, readLock: {_ => MetadataFileState(true,[1])})
        verify(r.errors == 1 && check(r,"Dependencies").status == "OK" && check(r,"cjpm update").status == "BLOCKED", "continued checks")
    })
    test("18 LF CRLF BOM Chinese structural diagnosis", { =>
        let r = report(text: "\u{FEFF}# 中文\r\n[dependencies]\r\nfoo={path='../中文'}\r\n")
        verify(r.errors == 0 && check(r,"Dependencies").detail == "1 dependency", "UTF8")
    })
    test("19 terminal control escaping and problem summary", { =>
        let r = diagnoseProject(version: {_ => throw Exception("missing\n\u{1b}tool")}, findProject: { => None })
        let output = formatDoctor(r)
        verify(output.contains("missing\\n?tool") && output.contains("3 problems found"), "display")
    })
    test("20 doctor extra argument rejected before diagnosis", { =>
        verify(runCli(["doctor","--fix"]) == 2 && runCli(["doctor","extra"]) == 2, "no fix flags")
    })
    test("21 relative and absolute existing Chinese Path", { =>
        let parent = canonicalize(Path("."))
        let root = Directory.createTemp(parent)
        try {
            let app = root.join("app")
            let dependency = root.join("中文库")
            Directory.create(app); Directory.create(dependency)
            File.writeTo(dependency.join("cjpm.toml"), "[package]\nname='foo'\n".toArray())
            let (status, detail) = inspectDoctorPath(app, "../中文库")
            verify(status == "OK" && detail.contains("../中文库"), "relative project root")
            let (absolute, _) = inspectDoctorPath(app, dependency.toString())
            verify(absolute == "OK", "absolute Path")
        } finally { verify(root.parent == parent, "unsafe cleanup"); remove(root, recursive: true) }
    })
    test("22 missing Path is an ERROR and exit 1", { =>
        let r = diagnoseProject(version: {_ => "1.0.5"}, findProject: { => Some(canonicalize(Path(".")).join("sample.toml")) },
            readConfig: {_ => "[dependencies]\nmissing={path='./cjx-no-such-dependency-22'}\n"}, readLock: {_ => MetadataFileState(true,[1])})
        verify(r.errors == 1 && r.exitCode == 1 && check(r,"missing").detail.contains("path does not exist"), "missing Path")
    })
    test("23 file Path is WARN", { =>
        let parent = canonicalize(Path("."))
        let root = Directory.createTemp(parent)
        try {
            File.writeTo(root.join("note"), "text".toArray())
            let (status, detail) = inspectDoctorPath(root, "note")
            verify(status == "WARN" && detail.contains("not a directory"), "file Path")
        } finally { verify(root.parent == parent, "unsafe cleanup"); remove(root, recursive: true) }
    })
    test("24 directory without project manifest is WARN", { =>
        let parent = canonicalize(Path("."))
        let root = Directory.createTemp(parent)
        try {
            let (status, detail) = inspectDoctorPath(root, ".")
            verify(status == "WARN" && detail.contains("no regular cjpm.toml"), "unverified directory")
        } finally { verify(root.parent == parent, "unsafe cleanup"); remove(root, recursive: true) }
    })
    test("25 Git never invokes filesystem dependency inspection", { =>
        let r = diagnoseProject(version: {_ => "1.0.5"}, findProject: { => Some(canonicalize(Path(".")).join("sample.toml")) },
            readConfig: {_ => "[dependencies]\nfoo={git='https://invalid.example/foo'}\n"}, readLock: {_ => MetadataFileState(true,[1])},
            inspectPath: {_, _ => throw Exception("must not inspect Git")})
        verify(check(r,"foo").status == "OK" && check(r,"foo").detail.contains("not contacted") && r.errors == 0, "Git offline")
    })
    test("26 Unknown summary names and safe long labels", { =>
        let r = report(text: "[dependencies]\n\"very_long_dependency_name\\tfoo\"={custom='x'}\n")
        verify(check(r,"Dependencies").status == "WARN" && r.warnings == 1 && r.exitCode == 0, "Unknown summary")
        let output = formatDoctor(r)
        verify(output.contains("very_long_dependency_name\\tfoo") && output.contains("Unknown:"), "label safe")
    })
    test("27 cjc missing leaves CJPM result available", { =>
        let r = diagnoseProject(version: {tool => if (tool == "cjc") { throw Exception("cjc was not found") }; return "1.0.5" }, findProject: { => None })
        verify(check(r,"Cangjie SDK").status == "ERROR" && check(r,"CJPM").status == "OK" && r.errors == 2, "cjc missing")
    })
    test("28 cjc startup reason preserved", { =>
        let r = diagnoseProject(version: {tool => if (tool == "cjc") { throw Exception("cjc startup failed: missing runtime") }; return "1.0.5" }, findProject: { => None })
        verify(check(r,"Cangjie SDK").detail.contains("missing runtime") && check(r,"CJPM").status == "OK", "startup reason")
    })
    test("29 cjpm missing leaves SDK result available", { =>
        let r = diagnoseProject(version: {tool => if (tool == "cjpm") { throw Exception("cjpm was not found") }; return "1.0.5" }, findProject: { => None })
        verify(check(r,"CJPM").status == "ERROR" && check(r,"Cangjie SDK").status == "OK" && check(r,"cjpm update").status == "BLOCKED", "cjpm missing")
    })
    test("30 actual cjc and CJPM version capture", { =>
        verify(readDoctorVersion("cjc") == "1.0.5" && readDoctorVersion("cjpm") == "1.0.5", "actual version capture")
    })
    test("31 invalid UTF8 diagnosed as read ERROR", { =>
        let parent = canonicalize(Path("."))
        let root = Directory.createTemp(parent)
        try {
            let path = root.join("cjpm.toml")
            File.writeTo(path, [255])
            let r = diagnoseProject(version: {_ => "1.0.5"}, findProject: { => Some(path) }, readLock: {_ => MetadataFileState(true,[1])})
            verify(r.errors == 1 && r.exitCode == 1 && check(r,"cjpm.toml").detail.contains("UTF-8"), "UTF8 error")
            verify(sameBytes(File.readFrom(path), [255]), "invalid file modified")
        } finally { verify(root.parent == parent, "unsafe cleanup"); remove(root, recursive: true) }
    })
    test("32 UNC Path is not probed", { =>
        let (status, detail) = inspectDoctorPath(canonicalize(Path(".")), "\\\\invalid.example\\share")
        verify(status == "WARN" && detail.contains("not checked"), "UNC offline")
    })
    println("${passed} doctor tests passed; ${failed} failed")
    return if (failed == 0) { 0 } else { 1 }
}
