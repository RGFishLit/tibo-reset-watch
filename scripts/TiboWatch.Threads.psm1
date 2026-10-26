Set-StrictMode -Version 2.0

function Assert-TiboFxBody($Body) {
    $code=Get-TiboField $Body 'code'
    if($code -ne 200){throw "FxEmbed returned an unsuccessful payload ($code)."}
}
function Get-TiboFxPostId($Post) {
    if((Get-TiboField $Post 'type') -cne 'status'){return $null}
    $id=[string](Get-TiboField $Post 'id')
    if($id -cnotmatch '^[0-9]{2,20}$'){throw 'Malformed post ID in timeline.'}
    return $id
}
function Add-TiboFxPosts([hashtable]$Map,$Posts) {
    foreach($p in @($Posts)){
        if($null -eq $p){continue}
        $id=Get-TiboFxPostId $p
        if($id){$Map[$id]=$p}
    }
}
function Read-TiboFxThread([string]$Id,[hashtable]$Map,[scriptblock]$Request,[hashtable]$Budget) {
    if($Budget.Remaining -le 0 -or $Budget.Clock.ElapsedMilliseconds -ge 150000){
        $ex=New-Object Exception 'Context work budget exhausted; retry next cycle.';$ex.Data['ContextBudget']=$true;throw $ex
    }
    $Budget.Remaining--
    $body=& $Request 'thread' @{id=$Id}
    Assert-TiboFxBody $body
    if((Get-TiboField $body 'thread') -isnot [Array]){throw 'Missing parent-chain array in FxEmbed thread.'}
    Add-TiboFxPosts $Map @((Get-TiboField $body 'status'))
    Add-TiboFxPosts $Map (Get-TiboField $body 'thread')
    if(!$Map.ContainsKey($Id)){throw 'Requested post is unavailable in its context response.'}
}
function Find-TiboRootPost($Post,[hashtable]$Map,[scriptblock]$Request,[hashtable]$Budget) {
    $visited=@{};$loaded=@{};$current=$Post
    for($depth=0;$depth -lt 64;$depth++){
        $id=Get-TiboFxPostId $current
        if(!$id -or $visited.ContainsKey($id)){throw 'Unresolved or circular parent chain.'}
        $visited[$id]=$true
        $relation=Get-TiboField $current 'replying_to'
        if($null -eq $relation){
            if($null -eq $current.PSObject.Properties['replying_to'] -and !($current -is [Collections.IDictionary] -and $current.Contains('replying_to'))){throw 'Missing reply relationship field.'}
            return $current
        }
        $parentId=[string](Get-TiboField $relation 'status')
        if($parentId -cnotmatch '^[0-9]{2,20}$'){throw 'Incomplete parent relationship.'}
        if(!$Map.ContainsKey($parentId)){
            if($loaded.ContainsKey($id)){throw 'Root context remains unavailable.'}
            $loaded[$id]=$true;Read-TiboFxThread $id $Map $Request $Budget
            if(!$Map.ContainsKey($parentId)){throw 'Root context remains unavailable.'}
        }
        $current=$Map[$parentId]
    }
    throw 'Parent chain exceeds the supported depth.'
}
function ConvertTo-TiboThreadEvent($Post,$Root) {
    $id=Get-TiboFxPostId $Post;$rootId=Get-TiboFxPostId $Root
    $rootText=Get-TiboField $Root 'text'
    if($rootText -isnot [string]){throw 'Root post body is unavailable or malformed.'}
    $pattern='(?i)\b(?:re-?set(?:s|ting|ted|ing|ed)?|reseting|banked\s+resets?|refill(?:s|ed|ing)?|(?:usage|rate)\s+limits?|quota)\b|额度重置|重置额度|额度恢复|备用重置|补充额度|重置'
    if($rootText -notmatch $pattern){return $null}
    $keyword=$Matches[0]
    $author=[string](Get-TiboField (Get-TiboField $Post 'author') 'screen_name')
    if($author -cne 'thsottiaux'){return $null}
    $url=[string](Get-TiboField $Post 'url');$rootUrl=[string](Get-TiboField $Root 'url')
    if(!(Test-TiboPostUrl $url) -or !(Test-TiboPostUrl $rootUrl $false)){throw 'Untrusted post permalink in API data.'}
    if($url -cne "https://x.com/thsottiaux/status/$id" -or $rootUrl -notmatch ('/status/'+[regex]::Escape($rootId)+'$')){throw 'Post ID and permalink disagree.'}
    $text=[string](Get-TiboField $Post 'text');if([string]::IsNullOrWhiteSpace($text)){throw 'Post text is missing.'}
    $stamp=Get-TiboField $Post 'created_timestamp';if($null -eq $stamp){throw 'Post timestamp is missing.'}
    $at=[datetimeoffset]::FromUnixTimeSeconds([long]$stamp).ToString('o')
    $kind='post';$title="Tibo：主帖命中关键词 $keyword"
    if($id -ne $rootId){$kind='reply';$title="Tibo：关键词主帖下的新回复（$keyword）"}
    $key='post:'+$id
    return [pscustomobject]@{Key=$key;Tag=(Get-TiboTag $key);Kind=$kind;Phase='keyword';Sticky=$true;Title=$title;Text=$text;At=$at;Url=$url;RootUrl=$rootUrl;RootText=$rootText;Keyword=$keyword;Source='FxEmbed';Silent=$false;DeferredCarry=$false}
}
function Get-TiboThreadSnapshot {
    param([hashtable]$State,[scriptblock]$Request,[datetimeoffset]$Now=[datetimeoffset]::UtcNow,[ValidateRange(1,8)][int]$ContextRequestBudget=8)
    $budget=@{Remaining=$ContextRequestBudget;Clock=[Diagnostics.Stopwatch]::StartNew()}
    $map=@{};$candidates=@{};$observed=@{};$cursor=$null;$visited=@{};$pages=0
    $cutoff=$null;if($State.BaselineComplete -and $State.LastSuccessfulCheck){$cutoff=([datetimeoffset]::Parse($State.LastSuccessfulCheck)).AddDays(-1).ToUnixTimeSeconds()}
    do{
        $query=@{count=100;with_replies='1'};if($cursor){$query.cursor=$cursor}
        if($budget.Clock.ElapsedMilliseconds -ge 120000){throw 'Timeline time budget exhausted; checkpoint preserved.'}
        $body=& $Request 'timeline' $query;Assert-TiboFxBody $body
        $items=Get-TiboField $body 'results'
        if($items -isnot [Array]){throw 'FxEmbed timeline schema changed: results must be an array.'}
        Add-TiboFxPosts $map $items
        $ownTimes=@()
        foreach($post in $items){
            $id=Get-TiboFxPostId $post;if(!$id){continue}
            if((Get-TiboField (Get-TiboField $post 'author') 'screen_name') -cne 'thsottiaux' -or (Get-TiboField $post 'reposted_by')){continue}
            $stamp=Get-TiboField $post 'created_timestamp';if($null -eq $stamp){throw 'Timeline entry has no timestamp.'}
            $ownTimes+=@([long]$stamp);$observed[$id]=$true
            $predatesBaseline=$State.BaselineComplete -and $State.BaselineAt -and [long]$stamp -lt ([datetimeoffset]::Parse($State.BaselineAt)).ToUnixTimeSeconds()
            if(!$predatesBaseline -and $State.Seen -notcontains ('post:'+$id)){$candidates[$id]=@{Id=$id;Silent=$false;Carry=$false}}
        }
        $cursor=Get-TiboField (Get-TiboField $body 'cursor') 'bottom';$pages++
        # Bootstrap one page; then backfill with a 24-hour overlap. Parent-context
        # timestamps from other authors cannot prematurely end timeline pagination.
        if(!$State.BaselineComplete -or !$cursor -or $items.Count -eq 0){break}
        if($null -ne $cutoff -and $ownTimes.Count -and ($ownTimes|Measure-Object -Maximum).Maximum -lt $cutoff){break}
        if($pages -ge 20){throw 'Timeline backfill exceeds 20 pages; checkpoint preserved.'}
        if([string]$cursor -cnotmatch '^[A-Za-z0-9_=-]{1,2048}$' -or $visited.ContainsKey($cursor)){throw 'Invalid or repeated timeline cursor.'}
        $visited[$cursor]=$true
    }while($true)
    foreach($item in @($State.Deferred)){
        $id=[string]$item.Id
        if($id -cnotmatch '^[0-9]{2,20}$'){throw 'Corrupt deferred post ID.'}
        $candidates[$id]=@{Id=$id;Silent=[bool]$item.Silent;Carry=$true}
    }
    $events=New-Object 'System.Collections.Generic.List[object]';$deferred=New-Object 'System.Collections.Generic.List[object]';$skipped=New-Object 'System.Collections.Generic.List[object]';$contextError=$null
    $order=New-Object 'System.Collections.Generic.List[string]'
    foreach($item in @($State.Deferred)){if(!$order.Contains([string]$item.Id)){$order.Add([string]$item.Id)}}
    foreach($id in @($candidates.Keys|Sort-Object)){if(!$order.Contains([string]$id)){$order.Add([string]$id)}}
    foreach($id in $order){
        $candidate=$candidates[$id]
        try{
            if(!$map.ContainsKey($id)){Read-TiboFxThread $id $map $Request $budget}
            $post=$map[$id]
            if((Get-TiboField (Get-TiboField $post 'author') 'screen_name') -cne 'thsottiaux' -or (Get-TiboField $post 'reposted_by')){continue}
            $observed[$id]=$true
            $root=Find-TiboRootPost $post $map $Request $budget
            $event=ConvertTo-TiboThreadEvent $post $root
            if($event){$event.Silent=$candidate.Silent;$event.DeferredCarry=$candidate.Carry;$events.Add($event)}
        }catch{
            if($_.Exception.Data.Contains('RetryAfterUtc')){throw}
            # Unknown context never authorizes a popup or blocks other valid posts.
            $silent=$candidate.Silent -or (!$State.BaselineComplete -and !$candidate.Carry)
            $entry=[pscustomobject]@{Id=$id;Silent=[bool]$silent}
            if($_.Exception.Data.Contains('ContextBudget')){$skipped.Add($entry)}else{$deferred.Add($entry)}
            $contextError="Post $id context unavailable: $($_.Exception.Message)"
        }
    }
    return @{Events=@($events.ToArray());ObservedIds=@($observed.Keys);Deferred=@($skipped.ToArray())+@($deferred.ToArray());ContextError=$contextError}
}
Export-ModuleMember -Function Get-TiboThreadSnapshot
