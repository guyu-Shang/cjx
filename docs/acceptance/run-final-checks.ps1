param([Parameter(Mandatory=$true)][string]$SdkRoot)
$ErrorActionPreference = 'Stop'
$cjxRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$auditOutput = Join-Path $PSScriptRoot 'final-checks'
if (Test-Path -LiteralPath $auditOutput) { throw 'Evidence already exists; preserve it instead of overwriting' }
New-Item -ItemType Directory -Path $auditOutput | Out-Null
$workspace = Join-Path ([IO.Path]::GetTempPath()) ('CJXFinalAudit_' + [Guid]::NewGuid().ToString('N'))
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
    $cjc = (Get-Command cjc -CommandType Application).Source
    $binary = Join-Path $cjxRoot 'target\release\bin\main.exe'
    New-Item -ItemType Directory -Path $workspace | Out-Null
    New-Source (Join-Path $workspace 'probe.cj') "main(args: Array<String>): Int64 { println(`"ENTERED_MAIN`"); for (arg in args) { println(arg) }; return 0 }`n"
    $r = Run $cjc @((Join-Path $workspace 'probe.cj'),'--output-dir',$workspace,'-o','probe.exe') $workspace
    $probe = Join-Path $workspace 'probe.exe'
    $r = Run $probe @('ascii') $workspace
    Finding ($r.Stdout.Contains('ENTERED_MAIN')) 'Minimal official-compiled main starts with ASCII argv'
    $r = Run $probe @('中文') $workspace @(0,1)
    Finding ($r.Exit -eq 1 -and !$r.Stdout.Contains('ENTERED_MAIN') -and $r.Stderr.Contains('Invalid unicode scalar value')) 'Unicode argv exception reproduced without CJX, before main'
    foreach ($dir in @($cjxRoot,'C:\sourse\cj\practice')) {
        $r = Run $binary @('list') $dir
        $r = Run $binary @('doctor') $dir
        Finding (Same-State $r.Before $r.After) "Real doctor is metadata read-only: $dir"
    }
    $nested = Join-Path $cjxRoot 'src'
    $r = Run $binary @('list') $nested @(0) 'normal' '' $cjxRoot
    Finding (Same-State $r.Before $r.After) 'Direct exe nested cwd lookup does not write'
    $r = Run $binary @('doctor') $workspace @(1)
    Finding ($r.Stdout -match 'Cangjie SDK\s+OK\s+1.0.5' -and $r.Stdout -match 'CJPM\s+OK\s+1.0.5' -and $r.Stdout -match 'cjpm.toml\s+ERROR') 'No-project doctor completes environment checks and exits 1'
} catch { Finding $false 'Final checks interrupted' $_.Exception.Message }
finally {
    Finding (Same-State $protectedBefore @($protected | ForEach-Object { State-File $_ })) 'Protected real TOML/lock unchanged'
    Finding (Same-State $sourceBefore @(Get-ChildItem (Join-Path $cjxRoot 'src') -Filter '*.cj' | Sort-Object Name | ForEach-Object { State-File $_.FullName })) 'Production source unchanged'
    $summary = [pscustomobject]@{Workspace=$workspace;Findings=$findings.ToArray();Setup=$setup.ToArray();Commands=$records.ToArray()}
    [IO.File]::WriteAllText((Join-Path $auditOutput 'summary.json'),($summary | ConvertTo-Json -Depth 10),$encoding)
    $table = @('# Final read-only and SDK argv controls','','| ID | cwd | native command | exit |','|---|---|---|---|')
    foreach ($record in $records) { $table += '| '+$record.Id+' | '+$record.Cwd+' | `'+$record.Executable+' '+($record.Arguments -join ' ')+'` | '+$record.Exit+' |' }
    [IO.File]::WriteAllText((Join-Path $auditOutput 'commands.md'),($table -join "`n"),$encoding)
    $absolute = [IO.Path]::GetFullPath($workspace)
    $allowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\CJXFinalAudit_'
    if (!$absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup root' }
    if (Test-Path -LiteralPath $absolute) { Remove-Item -LiteralPath $absolute -Recurse -Force }
    Write-Output "Final evidence: $auditOutput"
}