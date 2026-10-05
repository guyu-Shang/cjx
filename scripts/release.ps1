#requires -Version 7.0
param([string]$PracticeRoot = '')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$shell=(Get-Process -Id $PID).Path
$id=[Guid]::NewGuid().ToString('N')
$stage=Join-Path $root ('.cjx-release-'+$id)
$dist=Join-Path $root 'dist'
$evidence=Join-Path $root ('docs\release-evidence\'+$id)
$utf8=[Text.UTF8Encoding]::new($false)
$records=[Collections.Generic.List[object]]::new()
$code=1
$hash=''
function Native([string]$name,[string]$exe,[string[]]$argv) {
    Write-Host "[$name] $exe $($argv -join ' ')"
    $p=[Diagnostics.ProcessStartInfo]::new()
    $p.FileName=$exe;$p.WorkingDirectory=$root;$p.UseShellExecute=$false;$p.CreateNoWindow=$true
    $p.RedirectStandardOutput=$true;$p.RedirectStandardError=$true
    $p.StandardOutputEncoding=$utf8;$p.StandardErrorEncoding=$utf8
    $p.Environment['PATH']=$env:PATH
    $launch=$argv
    if($exe -eq $shell) {
        $text="[Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false); `$OutputEncoding=[Console]::OutputEncoding; `$ErrorActionPreference='Stop'; & "
        for($i=2;$i -lt $argv.Count;$i++) {
            if($i -gt 2 -and $argv[$i] -match '^-[A-Za-z]+$'){$text+=$argv[$i]+' '}
            else{$text+="'"+$argv[$i].Replace("'","''")+"' "}
        }
        $text+='; if (-not $?) { exit 1 }; exit 0'
        $launch=@('-NoProfile','-OutputFormat','Text','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($text)))
    }
    foreach($arg in $launch){$p.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$p
    $out='';$err='';$exit=-1
    try {
        [void]$process.Start()
        $o=$process.StandardOutput.ReadToEndAsync();$e=$process.StandardError.ReadToEndAsync()
        if(!$process.WaitForExit(600000)){$process.Kill($true);$process.WaitForExit();throw "$name timed out"}
        $out=$o.GetAwaiter().GetResult();$err=$e.GetAwaiter().GetResult();$exit=$process.ExitCode
    } finally {
        $records.Add([pscustomobject]@{Name=$name;Executable=$exe;Arguments=$argv;LaunchArguments=$launch;Exit=$exit;Stdout=$out;Stderr=$err})
        $process.Dispose()
    }
    Write-Host $out;if($err){Write-Host $err}
    if($exit -ne 0){throw "$name failed (exit $exit); release stopped"}
    return $out
}
try {
    if(Test-Path -LiteralPath $dist){throw 'dist already exists. Move the previous local artifacts elsewhere before rerunning; nothing will be overwritten.'}
    foreach($name in @('cjc','cjpm')) {
        $tool=Get-Command $name -CommandType Application -ErrorAction SilentlyContinue
        if(!$tool){throw "$name not found. Load the installed SDK envsetup.ps1 first; release does not change system PATH."}
        Set-Variable -Name ($name+'Exe') -Value $tool.Source
        $null=Native $name $tool.Source @('--version')
    }
    $argv=@('-NoProfile','-File',(Join-Path $root 'tests\verify.ps1'))
    if($PracticeRoot){$argv+=@('-PracticeRoot',$PracticeRoot)}
    $null=Native 'Verification Gate' $shell $argv
    $gateDir=Get-ChildItem -LiteralPath (Join-Path $root 'target\verification') -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $gate=Get-Content -LiteralPath (Join-Path $gateDir.FullName 'summary.json') -Raw | ConvertFrom-Json
    if($gate.Result -ne 'PASS' -or $gate.Exit -ne 0){throw 'Verification evidence is not PASS'}
    New-Item -ItemType Directory -Path $evidence -Force | Out-Null
    # Archive gate evidence before the release clean; never include project snapshots in dist.
    Copy-Item -LiteralPath (Join-Path $gateDir.FullName 'summary.json') -Destination (Join-Path $evidence 'verification.json')
    $null=Native 'Release clean' $cjpmExe @('clean')
    $null=Native 'Release build' $cjpmExe @('build','-o','cjx')
    $exe=Join-Path $root 'target\release\bin\cjx.exe'
    if(!(Test-Path -LiteralPath $exe -PathType Leaf)){throw 'Official build -o cjx did not create cjx.exe'}
    New-Item -ItemType Directory -Path $stage | Out-Null
    Copy-Item -LiteralPath $exe -Destination (Join-Path $stage 'cjx.exe')
    Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination (Join-Path $stage 'README.md')
    if(Test-Path -LiteralPath (Join-Path $root 'LICENSE') -PathType Leaf){
        Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $stage 'LICENSE')
    } else { Write-Host 'Warning: no LICENSE; the project owner must decide before public open-source release.' }
    $hash=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    if((Get-FileHash -LiteralPath (Join-Path $stage 'cjx.exe') -Algorithm SHA256).Hash -cne $hash){throw 'Copied executable hash mismatch'}
    [IO.File]::WriteAllText((Join-Path $stage 'SHA256SUMS.txt'),($hash+'  cjx.exe'+"`n"),$utf8)
    $null=Native 'Packaged artifact smoke' $shell @('-NoProfile','-File',(Join-Path $root 'tests\smoke.ps1'),'-Binary',(Join-Path $stage 'cjx.exe'))
    if((Get-FileHash -LiteralPath (Join-Path $stage 'cjx.exe') -Algorithm SHA256).Hash -cne $hash){throw 'Artifact changed during smoke validation'}
    foreach($path in @($stage,$dist)) {
        if([IO.Path]::GetFullPath($path).TrimEnd('\') -cne (Join-Path ([IO.Path]::GetFullPath($root)) ([IO.Path]::GetFileName($path)))){throw 'Unsafe local artifact move path'}
    }
    Move-Item -LiteralPath $stage -Destination $dist
    $code=0
    Write-Host "Local artifacts: $dist`ncjx.exe SHA-256: $hash`nRelease preparation: PASS (no upload/tag/push)"
} catch {Write-Host "Error: $($_.Exception.Message)`nRelease preparation: FAIL"}
finally {
    if(Test-Path -LiteralPath $stage) {
        $absolute=[IO.Path]::GetFullPath($stage)
        if(!$absolute.StartsWith([IO.Path]::GetFullPath($root).TrimEnd('\')+'\.cjx-release-',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe release staging cleanup path'}
        Remove-Item -LiteralPath $absolute -Recurse -Force
    }
    New-Item -ItemType Directory -Path $evidence -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $evidence 'release.json'),([pscustomobject]@{Exit=$code;Dist=$dist;SHA256=$hash;Commands=$records.ToArray()} | ConvertTo-Json -Depth 8),$utf8)
    Write-Host "Release evidence: $evidence"
}
exit $code
