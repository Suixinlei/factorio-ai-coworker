# E2E：plan_mining_outpost 全自动铺矿技能（ai-coworker 0.8.4）

日期：2026-10-08
环境：本地 headless（`scripts/local-headless.sh`，Factorio 2.0.77 + space-age，共享 dev-map）
复现：`.venv/bin/python audits/2026-10-08-mining-outpost-e2e.py`（或 `python3`；服务器需已在 27016 运行）

## 需求

用户：查询网上规则，增加"对某个矿全自动铺矿机、电线杆、belt"的方法；矿机与电线杆种类必须是参数。

## 规则来源（官方 Wiki，2026-10 查证）

- [Electric mining drill](https://wiki.factorio.com/Electric_mining_drill)：3×3 占位、5×5 采矿域、90kW、产物落在朝向前方第 2 格的 output tile。
- [Big mining drill](https://wiki.factorio.com/Big_mining_drill)（Space Age）：5×5 占位、**13×13** 采矿域。
- [Medium electric pole](https://wiki.factorio.com/Medium_electric_pole)：2.0 改平衡——供电域 **7×7**（1.x 是 9×9），接线 9。

## 实现（编码的铺设规则，全部从运行时原型推导）

- 点阵步距 S = 2H+1，H = `floor(mining_drill_radius)`（电钻 2.49→S=5；大钻 6.49→S=13）→ 全覆盖、零重叠、天然留带缝。
- 成对行相向朝向共享两条皮带行（带行 = 中心行 ±(floor(F/2)+1)，即钻机落料格）。
- 每 2S 行留"街道"放电线杆；杆列间距 = `min(wire-1, 2*supply+1)`（从原型读，2.0 数值变化不再踩坑）；预检供电半径够不够点阵（大钻需 substation 级）并明示。
- 参数：`resource / x,y / direction / drill / pole / belt / min_ore / max_drills / radius`。
- 幂等：重跑只扩展不重复；被占槽位精确报告 `name@tile`（上限 5 条+more）；同种既有实体算"已建"。

## 踩坑与直接修复（用户要求：修根因，不绕过）

| 坑 | 根因 | 修复 |
|---|---|---|
| `resource_searching_radius` 不存在 | 2.0 API 改名 | 用 `mining_drill_radius`（探针实测 2.49/6.49/0.99） |
| 杆原型 getter 全部 `Invalid QualityID` | 2.0.77 RCON 沙箱对 quality 参数校验异常（连合法 LuaQualityPrototype 都拒） | 优先尝试 getter → 基础杆种 Wiki 规格表 → 保守小杆缺省，报告注明 |
| ghost 被占槽位"建不起来"但不报是谁 | 技能只报数量 | 技能直接列出占用实体 `name@tile`；调用方精确移除（E2E 不再用区域启发式——启发式删不到无 ghost 的槽位） |
| 服务器测试中途被 SIGTERM | `nohup ... &` 仍在调用方进程组，harness 回收进程树时被拖杀 | `local-headless.sh` 用 Python `start_new_session=True` 分会话启动 |
| 钻机复活失败但周围无实体 | 我遗留的 builder 角色站在 (57,36)，碰撞盒压住脚印一角 | 删除该角色；E2E 预清理把测试区内角色移开（STEP_ASIDE） |
| `direction="northeast"` 被接受 | DIRECTION_MAP 含 16 向 | 技能限定四正向 |

## 结果（共享地图铁矿 patch @ (57,36)，1605 tiles）

| 检查 | 结果 |
|---|---|
| 非法方向 northeast | 拒绝，提示四正向 |
| big-mining-drill + medium 杆 | 预检拒绝："rows 13 apart, needs reach 7 — pass a bigger pole (e.g. substation)" |
| 规划（medium 杆，east 流向） | 79 电钻 + 650 皮带 + 49 中型杆，**覆盖率 99%** |
| 每台钻机输出格有皮带 | 79/79 |
| 每台钻机在杆供电范围 | 79/79 |
| 杆链接线间距 ≤ wire | 0 违规 |
| 皮带全部朝流向 | 650/650 |
| 中型杆未研究时自动降级 | 第二矿点自动用 small-electric-pole 规划成功 |
| 完整规划后重跑 | no-op 成功（不重复、不报错） |
| 占用报告与精确清理 | `small-electric-pole@47,18…` 按清单移除，重规划补齐 |
| 材料作弊 + build_ghosts | **778/778 建成**（79 钻 + 650 带 + 49 杆） |
| 实体级验证 | 每台钻机 drop_position 有实体皮带；每台钻机 electric_network_id ∈ 杆网络（79/79） |
| 钻机状态 | `no_power`（预期：电站接入不在本工具范围） |

## 遗留

- 前哨杆街为平行链（间距 2S=10 > medium wire 9）：报告中已提示在皮带出口桥接或 `pole=substation` 成单网。
- 铺完后的电站接入、矿流汇入总线属于后续任务（用户已明确不在本工具范围）。
- `get_mining_drill_radius()`/`get_supply_area_distance()` 的 quality 参数在 RCON 沙箱不可用（引擎侧问题），POLE_SPECS 表为 2.0 基础四杆的核证回退。
