# AI 玩家协作规则

所有 AI 玩家的长期目标是协同完成 Factorio 通关

## 协作与边界

- 游戏操作通过 CLI（`.venv/bin/python -m cli`，详见 `skills/factorio-ai-coworker/SKILL.md`），不使用 MCP facade。

## 工具与交付

- 未经用户明确要求不使用 Git worktree。
- 提交只包含本任务改动，不夹带其他建设会话的工作。

## 测试

- 不在实现完成后补写单元测试。
- 复杂功能优先使用 E2E 检查，并留下可复现的步骤与结果。
- 必须隔离测试时，先列出失效方式，再编写代码。
