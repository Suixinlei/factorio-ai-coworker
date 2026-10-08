---
name: factorio-ai-coworker
description: 通过本地 CLI 和 RCON 操控 Factorio AI 角色；覆盖状态、查询、建造、科研、采集、标注和原子动作。
metadata:
  purpose: dynamic-factorio-role-operation
---

# Factorio AI Coworker 操作手册

从仓库根目录调用 `.venv/bin/python -m cli`。CLI 每次命令都是独立进程，会重新读取
`FACTORIO_RCON_HOST`、`FACTORIO_RCON_PORT`、`FACTORIO_RCON_PASSWORD` 或 `cli/.env`，不需要重启客户端。
每个命令必须显式传 `--agent-id`，或设置 `FACTORIO_AGENT_ID`；角色和游戏状态由 Mod 持久化。

> 开发/迭代优先使用本地 headless 服务器：见 `skills/factorio-local-dev/SKILL.md`。

## 每次会话开始

```bash
.venv/bin/python -m cli status
.venv/bin/python -m cli catalog
.venv/bin/python -m cli session list
.venv/bin/python -m cli session bind --name "你的角色名" --agent-id 稳定ID
.venv/bin/python -m cli --agent-id 稳定ID session coop --enable
.venv/bin/python -m cli --agent-id 稳定ID session autonomy --disable
.venv/bin/python -m cli --agent-id 稳定ID state --detail brief
.venv/bin/python -m cli --agent-id 稳定ID map --width 64 --height 64
```

不要占用别人的活跃角色。`catalog` 返回服务器实际注册的复合 action、查询和 CLI 原子动作。

## CLI 调用契约

### 状态、扫描、查询和标注

```bash
.venv/bin/python -m cli --agent-id ID state --detail brief
.venv/bin/python -m cli --agent-id ID map --x 0 --y 0 --width 64 --height 64
.venv/bin/python -m cli --agent-id ID query KIND --params '{"key":"value"}'
.venv/bin/python -m cli --agent-id ID annotate --label '标签' --icon signal-A
.venv/bin/python -m cli --agent-id ID annotate --map-tag-json '{"text":"中心仓库","position":{"x":10,"y":20}}'
```

`state` 输出 `state_hash`。下一次 `step` 可传 `--expected-state HASH`；CLI 会在执行前重新读取
状态，哈希不一致时拒绝整批操作。`map` 是规划前的必做感知；单边上限 128，超大区域分批扫描。

### 组合 action 和原子 action

所有执行统一用一个 JSON 数组。命令行内联输入最多 4 个条目；复杂批处理推荐使用文件，文件输入最多展开为 256 个条目：

```bash
.venv/bin/python -m cli --agent-id ID step \
  '[{"action":"batch_mine","item":"iron-ore","count":50},{"action":"research"}]'
```

`action` 键同时支持下表的 batch action 和原子 action。CLI 的
`--dry-run` 只校验名称和 JSON，不联系游戏；`--continue-on-failure` 才会在失败后继续。

组合 action 已统一使用 `batch_` 前缀；旧名称不再接受。复杂数据可以放在 action 的 `file` 字段中，CLI 会在发送前读取并展开：

```bash
cat > blueprint.json <<'JSON'
[{"name":"assembling-machine-1","x":10.5,"y":10.5},
 {"name":"transport-belt","x":12.5,"y":10.5,"direction":"east"}]
JSON
.venv/bin/python -m cli --agent-id ID step --file plan.json --dry-run
```

`plan.json` 写成 `{"steps":[{"action":"batch_create_ghost","file":"blueprint.json"}]}`；
数组文件会自动作为 `entities` 读取，超过 500 个实体会自动切成多个 batch（分块分别执行，不保证跨块原子性）。清理也可以把多个区域放在数组文件中，作为 `batch_mine` 的 `areas` 输入。

### 组合 action

| action | 参数 | 说明 |
|---|---|---|
| `batch_build_ghost` | `area`/`x,y,radius`，或 `entities=[{name,x,y,direction?}]` ≤500，或 `use:"last_plan"` | 在范围内或精确列表中批量建 ghost；精确列表先检查缺料，范围模式尽量施工并报告缺料；自动审查并记录最近批次。 |
| `batch_mine` | `mode=gather` 的 `item,count`；`mode=deconstruct` 的 `radius`；或区域参数 | 统一批量挖掘、拆除标记对象和清理区域；默认按输入形态选择模式。 |
| `batch_create_ghost` | `entities=[{name,x,y,direction?}]` ≤500；或 `layout="mining_outpost",resource`，可选 `x,y,direction,drill,pole,belt,min_ore,max_drills` | 批量创建 ghost；支持显式蓝图或自动矿区布局，并记录 last_plan。 |
| `batch_review_build` | `area={x,y,width,height}` 或 `x,y,radius` | 审查己方实体状态、问题实体和未建 ghost；缺省审查最近批次。 |
| `batch_remove_ghost` | `area` 或 `x,y,radius`，可选 `name` | 批量清除 ghost，绝不碰真实建筑。 |
| `batch_insert` | `mode=fill` 的 `items`/`item+count`，或 `mode=deposit` 的 `item+count`/`keep` | 统一批量补给机器和向箱子存物。 |
| `batch_take` | `items` 或 `item+count`，可选 `radius` | 从容器按最近优先收取精确数量，没有全拿模式。 |
| `batch_pickup` | `position` 或范围参数 | 批量捡取范围内的地面物品。 |

### 原子 action

