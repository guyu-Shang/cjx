package cjx

import std.collection.{ArrayList, HashSet}

// All ranges are half-open UTF-8 BYTE ranges into the unchanged input.
class DependencyEntry {
    public let key: String
    public let rawValue: String
    public let start: Int64 // first byte of key, excluding indentation
    public let valueStart: Int64
    public let end: Int64 // end of value, excluding trailing spaces/comment
    public let lineStart: Int64
    public let statementEnd: Int64 // includes trailing comment and original newline
    public let commentStart: Int64 // -1 when there is no trailing comment

    init(key: String, rawValue: String, start: Int64, valueStart: Int64, end: Int64, lineStart: Int64,
        statementEnd: Int64, commentStart: Int64) {
        this.key = key
        this.rawValue = rawValue
        this.start = start
        this.valueStart = valueStart
        this.end = end
        this.lineStart = lineStart
        this.statementEnd = statementEnd
        this.commentStart = commentStart
    }
}

class DependencySection {
    public let start: Int64 // header line start; excludes any leading UTF-8 BOM
    public let contentStart: Int64 // after header comment and newline
    public let end: Int64 // next header line start or EOF
    public let entries: Array<DependencyEntry>

    init(start: Int64, contentStart: Int64, end: Int64, entries: Array<DependencyEntry>) {
        this.start = start
        this.contentStart = contentStart
        this.end = end
        this.entries = entries
    }
}

func scanDependencies(text: String): Option<DependencySection> {
    return DependencyScanner(text).scan()
}

// Structural scanner, not a TOML semantic validator or a serializer.
// Numeric/date values and inline-table fields are kept opaque.
private class DependencyScanner {
    let bytes: Array<Byte>
    var pos: Int64 = 0

    init(text: String) {
        bytes = text.toArray()
    }

    func fail(reason: String): Nothing {
        throw Exception("unsupported or malformed cjpm.toml at byte ${pos}: ${reason}")
    }

    func at(value: Byte): Bool {
        return pos < bytes.size && bytes[pos] == value
    }

    func space(): Bool {
        return at(32) || at(9)
    }

    func skipSpace(): Unit {
        while (space()) {
            pos++
        }
    }

    func newline(): Unit {
        if (at(13)) {
            pos++
            if (!at(10)) {
                fail("bare CR; expected LF or CRLF")
            }
        }
        if (!at(10)) {
            fail("expected newline")
        }
        pos++
    }

    func comment(): Unit {
        while (pos < bytes.size && !at(10) && !at(13)) {
            if ((bytes[pos] < 32 && !at(9)) || at(127)) {
                fail("control byte in comment")
            }
            pos++
        }
    }

    // Finish a statement without absorbing the next line. Return comment start.
    func finishLine(): Int64 {
        skipSpace()
        var commentStart: Int64 = -1
        if (at(35)) {
            commentStart = pos
            comment()
        }
        if (pos < bytes.size) {
            if (!at(10) && !at(13)) {
                fail("unexpected text after statement")
            }
            newline()
        }
        return commentStart
    }

    func slice(start: Int64, end: Int64): String {
        return String.fromUtf8(bytes[start..end])
    }

    func hexDigit(): UInt32 {
        if (pos >= bytes.size) {
            fail("incomplete Unicode escape")
        }
        let b = bytes[pos]
        pos++
        if (b >= 48 && b <= 57) {
            return UInt32(b - 48)
        }
        if (b >= 65 && b <= 70) {
            return UInt32(b - 65 + 10)
        }
        if (b >= 97 && b <= 102) {
            return UInt32(b - 97 + 10)
        }
        fail("invalid Unicode escape")
    }

