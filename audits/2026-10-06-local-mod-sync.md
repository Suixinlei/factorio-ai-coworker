# 本地客户端模组同步 E2E

日期：2026-10-06（Asia/Shanghai）

## 目标

把本地 Factorio 客户端的 `ai-coworker` 同步到服务器使用的 0.6.2，并保持 Space Age 基础模组启用。

## 操作

1. 读取服务器侧运行记录，确认服务器模组为 `ai-coworker` 0.6.2。
2. 在本地模组目录生成：
   `~/Library/Application Support/factorio/mods/ai-coworker_0.6.2.zip`
3. 将本地 `mod-list.json` 中的 `ai-coworker` 设为启用并标记为 0.6.2。
4. 在 `codex-sync-backup-20261006/` 保留同步前的配置和旧包备份，并将旧的 0.4.2/0.5.0 包移出活动模组目录。
5. 经用户明确授权后重启本地 Factorio 客户端。

## 验证结果

- `unzip -t`：通过，12 个文件无压缩错误。
- Factorio 2.0.77 无界面加载校验：通过；日志显示 `Loading mod settings ai-coworker 0.6.2`，模组 checksum `4260380536`。
- 本地 `mod-list.json`：`base`、`elevated-rails`、`quality`、`space-age`、`ai-coworker` 均为 `enabled: true`；活动目录只保留 `ai-coworker_0.6.2.zip`。
- 重启后的客户端成功连接原远程地址 `110.42.44.171:34197` 并进入游戏；日志显示 `Checksum for script __ai-coworker__/control.lua: 443724125`，随后状态进入 `InGame`。

## 复现

```bash
mods_dir="$HOME/Library/Application Support/factorio/mods"
node make-zip.js mod "$mods_dir/ai-coworker_0.6.2.zip" "ai-coworker_0.6.2"
unzip -t "$mods_dir/ai-coworker_0.6.2.zip"
```

Factorio 当前运行客户端已从该目录读取 0.6.2 并成功进入服务器。
