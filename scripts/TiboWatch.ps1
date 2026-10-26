[CmdletBinding()]
param(
    [ValidateSet('Enable','Pause','Status','Check','TestNotification','Uninstall')][string]$Action='Status',
    [string]$DataDirectory=(Join-Path $env:LOCALAPPDATA 'TiboResetWatch')
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'TiboWatch.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'TiboWatch.Platform.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'TiboWatch.Threads.psm1') -Force -DisableNameChecking
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
        $null=Install-TiboHiddenLauncher
        Register-TiboToastIdentity
        $appId=Get-TiboAppId
        $config=@{AppId=$appId;IntervalMinutes=30;Version='1.1.2';Source='FxEmbed-v2'}
        [IO.File]::WriteAllText($configPath,($config | ConvertTo-Json),(New-Object Text.UTF8Encoding $false))
        $xml=New-TiboTaskXml (Join-Path $PSScriptRoot 'TiboWatch.ps1') $identity.User.Value ([datetimeoffset]::Now) $DataDirectory
        $null=Register-ScheduledTask -TaskName $taskName -Xml $xml -Force
        Start-ScheduledTask -TaskName $taskName
        [pscustomobject]@{Enabled=$true;Task=$taskName;IntervalMinutes=30;Message='已启用；首次成功检查只建立基线。'} | ConvertTo-Json
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
            TaskState=$(if($task){[string]$task.State}else{'NotInstalled'});IntervalMinutes=30
            BaselineComplete=$s.BaselineComplete;LastSuccessfulCheck=$s.LastSuccessfulCheck
            LastAttemptAt=$s.LastAttemptAt;LastRunOutcome=$s.LastRunOutcome;SourceGeneratedAt=$s.LastDataGeneratedAt
            PendingNotifications=@($s.Pending).Count;LastError=$s.LastError;LastNotificationError=$s.LastNotificationError
            PendingContexts=@($s.Deferred).Count;LastContextError=$s.LastContextError;MatchingRule='Root post keywords only; Tibo authored posts and replies; silent persistent popup'
            RetryAfter=$s.NextAttemptAt;WindowsNotifications=$notificationSetting
            NextRun=$(if($info){$info.NextRunTime.ToString('o')}else{$null})
            LastTaskResult=$(if($info){$info.LastTaskResult}else{$null})
            Source='https://api.fxtwitter.com/2/profile/thsottiaux/statuses?with_replies=1';DataDirectory=$DataDirectory
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
            $fetch={param($state,$now) Get-TiboThreadSnapshot -State $state -Now $now -Request {param($path,$query) Invoke-TiboFxRequest $path $query}}
            $notify={param($event) Show-TiboToast $event $cfg.AppId $DataDirectory}
            $save={param($state) Save-TiboState $state $statePath}
            Invoke-TiboCycle -State $s -Fetch $fetch -Notify $notify -Save $save
            $result=[pscustomobject]@{At=$s.LastAttemptAt;Result=$s.LastRunOutcome;Pending=@($s.Pending).Count;PendingContexts=@($s.Deferred).Count;Error=$s.LastError;ContextError=$s.LastContextError;NotificationError=$s.LastNotificationError}
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
        if($s.LastMatchedPost){$ev=$s.LastMatchedPost}
        if(!$ev){$ev=[pscustomobject]@{Key='test';Tag='tibotest';Kind='post';Phase='test';Title='测试';Text='测试';At=[datetimeoffset]::UtcNow.ToString('o');Url='https://x.com/thsottiaux/status/2114588174249071102';RootUrl='https://x.com/thsottiaux/status/2114588174249071102';Sticky=$true}}
        $ev.Title='Tibo 常驻提醒测试（不代表有新重置）';$ev.Text='规则测试：主帖命中关键词才常驻。点击“知道了”关闭；未命中时完全不弹出。'
        $ev.Tag='tibotest'
        Show-TiboToast $ev $cfg.AppId $DataDirectory
        [pscustomobject]@{SubmittedToWindows=$true;Tag=$ev.Tag;Sticky=$true;ClickTarget=$ev.Url;RootTarget=$ev.RootUrl;Message='常驻测试窗已显示，点击“知道了”关闭；此测试不代表有新重置。'} | ConvertTo-Json
    }
    'Uninstall' {
        $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if($task){Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
        Close-TiboPersistentPopups $DataDirectory
        Unregister-TiboToastIdentity
        [pscustomobject]@{TaskRemoved=$true;Message='后台任务已移除，历史状态保留。可在 Codex 插件设置中移除插件。';DataDirectory=$DataDirectory} | ConvertTo-Json
    }
}
