param([switch]$ReadOnly)
$ErrorActionPreference = 'Stop'
$cjxRoot = Split-Path -Parent $PSScriptRoot
$cjxTemp = Join-Path ([IO.Path]::GetTempPath()) ('cjx-scanner-tests-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $cjxTemp | Out-Null
    Copy-Item -LiteralPath (Join-Path $cjxRoot 'src\dependencies.cj') -Destination $cjxTemp
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dependencies_tests.cj') -Destination $cjxTemp
    $cjxExe = Join-Path $cjxTemp 'scanner-tests.exe'
    & cjc -p $cjxTemp --output-dir $cjxTemp -o scanner-tests.exe
    if ($LASTEXITCODE -ne 0) { throw 'Scanner test compilation failed' }
    & $cjxExe
    if ($LASTEXITCODE -ne 0) { throw 'Scanner tests failed' }
    Remove-Item -LiteralPath (Join-Path $cjxTemp 'dependencies_tests.cj')
    Copy-Item -LiteralPath (Join-Path $cjxRoot 'src\dependency_value.cj') -Destination $cjxTemp
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dependency_value_tests.cj') -Destination $cjxTemp
    & cjc -p $cjxTemp --output-dir $cjxTemp -o value-tests.exe
    if ($LASTEXITCODE -ne 0) { throw 'Value/list test compilation failed' }
    & (Join-Path $cjxTemp 'value-tests.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Value/list tests failed' }
    Remove-Item -LiteralPath (Join-Path $cjxTemp 'dependency_value_tests.cj')
    foreach ($file in @('add_request.cj', 'add_plan.cj')) {
        Copy-Item -LiteralPath (Join-Path $cjxRoot ('src\' + $file)) -Destination $cjxTemp
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'add_plan_tests.cj') -Destination $cjxTemp
    & cjc -p $cjxTemp --output-dir $cjxTemp -o add-tests.exe
    if ($LASTEXITCODE -ne 0) { throw 'Add planner test compilation failed' }
    & (Join-Path $cjxTemp 'add-tests.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Add planner tests failed' }
    Remove-Item -LiteralPath (Join-Path $cjxTemp 'add_plan_tests.cj')
    Copy-Item -LiteralPath (Join-Path $cjxRoot 'src\remove_plan.cj') -Destination $cjxTemp
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'remove_plan_tests.cj') -Destination $cjxTemp
    & cjc -p $cjxTemp --output-dir $cjxTemp -o remove-tests.exe
    if ($LASTEXITCODE -ne 0) { throw 'Remove planner test compilation failed' }
    & (Join-Path $cjxTemp 'remove-tests.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Remove planner tests failed' }
    Remove-Item -LiteralPath (Join-Path $cjxTemp 'remove_plan_tests.cj')
    if ($ReadOnly) { return }
    Copy-Item -LiteralPath (Join-Path $cjxRoot 'src\safe_write.cj') -Destination $cjxTemp
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'safe_write_tests.cj') -Destination $cjxTemp
    & cjc -p $cjxTemp --output-dir $cjxTemp -o write-tests.exe
    if ($LASTEXITCODE -ne 0) { throw 'Safe-write test compilation failed' }
    Push-Location $cjxTemp
    try {
        & (Join-Path $cjxTemp 'write-tests.exe')
        if ($LASTEXITCODE -ne 0) { throw 'Safe-write tests failed' }
    } finally { Pop-Location }
    Remove-Item -LiteralPath (Join-Path $cjxTemp 'safe_write_tests.cj')
    foreach ($file in @('cli.cj', 'config.cj', 'project.cj', 'cjpm_runner.cj', 'metadata_transaction.cj', 'doctor.cj')) {
        Copy-Item -LiteralPath (Join-Path $cjxRoot ('src\' + $file)) -Destination $cjxTemp
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'add_cli_failure_tests.cj') -Destination $cjxTemp
    & cjc -p $cjxTemp --output-dir $cjxTemp -o cli-failure-tests.exe
    if ($LASTEXITCODE -ne 0) { throw 'Add CLI failure test compilation failed' }
    Push-Location $cjxTemp
    try {
        $cjxFailureOutput = & (Join-Path $cjxTemp 'cli-failure-tests.exe')
        if ($LASTEXITCODE -ne 0) { throw "Add CLI failure tests failed: $cjxFailureOutput" }
        $cjxFailureOutput
        # A post-commit failure must never print a success message in its case.
        $cjxInFinalFailure = $false
        foreach ($line in $cjxFailureOutput) {
            if ($line -like 'BEGIN 04*' -or $line -like 'BEGIN 09*') { $cjxInFinalFailure = $true }
            if ($cjxInFinalFailure -and $line -eq 'Added dependency:') { throw 'Final failure printed success' }
            if ($line -like 'PASS 04*' -or $line -like 'PASS 09*') { $cjxInFinalFailure = $false }
        }
        if (!($cjxFailureOutput -match 'Recovery location:') -or !($cjxFailureOutput -match '^Warning:.*Backup retained')) {
            throw 'Recovery path or committed cleanup warning missing from CLI output'
        }
    } finally { Pop-Location }
    Remove-Item -LiteralPath (Join-Path $cjxTemp 'add_cli_failure_tests.cj')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'update_tests.cj') -Destination $cjxTemp
    & cjc (Join-Path $PSScriptRoot 'update_child.cj') --output-dir $cjxTemp -o fake-cjpm.exe
    if ($LASTEXITCODE -ne 0) { throw 'Update output fixture compilation failed' }
    & cjc -p $cjxTemp --output-dir $cjxTemp -o update-tests.exe
    if ($LASTEXITCODE -ne 0) { throw 'Update transaction tests compilation failed' }
    Push-Location $cjxTemp
    try {
        & (Join-Path $cjxTemp 'update-tests.exe')
        if ($LASTEXITCODE -ne 0) { throw 'Update transaction tests failed' }
    } finally { Pop-Location }
    Remove-Item -LiteralPath (Join-Path $cjxTemp 'update_tests.cj')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'remove_transaction_tests.cj') -Destination $cjxTemp
    & cjc -p $cjxTemp --output-dir $cjxTemp -o remove-transaction-tests.exe
    if ($LASTEXITCODE -ne 0) { throw 'Remove transaction compilation failed' }
    Push-Location $cjxTemp
    try {
        $cjxRemoveOutput = @(& (Join-Path $cjxTemp 'remove-transaction-tests.exe'))
        if ($LASTEXITCODE -ne 0) { throw "Remove transaction tests failed: $cjxRemoveOutput" }
        $cjxRemoveOutput
        $cjxFailedCase = $false
        foreach ($line in $cjxRemoveOutput) {
            if ($line -match '^BEGIN (0[5-9]|1[0-8]|20) ') { $cjxFailedCase = $true }
            if ($cjxFailedCase -and $line -eq 'Removed dependency successfully.') { throw 'Failed remove claimed success' }
            if ($line -match '^PASS ') { $cjxFailedCase = $false }
        }
        if (!($cjxRemoveOutput -match 'snapshots retained') -or !($cjxRemoveOutput -match 'Project files were restored')) { throw 'Missing recovery output' }
    } finally { Pop-Location }
} finally {
    $cjxResolved = [IO.Path]::GetFullPath($cjxTemp)
    $cjxAllowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\cjx-scanner-tests-'
    if (!$cjxResolved.StartsWith($cjxAllowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path' }
    if (Test-Path -LiteralPath $cjxResolved) { Remove-Item -LiteralPath $cjxResolved -Recurse -Force }
}
