Set-StrictMode -Version 2.0

function Read-TiboState([string]$Path) {
    if (!(Test-Path -LiteralPath $Path)) { return New-TiboState }
    try { return ConvertTo-TiboState ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "Cannot read state; notification history was preserved. $($_.Exception.Message)" }
}

function Save-TiboState([hashtable]$State,[string]$Path) {
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        $json=ConvertTo-Json -InputObject $State -Depth 30
        [IO.File]::WriteAllText($temp,$json,(New-Object Text.UTF8Encoding $false))
        if ([IO.File]::Exists($Path)) { [IO.File]::WriteAllBytes($Path+'.bak',[IO.File]::ReadAllBytes($Path)) }
        # File.Replace merges EFS metadata and fails on MSIX encrypted AppData.
        # Same-directory MoveFileEx replaces the directory entry atomically instead.
        Initialize-TiboNativePaths
        if(![TiboWatch.NativePaths]::MoveFileEx($temp,$Path,9)){throw (New-Object ComponentModel.Win32Exception ([Runtime.InteropServices.Marshal]::GetLastWin32Error()))}
    } finally { if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)} }
}

function Get-TiboRetryTime([string]$Value,[datetimeoffset]$Now = [datetimeoffset]::UtcNow) {
    $seconds=0
    if ([int]::TryParse($Value,[ref]$seconds)) { return $Now.AddSeconds([Math]::Max(1,$seconds)).ToUniversalTime().ToString('o') }
    $date=[datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$date) -and $date -gt $Now) { return $date.ToUniversalTime().ToString('o') }
    return $Now.AddMinutes(5).ToUniversalTime().ToString('o')
}

function Invoke-TiboFxRequest([string]$Path,[hashtable]$Query) {
    if($Path -eq 'timeline'){$uri='https://api.fxtwitter.com/2/profile/thsottiaux/statuses'}
    elseif($Path -eq 'thread' -and [string]$Query.id -cmatch '^[0-9]{2,20}$'){$uri='https://api.fxtwitter.com/2/status/'+$Query.id}
    else{throw 'Unsupported FxEmbed request path or post ID.'}
    $parameters=@{};foreach($key in $Query.Keys){if($key -ne 'id'){$parameters[$key]=$Query[$key]}}
    $Query=$parameters
    if ($Query.Count) {
        $pairs=foreach($key in @($Query.Keys | Sort-Object)){[uri]::EscapeDataString($key)+'='+[uri]::EscapeDataString([string]$Query[$key])}
        $uri+='?'+($pairs -join '&')
    }
    $headers=@{Accept='application/json'}
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        $r=Invoke-WebRequest -Uri $uri -Headers $headers -UserAgent 'TiboResetWatch/1.1 (personal; 15 minute polling; github.com/RGFishLit/tibo-reset-watch)' -UseBasicParsing -TimeoutSec 20 -MaximumRedirection 0 -ErrorAction Stop
        return ($r.Content | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        $response=Get-TiboField $_.Exception 'Response'
        if ($null -ne $response -and [int]$response.StatusCode -eq 429) {
            $ex=New-Object System.Exception 'HTTP 429: the data source requested a pause.'
            $ex.Data['RetryAfterUtc']=Get-TiboRetryTime ([string]$response.Headers['Retry-After'])
            throw $ex
        }
        throw
    }
}

function Get-TiboAppId {
    return 'Codex.TiboResetWatch'
}

