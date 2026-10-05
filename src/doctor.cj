package cjx

import std.collection.ArrayList
import std.fs.{Path, FileInfo, exists}
import std.process.{executeWithOutput, ProcessRedirect}

class DoctorCheck {
    public let group: String
    public let label: String
    public let status: String
    public let detail: String
    init(group: String, label: String, status: String, detail: String) {
        this.group = group
        this.label = label
        this.status = status
        this.detail = detail
    }
}

class DoctorReport {
    public let checks: Array<DoctorCheck>
    public let errors: Int64
    public let warnings: Int64
    init(checks: Array<DoctorCheck>, errors: Int64, warnings: Int64) {
        this.checks = checks
        this.errors = errors
        this.warnings = warnings
    }
    public prop exitCode: Int64 {
        get() {
            return if (errors > 0) {
                1
            } else {
                0
            }
        }
    }
}

// Version commands have small outputs. Capture in memory: no project/temp writes,
// no shell, no environment changes, and never reuse the update runner here.
func readDoctorVersion(tool: String): String {
    let executable = locateToolExecutable(tool)
    try {
        let (code, out, err) = executeWithOutput(executable.toString(), ["--version"], stdIn: ProcessRedirect.Discard)
        if (code != 0) {
            throw Exception(
                "${tool} --version exited ${code}: " + displayCell(processOutputText(out) + processOutputText(err),
                    limit: 240))
        }
        let prefix = if (tool == "cjc") {
            "Cangjie Compiler: "
        } else {
            "Cangjie Package Manager: "
        }
        for (line in processOutputText(out).split("\n")) {
            if (line.startsWith(prefix)) {
                let version = line.removePrefix(prefix).removeSuffix("\r").split(" ")[0]
                if (!version.isEmpty()) {
                    return version
                }
            }
        }
        throw Exception(
            "unrecognized ${tool} version output: " + displayCell(processOutputText(out) + processOutputText(err),
                limit: 240))
    } catch (error: Exception) {
        throw Exception(error.message + ". Make sure the Cangjie SDK environment is loaded.")
    }
}

private class DoctorBuilder {
    let rows = ArrayList<DoctorCheck>()
    var errors: Int64 = 0
    var warnings: Int64 = 0
    func add(group: String, label: String, status: String, detail: String, count!: Bool = true): Unit {
        rows.add(DoctorCheck(group, label, status, detail))
        if (count && status == "ERROR") {
            errors++
        }
        if (count && status == "WARN") {
            warnings++
        }
    }
    func report(): DoctorReport {
        return DoctorReport(rows.toArray(), errors, warnings)
    }
}

func inspectDoctorPath(projectRoot: Path, spec: String): (String, String) {
    // Do not probe UNC/device paths: existence checks can contact a remote host.
    if (spec.startsWith("\\\\") || spec.startsWith("//")) {
        return ("WARN", "network/device path not checked: ${spec}")
    }
    try {
        let declared = Path(spec)
        let target = if (declared.isAbsolute()) {
            declared
        } else {
            projectRoot.join(declared)
        }
        if (!exists(target)) {
            return ("ERROR", "path does not exist: ${spec}")
        }
        if (!FileInfo(target).isDirectory()) {
            return ("WARN", "path exists but is not a directory: ${spec}")
        }
        let manifest = target.join("cjpm.toml")
        if (!exists(manifest) || !FileInfo(manifest).isRegular()) {
            return ("WARN", "directory exists but no regular cjpm.toml was found: ${spec}")
        }
        return ("OK", "path exists: ${spec}")
    } catch (error: Exception) {
        return ("ERROR", "cannot inspect path '${spec}': ${error.message}")
    }
}

