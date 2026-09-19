param([string]$RequestFile)
$ErrorActionPreference = 'Stop'

# CRM 0.2.0. Dot-source only loads functions, allowing offline checks without credentials.
function ConvertTo-CrmMap($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [Collections.IDictionary]) {
        $map = @{}; foreach ($key in $Value.Keys) { $map[$key] = ConvertTo-CrmMap $Value[$key] }; return $map
    }
    # Windows PowerShell 5.1 also treats a JSON root array as PSCustomObject.
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { ConvertTo-CrmMap $_ }) }
    if ($Value.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
        $map = @{}; foreach ($p in $Value.PSObject.Properties) { $map[$p.Name] = ConvertTo-CrmMap $p.Value }; return $map
    }
    return $Value
}
function Read-CrmJson([string]$Path) {
    ConvertTo-CrmMap (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)))
}
function Write-CrmJson([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 40), (New-Object Text.UTF8Encoding($false)))
}
function Assert-CrmKeys($Map, [string[]]$Allowed) {
    if ($Map -isnot [Collections.IDictionary]) { throw '请求必须是 JSON 对象。' }
    foreach ($key in $Map.Keys) { if ($key -notin $Allowed) { throw "不支持的参数：$key" } }
}
function Get-CrmMemberName([string]$Key) {
    $member = @($script:CrmConfig.members | Where-Object { $_.member_key -ceq $Key })
    if ($member.Count -ne 1) { throw '成员身份尚未核验。' }
    return [string]$member[0].display_name
}
function Get-CrmContext {
    if (-not $env:MULTICA_TASK_ID -or -not $env:MULTICA_AGENT_ID) { throw '缺少原生当前运行身份。' }
    if ($env:MULTICA_AGENT_ID -cne $script:CrmConfig.multica_agent_id) { throw '当前 Agent 不属于本轮试用。' }
    $raw = & $TrialMultica agent tasks $env:MULTICA_AGENT_ID --output json | Out-String
    if ($LASTEXITCODE -ne 0) { throw '无法核对本次运行发起人。' }
    $tasks = ConvertTo-CrmMap (ConvertFrom-Json -InputObject $raw)
    $task = @($tasks | Where-Object { $_.id -ceq $env:MULTICA_TASK_ID })
    if ($task.Count -ne 1 -or $task[0].attribution.precise -ne $true) { throw '本次运行归属不明确。' }
    $task = $task[0]
    if ($task.chat_session_id -cne $script:CrmConfig.multica_chat_id) { throw '当前运行不在批准的试用群会话中。' }
    $member = [string]$task.attribution.initiator.id
    $name = Get-CrmMemberName $member
    return @{ member=$member; name=$name; chat=[string]$task.chat_session_id; task=[string]$task.id; created_at=$task.created_at }
}
function Get-CrmDaemon {
    # The native task scopes status to its injected daemon; --profile is forbidden here.
    $raw = & $TrialMultica daemon status --output json | Out-String
    if ($LASTEXITCODE -ne 0) { throw '无法核对执行端状态。' }
    $d = ConvertFrom-Json -InputObject $raw
    if (-not $d.pid -or -not $d.daemon_id) { throw '执行端标识不完整。' }
    $started = (Get-Process -Id ([int]$d.pid) -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')
    return @{ id=[string]$d.daemon_id; pid=[int]$d.pid; started=$started }
}
function Read-CrmState {
    if (-not (Test-Path -LiteralPath $script:CrmStatePath)) { throw '预览状态文件缺失，需管理员核查；未重建空状态。' }
    $s = Read-CrmJson $script:CrmStatePath
    if ($s.schema_version -ne 2 -or $s.history -isnot [array]) { throw '预览状态版本或历史不正确。' }
    $seen = @{}
    foreach ($p in @($s.history) + @($s)) {
        if ($p -ne $s -and ($p.ContainsKey('history') -or $p.status -notin @('completed','cancelled','invalidated','partial','failed'))) { throw '预览历史包含未决操作或递归历史。' }
        if ($p.confirm_code) {
            if ($p.confirm_code -cnotmatch '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$' -or $seen.ContainsKey($p.confirm_code)) { throw '预览短码重复或损坏。' }
            $seen[$p.confirm_code]=$true
        }
    }
    if ($s.status -notin @('empty','pending','executing','unknown','completed','cancelled','invalidated','partial','failed')) { throw '未知的预览状态。' }
    if ($s.status -ne 'empty' -and (-not $s.preview_id -or -not $s.operation_id -or -not $s.initiator_member_key -or -not $s.chat_id)) { throw '预览必要信息不完整。' }
    return $s
}
function Save-CrmState($State) {
    $temp = $script:CrmStatePath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    Write-CrmJson $temp $State
    # Same-volume atomic replacement retains the existing destination ACL.
    [IO.File]::Replace($temp, $script:CrmStatePath, [NullString]::Value)
}
function Get-CrmSnapshot($State) {
    $copy = @{}; foreach ($key in $State.Keys) { if ($key -notin @('history','schema_version')) { $copy[$key]=$State[$key] } }; return $copy
}
function New-CrmCode($State) {
    $used=@{}; foreach($p in @($State.history)+@($State)){if($p.confirm_code){$used[$p.confirm_code]=$true}}
    for($attempt=0;$attempt -lt 100;$attempt++) {
        $code=New-CrmRandomCode
        if(-not $used.ContainsKey($code)){return $code}
    }
    throw '未能生成唯一确认码。'
}
function New-CrmRandomCode {
    $alphabet='ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes=New-Object byte[] 6; $rng.GetBytes($bytes)
        return -join @($bytes | ForEach-Object { $alphabet[$_ -band 31] })
    } finally { $rng.Dispose() }
}
function Get-CrmConfirmCode([string]$Text) {
    $text=$Text.Normalize([Text.NormalizationForm]::FormKC).Trim().ToUpperInvariant()
    if($text -cnotmatch '^确认\s*([ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6})[。.!！]?\s*$'){throw '请只发送“确认 六位短码”；修改或多个确认需先重新核对。'}
    return $Matches[1]
}
function ConvertTo-CrmDate($Value) {
    if($null -eq $Value -or ($Value -is [string] -and $Value -ceq '')){return $null}
    if($Value -is [datetime]){return $Value.ToString('yyyy-MM-dd HH:mm')}
    $text=[string]$Value
    if($text -match '^\d{4}-\d{2}-\d{2}$') {
        $parsed=[datetime]::ParseExact($text,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
        return $parsed.ToString('yyyy-MM-dd')
    }
    if($text -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$') {
        return ([datetime]::ParseExact($text,'yyyy-MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture)).ToString('yyyy-MM-dd HH:mm')
    }
    if($text -match '^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$') {
        return ([datetimeoffset]::Parse($text,[Globalization.CultureInfo]::InvariantCulture)).ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd HH:mm')
    }
    throw '日期必须是北京时间的明确年月日，可附小时和分钟。'
}
function Get-CrmComparable([string]$Key,$Value) {
    if($Key -in @('跟进日期','沟通时间')) {
        $v=ConvertTo-CrmDate $Value
        if($v -and $v.Length -eq 10){$v+=' 00:00'}
        return $v
    }
    if($Key -eq '阶段'){return (@($Value) -join '')}
    if($Key -eq '关联客户'){return (@($Value | ForEach-Object { $_.id } | Sort-Object) -join ',')}
    if($null -eq $Value -or ($Value -is [string] -and $Value -ceq '')){return $null}
    return [string]$Value
}
function Test-CrmFields($Actual,$Expected) {
    foreach($key in $Expected.Keys){if((Get-CrmComparable $key $Actual[$key]) -cne (Get-CrmComparable $key $Expected[$key])){return $false}}
    return $true
}
function Get-CrmDisplayValue([string]$Key,$Value) {
    if($null -eq $Value -or ($Value -is [string] -and $Value -ceq '')){return '未填写'}
    if($Key -in @('负责人','记录人')){return Get-CrmMemberName ([string]$Value)}
    if($Key -in @('跟进日期','沟通时间')){
        $date=ConvertTo-CrmDate $Value
        if($date.EndsWith(' 00:00')){return $date.Substring(0,10)+'（当日安排）'}
        if($date.Length -eq 10){return $date+'（当日安排）'}
        return $date+'（北京时间）'
    }
    if($Key -eq '阶段'){return (@($Value) -join '、')}
    return [string]$Value
}
function Invoke-CrmCli([string]$Arguments) {
    $id=[guid]::NewGuid().ToString('N')
    try {
        $result=Invoke-TrialLarkCommand -Arguments $Arguments
        Write-CrmJson (Join-Path $script:CrmWorkDir ('crm-cli-'+$id+'.json')) @{exit_code=$result.ExitCode;stdout=$result.Stdout;stderr=$result.Stderr}
        $script:CrmEvidence.Add('crm-cli-'+$id+'.json') | Out-Null
        if($result.ExitCode -ne 0){throw ('官方工具调用失败，退出码 '+$result.ExitCode+'；详情已保存在本次运行证据。')}
        return ConvertTo-CrmMap (ConvertFrom-Json -InputObject $result.Stdout)
    } catch { throw }
}
function Get-CrmRows([string]$Table) {
    if($Table -notin @('customers','followups')){throw '未知的查询表。'}
    $tableId=if($Table -eq 'customers'){$script:CrmConfig.customers_table_id}else{$script:CrmConfig.followups_table_id}
    $rows=New-Object Collections.ArrayList; $offset=0; $revision=$null
    # ponytail: two-person sample Base; read bounded pages, move filtering server-side if the trial grows.
    do {
        $file='crm-read-'+[guid]::NewGuid().ToString('N')+'.ndjson'
        $args="base +record-list --base-token $($script:CrmConfig.base_token) --table-id $tableId --limit 2000 --offset $offset --format ndjson --output ./$file --profile crm-trial --as bot"
        $m=Invoke-CrmCli $args
        if($m.manifest_version -cne 'v1' -or $m.format -cne 'ndjson' -or $m.base_token -cne $script:CrmConfig.base_token -or $m.table_id -cne $tableId){throw '查询返回资源或格式不匹配。'}
        if($null -ne $revision -and $revision -ne $m.rev){throw '翻页期间数据发生变化，请重新查询。'}
        $revision=$m.rev
        $page=@(Get-Content -LiteralPath (Join-Path $script:CrmWorkDir $file) -Encoding UTF8 | Where-Object {$_} | ForEach-Object {ConvertTo-CrmMap (ConvertFrom-Json -InputObject $_)})
        if($page.Count -ne $m.records_count){throw '查询记录数与文件不一致。'}
        foreach($r in $page){[void]$rows.Add($r)}
        if($m.has_more -and ([int]$m.next_offset -le $offset -or $rows.Count -ge 10000)){throw '查询范围超过本轮上限或分页没有进展，未报告为完整结果。'}
        $offset=[int]$m.next_offset
    } while($m.has_more)
    return @($rows)
}
function Get-CrmCustomer($Selector) {
    Assert-CrmKeys $Selector @('customer_code','record_id','company')
    if($Selector.Count -eq 0){throw '请明确客户名称或编号。'}
    $rows=@(Get-CrmRows customers)
    if($Selector.customer_code){$rows=@($rows | Where-Object {$_.'客户编号' -ceq $Selector.customer_code})}
    if($Selector.record_id){$rows=@($rows | Where-Object {$_.record_id -ceq $Selector.record_id})}
    if($Selector.company){$rows=@($rows | Where-Object {$_.'公司' -ceq $Selector.company})}
    if($rows.Count -ne 1){throw '没有找到唯一客户；请提供准确公司名称或客户编号。'}
    return $rows[0]
}
function Assert-CrmFields([string]$Kind,$Fields,$Context) {
    $allowed=if($Kind -eq 'followup.create'){@('内容','沟通时间','渠道')}else{@('公司','联系方式','阶段','负责人','下一步','跟进日期')}
    Assert-CrmKeys $Fields $allowed
    $f=ConvertTo-CrmMap $Fields
    foreach($key in @($f.Keys)){
        if($key -in @('跟进日期','沟通时间')){$f[$key]=ConvertTo-CrmDate $f[$key];continue}
        if($key -eq '阶段'){
            if(@($f[$key]).Count -ne 1 -or @($f[$key])[0] -notin @('新线索','已联系','沟通中','已成交','暂缓')){throw '客户阶段不在本轮约定范围。'}
            $f[$key]=@([string]@($f[$key])[0]);continue
        }
        if($null -ne $f[$key] -and $f[$key] -isnot [string]){throw "字段 $key 必须是文字或空值。"}
        if($key -eq '负责人'){[void](Get-CrmMemberName $f[$key])}
    }
    if($Kind -eq 'customer.create'){
        if(-not $f.ContainsKey('负责人')){$f['负责人']=$Context.member}
        if(-not $f.ContainsKey('阶段')){$f['阶段']=@('新线索')}
        foreach($key in @('联系方式','下一步','跟进日期')){if(-not $f.ContainsKey($key)){$f[$key]=$null}}
        if([string]::IsNullOrWhiteSpace($f['公司'])){throw '请提供公司名称。'}
    }
    if($Kind -eq 'followup.create'){
        foreach($key in @('内容','沟通时间','渠道')){if([string]::IsNullOrWhiteSpace([string]$f[$key])){throw "请补充$key。"}}
        if($f['沟通时间'].Length -eq 10){throw '实际沟通需要明确时间，不能只填日期。'}
        if(([datetime]::ParseExact($f['沟通时间'],'yyyy-MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture)) -gt [datetime]::UtcNow.AddHours(8).AddMinutes(1)){throw '跟进记录只记录已经发生的沟通。'}
    }
    if($Kind -eq 'customer.update' -and $f.Count -eq 0){throw '请明确要修改的字段。'}
    if($f.ContainsKey('公司') -and [string]::IsNullOrWhiteSpace($f['公司'])){throw '公司名称不能为空。'}
    return $f
}
function Get-CrmPreviewText($P) {
    $label=switch($P.kind){'customer.create'{'新建客户'} 'customer.update'{'修改客户'} 'followup.create'{'记录实际沟通'}}
    $lines=New-Object Collections.ArrayList
    [void]$lines.Add("准备$label：$($P.company)")
    [void]$lines.Add('发起人：'+(Get-CrmMemberName $P.initiator_member_key))
    [void]$lines.Add('客户编号：'+$P.customer_code)
    foreach($key in @('公司','联系方式','阶段','负责人','内容','沟通时间','渠道','下一步','跟进日期')){
        if($P.new_values.ContainsKey($key)){
            $new=Get-CrmDisplayValue $key $P.new_values[$key]
            if($P.kind -eq 'customer.update'){$old=Get-CrmDisplayValue $key $P.old_values[$key];[void]$lines.Add("${key}：$old → $new")}
            else{[void]$lines.Add("${key}：$new")}
        }
    }
    if($P.kind -eq 'followup.create'){[void]$lines.Add('同时将这次沟通内容同步为客户的最近沟通摘要。')}
    [void]$lines.Add("尚未保存。请本人 @Multica CRM 试用 回复：确认 $($P.confirm_code)")
    return $lines -join "`n"
}
function New-CrmPreview($Request,$Context,$State) {
    if($State.status -in @('executing','unknown')){throw '上一笔操作正在查证，暂不能生成新的写入预览。'}
    if($State.status -eq 'pending' -and ($State.initiator_member_key -cne $Context.member -or $State.chat_id -cne $Context.chat)){throw '群内已有另一位成员的待确认修改，请稍后重发；查询可以继续。'}
    $kind=[string]$Request.kind
    if($kind -notin @('customer.create','customer.update','followup.create')){throw '未知的 CRM 写入类型。'}
    $fields=Assert-CrmFields $kind $Request.fields $Context
    $daemon=Get-CrmDaemon
    $p=@{schema_version=2;history=@($State.history);preview_id=[guid]::NewGuid().ToString();operation_id=[guid]::NewGuid().ToString();confirm_code=(New-CrmCode $State);initiator_member_key=$Context.member;chat_id=$Context.chat;created_task_id=$Context.task;kind=$kind;status='pending';old_values=@{};new_values=$fields;daemon_id=$daemon.id;daemon_pid=$daemon.pid;daemon_pid_start_time_utc=$daemon.started;preview_captured_at_utc=[datetime]::UtcNow.ToString('o');record_id=$null;summary_status=$null}
    if($kind -eq 'customer.create'){
        $same=@(Get-CrmRows customers | Where-Object {$_.'公司' -ceq $fields['公司']})
        if($same.Count -gt 0 -and $Request.allow_duplicate_company -ne $true){throw '已经有同名公司，请先核对现有客户；确实是另一家公司时需明确说明。'}
        $p.customer_code='TRIAL-'+[guid]::NewGuid().ToString();$p.company=$fields['公司']
        $p.allow_duplicate_company=($Request.allow_duplicate_company -eq $true)
        $p.new_values['客户编号']=$p.customer_code;$p.new_values['最近沟通']=$null
    }else{
        $customer=Get-CrmCustomer $Request.customer
        $p.customer_code=$customer['客户编号'];$p.company=$customer['公司'];$p.customer_record_id=$customer.record_id
        if($kind -eq 'customer.update'){
            foreach($key in $fields.Keys){$p.old_values[$key]=$customer[$key]}
        }else{
            $p.old_values=@{'最近沟通'=$customer['最近沟通']}
            $p.new_values['关联客户']=@(@{id=$customer.record_id});$p.new_values['记录人']=$Context.member
        }
        $p.old_values['公司']=$customer['公司'];$p.old_values['客户编号']=$customer['客户编号']
    }
    if($State.status -ne 'empty'){
        if($State.status -eq 'pending'){$State.status='invalidated';$State.reason='由原发起人替换预览'}
        $p.history=@($State.history)+@((Get-CrmSnapshot $State))
    }
    Save-CrmState $p
    return @{status='pending';preview=(Get-CrmSnapshot $p);reply_text=(Get-CrmPreviewText $p)}
}
function Invoke-CrmWrite([string]$Table,[string]$Mode,$Fields,[string]$RecordId) {
    $tableId=if($Table -eq 'customers'){$script:CrmConfig.customers_table_id}else{$script:CrmConfig.followups_table_id}
    if($Mode -eq 'create'){$body=@{create_records=@($Fields)}}else{
        if($RecordId -cnotmatch '^rec[A-Za-z0-9]+$'){throw '目标记录标识无效。'}
        $body=@{update_records=@{}};$body.update_records[$RecordId]=$Fields
    }
    $file='crm-write-'+[guid]::NewGuid().ToString('N')+'.json'
    Write-CrmJson (Join-Path $script:CrmWorkDir $file) $body
    $r=Invoke-CrmCli "base +record-batch-$Mode --base-token $($script:CrmConfig.base_token) --table-id $tableId --json @./$file --format json --profile crm-trial --as bot"
    if($r.ok -ne $true -or $r.identity -cne 'bot' -or @($r.data.ignored_fields).Where({$null -ne $_}).Count -gt 0){throw '写入返回未完整确认，需回查实际记录。'}
    return $r
}
function Find-CrmOutcome($P) {
    $table=if($P.kind -eq 'followup.create'){'followups'}else{'customers'}
    $opField=if($table -eq 'followups'){'操作号'}else{'最近操作号'}
    $matches=@(Get-CrmRows $table | Where-Object {$_[$opField] -ceq $P.operation_id})
    if($matches.Count -gt 1){throw '发现同一操作号对应多条记录，已停止写入。'}
    if($matches.Count -eq 0){return $null}
    $r=$matches[0]
    if($P.kind -eq 'customer.update' -and $r.record_id -cne $P.customer_record_id){throw '操作号对应的客户与预览不一致。'}
    if(-not (Test-CrmFields $r $P.new_values)){return $null}
    return $r
}
function Complete-CrmOutcome($P,$Row) {
    $P.record_id=$Row.record_id;$P.status='completed';$P.completed_at_utc=[datetime]::UtcNow.ToString('o')
    if($P.kind -eq 'followup.create' -and $P.summary_status -ne 'completed'){$P.status='partial'}
    Save-CrmState $P
    $text=switch($P.kind){'customer.create'{"已新建客户「$($P.company)」，负责人：$(Get-CrmMemberName $P.new_values['负责人'])。"} 'customer.update'{"已更新「$($P.company)」的资料，并核对保存结果。"} 'followup.create'{"已记录「$($P.company)」的这次$($P.new_values['渠道'])沟通。"}}
    if($P.status -eq 'partial'){$text+='沟通记录已保存，客户最近沟通摘要尚未确认同步；不会重复新增跟进。'}
    return @{status=$P.status;record=$Row;preview_id=$P.preview_id;operation_id=$P.operation_id;reply_text=$text}
}
function Confirm-CrmPreview($Request,$Context,$State) {
    $code=Get-CrmConfirmCode $Request.text
    $matches=@(@($State.history)+@($State) | Where-Object {$_.confirm_code -ceq $code})
    if($matches.Count -ne 1){throw '没有找到这个确认码，请核对最新预览。'}
    $p=$matches[0]
    if($p.initiator_member_key -cne $Context.member -or $p.chat_id -cne $Context.chat){throw '这项操作需要原发起人在原试用群本人确认，尚未执行。'}
    if($p.status -in @('completed','partial')){
        $reply=if($p.status -eq 'partial'){'沟通此前已记录，摘要仍待核查；本次没有重复写入。'}else{'这项操作此前已经完成，本次没有重复写入。'}
        return @{status=$p.status;reply_text=$reply;record_id=$p.record_id;historical=$true}
    }
    if($p.status -in @('cancelled','invalidated','failed')){return @{status=$p.status;reply_text='这个预览已取消或失效，没有执行，请使用最新预览。'}}
    if($p.preview_id -cne $State.preview_id){throw '历史预览不能执行。'}
    if($p.status -in @('executing','unknown')){
        $p.status='unknown';Save-CrmState $p
        $found=Find-CrmOutcome $p
        if($found){return Complete-CrmOutcome $p $found}
        return @{status='unknown';reply_text='上一笔保存结果仍待查证，暂不重复写入。请管理员核查。'}
    }
    $d=Get-CrmDaemon
    if($p.daemon_id -cne $d.id -or $p.daemon_pid -ne $d.pid -or $p.daemon_pid_start_time_utc -cne $d.started){
        $p.status='invalidated';$p.reason='执行端已重启';Save-CrmState $p
        return @{status='invalidated';reply_text='执行端已重启，这个预览已失效。请重新核对修改并确认。'}
    }
    $already=Find-CrmOutcome $p
    if($already){return Complete-CrmOutcome $p $already}
    if($p.kind -eq 'customer.create'){
        $customers=@(Get-CrmRows customers)
        $existing=@($customers | Where-Object {$_.'客户编号' -ceq $p.customer_code})
        if($existing.Count){throw '客户编号已存在，需查证，未再次创建。'}
        if(-not $p.allow_duplicate_company -and @($customers | Where-Object {$_.'公司' -ceq $p.company}).Count){
            $p.status='invalidated';$p.reason='预览后出现同名公司';Save-CrmState $p
            return @{status='conflict';reply_text='预览后出现了同名客户，本次没有新增，请先核对现有客户。'}
        }
    }else{
        $current=Get-CrmCustomer @{customer_code=$p.customer_code;record_id=$p.customer_record_id}
        if(-not (Test-CrmFields $current $p.old_values)){
            $p.status='invalidated';$p.reason='预览后的相关字段发生变化';Save-CrmState $p
            return @{status='conflict';current=$current;reply_text='客户资料在预览后发生了变化，本次没有保存。请按最新资料重新预览确认。'}
        }
    }
    $p.status='executing';$p.executing_task_id=$Context.task;Save-CrmState $p
    try {
        $fields=ConvertTo-CrmMap $p.new_values
        if($p.kind -eq 'followup.create'){$fields['操作号']=$p.operation_id;[void](Invoke-CrmWrite followups create $fields '')}
        else{$fields['最近操作号']=$p.operation_id;$mode=if($p.kind -eq 'customer.create'){'create'}else{'update'};[void](Invoke-CrmWrite customers $mode $fields $p.customer_record_id)}
        $row=$null
        foreach($delay in @(0,1,2,4)){
            if($delay){Start-Sleep -Seconds $delay}
            $row=Find-CrmOutcome $p;if($row){break}
        }
        if(-not $row){throw '回读尚未确认全部字段。'}
        if($p.kind -eq 'followup.create'){
            $p.record_id=$row.record_id;$p.summary_status='pending';Save-CrmState $p
            try {
                $customer=Get-CrmCustomer @{record_id=$p.customer_record_id;customer_code=$p.customer_code}
                if(-not (Test-CrmFields $customer $p.old_values)){throw '最近沟通摘要已变化。'}
                $summary=@{'最近沟通'=$p.new_values['内容'];'最近操作号'=$p.operation_id}
                $p.summary_status='executing';Save-CrmState $p
                [void](Invoke-CrmWrite customers update $summary $p.customer_record_id)
                $customer=Get-CrmCustomer @{record_id=$p.customer_record_id;customer_code=$p.customer_code}
                if(-not (Test-CrmFields $customer $summary)){throw '摘要回读未匹配。'}
                $p.summary_status='completed'
            }catch{$p.summary_status='unknown'}
        }
        return Complete-CrmOutcome $p $row
    }catch{
        $p.status='unknown';$p.error=$_.Exception.Message;Save-CrmState $p
        return @{status='unknown';reply_text='本次保存结果尚未确认，已经停止重复写入。请先查证这项操作。';operation_id=$p.operation_id}
    }
}
function Invoke-CrmQuery($Request,$Context) {
    $entity=if($Request.entity){[string]$Request.entity}else{'customers'}
    if($entity -notin @('customers','followups','today')){throw '未知的查询类型。'}
    $scope=if($Request.scope){[string]$Request.scope}else{'mine'}
    if($scope -notin @('mine','all')){throw '查询范围只能是 mine 或 all。'}
    $table=if($entity -eq 'followups'){'followups'}else{'customers'}
    $rows=@(Get-CrmRows $table)
    if($Request.customer){
        $c=Get-CrmCustomer $Request.customer
        if($table -eq 'customers'){$rows=@($c)}else{$rows=@($rows | Where-Object {$c.record_id -cin @($_.'关联客户' | ForEach-Object {$_.id})})}
    }elseif($scope -eq 'mine'){
        $owner=if($table -eq 'followups'){'记录人'}else{'负责人'}
        $rows=@($rows | Where-Object {$_[$owner] -ceq $Context.member})
    }
    $rows=@($rows | Sort-Object {if($table -eq 'customers'){$_.'客户编号'}else{$_.record_id}})
    if($Request.order){
        $ordered=New-Object Collections.ArrayList
        foreach($id in @($Request.order)){$found=@($rows | Where-Object {$_.record_id -ceq $id});if($found.Count -ne 1){throw '原列表中的记录已变化或不可定位，请重新查询。'};[void]$ordered.Add($found[0])}
        if(@($Request.order | Select-Object -Unique).Count -ne @($Request.order).Count){throw '列表顺序有重复记录。'}
        $rows=@($ordered)
    }
    $today=[datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd')
    if($entity -eq 'today'){$rows=@($rows | Where-Object {-not $_.'跟进日期' -or (ConvertTo-CrmDate $_.'跟进日期').Substring(0,10) -cle $today})}
    $offset=if($Request.offset){[int]$Request.offset}else{0};$limit=if($Request.limit){[int]$Request.limit}else{10}
    if($offset -lt 0 -or $limit -lt 1 -or $limit -gt 10){throw '每页显示 1–10 条，页码不能为负。'}
    $page=@($rows | Select-Object -Skip $offset -First $limit)
    $lines=New-Object Collections.ArrayList
    $subject=if($scope -eq 'mine' -and -not $Request.customer){'你'}else{'本次查询'}
    $noun=if($entity -eq 'followups'){'条沟通记录'}else{'家客户'}
    [void]$lines.Add("$subject 共找到 $($rows.Count) $noun。")
    for($i=0;$i -lt $page.Count;$i++){
        $r=$page[$i];$n=$offset+$i+1
        if($table -eq 'customers'){
            $date=Get-CrmDisplayValue '跟进日期' $r.'跟进日期'
            $category=''
            if($entity -eq 'today'){$category=if(-not $r.'跟进日期'){'【未安排日期】'}elseif((ConvertTo-CrmDate $r.'跟进日期').Substring(0,10) -ceq $today){'【今日】'}else{'【逾期】'}}
            [void]$lines.Add("$n. $category$($r.'公司')｜$(Get-CrmMemberName $r.'负责人')｜$(@($r.'阶段') -join '、')`n下一步：$(Get-CrmDisplayValue '下一步' $r.'下一步')；日期：$date")
            if($Request.customer){[void]$lines.Add("客户编号：$($r.'客户编号')`n联系方式：$(Get-CrmDisplayValue '联系方式' $r.'联系方式')`n最近沟通：$(Get-CrmDisplayValue '最近沟通' $r.'最近沟通')")}
        }else{[void]$lines.Add("$n. $(Get-CrmDisplayValue '沟通时间' $r.'沟通时间')｜$($r.'渠道')｜$(Get-CrmMemberName $r.'记录人')`n$($r.'内容')")}
    }
    $more=($offset+$page.Count -lt $rows.Count)
    if($more){[void]$lines.Add('还有更多，回复“下一页”继续。')}
    return @{status='ok';records=$page;total=$rows.Count;has_more=$more;next_offset=($offset+$page.Count);order=@($rows | ForEach-Object {$_.record_id});initiator_member_key=$Context.member;chat_id=$Context.chat;source_task_id=$Context.task;reply_text=($lines -join "`n")}
}
function Invoke-CrmRequest($Request,$Context) {
    Assert-CrmKeys $Request @('action','entity','scope','customer','fields','kind','text','confirm_code','offset','limit','order','allow_duplicate_company')
    if($Request.action -eq 'query'){return Invoke-CrmQuery $Request $Context}
    $state=Read-CrmState
    if($Request.action -in @('preview','confirm','cancel') -and $script:CrmConfig.writes_enabled -ne $true){throw '当前只开放查询，写入尚未开放。'}
    switch($Request.action){
        'preview'{return New-CrmPreview $Request $Context $state}
        'confirm'{
            Assert-CrmKeys $Request @('action','text')
            return Confirm-CrmPreview $Request $Context $state
        }
        'cancel'{
            if($state.status -ne 'pending'){throw '当前没有可取消的待确认预览；执行中或待查证操作不能取消重做。'}
            if($state.initiator_member_key -cne $Context.member -or $state.chat_id -cne $Context.chat){throw '只有原发起人能取消这项预览。'}
            $state.status='cancelled';Save-CrmState $state
            return @{status='cancelled';reply_text='已取消这次修改，没有写入。'}
        }
        'status'{
            $p=$state
            if($Request.confirm_code){$code=Get-CrmConfirmCode ('确认 '+$Request.confirm_code);$found=@(@($state.history)+@($state)|Where-Object {$_.confirm_code -ceq $code});if($found.Count -ne 1){throw '未找到这项预览。'};$p=$found[0]}
            if($p.status -eq 'empty'){return @{status='empty';reply_text='当前没有待确认修改。'}}
            if($p.initiator_member_key -cne $Context.member -or $p.chat_id -cne $Context.chat){return @{status='busy';reply_text='群内已有另一位成员的操作，查询可以继续。'}}
            if($p.status -in @('executing','unknown')){
                $p.status='unknown';Save-CrmState $p
                $found=Find-CrmOutcome $p
                if($found){return Complete-CrmOutcome $p $found}
            }
            if($p.status -eq 'pending'){return @{status='pending';preview=(Get-CrmSnapshot $p);reply_text=(Get-CrmPreviewText $p)}}
            return @{status=$p.status;reply_text=('这项操作的状态：'+@{completed='已完成';partial='沟通已记录，摘要待核查';cancelled='已取消';invalidated='已失效';unknown='待查证';executing='执行结果待查证';failed='未完成'}[$p.status])}
        }
        default{throw '不支持的 CRM 动作。'}
    }
}

if($MyInvocation.InvocationName -ne '.'){
    [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
    $script:CrmEvidence=New-Object Collections.ArrayList
    try{
        . 'D:\Multica-CRM-Trial\ops\Trial.ps1'
        Assert-TrialRuntime
        $script:CrmConfig=Read-CrmJson 'D:\Multica-CRM-Trial\skills\crm-trial\connection.json'
        if($script:CrmConfig.ready -ne $true){throw 'CRM 尚未接通。'}
        if($script:CrmConfig.profile -cne 'crm-trial' -or $script:CrmConfig.identity -cne 'bot' -or $script:CrmConfig.cli_path -cne 'D:\Multica-CRM-Trial\tools\lark-cli\lark-cli.exe'){throw '固定 CLI 身份配置不匹配。'}
        foreach($key in @('base_token','customers_table_id','followups_table_id')){if($script:CrmConfig[$key] -cnotmatch '^[A-Za-z0-9]+$'){throw '资源配置标识无效。'}}
        $script:CrmWorkDir=(Get-Location).ProviderPath
        $root='D:\Multica-CRM-Trial\runtime\workspaces\'
        if(-not $script:CrmWorkDir.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw '请在本次原生 Run 工作目录中执行。'}
        if([IO.Path]::IsPathRooted($RequestFile) -or [string]::IsNullOrWhiteSpace($RequestFile)){throw '请求文件必须使用当前运行目录下的相对路径。'}
        $path=[IO.Path]::GetFullPath((Join-Path $script:CrmWorkDir $RequestFile))
        if(-not $path.StartsWith($script:CrmWorkDir.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $path.Substring(2).Contains(':')){throw '请求文件路径越界。'}
        $script:CrmStatePath='D:\Multica-CRM-Trial\runtime\pending-write.json'
        $context=Get-CrmContext
        $result=Invoke-CrmRequest (Read-CrmJson $path) $context
        $result.evidence=@($script:CrmEvidence)
        $result | ConvertTo-Json -Depth 35
    }catch{
        @{status='error';reply_text=$_.Exception.Message;evidence=@($script:CrmEvidence)} | ConvertTo-Json -Depth 8
        exit 1
    }
}
