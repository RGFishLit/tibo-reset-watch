$ErrorActionPreference='Stop'
$src=Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
$scratch=Join-Path $PSScriptRoot ('popup-timeout-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $scratch
$ownedHelper=$null
try{
    foreach($name in @('TiboWatch.Core.psm1','TiboWatch.Platform.psm1')){[IO.File]::WriteAllBytes((Join-Path $scratch $name),[IO.File]::ReadAllBytes((Join-Path $src $name)))}
    $helper=@'
param([string]$MessageFile)
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class PopupConsoleProbe{[DllImport("kernel32.dll")]public static extern IntPtr GetConsoleWindow();}'
$process=[Diagnostics.Process]::GetCurrentProcess()
[IO.File]::WriteAllText(($MessageFile+'.pid'),(@{ProcessId=$PID;StartTicks=$process.StartTime.ToUniversalTime().Ticks;ConsoleWindow=[PopupConsoleProbe]::GetConsoleWindow().ToInt64()}|ConvertTo-Json))
Start-Sleep -Seconds 30
'@
    [IO.File]::WriteAllText((Join-Path $scratch 'Show-TiboPopup.ps1'),$helper,(New-Object Text.UTF8Encoding $true))
    Import-Module (Join-Path $scratch 'TiboWatch.Core.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $scratch 'TiboWatch.Platform.psm1') -Force -DisableNameChecking
    $event=[pscustomobject]@{Key='timeout';Tag='tibotest';Kind='post';Sticky=$true;Title='test';Text='reset';At='2026-10-26T06:00:00Z';Url='https://x.com/thsottiaux/status/2114588174249071102';RootUrl='https://x.com/thsottiaux/status/2114588174249071102'}
    $data=Join-Path $scratch 'data';$failed=$false
    try{$null=Show-TiboPersistentPopup $event $data -WaitMilliseconds 5000}catch{$failed=$true}
    if(!$failed){throw 'Slow helper unexpectedly acknowledged a visible window'}
    $pidFile=Join-Path $data 'popups\tibotest.json.pid'
    if(!(Test-Path -LiteralPath $pidFile)){throw 'Test helper never started; timeout test is inconclusive'}
    $identity=Get-Content -LiteralPath $pidFile -Raw|ConvertFrom-Json
    if($identity.ConsoleWindow -ne 0){throw 'Popup helper allocated a PowerShell console window'}
    $process=Get-Process -Id ([int]$identity.ProcessId) -ErrorAction SilentlyContinue
    if($process -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$identity.StartTicks){$ownedHelper=$process;throw 'Timed-out helper could show a late duplicate popup'}
    'PASS popup helper has no console and is terminated on timeout'
}finally{
    if($ownedHelper -and !$ownedHelper.HasExited){$ownedHelper.Kill();$null=$ownedHelper.WaitForExit(3000)}
    $prefix=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\popup-timeout-'
    $resolved=[IO.Path]::GetFullPath($scratch)
    if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing unsafe scratch cleanup'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