// Internal read-only seams allow deterministic missing/permission/startup tests.
func diagnoseProject(version!: (String) -> String = readDoctorVersion, findProject!: () -> Option<Path> = findCjpmToml,
    readConfig!: (Path) -> String = readCjpmToml, readLock!: (Path) -> MetadataFileState = metadataState,
    inspectPath!: (Path, String) -> (String, String) = inspectDoctorPath): DoctorReport {
    let report = DoctorBuilder()
    var cjpmReady = false
    var cjpmVersion = ""
    for ((tool, label) in [("cjc", "Cangjie SDK"), ("cjpm", "CJPM")]) {
        try {
            let value = version(tool)
            if (tool == "cjpm") {
                cjpmVersion = value
                cjpmReady = true
            }
            report.add("Environment", label, if (value == "1.0.5") {
                "OK"
            } else {
                "WARN"
            }, value + if (value == "1.0.5") {
                ""
            } else {
                " (CJX is validated with 1.0.5; no upgrade is required)"
            })
        } catch (error: Exception) {
            report.add("Environment", label, "ERROR", error.message)
        }
    }
    var project: Option<Path> = None
    try {
        project = findProject()
        match (project) {
            case Some(path) => report.add("Project", "cjpm.toml", "OK", path.toString())
            case None => report.add("Project", "cjpm.toml", "ERROR",
                "not found in the current directory or any parent directory; run doctor inside a CJPM project")
        }
    } catch (error: Exception) {
        report.add("Project", "cjpm.toml", "ERROR", error.message)
    }
    match (project) {
        case Some(path) =>
            var text: Option<String> = None
            try {
                text = Some(readConfig(path))
            } catch (error: Exception) {
                // Replace the location row with a read error; count the cause once.
                report.rows.remove(at: report.rows.size - 1)
                report.add("Project", "cjpm.toml", "ERROR", "failed to read: ${error.message}")
            }
            try {
                let lock = readLock(path.parent.join("cjpm.lock"))
                report.add("Project", "cjpm.lock", if (!lock.present || lock.bytes.isEmpty()) {
                    "WARN"
                } else {
                    "OK"
                }, if (!lock.present) {
                    "not found; run cjpm update when ready"
                } else if (lock.bytes.isEmpty()) {
                    "empty file; lock contents are not parsed by doctor"
                } else {
                    "${lock.bytes.size} bytes (presence/readability only)"
                })
            } catch (error: Exception) {
                report.add("Project", "cjpm.lock", "ERROR", error.message)
            }
            try {
                if (exists(path.parent.join(".cjpm.toml.cjx-add"))) {
                    report.add("Project", "Transaction", "WARN",
                        "active operation or recovery snapshots exist; review them before add/remove")
                }
            } catch (error: Exception) {
                report.add("Project", "Transaction", "ERROR", "cannot inspect operation state: ${error.message}")
            }
            match (text) {
                case Some(content) => try {
                    let section = scanDependencies(content)
                    let entries = match (section) {
                        case Some(s) => s.entries;
                        case None => Array<DependencyEntry>()
                    }
                    report.add("Configuration", "TOML scan", "OK", "structural scan only; not full TOML/CJPM validation")
                    var unknown: Int64 = 0
                    var central: Int64 = 0
                    for (entry in entries) {
                        let info = classifyDependency(entry)
                        let source = sourceLabel(info.source)
                        if (source == "unknown") {
                            unknown++
                            report.add("Dependency details", entry.key, "WARN",
                                "Unknown: " + displayCell(entry.rawValue, limit: 120), count: false)
                        }
                        if (source == "central") {
                            central++
                            report.add("Dependency details", entry.key, if (cjpmVersion == "1.0.5") {
                                "WARN"
                            } else {
                                "INFO"
                            }, if (cjpmVersion == "1.0.5") {
                                "central version dependency is not supported by CJPM 1.0.5"
                            } else {
                                "version declaration; support in this CJPM version is not verified"
                            }, count: false)
                        }
                        if (source == "path") {
                            let (status, detail) = inspectPath(path.parent, info.spec)
                            report.add("Dependency details", entry.key, status, detail)
                        }
                        if (source == "git") {
                            report.add("Dependency details", entry.key, "OK",
                                "git dependency configured (not contacted)")
                        }
                    }
                    report.add("Project", "Dependencies", if (unknown > 0) {
                        "WARN"
                    } else {
                        "OK"
                    }, "${entries.size} " + if (entries.size == 1) {
                        "dependency"
                    } else {
                        "dependencies"
                    } + if (unknown > 0) {
                        "; ${unknown} could not be classified; see Unknown entries below"
                    } else {
                        ""
                    } + match (section) {
                        case Some(_) => "";
                        case None => " (no dependencies section)"
                    })
                    let unsupported = if (cjpmVersion == "1.0.5") {
                        central
                    } else {
                        0
                    }
                    report.add("Configuration", "Unsupported",
                        if (unsupported > 0) {
                            "WARN"
                        } else if (cjpmVersion != "1.0.5") {
                            "SKIP"
                        } else {
                            "OK"
                        }, if (cjpmVersion == "1.0.5") {
                            "${unsupported}" + if (unsupported > 0) {
                                " version/central declarations unsupported by CJPM 1.0.5"
                            } else {
                                " known unsupported declarations"
                            }
                        } else {
                            "compatibility not verified for the detected CJPM"
                        })
                    report.add("Configuration", "Unknown values", if (unknown > 0) {
                        "WARN"
                    } else {
                        "OK"
                    }, "${unknown}" + if (unknown > 0) {
                        "; review declarations with cjx list"
                    } else {
                        ""
                    }, count: false)
                } catch (error: Exception) {
                    report.add("Project", "Dependencies", "SKIP", "configuration scan failed")
                    report.add("Configuration", "TOML scan", "ERROR", error.message)
                    report.add("Configuration", "Unsupported", "SKIP", "cannot count safely after scan failure")
                    report.add("Configuration", "Unknown values", "SKIP", "cannot count safely after scan failure")
                }
                case None =>
                    report.add("Project", "Dependencies", "SKIP", "configuration could not be read")
                    report.add("Configuration", "TOML scan", "SKIP", "configuration could not be read")
                    report.add("Configuration", "Unsupported", "SKIP", "configuration could not be read")
                    report.add("Configuration", "Unknown values", "SKIP", "configuration could not be read")
            }
        case None =>
            report.add("Project", "cjpm.lock", "SKIP", "no project located")
            report.add("Project", "Dependencies", "SKIP", "no project located")
            report.add("Configuration", "TOML scan", "SKIP", "no project located")
            report.add("Configuration", "Unsupported", "SKIP", "no project located")
            report.add("Configuration", "Unknown values", "SKIP", "no project located")
    }
    report.add("CJPM", "cjpm update", if (cjpmReady) {
        "READY"
    } else {
        "BLOCKED"
    }, "executable startup only; update was not executed or validated")
    return report.report()
}

