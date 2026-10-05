param([Parameter(Mandatory=$true)][string]$SdkRoot)
$ErrorActionPreference = 'Stop'
$cjxRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$auditOutput = Join-Path $PSScriptRoot 'cache-control'
if (Test-Path -LiteralPath $auditOutput) { throw 'Evidence already exists; preserve it instead of overwriting' }
New-Item -ItemType Directory -Path $auditOutput | Out-Null
$workspace = Join-Path ([IO.Path]::GetTempPath()) ('CJXCacheAudit_' + [Guid]::NewGuid().ToString('N'))
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
    foreach ($case in @('official','cjx')) {
        $base = Join-Path $workspace $case
        $foo = Join-Path $base 'foo'; $app = Join-Path $base 'app'
        foreach ($name in @('foo','app')) {
            $dir = Join-Path $base $name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $package = if ($name -eq 'foo') { 'foo' } else { 'acceptapp' }
            $kind = if ($name -eq 'foo') { 'static' } else { 'executable' }
            $r = Run $cjpm @('init','--name',$package,'--type',$kind) $dir
        }
        New-Source (Join-Path $foo 'src\foo.cj') "package foo`npublic func message(): String { return `"foo`" }`n"
        if ($case -eq 'official') {
            $path = Join-Path $app 'cjpm.toml'
            New-Source $path ([IO.File]::ReadAllText($path).Replace('[dependencies]',"[dependencies]`nfoo = { path = `"../foo`" }"))
            $r = Run $cjpm @('update') $app
        } else { $r = Run $binary @('add','foo','--path','../foo') $app }
        $r = Run $cjpm @('build') $app
        if ($case -eq 'cjx') {
            $r = Run $binary @('remove','foo') $app
            $r = Run $cjpm @('build') $app
            $r = Run $binary @('add','foo','--path','../foo') $app
        }
        New-Source (Join-Path $app 'src\main.cj') "package acceptapp`nimport foo.*`nmain(): Int64 { println(message()); return 0 }`n"
        $edited = Run $cjpm @('build') $app @(0,1)
        $verbose = Run $cjpm @('build','-V') $app @(0,1)
        $setup.Add("$case build after source edit: plain=$($edited.Exit); verbose=$($verbose.Exit)")
        $r = Run $cjpm @('clean') $app
        $cleanBuild = Run $cjpm @('build','-V') $app
        Finding ($cleanBuild.Exit -eq 0) "Clean rebuild after adding import: $case"
        if ($cleanBuild.Exit -eq 0) {
            $r = Run (Join-Path $app 'target\release\bin\main.exe') @() $app
            Finding ($r.Stdout.Trim() -eq 'foo') "Fresh rebuilt program calls foo: $case"
        }
        $r = Run $binary @('add','cnprobe','--path','../中文目录','--dry-run') $app @(0,1,2)
        $setup.Add("$case Chinese argv dry-run: exit=$($r.Exit); metadata unchanged=$(Same-State $r.Before $r.After)")
        Finding (Same-State $r.Before $r.After) "Chinese argv failure/success does not write: $case"
    }
} catch { Finding $false 'Cache control harness interrupted' $_.Exception.Message }
finally {
    Finding (Same-State $protectedBefore @($protected | ForEach-Object { State-File $_ })) 'Real TOML/lock unchanged'
    Finding (Same-State $sourceBefore @(Get-ChildItem (Join-Path $cjxRoot 'src') -Filter '*.cj' | Sort-Object Name | ForEach-Object { State-File $_.FullName })) 'Production source unchanged'
    $summary = [pscustomobject]@{Workspace=$workspace;Findings=$findings.ToArray();Setup=$setup.ToArray();Commands=$records.ToArray()}
    [IO.File]::WriteAllText((Join-Path $auditOutput 'summary.json'),($summary | ConvertTo-Json -Depth 10),$encoding)
    $table = @('# Cache/source-change control journal','','| ID | cwd | native command | exit |','|---|---|---|---|')
    foreach ($record in $records) { $table += '| '+$record.Id+' | '+$record.Cwd+' | `'+$record.Executable+' '+($record.Arguments -join ' ')+'` | '+$record.Exit+' |' }
    [IO.File]::WriteAllText((Join-Path $auditOutput 'commands.md'),($table -join "`n"),$encoding)
    $absolute = [IO.Path]::GetFullPath($workspace)
    $allowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\CJXCacheAudit_'
    if (!$absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup root' }
    if (Test-Path -LiteralPath $absolute) { Remove-Item -LiteralPath $absolute -Recurse -Force }
    Write-Output "Cache evidence: $auditOutput"
}