# AI coworker 标注接口 E2E 验证

日期：2026-10-06（Asia/Shanghai）

## 范围

- Mod remote interface：`remote.call('ai_player', 'set_annotation', agent_id, spec)`。
- OpenCode MCP：新增 `factorio_annotate`，只作用于当前绑定角色。
- 标注只跟随角色当前位置；不接受任意坐标，不开放任意 Lua。

## 复现步骤

在仓库根目录执行：

```bash
PYTHONPATH=. .venv/bin/python audits/2026-10-06-annotation-e2e.py
node make-zip.js mod /tmp/ai-coworker-0.6.3-check.zip ai-coworker_0.6.3
unzip -t /tmp/ai-coworker-0.6.3-check.zip
```

绑定一个角色后，MCP 调用示例：

```text
factorio_annotate(
  label="化工接口",
  map_tag="化工接口 / 三号",
  icon="signal-A"
)
```

清除自定义标注：`factorio_annotate(clear=true)`。单个字段传空字符串会恢复该字段的默认身份标识。

## 结果

- MCP stdio 工具目录通过：共 6 个工具，包含 `factorio_annotate`。
- 未绑定角色调用 `factorio_annotate` 正确返回 `ERROR: bind a Factorio role first`，没有产生游戏写入。
- `factorio_step` 仍拒绝 `run_lua`，确认 compact facade 没有重新开放任意 Lua。
- Mod 0.6.3 压缩包生成成功，`unzip -t` 通过，12 个文件无压缩错误。

本次验证未重启 Factorio 或切换存档；实际头顶文字和地图 chart tag 需要加载 0.6.3 mod 后，在已绑定角色上执行上述调用复核。
