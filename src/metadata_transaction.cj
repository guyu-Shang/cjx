package cjx

import std.fs.{Path, File, FileInfo, Directory, exists, canonicalize, rename, remove}

class MetadataFileState {
    public let present: Bool
    public let bytes: Array<Byte>
    init(present: Bool, bytes: Array<Byte>) {
        this.present = present
        this.bytes = bytes
    }
}

func metadataState(path: Path): MetadataFileState {
    if (!exists(path)) {
        return MetadataFileState(false, Array<Byte>())
    }
    let info = FileInfo(path)
    if (!info.isRegular() || info.isSymbolicLink()) {
        throw Exception("Expected regular metadata file: ${path}")
    }
    return MetadataFileState(true, File.readFrom(path))
}

func sameMetadata(a: MetadataFileState, b: MetadataFileState): Bool {
    return a.present == b.present && sameBytes(a.bytes, b.bytes)
}

class AddMetadataSnapshot {
    public let manifest: Path
    public let directory: Path
    public let original: Array<Byte>
    public let lockOriginal: MetadataFileState
    init(manifest: Path, directory: Path, original: Array<Byte>, lockOriginal: MetadataFileState) {
        this.manifest = manifest
        this.directory = directory
        this.original = original
        this.lockOriginal = lockOriginal
    }
    public prop lockPath: Path {
        get() {
            return manifest.parent.join("cjpm.lock")
        }
    }
}

private func writeNewSnapshot(path: Path, bytes: Array<Byte>): Unit {
    let file = File.create(path)
    try {
        file.write(bytes);
        file.flush()
    } finally {
        file.close()
    }
    if (!sameBytes(File.readFrom(path), bytes)) {
        throw Exception("Metadata snapshot verification failed: ${path}")
    }
}

func beginAddMetadata(manifest: Path, original: Array<Byte>): AddMetadataSnapshot {
    let target = canonicalize(manifest.parent).join(manifest.fileName)
    let directory = target.parent.join(".cjpm.toml.cjx-add")
    Directory.create(directory) // A project-level lock held until update/rollback finishes.
    try {
        let current = metadataState(target)
        if (!current.present || !sameBytes(current.bytes, original)) {
            throw Exception("cjpm.toml changed before the operation started.")
        }
        let lock = metadataState(target.parent.join("cjpm.lock"))
        writeNewSnapshot(directory.join("cjpm.toml.original"), original)
        writeNewSnapshot(directory.join("lock-state"), (if (lock.present) {
            "present"
        } else {
            "absent"
        }).toArray())
        if (lock.present) {
            writeNewSnapshot(directory.join("cjpm.lock.original"), lock.bytes)
        }
        return AddMetadataSnapshot(target, directory, original, lock)
    } catch (error: Exception) {
        // Original project metadata has not been modified at this point.
        var cleanup = ""
        for (name in ["cjpm.toml.original", "lock-state", "cjpm.lock.original"]) {
            let p = directory.join(name)
            try {
                if (exists(p)) {
                    remove(p)
                }
            } catch (e: Exception) {
                cleanup += " ${e.message}"
            }
        }
        try {
            remove(directory)
        } catch (e: Exception) {
            cleanup += " Snapshot directory retained: ${directory}: ${e.message}"
        }
        throw Exception(error.message + cleanup)
    }
}

func finishAddMetadata(snapshot: AddMetadataSnapshot): String {
    var warning = ""
    for (name in ["cjpm.toml.original", "lock-state", "cjpm.lock.original"]) {
        let p = snapshot.directory.join(name)
        try {
            if (exists(p)) {
                remove(p)
            }
        } catch (e: Exception) {
            warning += " ${p}: ${e.message}."
        }
    }
    try {
        remove(snapshot.directory)
    } catch (e: Exception) {
        warning += " Operation directory retained: ${snapshot.directory}: ${e.message}."
    }
    return warning
}

func reportAbortedMetadata(snapshot: AddMetadataSnapshot): Unit {
    try {
        if (sameMetadata(metadataState(snapshot.manifest), MetadataFileState(true, snapshot.original)) && sameMetadata(
            metadataState(snapshot.lockPath), snapshot.lockOriginal)) {
            let warning = finishAddMetadata(snapshot)
            if (!warning.isEmpty()) {
                println("Warning: ${displayCell(warning)}")
            }
            return
        }
    } catch (_: Exception) {}
    println("Original metadata snapshots retained at ${displayCell(snapshot.directory.toString())}.")
}

