Set-StrictMode -Version 2.0

function Get-TiboField($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return ,($Object[$Name]) }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p) { return ,($p.Value) }
    return $null
}

function New-TiboState {
    return @{
        SchemaVersion=1; BaselineComplete=$false; BaselineAt=$null; Seen=@(); Pending=@()
        LastAttemptAt=$null; LastSuccessfulCheck=$null; LastDataGeneratedAt=$null
        FailureSince=$null; OutageAlerted=$false; NextAttemptAt=$null
        StatusEtag=$null; CachedStatus=$null; LastError=$null; LastNotificationError=$null
        LastRunOutcome='never'
    }
}

function ConvertTo-TiboState($Object) {
    if ((Get-TiboField $Object 'SchemaVersion') -ne 1) { throw 'Unsupported or corrupt state file. Refusing to reset notification history.' }
    $s = New-TiboState
    foreach ($key in @($s.Keys)) {
        if ($null -eq $Object.PSObject.Properties[$key] -and !($Object -is [System.Collections.IDictionary] -and $Object.Contains($key))) {
            throw "State file is missing $key. Refusing to reset notification history."
        }
        $s[$key] = Get-TiboField $Object $key
    }
    $s.Seen = @($s.Seen); $s.Pending = @($s.Pending)
    return $s
}

function Get-TiboTag([string]$Key) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Key)))).Replace('-','').Substring(0,16).ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function ConvertTo-TiboEvent($Record, [string]$Phase, [datetimeoffset]$Now) {
    if ($null -eq $Record) { return $null }
    $source = Get-TiboField $Record 'source'
    if ((Get-TiboField $source 'type') -cne 'x_post' -or (Get-TiboField $source 'author') -cne 'thsottiaux') { return $null }
    $uri = $null
    if (![uri]::TryCreate([string](Get-TiboField $source 'url'),[UriKind]::Absolute,[ref]$uri)) { return $null }
    if ($uri.Scheme -cne 'https' -or $uri.Host -notin @('x.com','www.x.com','twitter.com','www.twitter.com') -or $uri.UserInfo -or !$uri.IsDefaultPort) { return $null }
    if ($uri.AbsolutePath -cnotmatch '^/thsottiaux/status/([0-9]+)/?$') { return $null }
    $url = 'https://x.com/thsottiaux/status/' + $Matches[1]
    $text = [string](Get-TiboField $Record 'text')
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'API record is missing announcement text.' }
    if ($Phase -eq 'signal') {
        $expires = [datetimeoffset]::Parse([string](Get-TiboField $Record 'expires_at'))
        if ($expires -le $Now) { return $null }
        $kind = 'signal'; $at = Get-TiboField $Record 'observed_at'; $title = 'Tibo：额度重置相关信号（待确认）'
    } else {
        $kind = [string](Get-TiboField $Record 'reset_type')
        if ($kind -notin @('regular','banked')) { throw 'Unsupported reset_type in API record.' }
        $at = Get-TiboField $Record 'announced_at'
        if ($Phase -eq 'scheduled') { $title = 'Tibo：额度重置预告（待执行）' }
        elseif ($kind -eq 'banked') { $title = 'Tibo：备用重置消息' }
        else { $title = 'Tibo：常规额度重置消息' }
    }
    $when = [datetimeoffset]::Parse([string]$at)
    $key = "$url|$kind|$Phase"
    return [pscustomobject]@{
        Key=$key; Tag=(Get-TiboTag $key); Kind=$kind; Phase=$Phase
        Title=$title; Text=$text; At=$when.ToUniversalTime().ToString('o'); Url=$url
    }
}

function New-TiboSystemEvent([string]$Phase, [string]$Episode, [datetimeoffset]$Now) {
    $key = "system|$Phase|$Episode"
    $title = 'Tibo 监测已恢复'; $text = '已重新连接数据源，并继续补查新消息。'
    if ($Phase -eq 'outage') { $title = 'Tibo 监测暂时不可用'; $text = '连续 30 分钟未能成功检查。恢复连接后会补查；可在插件中查看错误。' }
    return [pscustomobject]@{Key=$key;Tag=(Get-TiboTag $key);Kind='system';Phase=$Phase;Title=$title;Text=$text;At=$Now.ToUniversalTime().ToString('o');Url='https://codex-resets.com/'}
}

