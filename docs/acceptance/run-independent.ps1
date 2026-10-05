param([Parameter(Mandatory=$true)][string]$SdkRoot)
$ErrorActionPreference = 'Stop'
$cjxRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$auditOutput = Join-Path $PSScriptRoot 'evidence'
if (Test-Path -LiteralPath $auditOutput) { throw 'Evidence already exists; preserve it instead of overwriting' }
New-Item -ItemType Directory -Path $auditOutput | Out-Null
$workspace = Join-Path ([IO.Path]::GetTempPath()) ('CJX independent audit ' + [Guid]::NewGuid().ToString('N'))
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
$userPathBefore = [Environment]::GetEnvironmentVariable('PATH','User')
$machinePathBefore = [Environment]::GetEnvironmentVariable('PATH','Machine')
$initialProcessSdk = @('cjc','cjpm') | ForEach-Object { $command = Get-Command $_ -ErrorAction SilentlyContinue; "$($_): $(if ($command) {$command.Source} else {'not located'})" }
try {
    . (Join-Path $SdkRoot 'envsetup.ps1')
    $cjc = (Get-Command cjc -CommandType Application).Source
    $cjpm = (Get-Command cjpm -CommandType Application).Source
    $binary = Join-Path $cjxRoot 'target\release\bin\main.exe'
    $oldBinary = State-File $binary
    $r = Run $cjc @('--version') $cjxRoot
    $r = Run $cjpm @('--version') $cjxRoot
    $r = Run $cjpm @('clean') $cjxRoot
    $cleanBinaryAbsent = !(Test-Path -LiteralPath $binary)
    $cleanTargetFiles = @(Get-ChildItem -LiteralPath (Join-Path $cjxRoot 'target') -Recurse -File -ErrorAction SilentlyContinue).Count
    Finding ($cleanBinaryAbsent -and $cleanTargetFiles -eq 0) 'Clean build removed prior executable and target files' "remaining=$cleanTargetFiles"
    if (!$cleanBinaryAbsent) { throw 'Refuse to test an old executable after clean failure' }
    $r = Run $cjpm @('build') $cjxRoot
    $newBinary = State-File $binary
    Finding ($r.Exit -eq 0 -and $newBinary.Present) 'New production exe exists after clean build' $newBinary.Hash
    if (!$newBinary.Present) { throw 'Clean build produced no executable' }
    New-Item -ItemType Directory -Path $workspace | Out-Null
    $setup.Add("New independent workspace: $workspace (contains spaces)")
    foreach ($spec in @(@('app','acceptapp','executable'),@('foo','foo','static'),@('bar','bar','static'),@('failure app','failureapp','executable'))) {
        $directory = Join-Path $workspace $spec[0]
        New-Item -ItemType Directory -Path $directory | Out-Null
        $r = Run $cjpm @('init','--name',$spec[1],'--type',$spec[2]) $directory
    }
    $app = Join-Path $workspace 'app'; $foo = Join-Path $workspace 'foo'; $bar = Join-Path $workspace 'bar'; $failureApp = Join-Path $workspace 'failure app'
    New-Source (Join-Path $foo 'src\foo.cj') "package foo`npublic func message(): String { return `"foo`" }`n"
    New-Source (Join-Path $bar 'src\bar.cj') "package bar`npublic func message(): String { return `"bar`" }`n"
    $initialApp = State-Metadata $app
    $r = Run $binary @('--help') $app
    Finding ($r.Stdout.Contains('list') -and $r.Stdout.Contains('doctor') -and $r.Stdout.Contains('remove')) 'Native exe help describes commands'
    $r = Run $binary @('--version') $app
    Finding ($r.Stdout.Trim() -eq 'cjx 0.1.0') 'Native exe version matches V0.1'
    $r = Run $binary @('doctor') $app
    Finding ($r.Stdout -match 'Cangjie SDK\s+OK\s+1.0.5' -and $r.Stdout -match 'CJPM\s+OK\s+1.0.5' -and $r.Stdout -match 'cjpm.lock\s+WARN') 'Fresh project environment valid and missing lock only WARN'
    $r = Run $binary @('list') $app
    Finding ($r.Stdout.Contains('(0 dependencies)')) 'Fresh project has no dependencies'
    $r = Run $binary @('add','foo','--path','../foo','--dry-run') $app
    Finding ((Same-State $r.Before $r.After) -and $r.Stdout.Contains('No files were modified.')) 'Native add dry-run has no metadata changes'
    $r = Run $binary @('add','foo','--path','../foo') $app
    Finding ($r.After[0].Text.Contains('foo = { path = "../foo" }') -and !$r.Before[1].Present -and $r.After[1].Present) 'Path add changed TOML and generated previously absent lock'
    $r = Run $binary @('list') $app
    Finding ($r.Stdout -match 'foo\s+path\s+../foo') 'List displays actual newly added Path declaration'
    $r = Run $cjpm @('check') $app
    $r = Run $cjpm @('build') $app
    Finding ($r.Stdout.Contains('foo') -and $r.Exit -eq 0) 'Official build compiled dependency foo' 'See command output, not a scanner assertion'
    $r = Run $binary @('remove','foo','--dry-run') $app
    Finding ((Same-State $r.Before $r.After) -and $r.Stdout.Contains('Would remove:')) 'Native remove dry-run has no metadata changes'
    $r = Run $binary @('remove','foo') $app
    Finding (!$r.After[0].Text.Contains('foo = ') -and $r.After[0].Text.Contains('[dependencies]')) 'Remove deleted foo and kept dependencies section'
    Finding ($r.After[0].Hash -ceq $initialApp[0].Hash) 'Add then remove restored original initialized TOML exactly'
    $r = Run $binary @('list') $app
    Finding ($r.Stdout.Contains('(0 dependencies)')) 'List empty after successful remove'
    $r = Run $cjpm @('check') $app
    $r = Run $cjpm @('build') $app
    # Also compile a consumer that actually imports foo, independent of list output.
    $r = Run $binary @('add','foo','--path','../foo') $app
    $sourcePath = Join-Path $app 'src\main.cj'
    $originalSource = [IO.File]::ReadAllText($sourcePath)
    New-Source $sourcePath "package acceptapp`nimport foo.*`nmain(): Int64 { println(message()); return 0 }`n"
    $r = Run $cjpm @('build') $app
    $consumer = Join-Path $app 'target\release\bin\main.exe'
    $r = Run $consumer @() $app
    Finding ($r.Stdout.Trim() -eq 'foo') 'Actual consumer imports, links and runs foo.message'
    New-Source $sourcePath $originalSource
    $r = Run $binary @('remove','foo') $app
    # Valid baseline before independent real failure tests.
    $r = Run $binary @('add','foo','--path','../foo') $failureApp
    $r = Run $binary @('add','bar','--path','../bar') $failureApp
    $r = Run $cjpm @('check') $failureApp
    $r = Run $cjpm @('build') $failureApp
    $r = Run $binary @('add','missing','--path','../does not exist') $failureApp @(1)
    Finding ((Same-State $r.Before $r.After) -and $r.Stdout.Contains('cjpm update failed') -and !$r.Stdout.Contains('Added dependency successfully.')) 'Real failed add restored TOML and existing lock bytes'
    $r = Run $cjpm @('check') $failureApp
    $r = Run $cjpm @('build') $failureApp
    $offlineBar = Join-Path $workspace 'bar temporarily offline'
    Safe-Workspace $bar; Safe-Workspace $offlineBar
    Move-Item -LiteralPath $bar -Destination $offlineBar
    $setup.Add("Move temporary dependency directory: '$bar' -> '$offlineBar'")
    try {
        $r = Run $binary @('remove','foo') $failureApp @(1)
        Finding ((Same-State $r.Before $r.After) -and $r.Stdout.Contains('cjpm update failed') -and !$r.Stdout.Contains('Removed dependency successfully.')) 'Real failed remove restored TOML and existing lock bytes'
    } finally {
        Safe-Workspace $offlineBar; Safe-Workspace $bar
        Move-Item -LiteralPath $offlineBar -Destination $bar
        $setup.Add("Restore temporary external dependency directory: '$offlineBar' -> '$bar'")
    }
    $r = Run $cjpm @('check') $failureApp
    $r = Run $cjpm @('build') $failureApp
    # PATH isolation retains runtime DLL folders; only tool executable visibility changes.
    $removedFolders = @($env:PATH -split ';' | Where-Object { $_ -and ((Test-Path -LiteralPath (Join-Path $_ 'cjc.exe') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $_ 'cjpm.exe') -PathType Leaf)) })
    $basePath = (($env:PATH -split ';') | Where-Object { $removedFolders -notcontains $_ }) -join ';'
    $runtimeOnly = Join-Path $workspace 'runtime only'; New-Item -ItemType Directory -Path $runtimeOnly | Out-Null
    foreach ($folder in $removedFolders) {
        Get-ChildItem -LiteralPath $folder -Filter '*.dll' -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $runtimeOnly -Force }
    }
    $basePath = $runtimeOnly + ';' + $basePath
    $cjcOnly = Join-Path $workspace 'cjc only'; $cjpmOnly = Join-Path $workspace 'cjpm only'
    New-Item -ItemType Directory -Path $cjcOnly,$cjpmOnly | Out-Null
    Copy-Item -LiteralPath $cjc -Destination (Join-Path $cjcOnly 'cjc.exe')
    Copy-Item -LiteralPath $cjpm -Destination (Join-Path $cjpmOnly 'cjpm.exe')
    $r = Run $binary @('doctor') $app @(1) 'missing-both-tools' $basePath
    Finding ($r.Stdout -match 'Cangjie SDK\s+ERROR.*not found' -and $r.Stdout -match 'CJPM\s+ERROR.*not found' -and (Same-State $r.Before $r.After)) 'Doctor reports both missing tools without metadata changes'
    $r = Run $binary @('doctor') $app @(1) 'missing-cjpm' ($cjcOnly+';'+$basePath)
    Finding ($r.Stdout -match 'Cangjie SDK\s+OK\s+1.0.5' -and $r.Stdout -match 'CJPM\s+ERROR.*not found') 'Doctor isolates missing CJPM while cjc starts'
    $r = Run $binary @('doctor') $app @(1) 'missing-cjc' ($cjpmOnly+';'+$basePath)
    Finding ($r.Stdout -match 'Cangjie SDK\s+ERROR.*not found' -and $r.Stdout -match 'CJPM\s+OK\s+1.0.5') 'Doctor isolates missing cjc while CJPM starts'
    # Observe official test discovery; do not infer that exit 0 means custom tests ran.
    $r = Run $cjpm @('test') $cjxRoot @(0,1)
    Finding ($r.Stdout.Contains('0 test') -or $r.Stdout.Contains('no test') -or $r.Stderr.Contains('no test')) 'Official test command reports no native test cases' 'Inspect actual discovery output separately'
    $setup.Add("Build exe SHA-256: old=$($oldBinary.Hash); new=$($newBinary.Hash); after cjpm test=$((State-File $binary).Hash)")
} catch {
    Finding $false 'Acceptance harness could not complete' $_.Exception.Message
} finally {
    $protectedAfter = @($protected | ForEach-Object { State-File $_ })
    Finding (Same-State $protectedBefore $protectedAfter) 'CJX and practice real TOML/lock hashes unchanged'
    $sourceAfter = @(Get-ChildItem (Join-Path $cjxRoot 'src') -Filter '*.cj' | Sort-Object Name | ForEach-Object { State-File $_.FullName })
    Finding (Same-State $sourceBefore $sourceAfter) 'Production source bytes unchanged'
    Finding ($userPathBefore -ceq [Environment]::GetEnvironmentVariable('PATH','User') -and $machinePathBefore -ceq [Environment]::GetEnvironmentVariable('PATH','Machine')) 'User and machine PATH unchanged'
    $summary = [pscustomobject]@{Workspace=$workspace;SdkRoot=$SdkRoot;InitialProcessTools=$initialProcessSdk;ProtectedBefore=$protectedBefore;ProtectedAfter=$protectedAfter;SourceBefore=$sourceBefore;SourceAfter=$sourceAfter;Findings=$findings.ToArray();Setup=$setup.ToArray();Commands=$records.ToArray()}
    [IO.File]::WriteAllText((Join-Path $auditOutput 'summary.json'),($summary | ConvertTo-Json -Depth 10),$encoding)
    $table = @('# Native command journal','','Each stdout/stderr file and JSON metadata snapshot is keyed by ID.','','| ID | cwd | mode | native command | exit |','|---|---|---|---|---|')
    foreach ($record in $records) { $table += '| '+$record.Id+' | '+$record.Cwd+' | '+$record.Mode+' | `'+$record.Executable+' '+($record.Arguments -join ' ')+'` | '+$record.Exit+' |' }
    [IO.File]::WriteAllText((Join-Path $auditOutput 'commands.md'),($table -join "`n"),$encoding)
    $absolute = [IO.Path]::GetFullPath($workspace)
    $allowed = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\CJX independent audit '
    if (!$absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup root' }
    if (Test-Path -LiteralPath $absolute) { Remove-Item -LiteralPath $absolute -Recurse -Force }
    Write-Output ("Acceptance assertions: PASS="+@($findings | Where-Object Status -eq 'PASS').Count+" FAIL="+@($findings | Where-Object Status -eq 'FAIL').Count)
    Write-Output "Evidence: $auditOutput"
}
