package cjx

import std.collection.ArrayList

class TextPatch {
    public let start: Int64
    public let end: Int64
    public let replacement: String
    init(start: Int64, end: Int64, replacement: String) {
        this.start = start
        this.end = end
        this.replacement = replacement
    }
}

func applyPatch(original: String, patch: TextPatch): String {
    let bytes = original.toArray()
    if (patch.start < 0 || patch.end < patch.start || patch.end > bytes.size) {
        throw Exception("invalid patch range")
    }
    // Decoding both slices also rejects offsets inside a UTF-8 sequence.
    return String.fromUtf8(bytes[..patch.start]) + patch.replacement + String.fromUtf8(bytes[patch.end..])
}

class AddPlan {
    public let patch: TextPatch
    public let modifiedText: String
    public let declaration: String
    init(patch: TextPatch, modifiedText: String, declaration: String) {
        this.patch = patch
        this.modifiedText = modifiedText
        this.declaration = declaration
    }
}

// Majority in the relevant section, otherwise whole document. Ties use first;
// a document without any line endings uses LF.
private func preferredNewline(text: String, fallback: String): String {
    let bytes = text.toArray()
    var crlf: Int64 = 0
    var lf: Int64 = 0
    var first = ""
    for (i in 0..bytes.size) {
        if (bytes[i] == 10) {
            let style = if (i > 0 && bytes[i - 1] == 13) {
                "\r\n"
            } else {
                "\n"
            }
            if (first.isEmpty()) {
                first = style
            }
            if (style == "\r\n") {
                crlf++
            } else {
                lf++
            }
        }
    }
    if (first.isEmpty()) {
        return fallback
    }
    if (crlf == lf) {
        return first
    }
    return if (crlf > lf) {
        "\r\n"
    } else {
        "\n"
    }
}

func planAdd(original: String, request: AddRequest): AddPlan {
    // Revalidate requests constructed outside the CLI too.
    let args = ArrayList<String>()
    args.add(request.name)
    for ((key, value) in request.fields) {
        args.add(if (key == "commitId") {
            "--commit-id"
        } else {
            "--" + key
        })
        args.add(value)
    }
    let checked = parseAddRequest(args.toArray())
    let before = scanDependencies(original)
    let oldEntries = match (before) {
        case Some(s) => s.entries
        case None => Array<DependencyEntry>()
    }
    for (entry in oldEntries) {
        if (entry.key == checked.name) {
            throw Exception("dependency '${checked.name}' already exists.")
        }
    }
    let declaration = addDeclaration(checked)
    let bytes = original.toArray()
    var offset = bytes.size
    var newline = preferredNewline(original, "\n")
    var insertion = ""
    match (before) {
        case Some(s) =>
            newline = preferredNewline(String.fromUtf8(bytes[s.start..s.end]), newline)
            offset = if (s.entries.isEmpty()) {
                s.contentStart
            } else {
                s.entries[s.entries.size - 1].statementEnd
            }
        case None => insertion = "[dependencies]" + newline
    }
    insertion += declaration
    // A BOM-only document has no preceding line that needs terminating.
    let bomOnlyPrefix = offset == 3 && bytes[0] == 239 && bytes[1] == 187 && bytes[2] == 191
    if (offset > 0 && !bomOnlyPrefix && bytes[offset - 1] != 10) {
        insertion = newline + insertion
    }
    if (offset < bytes.size || original.endsWith("\n")) {
        insertion += newline
    }
    let patch = TextPatch(offset, offset, insertion)
    let modified = applyPatch(original, patch)
    validateAddResult(original, modified, checked)
    let result = modified.toArray()
    if (modified.endsWith("\n") != original.endsWith("\n")) {
        throw Exception("add validation failed: declaration or final newline")
    }
    for (i in 0..offset) {
        if (bytes[i] != result[i]) {
            throw Exception("add validation failed: prefix changed")
        }
    }
    for (i in offset..bytes.size) {
        if (bytes[i] != result[i + insertion.size]) {
            throw Exception("add validation failed: suffix changed")
        }
    }
    return AddPlan(patch, modified, declaration)
}

// Shared by planner, transactional disk validation and CLI post-commit verification.
func validateAddResult(original: String, modified: String, request: AddRequest): Unit {
    let oldEntries = match (scanDependencies(original)) {
        case Some(s) => s.entries
        case None => Array<DependencyEntry>()
    }
    let after = match (scanDependencies(modified)) {
        case Some(s) => s
        case None => throw Exception("add validation failed: missing dependencies section")
    }
    if (after.entries.size != oldEntries.size + 1) {
        throw Exception("add validation failed: dependency count")
    }
    for (old in oldEntries) {
        var retained = false
        for (entry in after.entries) {
            if (entry.key == old.key && entry.rawValue == old.rawValue) {
                retained = true
            }
        }
        if (!retained) {
            throw Exception("add validation failed: existing dependency changed")
        }
    }
    var expectedSpec = if (request.fields.contains("path")) {
        request.fields["path"]
    } else {
        request.fields["git"]
    }
    for (selector in ["commitId", "branch", "tag"]) {
        if (request.fields.contains(selector)) {
            expectedSpec += " [${selector}=${request.fields[selector]}]"
        }
    }
    let expectedSource = if (request.fields.contains("path")) {
        "path"
    } else {
        "git"
    }
    var found = false
    for (entry in after.entries) {
        if (entry.key == request.name) {
            let info = classifyDependency(entry)
            found = sourceLabel(info.source) == expectedSource && info.spec == expectedSpec
        }
    }
    if (!found) {
        throw Exception("add validation failed: declaration source/spec")
    }
}
