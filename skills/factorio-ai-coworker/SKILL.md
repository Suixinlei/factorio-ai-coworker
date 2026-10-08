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

所有执行统一用一个 JSON 数组，每次最多 4 个条目：

```bash
.venv/bin/python -m cli --agent-id ID step \
  '[{"action":"gather","item":"iron-ore","count":50},{"action":"research"}]'
```

`action` 键同时支持下表的组合 action 和原子 action；`skill` 键仍兼容组合 action。CLI 的
`--dry-run` 只校验名称和 JSON，不联系游戏；`--continue-on-failure` 才会在失败后继续。

### 组合 action

| action | 参数 | 说明 |
|---|---|---|
| `build_ghosts` | 无 | 建造 ghost，自动审查并记录最近批次。 |
| `deconstruct` | `radius` 默认 96 | 只拆除已标记拆除的实体，不自动砍树。 |
| `clear_area` | `area` 或 `x,y,width,height` 或 `position+radius`；`kinds` 默认 `trees,rocks,marked` | 已授权清理自然障碍，不碰未标记建筑；单次有界，按 `remaining` 重试。 |
| `plan_blueprint` | `entities=[{name,x,y,direction?}]` ≤500 | 按精确坐标创建不过期 ghost；仅水格拒绝。 |
| `place_batch` | `entities=[{name,x,y,direction?}]` ≤500，或 `use:"last_plan"` | 只执行列表中已有 ghost；坐标/朝向须完全一致，缺料原子失败。`use:"last_plan"` 直接执行本角色最近一次 `plan_mining_outpost` 登记的全部未建 ghost（≤1000），坐标无需回传。 |
| `review_build` | `area={x,y,width,height}` 或 `x,y,radius` | 审查己方实体状态、问题实体和未建 ghost；缺省审查最近批次。 |
| `clear_ghosts` | `area` 或 `x,y,radius`，可选 `name` | 批量清除 ghost，绝不碰真实建筑。 |
| `plan_mining_outpost` | `resource`、可选 `x,y,direction,drill,pole,belt,min_ore,max_drills` | 自动规划矿机、皮带和电线杆 ghost；先查矿点，备料后用 `place_batch`（`use:"last_plan"`）施工。 |
| `gather` | `item`，可选 `count` 默认 50 | 采集最近资源或树；库存已满足时幂等返回。 |
| `fill` | `items` 或 `item+count`，可选 `radius` | 向周围可接收实体填充燃料、原料、科研包或弹药；无参数智能补给。 |
| `collect` | `items` 或 `item+count`，可选 `radius` | 从容器按最近优先收取精确数量，没有全拿模式。 |
| `deposit_to_chest` | `item+count` 或 `keep+radius` | 精确存物，或按 keep 存多余物资。 |
| `return_home` | 无 | 回到出生锚点。 |
| `goto` | `position={x,y}` 或 `x,y` | 传送到目标坐标。 |
| `research` | `tech`/`technology`/`name` 或空 | 空参数按偏好选科技；指定名称失败不 fallback。 |

### 原子 action

| action | 参数 | 说明 |
|---|---|---|
| `move` | `direction`、`distance` | 向 north/south/east/west 等移动。 |
| `mine` | `name`、`type` 或 `position`，可选 `radius` | 挖指定实体；`type=tree` 可砍树。 |
| `place` | `item`、`position`、可选 `direction` | 放置建筑。 |
| `set_recipe` | `recipe`、`position` | 只支持组装机，不支持熔炉。 |
| `craft` | `recipe`、`count` | 手搓物品。 |
| `pickup` | `position` | 捡起地面物品。 |
| `chat` | `message` | 发送游戏内聊天。 |
| `insert` | `item`、`count`、`position`、可选 `inventory` | 塞入实体库存；如 `inventory=fuel`。 |
| `take` | `item`、`count`、`position`、可选 `inventory` | 从实体库存取物。 |
| `summary` | `text` | 写入角色记忆摘要。 |
| `wait` | 无 | 等待一回合。 |

## Queries

调用 `.venv/bin/python -m cli --agent-id ID query KIND --params '{}'`。支持：

| kind | 参数 |
|---|---|
| `get_recipe` | `name` 或 `recipe` |
| `get_resource_patch` | `resource`、`radius`；`all=true` 或 `radius=0` 查全部已探知矿点 |
| `can_place` | 放置实体及坐标参数 |
| `nearest_buildable` | 实体及搜索位置参数 |
| `scan_area` | `x/y`、`width`、`height` ≤128 |
| `inspect_entity` | `x/y` 或 `position`、`radius`、`name` |
| `get_enemies` | `x/y` 或 `position`、`radius` ≤200 |
| `get_character_state` | 无 |
| `get_chart_tags` | 可选 `x/y`、`radius` |

`map` 是 `scan_area` 的便捷入口，返回地形网格和精确实体清单。`?` 是未探索，`W` 水，`T`
树，`R` 石，`B` 己方建筑，`g` ghost，资源字符为 `i/u/c/s/o/U/x`。

## 建设原则

- 一切最终自动化；早期手搓或手动补给只是过渡。
- 美观优先于紧凑：主干道留间距，冶炼区和总线区对齐模数。
- 标准流程：`map` → 规划 → `clear_area` → `plan_blueprint` → 备料 → `place_batch` → `review_build` → 标注；整片矿走 `plan_mining_outpost` → 备料 → `place_batch`（`use:"last_plan"`）。
- 不允许盲铺；未扫描区域不放大型阵列，阵列必须有显式坐标。

## 放置语义和安全边界

- 机械臂 `direction` 指向取货侧；钻机接带前先 `inspect_entity` 看 `drop_position`。
- 奇数尺寸轴用 `n+0.5`，偶数尺寸轴用整数；east/west 会交换宽高。CLI 不会自动对齐，非法坐标直接拒绝。
- 离岸泵等非对称碰撞盒需要错开一格；被拒时检查邻居碰撞。
- 不要对 `deconstruct` 自作主张；`clear_area` 只清树、石和已标记对象，不碰未标记建筑。
- 不要占用别的 builder 角色。`collect` 必须指定精确物品和数量。
- 不调用任意 Lua，不删除角色，不重启存档；这些操作需要用户明确授权并记录。

## 常见循环

```text
cli status/catalog/session list
→ cli --agent-id ID state
→ cli --agent-id ID map
→ cli --agent-id ID query get_resource_patch --params '{"resource":"iron-ore","all":true}'
→ cli --agent-id ID step '[{"action":"goto",...}]'
→ cli --agent-id ID step '[{"action":"clear_area",...}]'
→ cli --agent-id ID step '[{"action":"plan_blueprint",...}]'
→ cli --agent-id ID step '[{"action":"place_batch","entities":[...]}]'
→ cli --agent-id ID step '[{"action":"place_batch","use":"last_plan"}]'   # 矿阵
→ cli --agent-id ID step '[{"action":"review_build"}]'
→ cli --agent-id ID annotate --map-tag-json '{"text":"产线","position":...}'
```

完成一个工作单元后报告：角色 ID、已完成动作、当前位置/工厂状态、缺少材料或被阻塞的下一步。
