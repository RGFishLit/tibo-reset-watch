param([string]$ScratchRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot '..'
$module=Join-Path $root 'scripts\TiboWatch.Platform.psm1'
if(!(Test-Path -LiteralPath $module)){throw 'FAIL: Windows integration, durable state and task registration are missing.'}
Import-Module (Join-Path $root 'scripts\TiboWatch.Core.psm1') -Force -DisableNameChecking
Import-Module $module -Force -DisableNameChecking
$scratch=Join-Path $ScratchRoot ('platform-test-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $scratch
try {
    $path=Join-Path $scratch 'state.json'
    $s=Read-TiboState $path
    if($s.BaselineComplete){throw 'fresh baseline is incorrectly complete'}
    $s.Seen=@('中文|https://x.com/thsottiaux/status/1'); Save-TiboState $s $path
    $loaded=Read-TiboState $path
    if($loaded.Seen[0] -cne $s.Seen[0]){throw 'UTF8 state did not round trip'}
    $s.Pending=@([pscustomobject]@{Key='pending'}); Save-TiboState $s $path
    if((Read-TiboState $path).Pending.Count -ne 1){throw 'atomic replacement lost pending notification'}
    [IO.File]::WriteAllText($path,'broken JSON')
    $rejected=$false; try{$null=Read-TiboState $path}catch{$rejected=$true}
    if(!$rejected){throw 'corrupt state silently reset history'}
    Write-Output 'PASS durable UTF8 state replacement and corrupt-state refusal'
    $xml=New-TiboTaskXml 'D:\Folder with spaces\scripts\TiboWatch.ps1' 'S-1-5-21-123' ([datetimeoffset]'2026-10-25T03:00:00Z') 'D:\Stable Data'
    $doc=[xml]$xml; $ns=New-Object Xml.XmlNamespaceManager $doc.NameTable; $ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    if($doc.SelectSingleNode('//t:Repetition/t:Interval',$ns).InnerText -ne 'PT30M'){throw 'wrong polling interval'}
    if($doc.SelectSingleNode('//t:LogonType',$ns).InnerText -ne 'InteractiveToken'){throw 'task could run without a desktop session'}
    if($doc.SelectSingleNode('//t:Arguments',$ns).InnerText -notmatch '-WindowStyle Hidden.*"D:\\Folder with spaces\\scripts\\TiboWatch.ps1"'){throw 'task script path is not safely quoted'}
    if($doc.SelectSingleNode('//t:LogonTrigger/t:UserId',$ns).InnerText -ne 'S-1-5-21-123'){throw 'wrong logon identity'}
    if($doc.SelectSingleNode('//t:Arguments',$ns).InnerText -notmatch '-DataDirectory "D:\\Stable Data"'){throw 'task did not pin its physical data directory'}
    Write-Output 'PASS 30-minute task XML with interactive identity and hidden quoted action'
    $retry=Get-TiboRetryTime '120' ([datetimeoffset]'2026-10-25T03:00:00Z')
    if([datetimeoffset]$retry -ne [datetimeoffset]'2026-10-25T03:02:00Z'){throw 'numeric retry-after incorrect'}
    $retry=Get-TiboRetryTime 'Sun, 25 Oct 2026 03:05:00 GMT' ([datetimeoffset]'2026-10-25T03:00:00Z')
    if([datetimeoffset]$retry -ne [datetimeoffset]'2026-10-25T03:05:00Z'){throw 'date retry-after incorrect'}
    Write-Output 'PASS numeric and HTTP-date retry-after parsing'
    $badAck=Join-Path $scratch 'bad-window.json'
    $process=[Diagnostics.Process]::GetCurrentProcess()
    [IO.File]::WriteAllText($badAck,(@{ProcessId=$PID;StartTicks=$process.StartTime.ToUniversalTime().Ticks;WindowHandle=0}|ConvertTo-Json))
    $active=& (Get-Module TiboWatch.Platform) {param($p)Get-TiboActivePopup $p} $badAck
    if($active){throw 'An alive process without a visible owned window was accepted as delivery'}
    Write-Output 'PASS popup acknowledgement requires a visible window owned by its process'
    $popups=Join-Path $scratch 'popups';$null=New-Item -ItemType Directory -Path $popups
    $event=[pscustomobject]@{Key='already-ack';Tag=(Get-TiboTag 'already-ack');Kind='post';Sticky=$true;Title='reset';Text='reset';At='2026-10-26T06:00:00Z';Url='https://x.com/thsottiaux/status/123'}
    $receipt=Join-Path $popups ($event.Tag+'.json.closed.json')
    [IO.File]::WriteAllText($receipt,(@{Closed=$true;Key=$event.Key}|ConvertTo-Json))
    $result=Show-TiboPersistentPopup $event $scratch
    if(!$result.Closed -or (Test-Path -LiteralPath (Join-Path $popups ($event.Tag+'.json')))){throw 'Acknowledged message was redisplayed on retry'}
    Remove-Item -LiteralPath $receipt;Remove-Item -LiteralPath $popups
    Write-Output 'PASS manual acknowledgement survives a retry without a duplicate popup'
    $helperPath=Join-Path $root 'scripts\Show-TiboPopup.ps1'
    $tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($helperPath,[ref]$tokens,[ref]$parseErrors)
    $call=$ast.Find({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Add_FormClosed'},$true)
    $handler=$call.Arguments[0].ScriptBlock.GetScriptBlock()
    $event=[pscustomobject]@{Key='callback';Tag='callback'};$MessageFile=Join-Path $scratch 'callback.json'
    & $handler $null ([pscustomobject]@{CloseReason='UserClosing'})
    $closedPath=$MessageFile+'.closed.json'
    if(!(Test-Path -LiteralPath $closedPath)){throw 'Actual FormClosed handler did not preserve manual acknowledgement'}
    if(!(Get-Content -LiteralPath $closedPath -Raw|ConvertFrom-Json).Closed){throw 'Manual acknowledgement was not recorded'}
    Write-Output 'PASS actual form-close callback persists manual acknowledgement'
    Write-Output 'RESULT: 6 platform tests passed'
} finally {
    # Only files created in this exact, verified scratch directory are removed.
    Get-ChildItem -LiteralPath $scratch -File | Remove-Item -Force
    Remove-Item -LiteralPath $scratch
}
