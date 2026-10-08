# Agent router E2E 验证（2026-10-06）

## 目标

验证项目内 `scripts/ao-router.sh` 是否能把同一个 WU 通过稳定角色 ID 投递到临时 AO session，并在角色离线时明确失败。

## 隔离方式

使用临时目录、假的 `ao` CLI 和临时角色映射；没有向当前 Factorio 游戏或现有五个 AO 会话发送测试消息。

## 复现步骤

```bash
bash -n scripts/ao-router.sh
# 建立临时 project/.ao/role-sessions.json，映射四个角色到 ao-1..ao-4
# 假 ao 对 session ls --json 返回空列表，对 send 记录消息并返回成功
PROJECT_ROOT="$TMP/project" \
AO_BIN="$TMP/bin/ao" \
ROUTING_FILE="$TMP/project/.ao/role-sessions.json" \
ROUTER_LOG="$TMP/router.ndjson" \
scripts/ao-router.sh once --wu WU-E2E-1
```

第一轮结果：四个角色均返回 `DELIVERED`，四条日志包含 `WU-E2E-1`。

随后从映射中移除 `builder-4-science`，再次执行：

```bash
PROJECT_ROOT="$TMP/project" \
AO_BIN="$TMP/bin/ao" \
ROUTING_FILE="$TMP/project/.ao/role-sessions.json" \
ROUTER_LOG="$TMP/router.ndjson" \
scripts/ao-router.sh once --wu WU-E2E-2
```

第二轮结果：三个角色返回 `DELIVERED`，四号返回 `OFFLINE`，命令退出码为 `1`；日志没有伪造四号成功。

## 结果

通过。router 已具备“稳定角色 → 临时 session → 直接投递 → 送达日志/离线失败”的最小闭环。真实 AO 验证时运行：

```bash
./scripts/ao-router.sh once --wu <WU-ID>
```

并检查 `.ao/router.ndjson` 以及建设家的 `ACK/DONE/BLOCKED` 回执。
