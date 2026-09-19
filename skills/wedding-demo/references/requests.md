# 固定接口 0.1.0

所有请求均为 JSON 对象。工具输出 `status`、中文 `reply_text` 及内部回读证据。无 `order_no` 表示当前保存的轮次；历史订单仅支持查询。

```json
{"action":"query"}
{"action":"query","entity":"outstanding"}
{"action":"query","entity":"history","order_no":"HY-实际编号"}
{"action":"query","entity":"estimate","fields":{"total_tables":31}}
{"action":"preview","kind":"order.change","fields":{"total_tables":31,"special_tables":3,"menu":"无海鲜套餐"}}
{"action":"preview","kind":"order.change","fields":{"total_tables":32}}
{"action":"preview","kind":"handoff.update","fields":{"version":2,"receive":true}}
{"action":"preview","kind":"handoff.update","fields":{"version":2,"menu_handoff":"已落实","layout":"待落实"}}
{"action":"preview","kind":"handoff.update","fields":{"version":2,"receive":true,"layout":"有问题","layout_reason":"布桌图需要核对"}}
{"action":"preview","kind":"demo.new_round","fields":{}}
{"action":"confirm","text":"确认 用户本次实际提供的六位码"}
{"action":"cancel"}
{"action":"status"}
{"action":"status","confirm_code":"用户提供的六位码"}
```

上方是独立请求示例，不是一个可一次提交的文件。`confirm` 不接受其他业务字段。

`layout` 对应布桌方案核对，`menu_handoff` 对应菜单变更交接；各自支持待落实、已落实、有问题。原因分别用 `layout_reason`、`menu_reason`；有问题时必填。单改日期、折扣、婚期、未知套餐不支持。

省略的修改字段由工具保留；新订单默认 28 桌、特殊菜单 0 桌，普通桌数由总桌数减特殊桌数得到。每桌 300000 分，最多 32 桌。业务版本仅在订单内容变化时递增。反馈必须属于当前版。

所有远端数据写入由同一工具完成；禁止新增其他参数、直接提交金额、复用 CRM 入口或用旧 CRM 确认码。
