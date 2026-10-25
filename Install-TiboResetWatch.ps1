[CmdletBinding()]
param([switch]$SkipPluginRegistration)
$ErrorActionPreference='Stop'
$packageRoot=$PSScriptRoot
if(!(Test-Path -LiteralPath (Join-Path $packageRoot '.codex-plugin\plugin.json'))){$packageRoot=Join-Path $PSScriptRoot 'tibo-reset-watch'}
if(!(Test-Path -LiteralPath (Join-Path $packageRoot '.codex-plugin\plugin.json'))){throw 'Keep this installer beside the extracted tibo-reset-watch folder, or run the installer inside that folder.'}
$dataRoot=Join-Path $env:LOCALAPPDATA 'TiboResetWatch'
$runtime=Join-Path $dataRoot 'runtime'
$marketRoot=Join-Path $env:USERPROFILE 'Documents\Codex\plugin-marketplaces\tibo-reset-local'
$pluginTarget=Join-Path $marketRoot 'plugins\tibo-reset-watch'
$null=New-Item -ItemType Directory -Path $runtime,$pluginTarget,(Join-Path $marketRoot '.agents\plugins') -Force

function Copy-PackageFiles([string]$Source,[string]$Destination) {
    $sourcePath=[IO.Path]::GetFullPath($Source).TrimEnd('\')
    foreach($file in Get-ChildItem -LiteralPath $sourcePath -Recurse -File){
        $relative=$file.FullName.Substring($sourcePath.Length+1)
        $target=Join-Path $Destination $relative
        $null=New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
        # Write plaintext bytes, so EFS attributes from another checkout are not inherited.
        [IO.File]::WriteAllBytes($target,[IO.File]::ReadAllBytes($file.FullName))
    }
}

# Stop only this watcher's existing run before replacing its runtime.
$oldTask=Get-ScheduledTask -TaskName 'Codex-TiboResetWatch' -ErrorAction SilentlyContinue
if($oldTask){Stop-ScheduledTask -TaskName 'Codex-TiboResetWatch' -ErrorAction SilentlyContinue}
Copy-PackageFiles (Join-Path $packageRoot 'scripts') (Join-Path $runtime 'scripts')
Copy-PackageFiles $packageRoot $pluginTarget
Import-Module (Join-Path $packageRoot 'scripts\TiboWatch.Platform.psm1') -Force -DisableNameChecking
$physicalScript=Resolve-TiboPhysicalPath (Join-Path $runtime 'scripts\TiboWatch.ps1')
$dataRoot=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $physicalScript))
$location=@{DataDirectory=$dataRoot;ScriptPath=$physicalScript}
[IO.File]::WriteAllText((Join-Path $pluginTarget 'install-location.json'),($location | ConvertTo-Json),(New-Object Text.UTF8Encoding $false))
$market=@{name='tibo-reset-local';interface=@{displayName='Tibo 提醒（本地）'};plugins=@(@{name='tibo-reset-watch';source=@{source='local';path='./plugins/tibo-reset-watch'};policy=@{installation='AVAILABLE';authentication='ON_INSTALL'};category='Productivity'})}
[IO.File]::WriteAllText((Join-Path $marketRoot '.agents\plugins\marketplace.json'),($market | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding $false))

if(!$SkipPluginRegistration){
    $codex=Get-Command codex -ErrorAction Stop
    $sourcesText= & $codex plugin marketplace list --json
    if($LASTEXITCODE -ne 0){throw 'Unable to inspect Codex marketplaces.'}
    $sources=($sourcesText -join [Environment]::NewLine) | ConvertFrom-Json
    $existing=@($sources.marketplaces | Where-Object {$_.name -eq 'tibo-reset-local'})
    if($existing.Count -eq 0){
        & $codex plugin marketplace add $marketRoot --json
        if($LASTEXITCODE -ne 0){throw 'Unable to register the local Codex marketplace.'}
    } elseif([IO.Path]::GetFullPath($existing[0].root).TrimEnd('\') -ine [IO.Path]::GetFullPath($marketRoot).TrimEnd('\')) {
        throw 'A different marketplace already uses tibo-reset-local. Existing configuration was preserved.'
    }
    & $codex plugin add 'tibo-reset-watch@tibo-reset-local' --json
    if($LASTEXITCODE -ne 0){throw 'Unable to install the Codex plugin.'}
}
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $physicalScript -Action Enable -DataDirectory $dataRoot
if($LASTEXITCODE -ne 0){throw 'Unable to enable the scheduled watcher.'}
Write-Output '安装完成。首次检查只建立基线；在 Codex 新聊天中使用 Tibo 额度重置提醒。'
