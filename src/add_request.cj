package cjx

import std.collection.{ArrayList, HashMap}

class AddRequest {
    public let name: String
    public let fields: HashMap<String, String>
    init(name: String, fields: HashMap<String, String>) {
        this.name = name
        this.fields = fields
    }
}

// CLI-only flag is kept out of the dependency declaration and planner.
func parseAddCommand(args: Array<String>): (AddRequest, Bool, Bool) {
    if (args.isEmpty()) {
        return (parseAddRequest(args), false, false)
    }
    let requestArgs = ArrayList<String>()
    requestArgs.add(args[0])
    var dryRun = false
    var noUpdate = false
    var i: Int64 = 1
    while (i < args.size) {
        if (args[i] == "--dry-run" || args[i] == "--no-update") {
            if (args[i] == "--dry-run") {
                if (dryRun) {
                    throw Exception("duplicate add option: --dry-run")
                }
                dryRun = true
            } else {
                if (noUpdate) {
                    throw Exception("duplicate add option: --no-update")
                }
                noUpdate = true
            }
            i++
        } else {
            requestArgs.add(args[i])
            // Preserve option/value pairs. A flag in a value position must not
            // be stripped and accidentally turn a missing value into success.
            if (i + 1 < args.size) {
                requestArgs.add(args[i + 1])
            }
            i += 2
        }
    }
    return (parseAddRequest(requestArgs.toArray()), dryRun, noUpdate)
}

// CJPM 1.0.5 dependency-name checks accept a leading underscore too.
func validDependencyName(name: String): Bool {
    let bytes = name.toArray()
    if (bytes.isEmpty()) {
        return false
    }
    var first: Int64 = 0
    while (first < bytes.size && bytes[first] == 95) {
        first++
    }
    if (first == bytes.size || !(bytes[first] >= 65 && bytes[first] <= 90 || bytes[first] >= 97 && bytes[first] <= 122)) {
        return false
    }
    for (i in 0..bytes.size) {
        let b = bytes[i]
        if (!(b >= 65 && b <= 90 || b >= 97 && b <= 122 || b == 95 || i > 0 && b >= 48 && b <= 57)) {
            return false
        }
    }
    return true
}

func parseAddRequest(args: Array<String>): AddRequest {
    if (args.isEmpty() || !validDependencyName(args[0])) {
        throw Exception("add requires a CJPM dependency name: _*[A-Za-z][A-Za-z0-9_]* (no package@version).")
    }
    let fields = HashMap<String, String>()
    var i: Int64 = 1
    while (i < args.size) {
        let field = match (args[i]) {
            case "--path" => "path"
            case "--git" => "git"
            case "--branch" => "branch"
            case "--tag" => "tag"
            case "--commit-id" => "commitId"
            case _ => throw Exception("unknown add option: ${displayCell(args[i])}")
        }
        if (fields.contains(field)) {
            throw Exception("duplicate add option: ${args[i]}")
        }
        if (i + 1 >= args.size || args[i + 1].isEmpty() || args[i + 1].startsWith("--")) {
            throw Exception("missing value for ${args[i]}")
        }
        fields.add(field, args[i + 1])
        i += 2
    }
    if (fields.contains("path") == fields.contains("git")) {
        throw Exception("add requires exactly one of --path or --git.")
    }
    if (!fields.contains("git") && fields.size != 1) {
        throw Exception("--branch, --tag and --commit-id require --git.")
    }
    return AddRequest(args[0], fields)
}

func tomlBasicString(value: String): String {
    let out = ArrayList<Byte>()
    out.add(34)
    let hex = "0123456789ABCDEF".toArray()
    for (b in value.toArray()) {
        if (b == 34 || b == 92) {
            out.add(92);
            out.add(b)
        } else if (b < 32 || b == 127) {
            out.add(all: "\\u00".toArray())
            out.add(hex[Int64(b) / 16]);
            out.add(hex[Int64(b) % 16])
        } else {
            out.add(b)
        }
    }
    out.add(34)
    return String.fromUtf8(out.toArray())
}

func addDeclaration(request: AddRequest): String {
    var result = request.name + " = { "
    var separator = ""
    for (field in ["path", "git", "commitId", "branch", "tag"]) {
        if (request.fields.contains(field)) {
            result += separator + field + " = " + tomlBasicString(request.fields[field])
            separator = ", "
        }
    }
    return result + " }"
}