    // Keys need decoded text for comparison; values only need lexical validation.
    func stringToken(key: Bool): String {
        let delimiter = bytes[pos]
        let basic = delimiter == 34
        pos++
        let multiline = pos + 1 < bytes.size && bytes[pos] == delimiter && bytes[pos + 1] == delimiter
        if (multiline) {
            if (key) {
                fail("multiline keys are unsupported")
            }
            pos += 2
        }
        let decoded = ArrayList<Byte>()
        while (pos < bytes.size) {
            if (at(delimiter)) {
                var count: Int64 = 0
                while (pos + count < bytes.size && bytes[pos + count] == delimiter) {
                    count++
                }
                if (!multiline) {
                    pos++;
                    return String.fromUtf8(decoded.toArray())
                }
                if (count >= 3) {
                    if (count > 5) {
                        fail("ambiguous multiline closing quotes")
                    }
                    pos += count
                    return ""
                }
                pos += count
                continue
            }
            if (at(10) || at(13)) {
                if (!multiline) {
                    fail("unclosed single-line string")
                }
                newline()
                continue
            }
            if (basic && at(92)) {
                pos++
                if (multiline && (space() || at(10) || at(13))) {
                    skipSpace()
                    if (!at(10) && !at(13)) {
                        fail("invalid multiline continuation")
                    }
                    while (space() || at(10) || at(13)) {
                        if (space()) {
                            pos++
                        } else {
                            newline()
                        }
                    }
                    continue
                }
                if (pos >= bytes.size) {
                    fail("incomplete string escape")
                }
                let escape = bytes[pos]
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
                        let digits = if (escape == 117) {
                            4
                        } else {
                            8
                        }
                        for (_ in 0..digits) {
                            scalar = scalar * 16 + hexDigit()
                        }
                        if (scalar > 0x10FFFF || (scalar >= 0xD800 && scalar <= 0xDFFF)) {
                            fail("invalid Unicode scalar")
                        }
                    case _ => fail("invalid string escape")
                }
                if (key) {
                    decoded.add(all: Rune(scalar).toString().toArray())
                }
                continue
            }
            if ((bytes[pos] < 32 && !at(9)) || at(127)) {
                fail("control byte in string")
            }
            if (key) {
                decoded.add(bytes[pos])
            }
            pos++
        }
        fail("unclosed string or multiline string")
    }

    func keyPath(): ArrayList<String> {
        let parts = ArrayList<String>()
        while (true) {
            skipSpace()
            if (at(34) || at(39)) {
                parts.add(stringToken(true))
            } else {
                let start = pos
                while (pos < bytes.size) {
                    let b = bytes[pos]
                    if (!((b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 95 || b == 45)) {
                        break
                    }
                    pos++
                }
                if (pos == start) {
                    fail("expected bare or quoted key")
                }
                parts.add(slice(start, pos))
            }
            skipSpace()
            if (!at(46)) {
                break
            }
            pos++
        }
        return parts
    }

    // Scan balanced containers; strings and comments shield structural bytes.
    func container(): Unit {
        let closing = ArrayList<Byte>()
        while (pos < bytes.size) {
            if (at(34) || at(39)) {
                stringToken(false);
                continue
            }
            if (at(35)) {
                comment();
                continue
            }
            if (at(10) || at(13)) {
                newline();
                continue
            }
            if (at(91) || at(123)) {
                closing.add(if (at(91)) {
                    93
                } else {
                    125
                })
            } else if (at(93) || at(125)) {
                if (closing.isEmpty() || bytes[pos] != closing[closing.size - 1]) {
                    fail("mismatched [] or {}")
                }
                closing.remove(at: closing.size - 1)
                pos++
                if (closing.isEmpty()) {
                    return
                }
                continue
            } else if ((bytes[pos] < 32 && !at(9)) || at(127)) {
                fail("control byte in value")
            }
            pos++
        }
        fail("unclosed inline table or array")
    }

    func value(dependency: Bool): Int64 {
        if (pos >= bytes.size || at(10) || at(13) || at(35)) {
            fail("missing value")
        }
        if (at(34) || at(39)) {
            stringToken(false)
        } else if (at(123) || at(91)) {
            if (dependency && at(91)) {
                fail("unsupported dependencies expression: array value")
            }
            container()
        } else {
            if (dependency) {
                fail("unsupported dependencies expression: expected string or inline table")
            }
            // Opaque scalar in another section; this is not numeric/date validation.
            while (pos < bytes.size && !at(10) && !at(13) && !at(35)) {
                if (at(34) || at(39) || at(91) || at(93) || at(123) || at(125) || at(61) || (bytes[pos] < 32 && !at(9)) ||
                    at(127)) {
                    fail("unexpected byte in scalar")
                }
                pos++
            }
        }
        var end = pos
        while (end > 0 && (bytes[end - 1] == 32 || bytes[end - 1] == 9)) {
            end--
        }
        return end
    }

    func scan(): Option<DependencySection> {
        if (bytes.size >= 3 && bytes[0] == 239 && bytes[1] == 187 && bytes[2] == 191) {
            pos = 3
        }
        var sectionStart: Int64 = -1
        var contentStart: Int64 = -1
        var sectionEnd = bytes.size
        var inDependencies = false
        var root = true
        let entries = ArrayList<DependencyEntry>()
        let keys = HashSet<String>()
        while (pos < bytes.size) {
            let lineStart = pos
            skipSpace()
            if (pos == bytes.size) {
                break
            }
            if (at(35) || at(10) || at(13)) {
                finishLine();
                continue
            }
            if (at(91)) {
                if (inDependencies) {
                    sectionEnd = lineStart
                }
                inDependencies = false
                root = false
                pos++
                let arrayTable = at(91)
                if (arrayTable) {
                    pos++
                }
                let path = keyPath()
                if (!at(93)) {
                    fail("unclosed section header")
                }
                pos++
                if (arrayTable) {
                    if (!at(93)) {
                        fail("unclosed array-table header")
                    }
                    pos++
                }
                finishLine()
                if (path[0] == "dependencies") {
                    if (arrayTable || path.size != 1) {
                        fail("unsupported dependencies expression: subtable or array table")
                    }
                    if (sectionStart >= 0) {
                        fail("duplicate dependencies section")
                    }
                    sectionStart = lineStart
                    contentStart = pos
                    inDependencies = true
                }
                continue
            }
            let start = pos
            let path = keyPath()
            if (root && path[0] == "dependencies") {
                fail("unsupported dependencies expression: root assignment")
            }
            if (inDependencies && path.size != 1) {
                fail("unsupported dependencies expression: dotted key")
            }
            if (!at(61)) {
                fail("expected '=' after key")
            }
            pos++
            skipSpace()
            let valueStart = pos
            let end = value(inDependencies)
            let commentStart = finishLine()
            if (inDependencies) {
                if (keys.contains(path[0])) {
                    fail("duplicate dependency key '${path[0]}'")
                }
                keys.add(path[0])
                entries.add(
                    DependencyEntry(path[0], slice(valueStart, end), start, valueStart, end, lineStart, pos,
                        commentStart))
            }
        }
        if (sectionStart < 0) {
            return None
        }
        return Some(DependencySection(sectionStart, contentStart, sectionEnd, entries.toArray()))
    }
}
