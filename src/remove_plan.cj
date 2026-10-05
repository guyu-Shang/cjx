package cjx

class RemovePlan {
    public let dependency: DependencyEntry
    public let patch: TextPatch
    public let modifiedText: String
    public let declaration: String

    init(dependency: DependencyEntry, patch: TextPatch, modifiedText: String, declaration: String) {
        this.dependency = dependency
        this.patch = patch
        this.modifiedText = modifiedText
        this.declaration = declaration
    }
}

// Match the decoded scanner key exactly; do not apply add's SDK name rules
// when removing an existing declaration. The scanner remains the authority.
func parseRemoveRequest(args: Array<String>): String {
    if (args.size != 1 || args[0].isEmpty() || args[0].startsWith("-")) {
        throw Exception("expected one nonempty dependency name, not an option.")
    }
    return args[0]
}

func parseRemoveCommand(args: Array<String>): (String, Bool, Bool) {
    if (args.isEmpty()) {
        throw Exception("usage: cjx remove <name> [--dry-run] [--no-update]")
    }
    let name = parseRemoveRequest(args[..1])
    var dryRun = false
    var noUpdate = false
    for (flag in args[1..]) {
        if (flag == "--dry-run" && !dryRun) {
            dryRun = true
        } else if (flag == "--no-update" && !noUpdate) {
            noUpdate = true
        } else {
            throw Exception("unknown or duplicate remove option: ${flag}")
        }
    }
    return (name, dryRun, noUpdate)
}

// Same planner and semantic checks at temporary, committed and post-update reads.
func validateRemoveResult(original: String, modified: String, name: String): Unit {
    let expected = planRemoveDependency(original, name)
    if (!sameRemoveBytes(expected.modifiedText.toArray(), modified.toArray())) {
        throw Exception("remove validation failed: content differs from the validated remove plan")
    }
    scanDependencies(modified)
}

private func sameRemoveBytes(a: Array<Byte>, b: Array<Byte>): Bool {
    if (a.size != b.size) {
        return false
    }
    for (i in 0..a.size) {
        if (a[i] != b[i]) {
            return false
        }
    }
    return true
}

func planRemoveDependency(original: String, name: String): RemovePlan {
    if (name.isEmpty()) {
        throw Exception("dependency name must not be empty.")
    }
    let section = match (scanDependencies(original)) {
        case Some(s) => s
        case None => throw Exception("dependency '${name}' was not found.")
    }
    var selected: Option<DependencyEntry> = None
    for (entry in section.entries) {
        if (entry.key == name) {
            selected = Some(entry)
        }
    }
    let target = match (selected) {
        case Some(e) => e
        case None => throw Exception("dependency '${name}' was not found.")
    }
    let bytes = original.toArray()
    // Remove indentation + all physical statement lines + trailing comment +
    // that statement's line terminator. Keep every preceding comment/blank line:
    // textual adjacency alone cannot prove ownership of a user's explanation.
    let start = target.lineStart
    let end = target.statementEnd
    if (start < section.contentStart || end > section.end || start > target.start || end < target.end || (start > 0 &&
        bytes[start - 1] != 10) || (end < bytes.size && bytes[end - 1] != 10)) {
        throw Exception("remove validation failed: unsafe statement boundary")
    }
    let patch = TextPatch(start, end, "")
    let modified = applyPatch(original, patch)
    let after = match (scanDependencies(modified)) {
        case Some(s) => s
        case None => throw Exception("remove validation failed: dependencies section disappeared")
    }
    if (after.entries.size != section.entries.size - 1) {
        throw Exception("remove validation failed: dependency count")
    }
    for (entry in after.entries) {
        if (entry.key == name) {
            throw Exception("remove validation failed: dependency still exists")
        }
    }
    var index: Int64 = 0
    for (old in section.entries) {
        if (old.key == name) {
            continue
        }
        let retained = after.entries[index]
        let oldInfo = classifyDependency(old)
        let newInfo = classifyDependency(retained)
        if (old.key != retained.key || old.rawValue != retained.rawValue || sourceLabel(oldInfo.source) != sourceLabel(
            newInfo.source) || oldInfo.spec != newInfo.spec) {
            throw Exception("remove validation failed: retained dependency changed")
        }
        index++
    }
    let result = modified.toArray()
    if (result.size != bytes.size - (end - start)) {
        throw Exception("remove validation failed: byte length")
    }
    for (i in 0..start) {
        if (bytes[i] != result[i]) {
            throw Exception("remove validation failed: prefix changed")
        }
    }
    for (i in end..bytes.size) {
        if (bytes[i] != result[i - (end - start)]) {
            throw Exception("remove validation failed: suffix changed")
        }
    }
    // The preview excludes the final newline but includes the trailing comment.
    var displayEnd = end
    if (displayEnd > start && bytes[displayEnd - 1] == 10) {
        displayEnd--
        if (displayEnd > start && bytes[displayEnd - 1] == 13) {
            displayEnd--
        }
    }
    return RemovePlan(target, patch, modified, String.fromUtf8(bytes[target.start..displayEnd]))
}
