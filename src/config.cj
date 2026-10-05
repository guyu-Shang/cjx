package cjx

import std.fs.{Path, File, FileInfo, exists}

// Read only: preserve the complete text, including whitespace and an optional BOM.
// Empty files are valid reads; configuration semantics belong to a later phase.
func readCjpmToml(path: Path): String {
    if (!exists(path)) {
        throw Exception("File does not exist: '${path}'.")
    }
    if (!FileInfo(path).isRegular()) {
        throw Exception("Expected a regular file at '${path}'.")
    }

    // This standard-library helper owns opening and closing the file.
    // Let filesystem exceptions propagate so the CLI retains the actual reason.
    let bytes = File.readFrom(path)
    try {
        return String.fromUtf8(bytes)
    } catch (error: IllegalArgumentException) {
        throw Exception("UTF-8 decoding failed: ${error.message}")
    }
}
