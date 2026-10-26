Set-StrictMode -Version 2.0

function Get-TiboField($Object,[string]$Name) {
    if($null -eq $Object){return $null}
    if($Object -is [Collections.IDictionary]){return ,($Object[$Name])}
    $p=$Object.PSObject.Properties[$Name];if($null -ne $p){return ,($p.Value)}
    return $null
}
function Get-TiboTag([string]$Key) {
    $hash=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Key)))).Replace('-','').Substring(0,16).ToLowerInvariant()}
    finally{$hash.Dispose()}
}
function New-TiboState {
    return @{
        SchemaVersion=2;Source='FxEmbed-v2';BaselineComplete=$false;BaselineAt=$null
        Seen=@();Pending=@();Deferred=@();LastMatchedPost=$null
        LastAttemptAt=$null;LastSuccessfulCheck=$null;LastDataGeneratedAt=$null
        FailureSince=$null;OutageAlerted=$false;NextAttemptAt=$null
        LastError=$null;LastContextError=$null;LastNotificationError=$null;LastRunOutcome='never'
    }
}
function ConvertTo-TiboState($Object) {
    $version=Get-TiboField $Object 'SchemaVersion'
    if($version -eq 1){
        if((Get-TiboField $Object 'Seen') -isnot [Array] -or (Get-TiboField $Object 'Pending') -isnot [Array] -or (Get-TiboField $Object 'BaselineComplete') -isnot [bool]){throw 'Corrupt legacy state; notification history was not reset.'}
        # New source needs a fresh baseline; preserve seen IDs and owed alerts.
        $s=New-TiboState
        foreach($key in @('LastSuccessfulCheck','LastAttemptAt','LastNotificationError')){$s[$key]=Get-TiboField $Object $key}
        $legacySeen=Get-TiboField $Object 'Seen'
        foreach($key in $legacySeen){
            if([string]$key -match '^https://x\.com/thsottiaux/status/([0-9]+)\|'){$s.Seen+=@('post:'+$Matches[1])}
        }
        $legacyPending=Get-TiboField $Object 'Pending'
        foreach($event in $legacyPending){
            $url=[string](Get-TiboField $event 'Url')
            if($url -match '^https://x\.com/thsottiaux/status/([0-9]+)$'){
                $id=$Matches[1];$s.Deferred+=@([pscustomobject]@{Id=$id;Silent=$false})
                $s.Seen=@($s.Seen|Where-Object{$_ -ne ('post:'+$id)})
            }
        }
        return $s
    }
    if($version -ne 2){throw 'Unsupported or corrupt state file. Notification history was not reset.'}
    $s=New-TiboState
    foreach($key in @($s.Keys)){
        if($null -eq $Object.PSObject.Properties[$key] -and !($Object -is [Collections.IDictionary] -and $Object.Contains($key))){throw "State file is missing $key."}
        $s[$key]=Get-TiboField $Object $key
    }
    foreach($key in @('Seen','Pending','Deferred')){$s[$key]=@($s[$key])}
    if($s.Source -cne 'FxEmbed-v2'){throw 'Unexpected monitoring source in state.'}
    return $s
}
function Get-TiboRootKeyword($Text) {
    if($Text -isnot [string]){return $null}
    $pattern='(?i)\b(?:re-?set(?:s|ting|ted|ing|ed)?|reseting|banked\s+resets?|refill(?:s|ed|ing)?|(?:usage|rate)\s+limits?|quota)\b|额度重置|重置额度|额度恢复|备用重置|补充额度|重置'
    if($Text -match $pattern){return $Matches[0]}
    return $null
}
function Add-TiboPending($State,$Event) {
    if($State.Seen -contains $Event.Key){return}
    $State.Seen=@($State.Seen)+@($Event.Key);$State.Pending=@($State.Pending)+@($Event)
}
function Invoke-TiboCycle {
    param([hashtable]$State,[scriptblock]$Fetch,[scriptblock]$Notify,[scriptblock]$Save,[datetimeoffset]$Now=[datetimeoffset]::UtcNow)
    $State.LastAttemptAt=$Now.ToUniversalTime().ToString('o');$State.LastRunOutcome='backoff'
    if(!$State.NextAttemptAt -or $Now -ge [datetimeoffset]::Parse($State.NextAttemptAt)){
        try{
            $snapshot=& $Fetch $State $Now
            foreach($key in @('Events','ObservedIds','Deferred')){if((Get-TiboField $snapshot $key) -isnot [Array]){throw "Invalid thread snapshot: $key must be an array."}}
            $wasBaseline=$State.BaselineComplete
            foreach($event in @($snapshot.Events|Sort-Object At,Key)){
                $owed=(Get-TiboField $event 'DeferredCarry') -and !(Get-TiboField $event 'Silent')
                if(($wasBaseline -or $owed) -and !(Get-TiboField $event 'Silent')){Add-TiboPending $State $event}
                elseif($State.Seen -notcontains $event.Key){$State.Seen+=@($event.Key)}
                $State.LastMatchedPost=$event
            }
            $deferredIds=@($snapshot.Deferred|ForEach-Object{[string]$_.Id})
            foreach($id in $snapshot.ObservedIds){
                $key='post:'+$id
                if($deferredIds -notcontains [string]$id -and $State.Seen -notcontains $key){$State.Seen+=@($key)}
            }
            $State.Deferred=@($snapshot.Deferred);$State.LastContextError=Get-TiboField $snapshot 'ContextError'
            if(!$wasBaseline){$State.BaselineComplete=$true;$State.BaselineAt=$Now.ToUniversalTime().ToString('o')}
            $State.LastSuccessfulCheck=$Now.ToUniversalTime().ToString('o');$State.LastDataGeneratedAt=$State.LastSuccessfulCheck
            $State.FailureSince=$null;$State.OutageAlerted=$false;$State.NextAttemptAt=$null;$State.LastError=$null
            $State.LastRunOutcome=$(if($State.Deferred.Count){'partial'}else{'ok'})
        }catch{
            $State.LastRunOutcome='error';$State.LastError=$_.Exception.Message
            if(!$State.FailureSince){$State.FailureSince=$Now.ToUniversalTime().ToString('o')}
            if($_.Exception.Data.Contains('RetryAfterUtc')){$State.NextAttemptAt=[string]$_.Exception.Data['RetryAfterUtc']}
        }
    }
    # Strict quiet mode: operational failures and recovery are status/log data only.
    $State.Pending=@($State.Pending|Where-Object{$_.Kind -in @('post','reply') -and (Get-TiboField $_ 'Sticky') -and (Get-TiboRootKeyword (Get-TiboField $_ 'RootText'))})
    & $Save $State
    $State.LastNotificationError=$null
    foreach($event in @($State.Pending)){
        try{& $Notify $event}catch{$State.LastNotificationError=$_.Exception.Message;& $Save $State;break}
        $State.Pending=@($State.Pending|Where-Object{$_.Key -ne $event.Key});& $Save $State
    }
}
function ConvertTo-TiboXmlText([string]$Text,[int]$Limit=220) {
    $invalid='[\x00-\x08\x0B\x0C\x0E-\x1F\uFFFE\uFFFF]|[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]'
    $text=(($Text -replace $invalid,'') -replace '\s+',' ').Trim()
    if($text.Length -gt $Limit){$n=$Limit-3;if([char]::IsHighSurrogate($text[$n-1])){$n--};$text=$text.Substring(0,$n)+'...'}
    return [Security.SecurityElement]::Escape($text)
}
function Test-TiboPostUrl([string]$Url,[bool]$OnlyTibo=$true) {
    $uri=$null
    if(![uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'x.com' -or $uri.UserInfo -or !$uri.IsDefaultPort -or $uri.Query -or $uri.Fragment){return $false}
    if($OnlyTibo){return $uri.AbsolutePath -cmatch '^/thsottiaux/status/[0-9]+$'}
    return $uri.AbsolutePath -match '^/[A-Za-z0-9_]{1,15}/status/[0-9]+$'
}
function New-TiboToastXml($Event) {
    $url=[string]$Event.Url;$sticky=[bool](Get-TiboField $Event 'Sticky')
    if($Event.Kind -eq 'system'){
        if($url -cne 'https://github.com/FxEmbed/FxEmbed'){throw 'Unexpected system notification URL.'}
        $sticky=$false
    }elseif(!(Test-TiboPostUrl $url)){throw 'Refusing unsafe notification launch URL.'}
    $title=ConvertTo-TiboXmlText $Event.Title 100;$text=ConvertTo-TiboXmlText $Event.Text
    $time=([datetimeoffset]::Parse([string]$Event.At)).ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd HH:mm')
    $footer=ConvertTo-TiboXmlText "北京时间 $time；来源 FxEmbed。关键词提醒，不代表个人额度到账。" 180
    $actions='<action content="数据来源：FxEmbed" activationType="protocol" arguments="https://github.com/FxEmbed/FxEmbed" />'
    $rootUrl=Get-TiboField $Event 'RootUrl'
    if($rootUrl){
        if(!(Test-TiboPostUrl $rootUrl $false)){throw 'Refusing unsafe root-post URL.'}
        $rootUrl=[Security.SecurityElement]::Escape($rootUrl)
        $actions='<action content="查看主帖" activationType="protocol" arguments="'+$rootUrl+'" />'+$actions
    }
    $scenario=''
    if($sticky){
        # Alarm + silent audio persists without a background COM toast activator.
        $scenario=' scenario="alarm"';$actions='<action content="知道了" activationType="system" arguments="dismiss" />'+$actions
    }
    $url=[Security.SecurityElement]::Escape($url)
    return '<toast activationType="protocol" launch="'+$url+'"'+$scenario+'><visual><binding template="ToastGeneric"><text>'+$title+'</text><text>'+$text+'</text><text>'+$footer+'</text></binding></visual><audio silent="true"/><actions>'+$actions+'</actions></toast>'
}
Export-ModuleMember -Function Get-TiboField,Get-TiboTag,Get-TiboRootKeyword,New-TiboState,ConvertTo-TiboState,Invoke-TiboCycle,New-TiboToastXml,Test-TiboPostUrl
