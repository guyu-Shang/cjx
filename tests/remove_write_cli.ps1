$ErrorActionPreference = 'Stop'
$cjxRoot = Split-Path -Parent $PSScriptRoot
$cjxExe = Join-Path $cjxRoot 'target\release\bin\main.exe'
$cjxTemp = Join-Path ([IO.Path]::GetTempPath()) ('cjx-remove-write-' + [Guid]::NewGuid().ToString('N'))
$cjxUtf8 = [Text.UTF8Encoding]::new($false)
$script:cjxPassed = 0
function Assert-WriteRemove($ok, $reason) { if (!$ok) { throw $reason } }
function Invoke-WriteRemove($directory, [string[]]$arguments) {
    Push-Location $directory
    try { $lines = @(& $cjxExe @arguments); return [pscustomobject]@{ Code=$LASTEXITCODE; Lines=$lines; Text=($lines -join "`n") } }
    finally { Pop-Location }
}
function Read-RemoveHash($directory) {
    return @('cjpm.toml','cjpm.lock') | ForEach-Object {
        $path = Join-Path $directory $_
        if (Test-Path -LiteralPath $path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { 'absent' }
    }
}
function Assert-RemoveClean($directory) {
    Assert-WriteRemove (@(Get-ChildItem -LiteralPath $directory -Force | Where-Object { $_.Name -like '*cjx-*' -or $_.Name -like 'tmpFile*' -or $_.Name -like 'tmpDir*' }).Count -eq 0) 'Operation artifacts remain'
}
function Write-RemoveText($directory, [string]$text) {
    Assert-WriteRemove ([IO.Path]::GetFullPath($directory).StartsWith($cjxTemp + '\', [StringComparison]::OrdinalIgnoreCase)) 'Unsafe fixture write'
    [IO.File]::WriteAllBytes((Join-Path $directory 'cjpm.toml'), $cjxUtf8.GetBytes($text))
}
function Test-WriteRemove($name, [scriptblock]$body) {
    $case = Join-Path $cjxTemp ('case-' + ($script:cjxPassed + 1))
    New-Item -ItemType Directory -Path $case | Out-Null
    & $body $case
    $script:cjxPassed++
    Write-Output "PASS $name"
}
function Init-RemoveApp($case, [string]$declarations) {
    foreach ($name in @('app','foo','bar','baz')) {
        $directory = Join-Path $case $name
        New-Item -ItemType Directory -Path $directory | Out-Null
        Push-Location $directory
        try { cjpm init --name $name --type static | Out-Null; Assert-WriteRemove ($LASTEXITCODE -eq 0) 'Init failed' }
        finally { Pop-Location }
    }
    $app = Join-Path $case 'app'
    $text = [IO.File]::ReadAllText((Join-Path $app 'cjpm.toml'), $cjxUtf8)
    Assert-WriteRemove ($text.Contains('[dependencies]')) 'Init manifest changed'
    Write-RemoveText $app ($text.Replace('[dependencies]', "[dependencies]`n" + $declarations))
    return $app
}
function Seed-RemoveLock($app) {
    Push-Location $app
    try { cjpm update | Out-Null; Assert-WriteRemove ($LASTEXITCODE -eq 0) 'Initial update failed' }
    finally { Pop-Location }
}
function Assert-Removed($app, [string]$name) {
    $r = Invoke-WriteRemove $app @('remove',$name)
    Assert-WriteRemove ($r.Code -eq 0 -and $r.Lines -contains 'Removed dependency successfully.' -and $r.Lines -contains 'Dependencies updated successfully.') $r.Text
    Assert-RemoveClean $app
    return $r
}
function Format-Remove($case, [string]$original, [string]$expected, [string]$name='foo') {
    Write-RemoveText $case $original
    [IO.File]::WriteAllBytes((Join-Path $case 'cjpm.lock'), [byte[]]@(255,0,13,10))
    $before = @(Read-RemoveHash $case)
    $r = Invoke-WriteRemove $case @('remove',$name,'--no-update')
    Assert-WriteRemove ($r.Code -eq 0 -and $r.Text.Contains('Dependency was removed from cjpm.toml.') -and !$r.Text.Contains('Updating dependencies')) $r.Text
    Assert-WriteRemove ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $case 'cjpm.toml'))) -ceq [Convert]::ToBase64String($cjxUtf8.GetBytes($expected))) 'Exact bytes differ'
    $after = @(Read-RemoveHash $case)
    Assert-WriteRemove ($before[1] -ceq $after[1]) 'no-update changed lock'
    Assert-RemoveClean $case
}
try {
    New-Item -ItemType Directory -Path $cjxTemp | Out-Null
    Test-WriteRemove '01 real sole Path remove update with existing lock' { param($c)
        $app = Init-RemoveApp $c "foo = { path = '../foo' }`n"
        Seed-RemoveLock $app
        (Assert-Removed $app 'foo').Lines
        $list = Invoke-WriteRemove $app @('list')
        Assert-WriteRemove ($list.Code -eq 0 -and $list.Text.Contains('(0 dependencies)')) $list.Text
        $list.Lines
        Assert-WriteRemove ([IO.File]::ReadAllText((Join-Path $app 'cjpm.toml')).Contains('[dependencies]')) 'Empty section lost'
        [IO.File]::ReadAllText((Join-Path $app 'cjpm.lock'))
    }
    Test-WriteRemove '02 real remove generates initially absent lock' { param($c)
        $app = Init-RemoveApp $c "foo = { path = '../foo' }`n"
        Assert-WriteRemove (!(Test-Path (Join-Path $app 'cjpm.lock'))) 'Expected absent lock'
        [void](Assert-Removed $app 'foo')
        Assert-WriteRemove (Test-Path (Join-Path $app 'cjpm.lock')) 'Update did not generate lock'
    }
    Test-WriteRemove '03 Git remove update without remote access' { param($c)
        $app = Init-RemoveApp $c "foo = { git = 'https://invalid.example/foo.git', branch = 'main' }`n"
        [void](Assert-Removed $app 'foo')
    }
    Test-WriteRemove '04 first dependency and retained list' { param($c)
        $app = Init-RemoveApp $c "foo={path='../foo'}`nbar={path='../bar'}`nbaz={path='../baz'}`n"
        [void](Assert-Removed $app 'foo')
        $list = Invoke-WriteRemove $app @('list')
        Assert-WriteRemove ($list.Text -match 'bar\s+path\s+../bar' -and $list.Text -match 'baz\s+path\s+../baz' -and $list.Text.Contains('2 dependencies')) 'Retained list'
    }
    Test-WriteRemove '05 middle dependency' { param($c)
        $app = Init-RemoveApp $c "foo={path='../foo'}`nbar={path='../bar'}`nbaz={path='../baz'}`n"
        [void](Assert-Removed $app 'bar')
    }
    Test-WriteRemove '06 last dependency from nested cwd' { param($c)
        $app = Init-RemoveApp $c "foo={path='../foo'}`nbar={path='../bar'}`n"
        $sub = Join-Path $app 'src\nested'; New-Item -ItemType Directory -Path $sub -Force | Out-Null
        [void](Assert-Removed $sub 'bar')
        Assert-WriteRemove (Test-Path (Join-Path $app 'cjpm.lock')) 'Wrong update cwd'
        Assert-RemoveClean $app
    }
    Test-WriteRemove '07 real failure restores TOML and original lock' { param($c)
        $app = Init-RemoveApp $c "foo={path='../foo'}`n"
        Seed-RemoveLock $app
        $text = [IO.File]::ReadAllText((Join-Path $app 'cjpm.toml'))
        Write-RemoveText $app ($text + "`nmissing={path='../missing'}`n")
        $before = @(Read-RemoveHash $app)
        $r = Invoke-WriteRemove $app @('remove','foo')
        Assert-WriteRemove ($r.Code -eq 1 -and $r.Text.Contains('cjpm update failed') -and $r.Text.Contains('Project files were restored.') -and !$r.Text.Contains('Removed dependency successfully.')) $r.Text
        Assert-WriteRemove ((@(Read-RemoveHash $app) -join ':') -ceq ($before -join ':')) 'Failure metadata not restored'
        Assert-RemoveClean $app; $r.Lines
    }
    Test-WriteRemove '08 real failure restores initially absent lock state' { param($c)
        $app = Init-RemoveApp $c "foo={path='../foo'}`nmissing={path='../missing'}`n"
        $before = @(Read-RemoveHash $app)
        $r = Invoke-WriteRemove $app @('remove','foo')
        Assert-WriteRemove ($r.Code -eq 1 -and $r.Text.Contains('Project files were restored.')) $r.Text
        Assert-WriteRemove ((@(Read-RemoveHash $app) -join ':') -ceq ($before -join ':')) 'Failure state mismatch'
        Assert-RemoveClean $app
    }
    Test-WriteRemove '09 no-update only changes TOML' { param($c)
        Format-Remove $c "[dependencies]`nfoo={path='x'}`nbar={git='invalid'}`n" "[dependencies]`nbar={git='invalid'}`n"
    }
    Test-WriteRemove '10 dry-run and combination entirely side effect free' { param($c)
        Write-RemoveText $c "[dependencies]`nfoo='1'`n"
        foreach ($flags in @(@('--dry-run'), @('--dry-run','--no-update'))) {
            $before = @(Read-RemoveHash $c)
            $r = Invoke-WriteRemove $c (@('remove','foo') + $flags)
            Assert-WriteRemove ($r.Code -eq 0 -and $r.Text.Contains('Dry run')) $r.Text
            Assert-WriteRemove ((@(Read-RemoveHash $c) -join ':') -ceq ($before -join ':')) 'Dry-run metadata changed'
            Assert-WriteRemove (@(Get-ChildItem -LiteralPath $c -Force).Count -eq 1) 'Dry-run artifacts'
        }
    }
    Test-WriteRemove '11 missing dependency does not start update' { param($c)
        Write-RemoveText $c "[dependencies]`nfoo='1'`n"
        $before = @(Read-RemoveHash $c)
        $r = Invoke-WriteRemove $c @('remove','bar')
        Assert-WriteRemove ($r.Code -eq 1 -and $r.Text.Contains("dependency 'bar' was not found.") -and !$r.Text.Contains('Updating dependencies')) $r.Text
        Assert-WriteRemove ((@(Read-RemoveHash $c) -join ':') -ceq ($before -join ':')) 'Missing name changed metadata'
    }
    Test-WriteRemove '12 quoted decoded key' { param($c)
        Format-Remove $c "[dependencies]`n'org::foo'='1'`n" "[dependencies]`n" 'org::foo'
    }
    Test-WriteRemove '13 CRLF exact bytes' { param($c)
        Format-Remove $c "[dependencies]`r`nfoo='1' # tail`r`nbar='2'`r`n" "[dependencies]`r`nbar='2'`r`n"
    }
    Test-WriteRemove '14 LF exact bytes' { param($c)
        Format-Remove $c "[dependencies]`nfoo='1'`nbar='2'`n" "[dependencies]`nbar='2'`n"
    }
    Test-WriteRemove '15 BOM exact bytes' { param($c)
        Format-Remove $c ([char]0xFEFF+"[dependencies]`nfoo='1'`n") ([char]0xFEFF+"[dependencies]`n")
    }
    Test-WriteRemove '16 Chinese leading notes retained' { param($c)
        Format-Remove $c "# 项目`n[dependencies]`n# 中文依赖说明`nfoo={path='../中文'} # 行尾`nbar={path='../其他'}`n" "# 项目`n[dependencies]`n# 中文依赖说明`nbar={path='../其他'}`n"
    }
    Test-WriteRemove '17 EOF without newline' { param($c)
        Format-Remove $c "[dependencies]`nfoo='1'" "[dependencies]`n"
    }
    Test-WriteRemove '18 EOF with newline' { param($c)
        Format-Remove $c "[dependencies]`nfoo='1'`n" "[dependencies]`n"
    }
    Test-WriteRemove '19 multiline statement with comments safe commit' { param($c)
        Format-Remove $c "[dependencies]`n# keep`nfoo={`n git='url',`n branch='main'`n} # tail`nbar='2'`n" "[dependencies]`n# keep`nbar='2'`n"
    }
    Test-WriteRemove '20 malformed and unsupported refuse without writes' { param($c)
        foreach ($text in @("[dependencies]`nfoo='broken", "[dependencies.foo]`npath='x'")) {
            Write-RemoveText $c $text
            $before = @(Read-RemoveHash $c)
            $r = Invoke-WriteRemove $c @('remove','foo')
            Assert-WriteRemove ($r.Code -eq 1 -and !$r.Text.Contains('Updating dependencies')) $r.Text
            Assert-WriteRemove ((@(Read-RemoveHash $c) -join ':') -ceq ($before -join ':')) 'Invalid input changed'
        }
    }
    Write-Output "$script:cjxPassed remove write CLI tests passed"
} finally {
    $cjxResolved = [IO.Path]::GetFullPath($cjxTemp)
    $cjxAllowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\cjx-remove-write-'
    if (!$cjxResolved.StartsWith($cjxAllowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path' }
    if (Test-Path -LiteralPath $cjxResolved) { Remove-Item -LiteralPath $cjxResolved -Recurse -Force }
}