func formatDoctor(report: DoctorReport): String {
    var result = "CJX Doctor\n--------------------------------------------------\n"
    var width: Int64 = 18
    for (check in report.checks) {
        let size = displayCell(check.label).size + 2
        if (size > width) {
            width = size
        }
    }
    for (group in ["Environment", "Project", "Configuration", "Dependency details", "CJPM"]) {
        var present = false
        for (check in report.checks) {
            if (check.group == group) {
                present = true
            }
        }
        if (!present) {
            continue
        }
        result += "\n${group}\n\n"
        for (check in report.checks) {
            if (check.group == group) {
                let label = displayCell(check.label)
                result += label + " " * (width - label.size) + check.status + " " * (9 - check.status.size) +
                    displayCell(check.detail) + "\n"
            }
        }
    }
    result += "\nResult\n\n"
    if (report.errors + report.warnings == 0) {
        result += "All checks passed.\n"
    } else {
        let total = report.errors + report.warnings
        result += "${total} " + if (total == 1) {
            "problem"
        } else {
            "problems"
        } + " found (${report.errors} errors, ${report.warnings} warnings).\n"
    }
    return result
}

func doctorProject(): Int64 {
    try {
        let report = diagnoseProject()
        print(formatDoctor(report))
        return report.exitCode
    } catch (error: Exception) {
        println("Error: doctor could not complete: ${displayCell(error.message)}")
        return 1
    }
}
