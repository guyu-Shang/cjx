package cjx

import std.fs.Path

// Release version: keep in sync with [package].version; verification checks it.
let CJX_VERSION: String = "0.1.0"

func printHelp(): Unit {
    println("CJX - CJPM eXtension")
    println("Usage: cjx <command> [options]")
    println("")
    println("Commands:")
    println("  list           List project dependencies")
    println("  add <name>     Add a path or Git dependency")
    println("  remove <name>  Remove a project dependency")
    println("  doctor         Diagnose project and SDK environment (read-only)")
    println("")
    println("Options:")
    println("  -h, --help     Show help")
    println("  --version      Show version")
    println("  --dry-run      Preview add/remove without writing")
    println("  --no-update    Write add/remove without running CJPM")
    println("")
    println("Examples:")
    println("  cjx list")
    println("  cjx add cui --path ../CangjieCUI")
    println("  cjx add foo --git https://example.com/foo.git")
    println("  cjx remove cui --dry-run")
    println("  cjx doctor")
    println("")
    println("Add/remove run cjpm update by default. See README for Git selectors.")
}

func listProjectDependencies(manifest: Path): Int64 {
    let text: String
    try {
        text = readCjpmToml(manifest)
    } catch (error: Exception) {
        println("Error: failed to read cjpm.toml: ${error.message}")
        return 1
    }
    try {
        // Finish the entire scan before showing any entries: no partial success.
        print(formatDependencyList(scanDependencies(text)))
        return 0
    } catch (error: Exception) {
        println("Error: ${error.message}")
        return 1
    }
}

func addDependency(args: Array<String>): Int64 {
    let options: (AddRequest, Bool, Bool)
    try {
        options = parseAddCommand(args)
    } catch (error: Exception) {
        println("Error: ${error.message}");
        return 2
    }
    let (request, dryRun, noUpdate) = options
    try {
        match (findCjpmToml()) {
            case Some(manifest) => return addProjectDependency(manifest, request, dryRun, noUpdate: noUpdate)
            case None => throw Exception("cjpm.toml was not found in the current directory or any parent directory.")
        }
    } catch (error: Exception) {
        println("Error: ${displayCell(error.message)}");
        return 1
    }
}

// The injectable writer is an internal test seam, never a command-line option.
func addProjectDependency(manifest: Path, request: AddRequest, dryRun: Bool, noUpdate!: Bool = false,
    writer!: (Path, Array<Byte>, Array<Byte>, (Array<Byte>) -> Unit) -> SafeWriteResult = writeDependencyBytes,
    updater!: (Path) -> CjpmUpdateResult = runCjpmUpdate, rollbackHook!: (String, Path) -> Unit = {_, _ =>}): Int64 {
    let original: String
    try {
        original = readCjpmToml(manifest)
    } catch (error: Exception) {
        println("Error: failed to read cjpm.toml: ${displayCell(error.message)}");
        return 1
    }
    let plan: AddPlan
    try {
        plan = planAdd(original, request)
    } catch (error: Exception) {
        println("Error: ${displayCell(error.message)}");
        return 1
    }
    return commitDependencyChange(manifest, original, plan.modifiedText, plan.declaration, "add", dryRun, noUpdate,
        {text => validateAddResult(original, text, request)}, writer, updater, rollbackHook)
}

// Shared by add/remove; operation controls messages only, not safety rules.
private func commitDependencyChange(manifest: Path, original: String, modified: String, declaration: String,
    operation: String, dryRun: Bool, noUpdate: Bool, validate: (String) -> Unit,
    writer: (Path, Array<Byte>, Array<Byte>, (Array<Byte>) -> Unit) -> SafeWriteResult,
    updater: (Path) -> CjpmUpdateResult, rollbackHook: (String, Path) -> Unit): Int64 {
    let verb = if (operation == "add") {
        "Added"
    } else {
        "Removed"
    }
    let past = if (operation == "add") {
        "added"
    } else {
        "removed"
    }
    let preposition = if (operation == "add") {
        "to"
    } else {
        "from"
    }
    if (dryRun) {
        println(
            "Dry run\n\nWould ${operation}:\n\n${declaration}\n\n${preposition}:\n\n${displayCell(manifest.toString())}\n\nNo files were modified.")
        return 0
    }
    let snapshot: AddMetadataSnapshot
    try {
        snapshot = beginAddMetadata(manifest, original.toArray())
    } catch (error: Exception) {
        println("Error: metadata snapshot failed: ${displayCell(error.message)}");
        return 1
    }
    let result: SafeWriteResult
    try {
        result = writer(manifest, original.toArray(), modified.toArray(), {
            bytes => validate(String.fromUtf8(bytes))
        })
    } catch (error: Exception) {
        println("Error: ${displayCell(error.message)}")
        reportAbortedMetadata(snapshot)
        return 1
    }
    // Independent re-read after the transaction returns; do not claim success
    // when another writer has changed the file since its final disk validation.
    try {
        let finalText = readCjpmToml(manifest)
        if (!sameBytes(finalText.toArray(), modified.toArray())) {
            throw Exception("final file differs from the validated ${operation} plan")
        }
        validate(finalText)
    } catch (error: Exception) {
        println("Error: SERIOUS: final ${operation} verification failed: ${displayCell(error.message)}")
        if (!result.warning.isEmpty()) {
            println("Warning: ${displayCell(result.warning)}")
        }
        reportAbortedMetadata(snapshot)
        return 1
    }
    if (!result.warning.isEmpty()) {
        println("Warning: ${displayCell(result.warning)}")
    }
    if (!noUpdate) {
        return updateDependencyChange(snapshot, modified, declaration, verb, validate, updater, rollbackHook)
    }
    println("${verb} dependency:\n\n  ${declaration}\n\nUpdated:\n  ${displayCell(manifest.toString())}")
    println("\nDependency was ${past} ${preposition} cjpm.toml.\nRun `cjpm update` to refresh cjpm.lock.")
    let warning = finishAddMetadata(snapshot)
    if (!warning.isEmpty()) {
        println("Warning: ${displayCell(warning)}")
    }
    return 0
}

