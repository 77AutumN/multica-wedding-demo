param([string]$OutputDirectory = [IO.Path]::GetTempPath())
$ErrorActionPreference='Stop'
. "$PSScriptRoot\..\ops\Invoke-WeddingDemo.ps1"
$script:CrmConfig=@{members=@(@{member_key='sample-owner';display_name='销售样例'},@{member_key='sample-test';display_name='宴会负责人样例'})}
$script:WeddingConfig=@{sales_member=$script:CrmConfig.members[0].member_key;banquet_member=$script:CrmConfig.members[1].member_key;multica_chat_id='offline-chat';deployment_id='wedding-0.1.0';writes_enabled=$true;rules=@{version='sample-v1';unit_cents=300000;capacity=32;standard_menu='标准套餐';special_menu='无海鲜套餐'}}
$script:TestDir=Join-Path $OutputDirectory ('wedding-offline-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory -Path $script:TestDir)
$script:WeddingStatePath=Join-Path $script:TestDir 'state.json'
$script:Owner=@{member=$script:WeddingConfig.sales_member;chat='offline-chat';task='offline-owner'}
$script:Guest=@{member=$script:WeddingConfig.banquet_member;chat='offline-chat';task='offline-test'}
$script:SaveOriginal=${function:Save-WeddingState};$script:RandomOriginal=${function:New-CrmRandomCode}
$script:Checks=New-Object Collections.ArrayList
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Reject([scriptblock]$Body){$failed=$false;try{& $Body | Out-Null}catch{$failed=$true};Assert $failed 'Expected rejection'}
function Check([string]$Name,[scriptblock]$Body){Reset;try{& $Body;[void]$script:Checks.Add(@{name=$Name;passed=$true});Write-Output "PASS $Name"}catch{[void]$script:Checks.Add(@{name=$Name;passed=$false;error=$_.Exception.Message});Write-CrmJson (Join-Path $script:TestDir 'checks.json') @($script:Checks);throw}}
function Reset {
    $script:Rows=@();$script:Writes=0;$script:Boot='boot1';$script:Failure='';$script:SaveFailure='';$script:Collision=0
    $script:WeddingConfig.rules.unit_cents=300000;$script:WeddingConfig.writes_enabled=$true;$script:WeddingConfig.deployment_id='wedding-0.1.0'
    $script:WeddingConfig.bootstrap_only=$false
    Write-CrmJson $script:WeddingStatePath @{schema_version=1;active=$null;current=$null;history=@();reserved_codes=@('AAAAAA');used_codes=@('AAAAAA')}
}
function Get-CrmDaemon {return @{id='offline';pid=42;started=$script:Boot}}
function Get-WeddingRows {foreach($r in $script:Rows){Copy-Wedding $r}}
function Save-WeddingState($State){
    if($script:SaveFailure -eq 'all' -or ($script:SaveFailure -eq 'completed' -and -not $State.current -and @($State.history|Where-Object {$_.status -eq 'completed'}).Count -gt 1)){throw 'Simulated state save failure'}
    & $script:SaveOriginal $State
}
function Write-WeddingRow($Fields,[string]$RecordId){
    Assert ((Read-WeddingState).current.status -eq 'executing') 'Executing must be durable before write'
    $script:Writes++
    if($script:Failure -eq 'before'){throw 'Simulated timeout before known result'}
    if($RecordId){$r=@($script:Rows|Where-Object {$_.record_id -ceq $RecordId});Assert ($r.Count -eq 1) 'Missing row';foreach($k in $Fields.Keys){$r[0][$k]=$Fields[$k]}}
    else{$r=Copy-Wedding $Fields;$r.record_id='recOffline'+$script:Writes;$script:Rows=@($script:Rows)+@($r)}
    if($script:Failure -eq 'mismatch'){$script:Rows[-1]['金额分']=1}
    if($script:Failure -eq 'after'){throw 'Simulated response lost after successful write'}
    return @{ok=$true;identity='bot'}
}
function Preview([string]$Kind,$Fields=@{},$Actor=$script:Owner){Invoke-WeddingRequest @{action='preview';kind=$Kind;fields=$Fields} $Actor}
function Confirm([string]$Code,$Actor=$script:Owner){Invoke-WeddingRequest @{action='confirm';text=('确认 '+$Code)} $Actor}
function Begin-Round {$p=Preview 'demo.new_round';$r=Confirm $p.preview.code;Assert ($r.status -eq 'completed') 'Round creation failed';return $r.record}
Check '三轮主故事、版本、金额、历史和分项反馈' {
    $ids=@()
    for($n=0;$n -lt 3;$n++){
        $r=Begin-Round;$ids+=$r['订单编号'];Assert ($r['总桌数'] -eq 28 -and $r['金额分'] -eq 8400000) 'Initial sample wrong'
        $before=$script:Writes;$estimate=Invoke-WeddingRequest @{action='query';entity='estimate';fields=@{total_tables=31}} $script:Owner
        Assert ($estimate.estimate['金额分'] -eq 9300000 -and $script:Writes -eq $before -and (Read-WeddingState).active.fields['业务版本'] -eq 1) 'Estimate wrote or wrong'
        $p=Preview 'order.change' @{total_tables=31;special_tables=3;menu='无海鲜套餐'};$r=Confirm $p.preview.code
        Assert ($r.record['业务版本'] -eq 2 -and $r.record['金额分'] -eq 9300000 -and $r.record['接收状态'] -ceq '待接收') 'Order change failed'
        $p=Preview 'handoff.update' @{version=2;receive=$true} $script:Guest;[void](Confirm $p.preview.code $script:Guest)
        $p=Preview 'handoff.update' @{version=2;menu_handoff='已落实';layout='待落实'} $script:Guest;[void](Confirm $p.preview.code $script:Guest)
        $todo=Invoke-WeddingRequest @{action='query';entity='outstanding'} $script:Owner
        Assert ($todo.reply_text.Contains('布桌方案核对') -and -not $todo.reply_text.Contains('菜单变更交接')) 'Outstanding merged handoffs'
        $p=Preview 'handoff.update' @{version=2;layout='已落实'} $script:Guest;$r=Confirm $p.preview.code $script:Guest
        Assert ($r.record['业务版本'] -eq 2 -and $r.reply_text.Contains('本次变更交接完成')) 'Feedback changed business version'
    }
    Assert ($script:Rows.Count -eq 3 -and @($ids|Select-Object -Unique).Count -eq 3 -and $script:Writes -eq 15) 'Duplicate round or writes'
    $history=Invoke-WeddingRequest @{action='query';entity='history';order_no=$ids[0]} $script:Owner
    Assert ($history.history.Count -eq 5) 'Lost historical evidence'
    Reject {Invoke-WeddingRequest @{action='preview';kind='order.change';order_no=$ids[0];fields=@{total_tables=30}} $script:Owner}
}
Check '自然纠正合并、旧码、取消与无效确认文字' {
    [void](Begin-Round);$p=Preview 'order.change' @{total_tables=31;special_tables=3};$q=Preview 'order.change' @{total_tables=32}
    Assert ($q.preview.new_values['特殊菜单桌数'] -eq 3 -and $p.preview.code -cne $q.preview.code) 'Correction lost fields'
    Assert ((Confirm $p.preview.code).status -eq 'invalidated') 'Old code usable'
    foreach($text in @('好的','不要确认 '+$q.preview.code,'他说确认 '+$q.preview.code,'确认 '+$q.preview.code+'，但改到30桌','确认 '+$q.preview.code+' '+$p.preview.code)){Reject {Invoke-WeddingRequest @{action='confirm';text=$text} $script:Owner}}
    [void](Invoke-WeddingRequest @{action='cancel'} $script:Owner);Assert ((Confirm $q.preview.code).status -eq 'cancelled') 'Cancelled code usable'
    Assert ($script:Writes -eq 1) 'Invalid confirmation wrote'
}
Check '销售与宴会负责人权限、越人确认取消及身份伪造' {
    [void](Begin-Round)
    Reject {Preview 'demo.new_round' @{} $script:Guest};Reject {Preview 'order.change' @{total_tables=30} $script:Guest};Reject {Preview 'handoff.update' @{version=1;receive=$true} $script:Owner}
    $p=Preview 'order.change' @{total_tables=31};Reject {Confirm $p.preview.code $script:Guest};Reject {Invoke-WeddingRequest @{action='cancel'} $script:Guest}
    Reject {Preview 'handoff.update' @{version=1;receive=$true} $script:Guest}
    Reject {Invoke-WeddingRequest @{action='query';identity='owner'} $script:Guest}
    Reject {Invoke-WeddingRequest @{action='query'} @{member='fake';chat='offline-chat'}}
    Assert ((Invoke-WeddingRequest @{action='query'} $script:Guest).status -eq 'ok') 'Pending blocked reads'
    Assert ($script:Writes -eq 1) 'Unauthorized write'
}
Check '全角小写确认、错码、多码、重复确认零新增' {
    $p=Preview 'demo.new_round';Reject {Confirm 'ZZZZZZ'}
    $wide=-join @($p.preview.code.ToLowerInvariant().ToCharArray()|ForEach-Object {[char]([int]$_+65248)})
    $r=Invoke-WeddingRequest @{action='confirm';text=('确认'+$wide)} $script:Owner
    Assert ($r.status -eq 'completed') 'Full width rejected'
    [void](Confirm $p.preview.code);Assert ($script:Writes -eq 1 -and $script:Rows.Count -eq 1) 'Duplicate confirm created'
    Reject {Invoke-WeddingRequest @{action='confirm';text=('确认 '+$p.preview.code);fields=@{total_tables=32}} $script:Owner}
}
Check '桌数边界、未知菜单及禁止覆盖价格资源' {
    [void](Begin-Round)
    foreach($bad in @(0,33,-1,1.5,$true,'abc')){Reject {Preview 'order.change' @{total_tables=$bad}}}
    Reject {Preview 'order.change' @{total_tables=29;special_tables=30}}
    Reject {Preview 'order.change' @{total_tables=29;menu='豪华龙虾套餐'}}
    foreach($field in @('amount','price','base_token','app_id','member','command','wedding_date')){Reject {Preview 'order.change' @{$field='override'}}}
    Assert ($script:Writes -eq 1) 'Boundary wrote'
}
Check '无变化不写入、不增加版本；纠正回原值废弃旧码' {
    [void](Begin-Round);Assert ((Preview 'order.change' @{total_tables=28}).status -eq 'unchanged') 'No-op wrote'
    $p=Preview 'order.change' @{total_tables=31};Assert ((Preview 'order.change' @{total_tables=28}).status -eq 'unchanged') 'Correction no-op failed'
    Assert ((Confirm $p.preview.code).status -eq 'invalidated') 'Superseded code survived no-op'
    $p=Preview 'handoff.update' @{version=1;receive=$true;menu_handoff='已落实'} $script:Guest;[void](Confirm $p.preview.code $script:Guest)
    Assert ((Preview 'handoff.update' @{version=1;receive=$true;menu_handoff='已落实'} $script:Guest).status -eq 'unchanged') 'Feedback no-op wrote'
    Assert ($script:Writes -eq 2) 'No-op emitted write'
}
Check '有问题必须说明原因，合并接收反馈，订单变更重置旧反馈' {
    [void](Begin-Round);Reject {Preview 'handoff.update' @{version=1;layout='已落实'} $script:Guest}
    Reject {Preview 'handoff.update' @{version=1;receive=$true;layout='有问题'} $script:Guest}
    $p=Preview 'handoff.update' @{version=1;receive=$true;layout='有问题';layout_reason='需要调整座位';menu_handoff='已落实'} $script:Guest;$r=Confirm $p.preview.code $script:Guest
    Assert ($r.record['业务版本'] -eq 1 -and $r.record['布桌方案核对原因'] -ceq '需要调整座位') 'Combined feedback wrong'
    $p=Preview 'order.change' @{total_tables=31};$r=Confirm $p.preview.code
    Assert ($r.record['业务版本'] -eq 2 -and $r.record['接收状态'] -ceq '待接收' -and $r.record['菜单变更交接'] -ceq '待落实' -and -not $r.record['布桌方案核对原因']) 'Old feedback leaked'
    Reject {Preview 'handoff.update' @{version=1;receive=$true} $script:Guest}
}
Check '预览后外部冲突停止写入，不能以本地覆盖远端' {
    [void](Begin-Round);$p=Preview 'order.change' @{total_tables=31};$script:Rows[0]['场地']='被外部修改'
    Assert ((Confirm $p.preview.code).status -eq 'conflict') 'Conflict not detected'
    Reject {Preview 'order.change' @{total_tables=30}};Assert ($script:Writes -eq 1) 'Conflict overwritten'
}
Check '重启和发布切换废弃普通预览' {
    [void](Begin-Round);$p=Preview 'order.change' @{total_tables=31};$script:Boot='boot2';Assert ((Confirm $p.preview.code).status -eq 'invalidated') 'Restart left pending usable'
    $p=Preview 'order.change' @{total_tables=31};$script:WeddingConfig.deployment_id='next';Assert ((Confirm $p.preview.code).status -eq 'invalidated') 'Release left pending usable'
    Assert ($script:Writes -eq 1) 'Restart caused write'
}
Check '计价规则改变废弃预览' {
    [void](Begin-Round);$p=Preview 'order.change' @{total_tables=31};$script:WeddingConfig.rules.unit_cents=300001
    Assert ((Confirm $p.preview.code).status -eq 'invalidated') 'Pricing fingerprint missed'
}
Check '超时结果不明阻塞新写入，状态查询不重写' {
    [void](Begin-Round);$p=Preview 'order.change' @{total_tables=31};$script:Failure='before'
    Assert ((Confirm $p.preview.code).status -eq 'unknown') 'Timeout incorrectly success'
    $script:Boot='boot2';Assert ((Confirm $p.preview.code).status -eq 'unknown') 'Unknown restart cleared operation'
    Reject {Preview 'demo.new_round'};Reject {Invoke-WeddingRequest @{action='cancel'} $script:Owner}
    Assert ($script:Writes -eq 2) 'Unknown auto retried'
}
Check '新轮次创建响应丢失，重启后只查证并切换，重复确认不新增' {
    [void](Begin-Round);$old=(Read-WeddingState).active.record_id;$p=Preview 'demo.new_round';$script:Failure='after'
    Assert ((Confirm $p.preview.code).status -eq 'unknown') 'Lost response reported success'
    Assert ((Read-WeddingState).active.record_id -ceq $old) 'Switched without readback'
    $script:Boot='boot2';$script:Failure='';$r=Invoke-WeddingRequest @{action='status'} $script:Owner
    Assert ($r.status -eq 'completed' -and (Read-WeddingState).active.record_id -cne $old) 'Reconcile failed'
    [void](Confirm $p.preview.code);Assert ($script:Rows.Count -eq 2 -and $script:Writes -eq 2) 'Reconcile wrote again'
}
Check '写后完成状态保存失败不误报，恢复只读查证' {
    [void](Begin-Round);$p=Preview 'order.change' @{total_tables=31};$script:SaveFailure='completed'
    Assert ((Confirm $p.preview.code).status -eq 'unknown') 'Failed completion reported success'
    Assert ((Read-WeddingState).current.status -eq 'unknown') 'Lost unresolved operation'
    $script:SaveFailure='';Assert ((Invoke-WeddingRequest @{action='status'} $script:Owner).status -eq 'completed') 'Recovery failed'
    Assert ($script:Writes -eq 2) 'Recovery duplicated write'
}
Check '执行中状态保存失败先于写入，损坏状态原件保留' {
    [void](Begin-Round);$p=Preview 'order.change' @{total_tables=31};$script:SaveFailure='all';Reject {Confirm $p.preview.code};Assert ($script:Writes -eq 1) 'Write before executing durable'
    $script:SaveFailure='';[IO.File]::WriteAllText($script:WeddingStatePath,'{broken');Reject {Confirm $p.preview.code}
    Assert ([IO.File]::ReadAllText($script:WeddingStatePath) -ceq '{broken') 'Corrupt state reset'
}
Check '确认码碰撞重生成与重复历史检测' {
    function script:New-CrmRandomCode {if($script:Collision -eq 0){$script:Collision++;return 'AAAAAA'};return 'BBBBBB'}
    try{$p=Preview 'demo.new_round';Assert ($p.preview.code -ceq 'BBBBBB') 'Reserved CRM code reused'}finally{Set-Item Function:New-CrmRandomCode $script:RandomOriginal}
    $s=Read-WeddingState;$s.used_codes+=@($p.preview.code);Write-CrmJson $script:WeddingStatePath $s;Reject {Read-WeddingState}
}
Check '独占锁阻止并行写入、退出后释放' {
    $lock=[IO.File]::Open($script:WeddingStatePath+'.lock',[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{Assert ((Preview 'demo.new_round').status -eq 'busy') 'Lock failed'}finally{$lock.Dispose()}
    Assert ((Preview 'demo.new_round').status -eq 'pending') 'Lock did not release'
}
Check '回读不符停留待查证，不以退出码零报成功' {
    [void](Begin-Round);$p=Preview 'order.change' @{total_tables=31};$script:Failure='mismatch'
    Assert ((Confirm $p.preview.code).status -eq 'unknown') 'Mismatched readback success'
    Assert ((Confirm $p.preview.code).status -eq 'unknown' -and $script:Writes -eq 2) 'Mismatched write retried'
}
Check '新轮次预览提醒旧轮未完成，禁止未知轮次和空上下文猜测' {
    Reject {Invoke-WeddingRequest @{action='query'} $script:Owner};[void](Begin-Round)
    $p=Preview 'demo.new_round';Assert ($p.reply_text.Contains('上一轮仍有未完成交接')) 'Incomplete warning missing'
    Reject {Invoke-WeddingRequest @{action='query';order_no='不存在'} $script:Owner}
}
Check '新轮创建前已有同编号记录，不得再次创建' {
    $p=Preview 'demo.new_round';$r=Copy-Wedding $p.preview.new_values;$r.record_id='recExisting';$script:Rows=@($r)
    Assert ((Confirm $p.preview.code).status -eq 'unknown' -and $script:Writes -eq 0) 'Duplicate round preflight missed'
    Assert ((Invoke-WeddingRequest @{action='status'} $script:Owner).status -eq 'completed') 'Existing exact outcome not reconciled'
}
Check '重复操作号或回读目标错配时阻止恢复成功' {
    $p=Preview 'demo.new_round';$script:Failure='after';[void](Confirm $p.preview.code)
    $duplicate=Copy-Wedding $script:Rows[0];$duplicate.record_id='recDuplicate';$script:Rows+=@($duplicate)
    Reject {Invoke-WeddingRequest @{action='status'} $script:Owner};Assert ($script:Writes -eq 1) 'Duplicate operation re-written'
}
Check '首条样例初始化期间只许一轮创建、查询与询价' {
    $script:WeddingConfig.bootstrap_only=$true;[void](Begin-Round)
    Assert ((Invoke-WeddingRequest @{action='query'} $script:Guest).status -eq 'ok') 'Bootstrap blocked reads'
    Assert ((Invoke-WeddingRequest @{action='query';entity='estimate';fields=@{total_tables=31}} $script:Guest).status -eq 'estimate') 'Bootstrap blocked estimate'
    Reject {Preview 'demo.new_round'};Reject {Preview 'order.change' @{total_tables=31}};Reject {Preview 'handoff.update' @{version=1;receive=$true} $script:Guest}
    Assert ($script:Writes -eq 1) 'Bootstrap allowed another write'
    $script:WeddingConfig.bootstrap_only=$false;Assert ((Preview 'order.change' @{total_tables=31}).status -eq 'pending') 'Full acceptance phase did not open'
}
Check '有效JSON中字段被截断也要停写，保留损坏原件' {
    $p=Preview 'demo.new_round';$s=Read-WeddingState;[void]$s.current.new_values.Remove('金额分');Write-CrmJson $script:WeddingStatePath $s
    $before=[IO.File]::ReadAllText($script:WeddingStatePath);Reject {Confirm $p.preview.code}
    Assert ($script:Writes -eq 0 -and [IO.File]::ReadAllText($script:WeddingStatePath) -ceq $before) 'Malformed state was executed or reset'
}
Write-CrmJson (Join-Path $script:TestDir 'checks.json') @{kind='offline-simulated';checks=@($script:Checks);passed=$script:Checks.Count;real_feishu=$false;timestamp=[datetime]::UtcNow.ToString('o')}
Write-Output "Completed $($script:Checks.Count) offline checks. Evidence: $script:TestDir"
