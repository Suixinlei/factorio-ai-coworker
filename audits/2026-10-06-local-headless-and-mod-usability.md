# 本地 headless 开发链路 + mod 0.6.5 可用性修复

日期：2026-10-06（Asia/Shanghai）

## 目标

1. 把 Factorio MCP 的开发/迭代链路从远程 kouka 切到**本地 headless 服务器**，
   沉淀为可复用的 skill 与启动脚本。
2. 修复测试过程中发现的 mod 可用性 bug，让 agent 不查源码就能正确使用各工具。
3. 重写 `skills/factorio-ai-coworker/SKILL.md` 为中文，附精确参数表。
4. 移除项目内的 kouka 部署逻辑。

## 本地 headless 链路

- 脚本：`scripts/local-headless.sh`
  - 游戏端口 `34198`，RCON `127.0.0.1:27016`
  - 自动创建 `local-server/saves/dev-map.zip` 测试图
  - 自动生成 `local-server/rcon.pw`
  - 日志 `local-server/server.log`
- Skill：`skills/factorio-local-dev/SKILL.md`
- `opencode.json` 已切到本地 RCON（`127.0.0.1:27016`）。
  **改完后需重启一次 OpenCode 会话**，MCP 服务器才会连本地。
- `local-server/` 已加入 `.gitignore`。
- 验证：本地服成功加载 `ai-coworker 0.6.5`，RCON `list_skills` 返回正确列表。

## mod 0.6.5 修复

| 问题 | 修复位置 | 说明 |
|---|---|---|
| `session(spawn)` 对活角色误报 `ok:false` | `mod/control.lua` | 返回的 summary 增加 `ok=true`（同时保留另一会话在 `set_annotation` 加的 `ok=true`）。 |
| `gather` 背包已满足时误报“无资源” | `mod/scripts/skills.lua` | 提前返回 `ok=true` + “already have N (need M)”。 |
| `goto` 只接受 `position` 对象 | `mod/scripts/skills.lua` | 同时支持平铺 `x`/`y`。 |
| `build_miner` 最近一格被挡就失败 | `mod/scripts/skills.lua` | 尝试最近 12 个矿格 × 4 方向。 |
| `loot_chests`/`deposit_to_chest` 的 `item`/`count` 被静默忽略 | `mod/scripts/skills.lua` | 支持精确 `item+count`；无参数时保留旧行为。 |
| `research` 指定科技名失败时落入 autopilot | `mod/scripts/skills.lua` | 点名时幂等/报错，绝不 fallback；仍支持无参数 autopilot。 |
| query 参数形态不统一 | `mod/scripts/queries.lua` | `get_recipe` 支持 `recipe` 别名；`can_place`/`nearest_buildable` 支持 `item` 别名；`inspect_entity`/`can_place`/`nearest_buildable`/`get_resource_patch`/`get_enemies` 同时支持 `position={x,y}` 与平铺 `x`/`y`。 |

## 验证结果

在本地 headless 服务器上逐项验证：

- `create_agent` / `spawn_agent` 均返回 `ok=true` ✓
- `gather` 背包满足时返回 `ok=true` ✓
- `goto` 同时支持 `position` 对象与 `x`/`y` ✓
- `get_recipe` 用 `recipe=`、`can_place`/`nearest_buildable` 用 `item=`、`inspect_entity` 用 `position=` 均通过 ✓
- `research` 指定不可排科技时显式报错，未落入 autopilot ✓
- `build_miner` 在铁矿面成功放置钻机+收集箱 ✓
- `deposit_to_chest` + `loot_chests` 精确 `item+count`（存 10 木、取 5 木）✓
- `factorio-ai-coworker` skill 已重写为中文参数表。

## 项目结构变更

- 删除 `deployment/2026-10-04-kouka.md`。
- `README.md` 改为本地开发说明，仅保留 kouka 历史脚注。
- 远程 `opencode-helper-2` 等角色异常被清事件已在 `cf559e1 Reset project roles and remove AO dispatch` 中记录；本次远程清理了测试角色 `opencode-fixtest`。

## 复现

```bash
# 1. 启动本地服
./scripts/local-headless.sh

# 2. 改 mod 后打包替换
node make-zip.js mod /tmp/ai-coworker_0.6.X.zip ai-coworker_0.6.X
cp /tmp/ai-coworker_0.6.X.zip "$HOME/Library/Application Support/factorio/mods/"
pkill -f "start-server local-server/saves/dev-map.zip"
./scripts/local-headless.sh

# 3. RCON 冒烟
PW=$(cat local-server/rcon.pw)
FACTORIO_RCON_HOST=127.0.0.1 FACTORIO_RCON_PORT=27016 FACTORIO_RCON_PASSWORD="$PW" \
  .venv/bin/python -c "from bridge.factorio.rcon import RCONGateway; ..."
```
