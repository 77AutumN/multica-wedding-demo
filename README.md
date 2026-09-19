# Multica 婚宴 Demo

私有业务扩展源码仓库。飞书对话由现有 Multica 提供，本仓库维护婚宴样例工具、Skill、规则和检查。

当前：0.1.0 候选，三轮真实飞书验收通过；完整备份恢复及正式发布收尾中。

源码位于 `D:\multica-wedding-demo`，现有部署保持 `D:\Multica-CRM-Trial`。运行目录不是 Git 工作区。

## 协作

功能分支提交 PR，Codex 完成检查、审查、本机候选验收后 squash merge；正式发布创建独立标签。用户已授权常规检查、合并和发布，无需逐次确认。不得把同一 GitHub 账号的操作描述为两人独立审批。

仓库仅保存源码、脱敏说明和配置示例。实际连接配置、凭据、原始聊天、状态、Base 快照、数据库、附件和备份留在本机。

GitHub 离线检查不连接飞书，不启动 Claude、Multica 或 Docker。离线通过不等于演示验收通过。

入口：[开发与检查](docs/DEVELOPMENT.md)、[部署回退](docs/DEPLOYMENT.md)、[演示话术](docs/DEMO.md)、[实际验收状态](docs/ACCEPTANCE.md)。
