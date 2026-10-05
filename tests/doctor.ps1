param([string]$PracticeRoot = '')
$ErrorActionPreference = 'Stop'
$cjxRoot = Split-Path -Parent $PSScriptRoot
$cjxBinary = Join-Path $cjxRoot 'target\release\bin\main.exe'
$cjxTemp = Join-Path ([IO.Path]::GetTempPath()) ('cjx-doctor-tests-' + [Guid]::NewGuid().ToString('N'))
function Assert-Doctor($ok, $reason) { if (!$ok) { throw $reason } }
function State-Doctor($directory) {
    @(Get-ChildItem -LiteralPath $directory -Force -Recurse | Sort-Object FullName | ForEach-Object {
        if ($_.PSIsContainer) { 'dir:' + $_.FullName }
        else { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    }) -join "`n"
}
function Invoke-Doctor($directory) {
    Push-Location $directory
    try { $lines = @(& $cjxBinary doctor); return [pscustomobject]@{ Code=$LASTEXITCODE; Text=($lines -join "`n"); Lines=$lines } }
    finally { Pop-Location }
}
try {
    New-Item -ItemType Directory -Path $cjxTemp | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $cjxRoot 'src') -Filter '*.cj' | Where-Object { $_.Name -ne 'main.cj' } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $cjxTemp
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'doctor_tests.cj') -Destination $cjxTemp
    & cjc -p $cjxTemp --output-dir $cjxTemp -o doctor-tests.exe
    Assert-Doctor ($LASTEXITCODE -eq 0) 'Doctor tests did not compile'
    Push-Location $cjxTemp
    try { & (Join-Path $cjxTemp 'doctor-tests.exe'); Assert-Doctor ($LASTEXITCODE -eq 0) 'Doctor unit tests failed' }
    finally { Pop-Location }
    # Fixtures are newly created in an independent temporary directory only.
    $fixture = Join-Path $cjxTemp 'fixture'
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $dependency = Join-Path $cjxTemp 'foo'
    New-Item -ItemType Directory -Path $dependency | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $dependency 'cjpm.toml'), [Text.Encoding]::UTF8.GetBytes("[package]`nname='foo'`n"))
    [IO.File]::WriteAllBytes((Join-Path $fixture 'cjpm.toml'), [Text.Encoding]::UTF8.GetBytes("[dependencies]`nfoo={path='../foo'}`n"))
    $before = State-Doctor $fixture
    $r = Invoke-Doctor $fixture
    Assert-Doctor ($r.Code -eq 0 -and $r.Text -match 'cjpm.lock\s+WARN' -and $r.Text.Contains('1 problem found')) $r.Text
    Assert-Doctor ((State-Doctor $fixture) -ceq $before) 'Warning diagnosis changed files'
    Write-Output 'PASS CLI missing-lock warning and complete directory hash unchanged'
    [IO.File]::WriteAllBytes((Join-Path $fixture 'cjpm.toml'), [Text.Encoding]::UTF8.GetBytes("[dependencies]`nfoo='broken"))
    $before = State-Doctor $fixture
    $r = Invoke-Doctor $fixture
    Assert-Doctor ($r.Code -eq 1 -and $r.Text -match 'TOML scan\s+ERROR' -and $r.Text.Contains('READY')) $r.Text
    Assert-Doctor ((State-Doctor $fixture) -ceq $before) 'Error diagnosis changed files'
    Write-Output 'PASS CLI malformed configuration and complete directory hash unchanged'
    New-Item -ItemType Directory -Path (Join-Path $fixture '.cjpm.toml.cjx-add') | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $fixture 'cjpm.toml'), [Text.Encoding]::UTF8.GetBytes("[dependencies]`n"))
    $before = State-Doctor $fixture
    $r = Invoke-Doctor $fixture
    Assert-Doctor ($r.Code -eq 0 -and $r.Text -match 'Transaction\s+WARN' -and $r.Text.Contains('READY')) $r.Text
    Assert-Doctor ((State-Doctor $fixture) -ceq $before) 'Doctor removed recovery state'
    Write-Output 'PASS CLI recovery state reported and never removed'
    New-Item -ItemType Directory -Path (Join-Path $fixture 'src\nested') -Force | Out-Null
    $r = Invoke-Doctor (Join-Path $fixture 'src\nested')
    Assert-Doctor ($r.Text.Contains((Join-Path $fixture 'cjpm.toml'))) 'Nested discovery failed'
    Write-Output 'PASS CLI parent project diagnosis'
    [IO.File]::WriteAllBytes((Join-Path $fixture 'cjpm.toml'), [Text.Encoding]::UTF8.GetBytes("[dependencies]`nfoo={path='../missing'}`n"))
    $before = State-Doctor $fixture
    $r = Invoke-Doctor (Join-Path $fixture 'src\nested')
    Assert-Doctor ($r.Code -eq 1 -and $r.Text -match 'foo\s+ERROR\s+path does not exist: ../missing') $r.Text
    Assert-Doctor ((State-Doctor $fixture) -ceq $before) 'Path error diagnosis modified files'
    Write-Output 'PASS CLI missing Path relative to project root'
    [IO.File]::WriteAllBytes((Join-Path $fixture 'cjpm.toml'), [Text.Encoding]::UTF8.GetBytes("[dependencies]`nbar='1.2.3'`nfoo={custom='x'}`n"))
    $before = State-Doctor $fixture
    $r = Invoke-Doctor $fixture
    Assert-Doctor ($r.Code -eq 0 -and $r.Text -match 'Dependencies\s+WARN' -and $r.Text -match 'bar\s+WARN\s+central version' -and $r.Text.Contains('Unknown:')) $r.Text
    Assert-Doctor ((State-Doctor $fixture) -ceq $before) 'Compatibility warnings modified files'
    Write-Output 'PASS CLI central and Unknown warnings without error exit'
    $outside = Join-Path $cjxTemp 'outside'
    New-Item -ItemType Directory -Path $outside | Out-Null
    $before = State-Doctor $outside
    $r = Invoke-Doctor $outside
    Assert-Doctor ($r.Code -eq 1 -and $r.Text -match 'cjpm.toml\s+ERROR\s+not found' -and $r.Text -match 'Cangjie SDK\s+OK\s+1.0.5' -and $r.Text -match 'CJPM\s+OK\s+1.0.5') $r.Text
    Assert-Doctor ((State-Doctor $outside) -ceq $before) 'No-project diagnosis changed files'
    Write-Output 'PASS CLI outside a project still diagnoses SDK and CJPM'
} finally {
    $resolved = [IO.Path]::GetFullPath($cjxTemp)
    $allowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\cjx-doctor-tests-'
    if (!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
$realProjects = @($cjxRoot)
if ($PracticeRoot) { $realProjects += $PracticeRoot }
foreach ($project in $realProjects) {
    $files = @((Join-Path $project 'cjpm.toml'),(Join-Path $project 'cjpm.lock'))
    $before = @($files | ForEach-Object { if (Test-Path -LiteralPath $_) { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash } else { 'absent' } })
    $r = Invoke-Doctor $project
    $after = @($files | ForEach-Object { if (Test-Path -LiteralPath $_) { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash } else { 'absent' } })
    Assert-Doctor ($r.Code -eq 0 -and $r.Text.Contains('All checks passed.')) $r.Text
    Assert-Doctor (($before -join ':') -ceq ($after -join ':')) 'Real metadata changed'
    $r.Lines
    Write-Output "PASS real project doctor with unchanged TOML and lock SHA-256: $project"
}
