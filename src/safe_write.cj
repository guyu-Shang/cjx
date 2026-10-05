package cjx

import std.fs.{Path, File, FileInfo, Directory, canonicalize, exists, rename, remove}

class SafeWriteResult {
    // Returning means commit and final validation succeeded, even if cleanup warned.
    public let warning: String
    init(warning: String) {
        this.warning = warning
    }
}

func sameBytes(a: Array<Byte>, b: Array<Byte>): Bool {
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

private func readRegularBytes(path: Path): Array<Byte> {
    let info = FileInfo(path)
    if (!info.isRegular() || info.isSymbolicLink()) {
        throw Exception("Expected a regular, non-symbolic-link file: ${path}")
    }
    return File.readFrom(path)
}

private func validateConfigBytes(bytes: Array<Byte>): Unit {
    scanDependencies(String.fromUtf8(bytes))
}

private func validateSnapshot(bytes: Array<Byte>, validate: (Array<Byte>) -> Unit, scanConfig: Bool): Unit {
    if (scanConfig) {
        validateConfigBytes(bytes)
    }
    // A caller's validator cannot mutate the transaction's expected byte array.
    validate(Array<Byte>(bytes.size, {i => bytes[i]}))
}

// Raw metadata replacement (cjpm.lock is opaque bytes, not dependencies TOML).
func safeReplaceBytes(path: Path, expected: Array<Byte>, replacement: Array<Byte>): SafeWriteResult {
    return safeReplaceFileForTest(path, expected, replacement, {_ =>}, {_, _ =>}, scanConfig: false)
}

// Generic to the operation: callers may additionally validate add/remove semantics.
// This module has no command-line entry point; add uses it through its validator.
func safeReplaceFile(path: Path, expectedOriginalBytes: Array<Byte>, replacementBytes: Array<Byte>,
    validate!: (Array<Byte>) -> Unit = validateConfigBytes): SafeWriteResult {
    return safeReplaceFileForTest(path, expectedOriginalBytes, replacementBytes, validate, {_, _ =>})
}

// Internal seam: tests fail or alter real disk state at deterministic boundaries.
// Production always supplies the no-op hook above. No hook is exposed via CLI.
func safeReplaceFileForTest(path: Path, originalInput: Array<Byte>, replacementInput: Array<Byte>,
    validate: (Array<Byte>) -> Unit, hook: (String, Path) -> Unit, scanConfig!: Bool = true): SafeWriteResult {
    let original = Array<Byte>(originalInput.size, {i => originalInput[i]})
    let replacement = Array<Byte>(replacementInput.size, {i => replacementInput[i]})
    let parent = canonicalize(if (path.parent.toString().isEmpty()) {
        Path(".")
    } else {
        path.parent
    })
    let target = parent.join(path.fileName)
    let lock = parent.join("." + path.fileName + ".cjx-lock")
    let backup = lock.join("original")
    let rejected = lock.join("rejected")
    validateSnapshot(replacement, validate, scanConfig)
    if (!sameBytes(readRegularBytes(target), original)) {
        throw Exception("cjpm.toml changed since the operation started. No changes were written.")
    }
    // Directory.create is exclusive. Never remove or reuse a pre-existing lock.
    Directory.create(lock)
    var temporary: Option<Path> = None
    var saved = false
    var installed = false
    var failure = ""
    var recovery = ""
    var phase = "temporary file creation"
    try {
        hook("create", target)
        let file = File.createTemp(parent)
        let temp = file.info.path
        temporary = Some(temp)
        var writeFailure = ""
        phase = "temporary file write"
        try {
            hook("write", temp)
            file.write(replacement)
            hook("flush", temp)
            file.flush() // std.fs.File has no userspace buffer; NOT fsync.
        } catch (error: Exception) {
            writeFailure = error.message
        }
        try {
            file.close()
        } catch (error: Exception) {
            writeFailure += " close failed: " + error.message
        }
        if (!writeFailure.isEmpty()) {
            throw Exception(writeFailure)
        }
        hook("closed", temp)
        phase = "temporary file verification"
        let disk = readRegularBytes(temp)
        if (!sameBytes(disk, replacement)) {
            throw Exception("Temporary file byte verification failed.")
        }
        validateSnapshot(disk, validate, scanConfig)
        phase = "original file recheck"
        hook("before-check", target)
        if (!sameBytes(readRegularBytes(target), original)) {
            throw Exception("cjpm.toml changed since the operation started. No changes were written.")
        }
        phase = "saving original file"
        hook("save", target)
        rename(target, to: backup, overwrite: false)
        saved = true
        // Also catch changes between the pre-commit read and the first rename.
        if (!sameBytes(readRegularBytes(backup), original)) {
            throw Exception("cjpm.toml changed during commit; aborting replacement.")
        }
        phase = "commit"
        hook("replace", temp)
        rename(temp, to: target, overwrite: false)
        temporary = None
        installed = true
        phase = "final verification"
        hook("final", target)
        let finalBytes = readRegularBytes(target)
        if (!sameBytes(finalBytes, replacement)) {
            throw Exception("SERIOUS: final file byte verification failed.")
        }
        validateSnapshot(finalBytes, validate, scanConfig)
    } catch (error: Exception) {
        failure = "${phase}: ${error.message}"
        if (installed) {
            failure = "SERIOUS: post-replacement verification failed: " + failure
        }
        if (saved) {
            try {
                hook("restore", backup)
                if (installed && exists(target)) {
                    // Retain the failed/new version rather than deleting possible external edits.
                    readRegularBytes(target)
                    rename(target, to: rejected, overwrite: false)
                    recovery += " Retained rejected file: ${rejected}."
                }
                // Never overwrite a file created by another writer in the rename gap.
                rename(backup, to: target, overwrite: false)
                saved = false
                if (!sameBytes(readRegularBytes(target), original)) {
                    recovery += " Restored file contains an external change; inspect ${target}."
                } else {
                    recovery += " Original bytes restored."
                }
            } catch (restoreError: Exception) {
                recovery += " SERIOUS: recovery failed: ${restoreError.message}. Recovery location: ${backup}; target: ${target}."
            }
        }
    }
    var cleanup = ""
    // Only delete files owned by this transaction; never recursive-delete a directory.
    match (temporary) {
        case Some(temp) => try {
            hook("cleanup-temp", temp);
            remove(temp)
        } catch (error: Exception) {
            cleanup += " Temporary file retained at ${temp}: ${error.message}."
        }
        case None => ()
    }
    if (failure.isEmpty() && saved) {
        try {
            hook("cleanup-backup", backup);
            remove(backup);
            saved = false
        } catch (error: Exception) {
            cleanup += " Backup retained at ${backup}: ${error.message}."
        }
    }
    if (!saved && !exists(rejected)) {
        try {
            hook("cleanup-lock", lock);
            remove(lock)
        } catch (error: Exception) {
            cleanup += " Lock retained at ${lock}: ${error.message}."
        }
    }
    if (!failure.isEmpty()) {
        throw Exception("Safe write failed: ${failure}${recovery}${cleanup}")
    }
    return SafeWriteResult(cleanup)
}
