[CmdletBinding()]
param([ValidateSet('Enable','Pause','Status','Check','TestNotification','Uninstall')][string]$Action='Status')
$ErrorActionPreference='Stop'
$locationPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'install-location.json'
if(!(Test-Path -LiteralPath $locationPath)){throw 'Install this package first using Install-TiboResetWatch.ps1.'}
$location=Get-Content -LiteralPath $locationPath -Raw -Encoding UTF8 | ConvertFrom-Json
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $location.ScriptPath -Action $Action -DataDirectory $location.DataDirectory
exit $LASTEXITCODE
