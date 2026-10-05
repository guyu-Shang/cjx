param([Parameter(Mandatory=$true)][string]$SdkRoot)
$ErrorActionPreference = 'Stop'
$cjxRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$auditOutput = Join-Path $PSScriptRoot 'follow-up'
if (Test-Path -LiteralPath $auditOutput) { throw 'Evidence already exists; preserve it instead of overwriting' }
New-Item -ItemType Directory -Path $auditOutput | Out-Null
$workspace = Join-Path ([IO.Path]::GetTempPath()) ('CJXauditControl_' + [Guid]::NewGuid().ToString('N'))
$records = [Collections.Generic.List[object]]::new()
$findings = [Collections.Generic.List[object]]::new()
$setup = [Collections.Generic.List[string]]::new()
$encoding = [Text.UTF8Encoding]::new($false)
$script:sequence = 0
$protected = @((Join-Path $cjxRoot 'cjpm.toml'),(Join-Path $cjxRoot 'cjpm.lock'),'C:\sourse\cj\practice\cjpm.toml','C:\sourse\cj\practice\cjpm.lock')
function Digest-Text([string]$text) { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($encoding.GetBytes($text))) }
function State-File([string]$path) {
    if (!(Test-Path -LiteralPath $path)) { return [pscustomobject]@{ Path=$path; Present=$false; Hash='absent'; Text=''; Base64='' } }
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]@{ Path=$path; Present=$true; Hash='directory'; Text=''; Base64='' } }
    $bytes = [IO.File]::ReadAllBytes($path)
    return [pscustomobject]@{ Path=$path; Present=$true; Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash; Text=$encoding.GetString($bytes); Base64=[Convert]::ToBase64String($bytes) }
}
function State-Metadata([string]$directory) { return @((State-File (Join-Path $directory 'cjpm.toml')),(State-File (Join-Path $directory 'cjpm.lock'))) }
function Same-State($a,$b) { return ($a | ForEach-Object { $_.Hash }) -join ':' -ceq (($b | ForEach-Object { $_.Hash }) -join ':') }
function Finding([bool]$ok,[string]$name,[string]$detail='') {
    $status = if ($ok) { 'PASS' } else { 'FAIL' }
    $findings.Add([pscustomobject]@{Status=$status;Name=$name;Detail=$detail})
    Write-Output "$status $name $detail"
}
function Safe-Workspace([string]$path) {
    $absolute = [IO.Path]::GetFullPath($path)
    if (!$absolute.StartsWith([IO.Path]::GetFullPath($workspace).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe fixture mutation: $absolute" }
}
function New-Source([string]$path,[string]$text) {
    Safe-Workspace $path
    [IO.File]::WriteAllText($path,$text,$encoding)
    $setup.Add("Write new temporary source: $path; SHA-256=$((State-File $path).Hash)")
}
function Invoke-Audit([string]$exe,[string[]]$argv,[string]$directory,[int[]]$expected=@(0),[string]$mode='normal',[string]$childPath='', [string]$metadataDirectory='') {
    if (!$metadataDirectory) { $metadataDirectory = $directory }
    $before = State-Metadata $metadataDirectory
    $script:sequence++
    $id = '{0:D3}' -f $script:sequence
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $exe; $start.WorkingDirectory = $directory
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $encoding; $start.StandardErrorEncoding = $encoding
    foreach ($arg in $argv) { $start.ArgumentList.Add($arg) }
    if ($mode -ne 'normal') { $start.Environment['PATH'] = $childPath }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $code = -999; $out = ''; $err = ''
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(45000)) { $process.Kill($true); $process.WaitForExit(); $err = 'Acceptance timeout (45 seconds). ' }
        $out = $stdout.GetAwaiter().GetResult(); $err += $stderr.GetAwaiter().GetResult(); $code = $process.ExitCode
    } catch { $err += $_.Exception.Message }
    finally { $watch.Stop(); $process.Dispose() }
    [IO.File]::WriteAllText((Join-Path $auditOutput "$id.stdout.txt"),$out,$encoding)
    [IO.File]::WriteAllText((Join-Path $auditOutput "$id.stderr.txt"),$err,$encoding)
    $after = State-Metadata $metadataDirectory
    $record = [pscustomobject]@{Id=$id;Executable=$exe;Arguments=$argv;Cwd=$directory;Mode=$mode;Exit=$code;Expected=$expected;Seconds=$watch.Elapsed.TotalSeconds;Before=$before;After=$after;Stdout=$out;Stderr=$err}
    $records.Add($record)
    [IO.File]::AppendAllText((Join-Path $auditOutput 'commands.jsonl'),($record | ConvertTo-Json -Depth 8 -Compress)+"`n",$encoding)
    Finding ($expected -contains $code) "$id exit=$code" ((Split-Path -Leaf $exe)+' '+($argv -join ' ')+" [$mode]")
    return $record
}
# Return only the native record, not Finding's console string, to callers.
function Run([string]$exe,[string[]]$argv,[string]$directory,[int[]]$expected=@(0),[string]$mode='normal',[string]$childPath='', [string]$metadataDirectory='') {
    $items = @(Invoke-Audit $exe $argv $directory $expected $mode $childPath $metadataDirectory)
    foreach ($item in $items) { if ($item -is [string]) { Write-Host $item } }
    return $items[-1]
}