function Initialize-TiboNativePaths {
    if (!('TiboWatch.NativePaths' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace TiboWatch {
 public static class NativePaths {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern uint GetFinalPathNameByHandle(SafeFileHandle file, StringBuilder path, uint count, uint flags);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool MoveFileEx(string source, string destination, uint flags);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
 }
}
'@
    }
}

function Resolve-TiboPhysicalPath([string]$Path) {
    Initialize-TiboNativePaths
    $file=[IO.File]::OpenRead($Path)
    try {
        $buffer=New-Object Text.StringBuilder 32768
        $length=[TiboWatch.NativePaths]::GetFinalPathNameByHandle($file.SafeFileHandle,$buffer,32768,0)
        if($length -eq 0 -or $length -ge 32768){throw 'Unable to resolve physical runtime path.'}
        $resolved=$buffer.ToString()
        if($resolved.StartsWith('\\?\UNC\')){return '\\'+$resolved.Substring(8)}
        if($resolved.StartsWith('\\?\')){return $resolved.Substring(4)}
        return $resolved
    } finally {$file.Dispose()}
}

function Register-TiboToastIdentity {
    if(!('TiboWatch.ShortcutIdentity' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'ToastIdentity.cs')}
    $programs=[Environment]::GetFolderPath('Programs')
    $shortcut=Join-Path $programs 'Tibo Reset Watch.lnk'
    $key='HKCU:\Software\Classes\AppUserModelId\Codex.TiboResetWatch'
    $null=New-Item -Path $key -Force
    $null=New-ItemProperty -Path $key -Name DisplayName -Value 'Tibo 额度重置提醒' -PropertyType String -Force
    if(!(Test-Path -LiteralPath $shortcut)){
        $shell=New-Object -ComObject WScript.Shell
        try{
            $link=$shell.CreateShortcut($shortcut)
            $link.TargetPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $link.Arguments='-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'TiboWatch.ps1')+'" -Action Status'
            $link.Description='Tibo 额度重置提醒'
            $link.Save()
        }finally{if($shell){$null=[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}}
        [TiboWatch.ShortcutIdentity]::SetAppId($shortcut,'Codex.TiboResetWatch')
    }
}

function Get-TiboActivePopup([string]$AckFile) {
    if(!(Test-Path -LiteralPath $AckFile)){return $null}
    try{
        $ack=Get-Content -LiteralPath $AckFile -Raw -Encoding UTF8|ConvertFrom-Json
        $process=Get-Process -Id ([int]$ack.ProcessId) -ErrorAction Stop
        Initialize-TiboNativePaths
        $ownerId=[uint32]0;$handle=[intptr][long]$ack.WindowHandle
        $null=[TiboWatch.NativePaths]::GetWindowThreadProcessId($handle,[ref]$ownerId)
        if($process.StartTime.ToUniversalTime().Ticks -eq [long]$ack.StartTicks -and $ownerId -eq [uint32]$ack.ProcessId -and [TiboWatch.NativePaths]::IsWindowVisible($handle)){return $ack}
    }catch{}
    return $null
}

function Get-TiboClosedPopup([string]$Path,[string]$Key) {
    if(!(Test-Path -LiteralPath $Path)){return $null}
    try{$receipt=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json;if($receipt.Closed -eq $true -and $receipt.Key -ceq $Key){return $receipt}}catch{}
    return $null
}

function Show-TiboPersistentPopup($Event,[string]$DataDirectory,[ValidateRange(100,30000)][int]$WaitMilliseconds=15000) {
    if([string]$Event.Tag -cnotmatch '^(?:[a-f0-9]{16}|tibotest)$'){throw 'Unsafe popup tag.'}
    $null=New-TiboToastXml $Event
    $folder=Join-Path $DataDirectory 'popups';$null=New-Item -ItemType Directory -Path $folder -Force
    $message=Join-Path $folder ($Event.Tag+'.json');$ackPath=$message+'.shown.json';$closedPath=$message+'.closed.json'
    $ack=Get-TiboActivePopup $ackPath;if($ack){return $ack}
    if($Event.Tag -cne 'tibotest'){$closed=Get-TiboClosedPopup $closedPath $Event.Key;if($closed){return $closed}}
    elseif(Test-Path -LiteralPath $closedPath){Remove-Item -LiteralPath $closedPath -Force}
    [IO.File]::WriteAllText($message,($Event|ConvertTo-Json -Depth 12),(New-Object Text.UTF8Encoding $false))
    $helper=Join-Path $PSScriptRoot 'Show-TiboPopup.ps1'
    $arguments='-NoLogo -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$helper+'" -MessageFile "'+$message+'"'
    $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while($clock.ElapsedMilliseconds -lt $WaitMilliseconds){
        $ack=Get-TiboActivePopup $ackPath;if($ack){return $ack}
        $closed=Get-TiboClosedPopup $closedPath $Event.Key;if($closed){return $closed}
        if($process.HasExited){$closed=Get-TiboClosedPopup $closedPath $Event.Key;if($closed){return $closed};throw 'Persistent popup process exited before showing its window.'}
        Start-Sleep -Milliseconds 100
    }
    $ack=Get-TiboActivePopup $ackPath;if($ack){return $ack}
    $closed=Get-TiboClosedPopup $closedPath $Event.Key;if($closed){return $closed}
    # Failure must not leave our cold-starting child able to display a late popup.
    if(!$process.HasExited){$process.Kill();$null=$process.WaitForExit(3000)}
    throw 'Persistent popup did not acknowledge a visible window; notification remains queued.'
}

function Close-TiboPersistentPopups([string]$DataDirectory) {
    $folder=Join-Path $DataDirectory 'popups';if(!(Test-Path -LiteralPath $folder)){return}
    foreach($file in Get-ChildItem -LiteralPath $folder -Filter '*.shown.json' -File){
        $ack=Get-TiboActivePopup $file.FullName
        if($ack){$process=Get-Process -Id ([int]$ack.ProcessId) -ErrorAction SilentlyContinue;if($process){$null=$process.CloseMainWindow()}}
    }
}

function Show-TiboToast($Event,[string]$AppId,[string]$DataDirectory=(Join-Path $env:LOCALAPPDATA 'TiboResetWatch')) {
    Register-TiboToastIdentity
    $null=[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]
    $null=[Windows.UI.Notifications.NotificationSetting,Windows.UI.Notifications,ContentType=WindowsRuntime]
    $null=[Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom.XmlDocument,ContentType=WindowsRuntime]
    $notifier=[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId)
    # Windows creates the notification permission record on the first Show.
    $setting='Uninitialized'
    try{$setting=[string]$notifier.get_Setting()}catch{if($_.Exception.GetBaseException().HResult -ne -2147023728){throw}}
    if($setting -notin @('Enabled','Uninitialized')){throw "Windows notifications are disabled: $setting. Enable Tibo Reset Watch notifications in Windows settings."}
    $xml=New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml((New-TiboToastXml $Event))
    $toast=[Windows.UI.Notifications.ToastNotification]::new($xml)
    $toast.Tag=[string]$Event.Tag; $toast.Group='TiboResetWatch'
    if(Get-TiboField $Event 'Sticky'){$toast.SuppressPopup=$true}
    if(!(Get-TiboField $Event 'Sticky')){$toast.ExpirationTime=[datetimeoffset]::UtcNow.AddDays(3)}
    $notifier.Show($toast)
    if([string]$notifier.get_Setting() -ne 'Enabled'){throw 'Windows did not enable notification delivery.'}
    if(Get-TiboField $Event 'Sticky'){$null=Show-TiboPersistentPopup $Event $DataDirectory}
}

function Unregister-TiboToastIdentity {
    $programs=[Environment]::GetFolderPath('Programs')
    $shortcut=Join-Path $programs 'Tibo Reset Watch.lnk'
    if(Test-Path -LiteralPath $shortcut){
        $shell=New-Object -ComObject Shell.Application
        try{
            $item=$shell.NameSpace($programs).ParseName('Tibo Reset Watch.lnk')
            if($item.ExtendedProperty('System.AppUserModel.ID') -ceq 'Codex.TiboResetWatch'){Remove-Item -LiteralPath $shortcut -Force}
        }finally{if($shell){$null=[Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}}
    }
    $key='HKCU:\Software\Classes\AppUserModelId\Codex.TiboResetWatch'
    if(Test-Path -LiteralPath $key){Remove-Item -LiteralPath $key -Force}
}

function New-TiboTaskXml([string]$ScriptPath,[string]$UserSid,[datetimeoffset]$Now = [datetimeoffset]::Now,[string]$DataDirectory=(Join-Path $env:LOCALAPPDATA 'TiboResetWatch')) {
    $command=[Security.SecurityElement]::Escape((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    $arguments=[Security.SecurityElement]::Escape('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$ScriptPath+'" -Action Check -DataDirectory "'+$DataDirectory+'"')
    $sid=[Security.SecurityElement]::Escape($UserSid)
    $start=$Now.ToString('yyyy-MM-ddTHH:mm:sszzz')
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
 <RegistrationInfo><Description>Tibo 额度重置提醒：每 15 分钟检查本人发帖和回复；主帖命中关键词才常驻提醒。</Description></RegistrationInfo>
 <Triggers>
  <TimeTrigger><Repetition><Interval>PT15M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition><StartBoundary>$start</StartBoundary><Enabled>true</Enabled></TimeTrigger>
  <LogonTrigger><Enabled>true</Enabled><UserId>$sid</UserId><Delay>PT15S</Delay></LogonTrigger>
 </Triggers>
 <Principals><Principal id="User"><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
 <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable><RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>true</Hidden><WakeToRun>false</WakeToRun><ExecutionTimeLimit>PT4M</ExecutionTimeLimit><Priority>7</Priority></Settings>
 <Actions Context="User"><Exec><Command>$command</Command><Arguments>$arguments</Arguments></Exec></Actions>
</Task>
"@
}

Export-ModuleMember -Function Read-TiboState,Save-TiboState,Get-TiboRetryTime,Invoke-TiboFxRequest,Get-TiboAppId,Show-TiboToast,Show-TiboPersistentPopup,Close-TiboPersistentPopups,New-TiboTaskXml,Resolve-TiboPhysicalPath,Register-TiboToastIdentity,Unregister-TiboToastIdentity
