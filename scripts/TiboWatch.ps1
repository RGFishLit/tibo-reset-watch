[CmdletBinding()]
param(
    [ValidateSet('Enable','Pause','Status','Check','TestNotification','Uninstall')][string]$Action='Status',
    [string]$DataDirectory=(Join-Path $env:LOCALAPPDATA 'TiboResetWatch')
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'TiboWatch.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'TiboWatch.Platform.psm1') -Force -DisableNameChecking
$taskName='Codex-TiboResetWatch'
$statePath=Join-Path $DataDirectory 'state.json'
$configPath=Join-Path $DataDirectory 'config.json'
if (!(Test-Path -LiteralPath $DataDirectory)) { $null=New-Item -ItemType Directory -Path $DataDirectory -Force }

function Write-RunLog($Object) {
    $path=Join-Path $DataDirectory 'runs.jsonl'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 1048576) { Move-Item -LiteralPath $path -Destination ($path+'.1') -Force }
    [IO.File]::AppendAllText($path,($Object | ConvertTo-Json -Depth 8 -Compress)+[Environment]::NewLine,(New-Object Text.UTF8Encoding $false))
}

switch ($Action) {
    'Enable' {
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        Register-TiboToastIdentity
        $appId=Get-TiboAppId
        $config=@{AppId=$appId;IntervalMinutes=15;Version='1.0.0'}
        [IO.File]::WriteAllText($configPath,($config | ConvertTo-Json),(New-Object Text.UTF8Encoding $false))
        $xml=New-TiboTaskXml (Join-Path $PSScriptRoot 'TiboWatch.ps1') $identity.User.Value ([datetimeoffset]::Now) $DataDirectory
        $null=Register-ScheduledTask -TaskName $taskName -Xml $xml -Force
        Start-ScheduledTask -TaskName $taskName
        [pscustomobject]@{Enabled=$true;Task=$taskName;IntervalMinutes=15;Message='已启用；首次成功检查只建立基线。'} | ConvertTo-Json
    }
    'Pause' {
        $null=Disable-ScheduledTask -TaskName $taskName
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        [pscustomobject]@{Enabled=$false;Message='已暂停，通知历史保留。'} | ConvertTo-Json
    }
    'Status' {
        $s=Read-TiboState $statePath
        $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        $info=$null; if($task){$info=Get-ScheduledTaskInfo -TaskName $taskName}
        $notificationSetting='NotConfigured'
        if(Test-Path -LiteralPath $configPath){
            $cfg=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $null=[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]
            $null=[Windows.UI.Notifications.NotificationSetting,Windows.UI.Notifications,ContentType=WindowsRuntime]
            try{$notificationSetting=[string]([Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($cfg.AppId)).get_Setting()}catch{$notificationSetting='Unavailable: '+$_.Exception.Message}
        }
        [pscustomobject]@{
            Plugin='Tibo 额度重置提醒';Enabled=($null -ne $task -and $task.State -ne 'Disabled')
            TaskState=$(if($task){[string]$task.State}else{'NotInstalled'});IntervalMinutes=15
            BaselineComplete=$s.BaselineComplete;LastSuccessfulCheck=$s.LastSuccessfulCheck
            LastAttemptAt=$s.LastAttemptAt;LastRunOutcome=$s.LastRunOutcome;SourceGeneratedAt=$s.LastDataGeneratedAt
            PendingNotifications=@($s.Pending).Count;LastError=$s.LastError;LastNotificationError=$s.LastNotificationError
            RetryAfter=$s.NextAttemptAt;WindowsNotifications=$notificationSetting
            NextRun=$(if($info){$info.NextRunTime.ToString('o')}else{$null})
            LastTaskResult=$(if($info){$info.LastTaskResult}else{$null})
            Source='https://codex-resets.com/';DataDirectory=$DataDirectory
        } | ConvertTo-Json -Depth 6
    }
    'Check' {
        $mutex=New-Object Threading.Mutex($false,'Local\CodexTiboResetWatch')
        $owned=$false
        try {
            try {$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
            if(!$owned){ Write-Output '{"Skipped":"another check is running"}'; break }
            $s=Read-TiboState $statePath
            if(!(Test-Path -LiteralPath $configPath)){throw 'Run the installer or Enable first.'}
            $cfg=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $fetch={param($path,$query,$etag) Invoke-TiboRequest $path $query $etag}
            $notify={param($event) Show-TiboToast $event $cfg.AppId}
            $save={param($state) Save-TiboState $state $statePath}
            Invoke-TiboCycle -State $s -Fetch $fetch -Notify $notify -Save $save
            $result=[pscustomobject]@{At=$s.LastAttemptAt;Result=$s.LastRunOutcome;Pending=@($s.Pending).Count;Error=$s.LastError;NotificationError=$s.LastNotificationError}
            Write-RunLog $result
            $result | ConvertTo-Json
            if($s.LastRunOutcome -eq 'error' -or $s.LastNotificationError){exit 1}
        } catch {
            Write-RunLog @{At=[datetimeoffset]::UtcNow.ToString('o');Result='fatal';Error=$_.Exception.Message}
            throw
        } finally { if($owned){$mutex.ReleaseMutex()};$mutex.Dispose() }
    }
    'TestNotification' {
        if(!(Test-Path -LiteralPath $configPath)){throw 'Enable the watcher before testing notifications.'}
        $cfg=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $s=Read-TiboState $statePath
        $ev=$null
        if($s.CachedStatus){$ev=ConvertTo-TiboEvent (Get-TiboField (Get-TiboField $s.CachedStatus 'data') 'latest_reset') 'recorded' ([datetimeoffset]::UtcNow)}
        if(!$ev){$ev=[pscustomobject]@{Key='test';Tag='tibotest';Kind='system';Phase='test';Title='测试';Text='测试';At=[datetimeoffset]::UtcNow.ToString('o');Url='https://codex-resets.com/'}}
        $ev.Title='Tibo 提醒测试（不代表有新重置）';$ev.Text='通知测试：点击打开消息原帖。监测每 15 分钟运行。'
        $ev.Tag='tibotest'
        Show-TiboToast $ev $cfg.AppId
        [pscustomobject]@{SubmittedToWindows=$true;Tag=$ev.Tag;ClickTarget=$ev.Url;Message='测试通知已交给 Windows；是否弹出仍受系统通知设置影响。'} | ConvertTo-Json
    }
    'Uninstall' {
        $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if($task){Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
        Unregister-TiboToastIdentity
        [pscustomobject]@{TaskRemoved=$true;Message='后台任务已移除，历史状态保留。可在 Codex 插件设置中移除插件。';DataDirectory=$DataDirectory} | ConvertTo-Json
    }
}
