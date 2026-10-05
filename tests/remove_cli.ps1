param([string]$PracticeRoot = '')
$ErrorActionPreference = 'Stop'
$cjxRoot = Split-Path -Parent $PSScriptRoot
$cjxBinary = Join-Path $cjxRoot 'target\release\bin\main.exe'
$cjxTemp = Join-Path ([IO.Path]::GetTempPath()) ('cjx-remove-cli-' + [Guid]::NewGuid().ToString('N'))
$cjxUtf8 = [Text.UTF8Encoding]::new($false)
$script:cjxPassed = 0
function Assert-Remove($condition, $message) { if (!$condition) { throw $message } }
function Get-RemoveState($directory) {
    $state = @(Get-ChildItem -LiteralPath $directory -Force -Recurse | Sort-Object FullName | ForEach-Object {
        if ($_.PSIsContainer) { 'directory:' + $_.FullName }
        else { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    return $state -join "`n"
}
function Invoke-Remove($directory, [string[]]$arguments) {
    if ($arguments[0] -eq 'remove' -and $arguments.Count -eq 2) { $arguments += '--dry-run' }
    $before = Get-RemoveState $directory
    Push-Location $directory
    try {
        $output = @(& $cjxBinary @arguments)
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    Assert-Remove ((Get-RemoveState $directory) -ceq $before) 'Dry-run modified files or directories'
    return [pscustomobject]@{ Code = $code; Text = ($output -join "`n"); Lines = $output }
}
function Test-Remove($name, [scriptblock]$body) {
    $directory = Join-Path $cjxTemp ('case-' + ($script:cjxPassed + 1))
    New-Item -ItemType Directory -Path $directory | Out-Null
    & $body $directory
    $script:cjxPassed++
    Write-Output "PASS $name"
}
function Write-RemoveFixture($directory, [string]$text, [bool]$withLock = $false) {
    $resolved = [IO.Path]::GetFullPath($directory)
    Assert-Remove ($resolved.StartsWith($cjxTemp + '\', [StringComparison]::OrdinalIgnoreCase)) 'Unsafe fixture write path'
    [IO.File]::WriteAllBytes((Join-Path $directory 'cjpm.toml'), $cjxUtf8.GetBytes($text))
    if ($withLock) { [IO.File]::WriteAllBytes((Join-Path $directory 'cjpm.lock'), [byte[]]@(0, 255, 13, 10)) }
}
try {
    New-Item -ItemType Directory -Path $cjxTemp | Out-Null
    Test-Remove '01 explicit dry-run TOML + lock SHA unchanged' { param($d)
        Write-RemoveFixture $d "[dependencies]`nfoo={path='../foo'} # note`n" $true
        $r = Invoke-Remove $d @('remove','foo')
        Assert-Remove ($r.Code -eq 0 -and $r.Text.Contains("foo={path='../foo'} # note") -and $r.Lines -contains 'Dry run' -and $r.Lines -contains 'No files were modified.') 'Preview failed'
    }
    Test-Remove '02 no lock created, BOM CRLF Chinese retained' { param($d)
        Write-RemoveFixture $d ([char]0xFEFF + "[dependencies]`r`n# 中文说明`r`nfoo={path='../中文'} # 注释`r`n")
        $r = Invoke-Remove $d @('remove','foo')
        Assert-Remove ($r.Code -eq 0 -and $r.Text.Contains('../中文')) 'Unicode preview failed'
    }
    Test-Remove '03 quoted key decoded' { param($d)
        Write-RemoveFixture $d "[dependencies]`n'org::foo'='1.0'"
        $r = Invoke-Remove $d @('remove','org::foo')
        Assert-Remove ($r.Code -eq 0 -and $r.Text.Contains("'org::foo'='1.0'")) 'Quoted key failed'
    }
    Test-Remove '04 missing dependency nonzero' { param($d)
        Write-RemoveFixture $d "[dependencies]`nfoo='1'`n"
        $r = Invoke-Remove $d @('remove','bar')
        Assert-Remove ($r.Code -eq 1 -and $r.Text.Contains("dependency 'bar' was not found.")) 'Missing dependency failure'
    }
    Test-Remove '05 malformed refuses planning' { param($d)
        Write-RemoveFixture $d "[dependencies]`nfoo='broken"
        $r = Invoke-Remove $d @('remove','foo')
        Assert-Remove ($r.Code -eq 1 -and $r.Text.Contains('malformed') -and !$r.Text.Contains('Would remove:')) 'Malformed accepted'
    }
    Test-Remove '06 argument errors and no write switches' { param($d)
        Write-RemoveFixture $d "[dependencies]`nfoo='1'`n"
        foreach ($arguments in @(@('remove'), @('remove','foo','bar'), @('remove','foo','--force'), @('remove','foo','--apply'), @('remove','foo','--yes'), @('remove','foo','--dry-run','--dry-run'))) {
            $r = Invoke-Remove $d $arguments
            Assert-Remove ($r.Code -eq 2 -and !$r.Text.Contains('Would remove:')) 'Argument error expected'
        }
    }
    Test-Remove '07 nested working directory' { param($d)
        Write-RemoveFixture $d "[dependencies]`nfoo='1'`n"
        $sub = Join-Path $d 'src\utils'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        $before = Get-RemoveState $d
        $r = Invoke-Remove $sub @('remove','foo')
        Assert-Remove ($r.Code -eq 0 -and $r.Text.Contains((Join-Path $d 'cjpm.toml')) -and (Get-RemoveState $d) -ceq $before) 'Project discovery or hash mismatch'
    }
    Test-Remove '08 help and Git preview without resolution' { param($d)
        Write-RemoveFixture $d "[dependencies]`nfoo={git='https://invalid.example/foo'}`n"
        $r = Invoke-Remove $d @('remove','foo')
        Assert-Remove ($r.Code -eq 0 -and !$r.Text.Contains('Updating dependencies')) 'Unexpected runner invocation'
        $help = Invoke-Remove $d @('--help')
        Assert-Remove ($help.Code -eq 0 -and $help.Text.Contains('Remove a project dependency')) 'Help mismatch'
    }
    Write-Output "Remove CLI tests: $script:cjxPassed passed"
} finally {
    $cjxResolved = [IO.Path]::GetFullPath($cjxTemp)
    $cjxAllowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\cjx-remove-cli-'
    if (!$cjxResolved.StartsWith($cjxAllowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path' }
    if (Test-Path -LiteralPath $cjxResolved) { Remove-Item -LiteralPath $cjxResolved -Recurse -Force }
}
# Real project: read-only invocation and TOML/lock SHA-256 comparison.
if (!$PracticeRoot) { Write-Output 'SKIP optional practice remove dry-run (use -PracticeRoot to enable)'; return }
$cjxPractice = $PracticeRoot
$cjxProtected = @((Join-Path $cjxRoot 'cjpm.toml'), (Join-Path $cjxRoot 'cjpm.lock'), (Join-Path $cjxPractice 'cjpm.toml'), (Join-Path $cjxPractice 'cjpm.lock'))
$cjxBefore = @($cjxProtected | ForEach-Object { if (Test-Path -LiteralPath $_) { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash } else { 'absent' } })
Push-Location $cjxPractice
try {
    $cjxLines = @(& $cjxBinary remove cui --dry-run)
    $cjxResult = [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($cjxLines -join "`n"); Lines = $cjxLines }
} finally { Pop-Location }
Assert-Remove ($cjxResult.Code -eq 0 -and $cjxResult.Text.Contains('cui') -and $cjxResult.Text.Contains('../CangjieCUI')) 'Practice dry-run failed'
$cjxResult.Lines
for ($i = 0; $i -lt $cjxProtected.Count; $i++) {
    $hash = if (Test-Path -LiteralPath $cjxProtected[$i]) { (Get-FileHash -LiteralPath $cjxProtected[$i] -Algorithm SHA256).Hash } else { 'absent' }
    Assert-Remove ($hash -ceq $cjxBefore[$i]) "Protected file changed: $($cjxProtected[$i])"
    Write-Output "PASS SHA-256 unchanged: $($cjxProtected[$i]) = $hash"
}
