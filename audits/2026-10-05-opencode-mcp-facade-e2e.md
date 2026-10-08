# OpenCode MCP facade E2E verification

日期：2026-10-05

## 变更范围

- OpenCode 的 workspace 配置改为 `bridge.factorio.opencode_mcp`。
- OpenCode 默认只加载 5 个工具：`factorio_status`、`factorio_session`、
  `factorio_state`、`factorio_query`、`factorio_step`。
- `factorio_step` 支持最多 4 个有界 skill/primitive，默认遇到失败立即停止，
  并支持 `dry_run`、`expected_state` 乐观并发检查和结果 `state_hash`/`changes`。
  hash 忽略游戏 tick；执行前只比较角色、库存、机器、研究、ghost 和拆除标记等
  可影响动作的字段。
- `factorio_state` 默认返回紧凑状态，省略小型工厂的逐机器 roster，并支持
  `fields` 与 `since` 增量读取。
- 紧凑状态包含非执行性的 `next` 优先级提示，按 ghosts、拆除标记、燃料、研究和电力
  顺序给出确定性建议，减少模型重复推导。
- `build_smelter` 保留 `furnace`、`strategy`、`target_output` 等战略参数，精确施工仍由
  Factorio Runtime 完成。
- 任意 Lua 和角色移除没有放入 facade；旧 `bridge.factorio.mcp_server` 只保留给维护诊断。
- 已删除 Claude Code 专用的 `.claude/` 和 `.mcp.json` 兼容层。
- OpenCode 五角色入口设置 `OPENCODE_DISABLE_CLAUDE_CODE=1`，阻止运行时回退到
  用户级 Claude Code 规则和 skills。

## 复现步骤

在仓库根目录执行：

```bash
XDG_DATA_HOME=/tmp/opencode-mcp-e2e-data OPENCODE_DISABLE_CLAUDE_CODE=1 opencode mcp list
PYTHONPATH=. .venv/bin/python audits/2026-10-05-opencode-mcp-e2e.py
```

其中 `audits/2026-10-05-opencode-mcp-e2e.py` 通过 MCP stdio client 完成 initialize、`tools/list`、
`factorio_status`、`factorio_step(dry_run=true)` 和非法动作拒绝检查。

## 结果

### OpenCode 配置检查

通过。`opencode mcp list` 显示：

```text
● ✓ factorio connected
  /Users/xinleisui/Projects/factorio-ai-coworker/.venv/bin/python -m bridge.factorio.opencode_mcp
```

### MCP stdio 检查

通过。返回的工具集合为：

```text
factorio_status
factorio_session
factorio_state
factorio_query
factorio_step
```

`factorio_status` 返回 RCON 已连接；`factorio_step` 的 dry-run 正确接受
`gather(iron-ore, 20)` 和带有 `furnace`、`strategy`、`target_output` 的
`build_smelter` 意图参数；非法的 `run_lua` skill 被拒绝，且没有执行游戏写操作。

### 工具目录大小

使用 FastMCP 的实际 `tools/list` 模型序列化估算：

| 入口 | 工具数 | 序列化字符 | 粗略 token（字符/4） |
|---|---:|---:|---:|
| 旧 `mcp_server` | 43 | 24,499 | 约 6,125 |
| OpenCode facade | 5 | 4,139 | 约 1,035 |

实际 token 数取决于客户端 tokenizer；上表用于比较同一工作区内的相对变化。

### Mod 包检查

通过。`node make-zip.js mod /tmp/ai-coworker-0.6.1.zip ai-coworker_0.6.1`
生成 12 文件压缩包，`unzip -t` 检查通过。此次只验证本地包，没有重启 Factorio
或切换存档。
