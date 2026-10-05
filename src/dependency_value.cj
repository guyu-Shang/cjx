package cjx

import std.collection.{ArrayList, HashMap}

enum DependencySource {
    Path | Git | Central | Unknown
}

class DependencyInfo {
    public let name: String
    public let source: DependencySource
    public let spec: String

    init(name: String, source: DependencySource, spec: String) {
        this.name = name
        this.source = source
        this.spec = spec
    }
}

// A deliberately limited reader: single-line TOML strings and flat string fields.
// Unsupported values remain available as raw text for Unknown display.
private class DependencyValueReader {
    let data: Array<Byte>
    var pos: Int64 = 0

    init(text: String) {
        data = text.toArray()
    }

    func at(b: Byte): Bool {
        return pos < data.size && data[pos] == b
    }
    func reject(): Nothing {
        throw Exception("unsupported dependency value")
    }

    func whitespace(): Unit {
        while (pos < data.size) {
            if (at(32) || at(9) || at(10)) {
                pos++;
                continue
            }
            if (at(13)) {
                pos++
                if (!at(10)) {
                    reject()
                }
                pos++;
                continue
            }
            if (at(35)) {
                while (pos < data.size && !at(10) && !at(13)) {
                    pos++
                }
                continue
            }
            break
        }
    }

    func stringValue(): String {
        if (!at(34) && !at(39)) {
            reject()
        }
        let delimiter = data[pos]
        pos++
        if (pos + 1 < data.size && data[pos] == delimiter && data[pos + 1] == delimiter) {
            reject()
        }
        let output = ArrayList<Byte>()
        while (pos < data.size) {
            let b = data[pos]
            pos++
            if (b == delimiter) {
                return String.fromUtf8(output.toArray())
            }
            if (b < 32 && b != 9 || b == 127) {
                reject()
            }
            if (delimiter == 34 && b == 92) {
                if (pos >= data.size) {
                    reject()
                }
                let escape = data[pos]
                pos++
                var scalar: UInt32 = 0
                match (escape) {
                    case 34 => scalar = 34
                    case 92 => scalar = 92
                    case 98 => scalar = 8
                    case 116 => scalar = 9
                    case 110 => scalar = 10
                    case 102 => scalar = 12
                    case 114 => scalar = 13
                    case 117 | 85 =>
                        let count = if (escape == 117) {
                            4
                        } else {
                            8
                        }
                        for (_ in 0..count) {
                            if (pos >= data.size) {
                                reject()
                            }
                            let digit = data[pos]
                            pos++
                            scalar *= 16
                            if (digit >= 48 && digit <= 57) {
                                scalar += UInt32(digit - 48)
                            } else if (digit >= 65 && digit <= 70) {
                                scalar += UInt32(digit - 65 + 10)
                            } else if (digit >= 97 && digit <= 102) {
                                scalar += UInt32(digit - 97 + 10)
                            } else {
                                reject()
                            }
                        }
                        if (scalar > 0x10FFFF || scalar >= 0xD800 && scalar <= 0xDFFF) {
                            reject()
                        }
                    case _ => reject()
                }
                output.add(all: Rune(scalar).toString().toArray())
            } else {
                output.add(b)
            }
        }
        reject()
    }

    func key(): String {
        if (at(34) || at(39)) {
            return stringValue()
        }
        let start = pos
        while (pos < data.size) {
            let b = data[pos]
            if (!(b >= 65 && b <= 90 || b >= 97 && b <= 122 || b >= 48 && b <= 57 || b == 95 || b == 45)) {
                break
            }
            pos++
        }
        if (pos == start) {
            reject()
        }
        return String.fromUtf8(data[start..pos])
    }

    func fields(): HashMap<String, String> {
        let result = HashMap<String, String>()
        if (!at(123)) {
            reject()
        }
        pos++
        whitespace()
        if (at(125)) {
            pos++;
            return result
        }
        while (true) {
            let field = key()
            whitespace()
            if (!at(61) || result.contains(field)) {
                reject()
            }
            pos++
            whitespace()
            result.add(field, stringValue())
            whitespace()
            if (at(125)) {
                pos++;
                return result
            }
            if (!at(44)) {
                reject()
            }
            pos++
            whitespace()
            if (at(125)) {
                reject()
            } // no trailing comma in this reader
        }
        reject()
    }