$protectedBefore = @($protected | ForEach-Object { State-File $_ })
$sourceBefore = @(Get-ChildItem (Join-Path $cjxRoot 'src') -Filter '*.cj' | Sort-Object Name | ForEach-Object { State-File $_.FullName })
try {
    . (Join-Path $SdkRoot 'envsetup.ps1')
    $cjpm = (Get-Command cjpm -CommandType Application).Source
    $binary = Join-Path $cjxRoot 'target\release\bin\main.exe'
    New-Item -ItemType Directory -Path $workspace | Out-Null
    foreach ($case in @('noSpaces','with spaces')) {
        $caseRoot = Join-Path $workspace $case
        foreach ($name in @('foo','manual','cjx')) {
            $directory = Join-Path $caseRoot $name
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $package = if ($name -eq 'foo') { 'foo' } else { 'consumer' }
            $kind = if ($name -eq 'foo') { 'static' } else { 'executable' }
            $r = Run $cjpm @('init','--name',$package,'--type',$kind) $directory
        }
        $foo = Join-Path $caseRoot 'foo'; $manual = Join-Path $caseRoot 'manual'; $usingCjx = Join-Path $caseRoot 'cjx'
        New-Source (Join-Path $foo 'src\foo.cj') "package foo`npublic func message(): String { return `"foo`" }`n"
        foreach ($app in @($manual,$usingCjx)) {
            New-Source (Join-Path $app 'src\main.cj') "package consumer`nimport foo.*`nmain(): Int64 { println(message()); return 0 }`n"
        }
        $path = Join-Path $manual 'cjpm.toml'
        $original = [IO.File]::ReadAllText($path)
        New-Source $path ($original.Replace('[dependencies]',"[dependencies]`nfoo = { path = `"../foo`" }"))
        $r = Run $cjpm @('update') $manual
        $r = Run $cjpm @('check') $manual
        $manualBuild = Run $cjpm @('build','-V') $manual @(0,1)
        $r = Run $binary @('add','foo','--path','../foo') $usingCjx
        $r = Run $cjpm @('check') $usingCjx
        $cjxBuild = Run $cjpm @('build','-V') $usingCjx @(0,1)
        Finding ($manualBuild.Exit -eq $cjxBuild.Exit) "Official-only and CJX-configured build agree: $case" "manual=$($manualBuild.Exit); cjx=$($cjxBuild.Exit)"
        if ($cjxBuild.Exit -eq 0) {
            $r = Run (Join-Path $usingCjx 'target\release\bin\main.exe') @() $usingCjx
            Finding ($r.Stdout.Trim() -eq 'foo') "Fresh consumer imports and runs foo: $case"
        }
        $artifactsBefore = @(Get-ChildItem -LiteralPath (Join-Path $foo 'target') -File -Recurse -ErrorAction SilentlyContinue | Select-Object FullName,Length)
        $setup.Add("$case foo artifacts after consumer build: " + ($artifactsBefore | ConvertTo-Json -Compress))
        $r = Run $cjpm @('build','-V') $foo
        $afterLibraryBuild = Run $cjpm @('build','-V') $manual @(0,1)
        $setup.Add("$case manual consumer after explicit foo build: exit=$($afterLibraryBuild.Exit)")
    }
    $first = Get-Content (Join-Path $PSScriptRoot 'evidence\summary.json') -Raw | ConvertFrom-Json
    $test = @($first.Commands | Where-Object Id -eq '040')[0]
    Finding ($test.Exit -eq 0 -and $test.Stdout.Contains('Summary: TOTAL: 0')) 'Official cjpm test exited zero with TOTAL 0, not custom tests'
    $missing = @($first.Commands | Where-Object Id -eq '039')[0]
    Finding ($missing.Exit -eq 1 -and $missing.Stdout.Contains("failed to run 'cjc -v'") -and $missing.Stdout -match 'Cangjie SDK\s+ERROR' -and $missing.Stdout -match 'CJPM\s+ERROR') 'Actual missing-cjc behavior: CJPM version query also needs cjc'
} catch {
    Finding $false 'Control harness could not complete' $_.Exception.Message
} finally {
    Finding (Same-State $protectedBefore @($protected | ForEach-Object { State-File $_ })) 'Real TOML/lock unchanged after official-only controls'
    Finding (Same-State $sourceBefore @(Get-ChildItem (Join-Path $cjxRoot 'src') -Filter '*.cj' | Sort-Object Name | ForEach-Object { State-File $_.FullName })) 'Production source unchanged after controls'
    $summary = [pscustomobject]@{Workspace=$workspace;Findings=$findings.ToArray();Setup=$setup.ToArray();Commands=$records.ToArray()}
    [IO.File]::WriteAllText((Join-Path $auditOutput 'summary.json'),($summary | ConvertTo-Json -Depth 10),$encoding)
    $table = @('# Official-only control journal','','| ID | cwd | native command | exit |','|---|---|---|---|')
    foreach ($record in $records) { $table += '| '+$record.Id+' | '+$record.Cwd+' | `'+$record.Executable+' '+($record.Arguments -join ' ')+'` | '+$record.Exit+' |' }
    [IO.File]::WriteAllText((Join-Path $auditOutput 'commands.md'),($table -join "`n"),$encoding)
    $absolute = [IO.Path]::GetFullPath($workspace)
    $allowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\CJXauditControl_'
    if (!$absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup root' }
    if (Test-Path -LiteralPath $absolute) { Remove-Item -LiteralPath $absolute -Recurse -Force }
    Write-Output "Control evidence: $auditOutput"
}
