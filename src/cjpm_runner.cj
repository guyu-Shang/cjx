package cjx

import std.env.getVariable
import std.fs.{Path, File, FileInfo, Directory, canonicalize, exists, remove}
import std.process.{execute, ProcessRedirect}

class CjpmUpdateResult {
    public let exitCode: Int64
    public let stdout: Array<Byte>
    public let stderr: Array<Byte>
    init(exitCode: Int64, stdout: Array<Byte>, stderr: Array<Byte>) {
        this.exitCode = exitCode
        this.stdout = stdout
        this.stderr = stderr
    }
}

func locateCjpm(): Path {
    return locateToolExecutable("cjpm")
}

func locateToolExecutable(name: String): Path {
    let search = match (getVariable("PATH")) {
        case Some(value) => value;
        case None => ""
    }
    for (part in search.split(";")) {
        if (part.isEmpty()) {
            continue
        }
        let folder = part.removePrefix("\"").removeSuffix("\"")
        let candidate = Path(folder).join(name + ".exe")
        if (exists(candidate) && FileInfo(candidate).isRegular()) {
            return canonicalize(candidate)
        }
    }
    throw Exception(
        "unable to start ${name}: ${name}.exe was not found on PATH. Make sure the Cangjie SDK environment is loaded.")
}

func runCjpmUpdate(projectRoot: Path): CjpmUpdateResult {
    return runCjpmExecutable(projectRoot, locateCjpm())
}

// File redirection avoids filling stdout/stderr pipes while waiting for CJPM.
func runCjpmExecutable(projectRoot: Path, executable: Path): CjpmUpdateResult {
    if (!exists(executable) || !FileInfo(executable).isRegular()) {
        throw Exception(
            "unable to start cjpm: executable is missing or not a regular file. Make sure the Cangjie SDK environment is loaded.")
    }
    let root = canonicalize(projectRoot)
    let capture = Directory.createTemp(root)
    let outPath = capture.join("stdout")
    let errPath = capture.join("stderr")
    try {
        let outFile = File.create(outPath)
        try {
            let errFile = File.create(errPath)
            try {
                let code: Int64
                try {
                    code = execute(executable.toString(), ["update"], workingDirectory: Some(root),
                        stdIn: ProcessRedirect.Discard, stdOut: ProcessRedirect.FromFile(outFile),
                        stdErr: ProcessRedirect.FromFile(errFile))
                } catch (error: Exception) {
                    throw Exception(
                        "unable to start or wait for cjpm: ${error.message}. Make sure the Cangjie SDK environment is loaded.")
                }
                outFile.flush();
                errFile.flush()
                return CjpmUpdateResult(code, File.readFrom(outPath), File.readFrom(errPath))
            } finally {
                errFile.close()
            }
        } finally {
            outFile.close()
        }
    } finally {
        // Own files only, no recursive deletion of a directory supplied by a caller.
        if (exists(outPath)) {
            remove(outPath)
        }
        if (exists(errPath)) {
            remove(errPath)
        }
        remove(capture)
    }
}

func processOutputText(bytes: Array<Byte>): String {
    try {
        return String.fromUtf8(bytes)
    } catch (_: Exception) {
        var result = ""
        let hex = "0123456789ABCDEF".toArray()
        for (b in bytes) {
            if (b < 128) {
                result += Rune(UInt32(b)).toString()
            } else {
                result += "\\x" + Rune(UInt32(hex[Int64(b) / 16])).toString() +
                    Rune(UInt32(hex[Int64(b) % 16])).toString()
            }
        }
        return result
    }
}

func printCjpmFailure(result: CjpmUpdateResult): Unit {
    println("Error: cjpm update failed (exit ${result.exitCode}).\nCJPM:")
    for (bytes in [result.stdout, result.stderr]) {
        for (line in processOutputText(bytes).split("\n")) {
            if (!line.isEmpty()) {
                println("  " + displayCell(line.removeSuffix("\r")))
            }
        }
    }
}
