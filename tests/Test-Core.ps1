$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'scripts\TiboWatch.Core.psm1') -Force -DisableNameChecking
if(!(Test-Path (Join-Path $root 'scripts\TiboWatch.Threads.psm1'))){throw 'FAIL: parent-thread keyword filtering and Tibo reply collection are not implemented.'}
Import-Module (Join-Path $root 'scripts\TiboWatch.Threads.psm1') -Force -DisableNameChecking
$script:Passed=0
function Assert($Condition,[string]$Message){if(!$Condition){throw "ASSERT: $Message"}}
function Test($Name,[scriptblock]$Body){& $Body;$script:Passed++;Write-Output "PASS $Name"}
function Post($Id,$Text,$Parent=$null,$Author='thsottiaux',$Time=1792992000){
    $reply=$null;if($Parent){$reply=@{status=[string]$Parent;screen_name='thsottiaux';url="https://x.com/thsottiaux/status/$Parent"}}
    return [pscustomobject]@{type='status';id=[string]$Id;text=$Text;url="https://x.com/$Author/status/$Id";author=@{screen_name=$Author};created_timestamp=$Time;replying_to=$reply;reposted_by=$null;provider='twitter'}
}
function Page($Posts,$Next=$null){return @{code=200;results=@($Posts);cursor=@{bottom=$Next}}}
function Snapshot($State,$Posts,$Threads=@{}){
    $script:Posts=@($Posts);$script:Threads=$Threads;$script:Requests=New-Object 'System.Collections.Generic.List[string]'
    return Get-TiboThreadSnapshot -State $State -Request {param($Path,$Query)
        $script:Requests.Add($Path)
        if($Path -eq 'timeline'){return Page $script:Posts}
        if($script:Threads.ContainsKey([string]$Query.id)){return $script:Threads[[string]$Query.id]}
        throw 'upstream context unavailable'
    } -Now ([datetimeoffset]'2026-10-26T06:00:00Z')
}
function Ready { $s=New-TiboState;$s.BaselineComplete=$true;$s.LastSuccessfulCheck='2026-10-26T05:30:00Z';return $s }

