$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\TiboWatch.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'scripts\TiboWatch.Platform.psm1') -Force -DisableNameChecking
if(!(Get-Command Install-TiboHiddenLauncher -ErrorAction SilentlyContinue)){throw 'FAIL: a GUI-subsystem launcher that forbids console allocation is missing.'}
$scratch=Join-Path $PSScriptRoot ('headless-test-'+[guid]::NewGuid().ToString('N'))
$data=Join-Path $scratch 'data with spaces 中文'
$null=New-Item -ItemType Directory -Path $data -Force
try{
    $exe=Install-TiboHiddenLauncher $scratch
    $reader=New-Object IO.BinaryReader ([IO.File]::OpenRead($exe))
    try{$reader.BaseStream.Position=0x3c;$offset=$reader.ReadInt32();$reader.BaseStream.Position=$offset+4+20+68;$subsystem=$reader.ReadUInt16()}finally{$reader.Dispose()}
    if($subsystem -ne 2){throw 'Launcher is a console executable, not Windows GUI subsystem'}
    'PASS launcher is a GUI executable'
    $script=@'
param([string]$Action,[string]$DataDirectory)
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class HeadlessProbe{[DllImport("kernel32.dll")]public static extern IntPtr GetConsoleWindow();}'
$result=@{Action=$Action;DataDirectory=$DataDirectory;ConsoleWindow=[HeadlessProbe]::GetConsoleWindow().ToInt64()}
[IO.File]::WriteAllText((Join-Path $DataDirectory 'result.json'),($result|ConvertTo-Json))
'@
    [IO.File]::WriteAllText((Join-Path $scratch 'TiboWatch.ps1'),$script,(New-Object Text.UTF8Encoding $true))
    $process=Start-Process -FilePath $exe -ArgumentList ('"'+$data+'" Check') -WindowStyle Hidden -PassThru
    if(!$process.WaitForExit(20000)){$process.Kill();throw 'No-console launcher did not finish'}
    if($process.ExitCode -ne 0){throw 'No-console launcher returned failure'}
    $result=Get-Content -LiteralPath (Join-Path $data 'result.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if($result.ConsoleWindow -ne 0){throw 'Child PowerShell still allocated a console window'}
    if($result.Action -ne 'Check' -or $result.DataDirectory -cne $data){throw 'Launcher lost quoted or Unicode arguments'}
    'PASS child PowerShell has no console and receives quoted Unicode paths'
}finally{
    $prefix=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\headless-test-'
    $resolved=[IO.Path]::GetFullPath($scratch)
    if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing unsafe test cleanup'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