| action | 参数 | 说明 |
|---|---|---|
| `move` | `direction`、`distance` | 向 north/south/east/west 等移动。 |
| `goto` | `position={x,y}`、flat `x/y` 或 `home=true` | 传送到目标坐标或出生锚点。 |
| `mine` | `name`、`type` 或 `position`，可选 `radius` | 挖指定实体；`type=tree` 可砍树。 |
| `place` | `item`、`position`、可选 `direction` | 放置建筑。 |
| `create_ghost` | `name`、`position`、可选 `direction` | 创建一个 ghost；由 batch 规划 action 使用。 |
| `build_ghost` | `name`、`position` | 建造一个已存在的 ghost；由 batch 施工 action 使用。 |
| `review_build` | `position`、可选 `name,radius` | 审查一个建筑的状态；供 batch 审查聚合。 |
| `remove_ghost` | `position`、可选 `name` | 删除一个 ghost；由 batch 清理 action 使用。 |
| `set_recipe` | `recipe`、`position` | 只支持组装机，不支持熔炉。 |
| `craft` | `recipe`、`count` | 手搓物品。 |
| `pickup` | `position` | 捡起一个最近的地面物品堆。 |
| `chat` | `message` | 发送游戏内聊天。 |
| `insert` | `item`、`count`、`position`、可选 `inventory` | 塞入实体库存；如 `inventory=fuel`。 |
| `take` | `item`、`count`、`position`、可选 `inventory` | 从实体库存取物。 |
| `research` | `tech`/`technology`/`name` 或空 | 加入一个科技；空参数按偏好选择一个科技。 |
| `summary` | `text` | 写入角色记忆摘要。 |
| `shoot` | `position` | 设置朝一个位置射击。 |
| `add_note` / `view_notes` | `text` / 无 | 写一条笔记 / 显示笔记。 |
| `create_todo` | `title,items` | 创建一个待办列表。 |
| `add_todo` | `title,text` | 追加一个待办事项。 |
| `complete_todo` | `title,index` | 完成一个事项，index 从 0 开始。 |
| `view_todo` | 无 | 显示待办列表。 |
| `wait` | 无 | 本次调用不操作（不暂停或推进游戏时间）。 |

## Queries

调用 `.venv/bin/python -m cli --agent-id ID query KIND --params '{}'`。支持：

| kind | 参数 |
|---|---|
| `get_recipe` | `name` 或 `recipe` |
| `get_resource_patch` | `resource`、`radius`；`all=true` 或 `radius=0` 查全部已探知矿点 |
| `can_place` | 放置实体及坐标参数 |
| `nearest_buildable` | 实体及搜索位置参数 |
| `scan_area` | `x/y`、`width`、`height` ≤128 | 返回网格和精确实体清单；实体含世界坐标、旋转后 `bounding_box`，流体设备含 `fluid_connections.target_position`/连接状态，机械臂含取放位置和燃料信息。 |
| `inspect_entity` | `x/y` 或 `position`、`radius`、`name` |
| `get_enemies` | `x/y` 或 `position`、`radius` ≤200 |
| `get_character_state` | 无 |
| `get_chart_tags` | 可选 `x/y`、`radius` |

`map` 是 `scan_area` 的便捷入口，返回地形网格和精确实体清单。`?` 是未探索，`W` 水，`T`
树，`R` 石，`B` 己方建筑，`g` ghost，资源字符为 `i/u/c/s/o/U/x`。

## 建设原则

- 一切最终自动化；早期手搓或手动补给只是过渡。
- 美观优先于紧凑：主干道留间距，冶炼区和总线区对齐模数。
- 标准流程：`map` → 规划 → `batch_mine` → `batch_create_ghost` → 备料 → `batch_build_ghost` → `batch_review_build` → 标注；整片矿走 `batch_create_ghost(layout="mining_outpost")` → 备料 → `batch_build_ghost`（`use:"last_plan"`）。
- 不允许盲铺；未扫描区域不放大型阵列，阵列必须有显式坐标。

## 放置语义和安全边界

- 机械臂 `direction` 指向取货侧；钻机接带前先 `inspect_entity` 看 `drop_position`。
- 奇数尺寸轴用 `n+0.5`，偶数尺寸轴用整数；east/west 会交换宽高。CLI 不会自动对齐，非法坐标直接拒绝。
- 离岸泵等非对称碰撞盒需要错开一格；被拒时检查邻居碰撞。
- 不要对 `batch_mine` 自作主张；`batch_mine` 的清理模式只清树、石和已标记对象，不碰未标记建筑。
- 不要占用别的 builder 角色。`batch_take` 必须指定精确物品和数量。
- 不调用任意 Lua，不删除角色，不重启存档；这些操作需要用户明确授权并记录。

## 常见循环

```text
cli status/catalog/session list
→ cli --agent-id ID state
→ cli --agent-id ID map
→ cli --agent-id ID query get_resource_patch --params '{"resource":"iron-ore","all":true}'
→ cli --agent-id ID step '[{"action":"goto",...}]'
→ cli --agent-id ID step '[{"action":"batch_mine",...}]'
→ cli --agent-id ID step '[{"action":"batch_create_ghost",...}]'
→ cli --agent-id ID step '[{"action":"batch_build_ghost","entities":[...]}]'
→ cli --agent-id ID step '[{"action":"batch_build_ghost","use":"last_plan"}]'   # 矿阵
→ cli --agent-id ID step '[{"action":"batch_review_build"}]'
→ cli --agent-id ID annotate --map-tag-json '{"text":"产线","position":...}'
```

完成一个工作单元后报告：角色 ID、已完成动作、当前位置/工厂状态、缺少材料或被阻塞的下一步。
