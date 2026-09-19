param([string]$RequestFile)
$ErrorActionPreference='Stop'
$weddingRequestFile=$RequestFile
. "$PSScriptRoot\Invoke-Crm.ps1"

# wedding-demo 0.1.0 candidate. Reuse the tested CLI/JSON/identity adapters only.
function Get-WeddingRows { Get-CrmRows customers }
function Write-WeddingRow($Fields,[string]$RecordId) {
    $mode=if($RecordId){'update'}else{'create'}
    Invoke-CrmWrite customers $mode $Fields $RecordId
}
function Copy-Wedding($Value) { ConvertTo-CrmMap $Value }
function Get-WeddingFingerprint {
    $rule=$script:WeddingConfig.rules
    $text=@($rule.version,$rule.unit_cents,$rule.capacity,$rule.standard_menu,$rule.special_menu) -join '|'
    $sha=[Security.Cryptography.SHA256]::Create()
    try {return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','')} finally {$sha.Dispose()}
}
function Save-WeddingState($State) {
    $temp=$script:WeddingStatePath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    Write-CrmJson $temp $State
    [IO.File]::Replace($temp,$script:WeddingStatePath,[NullString]::Value)
}
function Read-WeddingState {
    if(-not (Test-Path -LiteralPath $script:WeddingStatePath)){throw '婚宴状态文件缺失，请管理员核查；没有重建空历史。'}
    $s=Read-CrmJson $script:WeddingStatePath
    if($s.schema_version -ne 1 -or $s.history -isnot [array] -or $s.used_codes -isnot [array] -or $s.reserved_codes -isnot [array]){throw '婚宴状态文件损坏，已停止操作。'}
    $used=@{};foreach($c in $s.used_codes){if($c -cnotmatch '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$' -or $used.ContainsKey($c)){throw '确认码历史损坏，已停止操作。'};$used[$c]=$true}
    $seen=@{};foreach($c in $s.reserved_codes){if(-not $used.ContainsKey($c) -or $seen.ContainsKey($c)){throw '旧确认码保留名单损坏。'};$seen[$c]=$true}
    foreach($p in @($s.history)+@($s.current)){
        if($null -eq $p){continue}
        if(-not $p.operation_id -or -not $p.preview_id -or -not $p.actor -or -not $p.chat -or -not $p.new_values -or $p.kind -notin @('order.change','handoff.update','demo.new_round')){throw '操作历史不完整，已停止操作。'}
        if($p.new_values -isnot [Collections.IDictionary] -or $p.old_values -isnot [Collections.IDictionary] -or $p.patch -isnot [Collections.IDictionary] -or -not $p.daemon -or $p.rule_fingerprint -cnotmatch '^[0-9A-F]{64}$'){throw '操作内容或版本指纹损坏，已停止操作。'}
        foreach($key in @('订单编号','轮次','门店','客户称呼','婚期','场地','销售','宴会负责人','总桌数','特殊菜单桌数','菜单选项','计价规则版本','金额分','业务版本','接收状态','接收人','接收时间','布桌方案核对','布桌方案核对原因','布桌方案核对反馈人','布桌方案核对反馈时间','菜单变更交接','菜单变更交接原因','菜单变更交接反馈人','菜单变更交接反馈时间','最近操作号')){if(-not $p.new_values.ContainsKey($key)){throw '已保存的订单字段不完整，已停止操作。'}}
        if(-not $used.ContainsKey($p.code) -or $seen.ContainsKey($p.code)){throw '操作确认码重复或缺失。'};$seen[$p.code]=$true
        if($p.status -notin @('pending','executing','unknown','completed','cancelled','invalidated')){throw '操作状态损坏。'}
    }
    foreach($p in $s.history){if($p.status -notin @('completed','cancelled','invalidated')){throw '历史中存在未决操作，已停止操作。'}}
    if($s.current -and $s.current.status -notin @('pending','executing','unknown')){throw '当前操作状态损坏。'}
    if($seen.Count -ne $used.Count){throw '确认码历史与操作记录不一致。'}
    if($s.active -and (-not $s.active.record_id -or -not $s.active.fields)){throw '当前轮次不完整。'}
    return $s
}
function New-WeddingCode($State) {
    for($n=0;$n -lt 100;$n++){$c=New-CrmRandomCode;if($c -cnotin $State.used_codes){return $c}}
    throw '未能生成唯一确认码，尚未建立预览。'
}
function Close-WeddingOperation($State,[string]$Status,[string]$Reason) {
    $State.current.status=$Status;$State.current.reason=$Reason;$State.current.closed_at=[datetime]::UtcNow.ToString('o')
    $State.history=@($State.history)+@($State.current);$State.current=$null
    Save-WeddingState $State
}
function Get-WeddingFields($Row) {
    $f=Copy-Wedding $Row;[void]$f.Remove('record_id');return $f
}
function Get-WeddingOrder($State,[string]$OrderNo) {
    if(-not $OrderNo -and -not $State.active){throw '还没有当前演示订单。请销售发起“开始新一轮演示”。'}
    $rows=@(Get-WeddingRows)
    if($OrderNo){$found=@($rows | Where-Object {$_['订单编号'] -ceq $OrderNo})}
    else{$found=@($rows | Where-Object {$_.record_id -ceq $State.active.record_id})}
    if($found.Count -ne 1){throw '未找到唯一订单，请核对订单编号。'}
    return $found[0]
}
function Assert-WeddingCount($Value,[int]$Min,[int]$Max,[string]$Name) {
    if($Value -is [bool] -or $null -eq $Value -or [string]$Value -cnotmatch '^\d+$' -or [decimal]$Value -lt $Min -or [decimal]$Value -gt $Max){throw "$Name 必须是 $Min 至 $Max 的整数。"}
    return [int]$Value
}
function Get-WeddingMenu($Fields,$Patch) {
    Assert-CrmKeys $Patch @('total_tables','special_tables','menu')
    $f=Copy-Wedding $Fields
    if($Patch.ContainsKey('total_tables')){$f['总桌数']=Assert-WeddingCount $Patch.total_tables 1 $script:WeddingConfig.rules.capacity '总桌数'}
    if($Patch.ContainsKey('special_tables')){$f['特殊菜单桌数']=Assert-WeddingCount $Patch.special_tables 0 $script:WeddingConfig.rules.capacity '特殊菜单桌数'}
    if($Patch.ContainsKey('menu') -and $Patch.menu -cne $script:WeddingConfig.rules.special_menu){throw '本轮特殊菜单仅支持预设的无海鲜套餐。'}
    if($f['特殊菜单桌数'] -gt $f['总桌数']){throw '特殊菜单桌数不能超过总桌数。'}
    $f['菜单选项']=if($f['特殊菜单桌数'] -gt 0){$script:WeddingConfig.rules.special_menu}else{'标准套餐'}
    $f['金额分']=[long]$f['总桌数']*[long]$script:WeddingConfig.rules.unit_cents
    $f['计价规则版本']=$script:WeddingConfig.rules.version
    return $f
}
function Reset-WeddingHandoff($Fields) {
    $Fields['接收状态']='待接收';$Fields['接收人']='';$Fields['接收时间']=''
    foreach($label in @('布桌方案核对','菜单变更交接')){
        $Fields[$label]='待落实';$Fields[$label+'原因']='';$Fields[$label+'反馈人']='';$Fields[$label+'反馈时间']=''
    }
}
function Get-WeddingOrderText($Row) {
    $ordinary=[int]$Row['总桌数']-[int]$Row['特殊菜单桌数'];$amount=[long]$Row['金额分']/100
    $lines=@("$($Row['客户称呼'])婚宴｜$($Row['订单编号'])｜第$($Row['业务版本'])版",
        "$($Row['婚期'])（北京时间）｜$($Row['门店'])·$($Row['场地'])",
        "$($Row['总桌数'])桌：$ordinary 桌标准套餐＋$($Row['特殊菜单桌数'])桌无海鲜套餐；样例金额 $amount 元。",
        "销售：$(Get-CrmMemberName $Row['销售'])；宴会负责人：$(Get-CrmMemberName $Row['宴会负责人'])。",
        "当前版本：$($Row['接收状态'])；布桌方案核对：$($Row['布桌方案核对'])；菜单变更交接：$($Row['菜单变更交接'])。")
    foreach($label in @('布桌方案核对','菜单变更交接')){if($Row[$label] -ceq '有问题'){$lines+="$label 原因：$($Row[$label+'原因'])"}}
    return $lines -join "`n"
}
function Get-WeddingPreviewText($P) {
    $new=$P.new_values;$old=$P.old_values
    $lines=@("发起人：$(Get-CrmMemberName $P.actor)","准备操作：$(@{'order.change'='修改婚宴订单';'handoff.update'='接收或反馈交接';'demo.new_round'='开始新一轮演示'}[$P.kind])",(Get-WeddingOrderText $new))
    if($P.kind -eq 'order.change'){
        $lines+="总桌数：$($old['总桌数']) → $($new['总桌数'])；特殊菜单桌数：$($old['特殊菜单桌数']) → $($new['特殊菜单桌数'])。"
        $lines+="金额：$([long]$old['金额分']/100) → $([long]$new['金额分']/100) 元；差额 $(([long]$new['金额分']-[long]$old['金额分'])/100) 元。"
        $lines+='保存后需宴会负责人重新接收，并重新落实布桌方案核对和菜单变更交接。'
    }
    if($P.kind -eq 'handoff.update'){
        foreach($key in @('接收状态','布桌方案核对','菜单变更交接')){if($old[$key] -cne $new[$key]){$lines+="${key}：$($old[$key]) → $($new[$key])"}}
    }
    if($P.kind -eq 'demo.new_round' -and $old.Count){$lines+='上一轮保留为历史，不再修改。';if($old['接收状态'] -cne '已接收' -or $old['布桌方案核对'] -cne '已落实' -or $old['菜单变更交接'] -cne '已落实'){$lines+='上一轮仍有未完成交接，将原样保留。'}}
    $lines+="尚未保存。请本人明确 @婚宴演示助手 回复：确认 $($P.code)"
    return $lines -join "`n"
}
function Assert-WeddingActor($Context,[string]$Kind) {
    $expected=if($Kind -eq 'handoff.update'){$script:WeddingConfig.banquet_member}else{$script:WeddingConfig.sales_member}
    if($Context.member -cne $expected){if($Kind -eq 'handoff.update'){throw '只有宴会负责人 test 可以接收和反馈交接。'};throw '只有销售可以修改订单或开始新轮次。'}
}
function Test-WeddingEpoch($P) {
    $d=Get-CrmDaemon
    return ($P.deployment -ceq $script:WeddingConfig.deployment_id -and $P.daemon.id -ceq $d.id -and $P.daemon.pid -eq $d.pid -and $P.daemon.started -ceq $d.started)
}
function New-WeddingPreview($Request,$Context,$State) {
    Assert-CrmKeys $Request @('action','kind','order_no','fields')
    if($Request.kind -notin @('order.change','handoff.update','demo.new_round')){throw '不支持这类婚宴修改。'}
    Assert-WeddingActor $Context $Request.kind
    if($script:WeddingConfig.bootstrap_only -and ($Request.kind -cne 'demo.new_round' -or $State.active)){throw '当前仅开放销售确认创建第一条样例；两账号只读验收后再开放其他写入。'}
    $previous=$State.current
    if($previous -and $previous.status -ne 'pending'){throw '上一笔操作结果待查证，暂不能开始新的写入。'}
    if($previous -and ($previous.actor -cne $Context.member -or $previous.chat -cne $Context.chat)){throw '群内有另一人的待确认操作，请稍后重发；查询可以继续。'}
    if($previous -and $previous.kind -cne $Request.kind){throw '请先确认或取消上一份预览，再进行另一类操作。'}
    $patch=if($null -eq $Request.fields){@{}}else{$Request.fields};Assert-CrmKeys $patch @('total_tables','special_tables','menu','version','receive','layout','layout_reason','menu_handoff','menu_reason')
    $old=@{};$recordId=''
    if($State.active){
        $row=Get-WeddingOrder $State $Request.order_no
        if($row.record_id -cne $State.active.record_id){throw '历史轮次仅可查询，不能修改。'}
        $old=Get-WeddingFields $row;$recordId=$row.record_id
        if(-not (Test-CrmFields $row $State.active.fields)){throw 'Base 与当前已核对记录不一致，已暂停写入，请管理员核查。'}
    }elseif($Request.kind -ne 'demo.new_round'){throw '请先开始一轮演示。'}
    if($previous -and $previous.record_id -cne $recordId){throw '待确认订单不同，请先取消原预览。'}
    if($previous){$merged=Copy-Wedding $previous.patch;foreach($k in $patch.Keys){$merged[$k]=$patch[$k]};$patch=$merged}
    $id=[guid]::NewGuid().ToString();$new=Copy-Wedding $old
    switch($Request.kind){
        'demo.new_round'{
            Assert-CrmKeys $patch @()
            if($previous){throw '新轮次预览已存在，请确认或取消。'}
            $round=[guid]::NewGuid().ToString('N')
            $new=@{'轮次'=$round;'订单编号'=('HY-'+$round);'门店'='喜悦宴会中心';'客户称呼'='张先生';'婚期'='2026-10-18 12:00';'场地'='如意厅';'销售'=$script:WeddingConfig.sales_member;'宴会负责人'=$script:WeddingConfig.banquet_member;'总桌数'=28;'特殊菜单桌数'=0;'菜单选项'='标准套餐';'金额分'=([long]28*$script:WeddingConfig.rules.unit_cents);'计价规则版本'=$script:WeddingConfig.rules.version;'业务版本'=1}
            Reset-WeddingHandoff $new
        }
        'order.change'{
            if($patch.Count -eq 0){throw '请明确要修改的桌数或菜单范围。'}
            $new=Get-WeddingMenu $old $patch
            if((Test-CrmFields $new $old)){if($previous){Close-WeddingOperation $State 'invalidated' '纠正后与当前订单一致'};return @{status='unchanged';reply_text='与当前订单相同，没有写入，也没有增加版本。'}}
            $new['业务版本']=[int]$old['业务版本']+1;Reset-WeddingHandoff $new
        }
        'handoff.update'{
            Assert-CrmKeys $patch @('version','receive','layout','layout_reason','menu_handoff','menu_reason')
            if(-not $patch.ContainsKey('version') -or (Assert-WeddingCount $patch.version 1 2147483647 '反馈版本') -ne $old['业务版本']){throw '请明确接收或反馈当前订单版本，旧版本反馈不能用于新版本。'}
            if($patch.ContainsKey('receive') -and $patch.receive -isnot [bool]){throw '接收必须是明确的是或否。'}
            if($patch.ContainsKey('receive') -and -not $patch.receive){throw '本版不支持撤回接收；可将具体交接事项标记为有问题。'}
            $now=[datetime]::UtcNow.AddHours(8).ToString('yyyy-MM-dd HH:mm:ss')
            if($patch.receive -and $old['接收状态'] -cne '已接收'){$new['接收状态']='已接收';$new['接收人']=$Context.member;$new['接收时间']=$now}
            foreach($pair in @(@('layout','layout_reason','布桌方案核对'),@('menu_handoff','menu_reason','菜单变更交接'))){
                $key=$pair[0];$reasonKey=$pair[1];$label=$pair[2]
                if($patch.ContainsKey($reasonKey) -and -not $patch.ContainsKey($key)){throw '说明原因时也需要明确对应事项的状态。'}
                if(-not $patch.ContainsKey($key)){continue}
                if($new['接收状态'] -cne '已接收'){throw '请先明确接收当前版本；也可同时接收并反馈。'}
                if($patch[$key] -cnotin @('待落实','已落实','有问题')){throw '交接状态只能是待落实、已落实或有问题。'}
                $reason='';if($patch[$key] -ceq '有问题'){
                    if($patch[$reasonKey] -isnot [string] -or [string]::IsNullOrWhiteSpace($patch[$reasonKey]) -or $patch[$reasonKey].Length -gt 500){throw '有问题时请说明具体原因，最多 500 字。'};$reason=$patch[$reasonKey]
                }
                if($old[$label] -cne $patch[$key] -or [string]$old[$label+'原因'] -cne $reason){$new[$label]=$patch[$key];$new[$label+'原因']=$reason;$new[$label+'反馈人']=$Context.member;$new[$label+'反馈时间']=$now}
            }
            if(Test-CrmFields $new $old){if($previous){Close-WeddingOperation $State 'invalidated' '纠正后无内容改变'};return @{status='unchanged';reply_text='与当前交接记录相同，没有重复写入。'}}
        }
    }
    $new['最近操作号']=$id
    $p=@{preview_id=[guid]::NewGuid().ToString();operation_id=$id;code=(New-WeddingCode $State);kind=$Request.kind;actor=$Context.member;chat=$Context.chat;created_task=$Context.task;created_at=[datetime]::UtcNow.ToString('o');status='pending';record_id=$recordId;old_values=$old;new_values=$new;patch=$patch;daemon=(Get-CrmDaemon);deployment=$script:WeddingConfig.deployment_id;rule_fingerprint=(Get-WeddingFingerprint)}
    if($previous){$previous.status='invalidated';$previous.reason='原发起人纠正，替换短码';$State.history=@($State.history)+@($previous)}
    $State.current=$p;$State.used_codes=@($State.used_codes)+@($p.code);Save-WeddingState $State
    return @{status='pending';preview=$p;reply_text=(Get-WeddingPreviewText $p)}
}
function Find-WeddingOutcome($P) {
    $rows=@(Get-WeddingRows);$found=@($rows|Where-Object {$_['最近操作号'] -ceq $P.operation_id})
    if($found.Count -gt 1){throw '发现重复操作号，已停止写入，需人工核查。'}
    if($found.Count -eq 0){return $null}
    if($P.kind -ne 'demo.new_round' -and $found[0].record_id -cne $P.record_id){throw '操作号对应错误订单，需核查。'}
    if(-not (Test-CrmFields $found[0] $P.new_values)){return $null}
    return $found[0]
}
function Complete-WeddingOperation($State,$Row) {
    $p=$State.current;$p.result=Copy-Wedding $Row;$p.result_record_id=$Row.record_id
    $State.active=@{record_id=$Row.record_id;fields=(Get-WeddingFields $Row)}
    Close-WeddingOperation $State 'completed' '全部字段及操作号回读一致'
    $text='已保存并核对。'+"`n"+(Get-WeddingOrderText $Row)
    if($Row['接收状态'] -ceq '已接收' -and $Row['布桌方案核对'] -ceq '已落实' -and $Row['菜单变更交接'] -ceq '已落实'){$text+="`n本次变更交接完成；这不表示婚宴现场已完成交付。"}
    return @{status='completed';record=$Row;operation_id=$p.operation_id;reply_text=$text}
}
function Resolve-WeddingOperation($State) {
    $row=Find-WeddingOutcome $State.current
    if($row){return Complete-WeddingOperation $State $row}
    return @{status='unknown';reply_text='这笔保存结果仍待查证，未重复写入。请管理员核查。'}
}
function Confirm-WeddingPreview($Request,$Context,$State) {
    Assert-CrmKeys $Request @('action','text')
    $code=Get-CrmConfirmCode $Request.text
    $found=@(@($State.history)+@($State.current)|Where-Object {$_ -and $_.code -ceq $code})
    if($found.Count -ne 1){throw '没有找到这个确认码，请核对最新预览。'}
    $p=$found[0]
    if($p.actor -cne $Context.member -or $p.chat -cne $Context.chat){throw '只能由原发起人在原群确认，尚未执行。'}
    Assert-WeddingActor $Context $p.kind
    if($p.status -eq 'completed'){return @{status='completed';historical=$true;record=$p.result;reply_text='这笔操作此前已完成，本次没有重复写入。'}}
    if($p.status -in @('cancelled','invalidated')){return @{status=$p.status;reply_text='这份预览已取消或失效，没有执行。'}}
    if($p.status -in @('executing','unknown')){return Resolve-WeddingOperation $State}
    if($script:WeddingConfig.bootstrap_only -and ($p.kind -cne 'demo.new_round' -or $State.active)){throw '当前仅开放第一条样例创建，请先完成两账号只读验收。'}
    if(-not (Test-WeddingEpoch $p) -or $p.rule_fingerprint -cne (Get-WeddingFingerprint)){
        Close-WeddingOperation $State 'invalidated' '执行端、发布版本或计价规则变化'
        return @{status='invalidated';reply_text='执行环境或计价规则已变化，请重新预览并确认。'}
    }
    if($State.active){
        $row=Get-WeddingOrder $State ''
        if($row.record_id -cne $p.record_id -or -not (Test-CrmFields $row $p.old_values)){
            Close-WeddingOperation $State 'invalidated' '订单在预览后变化'
            return @{status='conflict';reply_text='订单在预览后发生变化，尚未保存。请核对最新订单后重新预览。'}
        }
    }
    if($p.kind -eq 'demo.new_round'){
        $duplicates=@(Get-WeddingRows | Where-Object {$_['订单编号'] -ceq $p.new_values['订单编号'] -or $_['最近操作号'] -ceq $p.operation_id})
        if($duplicates.Count){$p.status='unknown';Save-WeddingState $State;return @{status='unknown';reply_text='新轮次编号或操作号已存在，先查证，没有再次创建。'}}
    }
    $p.status='executing';$p.confirmed_task=$Context.task;$p.confirmed_at=[datetime]::UtcNow.ToString('o');Save-WeddingState $State
    try {
        $target=if($p.kind -eq 'demo.new_round'){''}else{$p.record_id}
        [void](Write-WeddingRow $p.new_values $target)
        $row=$null;foreach($delay in @(0,1,2)){if($delay){Start-Sleep -Seconds $delay};$row=Find-WeddingOutcome $p;if($row){break}}
        if(-not $row){throw '全部目标字段尚未确认回读一致。'}
        return Complete-WeddingOperation $State $row
    }catch{
        # Re-read durable state: a failed completion save must not erase an executing operation.
        $durable=Read-WeddingState
        if($durable.current){$durable.current.status='unknown';$durable.current.error=$_.Exception.Message;try{Save-WeddingState $durable}catch{}}
        return @{status='unknown';operation_id=$p.operation_id;reply_text='本次保存结果或完成记录尚未确认，已停止重复写入。请先查证。'}
    }
}
function Invoke-WeddingQuery($Request,$Context,$State) {
    Assert-CrmKeys $Request @('action','entity','order_no','fields')
    $entity=if($Request.entity){$Request.entity}else{'order'}
    if($entity -notin @('order','outstanding','history','estimate')){throw '不支持这类查询。'}
    $r=Get-WeddingOrder $State $Request.order_no
    $text=Get-WeddingOrderText $r
    if($entity -eq 'estimate'){
        if(-not $Request.fields -or $Request.fields.Count -eq 0){throw '请明确测算的总桌数或特殊菜单桌数。'}
        $estimate=Get-WeddingMenu $r $Request.fields
        return @{status='estimate';record=$r;estimate=$estimate;reply_text="仅测算，尚未修改订单。按每桌 $($script:WeddingConfig.rules.unit_cents/100) 元，$($estimate['总桌数']) 桌合计 $($estimate['金额分']/100) 元，比当前增加 $(($estimate['金额分']-$r['金额分'])/100) 元。"}
    }
    if($Request.ContainsKey('fields')){throw '只有费用测算查询可以带桌数或菜单参数。'}
    if($entity -eq 'outstanding'){
        $items=@();if($r['接收状态'] -cne '已接收'){$items+='接收当前版本'}
        foreach($label in @('布桌方案核对','菜单变更交接')){if($r[$label] -cne '已落实'){$items+="$label（$($r[$label])）"}}
        $text=if($items.Count){"$($r['订单编号']) 第$($r['业务版本'])版尚未完成：$($items -join '、')。负责人：$(Get-CrmMemberName $r['宴会负责人'])。"}else{'本次变更交接已完成；这不表示婚宴现场已完成交付。'}
    }
    if($entity -eq 'history'){
        $history=@($State.history|Where-Object {$_.status -eq 'completed' -and $_.new_values['订单编号'] -ceq $r['订单编号']})
        $lines=@("$($r['订单编号']) 有 $($history.Count) 笔已核对操作：")
        foreach($p in $history){$time=([datetimeoffset]::Parse($p.closed_at)).ToOffset([timespan]::FromHours(8)).ToString('yyyy-MM-dd HH:mm:ss');$lines+="$time（北京时间）｜$(Get-CrmMemberName $p.actor)｜$(@{'order.change'='订单变更';'handoff.update'='交接反馈';'demo.new_round'='建立样例'}[$p.kind])｜第$($p.new_values['业务版本'])版"}
        return @{status='ok';record=$r;history=$history;reply_text=($lines -join "`n")}
    }
    return @{status='ok';record=$r;reply_text=$text}
}
function Invoke-WeddingRequest($Request,$Context) {
    Assert-CrmKeys $Request @('action','kind','order_no','fields','text','confirm_code','entity')
    if($Context.member -cnotin @($script:WeddingConfig.sales_member,$script:WeddingConfig.banquet_member) -or $Context.chat -cne $script:WeddingConfig.multica_chat_id){throw '当前身份或群尚未核验。'}
    # ponytail: one file lock for this two-person demo; split locks only if real concurrency is needed.
    $handle=$null
    try {
        try{$handle=[IO.File]::Open($script:WeddingStatePath+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{return @{status='busy';reply_text='正在处理上一笔操作，请稍后重试。'}}
        $s=Read-WeddingState
        if($s.current -and $s.current.status -eq 'pending' -and -not (Test-WeddingEpoch $s.current)){Close-WeddingOperation $s 'invalidated' '执行端重启或发布切换'}
        if($Request.action -in @('preview','confirm','cancel') -and $script:WeddingConfig.writes_enabled -ne $true){throw '婚宴写入尚未开放，当前可以查询。'}
        switch($Request.action){
            'query'{return Invoke-WeddingQuery $Request $Context $s}
            'preview'{return New-WeddingPreview $Request $Context $s}
            'confirm'{return Confirm-WeddingPreview $Request $Context $s}
            'cancel'{
                Assert-CrmKeys $Request @('action')
                if(-not $s.current -or $s.current.status -ne 'pending'){throw '没有可取消的预览；待查证操作不能取消重做。'}
                if($s.current.actor -cne $Context.member){throw '只有原发起人能取消预览。'}
                Close-WeddingOperation $s 'cancelled' '原发起人取消'
                return @{status='cancelled';reply_text='已取消预览，没有保存。'}
            }
            'status'{
                Assert-CrmKeys $Request @('action','confirm_code')
                $p=$s.current
                if($Request.confirm_code){$c=Get-CrmConfirmCode ('确认 '+$Request.confirm_code);$matches=@(@($s.history)+@($s.current)|Where-Object {$_ -and $_.code -ceq $c});if($matches.Count -ne 1){throw '没有找到这个预览。'};$p=$matches[0]}
                if(-not $p){return @{status='empty';reply_text='当前没有待确认操作。'}}
                if($p.actor -cne $Context.member){return @{status='busy';reply_text='群内存在另一人的操作，查询可以继续。'}}
                if($p.status -in @('executing','unknown')){return Resolve-WeddingOperation $s}
                if($p.status -eq 'pending'){return @{status='pending';preview=$p;reply_text=(Get-WeddingPreviewText $p)}}
                return @{status=$p.status;record=$p.result;reply_text=('这笔操作'+@{completed='已完成，本次没有重复保存。';invalidated='已失效。';cancelled='已取消。'}[$p.status])}
            }
            default{throw '不支持的婚宴操作。'}
        }
    }finally{if($handle){$handle.Dispose()}}
}

if($MyInvocation.InvocationName -ne '.'){
    [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
    $script:CrmEvidence=New-Object Collections.ArrayList
    try {
        . 'D:\Multica-CRM-Trial\ops\Trial.ps1';Assert-TrialRuntime
        $script:WeddingConfig=Read-CrmJson 'D:\Multica-CRM-Trial\skills\wedding-demo\connection.json'
        if($script:WeddingConfig.ready -ne $true -or $script:WeddingConfig.profile -cne 'crm-trial' -or $script:WeddingConfig.identity -cne 'bot' -or $script:WeddingConfig.cli_path -cne 'D:\Multica-CRM-Trial\tools\lark-cli\lark-cli.exe'){throw '婚宴固定工具配置尚未核验。'}
        foreach($k in @('base_token','orders_table_id')){if($script:WeddingConfig[$k] -cnotmatch '^[A-Za-z0-9]+$'){throw '婚宴资源标识无效。'}}
        $script:CrmConfig=Copy-Wedding $script:WeddingConfig
        $script:CrmConfig.customers_table_id=$script:WeddingConfig.orders_table_id
        $script:CrmWorkDir=(Get-Location).ProviderPath
        if(-not $script:CrmWorkDir.StartsWith('D:\Multica-CRM-Trial\runtime\workspaces\',[StringComparison]::OrdinalIgnoreCase)){throw '请在原生本次运行目录调用工具。'}
        if([IO.Path]::IsPathRooted($weddingRequestFile) -or [string]::IsNullOrWhiteSpace($weddingRequestFile)){throw '请求文件必须为本次运行目录下的相对路径。'}
        $path=[IO.Path]::GetFullPath((Join-Path $script:CrmWorkDir $weddingRequestFile))
        if(-not $path.StartsWith($script:CrmWorkDir.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $path.Substring(2).Contains(':')){throw '请求路径越界。'}
        $script:WeddingStatePath='D:\Multica-CRM-Trial\runtime\wedding-demo-state.json'
        $context=Get-CrmContext
        $result=Invoke-WeddingRequest (Read-CrmJson $path) $context
        $result.evidence=@($script:CrmEvidence);$result|ConvertTo-Json -Depth 40
    }catch{
        $message=$_.Exception.Message
        $reply=if($message -match '[\u4e00-\u9fff]' -and $message -notmatch '[A-Za-z]:\\'){$message}else{'本次操作未能完成核验。若刚才尝试保存，请先查证结果，不要重复提交。'}
        @{status='error';reply_text=$reply;evidence=@($script:CrmEvidence);diagnostic=$message}|ConvertTo-Json -Depth 8;exit 1
    }
}
