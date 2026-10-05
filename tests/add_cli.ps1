$ErrorActionPreference = 'Stop'
$cjxRoot = Split-Path -Parent $PSScriptRoot
$cjxBinary = Join-Path $cjxRoot 'target\release\bin\main.exe'
$cjxTemp = Join-Path ([IO.Path]::GetTempPath()) ('cjx-cli-tests-' + [Guid]::NewGuid().ToString('N'))
$cjxUtf8 = [Text.UTF8Encoding]::new($false)
$script:cjxPassed = 0

function Assert-Cjx($condition, $message) {
    if (!$condition) { throw $message }
}
function Write-CjxFixture($directory, [string]$text) {
    $resolved = [IO.Path]::GetFullPath($directory)
    Assert-Cjx ($resolved.StartsWith($cjxTemp + '\', [StringComparison]::OrdinalIgnoreCase)) 'Unsafe fixture write path'
    [IO.File]::WriteAllBytes((Join-Path $directory 'cjpm.toml'), $cjxUtf8.GetBytes($text))
}
function Invoke-Cjx($directory, [string[]]$arguments) {
    if ($arguments.Length -gt 0 -and $arguments[0] -eq 'add' -and $arguments -notcontains '--dry-run') { $arguments += '--no-update' }
    Push-Location $directory
    try {
        $lines = @(& $cjxBinary @arguments)
        $code = $LASTEXITCODE
        return [pscustomobject]@{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
    } finally { Pop-Location }
}
function Test-Cjx($name, [scriptblock]$body) {
    $directory = Join-Path $cjxTemp ('case-' + ($script:cjxPassed + 1))
    New-Item -ItemType Directory -Path $directory | Out-Null
    & $body $directory
    $script:cjxPassed++
    Write-Output "PASS $name"
}
function Assert-CjxAdd($directory, [string]$original, [string[]]$arguments, [string]$source, [string]$spec) {
    Write-CjxFixture $directory $original
    $r = Invoke-Cjx $directory (@('add') + $arguments)
    Assert-Cjx ($r.Code -eq 0 -and $r.Text.Contains('Added dependency:')) "Add failed: $($r.Text)"
    Assert-Cjx ($r.Text.Contains('Run `cjpm update` to refresh cjpm.lock.')) 'Missing update reminder'
    $final = [IO.File]::ReadAllText((Join-Path $directory 'cjpm.toml'), $cjxUtf8)
    Assert-Cjx ($final.EndsWith("`n") -eq $original.EndsWith("`n")) 'EOF newline changed'
    $list = Invoke-Cjx $directory @('list')
    $row = [regex]::Escape($arguments[0]) + '\s+' + [regex]::Escape($source) + '\s+' + [regex]::Escape($spec)
    Assert-Cjx ($list.Code -eq 0 -and $list.Text -match $row) "List mismatch: $($list.Text)"
    Assert-Cjx (@(Get-ChildItem -LiteralPath $directory -Force | Where-Object { $_.Name -like 'tmpFile*' -or $_.Name -like '*.cjx-lock' }).Count -eq 0) 'Transaction artifacts remain'
    # No automatic CJPM resolution: add/list must not create a lock file.
    Assert-Cjx (!(Test-Path -LiteralPath (Join-Path $directory 'cjpm.lock'))) 'Unexpected CJPM lock file'
    return $r
}

try {
    New-Item -ItemType Directory -Path $cjxTemp | Out-Null
    Test-Cjx '01 path add and subsequent list' { param($d)
        $r = Assert-CjxAdd $d "[dependencies]`n" @('foo','--path','../foo') 'path' '../foo'
        $r.Lines
        (Invoke-Cjx $d @('list')).Lines
    }
    Test-Cjx '02 Git add without network' { param($d)
        [void](Assert-CjxAdd $d "[dependencies]`n" @('foo','--git','https://example.com/foo.git') 'git' 'https://example.com/foo.git')
    }
    Test-Cjx '03 Git branch' { param($d)
        [void](Assert-CjxAdd $d '' @('foo','--git','url','--branch','main') 'git' 'url [branch=main]')
    }
    Test-Cjx '04 Git tag' { param($d)
        [void](Assert-CjxAdd $d '' @('foo','--git','url','--tag','v1') 'git' 'url [tag=v1]')
    }
    Test-Cjx '05 Git commitId' { param($d)
        [void](Assert-CjxAdd $d '' @('foo','--git','url','--commit-id','abc123') 'git' 'url [commitId=abc123]')
    }
    Test-Cjx '06 all selectors' { param($d)
        [void](Assert-CjxAdd $d '' @('foo','--git','url','--branch','main','--tag','v1','--commit-id','abc') 'git' 'url [commitId=abc] [branch=main] [tag=v1]')
    }
    Test-Cjx '07 dry-run SHA-256 unchanged' { param($d)
        Write-CjxFixture $d "[dependencies]`r`n"
        $before = (Get-FileHash (Join-Path $d 'cjpm.toml')).Hash
        $r = Invoke-Cjx $d @('add','foo','--path','../foo','--dry-run')
        Assert-Cjx ($r.Code -eq 0 -and $r.Text.Contains('No files were modified.')) 'Dry-run output'
        Assert-Cjx ((Get-FileHash (Join-Path $d 'cjpm.toml')).Hash -eq $before) 'Dry-run changed bytes'
        Assert-Cjx (@(Get-ChildItem -LiteralPath $d -Force).Count -eq 1) 'Dry-run created artifacts'
    }
    Test-Cjx '08 pre-existing decoded name rejected' { param($d)
        Write-CjxFixture $d "[dependencies]`n`"foo`"={path='../old'}`n"
        $before = (Get-FileHash (Join-Path $d 'cjpm.toml')).Hash
        $r = Invoke-Cjx $d @('add','foo','--path','../foo')
        Assert-Cjx ($r.Code -eq 1 -and $r.Text.Contains("dependency 'foo' already exists")) 'Duplicate error'
        Assert-Cjx ((Get-FileHash (Join-Path $d 'cjpm.toml')).Hash -eq $before) 'Duplicate changed bytes'
    }
    Test-Cjx '09 no dependency section' { param($d)
        [void](Assert-CjxAdd $d "[package]`nname='demo'`n" @('foo','--path','../foo') 'path' '../foo')
    }
    Test-Cjx '10 empty dependency section before another section' { param($d)
        [void](Assert-CjxAdd $d "[dependencies]`n# comment`n[package]`nname='demo'`n" @('foo','--path','../foo') 'path' '../foo')
    }
    Test-Cjx '11 empty file' { param($d)
        [void](Assert-CjxAdd $d '' @('foo','--path','../foo') 'path' '../foo')
    }
    Test-Cjx '12 LF preserved exactly' { param($d)
        [void](Assert-CjxAdd $d "[dependencies]`nold={path='../old'}`n" @('foo','--path','../foo') 'path' '../foo')
        $text = [IO.File]::ReadAllText((Join-Path $d 'cjpm.toml'))
        Assert-Cjx ($text -eq "[dependencies]`nold={path='../old'}`nfoo = { path = `"../foo`" }`n") 'LF exact bytes'
    }
    Test-Cjx '13 CRLF preserved exactly' { param($d)
        [void](Assert-CjxAdd $d "[dependencies]`r`nold={path='../old'}`r`n" @('foo','--path','../foo') 'path' '../foo')
        $text = [IO.File]::ReadAllText((Join-Path $d 'cjpm.toml'))
        Assert-Cjx ($text -eq "[dependencies]`r`nold={path='../old'}`r`nfoo = { path = `"../foo`" }`r`n") 'CRLF exact bytes'
    }
    Test-Cjx '14 BOM retained' { param($d)
        [void](Assert-CjxAdd $d ([char]0xFEFF + "[dependencies]`r`n") @('foo','--path','../foo') 'path' '../foo')
        $bytes = [IO.File]::ReadAllBytes((Join-Path $d 'cjpm.toml'))
        Assert-Cjx ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'BOM lost'
    }
    Test-Cjx '15 Chinese file contents' { param($d)
        [void](Assert-CjxAdd $d "# 中文注释`n[dependencies]`nold={path='../原始库'}`n" @('foo','--path','../foo') 'path' '../foo')
        Assert-Cjx ([IO.File]::ReadAllText((Join-Path $d 'cjpm.toml')).Contains("# 中文注释`n")) 'Chinese changed'
    }
    Test-Cjx '16 Windows path' { param($d)
        [void](Assert-CjxAdd $d '' @('foo','--path','C:\source\foo') 'path' 'C:\source\foo')
    }
    Test-Cjx '17 spaces in path' { param($d)
        [void](Assert-CjxAdd $d '' @('foo','--path','../my foo') 'path' '../my foo')
    }
    Test-Cjx '18 no final newline' { param($d)
        [void](Assert-CjxAdd $d "[dependencies]`nold={path='../old'}" @('foo','--path','../foo') 'path' '../foo')
    }
    Test-Cjx '19 consecutive distinct additions' { param($d)
        Write-CjxFixture $d "[dependencies]`n"
        foreach ($name in @('foo','bar')) {
            $r = Invoke-Cjx $d @('add',$name,'--path',('../' + $name))
            Assert-Cjx ($r.Code -eq 0) $r.Text
        }
        $list = Invoke-Cjx $d @('list')
        Assert-Cjx ($list.Text -match 'foo\s+path\s+../foo' -and $list.Text -match 'bar\s+path\s+../bar' -and $list.Text.Contains('2 dependencies')) 'Two additions lost'
    }
    Test-Cjx '20 second same-name add refused' { param($d)
        Write-CjxFixture $d "[dependencies]`n"
        Assert-Cjx ((Invoke-Cjx $d @('add','foo','--path','../foo')).Code -eq 0) 'Initial add'
        $before = (Get-FileHash (Join-Path $d 'cjpm.toml')).Hash
        Assert-Cjx ((Invoke-Cjx $d @('add','foo','--path','../other')).Code -eq 1) 'Second add accepted'
        Assert-Cjx ((Get-FileHash (Join-Path $d 'cjpm.toml')).Hash -eq $before) 'Second add changed bytes'
    }
    Test-Cjx '21 malformed and unsupported scanner refusal' { param($d)
        foreach ($text in @("[dependencies]`nfoo={", "[dependencies.foo]`npath='../foo'")) {
            Write-CjxFixture $d $text
            $before = (Get-FileHash (Join-Path $d 'cjpm.toml')).Hash
            Assert-Cjx ((Invoke-Cjx $d @('add','bar','--path','../bar')).Code -eq 1) 'Unsafe scanner input accepted'
            Assert-Cjx ((Get-FileHash (Join-Path $d 'cjpm.toml')).Hash -eq $before) 'Unsafe input changed'
        }
    }
    Test-Cjx '22 lock collision reaches real CLI' { param($d)
        Write-CjxFixture $d "[dependencies]`n"
        $before = (Get-FileHash (Join-Path $d 'cjpm.toml')).Hash
        New-Item -ItemType Directory (Join-Path $d '.cjpm.toml.cjx-lock') | Out-Null
        $r = Invoke-Cjx $d @('add','foo','--path','../foo')
        Assert-Cjx ($r.Code -eq 1 -and $r.Text.StartsWith('Error:')) 'Lock refusal output'
        Assert-Cjx ((Get-FileHash (Join-Path $d 'cjpm.toml')).Hash -eq $before) 'Lock conflict changed original'
    }
    Test-Cjx '23 dry-run before source option' { param($d)
        Write-CjxFixture $d ''
        $r = Invoke-Cjx $d @('add','foo','--dry-run','--path','../foo')
        Assert-Cjx ($r.Code -eq 0 -and $r.Text.StartsWith('Dry run')) 'Flag position'
        Assert-Cjx ([IO.File]::ReadAllBytes((Join-Path $d 'cjpm.toml')).Length -eq 0) 'Empty dry-run changed'
    }
    Test-Cjx '24 real initialized path project passes CJPM 1.0.5 check' { param($d)
        $app = Join-Path $d 'app'
        $dep = Join-Path $d 'foo'
        foreach ($p in @($app,$dep)) { New-Item -ItemType Directory $p | Out-Null }
        Push-Location $dep
        try { cjpm init --name foo --type static | Out-Null; Assert-Cjx ($LASTEXITCODE -eq 0) 'Dependency init' }
        finally { Pop-Location }
        Push-Location $app
        try { cjpm init --name demo | Out-Null; Assert-Cjx ($LASTEXITCODE -eq 0) 'App init' }
        finally { Pop-Location }
        $r = Invoke-Cjx $app @('add','foo','--path','../foo')
        Assert-Cjx ($r.Code -eq 0) $r.Text
        $r.Lines
        (Invoke-Cjx $app @('list')).Lines
        Push-Location $app
        try {
            cjpm check --skip-script
            Assert-Cjx ($LASTEXITCODE -eq 0) 'CJPM check rejected generated path declaration'
        } finally { Pop-Location }
    }
    Write-Output "$script:cjxPassed real CLI integration tests passed; 0 failed"
} finally {
    $resolved = [IO.Path]::GetFullPath($cjxTemp)
    $allowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\cjx-cli-tests-'
    if (!$resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe integration cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
