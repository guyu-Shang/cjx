#requires -Version 7.0
param([string]$PracticeRoot = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$shell = (Get-Process -Id $PID).Path
$binary = Join-Path $root 'target\release\bin\main.exe'
$work = Join-Path ([IO.Path]::GetTempPath()) ('cjx-verify-' + [Guid]::NewGuid().ToString('N'))
$logRoot = Join-Path $root ('target\verification\' + [Guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
$records = [Collections.Generic.List[object]]::new()
$stages = [Collections.Generic.List[object]]::new()
$total = 0
$exitCode = 1
$protected = @((Join-Path $root 'cjpm.toml'),(Join-Path $root 'cjpm.lock'))
if ($PracticeRoot) {
    $PracticeRoot = (Resolve-Path -LiteralPath $PracticeRoot -ErrorAction Stop).Path
    $protected += @((Join-Path $PracticeRoot 'cjpm.toml'),(Join-Path $PracticeRoot 'cjpm.lock'))
}
function Snapshot([string[]]$paths) {
    @($paths | ForEach-Object {
        $present = Test-Path -LiteralPath $_
        [pscustomobject]@{Path=$_;Present=$present;Bytes=if($present){[Convert]::ToBase64String([IO.File]::ReadAllBytes($_))}else{''};SHA256=if($present){(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}else{'absent'}}
    })
}
$before = Snapshot $protected
$sourcePaths = @(Get-ChildItem (Join-Path $root 'src') -Filter '*.cj' | Sort-Object Name | ForEach-Object FullName)
$sourceBefore = Snapshot $sourcePaths
$userPath = [Environment]::GetEnvironmentVariable('PATH','User')
$machinePath = [Environment]::GetEnvironmentVariable('PATH','Machine')
function Stage([string]$name, [string]$status, [string]$detail='') {
    $stages.Add([pscustomobject]@{Name=$name;Status=$status;Detail=$detail})
}
function Native([string]$name,[string]$exe,[string[]]$argv,[string]$cwd=$root) {
    Write-Host "`n[$name] $exe $($argv -join ' ')"
    $p = [Diagnostics.ProcessStartInfo]::new()
    $p.FileName=$exe; $p.WorkingDirectory=$cwd
    $p.UseShellExecute=$false; $p.CreateNoWindow=$true
    $p.RedirectStandardOutput=$true; $p.RedirectStandardError=$true
    $p.StandardOutputEncoding=$utf8; $p.StandardErrorEncoding=$utf8
    $launchArgs=$argv
    if($exe -eq $shell -and $argv[1] -eq '-File') {
        # Native CJX output is UTF-8; a redirected PowerShell can otherwise decode it as an OEM code page.
        $command = "[Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false); `$OutputEncoding=[Console]::OutputEncoding; `$ErrorActionPreference='Stop'; & "
        for($i=2;$i -lt $argv.Count;$i++) {
            if($i -gt 2 -and $argv[$i] -match '^-[A-Za-z]+$'){$command += $argv[$i]+' '}
            else{$command += "'"+$argv[$i].Replace("'","''")+"' "}
        }
        $command += '; if (-not $?) { exit 1 }; exit 0'
        $launchArgs=@('-NoProfile','-OutputFormat','Text','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
    }
    foreach($arg in $launchArgs){$p.ArgumentList.Add($arg)}
    # Pass the shell's effective PATH explicitly: some launchers provide both Path and PATH.
    $p.Environment['PATH']=$env:PATH
    # Every child test owns temporary files under this run, including its compiler subprocesses.
    $p.Environment['TEMP']=$work; $p.Environment['TMP']=$work
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$p
    $out='';$err='';$code=-1
    try {
        [void]$process.Start()
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(300000)) { $process.Kill($true); $process.WaitForExit(); throw "$name timed out after 300 seconds" }
        $out=$stdout.GetAwaiter().GetResult(); $err=$stderr.GetAwaiter().GetResult(); $code=$process.ExitCode
    } finally {
        $records.Add([pscustomobject]@{Name=$name;Executable=$exe;Arguments=$argv;LaunchArguments=$launchArgs;Cwd=$cwd;Exit=$code;Stdout=$out;Stderr=$err})
        $process.Dispose()
    }
    Write-Host $out
    if($err){Write-Host $err}
    if($code -ne 0){Stage $name 'FAIL' "exit $code"; throw "$name failed (exit $code)"}
    return $out
}
function Same-Snapshots($a,$b) {
    if($a.Count -ne $b.Count){return $false}
    for($i=0;$i -lt $a.Count;$i++){
        if($a[$i].Path -cne $b[$i].Path -or $a[$i].Present -ne $b[$i].Present -or $a[$i].Bytes -cne $b[$i].Bytes){return $false}
    }
    return $true
}
try {
    New-Item -ItemType Directory -Path $work | Out-Null
    foreach($name in @('cjc','cjpm')) {
        $tool=Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
        if(!$tool){Stage $name 'FAIL' 'not found'; throw "$name was not found. Load your installed SDK first: . '<SDK directory>\envsetup.ps1'. System PATH will not be changed."}
        Set-Variable -Name ($name+'Exe') -Value $tool.Source
    }
    $v=Native 'Cangjie SDK' $cjcExe @('--version')
    $version=[regex]::Match($v,'\b\d+\.\d+\.\d+\b').Value
    if(!$version){throw 'Could not identify Cangjie SDK version'}
    Stage 'Cangjie SDK' 'PASS' $version
    $v=Native 'CJPM' $cjpmExe @('--version')
    $pmVersion=[regex]::Match($v,'\b\d+\.\d+\.\d+\b').Value
    if(!$pmVersion){throw 'Could not identify CJPM version'}
    Stage 'CJPM' 'PASS' $pmVersion
    if($version -ne '1.0.5' -or $pmVersion -ne '1.0.5'){Stage 'Tested scope' 'WARN' 'This run is outside the independently accepted SDK/CJPM 1.0.5 scope'}
    $null=Native 'Clean' $cjpmExe @('clean')
    if(Test-Path -LiteralPath $binary){throw 'Clean left the previous executable behind'}
    $null=Native 'Build' $cjpmExe @('build')
    if(!(Test-Path -LiteralPath $binary -PathType Leaf)){throw 'Build did not produce target\release\bin\main.exe'}
    Stage 'Clean build' 'PASS'
    $manifest=[IO.File]::ReadAllText((Join-Path $root 'cjpm.toml'))
    $package=[regex]::Match($manifest,'(?ms)^\[package\]\r?\n(.*?)(?=^\[|\z)')
    $declared=[regex]::Matches($package.Groups[1].Value,'(?m)^\s*version\s*=\s*"([^"]+)"\s*$')
    if($declared.Count -ne 1){throw 'Cannot identify a unique package version in cjpm.toml'}
    $reported=Native 'CJX version consistency' $binary @('--version')
    if($reported.Trim() -cne ('CJX '+$declared[0].Groups[1].Value)){throw 'CLI version differs from cjpm.toml package version'}
    Stage 'CJX version consistency' 'PASS' $declared[0].Groups[1].Value
    foreach($script in @('run.ps1','doctor.ps1','add_cli.ps1','update_cli.ps1','remove_cli.ps1','remove_write_cli.ps1','dry_run.ps1')) {
        $argv=@('-NoProfile','-File',(Join-Path $PSScriptRoot $script))
        if($PracticeRoot -and $script -in @('doctor.ps1','remove_cli.ps1','dry_run.ps1')){$argv+=@('-PracticeRoot',$PracticeRoot)}
        $output=Native $script $shell $argv
        if($output -match '(?m)^FAIL\b' -or $output -match '(?m)^(?:Remove (?:planner|CLI) tests: )?\d+\b[^\r\n]*\bpassed[,;]\s*[1-9]\d* failed\b'){throw "$script reported failed tests"}
        $count=0
        foreach($line in ($output -split '\r?\n')) {
            if($line -match '^(?:Remove (?:planner|CLI) tests: )?(\d+)\b.*\bpassed\b'){$count += [int]$Matches[1]}
            elseif($script -in @('doctor.ps1','dry_run.ps1') -and $line -match '^PASS CLI '){$count++}
        }
        if($count -le 0){throw "$script executed zero recognized test cases"}
        $total+=$count
        Stage $script 'PASS' "$count test cases (runner output)"
    }
    Stage 'Custom tests' 'PASS' "$total test cases; metadata hash checks counted separately, not as extra cases"
    $official=Native 'cjpm test observation' $cjpmExe @('test')
    $found=[regex]::Match($official,'Summary:\s*TOTAL:\s*(\d+)')
    if(!$found.Success){throw 'Official cjpm test discovery count is missing'}
    Stage 'cjpm test discovery' 'INFO' "$($found.Groups[1].Value) cases; not the custom test entry"
    $smoke=Native 'Black-box smoke' $shell @('-NoProfile','-File',(Join-Path $PSScriptRoot 'smoke.ps1'),'-Binary',$binary)
    foreach($name in @('CLI smoke','Integration','Rollback')) {
        if(!$smoke.Contains("GATE $name PASS")){throw "Missing successful $name marker"}
        Stage $name 'PASS'
    }
    $exitCode=0
} catch {
    Stage 'Verification' 'FAIL' $_.Exception.Message
    Write-Host "Error: $($_.Exception.Message)"
} finally {
    try {
        $after=Snapshot $protected
        if(!(Same-Snapshots $before $after)){throw 'Protected CJX/practice TOML or lock bytes changed'}
        if(!(Same-Snapshots $sourceBefore (Snapshot $sourcePaths))){throw 'Production source changed'}
        if($userPath -cne [Environment]::GetEnvironmentVariable('PATH','User') -or $machinePath -cne [Environment]::GetEnvironmentVariable('PATH','Machine')){throw 'System/user PATH changed'}
        Stage 'Protected files/environment' 'PASS'
    } catch {Stage 'Protected files/environment' 'FAIL' $_.Exception.Message; $exitCode=1}
    try {
        if(Test-Path -LiteralPath $work) {
            $leftovers=@(Get-ChildItem -LiteralPath $work -Force)
            if($leftovers.Count){Stage 'Runner cleanup' 'FAIL' ($leftovers.Name -join ', ');$exitCode=1}
            $absolute=[IO.Path]::GetFullPath($work)
            $allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\cjx-verify-'
            if(!$absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe verification cleanup path'}
            Remove-Item -LiteralPath $absolute -Recurse -Force
        }
        Stage 'Temporary cleanup' 'PASS' 'owned workspace removed'
    } catch {Stage 'Temporary cleanup' 'FAIL' $_.Exception.Message;$exitCode=1}
    $result=if($exitCode -eq 0){'PASS'}else{'FAIL'}
    Write-Host "`nCJX V0.1 Verification`n--------------------------------"
    foreach($s in $stages){Write-Host ('{0,-29} {1,-5} {2}' -f $s.Name,$s.Status,$s.Detail)}
    Write-Host "RESULT: $result"
    try {
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
        $summary=[pscustomobject]@{Result=$result;Exit=$exitCode;CustomTestCases=$total;TemporaryRoot=$work;TemporaryRemoved=!(Test-Path -LiteralPath $work);Stages=$stages.ToArray();Before=$before;After=$after;Commands=$records.ToArray()}
        [IO.File]::WriteAllText((Join-Path $logRoot 'summary.json'),($summary | ConvertTo-Json -Depth 8),$utf8)
        foreach($r in $records){[IO.File]::WriteAllText((Join-Path $logRoot ($r.Name.Replace(' ','-')+'.log')),($r.Stdout+"`nSTDERR:`n"+$r.Stderr),$utf8)}
        Write-Host "Evidence: $logRoot"
    } catch {Write-Host "Error: could not save verification evidence: $($_.Exception.Message)";$exitCode=1;Write-Host 'RESULT: FAIL'}
}
exit $exitCode
