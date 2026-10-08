# 修复角色重绑时 rendering.destroy 报错（0.6.4）

日期：2026-10-06（Asia/Shanghai）

## 现象

重新绑定既有角色（如 `opencode-helper`）时报错
`LuaRendering doesn't contain key destroy`，原角色无法重绑，
用户临时改用新角色 `opencode-helper-2`。

## 根因

`mod/control.lua` 的 annotation/markers 代码使用 Factorio 1.1 的静态 API
`rendering.destroy(id)`（control.lua:44 与 :149）。Factorio 2.0 移除了该静态
函数；`rendering.draw_text` 返回 LuaRendering 对象，需调用对象方法
`:destroy()`。同文件里 `:valid` 检查已是 2.0 风格，仅 destroy 两处漏改。

## 改动

- `mod/control.lua`：两处 `rendering.destroy(p.label)` → `p.label:destroy()`。
- `mod/info.json`：版本 0.6.3 → 0.6.4；changelog 增加 0.6.4 Bugfixes 条目。

## 部署（kouka）

RCON `/save` → 备份 `backups/kouka-ai-map-<ts>-pre-0.6.4.zip` →
`docker cp` 0.6.4 zip（并删除容器内 0.6.3 zip）→ `docker restart`。
本地客户端 mods 目录同步为 `ai-coworker_0.6.4.zip`（旧包移入
`codex-sync-backup-20261006/`），客户端需重启重连。

## 验证结果

- 容器日志：`Loading mod settings ai-coworker 0.6.4` + 正确存档，无 mod 报错。
- 故障路径复测：`set_annotation("opencode-helper", {label=...})` 触发
  markers 重绘（旧 label 文本不同，确实走到 destroy 分支）→ `ok=true`，
  不再报错；随后 `{clear=true}` 恢复默认标签，仍 `ok=true`。
- 回归：`list_skills` 仍含 `deconstruct`（0.6.3 解封未回退）。

## 备注

`deconstruct` 技能按设计只挖掘"人工标记拆除"的实体（安全边界）。
批量清理树木的既定流程：玩家用拆迁规划器 / Shift+右键标记 → AI 执行
`deconstruct` 技能一次性挖掘。
