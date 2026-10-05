param([string]$PracticeRoot = '')
$ErrorActionPreference = 'Stop'
$cjxRoot = Split-Path -Parent $PSScriptRoot
$cjxBinary = Join-Path $cjxRoot 'target\release\bin\main.exe'
# These are read-only integration tests. No fixture, backup or manifest writes.
$realProjects = @($cjxRoot)
if ($PracticeRoot) { $realProjects += $PracticeRoot }
foreach ($directory in $realProjects) {
    $manifest = Join-Path $directory 'cjpm.toml'
    $before = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
    $lockPath = Join-Path $directory 'cjpm.lock'
    $lockBefore = if (Test-Path -LiteralPath $lockPath) { (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash } else { 'absent' }
    Push-Location $directory
    try {
        $output = & $cjxBinary add testdep --path ../test --dry-run
        $exitCode = $LASTEXITCODE
    } finally { Pop-Location }
    $after = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
    if ($before -ne $after) { throw "Manifest changed: $manifest" }
    $lockAfter = if (Test-Path -LiteralPath $lockPath) { (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash } else { 'absent' }
    if ($lockBefore -ne $lockAfter) { throw "Lock state changed: $lockPath" }
    if ($exitCode -ne 0 -or !($output -contains 'Dry run') -or !($output -contains 'No files were modified.')) {
        throw "Dry run failed: $output"
    }
    $output
    Write-Output "PASS SHA-256 unchanged: $manifest = $after"
    Write-Output "PASS lock state unchanged: $lockPath = $lockAfter"
}
foreach ($arguments in @(@('add'), @('add','foo'), @('add','foo','--path'), @('add','foo','--apply'))) {
    $output = & $cjxBinary @arguments
    if ($LASTEXITCODE -ne 2) { throw "Expected argument error: $arguments" }
}
Write-Output 'PASS CLI missing/forbidden argument exit codes'