private func updateDependencyChange(snapshot: AddMetadataSnapshot, modified: String, declaration: String, verb: String,
    validate: (String) -> Unit, updater: (Path) -> CjpmUpdateResult, rollbackHook: (String, Path) -> Unit): Int64 {
    var updateFailed = false
    var updaterStarted = false
    try {
        if (!sameMetadata(metadataState(snapshot.lockPath), snapshot.lockOriginal)) {
            throw Exception("cjpm.lock changed externally before update. Update was not started.")
        }
        println("Updating dependencies...")
        updaterStarted = true
        let result = updater(snapshot.manifest.parent)
        if (result.exitCode != 0) {
            printCjpmFailure(result);
            updateFailed = true
        } else {
            let finalText = readCjpmToml(snapshot.manifest)
            if (!sameBytes(finalText.toArray(), modified.toArray())) {
                throw Exception("cjpm.toml changed during update.")
            }
            validate(finalText)
            metadataState(snapshot.lockPath) // Validate type and actual disk readability.
        }
    } catch (error: Exception) {
        println("Error: ${displayCell(error.message)}");
        updateFailed = true
    }
    if (updateFailed) {
        let rollback = rollbackAddMetadata(snapshot, modified.toArray(), hook: rollbackHook,
            expectedLock: if (updaterStarted) {
                None
            } else {
                Some(snapshot.lockOriginal)
            })
        if (rollback.restored) {
            println("Project files were restored.")
        } else {
            println("Rollback could not be completed.")
        }
        if (!rollback.detail.isEmpty()) {
            println(displayCell(rollback.detail))
        }
        return 1
    }
    let warning = finishAddMetadata(snapshot)
    println(
        "${verb} dependency successfully.\n\n  ${declaration}\n\nUpdated:\n  ${displayCell(snapshot.manifest.toString())}\n\nDependencies updated successfully.")
    if (!warning.isEmpty()) {
        println("Warning: ${displayCell(warning)}")
    }
    return 0
}

private func writeDependencyBytes(path: Path, original: Array<Byte>, modified: Array<Byte>,
    validate: (Array<Byte>) -> Unit): SafeWriteResult {
    return safeReplaceFile(path, original, modified, validate: validate)
}

func removeDependency(args: Array<String>): Int64 {
    let options: (String, Bool, Bool)
    try {
        options = parseRemoveCommand(args)
    } catch (error: Exception) {
        println("Error: ${displayCell(error.message)}")
        return 2
    }
    let (name, dryRun, noUpdate) = options
    try {
        match (findCjpmToml()) {
            case Some(manifest) => return removeProjectDependency(manifest, name, dryRun, noUpdate: noUpdate)
            case None => throw Exception("cjpm.toml was not found in the current directory or any parent directory.")
        }
    } catch (error: Exception) {
        println("Error: ${displayCell(error.message)}")
        return 1
    }
}

func removeProjectDependency(manifest: Path, name: String, dryRun: Bool, noUpdate!: Bool = false,
    writer!: (Path, Array<Byte>, Array<Byte>, (Array<Byte>) -> Unit) -> SafeWriteResult = writeDependencyBytes,
    updater!: (Path) -> CjpmUpdateResult = runCjpmUpdate, rollbackHook!: (String, Path) -> Unit = {_, _ =>}): Int64 {
    try {
        let original = readCjpmToml(manifest)
        let plan = planRemoveDependency(original, name)
        return commitDependencyChange(manifest, original, plan.modifiedText, plan.declaration, "remove", dryRun,
            noUpdate, {text => validateRemoveResult(original, text, name)}, writer, updater, rollbackHook)
    } catch (error: Exception) {
        println("Error: ${displayCell(error.message)}")
        return 1
    }
}

func runCli(args: Array<String>): Int64 {
    if (args.size == 0) {
        printHelp()
        return 0
    }

    let command = args[0]
    if (command == "add") {
        return addDependency(args[1..])
    }
    if (command == "remove") {
        return removeDependency(args[1..])
    }
    if (command == "doctor") {
        if (args.size != 1) {
            println("Error: doctor does not accept additional arguments.")
            return 2
        }
        return doctorProject()
    }
    if (command == "--help" || command == "-h") {
        if (args.size != 1) {
            println("Error: help does not accept additional arguments.")
            return 2
        }
        printHelp()
        return 0
    }
    if (command == "--version") {
        if (args.size != 1) {
            println("Error: version does not accept additional arguments.")
            return 2
        }
        println("CJX ${CJX_VERSION}")
        return 0
    }

    if (command == "list") {
        try {
            match (findCjpmToml()) {
                case Some(manifest) => return listProjectDependencies(manifest)
                case None =>
                    println("Error: cjpm.toml was not found in the current directory or any parent directory.")
                    return 1
            }
        } catch (error: Exception) {
            println("Error: could not locate the CJPM project: ${error.message}")
            return 1
        }
    }

    println("Error: unknown command '${command}'. Use --help for usage.")
    return 2
}