function Add-TiboPending($State, $Event) {
    if ($null -eq $Event -or $State.Seen -contains $Event.Key) { return }
    $State.Seen = @($State.Seen) + @($Event.Key)
    $State.Pending = @($State.Pending) + @($Event)
}

function Assert-TiboMeta($Body) {
    if ((Get-TiboField (Get-TiboField $Body 'meta') 'api_version') -cne 'v1') { throw 'API schema changed: expected meta.api_version v1.' }
    $generated = Get-TiboField (Get-TiboField $Body 'meta') 'generated_at'
    if (!$generated) { throw 'API response has no generation time.' }
    $null = [datetimeoffset]::Parse([string]$generated)
}

function Invoke-TiboCycle {
    param([hashtable]$State,[scriptblock]$Fetch,[scriptblock]$Notify,[scriptblock]$Save,[datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    $State.LastAttemptAt = $Now.ToUniversalTime().ToString('o')
    $State.LastRunOutcome = 'backoff'
    if (!$State.NextAttemptAt -or $Now -ge [datetimeoffset]::Parse($State.NextAttemptAt)) {
        try {
            $response = & $Fetch 'status' @{} $State.StatusEtag
            if (Get-TiboField $response 'NotModified') {
                if ($null -eq $State.CachedStatus) { throw '304 without a cached status response.' }
                $body = $State.CachedStatus
            } else { $body = Get-TiboField $response 'Body' }
            Assert-TiboMeta $body
            $data = Get-TiboField $body 'data'
            foreach ($required in @('latest_reset','scheduled_reset','active_watch','stats')) {
                if ($null -eq $data -or ($null -eq $data.PSObject.Properties[$required] -and !($data -is [System.Collections.IDictionary] -and $data.Contains($required)))) { throw "API status missing $required." }
            }
            $events = New-Object 'System.Collections.Generic.List[object]'
            foreach ($pair in @(@('latest_reset','recorded'),@('scheduled_reset','scheduled'),@('active_watch','signal'))) {
                $record = Get-TiboField $data $pair[0]
                if ($null -ne $record) {
                    $ev = ConvertTo-TiboEvent $record $pair[1] $Now
                    if ($null -ne $ev) { $events.Add($ev) }
                }
            }
            $cursor = $null; $visited = @{}
            do {
                $query = @{limit=100;order='desc'}
                if ($cursor) { $query.cursor=$cursor }
                $history = & $Fetch 'resets' $query $null
                $page = Get-TiboField $history 'Body'
                Assert-TiboMeta $page
                $items = Get-TiboField $page 'data'; $pagination = Get-TiboField $page 'pagination'
                $hasMore = Get-TiboField $pagination 'has_more'
                if ($null -eq $items -or $items -isnot [System.Array] -or $hasMore -isnot [bool]) { throw 'API history schema changed: expected array and pagination.has_more.' }
                foreach ($record in $items) {
                    $ev = ConvertTo-TiboEvent $record 'recorded' $Now
                    if ($null -ne $ev) { $events.Add($ev) }
                }
                $cursor = Get-TiboField $pagination 'next_cursor'
                if ($hasMore) {
                    if (!$cursor -or [string]$cursor -cnotmatch '^[A-Za-z0-9_-]{1,1024}$' -or $visited.ContainsKey($cursor)) { throw 'Invalid or repeated history cursor.' }
                    $visited[$cursor]=$true
                }
            } while ($hasMore)
            # Commit only after the complete paginated snapshot succeeds.
            foreach ($ev in @($events | Sort-Object At,Key)) {
                if (!$State.BaselineComplete) {
                    if ($State.Seen -notcontains $ev.Key) { $State.Seen = @($State.Seen) + @($ev.Key) }
                } else { Add-TiboPending $State $ev }
            }
            if (!$State.BaselineComplete) { $State.BaselineAt=$Now.ToUniversalTime().ToString('o'); $State.BaselineComplete=$true }
            if ($State.OutageAlerted) { Add-TiboPending $State (New-TiboSystemEvent 'recovery' $State.FailureSince $Now) }
            $State.LastSuccessfulCheck=$Now.ToUniversalTime().ToString('o')
            $State.LastDataGeneratedAt=Get-TiboField (Get-TiboField $body 'meta') 'generated_at'
            $State.CachedStatus=$body
            if (!(Get-TiboField $response 'NotModified')) { $State.StatusEtag=Get-TiboField $response 'ETag' }
            $State.FailureSince=$null; $State.OutageAlerted=$false; $State.NextAttemptAt=$null; $State.LastError=$null
            $State.LastRunOutcome='ok'
        } catch {
            $State.LastRunOutcome='error'; $State.LastError=$_.Exception.Message
            if (!$State.FailureSince) { $State.FailureSince=$Now.ToUniversalTime().ToString('o') }
            if ($_.Exception.Data.Contains('RetryAfterUtc')) { $State.NextAttemptAt=[string]$_.Exception.Data['RetryAfterUtc'] }
        }
    }
    if ($State.FailureSince -and !$State.OutageAlerted -and ($Now - [datetimeoffset]::Parse($State.FailureSince)).TotalMinutes -ge 30) {
        Add-TiboPending $State (New-TiboSystemEvent 'outage' $State.FailureSince $Now)
        $State.OutageAlerted=$true
    }
    # Persist outbox before any OS side effect. Stable toast tags replace crash retries.
    & $Save $State
    $State.LastNotificationError=$null
    foreach ($event in @($State.Pending)) {
        try { & $Notify $event }
        catch { $State.LastNotificationError=$_.Exception.Message; & $Save $State; break }
        $State.Pending=@($State.Pending | Where-Object { $_.Key -ne $event.Key })
        & $Save $State
    }
}

function New-TiboToastXml($Event) {
    $url=[string]$Event.Url
    if ($Event.Kind -ne 'system') {
        $uri=$null
        if (![uri]::TryCreate($url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'x.com' -or $uri.AbsolutePath -cnotmatch '^/thsottiaux/status/[0-9]+$' -or $uri.UserInfo -or !$uri.IsDefaultPort) { throw 'Refusing unsafe notification launch URL.' }
    } elseif ($url -cne 'https://codex-resets.com/') { throw 'Unexpected system notification URL.' }
    # XML 1.0 cannot represent control characters or unpaired UTF-16 surrogates.
    $invalid='[\x00-\x08\x0B\x0C\x0E-\x1F\uFFFE\uFFFF]|[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]'
    $title=[Security.SecurityElement]::Escape(([string]$Event.Title -replace $invalid,''))
    $text=(([string]$Event.Text -replace $invalid,'') -replace '\s+',' ').Trim()
    if ($text.Length -gt 220) {
        $length=217
        if ([char]::IsHighSurrogate($text[$length-1])) { $length-- }
        $text=$text.Substring(0,$length)+'...'
    }
    $text=[Security.SecurityElement]::Escape($text)
    $time=([datetimeoffset]::Parse([string]$Event.At)).ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd HH:mm')
    $footer=[Security.SecurityElement]::Escape("北京时间 $time；适用范围以原帖为准。来源：Codex Resets（社区转述）")
    $url=[Security.SecurityElement]::Escape($url)
    return "<toast activationType=`"protocol`" launch=`"$url`"><visual><binding template=`"ToastGeneric`"><text>$title</text><text>$text</text><text>$footer</text></binding></visual><actions><action content=`"数据来源：Codex Resets`" activationType=`"protocol`" arguments=`"https://codex-resets.com/`" /></actions></toast>"
}

Export-ModuleMember -Function New-TiboState,ConvertTo-TiboState,Get-TiboField,ConvertTo-TiboEvent,Invoke-TiboCycle,New-TiboToastXml,Get-TiboTag