    func finish(): Unit {
        whitespace()
        if (pos != data.size) {
            reject()
        }
    }

    func read(name: String): DependencyInfo {
        whitespace()
        if (at(34) || at(39)) {
            let version = stringValue()
            finish()
            if (version.isEmpty()) {
                reject()
            }
            return DependencyInfo(name, Central, version)
        }
        let table = fields()
        finish()
        for ((k, _) in table) {
            if (k != "path" && k != "git" && k != "version" && k != "branch" && k != "tag" && k != "commitId") {
                reject()
            }
        }
        if (table.contains("path") && table.size == 1 && !table["path"].isEmpty()) {
            return DependencyInfo(name, Path, table["path"])
        }
        if (table.contains("version") && table.size == 1 && !table["version"].isEmpty()) {
            return DependencyInfo(name, Central, table["version"])
        }
        if (table.contains("git") && !table.contains("path") && !table.contains("version") && !table["git"].isEmpty()) {
            var spec = table["git"]
            // Show declarations, including lower-priority selectors, without hiding them.
            for (selector in ["commitId", "branch", "tag"]) {
                if (table.contains(selector)) {
                    if (table[selector].isEmpty()) {
                        reject()
                    }
                    spec += " [${selector}=${table[selector]}]"
                }
            }
            return DependencyInfo(name, Git, spec)
        }
        reject()
    }
}

func classifyDependency(entry: DependencyEntry): DependencyInfo {
    try {
        return DependencyValueReader(entry.rawValue).read(entry.key)
    } catch (_: Exception) {
        return DependencyInfo(entry.key, Unknown, entry.rawValue)
    }
}

func sourceLabel(source: DependencySource): String {
    match (source) {
        case Path => "path"
        case Git => "git"
        case Central => "central"
        case Unknown => "unknown"
    }
}

// Keep each cell on one line; do not send decoded control bytes to the terminal.
func displayCell(text: String, limit!: Int64 = 0): String {
    let out = ArrayList<Byte>()
    for (b in text.toArray()) {
        match (b) {
            case 10 => out.add(all: "\\n".toArray())
            case 13 => out.add(all: "\\r".toArray())
            case 9 => out.add(all: "\\t".toArray())
            case _ => out.add(if (b < 32 || b == 127) {
                63
            } else {
                b
            })
        }
    }
    let bytes = out.toArray()
    if (limit > 0 && bytes.size > limit) {
        var end = limit
        while (end > 0 && bytes[end] >= 128 && bytes[end] < 192) {
            end--
        }
        return String.fromUtf8(bytes[..end]) + "..."
    }
    return String.fromUtf8(bytes)
}

func formatDependencyList(section: Option<DependencySection>): String {
    let entries = match (section) {
        case Some(s) => s.entries;
        case None => Array<DependencyEntry>()
    }
    if (entries.isEmpty()) {
        return "Dependencies\n-------------\n(0 dependencies)\n"
    }
    let rows = ArrayList<DependencyInfo>()
    var width: Int64 = 4
    for (entry in entries) {
        let info = classifyDependency(entry)
        let name = displayCell(info.name)
        if (name.size > width) {
            width = name.size
        }
        rows.add(
            DependencyInfo(name, info.source,
                displayCell(info.spec, limit: if (sourceLabel(info.source) == "unknown") {
                    80
                } else {
                    0
                })))
    }
    let result = StringBuilder()
    result.append("Dependencies\n------------------------------------------------------------\n")
    result.append("NAME" + " " * (width - 4 + 2) + "SOURCE     SPEC\n")
    for (row in rows) {
        let label = sourceLabel(row.source)
        result.append(row.name + " " * (width - row.name.size + 2) + label + " " * (11 - label.size) + row.spec + "\n")
    }
    let noun = if (rows.size == 1) {
        "dependency"
    } else {
        "dependencies"
    }
    result.append("\n${rows.size} ${noun}\n")
    return result.toString()
}