Test 'only main-post text controls keyword eligibility' {
    $s=Ready
    $p=@((Post 100 'Appearance settings'),(Post 101 'reset please' 100),(Post 102 'We are resetting usage limits'),(Post 103 'Done' 102))
    $r=Snapshot $s $p
    Assert ($r.Events.Count -eq 2) 'reply keyword incorrectly qualified an unrelated root'
    Assert (@($r.Events|Where-Object {$_.Key -eq 'post:101'}).Count -eq 0) 'unrelated root generated alert'
    Assert (@($r.Events|Where-Object {$_.Key -eq 'post:103' -and $_.Sticky}).Count -eq 1) 'short Tibo reply to matching root was lost'
}
Test 'only Tibo authored posts qualify even inside matching threads' {
    $r=Snapshot (Ready) @((Post 104 'reset'),(Post 105 'great' 104 'someone'))
    Assert ($r.Events.Count -eq 1 -and $r.Events[0].Key -eq 'post:104') 'other user generated alert'
}
Test 'nested replies follow parents to root rather than the immediate parent' {
    $r=Snapshot (Ready) @((Post 106 'quota reset'),(Post 107 'question' 106 'someone'),(Post 108 'yes' 107))
    $e=@($r.Events|Where-Object {$_.Key -eq 'post:108'})
    Assert ($e.Count -eq 1 -and $e[0].RootUrl -eq 'https://x.com/thsottiaux/status/106') 'wrong root selected'
}
Test 'quoted text and unrelated discussion cannot supply the keyword' {
    $p=Post 109 'A nice day';$p|Add-Member quote (Post 110 'reset')
    $r=Snapshot (Ready) @($p)
    Assert ($r.Events.Count -eq 0) 'quoted post was treated as reply root'
}
Test 'missing parent chain is fetched from the thread endpoint' {
    $child=Post 112 'done' 111;$parent=Post 111 'banked reset'
    $r=Snapshot (Ready) @($child) @{'112'=@{code=200;status=$child;thread=@($parent,$child)}}
    Assert ($r.Events.Count -eq 1 -and $r.Events[0].RootUrl -match '/111$') 'fetched root not used'
    Assert ($script:Requests -contains 'thread') 'no context request made'
}
Test 'unknown root is deferred while valid alerts remain deliverable' {
    $r=Snapshot (Ready) @((Post 113 'done' 999),(Post 114 'reset today'))
    Assert ($r.Events.Count -eq 1 -and $r.Deferred.Count -eq 1 -and $r.ContextError) 'unknown root blocked valid post or was silently accepted'
}
Test 'deferred reply resolves even after falling out of the current timeline' {
    $s=Ready;$s.Deferred=@(@{Id='116';Silent=$false})
    $child=Post 116 'landed' 115;$parent=Post 115 'Reset all paid plans'
    $r=Snapshot $s @() @{'116'=@{code=200;status=$child;thread=@($parent,$child)}}
    Assert ($r.Events.Count -eq 1 -and $r.Deferred.Count -eq 0) 'deferred post was not retried'
}
Test 'circular or incomplete parent chains never create an alert' {
    $r=Snapshot (Ready) @((Post 117 'reset' 118),(Post 118 'another' 117))
    Assert ($r.Events.Count -eq 0 -and $r.Deferred.Count -eq 2) 'cycle was accepted as a root'
}
Test 'cursor pagination includes missing posts and rejects repeated cursors' {
    $script:Calls=0
    $r=Get-TiboThreadSnapshot -State (Ready) -Request {param($Path,$Query)
        $script:Calls++;if(!$Query.cursor){return Page @((Post 119 'reset')) 'next'};return Page @((Post 120 'quota reset'))
    } -Now ([datetimeoffset]'2026-10-26T06:00:00Z')
    Assert ($r.Events.Count -eq 2 -and $script:Calls -eq 2) 'second page skipped'
    $failed=$false
    try{$null=Get-TiboThreadSnapshot -State (Ready) -Request {param($Path,$Query) Page @((Post 119 'reset')) 'next'} -Now ([datetimeoffset]'2026-10-26T06:00:00Z')}catch{$failed=$true}
    Assert $failed 'cursor loop accepted'
}
Test 'unsupported API schemas fail rather than become an empty successful snapshot' {
    $failed=$false;try{$null=Get-TiboThreadSnapshot -State (Ready) -Request {@{code=200;unexpected=@()}}}catch{$failed=$true}
    Assert $failed 'invalid timeline schema accepted'
}
Test 'first baseline never sends old matching messages' {
    $s=New-TiboState;$shot=Snapshot $s @((Post 121 'reset'));$script:Sent=@()
    Invoke-TiboCycle -State $s -Fetch {param($state,$now)$shot}.GetNewClosure() -Notify {param($e)$script:Sent+=@($e)} -Save {} -Now ([datetimeoffset]'2026-10-26T06:00:00Z')
    Assert ($s.BaselineComplete -and $script:Sent.Count -eq 0 -and $s.Seen -contains 'post:121') 'baseline replayed history'
}
Test 'negative posts never notify and remain marked processed' {
    $s=Ready;$shot=Snapshot $s @((Post 122 'appearance'));$script:Sent=@()
    Invoke-TiboCycle -State $s -Fetch {param($state,$now)$shot}.GetNewClosure() -Notify {param($e)$script:Sent+=@($e)} -Save {}
    Assert ($script:Sent.Count -eq 0 -and $s.Seen -contains 'post:122') 'negative post notification or processing failure'
}
Test 'matched notifications persist before sending and retry across restart without duplicates' {
    $s=Ready;$shot=Snapshot $s @((Post 123 'reset'));$script:Saved=$false
    Invoke-TiboCycle -State $s -Fetch {param($state,$now)$shot}.GetNewClosure() -Notify {param($e) Assert $script:Saved 'outbox not durable';throw 'toast failed'} -Save {$script:Saved=$true}
    Assert ($s.Pending.Count -eq 1 -and $s.LastNotificationError) 'failed toast lost'
    $s=ConvertTo-TiboState ($s|ConvertTo-Json -Depth 30|ConvertFrom-Json);$script:Sent=@()
    $shot=Snapshot $s @((Post 123 'reset'))
    Invoke-TiboCycle -State $s -Fetch {param($state,$now)$shot}.GetNewClosure() -Notify {param($e)$script:Sent+=@($e)} -Save {}
    Assert ($script:Sent.Count -eq 1 -and $s.Pending.Count -eq 0) 'retry failed or duplicated'
}
Test 'outage and recovery remain silent while preserving the failed checkpoint' {
    $s=Ready;$checkpoint=$s.LastSuccessfulCheck;$script:Sent=@()
    foreach($time in @('2026-10-26T06:00:00Z','2026-10-26T06:30:00Z','2026-10-26T06:35:00Z')){Invoke-TiboCycle -State $s -Fetch {throw 'network down'} -Notify {param($e)$script:Sent+=@($e)} -Save {} -Now ([datetimeoffset]$time)}
    Assert ($s.LastSuccessfulCheck -eq $checkpoint -and $script:Sent.Count -eq 0) 'outage handling wrong'
    $shot=Snapshot $s @();Invoke-TiboCycle -State $s -Fetch {param($state,$now)$shot}.GetNewClosure() -Notify {param($e)$script:Sent+=@($e)} -Save {} -Now ([datetimeoffset]'2026-10-26T06:40:00Z')
    Assert ($script:Sent.Count -eq 0 -and !$s.FailureSince) 'recovery was not silent'
}
Test '429 retry-after pauses network while leaving pending alerts intact' {
    $s=Ready;$script:Calls=0
    Invoke-TiboCycle -State $s -Fetch {$e=New-Object Exception '429';$e.Data['RetryAfterUtc']='2026-10-26T07:00:00Z';throw $e} -Notify {} -Save {} -Now ([datetimeoffset]'2026-10-26T06:00:00Z')
    Invoke-TiboCycle -State $s -Fetch {$script:Calls++} -Notify {} -Save {} -Now ([datetimeoffset]'2026-10-26T06:15:00Z')
    Assert ($script:Calls -eq 0 -and $s.NextAttemptAt) 'rate-limit ignored'
}
Test 'sticky notification has silent persistent scenario dismiss and original-root buttons' {
    $shot=Snapshot (Ready) @((Post 124 'reset'),(Post 125 'Done' 124));$e=@($shot.Events|Where-Object {$_.Key -eq 'post:125'})[0]
    $doc=[xml](New-TiboToastXml $e)
    Assert ($doc.toast.scenario -eq 'alarm' -and $doc.toast.audio.silent -eq 'true') 'persistent scenario not silent'
    Assert ($doc.SelectSingleNode('//action[@arguments="dismiss"]') -and $doc.SelectSingleNode('//action[@content="查看主帖"]')) 'dismiss or root action missing'
    Assert ($doc.toast.launch -eq 'https://x.com/thsottiaux/status/125') 'notification opens wrong post'
}
Test 'emoji boundary XML and control characters remain safe' {
    $e=(Snapshot (Ready) @((Post 126 'reset'))).Events[0];$e.Text=('a'*216)+[char]::ConvertFromUtf32(0x1F680)+('b'*20)+[char]1
    $doc=[xml](New-TiboToastXml $e);Assert ($null -ne $doc.toast) 'bad XML'
}
Test 'old v1 state upgrades without losing seen history or pending messages' {
    $legacy=@{SchemaVersion=1;BaselineComplete=$true;Seen=@('https://x.com/thsottiaux/status/127|regular|recorded');Pending=@(@{Key='old';Url='https://x.com/thsottiaux/status/128';Kind='regular'})}
    $s=ConvertTo-TiboState ($legacy|ConvertTo-Json -Depth 10|ConvertFrom-Json)
    Assert (!$s.BaselineComplete -and $s.Seen -contains 'post:127' -and $s.Deferred[0].Id -eq '128' -and !$s.Deferred[0].Silent) 'migration lost history or queued context'
}
Test 'unseen posts older than the new-source baseline cannot replay on later pages' {
    $s=Ready;$s.BaselineAt='2026-10-26T06:00:00Z'
    $r=Snapshot $s @((Post 129 'reset from long ago' $null 'thsottiaux' 1792980000))
    Assert ($r.Events.Count -eq 0) 'older unseen post replayed after baseline'
}
Test 'incomplete legacy state is rejected rather than reset' {
    $failed=$false;try{$null=ConvertTo-TiboState ([pscustomobject]@{SchemaVersion=1})}catch{$failed=$true}
    Assert $failed 'corrupt legacy state accepted'
}
Test 'unsafe original or root links cannot authorize a popup' {
    $p=Post 130 'reset';$p.url='https://x.com.evil.test/thsottiaux/status/130'
    $r=Snapshot (Ready) @($p)
    Assert ($r.Events.Count -eq 0 -and $r.Deferred.Count -eq 1) 'unsafe original link accepted'
    $root=Post 131 'reset';$root.url='javascript:alert(1)'
    $r=Snapshot (Ready) @($root,(Post 132 'done' 131))
    Assert ($r.Events.Count -eq 0) 'unsafe root link accepted'
}
Test 'bootstrap deferred context stays silent when it is later resolved' {
    $s=New-TiboState;$shot=Snapshot $s @((Post 134 'done' 133));$script:Sent=@()
    Invoke-TiboCycle -State $s -Fetch {param($state,$now)$shot}.GetNewClosure() -Notify {param($e)$script:Sent+=@($e)} -Save {}
    $parent=Post 133 'reset';$child=Post 134 'done' 133
    $shot=Snapshot $s @() @{'134'=@{code=200;status=$child;thread=@($parent,$child)}}
    Invoke-TiboCycle -State $s -Fetch {param($state,$now)$shot}.GetNewClosure() -Notify {param($e)$script:Sent+=@($e)} -Save {}
    Assert ($script:Sent.Count -eq 0 -and $s.Seen -contains 'post:134' -and $s.Deferred.Count -eq 0) 'old deferred post replayed after bootstrap'
}
Test 'legacy owed notification is revalidated and delivered during migration baseline' {
    $legacy=@{SchemaVersion=1;BaselineComplete=$true;Seen=@('https://x.com/thsottiaux/status/136|regular|recorded');Pending=@(@{Key='old';Url='https://x.com/thsottiaux/status/136';Kind='regular'})}
    $s=ConvertTo-TiboState ($legacy|ConvertTo-Json -Depth 10|ConvertFrom-Json)
    $shot=Snapshot $s @((Post 135 'quota reset'),(Post 136 'done' 135));$script:Sent=@()
    Invoke-TiboCycle -State $s -Fetch {param($state,$now)$shot}.GetNewClosure() -Notify {param($e)$script:Sent+=@($e)} -Save {}
    Assert ($script:Sent.Count -eq 1 -and $script:Sent[0].Key -eq 'post:136') 'owed legacy post was dropped or unvalidated'
}
Test 'timeline request explicitly includes replies and system notices are transient' {
    $null=Get-TiboThreadSnapshot -State (New-TiboState) -Request {param($Path,$Query)Assert ($Query.with_replies -eq '1') 'reply collection disabled';Page @()}
    $event=[pscustomobject]@{Kind='system';Sticky=$true;Title='outage';Text='network';At='2026-10-26T06:00:00Z';Url='https://github.com/FxEmbed/FxEmbed'}
    $doc=[xml](New-TiboToastXml $event)
    Assert (!$doc.toast.HasAttribute('scenario')) 'operational notice became sticky'
}
Test 'missing or malformed root text is unknown and is retried after recovery' {
    foreach($bad in @($null,42)){
        $root=Post 140 'reset';$root.text=$bad
        $s=Ready;$shot=Snapshot $s @($root,(Post 141 'Done' 140));$script:Sent=@()
        Invoke-TiboCycle -State $s -Fetch {param($state,$now)$shot}.GetNewClosure() -Notify {param($e)$script:Sent+=@($e)} -Save {}
        Assert ($s.Deferred.Count -eq 2 -and $s.Seen -notcontains 'post:141') 'unknown root text was silently processed'
        $root.text='reset';$shot=Snapshot $s @($root,(Post 141 'Done' 140))
        Invoke-TiboCycle -State $s -Fetch {param($state,$now)$shot}.GetNewClosure() -Notify {param($e)$script:Sent+=@($e)} -Save {}
        Assert ($script:Sent.Count -eq 2 -and $s.Deferred.Count -eq 0) 'recovered root text did not allow retry'
    }
}
Test 'context request budget defers work fairly without blocking valid alerts' {
    $s=Ready;$script:ContextCalls=0
    $request={param($Path,$Query)
        if($Path -eq 'timeline'){return Page @((Post 150 'Done' 900),(Post 151 'Done' 901),(Post 152 'reset now'))}
        $script:ContextCalls++;throw 'context request timed out'
    }
    $r=Get-TiboThreadSnapshot -State $s -Request $request -ContextRequestBudget 1 -Now ([datetimeoffset]'2026-10-26T06:00:00Z')
    Assert ($script:ContextCalls -eq 1 -and $r.Events.Count -eq 1 -and $r.Deferred.Count -eq 2) 'context work was not bounded'
    $s.Deferred=$r.Deferred;$script:Attempted=@()
    $request={param($Path,$Query)if($Path -eq 'timeline'){return Page @()};$script:Attempted+=@([string]$Query.id);throw 'still missing'}
    $null=Get-TiboThreadSnapshot -State $s -Request $request -ContextRequestBudget 1 -Now ([datetimeoffset]'2026-10-26T06:15:00Z')
    Assert ($script:Attempted[0] -eq '151') 'previously unattempted context was starved'
}
Test 'stale operational and nonmatching queued messages are silently removed' {
    $s=Ready
    $s.Pending=@([pscustomobject]@{Key='old-outage';Kind='system';Sticky=$false},[pscustomobject]@{Key='old-unrelated';Kind='post';Sticky=$true;RootText='appearance settings'})
    $shot=Snapshot $s @();$script:Sent=@()
    Invoke-TiboCycle -State $s -Fetch {param($state,$now)$shot}.GetNewClosure() -Notify {param($e)$script:Sent+=@($e)} -Save {}
    Assert ($script:Sent.Count -eq 0 -and $s.Pending.Count -eq 0) 'a non-keyword queued message caused a notification'
}
Write-Output "RESULT: $script:Passed thread tests passed"
