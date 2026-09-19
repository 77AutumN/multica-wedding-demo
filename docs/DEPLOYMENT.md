# 部署与回退

本仓库是现有试用环境的业务扩展，不是新电脑的一键初始化器。现有部署为 D:\Multica-CRM-Trial，专用非管理员账户 multica-trial，daemon profile crm-trial，并发1。初始化脚本、账户授权和固定启停任务是本机前置依赖；版本及哈希见 dependency-baseline.json。

## 固定版本

Multica前后端与CLI 0.4.44；Claude Code 2.1.261；Lark CLI 1.0.90。实际婚宴 Run 的 task_usage 已核验模型为 claude-sonnet-5，Agent没有模型覆盖；本轮没有主动换模型。

## 候选切换

1. 服务正常且空闲时，归档现有指令、绑定、状态和数据；执行中/待查证操作必须先查清。
2. 按明确清单部署 ops 中两个工具、婚宴 Skill、references 和 Agent 指令。生产 Trial.ps1 不从本仓库替换。保留原文件访问权限，专用账户不能修改业务源码或配置。
3. 现有CRM连接配置关闭写入，保留原工具、Skill及数据用于回退。婚宴使用本机已验证的新Base配置，不使用 examples 中的空配置。
4. 初次发布才初始化婚宴状态，并导入最新旧CRM已用码；已存在婚宴状态时必须保留、核查，禁止用空模板覆盖。
5. 原生界面绑定婚宴Skill并设置中文Agent指令和展示名，使用新会话并同步核验允许的群绑定；不直接修改应用数据库。
6. 先 writes_enabled=false 验证两账号空表查询；再仅开放 bootstrap_only=true 的第一条样例确认。首条样例查询、询价通过后才关闭 bootstrap_only，开始完整写入验收。

部署记录保存提交号、文件哈希、依赖哈希、绑定及配置版本。CI不连接现场或执行部署。验收后的 squash 提交须与实际运行的业务文件内容一致。

## 启停与备份

沿用现场六个脚本：Start-Services、Start-Agent、Status、Stop-Agent、Stop-Services、Backup-Trial。daemon通过已有固定Start/Stop任务运行；服务只绑定本机。停止保留卷。

完整备份包含数据库、附件、状态、配置、工具、证据、专用账户材料和最新婚宴Base只读快照。隔离恢复仅核对文件哈希和数据库，不启动Bot或业务执行，不覆盖远端Base。GitHub不代替数据备份。

## 发布与回退

真实三轮和关键拒绝场景通过、备份恢复完成后，Codex更新脱敏结果、确认CI通过、squash merge，发布 wedding-demo-v0.1.0。未完成时只标候选。

回退前先处理不明结果，成套恢复原CRM入口、指令和Skill绑定；保留婚宴原始证据及远端记录。普通旧预览不得复活，不撤销已完成的业务写入。回退后先验证两账号只读，再开放写入。
