param([string]$ModulePath = "$PSScriptRoot\..\scripts\TiboWatch.Core.psm1")
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $ModulePath)) { throw 'FAIL: core module is missing; baseline and event filtering are not implemented.' }
Import-Module $ModulePath -Force -DisableNameChecking
$script:Passed = 0
function Assert($Condition, [string]$Message) { if (!$Condition) { throw "ASSERT: $Message" } }
function Test([string]$Name, [scriptblock]$Body) { & $Body; $script:Passed++; Write-Output "PASS $Name" }
function Post([string]$Id = '100', [string]$Type = 'regular', [string]$At = '2026-10-25T01:00:00Z') {
    return [pscustomobject]@{ id=$Id; reset_type=$Type; announced_at=$At; text='Done and dusted'; source=[pscustomobject]@{type='x_post';author='thsottiaux';url="https://x.com/thsottiaux/status/$Id"} }
}
function Status($Latest = $null, $Scheduled = $null, $Watch = $null) {
    return [pscustomobject]@{ data=[pscustomobject]@{latest_reset=$Latest;scheduled_reset=$Scheduled;active_watch=$Watch;stats=@{total=0}};meta=@{api_version='v1';generated_at='2026-10-25T01:00:00Z'} }
}
function Page($Items = @(), [bool]$More = $false, $Cursor = $null) {
    return [pscustomobject]@{data=@($Items);pagination=[pscustomobject]@{has_more=$More;next_cursor=$Cursor};meta=@{api_version='v1';generated_at='2026-10-25T01:00:00Z'} }
}
function Run($State, $StatusBody, $Items = @(), [datetimeoffset]$Now = [datetimeoffset]'2026-10-25T02:00:00Z', [scriptblock]$Notify = {param($Item) $script:Sent.Add($Item)}) {
    $script:ResponseStatus = $StatusBody
    $script:ResponseItems = @($Items)
    $script:Sent = New-Object 'System.Collections.Generic.List[object]'
    $script:Saves = New-Object 'System.Collections.Generic.List[string]'
    $fetch = {param($Path,$Query,$ETag) if($Path -eq 'status'){ return @{Body=$script:ResponseStatus;ETag='s1';NotModified=$false} }; return @{Body=(Page $script:ResponseItems);NotModified=$false} }
    Invoke-TiboCycle -State $State -Fetch $fetch -Notify $Notify -Save {param($s) $script:Saves.Add(($s | ConvertTo-Json -Depth 20 -Compress))} -Now $Now
}

