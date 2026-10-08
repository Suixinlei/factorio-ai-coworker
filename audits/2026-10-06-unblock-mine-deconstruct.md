# 解除 deconstruct/mine 的 mod 侧禁用

日期：2026-10-06（Asia/Shanghai）

## 目标

修复"deconstruct 技能与 mine 原语在当前部署中被 mod 侧硬禁用"的问题
（`mod/control.lua` 的 `BLOCKED_SKILLS`/`BLOCKED_ACTIONS` 自首次部署 commit
`038cfee` 起无条件拒绝二者，返回 `destructive skill/action disabled`）。
经用户授权执行（"修复下啊"）。

## 改动

1. `mod/control.lua:193-194`：
   - `BLOCKED_SKILLS = {}`（原 `{deconstruct=true}`）
   - `BLOCKED_ACTIONS = {destroy=true}`（原 `{mine=true, destroy=true}`，`destroy` 保持禁用且 facade 本就不暴露）
2. `mod/changelog.txt`：0.6.3 增加 Changes 条目说明解除封锁；项目策略
   （调用 `deconstruct` 前需用户显式授权）不变，仍写在 SKILL.md。
3. 打包：`node make-zip.js mod <out> ai-coworker_0.6.3`（info.json 0.6.3）。

## 部署（kouka）

1. RCON `/save` 落盘当前世界 → `kouka-ai-map.zip`。
2. 备份：`backups/kouka-ai-map-20261006T061618Z-pre-0.6.3.zip`。
3. scp 到 kouka `/tmp` + `docker cp` 进 `factorio-kouka-ai:/factorio/mods/`
   （xiaobin 无 sudo，走 docker 组权限）。
4. `docker restart factorio-kouka-ai`。
5. 本地客户端 mods 目录：安装 `ai-coworker_0.6.3.zip`，旧 0.6.2 zip 移入
   `codex-sync-backup-20261006/`。客户端需重启后才能重连（版本需匹配 0.6.3）。

## 验证结果

- 新 zip 内 `control.lua` 确认 `BLOCKED_SKILLS = {}`、`BLOCKED_ACTIONS = {destroy=true}`。
- 重启后容器日志：`Loading mod settings ai-coworker 0.6.3`、
  `Loading map /factorio/saves/kouka-ai-map.zip`（06:16 的 `/save`）。
- RCON 运行时探针（只读 / 无副作用）：
  - `list_skills` 现包含 `deconstruct`（此前被过滤）。
  - `run_primitive("zzz-nonexistent-probe", {action="mine"})` 返回
    `unknown role` 而非 `destructive action disabled`，证明 mine 封锁已移除。

## 复现

```bash
node make-zip.js mod /tmp/ai-coworker_0.6.3.zip ai-coworker_0.6.3
scp /tmp/ai-coworker_0.6.3.zip kouka:/tmp/
ssh kouka 'docker cp /tmp/ai-coworker_0.6.3.zip factorio-kouka-ai:/factorio/mods/ && docker restart factorio-kouka-ai'
```
