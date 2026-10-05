package cjx

import std.fs.{Path, FileInfo, canonicalize, exists}

// None means the search reached the root without finding a manifest.
// Filesystem errors propagate to the CLI, which reports them without a stack trace.
func findCjpmToml(): Option<Path> {
    var directory = canonicalize(Path("."))
    while (true) {
        let candidate = directory.join("cjpm.toml")
        if (exists(candidate)) {
            if (!FileInfo(candidate).isRegular()) {
                throw Exception("Expected a regular file at '${candidate}'.")
            }
            return Some(candidate)
        }

        // Path.parent is empty at the filesystem root. Also guard against
        // a parent equal to the current path to avoid repeating a directory.
        let parent = directory.parent
        if (parent.toString().isEmpty() || parent == directory) {
            break
        }
        directory = parent
    }
    return None
}
