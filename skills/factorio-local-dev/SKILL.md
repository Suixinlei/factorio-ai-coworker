---
name: factorio-local-dev
description: 在本地启动 headless Factorio 服务器，用于 ai-coworker mod 的快速迭代开发与 E2E 验证。无需远程 kouka 环境。
metadata:
  purpose: factorio-local-headless-loop
---

# Factorio 本地 Headless 开发

这条链路把 Factorio 单机/多人游戏的「服务端」放在本机，改完 mod 后秒级重启验证，
不干扰远程共享环境。

## 前置条件

- macOS + Steam 版 Factorio（二进制位于 `~/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio`）。
- **headless 与 GUI 客户端完全隔离**：Factorio 对 write-data 目录有排他锁（`.lock`），共用会导致 GUI 客户端无法启动。脚本自动生成 `local-server/config.ini`（write-data 指向 `local-server/data`），并把 mod 打包进独立的 `local-server/mods/`（含 `mod-list.json`）。两者可同时运行。
- 若想让 GUI 客户端也玩这个 mod，需自行把 zip 放进客户端 mods 目录并重启客户端（脚本不管那边）。

## 启动服务器

```bash
./scripts/local-headless.sh
```

脚本行为：

1. 生成隔离配置 `local-server/config.ini`（write-data = `local-server/data`）。
2. 把 `mod/` 按 info.json 版本号打包为 `local-server/mods/ai-coworker_<版本>.zip`（zip 内含顶层目录，Factorio 强制要求），并生成启用 mod 的 `mod-list.json`。**每次启动都会重新打包，改完 Lua 直接重启脚本即生效。**
3. 若 `local-server/saves/dev-map.zip` 不存在，自动生成一张 Nauvis 测试图。
4. 若 `local-server/rcon.pw` 不存在，自动生成 32 字符 RCON 密码。
5. 后台启动 headless 服务器：
   - 游戏端口 `34198`
   - RCON 端口 `27016`（仅监听 `127.0.0.1`）
   - 日志 `local-server/server.log`

查看日志：

```bash
tail -f local-server/server.log
```

直到出现：`Hosting game at IP ADDR:({0.0.0.0:34198})` 和 `Starting RCON interface at IP ADDR:({127.0.0.1:27016})` 即就绪。

## 让 CLI 连本地

CLI 每次调用都会重新读取 RCON 配置，不需要重启客户端。可直接做 RCON 冒烟：

```bash
FACTORIO_RCON_HOST=127.0.0.1 FACTORIO_RCON_PORT=27016 \
  FACTORIO_RCON_PASSWORD=$(cat local-server/rcon.pw) \
  .venv/bin/python -m cli status
```

## 标准迭代循环

1. 改 `mod/` 下的 Lua 代码。
2. 重启 headless 服务器（脚本会自动重新打包 mod zip）：
   ```bash
   pkill -f "start-server.*local-server"
   sleep 5   # 等 Factorio 释放 write-data 锁，否则新实例会因锁冲突退出
   ./scripts/local-headless.sh
   ```
3. 等待日志出现 `Starting RCON interface ...`。
4. 做 E2E 验证（绑定测试角色、跑技能、跑查询、看日志）。
5. 重复。

注意：pkill 的模式必须匹配绝对路径（脚本传入的是绝对路径），用 `start-server.*local-server`；
杀进程后务必等几秒再启动，否则报 `Couldn't acquire exclusive lock ... .lock`。

## 发布到 Factorio Mod Portal

公开发布前，先确认 `mod/info.json` 中的版本是三段式版本号，例如 `0.1.0`，并在 `mod/changelog.txt` 顶部添加对应版本说明。仓库提供的发布脚本会读取 Mod 元数据，生成符合 Factorio 目录要求的 `dist/ai-coworker_<版本>.zip`，并通过 Mod Portal API 上传。

首次发布需要在 Factorio 账号的 API Key 页面创建带有 `ModPortal: Publish Mods` 权限的 Key。推荐把 Key 放在用户 shell 配置中，不要写入仓库：

```bash
# ~/.zshrc
export FACTORIO_MOD_PORTAL_TOKEN=你的_Mod_Portal_API_Key
```

重新打开终端，或在当前终端加载配置后执行 dry-run：

```bash
source ~/.zshrc
python3 scripts/publish-mod.py --dry-run
unzip -t dist/ai-coworker_0.1.0.zip
```

确认压缩包结构和版本无误后正式发布：

```bash
source ~/.zshrc
python3 scripts/publish-mod.py
```

脚本会提交 `utilities` 分类、MIT 许可证、Mod Portal 描述和 GitHub 源码地址；它不会打印 API Key。发布成功后可在 <https://mods.factorio.com/mod/ai-coworker> 检查版本和下载记录。

如果需要发布新版本，先修改 `mod/info.json` 和 `mod/changelog.txt`，再重复 dry-run、ZIP 校验和正式发布流程。

## 客户端加入本地服

如果你想用 GUI 客户端围观/手操：

- headless 用隔离配置，**不影响 GUI 客户端正常启动**，两者可同时运行。
- Play → Multiplayer → Connect to server → 地址 `127.0.0.1:34198`。
- 客户端 mods 目录需有同版本 mod zip 并重启过客户端（版本不一致会连接失败）。

## 停止服务器

```bash
pkill -f "start-server.*local-server"
```

## 注意事项

- `local-server/` 目录与 RCON 密码文件不入库（已写 `.gitignore`）。
- 不要把真实生产档放进 `local-server/saves/` 做开发测试；这里是可丢弃的测试图。
- 若 `34198` 或 `27016` 被占用，修改 `scripts/local-headless.sh` 里的端口，并同步修改 CLI 调用中的 `--port` 或 `FACTORIO_RCON_PORT`。
- 历史上 headless 与 GUI 共用 write-data 曾触发 Factorio 单实例锁，导致 GUI 打不开并残留无参数的僵尸 factorio 进程；如遇此情况 `kill` 掉该进程（命令行无参数的 factorio）即可。
