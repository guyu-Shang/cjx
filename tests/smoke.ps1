param([Parameter(Mandatory=$true)][string]$Binary)
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('cjx-gate-smoke-' + [Guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
$cjpm = (Get-Command cjpm -CommandType Application -ErrorAction Stop).Source
function Assert-Smoke($ok, [string]$reason) { if (!$ok) { throw $reason } }
function Run-Native([string]$exe, [string[]]$argv, [string]$cwd, [int]$expected=0) {
    Push-Location $cwd
    try {
        $lines = @(& $exe @argv 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    Write-Output "COMMAND [$cwd] $exe $($argv -join ' ') => exit $code"
    $lines | ForEach-Object { Write-Output $_ }
    Assert-Smoke ($code -eq $expected) "Expected exit $expected, got $code"
    return [pscustomobject]@{Text=($lines -join "`n");Code=$code}
}
function Native([string]$exe, [string[]]$argv, [string]$cwd, [int]$expected=0) {
    $output = @(Run-Native $exe $argv $cwd $expected)
    $output[0..($output.Count-2)] | ForEach-Object { Write-Host $_ }
    return $output[-1]
}
function Metadata([string]$dir) {
    @('cjpm.toml','cjpm.lock') | ForEach-Object {
        $path = Join-Path $dir $_
        if (Test-Path -LiteralPath $path) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) } else { '<absent>' }
    }
}
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $r = Native $Binary @('--help') $root
    Assert-Smoke ($r.Text.Contains('Usage: cjx')) 'CJX help not shown'
    $r = Native $Binary @('--version') $root
    Assert-Smoke ($r.Text -match '^cjx \d+\.\d+\.\d+') 'CJX version not shown'
    Write-Output 'GATE CLI smoke PASS'
    foreach ($name in @('app','foo','bar')) {
        $dir = Join-Path $root $name
        New-Item -ItemType Directory -Path $dir | Out-Null
        $kind = if ($name -eq 'app') { 'executable' } else { 'static' }
        $r = Native $cjpm @('init','--name',$name,'--type',$kind) $dir
    }
    $app = Join-Path $root 'app'
    [IO.File]::WriteAllText((Join-Path $root 'foo\src\foo.cj'), "package foo`npublic func message(): String { return `"foo`" }`n", $utf8)
    $before = Metadata $app
    $r = Native $Binary @('doctor') $app
    $r = Native $Binary @('list') $app
    Assert-Smoke ($r.Text.Contains('(0 dependencies)')) 'Fresh list not empty'
    Assert-Smoke (($before -join ':') -ceq ((Metadata $app) -join ':')) 'Read-only commands changed metadata'
    $r = Native $Binary @('add','foo','--path','../foo','--dry-run') $app
    Assert-Smoke (($before -join ':') -ceq ((Metadata $app) -join ':')) 'Add dry-run wrote metadata'
    $r = Native $Binary @('add','foo','--path','../foo') $app
    Assert-Smoke (([IO.File]::ReadAllText((Join-Path $app 'cjpm.toml'))).Contains('foo = { path = "../foo" }')) 'Missing actual declaration'
    Assert-Smoke (Test-Path -LiteralPath (Join-Path $app 'cjpm.lock')) 'Update did not create lock'
    $r = Native $Binary @('list') $app
    Assert-Smoke ($r.Text -match 'foo\s+path\s+\.\./foo') 'Added dependency not listed'
    # Import before the first build; run an actual dependency consumer, not Hello World.
    $main = Join-Path $app 'src\main.cj'
    $hello = [IO.File]::ReadAllBytes($main)
    [IO.File]::WriteAllText($main, "package app`nimport foo.*`nmain(): Int64 { println(message()); return 0 }`n", $utf8)
    $r = Native $cjpm @('check') $app
    $r = Native $cjpm @('build') $app
    $r = Native (Join-Path $app 'target\release\bin\main.exe') @() $app
    Assert-Smoke ($r.Text.Trim() -eq 'foo') 'Fresh consumer did not execute dependency'
    [IO.File]::WriteAllBytes($main,$hello)
    $beforeRemove = Metadata $app
    $r = Native $Binary @('remove','foo','--dry-run') $app
    Assert-Smoke (($beforeRemove -join ':') -ceq ((Metadata $app) -join ':')) 'Remove dry-run wrote metadata'
    $r = Native $Binary @('remove','foo') $app
    $r = Native $Binary @('list') $app
    Assert-Smoke ($r.Text.Contains('(0 dependencies)')) 'Removed dependency still listed'
    Assert-Smoke ((Metadata $app)[0] -ceq $before[0]) 'Lifecycle changed original TOML bytes'
    $r = Native $cjpm @('check') $app
    $r = Native $cjpm @('clean') $app
    $r = Native $cjpm @('build') $app
    Write-Output 'GATE Integration PASS'
    $r = Native $Binary @('add','foo','--path','../foo') $app
    $r = Native $Binary @('add','bar','--path','../bar') $app
    $r = Native $cjpm @('check') $app
    $r = Native $cjpm @('build') $app
    $baseline = Metadata $app
    $r = Native $Binary @('add','missing','--path','../missing') $app 1
    Assert-Smoke ($r.Text.Contains('cjpm update failed')) 'Expected real update failure'
    Assert-Smoke (($baseline -join ':') -ceq ((Metadata $app) -join ':')) 'Failed add did not restore exact metadata'
    $bar = Join-Path $root 'bar'; $offline = Join-Path $root 'bar-offline'
    foreach ($path in @($bar,$offline)) {
        Assert-Smoke ([IO.Path]::GetFullPath($path).StartsWith([IO.Path]::GetFullPath($root).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) 'Unsafe dependency move path'
    }
    Move-Item -LiteralPath $bar -Destination $offline
    try {
        $r = Native $Binary @('remove','foo') $app 1
        Assert-Smoke ($r.Text.Contains('cjpm update failed')) 'Expected real remove update failure'
        Assert-Smoke (($baseline -join ':') -ceq ((Metadata $app) -join ':')) 'Failed remove did not restore exact metadata'
    } finally { Move-Item -LiteralPath $offline -Destination $bar }
    $r = Native $cjpm @('check') $app
    $r = Native $cjpm @('build') $app
    Write-Output 'GATE Rollback PASS'
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    $allowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\cjx-gate-smoke-'
    if (!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe smoke cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
