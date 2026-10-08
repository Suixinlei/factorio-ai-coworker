# OpenCode facade live-build E2E

日期：2026-10-05（Asia/Shanghai）

## 范围

- 服务器：`backend.kouka.tech:27015`，Factorio 2.0.77，Space Age。
- 模组：`ai-coworker` 0.6.2；启动日志确认选择最高版本 0.6.2。
- 角色：`builder-2-resources`，复用已有角色；`coop=true`、`autonomy=false`。
- 破坏性授权：用户明确批准部署、重启、真实建造，并要求删除历史 `session-*` 角色。

## 结果

1. 清理 72 条历史 `session-*` profile；清理后稳定角色 ID 可用。临时关闭 `auto_pause` 期间，旧版自动清理也回收了长期闲置 profile；随后用相同 ID 重新绑定 `builder-1-layout`、`builder-3-power`、`builder-4-science`、`chief-designer-v2`，`builder-2-resources` 原角色保留。
2. 服务器临时关闭 `auto_pause` 让无客户端时游戏 tick 推进；测试结束后恢复 `auto_pause=true` 并重启。
3. 在 `(-40,110)` 规划冶炼区附近，执行：

   ```json
   {"skill":"build_smelter","resource":"copper-ore","count":1,
    "furnace":"stone-furnace","strategy":"cheap","target_output":18}
   ```

4. 结果：放置成功；新炉 `unit_number=1180` 位于 `(-38,109)`，配方为 `copper-plate`，输入铜矿 10、煤 7，状态 `working`，复查时已有铜板产出 1。
5. 角色通过 `return_home` 回到 `(9,-17)`；存档已保存；最终 `auto_pause=true`，角色仍可用相同 ID 重绑，且没有 `session-*` 角色。

## 复现

```bash
PYTHONPATH=. .venv/bin/python audits/2026-10-05-opencode-mcp-e2e.py
```

真实建造使用同一 `bridge.factorio.opencode_mcp` stdio facade，并在每个有界步骤前后读取 `factorio_state`，将 `state_hash` 作为 `expected_state`。