// Restore presence as well as bytes. Creation/deletion use no-overwrite staging;
// replacements reuse the exact same transactional engine as manifest writes.
func restoreMetadataFile(path: Path, observed: MetadataFileState, original: MetadataFileState): String {
    if (!sameMetadata(metadataState(path), observed)) {
        throw Exception("${path.fileName} changed externally.")
    }
    if (sameMetadata(observed, original)) {
        return ""
    }
    if (observed.present && original.present) {
        return safeReplaceBytes(path, observed.bytes, original.bytes).warning
    }
    let guard = path.parent.join("." + path.fileName + ".cjx-lock")
    Directory.create(guard)
    var temporary: Option<Path> = None
    var saved = false
    let removed = guard.join("removed")
    try {
        if (original.present) {
            let file = File.createTemp(path.parent)
            let temp = file.info.path
            temporary = Some(temp)
            try {
                file.write(original.bytes);
                file.flush()
            } finally {
                file.close()
            }
            if (!sameBytes(File.readFrom(temp), original.bytes)) {
                throw Exception("Restored lock temporary bytes mismatch.")
            }
            if (metadataState(path).present) {
                throw Exception("cjpm.lock changed externally.")
            }
            rename(temp, to: path, overwrite: false)
            temporary = None
        } else {
            if (!sameMetadata(metadataState(path), observed)) {
                throw Exception("cjpm.lock changed externally.")
            }
            rename(path, to: removed, overwrite: false)
            saved = true
            if (!sameBytes(File.readFrom(removed), observed.bytes)) {
                rename(removed, to: path, overwrite: false);
                saved = false
                throw Exception("cjpm.lock changed during rollback deletion.")
            }
            remove(removed);
            saved = false
        }
        if (!sameMetadata(metadataState(path), original)) {
            throw Exception("Lock rollback final state mismatch.")
        }
    } catch (error: Exception) {
        var recovery = ""
        if (saved) {
            try {
                rename(removed, to: path, overwrite: false);
                saved = false
            } catch (e: Exception) {
                recovery += " Recovery file: ${removed}: ${e.message}."
            }
        }
        match (temporary) {
            case Some(p) => try {
                remove(p)
            } catch (e: Exception) {
                recovery += " Retained ${p}: ${e.message}."
            };
            case None => ()
        }
        if (!saved) {
            try {
                remove(guard)
            } catch (e: Exception) {
                recovery += " ${guard}: ${e.message}."
            }
        }
        throw Exception(error.message + recovery)
    }
    try {
        remove(guard);
        return ""
    } catch (e: Exception) {
        return " Lock cleanup failed: ${guard}: ${e.message}."
    }
}

class MetadataRollbackResult {
    public let restored: Bool
    public let detail: String
    init(restored: Bool, detail: String) {
        this.restored = restored
        this.detail = detail
    }
}

func rollbackAddMetadata(snapshot: AddMetadataSnapshot, committed: Array<Byte>,
    hook!: (String, Path) -> Unit = {_, _ =>}, expectedLock!: Option<MetadataFileState> = None): MetadataRollbackResult {
    var detail = ""
    var restored = true
    var observedLock: Option<MetadataFileState> = None
    try {
        observedLock = match (expectedLock) {
            case Some(state) => Some(state);
            case None => Some(metadataState(snapshot.lockPath))
        }
    } catch (e: Exception) {
        restored = false
        detail += " Cannot inspect cjpm.lock: ${e.message}."
    }
    try {
        hook("toml", snapshot.manifest)
        let current = metadataState(snapshot.manifest)
        if (!current.present || !sameBytes(current.bytes, committed)) {
            throw Exception("Rollback could not be completed because cjpm.toml changed externally.")
        }
        let result = safeReplaceFile(snapshot.manifest, committed, snapshot.original)
        detail += result.warning
    } catch (e: Exception) {
        restored = false
        detail += " ${e.message}"
    }
    match (observedLock) {
        case Some(observed) => try {
            hook("lock", snapshot.lockPath)
            detail += restoreMetadataFile(snapshot.lockPath, observed, snapshot.lockOriginal)
        } catch (e: Exception) {
            restored = false
            detail += " Lock rollback could not be completed: ${e.message}"
        }
        case None => ()
    }
    // Re-read both metadata files: successful operations are not assumed sufficient.
    try {
        if (!sameMetadata(metadataState(snapshot.manifest), MetadataFileState(true, snapshot.original)) ||
            !sameMetadata(metadataState(snapshot.lockPath), snapshot.lockOriginal)) {
            restored = false
        }
    } catch (e: Exception) {
        restored = false
        detail += " Final rollback verification: ${e.message}"
    }
    if (restored) {
        detail += finishAddMetadata(snapshot)
    } else {
        detail += " Original metadata snapshots retained at ${snapshot.directory}."
    }
    return MetadataRollbackResult(restored, detail)
}
