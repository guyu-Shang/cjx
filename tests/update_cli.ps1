$ErrorActionPreference = 'Stop'
$cjxRoot = Split-Path -Parent $PSScriptRoot
$cjxExe = Join-Path $cjxRoot 'target\release\bin\main.exe'
$cjxTemp = Join-Path ([IO.Path]::GetTempPath()) ('cjx-update-cli-' + [Guid]::NewGuid().ToString('N'))
$script:cjxPassed = 0
function Assert-Update($condition, $message) { if (!$condition) { throw $message } }
function Invoke-UpdateCli($directory, [string[]]$arguments) {
    Push-Location $directory
    try {
        $lines = @(& $cjxExe @arguments)
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($lines -join "`n"); Lines = $lines }
    } finally { Pop-Location }
}
function Metadata-Hash($directory) {
    $lock = Join-Path $directory 'cjpm.lock'
    return @((Get-FileHash (Join-Path $directory 'cjpm.toml')).Hash,
        $(if (Test-Path -LiteralPath $lock) { (Get-FileHash -LiteralPath $lock).Hash } else { 'absent' }))
}
function Assert-NoArtifacts($directory) {
    Assert-Update (@(Get-ChildItem -LiteralPath $directory -Force | Where-Object { $_.Name -like '*cjx-*' -or $_.Name -like 'tmpDir*' -or $_.Name -like 'tmpFile*' }).Count -eq 0) 'Transaction/capture artifacts remain'
}
function Seed-Lock($directory) {
    Push-Location $directory
    try { cjpm update | Out-Null; Assert-Update ($LASTEXITCODE -eq 0) 'Seed update failed' }
    finally { Pop-Location }
}
function Test-Update($name, [scriptblock]$body) {
    $case = Join-Path $cjxTemp ('case-' + ($script:cjxPassed + 1))
    foreach ($project in @('app','foo','bar')) {
        $path = Join-Path $case $project
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Push-Location $path
        try {
            cjpm init --name $project --type static | Out-Null
            Assert-Update ($LASTEXITCODE -eq 0) 'Project init failed'
        } finally { Pop-Location }
    }
    $app = Join-Path $case 'app'
    & $body $app
    Assert-NoArtifacts $app
    $script:cjxPassed++
    Write-Output "PASS $name"
}
try {
    New-Item -ItemType Directory $cjxTemp | Out-Null
    Test-Update '01 real Path add automatically generates lock' { param($app)
        $r = Invoke-UpdateCli $app @('add','foo','--path','../foo')
        Assert-Update ($r.Code -eq 0 -and $r.Text.Contains('Added dependency successfully.')) $r.Text
        Assert-Update (Test-Path -LiteralPath (Join-Path $app 'cjpm.lock')) 'No lock generated'
        $r.Lines
        $list = Invoke-UpdateCli $app @('list')
        Assert-Update ($list.Code -eq 0 -and $list.Text -match 'foo\s+path\s+../foo') 'List after update'
        $list.Lines
        Get-Content -LiteralPath (Join-Path $app 'cjpm.lock')
    }
    Test-Update '02 real update with pre-existing lock' { param($app)
        Seed-Lock $app
        $lock = Join-Path $app 'cjpm.lock'
        [IO.File]::AppendAllText($lock, "`n# original lock annotation`n")
        $before = (Get-FileHash -LiteralPath $lock).Hash
        $r = Invoke-UpdateCli $app @('add','foo','--path','../foo')
        Assert-Update ($r.Code -eq 0) $r.Text
        Assert-Update ((Get-FileHash -LiteralPath $lock).Hash -ne $before) 'CJPM did not refresh annotated lock'
    }
    Test-Update '03 consecutive legal Path add and update' { param($app)
        foreach ($name in @('foo','bar')) {
            $r = Invoke-UpdateCli $app @('add',$name,'--path',('../' + $name))
            Assert-Update ($r.Code -eq 0) $r.Text
        }
        $list = Invoke-UpdateCli $app @('list')
        Assert-Update ($list.Text.Contains('2 dependencies') -and $list.Text -match 'bar\s+path\s+../bar') 'Consecutive additions lost'
    }
    Test-Update '04 no-update writes TOML and preserves existing lock' { param($app)
        Seed-Lock $app
        $before = Metadata-Hash $app
        $r = Invoke-UpdateCli $app @('add','missing','--path','../missing','--no-update')
        $after = Metadata-Hash $app
        Assert-Update ($r.Code -eq 0 -and !$r.Text.Contains('Updating dependencies...')) $r.Text
        Assert-Update ($before[0] -ne $after[0] -and $before[1] -eq $after[1]) 'no-update metadata state'
        Assert-Update ($r.Text.Contains('Dependency was added to cjpm.toml.')) 'no-update message'
    }
    Test-Update '05 dry-run plus no-update is fully read-only' { param($app)
        Seed-Lock $app
        $before = Metadata-Hash $app
        $r = Invoke-UpdateCli $app @('add','missing','--path','../missing','--no-update','--dry-run')
        $after = Metadata-Hash $app
        Assert-Update ($r.Code -eq 0 -and !$r.Text.Contains('Updating dependencies...')) $r.Text
        Assert-Update ($before[0] -eq $after[0] -and $before[1] -eq $after[1]) 'dry-run modified metadata'
    }
    Test-Update '06 real update failure restores TOML and absent lock' { param($app)
        $before = Metadata-Hash $app
        $r = Invoke-UpdateCli $app @('add','missing','--path','../missing')
        $after = Metadata-Hash $app
        Assert-Update ($r.Code -eq 1 -and $r.Text.Contains('cjpm update failed') -and $r.Text.Contains('Project files were restored.')) $r.Text
        Assert-Update (!$r.Text.Contains('Added dependency successfully.')) 'Failure printed success'
        Assert-Update ($before[0] -eq $after[0] -and $after[1] -eq 'absent') 'Failure metadata not restored'
        $r.Lines
    }
    Test-Update '07 real update failure restores existing lock bytes' { param($app)
        Seed-Lock $app
        $before = Metadata-Hash $app
        $r = Invoke-UpdateCli $app @('add','missing','--path','../missing')
        $after = Metadata-Hash $app
        Assert-Update ($r.Code -eq 1 -and $r.Text.Contains('Project files were restored.')) $r.Text
        Assert-Update ($before[0] -eq $after[0] -and $before[1] -eq $after[1]) 'Existing metadata not restored'
    }
    Test-Update '08 no-update never creates absent lock' { param($app)
        $r = Invoke-UpdateCli $app @('add','foo','--path','../foo','--no-update')
        Assert-Update ($r.Code -eq 0 -and !(Test-Path -LiteralPath (Join-Path $app 'cjpm.lock'))) $r.Text
    }
    Test-Update '09 update runs at project root from src subdirectory' { param($app)
        $r = Invoke-UpdateCli (Join-Path $app 'src') @('add','foo','--path','../foo')
        Assert-Update ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $app 'cjpm.lock'))) $r.Text
        Assert-Update (!(Test-Path -LiteralPath (Join-Path $app 'src\cjpm.lock'))) 'Update ran in src'
    }
    Write-Output "$script:cjxPassed real update integration tests passed; 0 failed"
} finally {
    $resolved = [IO.Path]::GetFullPath($cjxTemp)
    $allowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\cjx-update-cli-'
    if (!$resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe update test cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