Test 'first successful cycle creates baseline without historical notifications' {
    $s=New-TiboState
    Run $s (Status (Post)) @((Post))
    Assert $s.BaselineComplete 'baseline was not established'
    Assert ($script:Sent.Count -eq 0) 'historical records caused notification'
    Assert ($s.LastSuccessfulCheck -eq '2026-10-25T02:00:00.0000000+00:00') 'success time missing'
}
Test 'new regular and banked posts notify exactly once across JSON reload' {
    $s=New-TiboState; Run $s (Status) @()
    $posts=@((Post '101' 'regular' '2026-10-25T02:01:00Z'),(Post '102' 'banked' '2026-10-25T02:02:00Z'))
    Run $s (Status $posts[1]) $posts ([datetimeoffset]'2026-10-25T02:05:00Z')
    Assert ($script:Sent.Count -eq 2) 'expected exactly 2 messages'
    Assert (@($script:Sent | Where-Object Kind -eq 'banked').Count -eq 1) 'banked type missing'
    $s=ConvertTo-TiboState ($s | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    Run $s (Status $posts[1]) $posts ([datetimeoffset]'2026-10-25T02:10:00Z')
    Assert ($script:Sent.Count -eq 0) 'restart caused duplicates'
}
Test 'unrelated authors observed sources and unsafe links are ignored' {
    $s=New-TiboState; Run $s (Status) @()
    $bad=@((Post '103'),(Post '104'),(Post '105'),(Post '106'),(Post '107'))
    $bad[0].source.author='someone'; $bad[1].source.type='observed'
    $bad[2].source.url='https://x.com.evil.test/thsottiaux/status/105'
    $bad[3].source.url='https://x.com/someone/status/106'
    $bad[4].source.url='javascript:alert(1)'
    Run $s (Status) $bad
    Assert ($script:Sent.Count -eq 0) 'untrusted source caused notification'
}
Test 'short context-dependent reset posts do not need a reset keyword' {
    $s=New-TiboState; Run $s (Status) @()
    $p=Post '108'; $p.text='Done'
    Run $s (Status $p) @($p)
    Assert ($script:Sent.Count -eq 1) 'upstream classified short post was dropped'
}
Test 'scheduled announcement can later notify as execution using same post' {
    $s=New-TiboState; Run $s (Status) @()
    $p=Post '109'; $p | Add-Member status scheduled; $p | Add-Member scheduled_for '2026-10-25T03:00:00Z'
    Run $s (Status $null $p) @()
    Assert ($script:Sent.Count -eq 1 -and $script:Sent[0].Phase -eq 'scheduled') 'scheduled phase missing'
    Run $s (Status $null $p) @() ([datetimeoffset]'2026-10-25T04:00:00Z')
    Assert ($script:Sent.Count -eq 0) 'time passage incorrectly confirmed execution'
    Run $s (Status $p) @($p) ([datetimeoffset]'2026-10-25T04:05:00Z')
    Assert ($script:Sent.Count -eq 1 -and $script:Sent[0].Phase -eq 'recorded') 'execution transition was suppressed'
}
Test 'active watch is distinct from confirmation and expires without notification' {
    $s=New-TiboState; Run $s (Status) @()
    $w=[pscustomobject]@{level='strong';reset_chance_percent=99;forecast_window='today';observed_at='2026-10-25T02:01:00Z';expires_at='2026-10-25T03:00:00Z';text='One day';source=(Post '110').source}
    Run $s (Status $null $null $w) @()
    Assert ($script:Sent.Count -eq 1 -and $script:Sent[0].Phase -eq 'signal') 'watch phase missing'
    Assert ($script:Sent[0].Title -notmatch '99|已到账|已完成') 'forecast promoted to fact'
    $s=New-TiboState; Run $s (Status) @()
    Run $s (Status $null $null $w) @() ([datetimeoffset]'2026-10-25T04:00:00Z')
    Assert ($script:Sent.Count -eq 0) 'expired watch caused notification'
}
Test 'durable outbox is saved before notify and retries a failed notification' {
    $s=New-TiboState; Run $s (Status) @()
    Run $s (Status (Post '111')) @((Post '111')) ([datetimeoffset]'2026-10-25T02:05:00Z') {param($e) Assert ($script:Saves.Count -gt 0) 'not durable before notification'; throw 'toast unavailable'}
    Assert ($s.Pending.Count -eq 1) 'failed message was lost'
    Assert ($s.LastNotificationError -match 'toast unavailable') 'notification error missing'
    $s=ConvertTo-TiboState ($s | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    Run $s (Status (Post '111')) @((Post '111')) ([datetimeoffset]'2026-10-25T02:10:00Z')
    Assert ($script:Sent.Count -eq 1 -and $s.Pending.Count -eq 0) 'pending notification not retried'
}
Test 'all history pages are consumed and backlog is delivered oldest first' {
    $s=New-TiboState; Run $s (Status) @()
    $script:Sent.Clear(); $script:PageCalls=0
    $fetch={param($Path,$Query,$ETag) if($Path -eq 'status'){return @{Body=(Status);NotModified=$false}}; $script:PageCalls++; if(!$Query.cursor){return @{Body=(Page @((Post '113')) $true 'next_1');NotModified=$false}}; Assert ($Query.cursor -eq 'next_1') 'wrong cursor'; return @{Body=(Page @((Post '112')));NotModified=$false} }
    Invoke-TiboCycle -State $s -Fetch $fetch -Notify {param($e)$script:Sent.Add($e)} -Save {} -Now ([datetimeoffset]'2026-10-25T04:00:00Z')
    Assert ($script:PageCalls -eq 2 -and $script:Sent.Count -eq 2) 'pagination lost records'
    Assert ($script:Sent[0].Url -match '/112$') 'backlog order wrong'
}
Test 'failed fetch retains checkpoint and alerts once after 30 minutes then recovers once' {
    $s=New-TiboState; Run $s (Status) @(); $checkpoint=$s.LastSuccessfulCheck; $script:Sent.Clear()
    $fail={throw 'network down'}; $notify={param($e)$script:Sent.Add($e)}
    foreach($time in @('2026-10-25T02:05:00Z','2026-10-25T02:35:00Z','2026-10-25T02:40:00Z')) { Invoke-TiboCycle -State $s -Fetch $fail -Notify $notify -Save {} -Now ([datetimeoffset]$time) }
    Assert ($s.LastSuccessfulCheck -eq $checkpoint) 'failed fetch advanced checkpoint'
    Assert ($script:Sent.Count -eq 1 -and $script:Sent[0].Phase -eq 'outage') 'outage spam or missing alert'
    Run $s (Status) @() ([datetimeoffset]'2026-10-25T02:45:00Z')
    Assert ($script:Sent.Count -eq 1 -and $script:Sent[0].Phase -eq 'recovery') 'recovery notification missing'
}
Test 'rate limiting suppresses requests until retry-after and still retries queued notifications' {
    $s=New-TiboState; Run $s (Status) @(); $script:Calls=0
    $limited={ $ex=New-Object System.Exception 'HTTP 429'; $ex.Data['RetryAfterUtc']='2026-10-25T02:25:00Z'; throw $ex }
    Invoke-TiboCycle -State $s -Fetch $limited -Notify {} -Save {} -Now ([datetimeoffset]'2026-10-25T02:05:00Z')
    Assert ($s.NextAttemptAt -eq '2026-10-25T02:25:00Z') 'retry-after not saved'
    Invoke-TiboCycle -State $s -Fetch {$script:Calls++;throw 'should not fetch'} -Notify {} -Save {} -Now ([datetimeoffset]'2026-10-25T02:10:00Z')
    Assert ($script:Calls -eq 0) 'rate-limit ignored'
}
Test 'malformed responses fail without creating a false empty baseline' {
    $s=New-TiboState
    Run $s ([pscustomobject]@{unexpected='changed API'}) @()
    Assert (!$s.BaselineComplete -and $s.LastError) 'invalid response treated as empty success'
}
Test '304 status still scans history for late indexed posts' {
    $s=New-TiboState; Run $s (Status) @(); $script:Sent.Clear()
    $fetch={param($Path,$Query,$ETag) if($Path -eq 'status'){return @{NotModified=$true}}; return @{Body=(Page @((Post '114')));NotModified=$false} }
    Invoke-TiboCycle -State $s -Fetch $fetch -Notify {param($e)$script:Sent.Add($e)} -Save {} -Now ([datetimeoffset]'2026-10-25T02:05:00Z')
    Assert ($script:Sent.Count -eq 1) '304 skipped unseen historical record'
}
Test 'partial pagination failure commits no partial event set' {
    $s=New-TiboState; Run $s (Status) @(); $before=$s.Seen.Count
    $fetch={param($Path,$Query,$ETag) if($Path -eq 'status'){return @{Body=(Status);NotModified=$false}}; if(!$Query.cursor){return @{Body=(Page @((Post '115')) $true 'next_2');NotModified=$false}}; throw 'second page unavailable' }
    Invoke-TiboCycle -State $s -Fetch $fetch -Notify {} -Save {} -Now ([datetimeoffset]'2026-10-25T02:05:00Z')
    Assert ($s.Seen.Count -eq $before -and $s.Pending.Count -eq 0) 'partial data committed'
}
Test 'HTML or broken history data is rejected' {
    $s=New-TiboState
    $fetch={param($Path,$Query,$ETag) if($Path -eq 'status'){return @{Body=(Status);NotModified=$false}};return @{Body=@{data=@();meta=@{api_version='v1'}};NotModified=$false} }
    Invoke-TiboCycle -State $s -Fetch $fetch -Notify {} -Save {} -Now ([datetimeoffset]'2026-10-25T02:00:00Z')
    Assert (!$s.BaselineComplete -and $s.LastError) 'broken history accepted'
}
Test 'notification XML escapes text and only launches validated source URLs' {
    $e=ConvertTo-TiboEvent (Post '116') 'recorded' ([datetimeoffset]'2026-10-25T02:00:00Z')
    $e.Text='a < b & "quoted"'; $xml=New-TiboToastXml $e
    $doc=New-Object xml; $doc.LoadXml($xml)
    Assert ($doc.toast.launch -eq 'https://x.com/thsottiaux/status/116') 'wrong launch URL'
    Assert ($doc.SelectSingleNode('/toast/visual/binding/text[2]').InnerText -match 'a < b &') 'XML escaping lost text'
    Assert ($doc.DocumentElement.InnerText -match 'Codex Resets' -and $doc.DocumentElement.InnerText -match '以原帖为准') 'attribution or scope missing'
}
Test 'emoji at truncation boundary and forbidden control characters cannot poison the queue' {
    $ev=ConvertTo-TiboEvent (Post '117') 'recorded' ([datetimeoffset]'2026-10-25T02:00:00Z')
    $ev.Text=('a'*216)+[char]::ConvertFromUtf32(0x1F680)+('b'*20)+[char]1
    $doc=New-Object xml; $doc.LoadXml((New-TiboToastXml $ev))
    $ev.Text='before'+[char]1+'after'
    $doc.LoadXml((New-TiboToastXml $ev))
    Assert ($doc.DocumentElement.InnerText -match 'beforeafter') 'control character removal damaged message'
}
Write-Output "RESULT: $script:Passed tests passed"
