# E2E：地图感知与规划工作流（ai-coworker 0.7.0）

日期：2026-10-06
环境：本地 headless（`scripts/local-headless.sh`，mod 0.7.0）

## 背景

用户反馈两个感知缺陷：AI 看不到整体地图，导致接线/传送带混乱、冶炼线铺到矿上。
授权三项改造 + 一条规则改写（`clear_area` 允许自动清理树/石头，无需预先标记；
未标记建筑仍不可碰）。

## 改动

- `scan_area` 查询 + 独立 `factorio_map` MCP 工具（地形网格 + 精确实体清单，
  限当前星球已探知区块，单边 ≤128，可多次扫描拼接）。
- `get_resource_patch` 支持 `all=true`：无半径上限，返回已探知地图全部矿点
  （tile 邻接聚类，crude-oil 用 24 格松散合并）。
- 新 skill `clear_area`：自动清理区域内树/石头（kinds 默认 trees,rocks,marked），
  有界执行并报告 remaining；悬崖只报告。
- 新 skill `plan_blueprint`：≤500 条实体一次性放成不过期 ghost
  （blueprint_ghost 合法性校验，整数坐标对齐 tile 中心），后续由 `build_ghosts` 执行。
- 文档：SKILL.md（工具表、megabase 建设原则、标准工作流、标注规范
  `[类型] 名称 @角色`、安全边界改写、常见循环）、README、api.py、prompt.py、
  FastMCP instructions。

## 复现步骤

1. 重启本地 headless（自动打包 0.7.0）。
2. RCON 直跑脚本（绑定测试角色 `e2e-map-070`）执行上述查询与技能。

## 结果

| 检查 | 结果 |
|---|---|
| scan_area 64×48 | 返回 origin/grid/explored_pct=100，字符正确（`.`/`T`） |
| get_resource_patch all（铁） | 11 个 patch 聚类，total_tiles=8099，按距离排序 |
| get_resource_patch 旧模式（radius=64 无煤） | `found=false`，行为不变 |
| clear_area radius=24 | 清 12 棵树，无需预标记 |
| plan_blueprint 5 条（含 1 非法名） | 放 4 ghost，跳过 1 并给出原因 |
| scan_area 验证 ghost | 网格中正确显示 `g`（3 传送带 + 1 石炉） |
| clear_area kinds=marked 无标记 | 安全返回 "nothing to clear"，不碰建筑 |
| Python 侧 | ast 解析通过；facade allowlist 含新 skill/query；7 个工具注册 |

## 遗留

- scan_area 单边 128/调用为硬性 token/性能上限，大区域需多次调用（文档已注明）。
- 极小的 1 格残留矿点会作为独立 patch 出现（已枯竭 tile），不影响规划。
- 悬崖清理需要 cliff explosives，暂只报告。
- 旧版 `mcp_server.py`（诊断用）未加新工具，保持现状。

## 追加：0.7.1 修复 + 铜矿自动化产线全流程实测（MCP 工具直连）

### 修复

- `set_annotation` 前向引用 nil global `summary`（0.6.x 就存在的 bug，
  factorio_annotate 必失败）→ `summary` 声明前移，0.7.1。
- `plan_blueprint` 坐标对齐：1×1 实体 snap 到 tile 中心（.5）、2×2 snap 到
  整数角点（.0），此前统一 +0.5 依赖引擎二次吸附。
- `scripts/local-headless.sh` 补 `--server-settings`（此前 server-settings.json
  根本没被加载，autopause 导致 wait 空转）；`allow_commands: "admins"` 是 1.x
  旧值，改为 2.0 合法的 `"admins-only"`；新增 `auto_pause=false`。

### 产线实测（scan → plan → build → fuel → verify → annotate）

角色 `opencode-verify-070`，目标：铜矿→炉子→铜板入箱，煤自动供给。

| 步骤 | 工具调用 | 结果 |
|---|---|---|
| 找矿 | factorio_query get_resource_patch all ×2 | 铜(51,40) 煤(87,14)，同屏 128 内 |
| 到位 | factorio_step goto | 1 步 |
| 看地形 | factorio_map 64×44 | 煤铜同框，确认间隙可放炉子 |
| 规划 | factorio_step plan_blueprint ×1 | **48 实体一次提交，48/48 成功** |
| 建造 | factorio_step build_ghosts ×1 | 48/48 |
| 点火 | factorio_step insert ×2（8 个 insert） | 过渡性手动煤 |
| 补丁 | factorio_step plan+build ×1 | 钻机落点偏半格，补 2 带 |
| 修正 | RCON 旋转 5 个机械臂 | 方向语义放反（见下） |
| 验证 | inspect_entity + RCON 诊断 | 箱子 45 秒产出 **13 铜板**，炉子 working |
| 标注 | factorio_annotate | `[产线] 铜线-01 @opencode-verify-070` |

**核心建造仅 5 次 factorio_step 调用**（规划 1、建造 1、点火 2、补丁 1）。

### 新发现的语义坑（已写入 SKILL.md「放置语义」）

1. 机械臂 `direction` 指向**取货侧**，放到背后——5 个机械臂全部放反，
   status=`waiting_for_source_items`。
2. 钻机 `drop_position` 相对中心偏半格，接带子前必须先 inspect。
3. headless autopause：无玩家连接 tick 不走，"机器不动"先查 game.tick。
