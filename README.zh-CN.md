# Factorio AI Coworker（AI 协作者）

Factorio AI Coworker（AI 协作者）是一个开源工具集，用于在 Factorio 中构建和协同多个 AI 玩家。项目由游戏内 Mod 和轻量级、一次一命令的 RCON CLI 组成，让 AI 可以读取世界状态、保持稳定的玩家身份，并执行边界明确的组合 action、原子 action 和查询。

本项目**受 [ai-player-v3](https://github.com/Suixinlei/factorio-ai-player-workspace) 启发**。Factorio Mod、代码仓库和项目名称统一使用 `ai-coworker`；早期的 `ai-player-v3` 项目作为灵感来源保留署名。

[English README](README.md)

## 项目内容

- `mod/`：Factorio 2.0 Mod，提供动态 AI 玩家、组合 action、原子 action、查询和标注。
- `cli/`：独立命令行客户端。每次调用都会重新读取当前 RCON 配置，执行一次操作后退出。
- `skills/`：AI 玩家的操作规范和本地 headless 服务器说明。
- `audits/`：可复现的端到端验证记录和脚本。
- `scripts/local-headless.sh`：自动打包当前 Mod 并启动本地 Factorio headless 服务器。

## 快速开始

通过环境变量或 `cli/.env` 提供 RCON 配置：

```bash
FACTORIO_RCON_HOST=127.0.0.1
FACTORIO_RCON_PORT=27016
FACTORIO_RCON_PASSWORD=your-password
```

在仓库根目录执行：

```bash
.venv/bin/python -m cli status
.venv/bin/python -m cli catalog
.venv/bin/python -m cli session list
.venv/bin/python -m cli --agent-id builder state
.venv/bin/python -m cli --agent-id builder map --width 64 --height 64
.venv/bin/python -m cli --agent-id builder query get_recipe \
  --params '{"name":"iron-gear-wheel"}'
.venv/bin/python -m cli --agent-id builder step \
  '[{"action":"batch_mine","item":"iron-ore","count":50}]'
```

完整命令参数见 [`cli/README.md`](cli/README.md)。不要提交真实凭据；`.env` 文件和本地服务器数据已被 Git 忽略。

## 本地 headless 服务器

执行 `./scripts/local-headless.sh` 会打包当前 `mod/` 并启动本地服务器。默认游戏端口是 `127.0.0.1:34198`，RCON 端口是 `127.0.0.1:27016`。完整开发流程见 [`skills/factorio-local-dev/SKILL.md`](skills/factorio-local-dev/SKILL.md)。

## 安全边界

AI 操作有明确边界：组合 action 和原子 action采用白名单，查询返回结构化数据，涉及玩家的 CLI 操作必须显式指定 `agent_id`。把 AI 连接到真实服务器前，请先阅读 [`skills/factorio-ai-coworker/SKILL.md`](skills/factorio-ai-coworker/SKILL.md)。

## 发布到 Factorio Mod Portal

仓库提供了 [`scripts/publish-mod.py`](scripts/publish-mod.py)。它会生成符合要求的 `ai-coworker_<版本>.zip`，也可以通过 Factorio 的 Mod Publish API 发布：

```bash
python3 scripts/publish-mod.py --dry-run
export FACTORIO_MOD_PORTAL_TOKEN=你的 Mod Portal API Key
python3 scripts/publish-mod.py
```

请在 Factorio 账号中创建带有 `ModPortal: Publish Mods` 权限的 API Key。脚本会提交 Mod 说明、`utilities` 分类、MIT 许可证和 GitHub 源码地址。不要把 API Key 提交到 Git。

## 验证记录

仓库在 [`audits/`](audits/) 中保留本地 RCON 端到端验证记录。例如 [`audits/2026-10-08-factorio-cli-e2e.md`](audits/2026-10-08-factorio-cli-e2e.md) 记录了 CLI 冒烟运行及结果。

## 许可证

Factorio AI Coworker 使用 [MIT License](LICENSE) 开源。
